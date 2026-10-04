#!/bin/sh
# capture_ubus.sh v1.0 -- one-shot stock-dial capture (runs on slot-B boot).
# Launched by rc.extend v1.5 ONLY when /data/gw/DO_UBUS_CAP flag exists.
# Captures: full ubus traffic (ubus monitor sees method CALLS incl. the
# ql-netd datacall blob stock's mobilenetwork issues) + ccmni counter samples.
# Self-removes the flag; bounded lifetime (5 min) so it never lingers.
FLAG=/data/gw/DO_UBUS_CAP
LOG=/tmp/ubus_mon.log
SMPL=/tmp/ccmni_samples.log
[ -f $FLAG ] || exit 0
rm -f $FLAG $LOG $SMPL
echo "capture start $(date -u +%FT%TZ)" > $LOG

# 1. wait for ubusd the moment it exists (before any client registers)
i=0
while [ $i -lt 60 ] && [ -z "$(pidof ubusd)" ]; do sleep 1; i=$((i+1)); done
[ -z "$(pidof ubusd)" ] && { echo "no ubusd in 60s" >> $LOG; exit 1; }
ubus monitor >> $LOG 2>&1 &
MON=$!
echo "monitor pid=$MON $(date -u +%T)" >> $LOG

# 2. ccmni sampling, 3s interval, 100 samples (~5 min)
i=0
while [ $i -lt 100 ]; do
    grep ccmni /proc/net/dev >> $SMPL 2>/dev/null
    echo "-- $(date -u +%T)" >> $SMPL
    sleep 3
    i=$((i+1))
done
kill $MON 2>/dev/null
echo "capture done $(date -u +%FT%TZ)" >> $LOG
