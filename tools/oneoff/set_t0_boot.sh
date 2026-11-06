#!/bin/sh
bt=$(tail -1 /data/stealth/boot.log 2>/dev/null | cut -d' ' -f1)
[ -n "$bt" ] || bt=$(date +%s)
echo "$bt T0_UP_p6s_boot" > /data/stealth/T0
cat /data/stealth/T0
