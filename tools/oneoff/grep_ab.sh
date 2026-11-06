#!/bin/sh
# grep_ab.sh -- reproduce vendor grep crash on /tmp/mtketh_esw_cnt (U-P)
N=${1:-20}
P=/bin/busybox
S=/data/stealth/stock/busybox
F=/tmp/mtketh_esw_cnt
if [ ! -r "$F" ]; then echo "NO_INPUT $F"; exit 0; fi
echo "input_size=$(wc -c < "$F") mtime=$(ls -l "$F" | awk '{print $6,$7,$8}')"
head -c 200 "$F" | od -An -tx1 | head -3
i=0; pok=0; psig=0; sok=0; ssig=0
while [ "$i" -lt "$N" ]; do
  cat "$F" | "$P" grep PSE_OQ_STA3 >/dev/null 2>&1; rc=$?
  if [ "$rc" -ge 128 ]; then psig=$((psig+1)); else pok=$((pok+1)); fi
  cat "$F" | "$S" grep PSE_OQ_STA3 >/dev/null 2>&1; rc=$?
  if [ "$rc" -ge 128 ]; then ssig=$((ssig+1)); else sok=$((sok+1)); fi
  i=$((i+1))
done
echo "GREP_AB N=$N P[ok=$pok sig=$psig] S[ok=$sok sig=$ssig]"
