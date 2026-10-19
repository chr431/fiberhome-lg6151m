#!/bin/sh
# dial_keeper.sh v1.7 -- 拨号自持守护 (ROADMAP P2, 2026-10-06)
#
# v1.7 (2026-10-19 SIGSEGV 根治轮): 单实例锁判据收紧(绝对路径+非僵尸) — 与
#   led_mgr v2.6 同型修复, 防锁 pid 复用时新实例永久误判 duplicate。
# v1.5 (2026-10-17 日志加密轮): 每 60s TICK(has_ip/cell_alive/wan_alive 原文与
#   年龄/DOWN/退避/APN/cci); 僵尸 IP 触发边沿、modem 未就绪原因、飞行模式切换、
#   APN 来源、ccmni_up 的 rc+输出+耗时全部留痕 — 冷启动 cid 轮换/EE 事故可复盘。
#
# v1.4 (2026-10-17 netagent 摘除试验轮): 三改 —
#   ① dial() 改走 ccmni_up.sh(拨号+接口落地一体): 实证 mtk_netagent 才是
#      ccmni IP 执行者(act 响应含全套地址而无人落地), 它退役后裸调用会得到
#      result:0 + 僵尸 IP。ccmni_up.sh 缺席时回退旧裸配方(过渡态兜底)。
#   ② 触发条件补数据面: 原判据仅"无 IP" — 实弹发现飞行模式往返后 ccmni 挂
#      僵尸 IP(IP 在而数据面死), 本守护被骗过从未重拨(wan_alive cell=0 整夜
#      无人救)。现叠加消费 wan_agg 发布的 /tmp/wan_alive(唯一权威, ts 新鲜
#      才信; 无文件/过期回退旧 IP 判据)。
#   ③ 重拨前飞行模式守卫: CFUN=0 时跳过拨号尝试(避免飞行中盲拨刷退避)。
#
# 背景(闸门A实证): mobilenetwork 是 PDN 生命周期持有者 — 杀掉后 ccmni IPv4
# ≤10s 消失; 因此 P3 下架 cfgmgr/mobilenetwork 前必须有自研拨号能力。
#
# 本守护为兜底拨号器: ccmni 无 IPv4 持续超过宽限期(GRACE, 默认 35s — 避开
# mobilenetwork 正常重拨窗口 10-20s, 不与之竞速)时, 以 MIPC 直连配方重拨,
# 全程不经 mobilenetwork/cfgmgr。mobilenetwork 在位时它是安静的备份;
# P3 下架后它自然成为唯一拨号者。
#
# 配方(netifd mipc.sh proto 权威默认 + 实弹验证 result:0):
#   APN 取自 --apn_provision_by_sim (cellular_engine.conf 可覆盖 APN=xxx)
#   --data_call_deact_apn $APN → --data_call_act_type '{...vendor默认...}'
#   成功判据: 响应含 "result": 0 且 3s 后 ccmni 有 IPv4
#
# v1.3 (2026-10-14 部署实测): 单实例守改 PID 锁(/tmp/dial_keeper.lock) — 原
#   pgrep -f 判据在启动者 argv 含脚本路径时自匹配误判"重复"(SSH 一行式启动实测
#   两次命中, 实例静默不启动); 锁定法无模式匹配, 且 cmdline 复核防 PID 复用,
#   并供 watchdog 精确定位实例(避免"杀所有匹配"误伤旁观 shell)。
# v1.2 (2026-10-14 部署实测): 启动即写心跳 — watchdog v1.7 首见"无心跳文件且已过
#   开机宽限"会判陈旧杀+拉(部署重启新实例实测命中, 属误判); 提前到脚本入口写,
#   窗口≈0。旧版本实例(无 hb 文件)该规则仍按设计触发 = 换代码自动重启。
# v1.1 (2026-10-14 模组 EE 事故实弹): 三处加固 —
#   ① 全部 mipc_wan_cli 调用过 mto() 硬超时(纯 shell 实现: 本机无 timeout
#      命令, busybox 也无此 applet)。事故复盘: 模组 Fatal(EE) 后厂商重启
#      RIL/ql_netd 期间, 本守护没有任何重拨留痕 — 疑似卡死在一次 mipc 调用
#      (进程在而守护死; 旧 watchdog 只查进程存活, 查不到这种死法)。
#   ② 心跳 /tmp/dial_keeper.hb(uptime 秒; 退避等待分片刷新 — 等待≠卡死),
#      供 watchdog 判陈旧即杀+拉起。
#   ③ EE 转储增量(/data/log/aee_exp/db.*.EE)= 模组复位事件 → 强制进入重拨
#      分支并重置退避, 不等被动宽限。
#   关键事件(启动/EE/重拨尝试与结果)同时 logger 进 syslog → 经 log_keeper
#   镜像持久化(事故当晚本守护只写 /tmp, 重启即失, 复盘缺一环)。
LOG=/tmp/dial_keeper.log
HB=/tmp/dial_keeper.hb
LOCK=/tmp/dial_keeper.lock
CONF=/data/gw/cellular_engine.conf
GRACE=35      # PDN 掉线多少秒后才接管(避开 mobilenetwork 重拨窗口)
POLL=5        # 探测周期
MINB=15       # 失败退避起步
MAXB=300      # 退避上限
MTO=10        # 单次 mipc 调用硬超时(秒)

