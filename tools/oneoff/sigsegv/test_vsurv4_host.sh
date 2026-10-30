#!/bin/bash
# host-only plumbing test for vsurv4 (x86_64 WSL); not a device test
set -u
mkdir -p /data/repro
rm -f /tmp/vsurv4.out
/tmp/vsurv4_host > /tmp/vsurv4.out 2>&1 &
sleep 1
p=$(sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' /tmp/vsurv4.out | head -1)
echo "PID=$p"
if [ -z "$p" ]; then echo "no pid"; cat /tmp/vsurv4.out; exit 1; fi
out="/data/repro/h4_$p"_1.bin
kill -11 "$p"
sleep 1
ls -l "$out" 2>/dev/null || echo "NO FILE"
xxd -l 96 "$out" 2>/dev/null | head -8
kill -9 "$p" 2>/dev/null
cat /tmp/vsurv4.out
