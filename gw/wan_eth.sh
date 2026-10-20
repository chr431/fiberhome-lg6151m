#!/bin/sh
# wan_eth.sh v1.5 — 有线 WAN(eth0) 接口管理守护 (自 wan_agg v2.34 ensure_lease 拆出, 架构轮)
# v1.4 (P1-1): 单实例锁 — 看门狗监督表重启不会拉出双写方.
# v1.3 (2026-10-20 stability batch1): 每轮写 /tmp/wan_eth.hb — watchdog 用
#   心跳年龄识别“进程活但循环卡死”(原仅 alive() 进程判据)。
# v1.1 (2026-10-17 日志加密轮): 租约尝试/结果与耗时、载波/IP/网关/RA 网关边沿、
#   每条规则的真实补装(REPAIR, 含 rc)、每 60s TICK 汇总 — 家宽侧静默劣化可追溯。
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
MAXL=600
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
log_rot() { [ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt $MAXL ] && \
    { tail -n $((MAXL/2)) $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }; }
log "===== wan_eth v1.5 start (fine-log: lease/carrier/repair/tick; +heartbeat; svc_lib) ====="
# v1.5 (batch3): shared single-instance lock + heartbeat primitives.
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else echo "wan_eth: svc_lib.sh missing" >&2; exit 1; fi
if [ -r /data/gw/netlock.sh ]; then . /data/gw/netlock.sh; else
    netcfg_lock() { return 0; }; netcfg_unlock() { :; }; netcfg_repair() { :; }
fi
_rc=0; svc_lock wan_eth /data/gw/wan_eth.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    [ "$_rc" = 1 ] && echo "wan_eth: already running" >&2 || echo "wan_eth: lost lock race" >&2
    exit 0
