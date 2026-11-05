#!/bin/sh
# ud1_e3b.sh -- U-D1/E3b: deep frame + busy hold (NO nanosleep), vcall still runs.
# Separates "writer needs nanosleep" from "writer needs the call/stack or interrupts".
# Usage: ud1_e3b.sh [seconds]
DUR=${1:-600}
cd /data/repro || exit 1
rm -f ud1_e3b_busy.log ud1_e3b_orch.log
echo "E3B_START date=$(date +%s) up=$(cut -d. -f1 /proc/uptime)" >> ud1_e3b_orch.log
./scanary_ro_v24 --victim main --depth-list 0x1000 --cycle 0 \
  --hold-us 10000 --hold-mode busy --duration "$DUR" \
  --selftest 1 --ctx 200 --ctxbytes 2048 --log /data/repro/ud1_e3b_busy.log \
  >/dev/null 2>&1
RC=$?
echo "E3B_END date=$(date +%s) rc=$RC" >> ud1_e3b_orch.log
VREAL=$(grep -cE "^EV [0-9]+ HIT_APPEAR .*inj=0" ud1_e3b_busy.log 2>/dev/null)
echo "E3B_SUM real=$VREAL" >> ud1_e3b_orch.log
grep -E "EXIT reason=" ud1_e3b_busy.log | tail -1 >> ud1_e3b_orch.log
