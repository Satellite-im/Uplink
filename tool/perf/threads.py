#!/usr/bin/env python3
"""Per-thread CPU time of an Android app over a window, read from /proc on the device.

usage: threads.py <seconds> [serial] [package]
Prints each thread's CPU milliseconds (user+system) in the window, busiest first, for the app's process and any
process it started, and the total as a share of one core.
"""
import subprocess, sys, time

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 30
serial = sys.argv[2] if len(sys.argv) > 2 else 'emulator-5584'
pkg = sys.argv[3] if len(sys.argv) > 3 else 'com.infamousvague.ghostmessaging'

def sh(cmd):
    return subprocess.run(['adb', '-s', serial, 'shell', cmd], capture_output=True, text=True).stdout

def pids():
    out = {}
    uid = None
    rows = [l.split(None, 3) for l in sh('ps -A -o PID,PPID,USER,NAME').splitlines()[1:]]
    for r in rows:
        if len(r) == 4 and r[3].strip().startswith(pkg):
            uid = r[2]
    for r in rows:
        if len(r) == 4 and r[2] == uid:
            out[r[0]] = r[3].strip()
    return out

def snap(ps):
    got = {}
    cmd = ' ; '.join(f'for t in /proc/{p}/task/*; do cat $t/stat 2>/dev/null; done' for p in ps)
    # Which process a thread is in is not in its stat line: asked a process at a time.
    for p in ps:
        for line in sh(f'for t in /proc/{p}/task/*; do cat $t/stat 2>/dev/null; done').splitlines():
            try:
                tid = line[:line.index(' ')]
                name = line[line.index('(') + 1:line.rindex(')')]
                rest = line[line.rindex(')') + 2:].split()
                got[(p, tid)] = (name, int(rest[11]), int(rest[12]))
            except Exception:
                pass
    return got

ps = pids()
if not ps:
    sys.exit('the app is not running')
a = snap(ps)
t0 = time.time()
time.sleep(secs)
ps2 = pids()
b = snap(ps2)
dt = time.time() - t0
rows = []
for k, (name, u, s) in b.items():
    u0, s0 = (a[k][1], a[k][2]) if k in a else (0, 0)
    d = (u - u0) + (s - s0)
    if d > 0:
        rows.append((d * 10, (u - u0) * 10, (s - s0) * 10, ps2.get(k[0], '?'), name, k[1]))
rows.sort(reverse=True)
total = sum(r[0] for r in rows)
print(f'window {dt:.1f}s  total {total} ms  = {100 * total / 1000 / dt:.2f}% of one core   processes: {", ".join(f"{p}:{n}" for p, n in ps2.items())}')
by = {}
for r in rows:
    by[r[4]] = by.get(r[4], 0) + r[0]
print('by thread name:')
for name, ms in sorted(by.items(), key=lambda x: -x[1])[:25]:
    print(f'  {ms:7d} ms  {100 * ms / 1000 / dt:6.2f}%  {name}')
