#!/bin/sh
# /init for the LG6151M lab (instrument) kernel initramfs -- V3 asset build.
# V3 = V2 fixes (kept verbatim) + reliability/safety + V5 reserves:
#   F1  cpio ships /dev/console (c 5:1 0600) + /dev/null (c 1:3 0666)
#       -> rdinit=/bin/sh works (v1 panicked "Attempted to kill init").
#   F2  interactive shell after the scanary window (setsid+cttyhack,
#       respawn loop); heartbeat kept (10s window / 60s hb-slow after).
#   F3  /bin/netup zero-conf 169.254/16 on eth*.
#   A1  THERMAL: MTK_LVTS_THERMAL built in; heartbeat carries max zone
#       temp; warn >= lab_thermal_warn (default 85000 milli-C) and
#       protective poweroff >= lab_thermal_off (default 95000; 0 disables).
#       Rationale: the 2026-11-01 lab session had no thermal control and
#       ended in a manual power cut.
#   A2  WATCHDOG: MEDIATEK_WATCHDOG built in; /init feeds /dev/watchdog
#       every 10s (fd held open). Disable with lab_wdt=off.
#   A3  TRY_A auto-clear: misc[2061] zeroed at boot (readback verified),
#       immunizing against the >3-tries rollback to slot B. Disable with
#       lab_trya=off.
#   A4  BOOT CARD: one-page capability summary at boot.
#   B   V5 reserves (built, NOT enabled): mt76/mt7996e wifi modules in
#       /modules (insmod manually; firmware NOT bundled); /bin/romount
#       read-only partition mount helper; /bin/kjump kexec helper.
# Alive checks follow project discipline: exact argv token scan of
# /proc/*/cmdline, excluding self and parent (no pgrep -f substring traps).

export PATH=/bin:/sbin:/usr/bin:/usr/sbin
BUILD_ID="labkernel-v3.1 2026-11-03 base=6.18.44 v2-fixes + TRY_A p1-offset fix + window-end log channel"

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

cmd_val() # cmd_val <key> -> value of <key>=... on the kernel cmdline
{
    sed 's/ /\n/g' /proc/cmdline 2>/dev/null | grep "^$1=" | head -1 | cut -d= -f2
}

# ---------------- A3: TRY_A auto-clear (before anything else) ----------------
trya_clear()
{
    case " $(cat /proc/cmdline 2>/dev/null) " in
        *" lab_trya=off "*) echo "TRYA: autoclear disabled by lab_trya=off" > /dev/console; return;;
    esac
    # v3.1 FIX: the A/B control block lives at p1 offset 2060 (p1 starts at
    # sector 64), NOT at raw /dev/mmcblk0 offset 2060.  v3 wrote raw offset
    # 2061 (a GPT entry byte) -- never do that.  Use the misc partition.
    P1=/dev/mmcblk0p1
    [ -b "$P1" ] || mknod "$P1" b 179 1 2>/dev/null || true
    if [ ! -b "$P1" ]; then echo "TRYA: no $P1 -- SKIP (state unknown)" > /dev/console; return; fi
    before=$(dd if="$P1" bs=1 skip=2060 count=10 2>/dev/null | hexdump -e '10/1 "%02x "')
    echo "TRYA: p1[2060..2069] before: $before" > /dev/console
    cur=$(dd if="$P1" bs=1 skip=2061 count=1 2>/dev/null | hexdump -e '1/1 "%02x"')
    if [ -z "$cur" ]; then echo "TRYA: p1[2061] read failed -- SKIP (state unknown)" > /dev/console; return; fi
    if [ "$cur" = "00" ]; then
        echo "TRYA: p1[2061]=0x00 already clear (TRY_A=0)" > /dev/console; return
    fi
    dd if=/dev/zero of="$P1" bs=1 seek=2061 count=1 2>/dev/null
    now=$(dd if="$P1" bs=1 skip=2061 count=1 2>/dev/null | hexdump -e '1/1 "%02x"')
    after=$(dd if="$P1" bs=1 skip=2060 count=10 2>/dev/null | hexdump -e '10/1 "%02x "')
    if [ "$now" = "00" ]; then
        echo "TRYA_CLEARED: p1[2061] 0x${cur} -> 0x00 (slot-B rollback trap immunized) after: $after" > /dev/console
    else
        echo "TRYA_CLEAR_FAILED: readback 0x${now} -- clear manually: dd if=/dev/mmcblk0p1 bs=1 seek=2061 count=1 (zero)" > /dev/console
    fi
}

