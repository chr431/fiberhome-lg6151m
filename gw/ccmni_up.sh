#!/bin/sh
# ccmni_up.sh v1.3 — MIPC 数据呼叫 + ccmni 接口落地 (netagent-lite, 自研替代)
# v1.1 (2026-10-17 日志加密轮): 全程阶段留痕 — 入口/旧地址清单、deact rc+耗时、
#   act rc+耗时+关键响应、flush 清单、逐条 add/up rc、最终 exit code。拨号失败时
#   不再只有一行 "dial FAIL", 而是能定位到 deact/act/解析/落地哪一段。
# usage: ccmni_up.sh <apn>
#   deact+act(与 dial_keeper v1.0 起实弹验证的同款配方) → 解析响应 → 落地。
#
# 为什么需要它(2026-10-17 netagent 摘除试验实证):
#   act 响应自带全套地址(v4_addr/v4_mask/v4_gw/v4_mtu + v6_addr/v6_prefix + dns),
#   但**接口落地(IP flush/add/mtu)没有任何人做** — mtk_netagent 才是执行者:
#   无它时拨号 result:0 而接口永远挂着僵尸旧 IP(实测: 老 IP 10.65.104.67 纹丝
#   不动, 数据面 100% 丢包)。厂商 netifd proto(mipc.sh)同样不含落地语句——
#   dial_5g 的 proto 路径与 dial_keeper 的裸调用**都**依赖 netagent 兜落地。
#   本脚本 = 这段唯一缺失职责的自研实现, 退役 netagent 的前提。
#
# 路由纪律: 本脚本不写任何路由/NAT —— main 表归 wan_agg.main_primary_apply
#   独占(按聚合模式推导), 探活路由(metric 250)由其每周期维持; NAT/FORWARD 由
#   rc_netfh(开机幂等)/wan_agg(漂移块)装。单写方纪律不因 netagent 退役而破。
# 退出码: 0=落地成功(打印 ifname); 2=拨号失败/超时; 3=响应解析失败; 4=落地失败
# v1.3: 落地后调 v6_reconcile.sh 收敛 LAN v6(承载切换可能带来/带走全局 v6).
# v1.2 (batch3): address landing is serialized with route/firewall writers.
if [ -r /data/gw/netlock.sh ]; then . /data/gw/netlock.sh; else
    netcfg_lock() { return 0; }; netcfg_unlock() { :; }; netcfg_repair() { :; }
fi
LOG=/tmp/ccmni_up.log
MTO=15
MAXL=240
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt $MAXL ] && { tail -n $((MAXL/2)) $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }

# 硬超时封装(dial_keeper mto 同款; 设备无 timeout 命令)
mto() {
    mipc_wan_cli "$@" >/tmp/cup.$$ 2>&1 & _p=$!
    _i=0
    while [ "$_i" -lt "$MTO" ] && kill -0 $_p 2>/dev/null; do sleep 1; _i=$((_i+1)); done
    if kill -0 $_p 2>/dev/null; then
        kill -9 $_p 2>/dev/null; rm -f /tmp/cup.$$
        log "mipc timeout(${MTO}s): $1"; return 124
    fi
    wait $_p; _rc=$?
    cat /tmp/cup.$$ 2>/dev/null; rm -f /tmp/cup.$$
    return $_rc
}
jf() {  # $1=字段名 -> 从 $RESP 提取(字符串/数值均带引号容忍)
    printf '%s' "$RESP" | grep -oE "\"$1\": *\"?[^,}]*\"?" | head -1 | sed 's/^"[^"]*": *//; s/"//g'
}

APN=$1
[ -n "$APN" ] || { echo "usage: ccmni_up.sh <apn>" >&2; exit 1; }
T_ALL=$(date +%s)
OLD=$(ip -o -4 addr show 2>/dev/null | grep ccmni | awk '{print $2":"$4}' | tr '\n' ',')
log "EVT start apn=$APN old=[${OLD%,}]"
T0=$(date +%s)
mto --data_call_deact_apn "$APN" >/dev/null 2>&1
DRC=$?
log "EVT deact apn=$APN rc=$DRC elapsed=$(( $(date +%s) - T0 ))s"
T0=$(date +%s)
RESP=$(mto --data_call_act_type \
    "{\"apn\":\"$APN\",\"apn_type\":0,\"ip_type\":3,\"roaming_type\":3,\"auth_type\":0,\"username\":\"\",\"password\":\"\",\"bearer_bitmask\":\"0xfffdffff\",\"mtu\":1400,\"mode\":1}" \
    2>/dev/null)
ARC=$?
_el=$(( $(date +%s) - T0 ))
log "EVT act apn=$APN rc=$ARC elapsed=${_el}s resp=$(printf '%s' "$RESP" | tr '\n' ' ' | head -c 200)"
case $ARC in 124) log "dial TIMEOUT apn=$APN"; exit 2 ;; esac
printf '%s' "$RESP" | grep -q '"result": *0' || {
    log "dial FAIL apn=$APN resp=$(printf '%s' "$RESP" | head -c 160)"
    exit 2
}
IF=$(jf ifname); V4=$(jf v4_addr); M4=$(jf v4_mask)
V6=$(jf v6_addr); P6=$(jf v6_prefix); MU=$(jf v4_mtu)
[ -n "$IF" ] && [ -n "$V4" ] || { log "parse FAIL: ifname/v4_addr missing: $(printf '%s' "$RESP" | head -c 160)"; exit 3; }
log "EVT act-ok if=$IF v4=$V4/${M4:-32} v6=${V6:-none}/${P6:-64} mtu=${MU:-1400}"
# 落地: flush 僵尸 IP(v4+v6 一并) → 新地址 → mtu → up。
# /32 兜底: ccmni 是点对点形态, 出向走 dev 路由, 掩码缺席不阻断(NAT 只用源地址)。
FLUSHED=$(ip -o addr show dev $IF 2>/dev/null | awk '{print $3":"$4}' | tr '\n' ',')
_nl=0; netcfg_lock 5 && _nl=1
[ "$_nl" = 1 ] || log "WARN netcfg lock timeout: ccmni landing (proceeding best-effort)"
ip addr flush dev $IF
log "EVT land $IF flush=[${FLUSHED%,}]"
ip addr add "$V4/${M4:-32}" dev $IF 2>/dev/null; R4=$?
R6=0; [ -n "$V6" ] && { ip -6 addr add "$V6/${P6:-64}" dev $IF 2>/dev/null; R6=$?; }
ip link set $IF mtu "${MU:-1400}" up 2>/dev/null; RUP=$?
log "EVT land $IF add_v4_rc=$R4 add_v6_rc=$R6 link_up_rc=$RUP"
[ "$_nl" = 1 ] && netcfg_unlock
ip -o -4 addr show $IF 2>/dev/null | grep -q inet || { log "land FAIL: no v4 on $IF after add"; exit 4; }
log "EVT up $IF v4=$V4/${M4:-32} v6=${V6:-none} mtu=${MU:-1400} total=$(( $(date +%s) - T_ALL ))s"
# v1.3: 承载变更后收敛 LAN v6 —— 新承载可能带全局 v6(也可能没有), 开/拆由
#   v6_reconcile.sh 的判据决定(任一上行有全局 v6); 本脚本不持 v6 状态机。
_v6o=$(sh /data/gw/v6_reconcile.sh apply 2>&1)
log "EVT v6 $_v6o"
echo "$IF"
exit 0
