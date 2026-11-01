#!/bin/sh
# /init for the LG6151M lab (instrument) kernel initramfs -- C2 repack.
# C1 base (banner/self-check/heartbeat/vsurv4) + scanary window-1 auto-start
# for the C2 first-boot ablation arm (pre-registered invocation, do not edit
# without amending 05_LOG/2026-11-01-12-c2-firstboot-ablation.md).
# Alive checks follow project discipline: exact argv token scan of
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
mkdir -p /data/repro   # vsurv4 + scanary dump target (RAM, lost on reboot)

b()
{
    echo ""                                    > /dev/console
    echo "==============================================" > /dev/console
    echo " $*"                                  > /dev/console
    echo "==============================================" > /dev/console
}

b "LG6151M LAB KERNEL C2 -- initramfs userspace reached (+scanary)"
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

b "starting scanary window-1 (C2 ablation arm: 1800s, victim=main, decoy 8M)"
# Pre-registered invocation -- same shape as the vendor-kernel baseline arm
# (--victim main: writer historically targets start_stack-K, PROTOCOL s7.1.3;
#  --hold-us 10000: observation mode, full-speed rewrite would mask records).
/scanary --victim main --duration 1800 --epoch-sec 0 --probe-sec 120 \
          --hold-us 10000 --period-us 5000 --stride 16 --writeback safe \
          --log /data/repro/scanary_c2_w1.log > /dev/console 2>&1 &
sleep 3
head -8 /data/repro/scanary_c2_w1.log > /dev/console 2>&1
echo "summarize with: /bin/scanary_report /data/repro/scanary_c2_w1.log" > /dev/console

alive_check()
{
    # $1 = exact argv[0] token; excludes self($$) and parent($PPID)
    role="$1"; hit=0
    for c in /proc/[0-9]*/cmdline; do
        pid=${c#/proc/}; pid=${pid%/cmdline}
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        IFS= read -r argv0 < "$c" 2>/dev/null || continue
        [ "$argv0" = "$role" ] && hit=$((hit+1))
    done
    echo $hit
}

b "heartbeat every 10s (uptime | MemAvail | vsurv4 | scanary)"
i=0
while :; do
    i=$((i+1))
    up=$(cut -d. -f1 /proc/uptime)
    ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    echo "[hb $i] uptime=${up}s MemAvail=${ma}kB vsurv4=$(alive_check /vsurv4) scanary=$(alive_check /scanary) date=$(date 2>/dev/null)" > /dev/console
    sleep 10
done
