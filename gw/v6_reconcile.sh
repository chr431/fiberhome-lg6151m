#!/bin/sh
# v6_reconcile.sh v1.0 -- LAN IPv6 (ULA + NAT66 + radvd) 幂等收敛器
#
# 为什么需要它 (2026-10-28 实弹):
#   rc_netfh v1.4 把"LAN 要不要开 v6"绑在"**蜂窝承载口此刻**有全局 v6"上, 且只在
#   开机跑一次。本次启动承载口是 ccmni2(只有 v4) -> 整块跳过(ULA/NAT66/radvd 全没
#   做); 2 分钟后承载切到 ccmni3(有全局 v6 240a:42c6:...), 没有任何东西会重跑它 ->
#   LAN v6 整个 boot 缺失, 而 GUI 状态页硬编码显示"ULA 已部署"。
#   判据错在对象: LAN v6 的出口可以是 eth0(家宽/上游 v6) 也可以是蜂窝, 蜂窝有没有
#   v6 不该决定 LAN 要不要开。
#
# 本脚本职责:
#   * 判据 = **任一上行**(eth0 / ccmni*)有全局 v6;
#   * 可重入 + 幂等: 开机(rc_netfh)、拨号落地(ccmni_up)、看门狗兜底都会调;
#   * 配置 V6LAN(defaults.conf 默认 1; settings.conf 覆盖): 0 = 停用并拆除。
#
# 子命令:
#   apply (默认)  收敛到期望态, stdout 一行 kv: mode/up/ula/radvd/v6lan
#   status        只读当前态(不改任何东西), 同样的 kv 行
#   check         退出码 0 = 健康/停用/无 v6 上行(不该报错); 1 = 该在没在
#
# mode 语义 (供 avail_sampler / GUI 单一事实源):
#   on        已启用且有 v6 上行, ULA 与 radvd 已就位
#   disabled  V6LAN=0 (用户关闭)            -> 可用性 off
#   noup      已启用但当前没有任何上行带全局 v6 -> 可用性 deg (不冒充绿, 也不报死)
#   wait      br-lan 还没建好(开机竞态)      -> 可用性 deg
#   nobr      本机没有 br-lan                -> 可用性 nodata
#
# 纪律: 只写 ULA/NAT66/radvd 三件(路由默认只在"完全没有 v6 默认"时补一条);
#       main 表主默认归 wan_agg 独占, 本脚本不抢。

DIR=/data/gw
BR=br-lan
ULA_ADDR=fd42:9ac1:7e50::1/64
ULA_PFX=fd42:9ac1:7e50
STATE=/tmp/v6_state
LOG=/tmp/v6_reconcile.log
IP=/data/gw/bin/ip
[ -x "$IP" ] || IP=ip
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt 400 ] && \
    { tail -n 200 $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }

# 配置 (defaults 只读基线 + settings 稀疏覆盖)
[ -r $DIR/defaults.conf ] && . $DIR/defaults.conf 2>/dev/null
[ -r $DIR/settings.conf ] && . $DIR/settings.conf 2>/dev/null
V6LAN=${V6LAN:-1}

have_ula() { $IP -6 addr show dev $BR 2>/dev/null | grep -q "$ULA_PFX"; }
radvd_pid() { pidof radvd 2>/dev/null | awk '{print $1}'; }

uplink() { # 找一个有全局 v6 的上行口; 找不到返回 1
    for i in eth0 ccmni0 ccmni1 ccmni2 ccmni3; do
        [ -d /sys/class/net/$i ] || continue
        $IP -6 addr show dev $i 2>/dev/null | grep -q 'scope global' && { echo $i; return 0; }
    done
    return 1
}

state_write() { # $1=mode $2=up
    _r=$(radvd_pid)
    _u=0; have_ula && _u=1
    printf 'mode=%s up=%s ula=%s radvd=%s ts=%s\n' \
        "$1" "${2:--}" "$_u" "${_r:--}" "$(date +%s)" > $STATE
}

