#!/bin/sh
# netup -- zero-conf ethernet for the LG6151M lab kernel (V2, F3).
# mtk_eth_soc (CONFIG_NET_MEDIATEK_SOC=y) is built into the kernel; if eth*
# ports enumerated, bring each up with a deterministic APIPA-style address:
#   eth0 -> 169.254.9.1/16, eth1 -> 169.254.9.2/16, ...
# (mnemonic: management octet matches the v4.x LAN 192.168.9.1).  This is the
# layer-2/3 fallback channel for emergency file transfer -- busybox tftp and
# httpd applets are present in this initramfs.  No DHCP, nothing is
# transmitted until you actually start a server.  Ports are symmetric and the
# PHY attaches a few seconds after ifup (drill pipeline precedent).
[ -d /sys/class/net ] || mount -t sysfs sysfs /sys 2>/dev/null
n=1
found=0
for d in /sys/class/net/eth*; do
    [ -e "$d" ] || continue
    found=1
    ifc=${d#/sys/class/net/}
    addr=169.254.9.$n
    ip link set dev "$ifc" up 2>/dev/null || ifconfig "$ifc" up
    sleep 2
    ip addr add "$addr/16" dev "$ifc" 2>/dev/null || ifconfig "$ifc" "$addr" netmask 255.255.0.0
    echo "netup: $ifc -> $addr/16 carrier=$(cat "$d/carrier" 2>/dev/null || echo '?') state=$(cat "$d/operstate" 2>/dev/null || echo '?')"
    n=$((n+1))
done
if [ "$found" = "0" ]; then
    echo "netup: no eth* interface enumerated (mtk_eth_soc probe failed or DTS mismatch)"
    exit 1
fi
echo "netup: PC side -- set any 169.254.x.y/16 on the linked port; busybox tftp/httpd available here"
