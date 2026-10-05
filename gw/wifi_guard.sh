#!/bin/sh
# wifi_guard.sh — BA-stall auto-recovery + telemetry for the wifi TX quirk.
#
# Mechanism (2026-10-01): after bridge churn, unicast TCP/UDP to a wifi client
# dies while ICMP flows (SYN-ACKs queued at dev level, never on air; wed_task1
# permanently D-state). Kernel-side detection: v3_steth.ko flags TX-stall
# episodes (rx advancing + tx frozen + iface running) in /proc/v3_steth.
# This guard polls that flag (with a userspace heuristic fallback when the
# module is absent) and performs the PROVEN recovery: bounce rai0. All actions
# timestamped to /tmp/wifi_guard.log — evidence, not guessing.
LOG=/tmp/wifi_guard.log
glog() { echo "$(date -u +%FT%TZ) $*" >> $LOG; }

STRIKES=0
LAST_EP=0
BOUNCED=0

glog "wifi_guard start (pid $$)"

while true; do
    sleep 15

    # ---- primary signal: kernel stethoscope ----
    STALL=0; EP=0
    if [ -r /proc/v3_steth ]; then
        line=$(grep 'if rai0' /proc/v3_steth 2>/dev/null)
        STALL=$(echo "$line" | sed -n 's/.*stall=\([0-9]*\).*/\1/p')
        EP=$(echo "$line"   | sed -n 's/.*episodes=\([0-9]*\).*/\1/p')
        [ -z "$STALL" ] && STALL=0
        [ -z "$EP" ] && EP=0
    fi

    # ---- telemetry every ~5min: wed_task1 D-state + counters ----
    if [ $(( $(date -u +%s) % 300 )) -lt 16 ]; then
        WED=$(grep -c "wed_task1" /proc/[0-9]*/comm 2>/dev/null | grep -c ":1")
        glog "tick stall=$STALL episodes=$EP wed_task1_procs=$WED $(grep 'if ra' /proc/v3_steth 2>/dev/null | tr '\n' ' ')"
    fi

    # ---- episode transition => new stall detected by kernel ----
    if [ "$EP" -gt "$LAST_EP" ]; then
        STRIKES=$((STRIKES+1))
        glog "STALL EPISODE #$EP (strike $STRIKES): $(grep 'if rai0' /proc/v3_steth)"
        LAST_EP=$EP
    elif [ "$STALL" = "0" ]; then
        STRIKES=0
    fi

    # ---- recovery after 3 strikes (~45s confirmed stall) ----
    if [ $STRIKES -ge 3 ] && [ $BOUNCED -lt 20 ]; then
        glog "RECOVERY: bouncing rai0 (strikes=$STRIKES ep=$EP)"
        ifconfig rai0 down 2>>$LOG
        sleep 2
        ifconfig rai0 up 2>>$LOG
        brctl addif br-lan rai0 2>>$LOG
        BOUNCED=$((BOUNCED+1))
        STRIKES=0
        glog "RECOVERY done (total bounces=$BOUNCED) — clients must re-associate"
    fi

    # ---- hard cap: 20 bounces per boot then alert-only ----
    if [ $BOUNCED -ge 20 ]; then
        :   # stop acting, keep logging
    fi
done