teardown() { # $1=mode(disabled|noup|nobr)
    _p=$(radvd_pid)
    [ -n "$_p" ] && { kill "$_p" 2>/dev/null; log "stop radvd ($1)"; }
    have_ula && { $IP -6 addr del $ULA_ADDR dev $BR 2>/dev/null; log "del ULA ($1)"; }
    state_write "$1" ""
}

apply() {
    if [ ! -d /sys/class/net/$BR ]; then
        # 30s 上限: 开机路径(br-lan 由 rc19 在 ~t+50s 建)与看门狗兜底(2min 一次)
        # 共同覆盖竞态; 这里不再等 60s, 免得把 rc_netfh 的 fw_apply 拖后一分钟。
        j=0
        while [ "$j" -lt 6 ] && [ ! -d /sys/class/net/$BR ]; do sleep 5; j=$((j+1)); done
        [ -d /sys/class/net/$BR ] || { state_write nobr ""; return 1; }
    fi
    if [ "$V6LAN" != 1 ]; then teardown disabled; return 0; fi
    UP=$(uplink) || { teardown noup; return 0; }

    _nl=0
    . $DIR/netlock.sh 2>/dev/null
    netcfg_lock 5 2>/dev/null && _nl=1
    [ "$_nl" = 1 ] || log "WARN netcfg lock timeout: v6 reconcile (proceeding best-effort)"

    have_ula || { $IP -6 addr add $ULA_ADDR dev $BR 2>/dev/null && log "add ULA on $BR"; }
    [ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null)" = 1 ] || \
        sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    # NAT66 + FORWARD: eth0 那条由 rc_netfh 无条件装; 这里补齐当前上行并保持幂等
    for _o in eth0 $UP; do
        ip6tables -t nat -C POSTROUTING -s $ULA_PFX::/64 -o $_o -j MASQUERADE 2>/dev/null || \
            ip6tables -t nat -A POSTROUTING -s $ULA_PFX::/64 -o $_o -j MASQUERADE 2>/dev/null
        ip6tables -C FORWARD -i $BR -o $_o -j ACCEPT 2>/dev/null || \
            ip6tables -I FORWARD -i $BR -o $_o -j ACCEPT 2>/dev/null
        ip6tables -C FORWARD -i $_o -o $BR -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            ip6tables -I FORWARD -i $_o -o $BR -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null
    done
    # 默认路由: 只在"一条 v6 默认都没有"时补(主默认归 wan_agg, 不抢)
    $IP -6 route show default 2>/dev/null | grep -q . || \
        { $IP -6 route add default dev $UP 2>/dev/null && log "add v6 default dev $UP"; }
    # radvd
    if [ -z "$(radvd_pid)" ]; then
        if [ -x /fhrom/bin/radvd ]; then
            LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib /fhrom/bin/radvd \
                -C $DIR/radvd.conf -p /tmp/radvd.pid -m logfile -l /tmp/radvd.log 2>/dev/null
            log "start radvd rc=$? pid=$(radvd_pid)"
        else
            log "WARN /fhrom/bin/radvd missing"
        fi
    fi
    [ "$_nl" = 1 ] && netcfg_unlock
    state_write on "$UP"
    return 0
}

status() {
    _m=unknown
    [ -r $STATE ] && _m=$(sed -n 's/^mode=\([a-z]*\).*/\1/p' $STATE 2>/dev/null | head -1)
    _u=$(uplink) || _u=""
    _r=$(radvd_pid)
    _a=0; have_ula && _a=1
    printf 'mode=%s up=%s ula=%s radvd=%s v6lan=%s\n' \
        "${_m:-unknown}" "${_u:--}" "$_a" "${_r:--}" "$V6LAN"
}

check() {
    [ "$V6LAN" = 1 ] || exit 0
    [ -d /sys/class/net/$BR ] || exit 0
    uplink >/dev/null 2>&1 || exit 0
    have_ula && [ -n "$(radvd_pid)" ] && exit 0
    exit 1
}

case "${1:-apply}" in
    apply)  O=$(apply); RC=$?; status; exit $RC ;;
    status) status ;;
    check)  check ;;
    *)      echo "usage: v6_reconcile.sh [apply|status|check]" >&2; exit 1 ;;
esac
