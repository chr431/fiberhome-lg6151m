#!/bin/sh
# soak_p6s.sh -- 20-minute production busybox (p6s) soak, 2 workers (U-P)
# usage: soak_p6s.sh <seconds> <worker-id>
DUR=${1:-1200}
W=${2:-1}
B=/bin/busybox
M=/tmp/zz_soak_missing_$W
LOG=/data/stealth/stab/logs/soak_$W.log
end=$(( $(date +%s) + DUR ))
n=0; sig=0
echo "SOAK_START w=$W t=$(date +%s) dur=$DUR bin=$(md5sum $B | cut -c1-8)" > "$LOG"
while [ "$(date +%s)" -lt "$end" ]; do
  case $((n % 10)) in
    0) "$B" ls -l "$M" >/dev/null 2>&1 ;;
    1) "$B" cat "$M" >/dev/null 2>&1 ;;
    2) "$B" tar -cf /tmp/zz_soak_$W.t "$M" >/dev/null 2>&1 ;;
    3) "$B" ls -l /proc/1/exe /proc/999998/exe /proc/999999/exe >/dev/null 2>&1 ;;
    4) "$B" sh -c 'printf "%s %d\n" a 1' >/dev/null 2>&1 ;;
    5) "$B" awk 'BEGIN{printf "%.3f\n", 3.14159}' >/dev/null 2>&1 ;;
    6) "$B" printf '%d %s %f\n' 7 xyz 2.5 >/dev/null 2>&1 ;;
    7) "$B" grep -q T0 /data/stealth/T0 >/dev/null 2>&1 ;;
    8) "$B" true ;;
    9) "$B" sh -c 'exit 3' >/dev/null 2>&1 ;;
  esac
  rc=$?
  [ "$rc" -ge 128 ] && sig=$((sig+1))
  n=$((n+1))
  if [ $((n % 60)) -eq 0 ]; then
    echo "SOAK w=$W t=$(date +%s) n=$n sig=$sig" >> "$LOG"
  fi
  sleep 1
done
echo "SOAK_END w=$W t=$(date +%s) n=$n sig=$sig" >> "$LOG"
