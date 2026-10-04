#!/bin/sh
# Boot Babysitter v2: /tmp on this firmware is NOT tmpfs (fstab has no tmpfs
# entry) so /tmp/boot.done persists across reboots and disarms us — v2 only
# honors the marker when it is fresh (written this boot).
# Started from /etc/preinit BEFORE procd/rcS. Independent of procd phases.
# Log to /dev/console (JP1 serial) + /tmp/babysit.log.

LOG=/tmp/babysit.log
DONE=/tmp/boot.done
T1=180    # seconds before surgery (kill hung rcS subtree)
T2=360    # seconds before nuke (flip bootctrl to other slot + hard reset)

bb_log() { echo "babysit: $*" >> $LOG; echo "babysit: $*" > /dev/console 2>/dev/null; }

bb_log "armed pid=$$ t1=$T1 t2=$T2"

# --- parachute: always-on serial getty (independent of procd respawn) ---
if [ ! -f /tmp/babysit.getty ] && ! pidof getty >/dev/null 2>&1; then
    touch /tmp/babysit.getty
    /sbin/getty -L ttyS0 921600 vt100 >/dev/console 2>&1 &
    bb_log "console parachute: getty on ttyS0"
fi

ticks=0
acted1=0
acted2=0
while :; do
    sleep 5
    ticks=$((ticks + 1))
    if [ -f $DONE ]; then
        if [ $ticks -le 6 ]; then
            # legit marker is written by rcS at boot end (>60s); one visible in
            # the first ~30s of this boot persisted from a previous boot
            bb_log "stale boot.done (el=${el}s) - removing, staying armed"
            rm -f $DONE
        else
            bb_log "boot.done present (el=${el}s), exiting"; exit 0
        fi
    fi
    el=$((ticks * 5))

    # --- stage 1: surgery — kill the hung rcS subtree so procd can proceed ---
    if [ $el -ge $T1 ] && [ $acted1 -eq 0 ]; then
        acted1=1
        bb_log "T1 reached (${el}s) — FORENSIC DUMP then surgery"
        echo t > /proc/sysrq-trigger 2>/dev/null
        echo w > /proc/sysrq-trigger 2>/dev/null
        bb_log "forensic sysrq-t/w dumped"
        for p in /proc/[0-9]*/stat; do
            pid=${p%/stat}; pid=${pid#/proc/}
            [ "$pid" = "$$" ] && continue
            name=$(awk '{print $2}' $p 2>/dev/null)
            case "$name" in
                "(mipc_wan_cli)"|"(rcS)")
                    wchan=$(cat /proc/$pid/wchan 2>/dev/null)
                    bb_log "killing $pid $name wchan=$wchan"
                    kill -9 $pid 2>/dev/null ;;
            esac
        done
    fi

    # --- stage 2: nuke — flip bootctrl to the OTHER slot + hard reset ---
    if [ $el -ge $T2 ] && [ $acted2 -eq 0 ]; then
        acted2=1
        bb_log "T2 reached (${el}s) — NUKE: flipping bootctrl to slot B + hard reset"
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
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
        echo b > /proc/sysrq-trigger 2>/dev/null
        # fallback if sysrq dead
        reboot -f 2>/dev/null
        bb_log "nuke fallback failed — check manually"
    fi
done
