#!/usr/bin/env python3
"""Read only Memory Guard's own rusage; does not signal or inspect protected apps."""
import ctypes
import json
import struct
import time
import subprocess
import re
import os
from pathlib import Path

root = Path.home() / 'Library/Application Support/MemoryGuard'
lib = ctypes.CDLL('/usr/lib/libproc.dylib', use_errno=True)
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
def metadata():
    return {p.name: (p.stat().st_ino, p.stat().st_size, p.stat().st_mtime_ns)
            for p in root.iterdir() if p.is_file()}
def cpu_seconds(pid):
    fields = subprocess.check_output(['ps', '-p', str(pid), '-o', 'time='], text=True).strip().split(':')
    return sum(float(part) * 60 ** i for i, part in enumerate(reversed(fields)))
initial_files = metadata()
start = time.monotonic()
samples = []
for index in range(7):
    sample = {'elapsed': time.monotonic() - start, 'processes': {}}
    for role in ['agent', 'recovery']:
        job = subprocess.check_output(['/bin/launchctl', 'print', f'gui/{os.getuid()}/local.memoryguard.{role}'], text=True)
        pid = int(re.search(r'\bpid = (\d+)', job).group(1))
        buf = ctypes.create_string_buffer(1024)
        if lib.proc_pid_rusage(pid, 2, ctypes.byref(buf)):
            raise OSError(ctypes.get_errno(), 'proc_pid_rusage')
        values = struct.unpack_from('=18Q', buf.raw, 16)
        sample['processes'][role] = {'pid': pid, 'cpu_seconds': cpu_seconds(pid),
            'resident_mib': values[6] / 1048576, 'footprint_mib': values[7] / 1048576,
            'disk_written_bytes': values[17]}
    samples.append(sample)
    print(json.dumps(sample), flush=True)
    if index < 6:
        time.sleep(10)
summary = {}
for role in ['agent', 'recovery']:
    first, last = samples[0]['processes'][role], samples[-1]['processes'][role]
    summary[role] = {'same_process': first['pid'] == last['pid'],
        'average_cpu_percent': (last['cpu_seconds'] - first['cpu_seconds']) / (samples[-1]['elapsed'] - samples[0]['elapsed']) * 100,
        'first_footprint_mib': first['footprint_mib'], 'last_footprint_mib': last['footprint_mib'],
        'max_footprint_mib': max(s['processes'][role]['footprint_mib'] for s in samples),
        'disk_written_bytes': last['disk_written_bytes'] - first['disk_written_bytes']}
final_files = metadata()
print(json.dumps({'summary': summary, 'changed_state_files': sorted(k for k in set(initial_files) | set(final_files)
      if initial_files.get(k) != final_files.get(k))}), flush=True)
