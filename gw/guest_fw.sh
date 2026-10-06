#!/bin/sh
# guest_fw.sh v1.6 — 访客网络隔离 (强制开启, 无开关)
#
# v1.6 (审计P0): 删除 GUEST_ISOLATE 开关 — 访客可达管理面/内网曾是开关关闭态,
#   属实弹高危面(访客口令一旦泄露=内网全权)。兼容需求(不支持MLO的设备等)改由
#   主 WiFi "终端频段锁定"(band_pins.conf) 承接, 访客一律仅出网。
# v1.3(历史): 曾有 GUEST_ISOLATE=0 普通内网SSID兼容模式, 已移除。
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
LAN_NET=$(ip route show dev br-lan 2>/dev/null | awk 'NR==1{print $1}')
[ -z "$LAN_NET" ] && LAN_NET=192.168.9.0/24
GW_IP=$(ip -o -4 addr show br-lan 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)   # v1.5: INPUT链--ip-dst锚点
[ -z "$GW_IP" ] && GW_IP=192.168.9.1

log() { echo "guest_fw: $*"; }

clean_iface() {  # 摘除一个 iface 的全部隔离规则(含 v1.0-v1.3 时代遗留)
    _if=$1; _ch=${PRE}_${_if}
    ebtables -t broute -D BROUTING -i $_if -j $_ch 2>/dev/null
    ebtables -t broute -F $_ch 2>/dev/null
    ebtables -t broute -X $_ch 2>/dev/null
    ebtables -D FORWARD -o $_if -j $_ch 2>/dev/null
    ebtables -D FORWARD -i $_if -j $_ch 2>/dev/null
    ebtables -D INPUT -i $_if -j ${_ch}_I 2>/dev/null      # v1.4 本机交付链
    ebtables -F ${_ch}_I 2>/dev/null; ebtables -X ${_ch}_I 2>/dev/null
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
    # 隔离四层:
    #   1) ebtables filter FORWARD 双向 DROP = L2 隔离(访客帧只能本地交付, 不达其他端口)
    #   2) ebtables filter INPUT  = 网关本机交付面只留 DHCP/DNS/ICMP(v1.4 — 实弹:
    #      桥接本地交付进 iptables INPUT 时 indev=br-lan, v1.2 的 -i <if> 跳转永不
    #      命中, 访客能开 192.168.9.1; ebtables INPUT 按桥口匹配, 是正确层次)
    #   3) iptables INPUT -i <if> = 同语义兜底(万一 indev 形态变化)
    #   4) iptables FORWARD -i <if> = 路由面拒绝访客->LAN网段, 出网放行(同主WiFi)
    ebtables -N $_ch 2>/dev/null; ebtables -F $_ch
    ebtables -I FORWARD 1 -i $_if -j $_ch
    ebtables -I FORWARD 2 -o $_if -j $_ch
    ebtables -A $_ch -j DROP
    # --- ebtables filter INPUT: 网关本机交付面(桥口精确匹配, 不依赖br_netfilter) ---
    # v1.5: 只约束 目标IP=网关自身 的流量(--ip-dst 匹配后白名单/拒绝)。
    # v1.4 实弹教训: 访客出网帧的下一跳=网关MAC, 同样走本地交付进 INPUT 链 —
    # 无差别 DROP 把待路由转发的流量一起杀了(guest 全断网)。非网关目标的 IPv4
    # 不设规则(RETURN→放行, 交给 iptables FORWARD 管 LAN 网段)。ARP 放行。
    ebtables -N ${_ch}_I 2>/dev/null; ebtables -F ${_ch}_I
    ebtables -I INPUT 1 -i $_if -j ${_ch}_I
    ebtables -A ${_ch}_I -p 0x0800 --ip-dst $GW_IP --ip-proto 17 --ip-dport 67:68 -j ACCEPT
    ebtables -A ${_ch}_I -p 0x0800 --ip-dst $GW_IP --ip-proto 17 --ip-dport 53 -j ACCEPT
    ebtables -A ${_ch}_I -p 0x0800 --ip-dst $GW_IP --ip-proto 6  --ip-dport 53 -j ACCEPT
    ebtables -A ${_ch}_I -p 0x0800 --ip-dst $GW_IP --ip-proto 1 -j ACCEPT
    ebtables -A ${_ch}_I -p 0x0800 --ip-dst $GW_IP -j DROP
    ebtables -A ${_ch}_I -p 0x86DD -j DROP
    # --- iptables INPUT: 同语义兜底(indev=访客口形态时生效) ---
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
            _if=${_ch#$PRE_}; _if=${_if%_I}   # v1.4: 剥本机交付链后缀再探测
            [ -d /sys/class/net/$_if ] || clean_iface $_if
        done
    done
    # v1.6: 隔离无条件启用(开关已删) — settings.conf 残留 GUEST_ISOLATE 键被忽略
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
