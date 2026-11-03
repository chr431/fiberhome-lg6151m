#!/bin/sh
# T1: start 4 vsurv5 canaries, record pids
D=/data/repro/t1
mkdir -p $D
for d in /proc/[0-9]*; do
  c=$(cat $d/comm 2>/dev/null)
  case "$c" in vsurv5|scanary*) kill -9 ${d#/proc/} 2>/dev/null;; esac
done
sleep 1
rm -f $D/v5_*.log $D/canary_pids
: > $D/canary_pids
i=0
while [ "$i" -lt 4 ]; do
  /data/repro/vsurv5 > $D/v5_$i.log 2>&1 &
  i=$((i+1))
done
sleep 2
for d in /proc/[0-9]*; do
  c=$(cat $d/comm 2>/dev/null)
  if [ "$c" = "vsurv5" ]; then echo ${d#/proc/} >> $D/canary_pids; fi
done
echo "start ts=$(date +%s) up=$(cut -d' ' -f1 /proc/uptime) pids=$(tr '\n' ',' < $D/canary_pids)"
cat $D/v5_*.log
