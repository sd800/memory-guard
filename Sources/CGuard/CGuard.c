#include "CGuard.h"
#include <libproc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <mach/mach.h>
#include <unistd.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <sys/mman.h>
#include <stdatomic.h>

int mg_pids(int32_t *pids, int capacity) {
    return proc_listallpids(pids, capacity * sizeof(int32_t));
}
int mg_process(int32_t pid, int sample, MGProcess *out) {
    struct proc_bsdinfo b = {0};
    memset(out, 0, sizeof(*out));
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &b, sizeof(b)) != sizeof(b)) return -1;
    out->pid = pid; out->ppid = b.pbi_ppid; out->uid = b.pbi_uid;
    out->status = b.pbi_status; out->start_seconds = b.pbi_start_tvsec;
    out->start_microseconds = b.pbi_start_tvusec;
    if (proc_pidpath(pid, out->path, sizeof(out->path)) <= 0) return -1;
    if (sample) {
        struct rusage_info_v2 usage = {0};
        if (proc_pid_rusage(pid, RUSAGE_INFO_V2, (rusage_info_t *)&usage) == 0) {
            out->footprint = usage.ri_phys_footprint; out->footprint_valid = 1;
        }
    }
    return 0;
}
MGSystem mg_system(void) {
    MGSystem out = {0}; size_t size = sizeof(out.physical);
    if (sysctlbyname("hw.memsize", &out.physical, &size, NULL, 0)) return out;
    vm_statistics64_data_t vm; mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    mach_port_t host = mach_host_self(); vm_size_t page = 0;
    kern_return_t result = host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &count);
    host_page_size(host, &page); mach_port_deallocate(mach_task_self(), host);
    if (result != KERN_SUCCESS || !page) return out;
    int64_t pages = (int64_t)vm.active_count + vm.inactive_count + vm.wire_count + vm.compressor_page_count
        - vm.purgeable_count - vm.external_page_count;
    out.used = pages > 0 ? (uint64_t)pages * page : 0;
    if (out.used > out.physical) out.used = out.physical;
    out.swapouts = vm.swapouts * (uint64_t)page;
    struct xsw_usage swap = {0}; size = sizeof(swap);
    if (!sysctlbyname("vm.swapusage", &swap, &size, NULL, 0)) out.swap_used = swap.xsu_used;
    out.valid = 1; return out;
}
// fsync before rename; never follow the destination's symlink. Files are private to the user.
int mg_atomic_write(const char *path, const void *data, size_t count) {
    char temp[4096]; if (snprintf(temp, sizeof(temp), "%s.XXXXXX", path) >= sizeof(temp)) return ENAMETOOLONG;
    int fd = mkstemp(temp); if (fd < 0) return errno;
    fchmod(fd, 0600); size_t written = 0; int error = 0;
    while (written < count) {
        ssize_t n = write(fd, (const char *)data + written, count - written);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { error = errno ? errno : EIO; break; }
        written += n;
    }
    if (!error && fsync(fd)) error = errno;
    close(fd);
    if (!error && rename(temp, path)) error = errno;
    if (error) { unlink(temp); return error; }
    char parent[4096]; strlcpy(parent, path, sizeof(parent));
    char *slash = strrchr(parent, '/'); if (slash) *slash = '\0';
    int dir = open(parent, O_RDONLY | O_DIRECTORY);
    if (dir < 0) return errno;
    if (fsync(dir)) error = errno;
    close(dir); return error;
}

