#!/bin/sh
# fw_apply.sh v1.5 -- 端口映射/DMZ/禁网/厂商面纵深封禁 持久层安装器 (幂等)
#   被 rc_netfh.sh 开机调用 + api.sh 在配置变更时 source 调用
# v1.5 (P1): v4 WAN 面升级 default-deny(icmp/DHCP客户端/established 放行, 其余
#   DROP; 原 v1.1-v1.3 的 7 端口黑名单语义被整体包含) + V4WANGUARDF 挡 WAN->LAN
#   新建转发(原 FORWARD policy ACCEPT)。
# v1.4 (P0): IPv6 同构 — V6WANGUARD/V6WANGUARDF (ICMPv6/DHCPv6/established 放行,
#   其余 DROP; 实测曾堵死 WAN 侧 v6 直连 :22)。
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
    # WAN 面纵深封禁 (v1.5/P1: v4 升级 default-deny — 原 7 端口黑名单被整体包含;
    #   放行 icmp/DHCP客户端应答/established, 其余 INPUT 一律 DROP。FORWARD 同构
    #   V4WANGUARDF: 挡 WAN->LAN 新建(含同网段主机加静态路由穿透内网的路径)。
    #   挂载点: INPUT 用 -I(顶部); FORWARD 用 -A(尾部) — DNAT 放行(forwards/DMZ)
    #   经 -I 落在链首, 必须先于本守卫命中, 否则端口映射会被误杀。)
    iptables -N V3WANGUARD 2>/dev/null
    iptables -F V3WANGUARD
    iptables -A V3WANGUARD -p icmp -j ACCEPT
    iptables -A V3WANGUARD -p udp --sport 67 --dport 68 -j ACCEPT
    iptables -A V3WANGUARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A V3WANGUARD -j DROP
    iptables -N V4WANGUARDF 2>/dev/null
    iptables -F V4WANGUARDF
    iptables -A V4WANGUARDF -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A V4WANGUARDF -j DROP
    for IF in eth0 ccmni+; do
        iptables -C INPUT -i $IF -j V3WANGUARD 2>/dev/null || \
            iptables -I INPUT -i $IF -j V3WANGUARD
        iptables -C FORWARD -i $IF -j V4WANGUARDF 2>/dev/null || \
            iptables -A FORWARD -i $IF -j V4WANGUARDF
    done
    # v1.4: IPv6 WAN 面默认拒绝 (INPUT: 管理面; FORWARD: WAN->LAN 新建)
    ip6tables -N V6WANGUARD 2>/dev/null
    ip6tables -F V6WANGUARD
    ip6tables -A V6WANGUARD -p ipv6-icmp -j ACCEPT
    ip6tables -A V6WANGUARD -p udp --sport 547 --dport 546 -j ACCEPT
    ip6tables -A V6WANGUARD -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A V6WANGUARD -j DROP
    ip6tables -N V6WANGUARDF 2>/dev/null
    ip6tables -F V6WANGUARDF
    ip6tables -A V6WANGUARDF -p ipv6-icmp -j ACCEPT
    ip6tables -A V6WANGUARDF -m state --state RELATED,ESTABLISHED -j ACCEPT
    ip6tables -A V6WANGUARDF -j DROP
    for IF in eth0 ccmni+; do
        ip6tables -C INPUT -i $IF -j V6WANGUARD 2>/dev/null || \
            ip6tables -I INPUT -i $IF -j V6WANGUARD
        ip6tables -C FORWARD -i $IF -j V6WANGUARDF 2>/dev/null || \
            ip6tables -I FORWARD -i $IF -j V6WANGUARDF
    done
    return 0
}

# 直接执行时安装一次 (开机路径)
case "$1" in
    apply|"") fw_apply ;;
esac
