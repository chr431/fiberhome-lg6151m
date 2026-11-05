#!/bin/sh
# ud1_e4.sh -- U-D1/E4: pin the victim thread to one CPU and sample /proc/softirqs.
# Usage: ud1_e4.sh <cpu> [seconds]
CPU=${1:-0}
DUR=${2:-600}
cd /data/repro || exit 1
LOG=ud1_e4_cpu${CPU}.log
ORM=ud1_e4_cpu${CPU}_orch.log
rm -f "$LOG" "$ORM" /tmp/e4_sq_${CPU}.series
echo "E4_START cpu=$CPU date=$(date +%s)" >> "$ORM"
cat /proc/softirqs > /tmp/e4_sq_${CPU}.before
(
  i=0
  while [ $i -lt 40 ]; do
    cat /proc/softirqs >> /tmp/e4_sq_${CPU}.series
    sleep 30
    i=$((i+1))
  done
) &
SP=$!
./scanary_ro_v24 --victim main --cpu "$CPU" --depth-list 0x1000 --cycle 0 \
  --duration "$DUR" --selftest 1 --ctx 100 --ctxbytes 2048 \
  --log /data/repro/$LOG >/dev/null 2>&1
RC=$?
kill $SP 2>/dev/null
cat /proc/softirqs > /tmp/e4_sq_${CPU}.after
echo "E4_END cpu=$CPU date=$(date +%s) rc=$RC" >> "$ORM"
VREAL=$(grep -cE "^EV [0-9]+ HIT_APPEAR .*inj=0" "$LOG" 2>/dev/null)
echo "E4_SUM cpu=$CPU real=$VREAL" >> "$ORM"
grep -E "AFFINITY|EXIT reason=" "$LOG" | tail -3 >> "$ORM"
