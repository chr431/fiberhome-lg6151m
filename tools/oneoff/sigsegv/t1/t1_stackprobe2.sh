#!/bin/sh
# T1: map the page-aligned canary stack pages (start_stack & ~0xfff) - k*4096, k=0..7
D=/data/repro/t1
TAG=$1
OUT=$D/stackpa2_$TAG.txt
: > $OUT
echo "# ts=$(date +%s) up=$(cut -d' ' -f1 /proc/uptime) tag=$TAG" >> $OUT
for pid in $(cat $D/canary_pids); do
  [ -d /proc/$pid ] || continue
  st=$(awk '{print $28}' /proc/$pid/stat 2>/dev/null)
  [ -z "$st" ] && continue
  base=$(( st & ~4095 ))
  echo "PID $pid start_stack=$st base=$base" >> $OUT
  k=0
  while [ $k -le 7 ]; do
    va=$(printf '0x%x' $(( base - k*4096 )))
    echo "$pid $va" > /proc/patrace
    cat /proc/patrace >> $OUT
    k=$((k+1))
  done
done
echo DONE >> $OUT