MAXL=400
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
log_rot() { [ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt $MAXL ] && \
    { tail -n $((MAXL/2)) $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }; }

# v1.3: 单实例守 — PID 锁 + cmdline 复核(无模式匹配; 供 watchdog 精确取实例 PID)
# v1.7: 锁判据收紧 — 必须命中本脚本绝对路径且非僵尸(锁 pid 复用给含
#   dial_keeper 字样的其它命令时, 旧判据会让新实例误判 duplicate 永久退出)。
_lp=$(cat $LOCK 2>/dev/null)
if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null \
   && ! grep -q '^State:.*Z' /proc/$_lp/status 2>/dev/null \
   && grep -qa '/data/gw/dial_keeper.sh' /proc/$_lp/cmdline 2>/dev/null; then
    log "duplicate instance pid=$_lp alive — exit (single-instance lock)"
    exit 0
fi
echo $$ > $LOCK

hb() { cut -d. -f1 /proc/uptime > $HB 2>/dev/null; }
hb   # v1.2: 启动即写心跳 — 消 watchdog 首见"无心跳文件"窗口(deploy 重启实测命中:
     #   新实例起 ~2s 时 watchdog 判 stale(hb=none) 杀+拉, 属误判; 旧 v1.0 实例
     #   无 hb 文件时该规则仍按设计触发 = 换代码后自动重启)
# v1.1: 分片睡眠(每片刷心跳 — watchdog 阈值 90s 对 5s 分片有大余量)
nap() {
    _n=$1
    while [ "$_n" -gt 0 ]; do
        hb
        _s=5; [ "$_n" -lt 5 ] && _s=$_n
        sleep $_s
        _n=$((_n - _s))
    done
}
# v1.1: timeout 语义封装(设备无 timeout/coreutils; kill -0 轮询 + 到期 SIGKILL)。
# 输出走临时文件回显, 保持 stdout 语义(调用方照旧 | grep); 超时返回 124。
mipc_to() {
    mipc_wan_cli "$@" >/tmp/mto.$$ 2>&1 & _p=$!
    _i=0
    while [ "$_i" -lt "$MTO" ] && kill -0 $_p 2>/dev/null; do
        sleep 1; _i=$((_i + 1))
    done
    if kill -0 $_p 2>/dev/null; then
        kill -9 $_p 2>/dev/null
        rm -f /tmp/mto.$$
        log "mipc timeout(${MTO}s): $1"
        return 124
    fi
    wait $_p; _rc=$?
    cat /tmp/mto.$$ 2>/dev/null
    rm -f /tmp/mto.$$
    return $_rc
}

has_ip() { ip -o -4 addr show 2>/dev/null | grep -q 'ccmni.*inet'; }

