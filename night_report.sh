#!/bin/sh
# night report: failover timeline + auth timeline + current state
echo "===== wan_policy timeline ====="
strings /tmp/wan_policy.log 2>/dev/null | tail -20
echo "===== current state ====="
ip rule | grep 192.168.8 || echo "RULE ABSENT (LAN on 5G)"
cat /sys/class/net/eth1/carrier
ping -c 2 -W 2 -I eth1 223.5.5.5 2>&1 | tail -1
ping -6 -c 2 -W 3 -I eth1 240c::6666 2>&1 | tail -1
echo "===== 5G usage since boot ====="
grep ccmni2 /proc/net/dev | awk '{printf "RX %.2f GB  TX %.2f GB
", $2/1073741824, $10/1073741824}'
