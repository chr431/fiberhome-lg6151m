#!/bin/sh
# guest_fw.sh v1.0 — 访客网络隔离 (原厂 wifiguest.sh type=2 配方复刻改造, RP103实证)
#
# 核心原语: ebtables broute DROP = 帧不桥接、改送本机 L3 路由。访客流量因此
# 全部经网关 NAT 出网, 不再二层直达 LAN。放行仅 DHCP(桥接 udhcpd) 与 DNS(53)。
# ARP 照常桥接(网关 MAC 解析必需, 原厂同款)。iptables 层显式拒绝访客到
# LAN 网段与网关管理面(本机 INPUT 仅留 ICMP ping)。
#
# 与原厂差异: 原厂分 type=1(仅锁网关服务)/type=2(仅出网)两类按 ssidindex 下发,
# 由 wifimgr 调用; 本版只实现 type=2 语义(访客=仅出网), 由 wifi_up.sh v1.17 调用。
# IPv6: 与原厂一致, 入向 filter 链封 v6 桥接(含RA) => 访客实为纯v4, ip6tables仅兜底。
#
# 用法: guest_fw.sh sync   (幂等: 重建全部规则; 访客 iface 消失则清理)
# 状态: /tmp/guest_fw.state 与内核规则同生命周期(重启均清零, 天然一致)

PRE=WIFI_GUEST
STATE=/tmp/guest_fw.state
LAN_NET=$(ip route show dev br-lan 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$LAN_NET" ] && LAN_NET=192.168.9.0/24

log() { echo "guest_fw: $*"; }

clean_iface() {  # 摘除一个 iface 的全部隔离规则
    _if=$1; _ch=${PRE}_${_if}
    ebtables -t broute -D BROUTING -i $_if -j $_ch 2>/dev/null
    ebtables -t broute -F $_ch 2>/dev/null
    ebtables -t broute -X $_ch 2>/dev/null
    ebtables -D FORWARD -o $_if -j $_ch 2>/dev/null
    ebtables -F $_ch 2>/dev/null
    ebtables -X $_ch 2>/dev/null
    # iptables: 跳转规则两种 indev 形态都摘(规则文本精确匹配); F链一并清
    iptables  -D INPUT   -i $_if -j $_ch   2>/dev/null
    iptables  -D FORWARD -i $_if -j ${_ch}_F  2>/dev/null
    iptables  -D INPUT   -m physdev --physdev-in $_if -j $_ch   2>/dev/null
    iptables  -D FORWARD -m physdev --physdev-in $_if -j ${_ch}_F  2>/dev/null
    iptables  -F ${_ch}_F 2>/dev/null; iptables  -X ${_ch}_F 2>/dev/null
    iptables  -F $_ch 2>/dev/null; iptables  -X $_ch 2>/dev/null
    ip6tables -D INPUT   -i $_if -j $_ch   2>/dev/null
    ip6tables -F $_ch 2>/dev/null; ip6tables -X $_ch 2>/dev/null
}

apply_iface() {  # 为一个现存访客 iface 施加隔离
    _if=$1; _ch=${PRE}_${_if}
    # --- ebtables broute: 入向(访客->任意) 仅放行 DHCP/DNS(v4)+DHCPv6/ICMPv6, 其余上送L3 ---
    ebtables -t broute -N $_ch 2>/dev/null; ebtables -t broute -F $_ch
    ebtables -t broute -I BROUTING 1 -i $_if -j $_ch
    ebtables -t broute -A $_ch -p 0x0800 --ip-proto 17 --ip-dport 67:68 -j ACCEPT
    ebtables -t broute -A $_ch -p 0x0800 --ip-proto 17 --ip-dport 53 -j ACCEPT
    ebtables -t broute -A $_ch -p 0x0800 --ip-proto 6  --ip-dport 53 -j ACCEPT
    ebtables -t broute -A $_ch -p 0x86DD --ip6-proto 17 --ip6-dport 546:547 -j ACCEPT
    ebtables -t broute -A $_ch -p 0x86DD --ip6-proto 58 -j ACCEPT
    ebtables -t broute -A $_ch -p 0x0800 -j DROP
    ebtables -t broute -A $_ch -p 0x86DD -j DROP
    ebtables -t broute -A $_ch -j RETURN
    # --- ebtables filter: LAN 桥接直达访客的旁路也封(回包走L3不受影响) ---
    ebtables -N $_ch 2>/dev/null; ebtables -F $_ch
    ebtables -I FORWARD 1 -o $_if -j $_ch
    ebtables -A $_ch -p 0x0800 -j DROP
    ebtables -A $_ch -p 0x0806 -j DROP
    ebtables -A $_ch -p 0x86DD -j DROP
    ebtables -A $_ch -j RETURN
    # --- iptables: broute DROP 上送的 L3 流量 ---
    # INPUT: 网关本机只留 ICMP(诊断); DNS/DHCP 不经此路径(已桥接ACCEPT)
    iptables -N $_ch 2>/dev/null; iptables -F $_ch
    iptables -A $_ch -p icmp -j ACCEPT
    iptables -A $_ch -j DROP
    iptables -I INPUT 1 -i $_if -j $_ch
    # FORWARD: 访客出网放行(走默认NAT), 到内网网段拒绝
    iptables -N ${_ch}_F 2>/dev/null; iptables -F ${_ch}_F
    iptables -A ${_ch}_F -d $LAN_NET -j DROP
    iptables -A ${_ch}_F -j RETURN
    iptables -I FORWARD 1 -i $_if -j ${_ch}_F
    # 兼容: broute DROP 后 indev 形态因内核而异, physdev 形态并挂 (不支持则静默跳过)
    iptables -C INPUT -m physdev --physdev-in $_if -j $_ch 2>/dev/null || \
        iptables -I INPUT 2 -m physdev --physdev-in $_if -j $_ch 2>/dev/null
    iptables -C FORWARD -m physdev --physdev-in $_if -j ${_ch}_F 2>/dev/null || \
        iptables -I FORWARD 2 -m physdev --physdev-in $_if -j ${_ch}_F 2>/dev/null
    # --- ip6tables: v6 INPUT 拒绝(访客无RA入向已被filter链封, 此为兜底) ---
    if ip6tables -L >/dev/null 2>&1; then
        ip6tables -N $_ch 2>/dev/null; ip6tables -F $_ch
        ip6tables -A $_ch -p icmpv6 -j ACCEPT
        ip6tables -A $_ch -j DROP
        ip6tables -I INPUT 1 -i $_if -j $_ch
    fi
    log "applied on $_if (LAN_NET=$LAN_NET)"
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
