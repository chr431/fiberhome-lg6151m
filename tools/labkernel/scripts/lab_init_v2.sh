#!/bin/sh
# /init for the LG6151M lab (instrument) kernel initramfs -- V2 repack.
# V2 fixes over the C2/v1 session kernel (both seen live 2026-11-01/02):
#   F1  cpio now ships /dev/console (c 5:1 mode 0600) + /dev/null (c 1:3 0666).
#       v1: cpio had no console node -> kernel printed "Warning: unable to
#       open an initial console." and rdinit=/bin/sh (PID1, no fd 0/1/2)
#       exited instantly -> panic "Attempted to kill init"
#       (console-s4-20261102-0046.log line 4055).  With the node in the
#       archive the kernel itself opens the console for PID1 before exec.
#   F2  after the pre-registered scanary window-1 (invocation byte-identical
#       to the C2 arm, for data comparability) this init hands the console to
#       an interactive shell (setsid+cttyhack, respawn on exit) instead of
#       the v1 heartbeat-only dead loop.  rdinit=/bin/sh also works now (F1).
#   F3  /bin/netup: zero-conf 169.254/16 on every enumerated eth* port
#       (CONFIG_NET_MEDIATEK_SOC=y built in) for emergency file transfer.
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

b "LG6151M LAB KERNEL V2 -- initramfs userspace reached (+scanary, +console/shell/netup)"
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

b "v2 self-check (F1 console node / F2 shell path / F3 netup)"
for f in /dev/console /dev/null /bin/sh /bin/netup /bin/setsid /bin/cttyhack; do
    if [ -e "$f" ]; then echo "PRESENT: $f" > /dev/console
    else echo "MISSING: $f" > /dev/console; fi
done
if /bin/busybox --list 2>/dev/null | grep -qx cttyhack && /bin/busybox --list 2>/dev/null | grep -qx setsid; then
    CTTYHACK_OK=1
    echo "applets: cttyhack+setsid OK -> interactive shell with job control" > /dev/console
else
    CTTYHACK_OK=0
    echo "applets: cttyhack/setsid MISSING -> plain sh fallback (no job control)" > /dev/console
fi
echo "rdinit=/bin/sh also supported (bare shell, no mounts; 'exec /init' re-enters this flow)" > /dev/console

b "netup (zero-conf ethernet, emergency transfer channel)"
/bin/netup > /dev/console 2>&1 &

b "starting canary vsurv4 (SIGSEGV survivor, dumps -> /data/repro)"
/vsurv4 > /dev/console 2>&1 &

b "starting scanary window-1 (C2 ablation arm: 1800s, victim=main, decoy 8M)"
# Pre-registered invocation -- same shape as the vendor-kernel baseline arm
# (--victim main: writer historically targets start_stack-K, PROTOCOL s7.1.3;
#  --hold-us 10000: observation mode, full-speed rewrite would mask records).
/scanary --victim main --duration 1800 --epoch-sec 0 --probe-sec 120 \
          --hold-us 10000 --period-us 5000 --stride 16 --writeback safe \
          --log /data/repro/scanary_c2_w1.log > /dev/console 2>&1 &
WIN=1800
win_end=$(( $(cut -d. -f1 /proc/uptime) + WIN ))
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

b "heartbeat every 10s during the window; interactive shell starts when it ends"
i=0; miss=0
while :; do
    i=$((i+1))
    up=$(cut -d. -f1 /proc/uptime)
    ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    sc=$(alive_check /scanary)
    echo "[hb $i] uptime=${up}s MemAvail=${ma}kB vsurv4=$(alive_check /vsurv4) scanary=${sc} date=$(date 2>/dev/null)" > /dev/console
    [ "$up" -ge "$win_end" ] && break
    if [ "$sc" = "0" ]; then
        miss=$((miss+1))
        if [ "$miss" -ge 3 ]; then
            echo "[hb $i] scanary_exited_early -- observation window truncated (log is final), starting shell" > /dev/console
            break
        fi
    else
        miss=0
    fi
    sleep 10
done

b "observation window complete -- interactive shell on this console"
echo "type commands; exit (or Ctrl-D) respawns the shell; heartbeat continues at 60s as [hb-slow]" > /dev/console
echo "evidence: /bin/scanary_report /data/repro/scanary_c2_w1.log ; dumps in /data/repro (RAM)" > /dev/console
echo "emergency transfer: /bin/netup (169.254/16), busybox tftp/httpd applets present" > /dev/console
echo "FIRST ACTION on first boot after p25 flash: clear TRY_A (misc[2061]): mknod /dev/mmcblk0 b 179 0; dd if=/dev/zero of=/dev/mmcblk0 bs=1 seek=2061 count=1" > /dev/console
( j=0
  while :; do
      sleep 60
      j=$((j+1))
      up=$(cut -d. -f1 /proc/uptime)
      echo "[hb-slow $j] uptime=${up}s shell=available date=$(date 2>/dev/null)" > /dev/console
  done
) &
while :; do
    if [ "$CTTYHACK_OK" = "1" ]; then
        setsid cttyhack sh -c 'exec sh </dev/console >/dev/console 2>&1'
    else
        sh -c 'exec sh </dev/console >/dev/console 2>&1'
    fi
    echo "shell exited -- respawning in 3s" > /dev/console
    sleep 3
done
