#!/bin/sh
# rc.extend.sh v1.5 -- slot-aware dispatcher (shared /data between v2/v3)
# v1.4 SUBTRACTION mandate (2026-10-03): slot-B (v2) is the MINIMAL fallback --
#   stock firmware + pure access layer, zero contention with FH daemons.
#   b-branch reduced to v2_access.sh only. wan_policy2/v3_fix/hnat/healthdog
#   moved to slot-a (v3) where the sharing mission lives.
# v1.5: flag-gated one-shot capture launch (capture_ubus.sh) BEFORE slot case
#   -- must precede FH's mobilenetwork dial to record the stock datacall blob.
grep -q healthdog /proc/modules 2>/dev/null || true
[ -f /data/gw/DO_UBUS_CAP ] && nohup sh /data/gw/capture_ubus.sh >/dev/null 2>&1 &
slot=$(cat /proc/cmdline | tr ' ' '\n' | sed -n 's/^bootslot=//p')
case "$slot" in
  b) # v2: access layer ONLY (serial/SSH/DHCP/firewall-22 + logging)
     logger -t rc.extend "slot=b (v2 minimal): v2_access only"
     nohup sh /data/gw/v2_access.sh >/dev/null 2>&1 &
     ;;
  *) # v3: full stack (forensics, flight rc19, TTL/hnat are v3 duties)
     logger -t rc.extend "slot=$slot: v3 rc19.sh"
     # v1.6: route A -- FH modem-stack environment parallel to our layer
     # (mobilenetwork dials; rc19 skips rmmod+dial_5g via MODE.fh gate)
     [ -f /data/gw/MODE.fh ] && nohup sh /data/gw/rc_netfh.sh >/tmp/netfh.out 2>&1 &
     insmod /data/gw/healthdog.ko forensic=1 armed=0 2>/dev/null
     nohup sh /data/gw/rc19.sh >/tmp/rc19.log 2>&1 &
     # healthdog stack + RCU-stall panic
     echo 1 > /proc/sys/kernel/panic_on_rcu_stall 2>/dev/null
     [ -e /proc/healthdog ] || insmod /data/gw/healthdog.ko 2>/dev/null
     pgrep -f healthdog.sh >/dev/null || nohup /data/gw/healthdog.sh >/dev/null 2>&1 &
     ;;
esac
