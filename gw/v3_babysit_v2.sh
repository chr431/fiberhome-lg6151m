#!/bin/sh
# Boot Babysitter v3.0 -- progress-aware last resort for a boot that never
# proves itself.
#
# v3.0 (2026-10-20 stability P0-2):
#   * /tmp/boot.done is now written by boot_gate.sh only after the critical
#     boot chain is verified; a stale marker from a previous boot is removed
#     unconditionally here (we are the first writer of this boot).
#   * T1 is progress-based: at 240s, only a boot with NO progress for 120s is
#     touched; it dumps tasks and kills the specific hung children (rcS /
#     mipc_wan_cli), never the whole tree.
#   * T2 is 600s (was 360s) and only fires when there is still no progress;
#     with progress continuing it extends in 60s steps to a hard cap of 900s.
#   * every decision goes to /tmp/babysit.log and, once /data is mounted, to
#     /data/gw/logs/boot_babysit.log (the old script only had /tmp, so the
#     evidence died with the reboot it caused).
#
# Started from /etc/preinit BEFORE procd/rcS via /data/rescue/babysit.sh.
# Independent of procd phases.  Log to /dev/console (JP1 serial) + files.

LOG=/tmp/babysit.log
DONE=/tmp/boot.done
PROG=/tmp/boot.progress
T1=240          # first escalation point (only when boot shows no progress)
STALL=120       # "no progress" window before T1 may act
T2=600          # nuke point when still no progress
T2MAX=900       # hard cap even if progress keeps trickling
DLOG=/data/gw/logs/boot_babysit.log

bb_log() {
    echo "babysit: $*" >> $LOG
    echo "babysit: $*" > /dev/console 2>/dev/null
    [ -d /data/gw/logs ] && echo "$(date '+%Y-%m-%d %H:%M:%S') $(cat /proc/uptime | cut -d. -f1) $*" >> $DLOG 2>/dev/null
}
btime() { awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null; }
uptime_s() { cut -d. -f1 /proc/uptime; }

# --- this boot starts here: any existing marker/progress is stale ----------
rm -f $DONE $PROG 2>/dev/null
BT=$(btime)
bb_log "armed v3.0 pid=$$ btime=$BT t1=$T1 stall=$STALL t2=$T2 cap=$T2MAX"

# --- parachute: always-on serial getty (independent of procd respawn) ------
if [ ! -f /tmp/babysit.getty ] && ! pidof getty >/dev/null 2>&1; then
    touch /tmp/babysit.getty
    /sbin/getty -L ttyS0 921600 vt100 >/dev/console 2>&1 &
    bb_log "console parachute: getty on ttyS0"
fi

sig() { # progress signature: marker presence + progress file mtime/size
    _m=0
    [ -f $DONE ] && _m=1
    _p=-
    if [ -f $PROG ]; then
        _p=$(stat -c '%Y:%s' $PROG 2>/dev/null)
        [ -n "$_p" ] || _p=$(wc -c < $PROG 2>/dev/null)
    fi
    echo "$_m|$_p"
}

# v3.0 safety: a box that still answers SSH is recoverable by hand; flipping
# the slot would destroy a working system just because a marker was late.
ssh_alive() {
    pidof dropbear >/dev/null 2>&1 || return 1
    awk '$4=="0A" && substr($2,length($2)-4)==":0016"{f=1} END{exit(f?0:1)}' \
        /proc/net/tcp 2>/dev/null
}

LAST_SIG=$(sig)
LAST_PROGRESS=$(uptime_s)
acted1=0
acted2=0
ticks=0

while :; do
    sleep 5
    ticks=$((ticks + 1))
    el=$(uptime_s)

    if [ -f $DONE ]; then
        bb_log "boot.done present (el=${el}s) — boot gate passed, exiting"
        exit 0
    fi

    NOW_SIG=$(sig)
    if [ "$NOW_SIG" != "$LAST_SIG" ]; then
        LAST_SIG=$NOW_SIG
        LAST_PROGRESS=$el
        bb_log "progress at ${el}s [$(tail -n 1 $PROG 2>/dev/null)]"
    fi
    stall=$((el - LAST_PROGRESS))

    # ---- stage 1: progress-based surgery --------------------------------
    if [ $el -ge $T1 ] && [ $stall -ge $STALL ] && [ $acted1 -eq 0 ]; then
        acted1=1
        bb_log "T1 reached (el=${el}s, no progress for ${stall}s) — FORENSIC DUMP then surgery"
        echo t > /proc/sysrq-trigger 2>/dev/null
        echo w > /proc/sysrq-trigger 2>/dev/null
        bb_log "forensic sysrq-t/w dumped"
        for p in /proc/[0-9]*/stat; do
            pid=${p%/stat}; pid=${pid#/proc/}
            [ "$pid" = "$$" ] && continue
            name=$(awk '{print $2}' $p 2>/dev/null)
            case "$name" in
                "(mipc_wan_cli)"|"(rcS)"|"(dial_5g.sh)"|"(ccmni_up.sh)")
                    wchan=$(cat /proc/$pid/wchan 2>/dev/null)
                    bb_log "killing $pid $name wchan=$wchan"
                    kill -9 $pid 2>/dev/null ;;
            esac
        done
    fi

    # ---- stage 2: progress-aware nuke -----------------------------------
    if [ $acted2 -eq 0 ]; then
        if [ $el -ge $T2 ] && [ $stall -ge 180 ]; then
            acted2=1
        elif [ $el -ge $T2MAX ]; then
            acted2=1
            bb_log "hard cap ${T2MAX}s reached despite progress — nuking"
        fi
    fi
    if [ $acted2 -eq 1 ]; then
        acted2=2
        if ssh_alive; then
            bb_log "NUKE SUPPRESSED: dropbear :22 is listening (el=${el}s stall=${stall}s) — box is reachable, manual repair keeps the slot"
            [ -d /data/gw ] && echo "$(date +%s) btime=$BT nuke_suppressed el=$el stall=$stall" >> /data/gw/boot_nuke.tsv 2>/dev/null
            continue
        fi
        bb_log "NUKE: flipping bootctrl to slot B + hard reset (el=${el}s stall=${stall}s btime=$BT)"
        # A.pri=14 < B.pri=15 (B slot = last known good)
        echo -en '\016\000\001\000\000\017\000\001\002\000' > /tmp/bc.bin 2>/dev/null
        if [ -e /dev/mmcblk0p1 ]; then
            dd if=/tmp/bc.bin of=/dev/mmcblk0p1 bs=1 seek=2060 2>>$LOG
        elif [ -e /mnt/p1 ]; then
            dd if=/tmp/bc.bin of=/mnt/p1 bs=1 seek=2060 2>>$LOG
        else
            mkdir -p /mnt 2>/dev/null
            mount -t tmpfs tmpfs /mnt 2>/dev/null
            mknod /mnt/p1 b 179 1 2>/dev/null
            dd if=/tmp/bc.bin of=/mnt/p1 bs=1 seek=2060 2>>$LOG
        fi
        sync
        [ -d /data/gw ] && echo "$(date +%s) btime=$BT nuke el=$el stall=$stall" >> /data/gw/boot_nuke.tsv 2>/dev/null
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
        echo b > /proc/sysrq-trigger 2>/dev/null
        # fallback if sysrq dead
        reboot -f 2>/dev/null
        bb_log "nuke fallback failed — check manually"
    fi
done