# ---------------- A2: watchdog feeder ----------------
wdt_feed()
{
    case " $(cat /proc/cmdline 2>/dev/null) " in
        *" lab_wdt=off "*) echo "WDT: feeder disabled by lab_wdt=off" > /dev/console; return;;
    esac
    if [ ! -c /dev/watchdog ]; then
        echo "WDT: /dev/watchdog missing (mtk_wdt probe?) -- no feeding" > /dev/console; return
    fi
    (
        exec 3<>/dev/watchdog || exit 1
        echo "WDT: feeder armed (/dev/watchdog, 10s tick)" > /dev/console
        while :; do
            printf 'w' >&3 2>/dev/null || { echo "WDT: write failed -- feeder stopped" > /dev/console; break; }
            sleep 10
        done
    ) &
}

# ---------------- A1: thermal helpers ----------------
tz_max() # echo max zone temp in milli-C, empty if no readable zone
{
    m=""
    for z in /sys/class/thermal/thermal_zone[0-9]*; do
        [ -r "$z/temp" ] || continue
        t=$(cat "$z/temp" 2>/dev/null) || continue
        case "$t" in ''|*[!0-9-]*) continue;; esac
        if [ -z "$m" ] || [ "$t" -gt "$m" ]; then m=$t; fi
    done
    echo "$m"
}

thermal_guard() # $1 = tmax (milli-C); warn + protective poweroff
{
    t="$1"
    [ -n "$t" ] || return
    if [ "$t" -ge "$TH_OFF" ] && [ "$TH_OFF" -gt 0 ]; then
        echo "THERMAL_SHUTDOWN: tmax=${t}mC >= lab_thermal_off=${TH_OFF}mC -- sync+poweroff in 5s (lab_thermal_off=0 to disable)" > /dev/console
        sync
        sleep 5
        poweroff -f
        sleep 10
        reboot -f   # fallback if poweroff unsupported on this platform
    fi
    if [ "$t" -ge "$TH_WARN" ]; then
        echo "THERMAL_ALARM: tmax=${t}mC >= lab_thermal_warn=${TH_WARN}mC" > /dev/console
    fi
}

TH_WARN=$(cmd_val lab_thermal_warn); TH_WARN=${TH_WARN:-85000}
TH_OFF=$(cmd_val lab_thermal_off);  TH_OFF=${TH_OFF:-95000}
echo "thermal limits: warn=${TH_WARN}mC off=${TH_OFF}mC (cmdline-overridable)" > /dev/console

b "LG6151M LAB KERNEL V3.1 -- initramfs userspace reached (D28 revalidation build)"
uname -a > /dev/console
echo "$BUILD_ID" > /dev/console

# ---------------- A4: boot card ----------------
b "BOOT CARD -- capability summary"
echo " console : /dev/console $([ -c /dev/console ] && echo PRESENT || echo MISSING) (rdinit=/bin/sh supported)" > /dev/console
echo " shell   : interactive after scanary window; exit respawns; rdinit=/bin/sh for bare shell" > /dev/console
neth=$(ls /sys/class/net/eth* 2>/dev/null | wc -l)
echo " net     : eth* enumerated=${neth} ; /bin/netup -> 169.254.9.n/16 zero-conf" > /dev/console
ntz=$(ls -d /sys/class/thermal/thermal_zone[0-9]* 2>/dev/null | wc -l)
echo " thermal : zones=${ntz} (lvts) warn=${TH_WARN}mC off=${TH_OFF}mC ; heartbeat carries tmax" > /dev/console
echo " watchdog: $([ -c /dev/watchdog ] && echo '/dev/watchdog PRESENT, fed 10s' || echo 'MISSING')" > /dev/console
for f in /sys/kernel/tracing/kprobe_events /sys/kernel/tracing/uprobe_events \
         /sys/kernel/debug /proc/self/pagemap /proc/self/clear_refs \
         /proc/kcore /proc/config.gz; do
    if [ -e "$f" ]; then echo " obs     : PRESENT $f" > /dev/console
    else echo " obs     : MISSING $f" > /dev/console; fi
