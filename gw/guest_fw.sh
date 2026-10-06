#!/bin/sh
# guest_fw.sh v1.3 — 访客网络隔离 (原厂 wifiguest.sh 语义, 桥接路径实现; 可开关)
#
# v1.3: 隔离开关 GUEST_ISOLATE(默认1) — settings.conf 可关(=0): 访客作为普通
#   内网 SSID(用户场景: 给不支持 MLO 的设备一个兼容 SSID), 仅保留入桥(wifi_up
#   负责 DHCP 可用), 不施加任何隔离规则。关->开/开->关 都幂等。
# v1.2 架构: broute DROP 强制L3路由在本内核+多WAN mark管线 pre-conntrack 蒸发,
#   改与主WiFi同路径(全桥接->网关MAC本地交付->路由出网)。隔离三层:
#   ebtables filter FORWARD 双向 DROP (L2: 访客帧不达任何其他桥口)
#   iptables INPUT  -i <if> (网关管理面只留 DHCP/DNS/ICMP)
#   iptables FORWARD -i <if> (路由面: ->LAN网段拒, ->WAN 放行同主WiFi)
#   开启时语义"仅出网"; IPv6 RA 被 ebtables -o DROP 封(访客纯v4)。
#
# 用法: guest_fw.sh sync   (幂等: 按设置重建/清除规则; 访客 iface 消失则清理)
# 状态: /tmp/guest_fw.state 与内核规则同生命周期(重启均清零, 天然一致)

