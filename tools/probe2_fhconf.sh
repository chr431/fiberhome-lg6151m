#!/bin/sh
# Probe #2 (no re-flash!): neuter the FH daemon army by emptying the runtime
# process_start_list that sysmgr reads. rcS still runs complete (sysmgr starts,
# finds nothing to spawn, mipc_wan_cli L122 still gets its modem daemon --
# WAIT: mobilenetwork is IN the list, so keep it and the minimum modem chain).
#
# Design: comment out ONLY the app-layer daemons; keep modem-critical ones:
#   KEEP:   mobilenetwork        (modem manager, mipc_wan_cli depends on it)
#   KEEP:   cfgmgr, logmgr, eventmgr  (config/log infra, cheap, may be needed
#                                      by mobilenetwork)
#   DROP:   lancc wancc protocolmgr wifimgr secmgr iotagtd link_detection
#           onu_igmpv3 trafficmgr adaptmgr sip sipjudge fanjudge peripheral
#           adbjudge web customer trafficmgr process_check
#
# Run ON THE RUNNING v2 SYSTEM. Reversible: restore from backup + reboot.

BK=/fhconf/process_start_list.v2bak
[ -f "$BK" ] || cp /fhconf/process_start_list "$BK"

awk -F',' '
BEGIN { OFS="," }
{
    keep = 1
    name = $1
    if (name ~ /^(lancc|wancc|protocolmgr|wifimgr|secmgr|iotagtd|link_detection|onu_igmpv3|trafficmgr|adaptmgr|sip|sipjudge|fanjudge|peripheral|adbjudge|customer|process_check)$/) keep = 0
    if (name ~ /^web$/) keep = 0
    if (keep) print
    else print "#probe2:" $0
}' "$BK" > /fhconf/process_start_list

echo "=== new process_start_list:"
grep -v "^#" /fhconf/process_start_list | cut -d, -f1 | tr '\n' ' '
echo
echo "=== dropped:"
grep "^#probe2" /fhconf/process_start_list | cut -d, -f1 | tr '\n' ' '
echo
echo "revert: cp $BK /fhconf/process_start_list && reboot"
