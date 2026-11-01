#pragma once
#include <stdint.h>
#include <stddef.h>
typedef struct {
    int32_t pid, ppid;
    uint32_t uid, status;
    uint64_t start_seconds, start_microseconds, footprint;
    int footprint_valid;
    char path[4096];
} MGProcess;
typedef struct {
    uint64_t physical, used, swap_used, swapouts;
    int valid;
} MGSystem;
int mg_pids(int32_t *pids, int capacity);
int mg_process(int32_t pid, int sample, MGProcess *out);
MGSystem mg_system(void);
int mg_atomic_write(const char *path, const void *data, size_t count);
typedef struct {
    int32_t pid; uint32_t uid;
    uint64_t start_seconds, start_microseconds;
    double uptime;
    char path[4096];
} MGHeartbeat;
int mg_heartbeat_write(const char *name, const MGHeartbeat *value);
int mg_heartbeat_read(const char *name, MGHeartbeat *value);
void mg_heartbeat_remove(const char *name);

// Caller holds the per-user leases lock. The active slot is published only after the entire copy.
#define MG_LEASE_CAPACITY (256 * 1024)
int mg_leases_read(const char *name, void *out, size_t capacity, size_t *length);
int mg_leases_write(const char *name, const void *data, size_t length);