PRE=WIFI_GUEST
STATE=/tmp/guest_fw.state
GWDATA=$(cd "$(dirname "$0")" && pwd)
GUEST_ISOLATE=1
[ -r "$GWDATA/defaults.conf" ] && . "$GWDATA/defaults.conf"
[ -r "$GWDATA/settings.conf" ] && . "$GWDATA/settings.conf"
case "$GUEST_ISOLATE" in 0|1) ;; *) GUEST_ISOLATE=1 ;; esac
LAN_NET=$(ip route show dev br-lan 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$LAN_NET" ] && LAN_NET=192.168.9.0/24

log() { echo "guest_fw: $*"; }

clean_iface() {  # 摘除一个 iface 的全部隔离规则(含 v1.0/v1.1 broute 时代遗留)
    _if=$1; _ch=${PRE}_${_if}
    ebtables -t broute -D BROUTING -i $_if -j $_ch 2>/dev/null
    ebtables -t broute -F $_ch 2>/dev/null
    ebtables -t broute -X $_ch 2>/dev/null
    ebtables -D FORWARD -o $_if -j $_ch 2>/dev/null
    ebtables -D FORWARD -i $_if -j $_ch 2>/dev/null
    ebtables -F $_ch 2>/dev/null
    ebtables -X $_ch 2>/dev/null
    # iptables: 跳转规则摘除(规则文本精确匹配); F链一并清
    iptables  -D INPUT   -i $_if -j $_ch   2>/dev/null
    iptables  -D FORWARD -i $_if -j ${_ch}_F  2>/dev/null
    iptables  -D INPUT   -m physdev --physdev-in $_if -j $_ch   2>/dev/null
    iptables  -D FORWARD -m physdev --physdev-in $_if -j ${_ch}_F  2>/dev/null
    iptables  -F ${_ch}_F 2>/dev/null; iptables  -X ${_ch}_F 2>/dev/null
    iptables  -F $_ch 2>/dev/null; iptables  -X $_ch 2>/dev/null
    ip6tables -D INPUT   -i $_if -j $_ch   2>/dev/null
    ip6tables -F $_ch 2>/dev/null; ip6tables -X $_ch 2>/dev/null
}

apply_iface() {  # 为一个现存访客 iface 施加隔离 (v1.2 架构: 纯桥接路径)
    _if=$1; _ch=${PRE}_${_if}
    # v1.2 重设计: 移除 broute DROP(强制L3路由) — 实证该路径在本内核+多WAN mark
    # 管线下 pre-conntrack 蒸发(出网SYN有ebtables计数但零conntrack条目/零iptables
    # FORWARD命中/零IP层丢弃计数), 访客因此"连上无网"。改走与主WiFi客户端完全相同
    # 的路径: 全桥接 -> 网关MAC本地交付 -> 路由出网(主WiFi已实证可用)。
    # 隔离三件套:
    #   1) ebtables filter FORWARD 双向 DROP = L2 隔离(访客帧只能本地交付, 不达其他端口;
    #      网关自身回包走 OUTPUT 链不受影响)
    #   2) iptables INPUT -i <if> = 网关管理面只留 DHCP/DNS/ICMP
    #   3) iptables FORWARD -i <if> = 路由面拒绝访客->LAN网段, 出网放行(同主WiFi NAT/mark)
    ebtables -N $_ch 2>/dev/null; ebtables -F $_ch
    ebtables -I FORWARD 1 -i $_if -j $_ch
    ebtables -I FORWARD 2 -o $_if -j $_ch
    ebtables -A $_ch -j DROP
    # --- iptables INPUT: 网关本机服务面(DHCP/DNS/ICMP 放行, 拒管理面) ---
    # (br_netfilter=1 下桥接帧的本地投递以此链匹配 indev=访客口 — DHCP 计数实证)
    iptables -N $_ch 2>/dev/null; iptables -F $_ch
    iptables -A $_ch -p udp --dport 67:68 -j ACCEPT
    iptables -A $_ch -p udp --dport 53 -j ACCEPT
    iptables -A $_ch -p tcp --dport 53 -j ACCEPT
    iptables -A $_ch -p icmp -j ACCEPT
    iptables -A $_ch -j DROP
    iptables -I INPUT 1 -i $_if -j $_ch
    # --- iptables FORWARD: 访客路由面(->LAN拒, ->WAN放行走主链mark/NAT) ---
    iptables -N ${_ch}_F 2>/dev/null; iptables -F ${_ch}_F
    iptables -A ${_ch}_F -d $LAN_NET -j DROP
    iptables -A ${_ch}_F -j RETURN
    iptables -I FORWARD 1 -i $_if -j ${_ch}_F
    # --- ip6tables: v6 本机面同语义(桥接RA到访客被ebtables -o DROP封 => 访客纯v4) ---
    if ip6tables -L >/dev/null 2>&1; then
        ip6tables -N $_ch 2>/dev/null; ip6tables -F $_ch
        ip6tables -A $_ch -p udp --dport 546:547 -j ACCEPT
        ip6tables -A $_ch -p udp --dport 53 -j ACCEPT
        ip6tables -A $_ch -p tcp --dport 53 -j ACCEPT
        ip6tables -A $_ch -p ipv6-icmp -j ACCEPT
        ip6tables -A $_ch -j DROP
        ip6tables -I INPUT 1 -i $_if -j $_ch
    fi
    log "applied on $_if (LAN_NET=$LAN_NET, bridged-path isolation)"
}

case "$1" in
sync)
    # 清旧(状态文件记录的 + 残留链名扫描), 再按现存访客 iface 重建
    for _if in $(cat $STATE 2>/dev/null); do clean_iface $_if; done
    for _t in broute filter; do
        for _ch in $(ebtables -t $_t -L 2>/dev/null | awk -v p="^$PRE" '/^Bridge chain:/{gsub(/,/,"",$3); if ($3 ~ p) print $3}'); do
            _if=${_ch#$PRE_}; [ -d /sys/class/net/$_if ] || clean_iface $_if
        done
    done
    # v1.3: 隔离关闭 = 清完即止(访客=普通内网SSID, 仅保留wifi_up的入桥/DHCP)
    if [ "$GUEST_ISOLATE" != 1 ]; then
        : > $STATE
        log "isolation OFF (GUEST_ISOLATE=0) — guest rides plain LAN"
        exit 0
    fi
    : > $STATE.new
    for _if in ra1 rai1; do
        [ -d /sys/class/net/$_if ] || continue
        apply_iface $_if
        echo $_if >> $STATE.new
    done
    mv $STATE.new $STATE
    [ -s $STATE ] || log "no guest iface — all clean"
    ;;
*)
    echo "Usage: $0 sync"; exit 1
    ;;
esac
