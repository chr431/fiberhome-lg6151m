#!/bin/sh
# lab_wan.sh <seconds> <url> -- device-initiated WAN download loop (W arm traffic source)
export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib
OUT=/data/repro/exp/wan_run
mkdir -p $OUT
: > $OUT/curl_bytes.txt
S=$(date +%s)
n=0
while :; do
  now=$(date +%s)
  [ $(( now - S )) -ge $1 ] && break
  /fhrom/bin/curl -m 120 -s -o /dev/null -w "%{size_download}\n" "$2" >> $OUT/curl_bytes.txt
  n=$((n + 1))
done
echo "curl_rounds=$n start=$S end=$(date +%s)" >> $OUT/curl_bytes.txt