done
nmod=$(ls /modules/*.ko 2>/dev/null | wc -l)
echo " modules : ${nmod} .ko in /modules (wifi reserve: cfg80211->mac80211->mt76->mt76-connac-lib->mt7996e; firmware NOT bundled, not loaded)" > /dev/console
echo " kexec   : kernel support built in; /bin/kjump (userland kexec NOT bundled -- kjump reports)" > /dev/console
echo " helpers : /bin/netup /bin/romount /bin/kjump /bin/scanary_report" > /dev/console

trya_clear
wdt_feed

b "netup (zero-conf ethernet, emergency transfer channel)"
/bin/netup > /dev/console 2>&1 &

b "instrumentation self-check"
echo "kallsyms entries: $(wc -l < /proc/kallsyms)" > /dev/console
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null
echo 0 > /proc/sys/kernel/perf_event_paranoid 2>/dev/null
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
if [ -e /proc/config.gz ]; then
    cnt=$(zcat /proc/config.gz | grep -c -E "^CONFIG_(KPROBES|KPROBE_EVENTS|DYNAMIC_FTRACE|FUNCTION_TRACER|PERF_EVENTS|HW_BREAKPOINT|USERFAULTFD|PROC_PAGE_MONITOR|KEXEC|KEXEC_FILE|KGDB|KGDB_SERIAL_CONSOLE|KALLSYMS_ALL|UPROBE_EVENTS|PAGE_OWNER|DEBUG_FS)=y")
    echo "instrument config symbols (=y): $cnt/16 expected" > /dev/console
    zcat /proc/config.gz | grep -E "^CONFIG_(KPROBES|KPROBE_EVENTS|DYNAMIC_FTRACE|FUNCTION_TRACER|PERF_EVENTS|HW_BREAKPOINT|USERFAULTFD|PROC_PAGE_MONITOR|KEXEC_FILE|KGDB|KGDB_SERIAL_CONSOLE|KALLSYMS_ALL|UPROBE_EVENTS|PAGE_OWNER|DEBUG_FS)=y" > /dev/console
fi
echo "thermal zones now:" > /dev/console
for z in /sys/class/thermal/thermal_zone[0-9]*; do
    [ -r "$z/temp" ] || continue
    echo "  $(basename "$z") type=$(cat "$z/type" 2>/dev/null) temp=$(cat "$z/temp" 2>/dev/null)mC" > /dev/console
done

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
    # v3.1 FIX: read /proc/<pid>/stat comm instead of cmdline (cmdline has NULs;
    # a whole-line read never equals the argv[0] token -> false negatives).
    # $1 = exact comm token; excludes self($$) and parent($PPID).
    role="$1"; hit=0
    for c in /proc/[0-9]*/stat; do
        pid=${c#/proc/}; pid=${pid%/stat}
        [ "$pid" = "$$" ] && continue
        [ "$pid" = "$PPID" ] && continue
        s=$(cat "$c" 2>/dev/null) || continue
        comm=${s#*(}
        comm=${comm%%)*}
        [ "$comm" = "$role" ] && hit=$((hit+1))
    done
    echo $hit
}

b "heartbeat every 10s during the window; interactive shell starts when it ends"
i=0; miss=0
while :; do
    i=$((i+1))
    up=$(cut -d. -f1 /proc/uptime)
    ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
    sc=$(alive_check scanary)
    tm=$(tz_max)
    echo "[hb $i] uptime=${up}s MemAvail=${ma}kB tmax=${tm:-na}mC vsurv4=$(alive_check vsurv4) scanary=${sc} date=$(date 2>/dev/null)" > /dev/console
    thermal_guard "$tm"
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

b "WINDOW-1 END -- full scanary log to console (C-187 channel fix)"
echo "W1_LOG_PATH=/data/repro/scanary_c2_w1.log" > /dev/console
echo "W1_LOG_BYTES=$(wc -c < /data/repro/scanary_c2_w1.log 2>/dev/null)" > /dev/console
echo "W1_LOG_LINES=$(wc -l < /data/repro/scanary_c2_w1.log 2>/dev/null)" > /dev/console
/bin/busybox md5sum /data/repro/scanary_c2_w1.log > /dev/console 2>&1
cat /data/repro/scanary_c2_w1.log > /dev/console 2>&1
echo "D28_W1_LOG_END" > /dev/console

b "observation window complete -- interactive shell on this console"
echo "type commands; exit (or Ctrl-D) respawns the shell; heartbeat continues at 60s as [hb-slow]" > /dev/console
echo "evidence: /bin/scanary_report /data/repro/scanary_c2_w1.log ; dumps in /data/repro (RAM)" > /dev/console
echo "emergency transfer: /bin/netup (169.254/16), busybox tftp/httpd applets present" > /dev/console
( j=0
  while :; do
      sleep 60
      j=$((j+1))
      up=$(cut -d. -f1 /proc/uptime)
      tm=$(tz_max)
      echo "[hb-slow $j] uptime=${up}s tmax=${tm:-na}mC shell=available date=$(date 2>/dev/null)" > /dev/console
      thermal_guard "$tm"
  done
) &
while :; do
    if [ -x /bin/cttyhack ] && [ -x /bin/setsid ]; then
        setsid cttyhack sh -c 'exec sh </dev/console >/dev/console 2>&1'
    else
        sh -c 'exec sh </dev/console >/dev/console 2>&1'
    fi
    echo "shell exited -- respawning in 3s" > /dev/console
    sleep 3
done
