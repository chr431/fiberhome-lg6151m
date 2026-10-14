#!/bin/sh
# dial_keeper.sh v1.2 -- 拨号自持守护 (ROADMAP P2, 2026-10-06)
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
CONF=/data/gw/cellular_engine.conf
GRACE=35      # PDN 掉线多少秒后才接管(避开 mobilenetwork 重拨窗口)
POLL=5        # 探测周期
MINB=15       # 失败退避起步
MAXB=300      # 退避上限
MTO=10        # 单次 mipc 调用硬超时(秒)

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s $LOG ] && [ "$(wc -l < $LOG)" -gt 200 ] && { tail -100 $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }

# v1.1: 单实例守护 — rc19 与 watchdog 可能同时拉起(启动竞态), 发现同侪即退
# (不杀戮: 正在运行的实例优先; watchdog 判陈旧时会先杀后拉, 不冲突)
for _op in $(pgrep -f dial_keeper.sh 2>/dev/null); do
    [ "$_op" = "$$" ] && continue
    log "duplicate instance pid=$_op detected — exit (single-instance guard)"
    exit 0
done

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
    [ "$(cat /sys/kernel/ccci/boot 2>/dev/null | head -c 5)" = "md1:4" ] || return 1
    mipc_to --show_sim_status 2>/dev/null | grep -q COMPLETE_READY
}

get_apn() {
    # busybox ash: . 缺失文件 = 致命退出, 必须 [ -r ] 守卫
    [ -r "$CONF" ] && . "$CONF"
    if [ -n "${APN:-}" ] && [ "$APN" != "auto" ]; then echo "$APN"; return; fi
    mipc_to --apn_provision_by_sim 2>/dev/null | grep -oE '"apn": *"[^"]+"' | cut -d'"' -f4
}

dial() {  # $1=apn
    mipc_to --data_call_deact_apn "$1" >/dev/null 2>&1
    mipc_to --data_call_act_type \
        "{\"apn\":\"$1\",\"apn_type\":0,\"ip_type\":3,\"roaming_type\":3,\"auth_type\":0,\"username\":\"\",\"password\":\"\",\"bearer_bitmask\":\"0xfffdffff\",\"mtu\":1400,\"mode\":1}" \
        2>&1 | grep -q '"result": *0'
}

ee_count() { ls -d /data/log/aee_exp/db.*.EE 2>/dev/null | wc -l; }

DOWN=0; B=$MINB
EE_N=$(ee_count)
log "===== keeper v1.2 start (grace=${GRACE}s poll=${POLL}s mto=${MTO}s ee=${EE_N}) ====="
logger -t dial_keeper "keeper v1.2 start (grace=${GRACE}s mto=${MTO}s ee=${EE_N})"
while :; do
    hb
    # v1.1: 模组 EE 事件 = 复位信号 → 强制重拨路径(不等被动宽限)
    EEN=$(ee_count)
    if [ "${EEN:-0}" -gt "${EE_N:-0}" ] 2>/dev/null; then
        log "modem EE detected (${EE_N}->${EEN}) — force redial path"
        logger -t dial_keeper "modem EE detected (${EE_N}->${EEN}); forced redial"
        EE_N=$EEN
        DOWN=$GRACE
        B=$MINB
    fi
    if has_ip; then
        [ "$DOWN" -gt 0 ] && log "recovered (down ${DOWN}s)"
        DOWN=0; B=$MINB
    else
        DOWN=$((DOWN + POLL))
        if [ "$DOWN" -ge "$GRACE" ]; then
            if ! modem_ok; then
                log "down ${DOWN}s but modem/SIM not ready, wait"
            else
                APN=$(get_apn)
                if [ -z "$APN" ]; then
                    log "down ${DOWN}s but no APN (SIM?), wait"
                else
                    log "dial attempt apn=$APN (down ${DOWN}s)"
                    logger -t dial_keeper "dial attempt apn=$APN (down ${DOWN}s)"
                    if dial "$APN"; then
                        nap 3
                        if has_ip; then
                            log "DIAL OK apn=$APN (was down ${DOWN}s)"
                            logger -t dial_keeper "DIAL OK apn=$APN (was down ${DOWN}s)"
                        else
                            log "result:0 but no IP yet, continue watch"
                        fi
                        DOWN=0
                    else
                        log "DIAL FAIL apn=$APN backoff ${B}s"
                        logger -t dial_keeper "DIAL FAIL apn=$APN backoff ${B}s"
                        nap "$B"
                        B=$((B * 2)); [ "$B" -gt "$MAXB" ] && B=$MAXB
                        DOWN=0   # 退避后重新计时(退避本身就是等待)
                    fi
                fi
            fi
        fi
    fi
    nap $POLL
done
