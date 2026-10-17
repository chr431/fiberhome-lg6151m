#!/bin/sh
# ccmni_up.sh v1.0 — MIPC 数据呼叫 + ccmni 接口落地 (netagent-lite, 自研替代)
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
LOG=/tmp/ccmni_up.log
MTO=15
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s $LOG ] && [ "$(wc -l < $LOG)" -gt 120 ] && { tail -60 $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }

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
mto --data_call_deact_apn "$APN" >/dev/null 2>&1
RESP=$(mto --data_call_act_type \
    "{\"apn\":\"$APN\",\"apn_type\":0,\"ip_type\":3,\"roaming_type\":3,\"auth_type\":0,\"username\":\"\",\"password\":\"\",\"bearer_bitmask\":\"0xfffdffff\",\"mtu\":1400,\"mode\":1}" \
    2>/dev/null)
case $? in 124) log "dial TIMEOUT apn=$APN"; exit 2 ;; esac
printf '%s' "$RESP" | grep -q '"result": *0' || {
    log "dial FAIL apn=$APN resp=$(printf '%s' "$RESP" | head -c 120)"
    exit 2
}
IF=$(jf ifname); V4=$(jf v4_addr); M4=$(jf v4_mask)
V6=$(jf v6_addr); P6=$(jf v6_prefix); MU=$(jf v4_mtu)
[ -n "$IF" ] && [ -n "$V4" ] || { log "parse FAIL: ifname/v4_addr missing: $(printf '%s' "$RESP" | head -c 120)"; exit 3; }
# 落地: flush 僵尸 IP(v4+v6 一并) → 新地址 → mtu → up。
# /32 兜底: ccmni 是点对点形态, 出向走 dev 路由, 掩码缺席不阻断(NAT 只用源地址)。
ip addr flush dev $IF
ip addr add "$V4/${M4:-32}" dev $IF 2>/dev/null
[ -n "$V6" ] && ip -6 addr add "$V6/${P6:-64}" dev $IF 2>/dev/null
ip link set $IF mtu "${MU:-1400}" up 2>/dev/null
ip -o -4 addr show $IF 2>/dev/null | grep -q inet || { log "land FAIL: no v4 on $IF after add"; exit 4; }
log "up $IF v4=$V4/${M4:-32} v6=${V6:-none} mtu=${MU:-1400}"
echo "$IF"
exit 0