modem_ok() {
    _b=$(cat /sys/kernel/ccci/boot 2>/dev/null)
    [ "$(printf '%s' "$_b" | head -c 5)" = "md1:4" ] || { MODEM_WHY="cci=$(printf '%s' "$_b" | head -c 24)"; return 1; }
    _s=$(mipc_to --show_sim_status 2>/dev/null)
    printf '%s' "$_s" | grep -q COMPLETE_READY || { MODEM_WHY="sim=$(printf '%s' "$_s" | tr '\n' ' ' | head -c 60)"; return 1; }
    MODEM_WHY=ok
}

get_apn() {
    # busybox ash: . 缺失文件 = 致命退出, 必须 [ -r ] 守卫
    [ -r "$CONF" ] && . "$CONF"
    if [ -n "${APN:-}" ] && [ "$APN" != "auto" ]; then
        APN_SRC=conf
        echo "$APN"; return
    fi
    APN_SRC=sim
    mipc_to --apn_provision_by_sim 2>/dev/null | grep -oE '"apn": *"[^"]+"' | cut -d'"' -f4
}

dial() {  # $1=apn — v1.4: ccmni_up 拨号+落地一体(回退旧裸配方)
    if [ -x /data/gw/ccmni_up.sh ]; then
        _t0=$(date +%s)
        _out=$(sh /data/gw/ccmni_up.sh "$1" 2>&1); _rc=$?
        log "EVT ccmni_up apn=$1 rc=$_rc elapsed=$(( $(date +%s) - _t0 ))s out=$(printf '%s' "$_out" | tr '\n' ' ' | head -c 200)"
        return $_rc
    fi
    log "WARN ccmni_up.sh missing — fallback bare dial recipe"
    mipc_to --data_call_deact_apn "$1" >/dev/null 2>&1
    mipc_to --data_call_act_type \
        "{\"apn\":\"$1\",\"apn_type\":0,\"ip_type\":3,\"roaming_type\":3,\"auth_type\":0,\"username\":\"\",\"password\":\"\",\"bearer_bitmask\":\"0xfffdffff\",\"mtu\":1400,\"mode\":1}" \
        2>&1 | grep -q '"result": *0'
}

# v1.4: 数据面判活(堵僵尸 IP 洞) — 消费 wan_agg 的唯一权威结论;
#   无文件/ts 过期(>30s)回退 0(=由调用方回退 IP-only 旧判据)。
cell_alive() {
    _wa=$(cat /tmp/wan_alive 2>/dev/null); WA_RAW=$_wa
    _c=$(printf '%s' "$_wa" | sed -n 's/.*cell=\([01]\).*/\1/p')
    _t=$(printf '%s' "$_wa" | sed -n 's/.*ts=\([0-9]*\).*/\1/p')
    if [ -n "$_t" ]; then WA_AGE=$(( $(date +%s) - _t )); else WA_AGE=-1; fi
    [ -n "$_t" ] || { WA_STATE=no_file; return 0; }
    [ "$WA_AGE" -le 30 ] || { WA_STATE=stale; return 0; }
    [ "$_c" = 1 ] && { WA_STATE=alive; return 0; }
    WA_STATE=dead; return 1
}

# v1.4: 飞行模式守卫(CFUN=0 时不盲拨)
cfun_off() { mipc_to --at_cmd 'AT+CFUN?' 2>/dev/null | grep -q 'CFUN: 0'; }

ee_count() { ls -d /data/log/aee_exp/db.*.EE 2>/dev/null | wc -l; }

