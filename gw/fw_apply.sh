#!/bin/sh
# fw_apply.sh v1.0 -- 端口映射/DMZ/禁网 持久层安装器 (幂等)
#   被 rc_netfh.sh 开机调用 + api.sh 在配置变更时 source 调用
GWDATA=/data/gw

fw_apply() {
    iptables -t nat -F V3FWD 2>/dev/null
    iptables -t nat -X V3FWD 2>/dev/null
    iptables -t nat -N V3FWD
    iptables -t nat -C PREROUTING -i eth0 -j V3FWD 2>/dev/null || \
        iptables -t nat -A PREROUTING -i eth0 -j V3FWD
    if [ -r $GWDATA/forwards.conf ]; then
        grep -v '^#' $GWDATA/forwards.conf | while IFS='|' read proto eport dip dport; do
            [ -n "$proto$dport$eport$dip" ] || continue
            iptables -t nat -A V3FWD -p $proto --dport $eport -j DNAT --to-destination $dip:$dport
            iptables -C FORWARD -d $dip -p $proto --dport $dport -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -d $dip -p $proto --dport $dport -j ACCEPT
        done
    fi
    if [ -r $GWDATA/dmz.conf ]; then
        . $GWDATA/dmz.conf
        if [ "$DMZ_EN" = "1" ] && [ -n "$DMZ_IP" ]; then
            iptables -t nat -A V3FWD -j DNAT --to-destination $DMZ_IP
            iptables -C FORWARD -d $DMZ_IP -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -d $DMZ_IP -j ACCEPT
        fi
    fi
    if [ -r $GWDATA/block.conf ]; then
        for M in $(grep -oE '^[0-9a-fA-F:]{17}$' $GWDATA/block.conf); do
            iptables -C FORWARD -m mac --mac-source $M -j DROP 2>/dev/null || \
                iptables -I FORWARD -m mac --mac-source $M -j DROP
        done
    fi
    return 0
}

# 直接执行时安装一次 (开机路径)
case "$1" in
    apply|"") fw_apply ;;
esac
