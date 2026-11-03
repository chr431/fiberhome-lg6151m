#!/bin/sh
# lab_uwhook_ctl.sh -- uwhook.ko positive/negative control (kdev PROTOCOL_UWHOOK §1-§2)
# Window for the controls: [0x7ff000000000, 0x800000000000) = user stacks only (mmap heap sits lower).
KO=/data/repro/uwhook.ko
echo "=== 0. preconditions ==="
echo "panic_on_oops=$(cat /proc/sys/kernel/panic_on_oops)"
echo "kernel=$(uname -r)"
echo "ko_md5=$(md5sum $KO)"
echo "=== 1. insmod (wide stack window) ==="
insmod $KO lo=0x7ff000000000 hi=0x800000000000
echo "insmod_rc=$?"
dmesg | tail -3
echo "=== 2. baseline /proc/uwhook ==="
cat /proc/uwhook
echo "=== 3. run uwtest (getrusage on stack = positive; read() into mmap = negative) ==="
/data/repro/uwtest &
UWPID=$!
sleep 3
echo "uwtest_pid=$UWPID"
cat /proc/uwhook
wait $UWPID 2>/dev/null
echo "=== 4. after uwtest ==="
cat /proc/uwhook
echo "=== 5. rmmod ==="
rmmod uwhook
echo "rmmod_rc=$?"
dmesg | tail -3
