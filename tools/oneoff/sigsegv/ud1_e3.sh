#!/bin/sh
# ud1_e3.sh -- U-D1/E3: victim spins with yield only (zero syscalls), scanner keeps scanning.
# Usage: ud1_e3.sh [seconds]
DUR=${1:-600}
cd /data/repro || exit 1
rm -f ud1_e3_spin.log ud1_e3_orch.log
echo "E3_START date=$(date +%s) up=$(cut -d. -f1 /proc/uptime)" >> ud1_e3_orch.log
./scanary_ro_v22 --victim main --depth-list 0x1000 --cycle 0 --spin 1 --duration "$DUR" \
  --selftest 1 --ctx 200 --ctxbytes 2048 --log /data/repro/ud1_e3_spin.log \
  >/dev/null 2>&1
RC=$?
echo "E3_END date=$(date +%s) rc=$RC" >> ud1_e3_orch.log
VREAL=$(grep -cE "^EV [0-9]+ HIT_APPEAR .*inj=0" ud1_e3_spin.log 2>/dev/null)
echo "E3_SUM real=$VREAL" >> ud1_e3_orch.log
grep -E "SPIN_|EXIT reason=" ud1_e3_spin.log | tail -4 >> ud1_e3_orch.log
