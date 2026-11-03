#!/bin/sh
# lab_uwhook_run.sh -- uwhook real run: hot canaries + hook window = [min(top)-0x8000, max(top))
# usage: lab_uwhook_run.sh <tag> <minutes>
EXP=/data/repro/exp
BIN=/data/repro/vsurv4
KO=/data/repro/uwhook.ko
TAG=$1; MINS=$2
B=$EXP/$TAG
mkdir -p $B
: > $B/pids.txt; : > $B/uwhook.log
printf 'ts\th4_total\teach0_rx\teach1_rx\tuwhook_seen\n' > $B/corr.tsv
echo "=== manifest ===" > $B/manifest.txt
echo "panic_on_oops=$(cat /proc/sys/kernel/panic_on_oops)" >> $B/manifest.txt
echo "ko_md5=$(md5sum $KO)" >> $B/manifest.txt
echo "uptime=$(cat /proc/uptime)" >> $B/manifest.txt
echo "bootid=$(cat /proc/sys/kernel/random/boot_id)" >> $B/manifest.txt
i=0
while [ $i -lt 4 ]; do
  taskset -c $(( 2 + (i % 2) )) $BIN >/dev/null 2>&1 &
  echo $! >> $B/pids.txt
  i=$((i + 1))
done
sleep 5
BEFORE=$(ls /data/repro/h4_*.bin | wc -l)
sleep 25
AFTER=$(ls /data/repro/h4_*.bin | wc -l)
echo "hotness_30s_h4_delta=$((AFTER - BEFORE))" >> $B/manifest.txt
LO=0; HI=0
while read p; do
  ss=$(cut -d" " -f28 /proc/$p/stat 2>/dev/null)
  [ -z "$ss" ] && continue
  l=$(( ss - 0x8000 ))
  [ $LO -eq 0 ] && LO=$l
  [ $l -lt $LO ] && LO=$l
  [ $ss -gt $HI ] && HI=$ss
  echo "pid=$p startstack=$ss" >> $B/manifest.txt
done < $B/pids.txt
echo "window_lo=$(printf '0x%x' $LO) window_hi=$(printf '0x%x' $HI)" >> $B/manifest.txt
insmod $KO lo=$LO hi=$HI
echo "insmod_rc=$?" >> $B/manifest.txt
dmesg | tail -3 >> $B/manifest.txt
m=0
while [ $m -lt $MINS ]; do
  echo "--- t=$m min $(date +%s) ---" >> $B/uwhook.log
  cat /proc/uwhook >> $B/uwhook.log 2>&1
  SEEN=$(sed -n 's/^uwhook .* seen=\([0-9]*\) hit=\([0-9]*\).*/\1\/\2/p' /proc/uwhook)
  echo "$(date +%s)	$(ls /data/repro/h4_*.bin | wc -l)	$(awk -v n=eth0 '{gsub(":"," ")} $1==n{print $3}' /proc/net/dev)	$(awk -v n=eth1 '{gsub(":"," ")} $1==n{print $3}' /proc/net/dev)	$SEEN" >> $B/corr.tsv
  sleep 60
  m=$((m + 1))
done
cat /proc/uwhook > $B/uwhook_final.txt 2>&1
rmmod uwhook
echo "rmmod_rc=$?" >> $B/manifest.txt
dmesg | tail -3 >> $B/manifest.txt
for p in $(cat $B/pids.txt); do
  [ "$(readlink /proc/$p/exe 2>/dev/null)" = "$BIN" ] && kill -9 $p 2>/dev/null
done
echo DONE > $B/state