fi
CYC=0; LAST_CAR=""; LAST_IP=""; LAST_GW=""; LAST_V6GW=""; STATIC_LOGGED=""; NOCAR_LOGGED=""
while :; do
    svc_hb wan_eth
    CYC=$((CYC+1)); [ $((CYC % 12)) -eq 0 ] && log_rot
    # v1.4(原 wan_agg): PHY 只在 ifup 后 attach, 别裸 DOWN
    ip link set $W2_IF up 2>/dev/null
    CAR=$(cat /sys/class/net/$W2_IF/carrier 2>/dev/null)
    [ "$CAR" != "$LAST_CAR" ] && {
        log "EVT carrier ${LAST_CAR:-?} -> ${CAR:-?}"
        LAST_CAR=$CAR
    }
    IP4=$(ip -o -4 addr show $W2_IF 2>/dev/null | awk '{print $4}' | head -1)
    [ "$IP4" != "$LAST_IP" ] && {
        log "EVT eth0 ip ${LAST_IP:-none} -> ${IP4:-none}"
        LAST_IP=$IP4
    }
    if [ -z "$IP4" ]; then
        # v1.6: 本机busybox无timeout(127静默失败的元凶); 载波守卫防链路断时udhcpc长挂。
        # v1.5: 唯一所有者=本循环; 弃 renewal 守护(双udhcpc打架=全网黑洞根源)。
        # v2.19: FORM=static 跳过 — 静态 IP 归 rc19 档案管(开机窗口此处狂发
        #        DHCPDISCOVER 到未认证口是纯噪声, 2026-10-07 实弹 15s 一条刷屏)
        if [ "$CAR" = "1" ] && ! grep -q '^FORM=static' /data/gw/uplink.conf 2>/dev/null; then
            log "EVT lease: no IP on $W2_IF (carrier=1) -> one-shot udhcpc"
            _t0=$(date +%s)
            udhcpc -i $W2_IF -n -q -t 3 -T 3 -p $UDHCPC_PID -s $UDHCPC_SCRIPT >/dev/null 2>&1
            _rc=$?
            IP4=$(ip -o -4 addr show $W2_IF 2>/dev/null | awk '{print $4}' | head -1)
            _gw=$(head -1 $GW_FILE 2>/dev/null)
            log "EVT lease result rc=$_rc elapsed=$(( $(date +%s) - _t0 ))s ip=${IP4:-none} gw=${_gw:-none}"
            [ "$IP4" != "$LAST_IP" ] && { log "EVT eth0 ip ${LAST_IP:-none} -> ${IP4:-none} (post-lease)"; LAST_IP=$IP4; }
            STATIC_LOGGED=""
        elif grep -q '^FORM=static' /data/gw/uplink.conf 2>/dev/null; then
            [ "$STATIC_LOGGED" != 1 ] && { log "EVT static form: udhcpc skipped (rc19 owns eth0 IP)"; STATIC_LOGGED=1; }
        else
            [ "$NOCAR_LOGGED" != 1 ] && { log "EVT no carrier on $W2_IF, waiting (udhcpc skipped)"; NOCAR_LOGGED=1; }
        fi
    else
        STATIC_LOGGED=""; NOCAR_LOGGED=""
    fi
    # v1.7: to-LAN 护盾看门狗(入向回包带ct-mark, 无此规则会被fwmark劫持回WAN表
    #       原路弹回公网 = 全LAN黑洞; 原属wan_policy2, 退役后重启即蒸发)
    # v1.5 (batch3): the whole repair block runs under the netcfg lock; a busy
    # writer skips one 5s cycle (level-driven, retried next cycle).
    if netcfg_lock 3; then
    ip rule show | grep -q "to $LAN_NET lookup main" || {
        ip rule add to $LAN_NET lookup main priority 50; _r=$?
        netcfg_repair "to-LAN shield" "$_r"
        log "REPAIR to-LAN shield rule (missing -> re-added rc=$_r)"
    }
    # 家宽备用默认 + 表200 默认(v4): 网关来自 /tmp/wan.gw(租约/静态档案写)
    if [ -s $GW_FILE ]; then
        BB_GW=$(head -1 $GW_FILE)
        [ "$BB_GW" != "$LAST_GW" ] && { log "EVT gw ${LAST_GW:-none} -> $BB_GW"; LAST_GW=$BB_GW; }
        ip route show table $T2 2>/dev/null | grep -q "^default via $BB_GW dev $W2_IF" || {
            ip route replace default via $BB_GW dev $W2_IF table $T2 2>/dev/null; _r=$?
            netcfg_repair "table$T2 default" "$_r"
            log "REPAIR table$T2 default via $BB_GW (missing -> re-added rc=$_r)"
        }
        ip route show default | grep -q "via $BB_GW dev $W2_IF" || {
            ip route add default via $BB_GW dev $W2_IF metric 200 2>/dev/null; _r=$?
            netcfg_repair "main backup metric200" "$_r"
            log "REPAIR main backup default metric200 via $BB_GW (missing -> added rc=$_r)"
        }
        # v2.31: main 表主默认由 wan_agg.main_primary_apply() 独占维护 ——
        #   本处只保留表200与备用, 不写主默认, 避免多写方互抢。
    fi
    # v2.3: eth0 NAT/FORWARD 看门狗(真补上——v1.7提交曾虚报覆盖, 手工规则重启即蒸发,
    #       eth0裸源出公网=黑洞)
    NAT_OK=1; FWD_OK=1
    iptables -t nat -C POSTROUTING -s $LAN_NET -o $W2_IF -j MASQUERADE 2>/dev/null || {
        iptables -t nat -A POSTROUTING -s $LAN_NET -o $W2_IF -j MASQUERADE; _r=$?
        netcfg_repair "nat eth0" "$_r"
        log "REPAIR nat POSTROUTING -o $W2_IF (missing -> added rc=$_r)"; NAT_OK=0; }
    iptables -C FORWARD -i br-lan -o $W2_IF -j ACCEPT 2>/dev/null || {
        iptables -I FORWARD -i br-lan -o $W2_IF -j ACCEPT; _r=$?
        netcfg_repair "fwd br-lan->eth0" "$_r"
        log "REPAIR FORWARD br-lan->$W2_IF (missing -> added rc=$_r)"; FWD_OK=0; }
    iptables -C FORWARD -i $W2_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || {
        iptables -I FORWARD -i $W2_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT; _r=$?
        netcfg_repair "fwd eth0->br-lan est" "$_r"
        log "REPAIR FORWARD $W2_IF->br-lan established (missing -> added rc=$_r)"; FWD_OK=0; }
    # v2.0: v6 T200 家宽路由学习(从 main 的 RA 默认路由取 gw, 每周期刷新)
    V6GW=$(ip -6 route show default 2>/dev/null | grep "dev $W2_IF" | grep -oE "via [a-f0-9:]+ " | awk '{print $2}' | head -1)
    if [ -n "$V6GW" ]; then
        [ "$V6GW" != "$LAST_V6GW" ] && { log "EVT v6 ra gw ${LAST_V6GW:-none} -> $V6GW"; LAST_V6GW=$V6GW; }
        ip -6 route show table $T2 2>/dev/null | grep -q "default via $V6GW dev $W2_IF" || {
            ip -6 route replace default via $V6GW dev $W2_IF table $T2 2>/dev/null; _r=$?
            netcfg_repair "table$T2 v6 default" "$_r"
            log "REPAIR table$T2 v6 default via $V6GW (missing -> re-added rc=$_r)"
        }
    fi
    netcfg_unlock
    else
        log "WARN netcfg lock timeout: wan_eth repairs (skip this cycle)"
    fi
    if [ $((CYC % 12)) -eq 0 ]; then
        log "TICK epoch=$(date +%s) carrier=${CAR:-?} ip=${IP4:-none} gw=$(head -1 $GW_FILE 2>/dev/null || echo none) v6gw=${V6GW:-none} nat=$NAT_OK fwd=$FWD_OK form=$(grep -m1 '^FORM=' /data/gw/uplink.conf 2>/dev/null | cut -d= -f2 || echo '?')"
    fi
    sleep 5
done
