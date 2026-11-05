#!/bin/sh
# ud1_ue1.sh -- U-E1 main window: pulse victim only.  The operator insmods
# fxhook_v6 with the printed stack/top/pid (text patch stays explicit).
# Usage: ud1_ue1.sh [seconds]
DUR=${1:-1200}
cd /data/repro || exit 1
rm -f ue1_victim.log ue1_orch.log
echo "UE1_START date=$(date +%s) up=$(cut -d. -f1 /proc/uptime)" >> ue1_orch.log
./scanary_ro_v24 --victim main --pulse 1000,1000 \
  --depth-list 0x1000 --cycle 0 --duration "$DUR" --selftest 1 \
  --ctx 100 --ctxbytes 2048 --log /data/repro/ue1_victim.log >/dev/null 2>&1 &
VP=$!
i=0
while [ $i -lt 60 ]; do
    grep -q "START" ue1_victim.log 2>/dev/null && break
    sleep 1; i=$((i+1))
done
STACK=$(sed -n 's/.*stack=\(0x[0-9a-f]*\).*/\1/p' ue1_victim.log | head -1)
TOP=$(sed -n 's/.*top=\(0x[0-9a-f]*\).*/\1/p' ue1_victim.log | head -1)
echo "UE1_VICTIM pid=$VP stack=$STACK top=$TOP" >> ue1_orch.log
echo "UE1_CMDS insmod /data/repro/fxhook_v6.ko lo=$STACK hi=$TOP vpid=$VP site=0xffffffc008126740 patchfn=0xffffffc008122394" >> ue1_orch.log
wait $VP
echo "UE1_END date=$(date +%s) rc=$?" >> ue1_orch.log
grep -E "EXIT reason=" ue1_victim.log | tail -1 >> ue1_orch.log
