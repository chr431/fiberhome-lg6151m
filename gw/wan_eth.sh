#!/bin/sh
# wan_eth.sh v1.0 — 有线 WAN(eth0) 接口管理守护 (自 wan_agg v2.34 ensure_lease 拆出, 架构轮)
# 职责(与聚合决策正交; 聚合旁路/仅蜂窝模式下照样要跑):
#   链路拉起 + one-shot udhcpc(静态形态跳过) + to-LAN 护盾 + 家宽备用默认(metric 200)
#   + 表200 默认(v4 经网关 / v6 学 RA) + eth0 NAT/FORWARD 看门狗。
#   全部幂等 level-driven: 每周期只补缺失, 不动存量 —— 谁冲刷都 5s 内自愈。
# 拆分动机(实害修复): udhcpc(-n -q -t3 -T3, 最坏 9s+)原内联在 wan_agg 探活环循里,
#   租约获取期间整个 FSM 停摆(探活/故障转移全停, 侵蚀 25s 硬截止预算); 独立进程后
#   互不阻塞。崩溃隔离: FSM 卡死不再连累租约续订与 NAT 看门狗。
# 单写方纪律(随迁不变): 表200 默认与 eth0 NAT/FORWARD 的写方 = 本守护(原 ensure_lease
#   整体迁入); main 表主默认归 wan_agg.main_primary_apply 独占; 蜂窝探活路由(metric
#   250)与 metric-50 遗留清理同归 wan_agg —— 本脚本不写 main 表默认、不碰蜂窝侧。
# 契约: /tmp/wan.gw = 家宽网关(udhcpc_wan.script 写 / rc19 static 档案写), 本守护与
#   wan_agg 均只读。由 rc19 拉起(先于 wan_agg), watchdog v1.12+ 自愈。
W2_IF=eth0
LAN_NET=192.168.9.0/24
T2=200
GW_FILE=/tmp/wan.gw
UDHCPC_PID=/tmp/udhcpc_wan.pid
UDHCPC_SCRIPT=/data/gw/udhcpc_wan.script
LOG=/tmp/wan_eth.log
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
log "===== wan_eth v1.0 start ====="
while :; do
    # v1.4(原 wan_agg): PHY 只在 ifup 后 attach, 别裸 DOWN
    ip link set $W2_IF up 2>/dev/null
    if [ -z "$(ip -4 addr show $W2_IF 2>/dev/null | grep inet)" ]; then
        # v1.6: 本机busybox无timeout(127静默失败的元凶); 载波守卫防链路断时udhcpc长挂。
        # v1.5: 唯一所有者=本循环; 弃 renewal 守护(双udhcpc打架=全网黑洞根源)。
        # v2.19: FORM=static 跳过 — 静态 IP 归 rc19 档案管(开机窗口此处狂发
        #        DHCPDISCOVER 到未认证口是纯噪声, 2026-10-07 实弹 15s 一条刷屏)
        if [ "$(cat /sys/class/net/$W2_IF/carrier 2>/dev/null)" = "1" ] && \
           ! grep -q '^FORM=static' /data/gw/uplink.conf 2>/dev/null; then
            log "lease: no IP on $W2_IF, one-shot udhcpc"
            udhcpc -i $W2_IF -n -q -t 3 -T 3 -p $UDHCPC_PID -s $UDHCPC_SCRIPT >/dev/null 2>&1
        fi
    fi
    # v1.7: to-LAN 护盾看门狗(入向回包带ct-mark, 无此规则会被fwmark劫持回WAN表
    #       原路弹回公网 = 全LAN黑洞; 原属wan_policy2, 退役后重启即蒸发)
    ip rule show | grep -q "to $LAN_NET lookup main" || \
        ip rule add to $LAN_NET lookup main priority 50
    # 家宽备用默认 + 表200 默认(v4): 网关来自 /tmp/wan.gw(租约/静态档案写)
    if [ -s $GW_FILE ]; then
        BB_GW=$(head -1 $GW_FILE)
        ip route replace default via $BB_GW dev $W2_IF table $T2 2>/dev/null
        ip route show default | grep -q "via $BB_GW dev $W2_IF" || \
            ip route add default via $BB_GW dev $W2_IF metric 200 2>/dev/null
        # v2.31: main 表主默认由 wan_agg.main_primary_apply() 独占维护 ——
        #   本处只保留表200与备用, 不写主默认, 避免多写方互抢。
    fi
    # v2.3: eth0 NAT/FORWARD 看门狗(真补上——v1.7提交曾虚报覆盖, 手工规则重启即蒸发,
    #       eth0裸源出公网=黑洞)
    iptables -t nat -C POSTROUTING -s $LAN_NET -o $W2_IF -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s $LAN_NET -o $W2_IF -j MASQUERADE
    iptables -C FORWARD -i br-lan -o $W2_IF -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i br-lan -o $W2_IF -j ACCEPT
    iptables -C FORWARD -i $W2_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i $W2_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
    # v2.0: v6 T200 家宽路由学习(从 main 的 RA 默认路由取 gw, 每周期刷新)
    V6GW=$(ip -6 route show default 2>/dev/null | grep "dev $W2_IF" | grep -oE "via [a-f0-9:]+ " | awk '{print $2}' | head -1)
    [ -n "$V6GW" ] && ip -6 route replace default via $V6GW dev $W2_IF table $T2 2>/dev/null
    sleep 5
done