typedef struct { _Atomic uint64_t sequence; MGHeartbeat value; } MGSharedHeartbeat;
// One writer per role (the singleton job). Sequence validation fails closed if a writer dies mid-update.
int mg_heartbeat_write(const char *name, const MGHeartbeat *value) {
    int fd = shm_open(name, O_CREAT | O_RDWR, 0600); if (fd < 0) return errno;
    struct stat stat;
    if (fstat(fd, &stat) || stat.st_uid != getuid()) { close(fd); return EACCES; }
    if (stat.st_size == 0 && ftruncate(fd, sizeof(MGSharedHeartbeat))) { int e = errno; close(fd); return e; }
    if (stat.st_size != 0 && stat.st_size < sizeof(MGSharedHeartbeat)) { close(fd); return EINVAL; }
    MGSharedHeartbeat *shared = mmap(NULL, sizeof(*shared), PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd); if (shared == MAP_FAILED) return errno;
    uint64_t odd = atomic_load_explicit(&shared->sequence, memory_order_relaxed) | 1;
    atomic_store_explicit(&shared->sequence, odd, memory_order_seq_cst);
    memcpy(&shared->value, value, sizeof(*value));
    atomic_store_explicit(&shared->sequence, odd + 1, memory_order_release);
    munmap(shared, sizeof(*shared)); return 0;
}
int mg_heartbeat_read(const char *name, MGHeartbeat *value) {
    int fd = shm_open(name, O_RDONLY, 0); if (fd < 0) return errno;
    struct stat stat;
    if (fstat(fd, &stat) || stat.st_uid != getuid() || stat.st_size < sizeof(MGSharedHeartbeat)) { close(fd); return EACCES; }
    MGSharedHeartbeat *shared = mmap(NULL, sizeof(*shared), PROT_READ, MAP_SHARED, fd, 0);
    close(fd); if (shared == MAP_FAILED) return errno;
    int result = EAGAIN;
    for (int i = 0; i < 3; i++) {
        uint64_t first = atomic_load_explicit(&shared->sequence, memory_order_acquire);
        if (!first || (first & 1)) continue;
        memcpy(value, &shared->value, sizeof(*value));
        atomic_thread_fence(memory_order_seq_cst);
        if (first == atomic_load_explicit(&shared->sequence, memory_order_acquire)) { result = 0; break; }
    }
    munmap(shared, sizeof(*shared)); return result;
}
void mg_heartbeat_remove(const char *name) { shm_unlink(name); }

typedef struct {
    _Atomic uint32_t active; // 0: not yet published, 1 or 2: complete slot
    uint32_t lengths[2];
    unsigned char slots[2][MG_LEASE_CAPACITY];
} MGLeasePages;

static int mg_lease_map(const char *name, int writing, MGLeasePages **pages) {
    int fd = shm_open(name, writing ? O_CREAT | O_RDWR : O_RDONLY, 0600);
    if (fd < 0) return errno;
    struct stat st; int err = 0;
    if (fstat(fd, &st)) err = errno;
    else if (st.st_uid != getuid() || (st.st_mode & 077)) err = EACCES;
    else if (st.st_size == 0 && writing) {
        if (ftruncate(fd, sizeof(**pages))) err = errno;
    } else if (st.st_size < sizeof(**pages)) err = st.st_size == 0 ? ENOENT : EINVAL;
    if (!err) {
        *pages = mmap(NULL, sizeof(**pages), writing ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, 0);
        if (*pages == MAP_FAILED) err = errno;
    }
    close(fd); return err;
}
int mg_leases_write(const char *name, const void *data, size_t length) {
    if (!length) return shm_unlink(name) == 0 || errno == ENOENT ? 0 : errno;
    if (length > MG_LEASE_CAPACITY) return E2BIG;
    MGLeasePages *pages; int err = mg_lease_map(name, 1, &pages); if (err) return err;
    uint32_t active = atomic_load_explicit(&pages->active, memory_order_acquire);
    if (active > 2) err = EINVAL;
    else {
        unsigned slot = active == 1 ? 1 : 0;
        memcpy(pages->slots[slot], data, length); pages->lengths[slot] = (uint32_t)length;
        atomic_store_explicit(&pages->active, slot + 1, memory_order_release);
    }
    munmap(pages, sizeof(*pages)); return err;
}
int mg_leases_read(const char *name, void *out, size_t capacity, size_t *length) {
    MGLeasePages *pages; int err = mg_lease_map(name, 0, &pages); if (err) return err;
    uint32_t active = atomic_load_explicit(&pages->active, memory_order_acquire);
    if (!active) err = ENOENT;
    else if (active > 2) err = EINVAL;
    else {
        *length = pages->lengths[active - 1];
        if (!*length || *length > MG_LEASE_CAPACITY) err = EINVAL;
        else if (out && capacity < *length) err = ERANGE;
        else if (out) memcpy(out, pages->slots[active - 1], *length);
    }
    munmap(pages, sizeof(*pages)); return err;
}
