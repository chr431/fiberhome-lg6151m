#!/bin/sh
# /init for the LG6151M lab (instrument) kernel initramfs.
# Boot banner + instrumentation self-check + heartbeat + canary (vsurv4).
# Alive check follows project discipline: exact argv token scan of
# /proc/*/cmdline, excluding self and parent (no pgrep -f substring traps).

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t debugfs none /sys/kernel/debug 2>/dev/null || true
mount -t tracefs none /sys/kernel/tracing 2>/dev/null || true
mount -t tmpfs tmpfs /tmp 2>/dev/null || true
[ -e /dev/null ] || mknod /dev/null c 1 3
[ -e /dev/console ] || mknod /dev/console c 5 1
mkdir -p /data/repro   # vsurv4 dump target (RAM)

b()
{
    echo ""                                    > /dev/console
    echo "==============================================" > /dev/console
    echo " $*"                                  > /dev/console
    echo "==============================================" > /dev/console
}

b "LG6151M LAB KERNEL C1 -- initramfs userspace reached"
uname -a > /dev/console

b "instrumentation self-check"
echo "kallsyms entries: $(wc -l < /proc/kallsyms)" > /dev/console
for f in /sys/kernel/tracing/kprobe_events \
         /sys/kernel/tracing/uprobe_events \
         /sys/kernel/debug /proc/self/pagemap \
         /proc/self/clear_refs /proc/kcore /proc/config.gz; do
    if [ -e "$f" ]; then echo "PRESENT: $f" > /dev/console
    else echo "MISSING: $f" > /dev/console; fi
done
echo "perf paranoia: $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null)" > /dev/console
echo "kptr_restrict: $(cat /proc/sys/kernel/kptr_restrict 2>/dev/null)" > /dev/console
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null
echo 0 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
if [ -e /proc/config.gz ]; then
    cnt=$(zcat /proc/config.gz | grep -c -E "^CONFIG_(KPROBES|KPROBE_EVENTS|DYNAMIC_FTRACE|FUNCTION_TRACER|PERF_EVENTS|HW_BREAKPOINT|USERFAULTFD|PROC_PAGE_MONITOR|KEXEC|KEXEC_FILE|KGDB|KGDB_SERIAL_CONSOLE|KALLSYMS_ALL|UPROBE_EVENTS|PAGE_OWNER|DEBUG_FS)=y")
    echo "instrument config symbols (=y): $cnt/16 expected" > /dev/console
    zcat /proc/config.gz | grep -E "^CONFIG_(KPROBES|KPROBE_EVENTS|DYNAMIC_FTRACE|FUNCTION_TRACER|PERF_EVENTS|HW_BREAKPOINT|USERFAULTFD|PROC_PAGE_MONITOR|KEXEC_FILE|KGDB|KGDB_SERIAL_CONSOLE|KALLSYMS_ALL|UPROBE_EVENTS|PAGE_OWNER|DEBUG_FS)=y" > /dev/console
fi

b "starting canary vsurv4 (SIGSEGV survivor, dumps -> /data/repro)"
/vsurv4 > /dev/console 2>&1 &

alive_check()
{
    # exact argv[0] token match on /proc/*/cmdline; exclude self($$) and parent($PPID)
    hit=0
    for c in /proc/[0-9]*/cmdline; do
        pid=${c#/proc/}; pid=${pid%/cmdline}
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        IFS= read -r argv0 < "$c" 2>/dev/null || continue
        [ "$argv0" = "/vsurv4" ] && hit=$((hit+1))
    done
    echo $hit
}

b "heartbeat every 10s (uptime | MemAvail | vsurv4 alive-count)"
i=0
while :; do
    i=$((i+1))
    up=$(cut -d. -f1 /proc/uptime)
    ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    echo "[hb $i] uptime=${up}s MemAvail=${ma}kB vsurv4=$(alive_check) date=$(date 2>/dev/null)" > /dev/console
    sleep 10
done
