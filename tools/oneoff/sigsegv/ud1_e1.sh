#!/bin/sh
# ud1_e1.sh -- U-D1/E1: victim on the main stack + inert decoy at the SAME numeric VA.
# Usage: ud1_e1.sh [seconds]
DUR=${1:-600}
cd /data/repro || exit 1
rm -f ud1_e1_victim.log ud1_e1_decoy.log ud1_e1_orch.log
echo "E1_START date=$(date +%s) up=$(cut -d. -f1 /proc/uptime)" >> ud1_e1_orch.log

./scanary_ro_v22 --victim main --depth-list 0x1000 --cycle 0 --duration "$DUR" \
  --selftest 1 --ctx 200 --ctxbytes 2048 --log /data/repro/ud1_e1_victim.log \
  >/dev/null 2>&1 &
VP=$!

i=0
while [ $i -lt 50 ]; do
    if grep -q "START" ud1_e1_victim.log 2>/dev/null; then break; fi
    sleep 1; i=$((i+1))
done
BASE=$(sed -n 's/.*stack=\(0x[0-9a-f]*\).*/\1/p' ud1_e1_victim.log | head -1)
TOP=$(sed -n 's/.*top=\(0x[0-9a-f]*\).*/\1/p' ud1_e1_victim.log | head -1)
echo "E1_VICTIM pid=$VP base=$BASE top=$TOP" >> ud1_e1_orch.log
if [ -z "$BASE" ]; then
    echo "E1_NO_START" >> ud1_e1_orch.log
    kill $VP 2>/dev/null
    exit 2
fi

n=0
rc=99
while [ $n -lt 5 ]; do
    ./va_decoy "$BASE" 0x200000 "$DUR" /data/repro/ud1_e1_decoy.log >/dev/null 2>&1
    rc=$?
    echo "E1_DECOY try=$n rc=$rc" >> ud1_e1_orch.log
    [ $rc -ne 4 ] && break
    n=$((n+1)); sleep 1
done

wait $VP
VRC=$?
echo "E1_END date=$(date +%s) victim_rc=$VRC decoy_rc=$rc" >> ud1_e1_orch.log
VREAL=$(grep -cE "^EV [0-9]+ HIT_APPEAR .*inj=0" ud1_e1_victim.log 2>/dev/null)
DREAL=$(grep -c "DECOY_HIT" ud1_e1_decoy.log 2>/dev/null)
echo "E1_SUM victim_real=$VREAL decoy_real=$DREAL" >> ud1_e1_orch.log
grep -E "EXIT reason=" ud1_e1_victim.log | tail -1 >> ud1_e1_orch.log
grep -E "DECOY_EXIT" ud1_e1_decoy.log | tail -1 >> ud1_e1_orch.log
