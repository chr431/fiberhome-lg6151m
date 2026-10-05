#!/bin/sh
# fw_apply.sh v1.1 -- 端口映射/DMZ/禁网/厂商面纵深封禁 持久层安装器 (幂等)
#   被 rc_netfh.sh 开机调用 + api.sh 在配置变更时 source 调用
# v1.1 (ROADMAP P0): WAN 面纵深封禁 -- iotagtd NDMP(18996-18998)/TR-069 连接请求
#   (30005)/filink CoAP(5683)/telnet(23) 即使对应守护被裁/未启, 规则也常备。
#   不依赖"进程不在"这一假设; 若未来任一守护意外复活, WAN 侧仍不可达。
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
    # WAN 面纵深封禁 (deny 优先于任何后续 accept; 双 WAN 面: eth0 家宽 + ccmni 蜂窝)
    iptables -N V3WANGUARD 2>/dev/null
    iptables -F V3WANGUARD
    for P in 22 23 5683 30005 18996 18997 18998; do   # v1.3: +22(dropbear绑0.0.0.0, 管理面限LAN)
        iptables -A V3WANGUARD -p tcp --dport $P -j DROP
        iptables -A V3WANGUARD -p udp --dport $P -j DROP
    done
    for IF in eth0 ccmni+; do
        iptables -C INPUT -i $IF -j V3WANGUARD 2>/dev/null || \
            iptables -I INPUT -i $IF -j V3WANGUARD
    done
    return 0
}

# 直接执行时安装一次 (开机路径)
case "$1" in
    apply|"") fw_apply ;;
esac
