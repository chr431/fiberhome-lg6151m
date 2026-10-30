#!/bin/bash
# host-only plumbing test for stackdump (x86_64 WSL); not a device test
set -u
gcc -O2 -o /tmp/stackdump_host /mnt/d/Repo/lg6151m-project/lg6151m-public/tools/oneoff/sigsegv/stackdump.c 2>/dev/null
sleep 100 &
sp=$(pgrep -n -x sleep || true)
echo "PID=$sp"
if [ -z "$sp" ]; then echo "no sleep"; exit 1; fi
/tmp/stackdump_host "$sp" /tmp/test.stack 16
ls -l /tmp/test.stack
python3 /mnt/d/Repo/lg6151m-project/lg6151m-public/tools/oneoff/sigsegv/natural_scan.py --format sd /tmp/test.stack 2>&1 | head -5
pkill -x sleep 2>/dev/null || true
