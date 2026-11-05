#!/bin/sh
# ud1_e45.sh -- U-D1/E4+E5: victim pinned to one CPU, softirqs sampled, eth0 pcap captured.
# Usage: ud1_e45.sh <cpu> [seconds]
CPU=${1:-2}
DUR=${2:-600}
cd /data/repro || exit 1
LOG=ud1_e45_cpu${CPU}.log
ORM=ud1_e45_cpu${CPU}_orch.log
rm -f "$LOG" "$ORM" ud1_e5.pcap /tmp/e45_sq_series
echo "E45_START cpu=$CPU date=$(date +%s) up=$(cut -d. -f1 /proc/uptime)" >> "$ORM"
cat /proc/softirqs > /tmp/e45_sq_before
tcpdump -i eth0 -nn -s 96 -tt -c 300000 -w /data/repro/ud1_e5.pcap >/dev/null 2>&1 &
TP=$!
(
  i=0
  while [ $i -lt 40 ]; do
    cat /proc/softirqs >> /tmp/e45_sq_series
    sleep 30
    i=$((i+1))
  done
) &
SP=$!
./scanary_ro_v24 --victim main --cpu "$CPU" --depth-list 0x1000 --cycle 0 \
  --duration "$DUR" --selftest 1 --ctx 100 --ctxbytes 2048 \
  --log /data/repro/$LOG >/dev/null 2>&1
RC=$?
kill $TP $SP 2>/dev/null
wait $TP 2>/dev/null
cat /proc/softirqs > /tmp/e45_sq_after
echo "E45_END cpu=$CPU date=$(date +%s) rc=$RC pcap_bytes=$(wc -c < ud1_e5.pcap 2>/dev/null)" >> "$ORM"
echo "E45_SUM cpu=$CPU real=$(grep -cE '^EV [0-9]+ HIT_APPEAR .*inj=0' "$LOG" 2>/dev/null)" >> "$ORM"
grep -E "AFFINITY|EXIT reason=" "$LOG" | tail -3 >> "$ORM"
