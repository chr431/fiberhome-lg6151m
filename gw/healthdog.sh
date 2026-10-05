#!/bin/sh
# healthdog.sh — userspace half of healthdog (kernel: healthdog.c)
# HEALTHY = loopback answers AND (LAN PC OR uplink answers). If the loop
# itself stalls (D-storm), heartbeats stop naturally -> kernel resets.
# Opt-in per session: touch /data/gw/healthdog.armed
LOG=/tmp/healthdog.log
# slot-aware: v2 (bootslot=b) always armed — it is the safety slot; v3 only
# with explicit marker (5G may be absent there during bring-up)
if ! grep -q "bootslot=b" /proc/cmdline 2>/dev/null; then
    [ -e /data/gw/healthdog.armed ] || { echo "$(date) v3 + marker absent, disarmed" >> $LOG 2>/dev/null; exit 0; }
fi
[ -e /proc/healthdog ] || { echo "$(date) module not loaded" >> $LOG; exit 1; }
echo arm > /proc/healthdog
echo "$(date) armed pid=$$" >> $LOG
hbs=0
while :; do
    lo=0; ext=0
    ping -c1 -W2 127.0.0.1 >/dev/null 2>&1 && lo=1
    ping -c1 -W2 192.168.9.101 >/dev/null 2>&1 && ext=1
    ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 && ext=1
    if [ $lo -eq 1 ] && [ $ext -eq 1 ]; then
        echo hb > /proc/healthdog 2>/dev/null || exit 0
        hbs=$((hbs+1))
        [ $((hbs % 60)) -eq 0 ] && echo "$(date) $hbs heartbeats ok" >> $LOG
    else
        echo "$(date) HEALTH FAIL hb=$hbs lo=$lo ext=$ext" >> $LOG
    fi
    sleep 10
done
