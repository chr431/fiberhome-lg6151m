#!/bin/sh
# T1: map 8 stack pages per canary via patrace (read-only)
D=/data/repro/t1
TAG=$1
OUT=$D/stackpa_$TAG.txt
: > $OUT
echo "# ts=$(date +%s) up=$(cut -d' ' -f1 /proc/uptime) tag=$TAG" >> $OUT
for pid in $(cat $D/canary_pids); do
  [ -d /proc/$pid ] || continue
  st=$(awk '{print $28}' /proc/$pid/stat 2>/dev/null)
  [ -z "$st" ] && continue
  echo "PID $pid start_stack=$st" >> $OUT
  k=1
  while [ $k -le 8 ]; do
    va=$(printf '0x%x' $(( st - k*4096 )))
    echo "$pid $va" > /proc/patrace
    cat /proc/patrace >> $OUT
    k=$((k+1))
  done
done
echo DONE >> $OUT
