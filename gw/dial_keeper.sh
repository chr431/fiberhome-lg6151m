#!/bin/sh
# dial_keeper.sh v1.0 -- 拨号自持守护 (ROADMAP P2, 2026-10-06)
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
LOG=/tmp/dial_keeper.log
CONF=/data/gw/cellular_engine.conf
GRACE=35      # PDN 掉线多少秒后才接管(避开 mobilenetwork 重拨窗口)
POLL=5        # 探测周期
MINB=15       # 失败退避起步
MAXB=300      # 退避上限

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s $LOG ] && [ "$(wc -l < $LOG)" -gt 200 ] && { tail -100 $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }

has_ip() { ip -o -4 addr show 2>/dev/null | grep -q 'ccmni.*inet'; }

modem_ok() {
    [ "$(cat /sys/kernel/ccci/boot 2>/dev/null | head -c 5)" = "md1:4" ] || return 1
    mipc_wan_cli --show_sim_status 2>/dev/null | grep -q COMPLETE_READY
}

get_apn() {
    # busybox ash: . 缺失文件 = 致命退出, 必须 [ -r ] 守卫
    [ -r "$CONF" ] && . "$CONF"
    if [ -n "${APN:-}" ] && [ "$APN" != "auto" ]; then echo "$APN"; return; fi
    mipc_wan_cli --apn_provision_by_sim 2>/dev/null | grep -oE '"apn": *"[^"]+"' | cut -d'"' -f4
}

dial() {  # $1=apn
    mipc_wan_cli --data_call_deact_apn "$1" >/dev/null 2>&1
    mipc_wan_cli --data_call_act_type \
        "{\"apn\":\"$1\",\"apn_type\":0,\"ip_type\":3,\"roaming_type\":3,\"auth_type\":0,\"username\":\"\",\"password\":\"\",\"bearer_bitmask\":\"0xfffdffff\",\"mtu\":1400,\"mode\":1}" \
        2>&1 | grep -q '"result": *0'
}

DOWN=0; B=$MINB
log "===== keeper v1.0 start (grace=${GRACE}s poll=${POLL}s) ====="
while :; do
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
                elif dial "$APN"; then
                    sleep 3
                    has_ip && log "DIAL OK apn=$APN (was down ${DOWN}s)" \
                             || log "result:0 but no IP yet, continue watch"
                    DOWN=0
                else
                    log "DIAL FAIL apn=$APN backoff ${B}s"
                    sleep "$B"
                    B=$((B * 2)); [ "$B" -gt "$MAXB" ] && B=$MAXB
                    DOWN=0   # 退避后重新计时(退避本身就是等待)
                fi
            fi
        fi
    fi
    sleep "$POLL"
done