DOWN=0; B=$MINB
CYC=0; ZOMBIE=0; APN_LAST=""; APN_SRC_LAST=""; CFUN_LAST=""
EE_N=$(ee_count)
log "===== keeper v1.7 start (grace=${GRACE}s poll=${POLL}s mto=${MTO}s ee=${EE_N}; ccmni_up=netagent-lite; trigger=ip+dataplane; fine-log) ====="
logger -t dial_keeper "keeper v1.7 start (grace=${GRACE}s mto=${MTO}s ee=${EE_N})"
while :; do
    hb; CYC=$((CYC+1)); [ $((CYC % 12)) -eq 0 ] && log_rot
    # v1.1: 模组 EE 事件 = 复位信号 → 强制重拨路径(不等被动宽限)
    EEN=$(ee_count)
    if [ "${EEN:-0}" -gt "${EE_N:-0}" ] 2>/dev/null; then
        log "modem EE detected (${EE_N}->${EEN}) — force redial path"
        logger -t dial_keeper "modem EE detected (${EE_N}->${EEN}); forced redial"
        EE_N=$EEN
        DOWN=$GRACE
        B=$MINB
    fi
    # v1.4: 无 IP **或** 数据面死(僵尸 IP) 都计 DOWN — 后者来自 wan_alive
    HIP=0; has_ip && HIP=1
    CA=0; cell_alive && CA=1
    if [ "$HIP" = 1 ] && [ "$CA" = 1 ]; then
        [ "$DOWN" -gt 0 ] && log "recovered (down ${DOWN}s)"
        [ "$ZOMBIE" = 1 ] && { log "EVT zombie-IP cleared: data plane alive again (wa_age=${WA_AGE}s)"; ZOMBIE=0; }
        DOWN=0; B=$MINB; CFUN_LAST=""
    else
        # v1.5: 僵尸 IP 触发边沿 — "有 IP 但数据面死"是重拨的真正理由, 单独留痕
        if [ "$HIP" = 1 ] && [ "$CA" = 0 ] && [ "$ZOMBIE" = 0 ]; then
            log "EVT zombie-IP: has_ip=1 data_plane=dead wa_state=${WA_STATE:-?} wa_age=${WA_AGE:-?}s wa=[${WA_RAW:-none}]"
            ZOMBIE=1
        fi
        DOWN=$((DOWN + POLL))
        if [ "$DOWN" -ge "$GRACE" ]; then
            if ! modem_ok; then
                log "down ${DOWN}s but modem/SIM not ready: ${MODEM_WHY:-?}"
            elif cfun_off; then
                log "down ${DOWN}s but airplane (CFUN=0), skip dial"
                [ "$CFUN_LAST" != 1 ] && { log "EVT airplane ON (CFUN=0) — dial suppressed"; CFUN_LAST=1; }
                DOWN=0   # 飞行解除后重新计时
            else
                [ "$CFUN_LAST" = 1 ] && { log "EVT airplane OFF (CFUN!=0) — dial re-enabled"; CFUN_LAST=0; }
                APN=$(get_apn)
                [ "$APN" != "$APN_LAST" ] && {
                    log "EVT apn ${APN_LAST:-none} -> ${APN:-none} src=${APN_SRC:-?}"
                    APN_LAST=$APN
                }
                if [ -z "$APN" ]; then
                    log "down ${DOWN}s but no APN (SIM?), wait"
                else
                    _dt=$(date +%s)
                    log "dial attempt apn=$APN (down ${DOWN}s backoff=$B)"
                    logger -t dial_keeper "dial attempt apn=$APN (down ${DOWN}s)"
                    if dial "$APN"; then
                        nap 3
                        if has_ip; then
                            log "DIAL OK apn=$APN (was down ${DOWN}s dial=$(( $(date +%s) - _dt ))s)"
                            logger -t dial_keeper "DIAL OK apn=$APN (was down ${DOWN}s)"
                        else
                            log "result:0 but no IP yet, continue watch (dial=$(( $(date +%s) - _dt ))s)"
                        fi
                        DOWN=0
                    else
                        log "DIAL FAIL apn=$APN backoff ${B}s (dial=$(( $(date +%s) - _dt ))s)"
                        logger -t dial_keeper "DIAL FAIL apn=$APN backoff ${B}s"
                        nap "$B"
                        B=$((B * 2)); [ "$B" -gt "$MAXB" ] && B=$MAXB
                        DOWN=0   # 退避后重新计时(退避本身就是等待)
                    fi
                fi
            fi
        fi
    fi
    # v1.5: 每 12 环循(~60s)一行决策输入快照 — 24h 时间线的主干
    if [ $((CYC % 12)) -eq 0 ]; then
        log "TICK epoch=$(date +%s) has_ip=$HIP cell_alive=$CA wa_state=${WA_STATE:-?} wa_age=${WA_AGE:--}s wa=[${WA_RAW:-none}] down=$DOWN backoff=$B apn=${APN_LAST:-?} cci=$(cat /sys/kernel/ccci/boot 2>/dev/null | head -c 16)"
    fi
    nap $POLL
done
