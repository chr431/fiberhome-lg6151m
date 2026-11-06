#!/bin/sh
# uq_soak.sh -- 20-minute soak targeting the mounted p7 gw static busybox (U-Q)
# usage: uq_soak.sh <seconds> <worker-id>
DUR=${1:-1200}
W=${2:-1}
B=/data/gw/bin/busybox
M=/tmp/zz_uq_missing_$W
LOG=/data/stealth/stab/logs/uq_soak_$W.log
end=$(( $(date +%s) + DUR ))
n=0; sig=0; err=0
echo "UQ_SOAK_START w=$W t=$(date +%s) dur=$DUR bin=$(md5sum $B | cut -c1-8)" > "$LOG"
while [ "$(date +%s)" -lt "$end" ]; do
  case $((n % 12)) in
    0) "$B" ls -l "$M" >/dev/null 2>&1 ;;
    1) "$B" cat "$M" >/dev/null 2>&1 ;;
    2) "$B" tar -cf /tmp/zz_uq_$W.t "$M" >/dev/null 2>&1 ;;
    3) "$B" sh -c 'i=0; while [ $i -lt 50 ]; do i=$((i+1)); done; echo $i' >/dev/null 2>&1 ;;
    4) "$B" awk 'BEGIN{printf "%.3f %f %f %.2f\n",3.14159,1.5,2.5,9.99}' >/dev/null 2>&1 ;;
    5) "$B" printf '%f %f %f %f %d %s\n' 1 2 3 4 5 x >/dev/null 2>&1 ;;
    6) "$B" grep -q T0 /data/stealth/T0 >/dev/null 2>&1 ;;
    7) "$B" sed -n '1p' /data/stealth/T0 >/dev/null 2>&1 ;;
    8) "$B" sh -c 'echo $((6*7))' >/dev/null 2>&1 ;;
    9) "$B" true >/dev/null 2>&1 ;;
    10) "$B" awk -F'\t' '$2=="SEV1"{print $1; exit}' /data/gw/logs/incidents.tsv >/dev/null 2>&1 ;;
    11) "$B" sh -c 'exit 3' >/dev/null 2>&1 ;;
  esac
  rc=$?
  [ "$rc" -ge 128 ] && sig=$((sig+1))
  [ "$rc" -ne 0 ] && [ "$rc" -lt 128 ] && err=$((err+1))
  n=$((n+1))
  if [ $((n % 60)) -eq 0 ]; then
    echo "UQ_SOAK w=$W t=$(date +%s) n=$n sig=$sig err=$err" >> "$LOG"
  fi
  sleep 1
done
echo "UQ_SOAK_END w=$W t=$(date +%s) n=$n sig=$sig err=$err" >> "$LOG"
