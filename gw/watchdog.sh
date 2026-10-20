#!/bin/sh
# watchdog.sh v1.27 -- on-device continuous invariant monitor.
# v1.27 (2026-10-20 stability P0/P1 batch2):
#   ① 每个外部检查/探针经静态 busybox timeout 限时(默认 8s; 超时/137/139 视为
#      "工具故障" — 重试 3 次, 仍失败只告警并记 toolfaults, 不再等价于服务死);
#   ② 破坏性自愈改为 3 次连续确认(3×30s=90s)才动作, 单次抖动不动射频/不杀进程;
#   ③ 统一服务监督表(存活+cmdline配方+心跳新鲜度+限频 3 次/小时), 覆盖
#      dnsmasq/dropbear/v3httpd/authd/ntp_keeper/traffic_logger/wifi_guard/
#      reboot_sched/led_mgr/fan_mgr/wan_eth/log_keeper/core_trap/healthdog;
#   ④ 端口判据改用 /proc/net/tcp{,6} 静态解析(最小读取, 不再 spawn netstat);
#   ⑤ mto 改 0.1s 轮询 + 有界 reap(D 态子进程不再永久阻塞看门狗);
#   ⑥ 心跳自证 /tmp/watchdog.beat 供 healthdog 二级监督; 启动 10 分钟做一次
#      boot.healthy 复检(健康漂移进 WARN, 不重复清 TRY_A);
#   ⑦ 工具故障明细落 /data/gw/logs/toolfaults.log(cmd/rc/pid/时间, 供归因).
# v1.26 (2026-10-19 stability batch1): 限时/服务监督初版.
# v1.25 (2026-10-19 SIGSEGV 根治轮): wan_agg 开机 180s 宽限期 — rc19 在启动
#   配方 ~60s 后才拉起 wan_agg, 看门狗 90s 周期曾抢跑拉出第二个实例(冷启动
#   实测两个 `sh wan_agg.sh` 并存, 双写路由)。宽限期内只记 SKIP 不算失败。
# v1.24 (2026-10-19 SIGSEGV 根治轮): spawn() 给子进程 stdin 接 /dev/null;
#   配合 led_mgr v2.7/dial_keeper v1.8 的"排除自身 pid"修复 — watchdog 预写
#   子进程 pid 到锁文件后, 守护不应把自己判成 duplicate 而退出。
# v1.23 (2026-10-19 SIGSEGV 根治轮): 单实例/自愈判据收紧 — 锁 pid 必须命中
#   本守护的绝对路径且非僵尸(旧判据 grep 子串, 锁 pid 被复用给含同名子串的
#   命令时会把死守护误判为活; led_mgr/dial_keeper/watchdog 三处同型修复)。
# v1.22: fault 判据加 aee db_history 行数增量 + core_trap 自愈 + dial_keeper
#   重启保留静态 PATH。
# v1.21: 用户态 fault 计数移出 $STATE(独立 /tmp/watchdog_faultcount)。
# v1.20: 自愈拉起统一走 alive() 双判据; 看门狗自身单实例锁; fan_mgr 补齐。
# v1.19: wan_agg 只检不拉补齐(静默死亡实弹).
# v1.18: hostapd 崩溃自愈(MLO 在线重应用配方, 限频 3 次/小时).
# v1.17: modem_reg/at_chan 失败附 COPS/CFUN 原文.
# v1.15: 失败检查附 rc/输出摘要; TICK/HEALTH 周期汇总.
# v1.12: +wan_eth 检查+自愈拉.
# v1.9: 告警灯从 WAN 灯迁 5G 橙灯(gpio473); WAN 灯写权单一化归 led_mgr.
# v1.7: mipc 探针硬超时; dial_keeper 心跳; led_mgr 自愈.
# v1.6: +log_keeper 自愈 + ql_wifi_sample 卡死清除.
# L13: "feature silently broken until manual inspection" countermeasure.
# Runs every 30s; failures log + ALERT LED flash (5G orange); recovers silently.

LOG=/tmp/watchdog.log
STATE=/tmp/watchdog_state
ALED=/sys/class/gpio/gpio473/value
CYCLE=30
MAX_LOG=800
CYC_TICK=0; QNODISC=""; LAST_EPOCH=""; LAST_UP=""
HEALTHY=/data/gw/boot.healthy
TOOL_LOG=/data/gw/logs/toolfaults.log

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

# ---- v1.27: bounded execution helpers ------------------------------------
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=
tmo() { # $1=seconds, $2...=command string; static busybox timeout when available
    _secs=$1; shift
    if [ -n "$BB" ]; then
        "$BB" timeout -s KILL "$_secs" sh -c "$*" 2>/dev/null
    else
        sh -c "$*" 2>/dev/null
    fi
}
# v1.27: tool fault = timeout/SIGKILL/SIGSEGV of the probing tool itself.
is_toolfault() { case "$1" in 124|137|139) return 0 ;; esac; return 1; }
toolfault() { # $1=what $2=rc $3=cmd $4=extra
    _l="$TOOL_LOG"
    [ -d /data/gw/logs ] || _l=/tmp/toolfaults.log
    echo "$(date '+%Y-%m-%d %H:%M:%S') epoch=$(date +%s) what=$1 rc=$2 pid=$$ up=$(cut -d. -f1 /proc/uptime) cmd=[$3] $4" >> "$_l"
    _sz=$(wc -c < "$_l" 2>/dev/null || echo 0)
    if [ "${_sz:-0}" -gt 262144 ]; then
        tail -n 400 "$_l" > "$_l.tmp" 2>/dev/null && mv "$_l.tmp" "$_l"
    fi
}
hb_age() { # $1=heartbeat file (uptime seconds); 999999 if missing/non-numeric
    _v=$(cat "$1" 2>/dev/null)
    _u=$(cut -d. -f1 /proc/uptime)
    case "$_v" in ''|*[!0-9]*) echo 999999 ;; *) echo $((_u - _v)) ;; esac
}
save_cmdline() { # $1=pid $2=file — cache a service restart recipe
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | sed 's/ $//' > "$2"
}
# v1.27: port liveness from /proc/net/tcp{,6} (hex local_address), no netstat.
port_listen() { # $1=port
    _hx=$(printf '%04X' "$1" 2>/dev/null)
    [ -n "$_hx" ] || return 1
    for _f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$_f" ] || continue
        awk -v p=":$_hx" '$4=="0A" && substr($2,length($2)-4)==p{f=1} END{exit(f?0:1)}' "$_f" 2>/dev/null && return 0
    done
    return 1
}
# v1.27: 3-consecutive-failure gate; destructive actions only when this returns 0.
strike() { # $1=key -> 0 when 3 consecutive failures reached
    _f=/tmp/watchdog_strike_$1; _n=$(cat "$_f" 2>/dev/null)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    _n=$((_n + 1)); echo "$_n" > "$_f"
    [ "$_n" -ge 3 ] && { rm -f "$_f"; return 0; }
    return 1
}
strike_clear() { rm -f /tmp/watchdog_strike_$1; }
# per-service restart rate limit: max 3 per hour (tmpfs; reboot resets)
rl_ok() { # $1=name
    _f=/tmp/watchdog_svc_$1.rec; _n=0; _t=0
    [ -r "$_f" ] && read _n _t < "$_f"
    _now=$(date +%s)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    case "$_t" in ''|*[!0-9]*) _t=$_now ;; esac
    [ $((_now - _t)) -gt 3600 ] && { _n=0; _t=$_now; }
    [ "$_n" -ge 3 ] && return 1
    echo "$((_n + 1)) $_t" > "$_f"
    return 0
}

# v1.20: 单实例判活 — SIGSEGV 家族里 pgrep/grep 自身也会被打死(实测), 仅凭 pgrep
#   会重复拉起(现场: 3×wan_eth / 2×log_keeper / 2×watchdog)。锁文件记的 pid 活着
#   且 /proc cmdline 复核匹配 → 视为在跑, 不再起第二个。
alive() { # $1=pgrep pattern  $2=lock name  $3=cmdline token
    pgrep -f "$1" >/dev/null 2>&1 && return 0
    _ap=$(cat /tmp/$2.lock 2>/dev/null)
    [ -n "$_ap" ] && kill -0 "$_ap" 2>/dev/null && \
        ! grep -q '^State:.*Z' /proc/$_ap/status 2>/dev/null && \
        grep -qa "/data/gw/$3" /proc/$_ap/cmdline 2>/dev/null && return 0
    return 1
}
spawn() { # $1=lock name  $2=log file  $3...=command
    _sl=$1; _so=$2; shift 2
    # v1.24: stdin 接 /dev/null — 被拉起的守护不再继承调用方的管道
    nohup "$@" >"$_so" 2>&1 </dev/null &
    echo $! > /tmp/$_sl.lock
}

# v1.9: 告警灯自举 — gpio473 由 led_mgr 管(已 export+out); 若 watchdog 先跑
#   (开机竞态), 这里补 export。写成 brightness 优先(class 节点不存在时回落 sysfs)。
alert_led_set() {
    if [ ! -d /sys/class/gpio/gpio473 ]; then
        echo 473 > /sys/class/gpio/export 2>/dev/null
    fi
    echo out > /sys/class/gpio/gpio473/direction 2>/dev/null
    echo "$1" > $ALED 2>/dev/null
}

# v1.7/v1.27: timeout 语义的 mipc 探针封装. 优先静态 busybox timeout;
#   回退路径 0.1s 轮询 + 有界 reap — D 态子进程 kill -9 无效时绝不无限 wait.
MTO=10
mto() {
    _tmp=/tmp/mto.$$
    if [ -n "$BB" ]; then
        "$BB" timeout -s KILL "$MTO" mipc_wan_cli "$@" >"$_tmp" 2>&1
        _rc=$?
        if [ "$_rc" = 124 ] || [ "$_rc" = 137 ]; then
            rm -f "$_tmp"
            log "WARN  mipc probe timeout(${MTO}s): $1"
            return 124
        fi
    else
        mipc_wan_cli "$@" >"$_tmp" 2>&1 & _mp=$!
        _i=0
        while [ "$_i" -lt $((MTO * 10)) ] && kill -0 $_mp 2>/dev/null; do
            sleep 1; _i=$((_i + 1))
        done
        if kill -0 $_mp 2>/dev/null; then
            kill -9 $_mp 2>/dev/null
            _j=0
            while [ "$_j" -lt 10 ] && kill -0 $_mp 2>/dev/null; do sleep 1; _j=$((_j + 1)); done
            rm -f "$_tmp"
            log "WARN  mipc probe timeout(${MTO}s): $1"
            return 124
        fi
        wait $_mp 2>/dev/null; _rc=$?
    fi
    cat "$_tmp" 2>/dev/null
    rm -f "$_tmp"
    return $_rc
}

# state helpers (track transitions, not absolutes)
set_state() {  # $1=key $2=0(ok)|1(fail) $3=label
    PREV=$(grep "^$1=" $STATE 2>/dev/null | tail -1 | cut -d= -f2)
    if [ "$2" != "$PREV" ]; then
        if [ "$2" = 1 ]; then
            log "FAIL  $3"
        else
            log "OK    $3 (recovered)"
        fi
        # upsert
        grep -v "^$1=" $STATE 2>/dev/null > $STATE.tmp
        echo "$1=$2" >> $STATE.tmp
        mv $STATE.tmp $STATE
    fi
}

# v1.27: bounded invariant check. Tool failures are retried and never counted
# as service failures on their own (they only feed the toolfault ledger).
check() {  # $1=key $2=check command  $3=label
    KEY=$1; CMD=$2; LABEL=$3
    _rc=1; _out=""; _try=1
    while [ "$_try" -le 3 ]; do
        _out=$(tmo 8 "$CMD"); _rc=$?
        [ "$_rc" -eq 0 ] && break
        is_toolfault "$_rc" || break
        sleep 1
        _try=$((_try + 1))
    done
    if [ "$_rc" -eq 0 ]; then
        set_state "$KEY" 0 "$LABEL"
    else
        set_state "$KEY" 1 "$LABEL"
        FAILS=$((FAILS+1))
        if is_toolfault "$_rc"; then
            TOOLFAILS=$((TOOLFAILS + 1))
            toolfault "$KEY" "$_rc" "$CMD" "retries=$_try"
            log "FAIL detail $KEY rc=$_rc toolfail=1 out=$(printf '%s' "$_out" | tr '\n' ' ' | head -c 160)"
        else
            log "FAIL detail $KEY rc=$_rc out=$(printf '%s' "$_out" | tr '\n' ' ' | head -c 160)"
        fi
    fi
}
# v1.27: in-shell port check (port_listen is a function, cannot run via tmo).
check_port() { # $1=key $2=port $3=label
    if port_listen "$2"; then
        set_state "$1" 0 "$3"
    else
        set_state "$1" 1 "$3"
        FAILS=$((FAILS+1))
        log "FAIL detail $1 out=no listener on :$2 (/proc/net/tcp)"
    fi
}

# v1.27: unified supervision for script daemons.
# Columns: name|pgrep-pattern|lock-token|recipe|heartbeat|max-hb-age
SVC_TABLE='
ntp_keeper|ntp_keeper[.]sh|ntp_keeper.sh|sh /data/gw/ntp_keeper.sh|/tmp/ntp_keeper.hb|600
traffic_logger|traffic_logger[.]sh|traffic_logger.sh|sh /data/gw/traffic_logger.sh|/tmp/traffic_logger.hb|900
wifi_guard|wifi_guard[.]sh|wifi_guard.sh|sh /data/gw/wifi_guard.sh|/tmp/wifi_guard.hb|90
reboot_sched|reboot_sched[.]sh|reboot_sched.sh|sh /data/gw/reboot_sched.sh|/tmp/reboot_sched.hb|900
led_mgr|led_mgr[.]sh|led_mgr.sh|sh /data/gw/led_mgr.sh|/tmp/led_mgr.hb|60
fan_mgr|fan_mgr[.]sh|fan_mgr.sh|sh /data/gw/fan_mgr.sh|/tmp/fan_mgr.hb|60
wan_eth|wan_eth[.]sh|wan_eth.sh|sh /data/gw/wan_eth.sh|/tmp/wan_eth.hb|150
log_keeper|log_keeper[.]sh|log_keeper.sh|sh /data/gw/log_keeper.sh|/tmp/log_keeper.hb|180
core_trap|core_trap[.]sh|core_trap.sh|sh /data/gw/core_trap.sh|/tmp/core_trap.hb|600
healthdog|healthdog[.]sh|healthdog.sh|sh /data/gw/healthdog.sh|/tmp/healthdog.hb|60
'
svc_supervise() { # $1=name $2=pattern $3=lock $4=recipe $5=hb $6=maxage
    _sn=$1; _sp=$2; _st=$3; _sc=$4; _shb=$5; _smax=$6
    _hb=999999
    [ -n "$_shb" ] && _hb=$(hb_age "$_shb")
    _live=0
    alive "$_sp" "$_sn" "$_st" && _live=1
    # boot grace: rc19 owns first-boot startup; do not race or cry wolf
    if [ "$UP" -lt 240 ]; then
        [ "$_live" = 1 ] && set_state "$_sn" 0 "$_sn (boot)"
        return 0
    fi
    if [ "$_live" = 1 ] && [ "$_hb" -le "$_smax" ]; then
        set_state "$_sn" 0 "$_sn"
        strike_clear "$_sn"
        return 0
    fi
    set_state "$_sn" 1 "$_sn"
    FAILS=$((FAILS + 1))
    if [ "$_live" = 1 ]; then
        log "WARN  $_sn heartbeat stale (${_hb}s > ${_smax}s) — process alive, counting"
    else
        log "WARN  $_sn not running (hb=${_hb}s)"
    fi
    strike "$_sn" || { log "SKIP  $_sn recovery (confirmation 1/3)"; return 0; }
    if rl_ok "$_sn"; then
        _oldpid=$(cat /tmp/$_sn.lock 2>/dev/null)
        if [ -n "$_oldpid" ] && kill -0 "$_oldpid" 2>/dev/null && \
           grep -qa "/data/gw/$_st" /proc/$_oldpid/cmdline 2>/dev/null; then
            kill -9 "$_oldpid" 2>/dev/null
            log "EVT $_sn stale instance pid=$_oldpid killed before restart"
        fi
        log "EVT restart $_sn (live=$_live hb=${_hb}s recipe=[$_sc])"
        # v1.27: run a plain "sh /data/gw/<script>" recipe directly (no sh -c
        # wrapper) so $! is the script's own pid and its single-instance lock
        # matches the pid the watchdog remembers.
        case "$_sc" in
        "sh /data/gw/"*) spawn "$_sn" /tmp/$_sn.out sh "/data/gw/$_st" ;;
        *)               spawn "$_sn" /tmp/$_sn.out sh -c "$_sc" ;;
        esac
        logger -t watchdog "restarted $_sn"
    else
        log "WARN  $_sn restart budget exhausted (3/h) — alert only"
    fi
}

run_cycle() {
    FAILS=0
    TOOLFAILS=0
    UP=$(cut -d. -f1 /proc/uptime)
    # v1.15: 时钟跳变检测 — NTP 校时/回拨会让本地时间戳不可跨段比较; epoch 与
    #   uptime 增量不一致即留痕(设备无 RTC, 开机曾出现 8h 跳变)。
    _NOW=$(date +%s)
    if [ -n "$LAST_EPOCH" ] && [ -n "$LAST_UP" ]; then
        _de=$(( _NOW - LAST_EPOCH )); _du=$(( UP - LAST_UP ))
        _dd=$(( _de - _du )); [ $_dd -lt 0 ] && _dd=$(( -_dd ))
        [ "$_dd" -gt 5 ] && log "EVT clock jump: epoch +${_de}s vs uptime +${_du}s (skew ${_dd}s)"
    fi
    LAST_EPOCH=$_NOW; LAST_UP=$UP

    # ---- process invariants (pidof 比 pgrep -x 更可靠, busybox -x 有怪癖) ----
    # v1.27: 服务本体统一走下方监督表/专用块; 这里只做静态不变量.
    check mipc_tool "[ -x /data/gw/mipc_cellular ]"  "cellular direct tool"
    check ccmni_up  "[ -x /data/gw/ccmni_up.sh ]"    "ccmni landing tool"
    check bootgate  "[ -x /data/gw/boot_gate.sh ]"   "boot health gate tool"
    check coremeta  "[ -x /data/gw/core_meta.sh ]"   "core metadata wrapper"

    # ---- data plane invariants ----
    check agg_rules "iptables -t mangle -S WANAGG 2>/dev/null | grep -q MARK" "split rules installed"
    check fwmark    "ip rule | grep -q fwmark"       "fwmark policy routing"
    check nat       "iptables -t nat -S POSTROUTING | grep -q MASQ"  "NAT masquerade"
    check bss       "[ \$(iw dev 2>/dev/null | grep -c 'type AP') -ge 2 ]"  "2+ BSS active"
    check_port port80 80 "GUI :80 reachable"
    check_port port22 22 "SSH :22 reachable"
    if [ -f /tmp/boot.done ]; then
        set_state boot 0 "boot chain complete"
    elif [ "$UP" -lt 600 ]; then
        set_state boot 0 "boot chain in progress"
    else
        check boot "[ -f /tmp/boot.done ]" "boot chain complete"
    fi
    check lan_ip    "ip -4 addr show br-lan | grep -q inet"  "LAN IP present"
    check lo_up     "ip link show lo | grep -q 'LOOPBACK,UP'" "loopback up"

    # ---- dial_keeper: hb + lock (v1.7/v1.8 semantics preserved) ----
    _dhb=$(cat /tmp/dial_keeper.hb 2>/dev/null)
    _dstale=0
    case "$_dhb" in
    ''|*[!0-9]*) [ "${UP:-0}" -gt 300 ] && _dstale=1 ;;
    *) [ $((UP - _dhb)) -gt 90 ] && _dstale=1 ;;
    esac
    _kp=$(cat /tmp/dial_keeper.lock 2>/dev/null)
    _kalive=0
    if [ -n "$_kp" ] && kill -0 "$_kp" 2>/dev/null \
       && ! grep -q '^State:.*Z' /proc/$_kp/status 2>/dev/null \
       && grep -qa '/data/gw/dial_keeper.sh' /proc/$_kp/cmdline 2>/dev/null; then
        _kalive=1
    elif pgrep -f 'dial_keepe[r].sh' >/dev/null 2>&1; then
        _kalive=1
    fi
    if [ "$_kalive" = 1 ] && [ "$_dstale" = 0 ]; then
        set_state keeper 0 "dial keeper"
        strike_clear dial_keeper
    else
        if [ "$_dstale" = 1 ]; then
            log "WARN  stale dial_keeper heartbeat (hb=${_dhb:-none} up=${UP}) — counting"
        fi
        set_state keeper 1 "dial keeper"
        FAILS=$((FAILS+1))
        if strike dial_keeper; then
            log "EVT restart dial_keeper (alive=$_kalive stale=$_dstale old_pid=${_kp:-none} hb=${_dhb:-none} up=${UP})"
            if [ -n "$_kp" ] && kill -0 "$_kp" 2>/dev/null \
               && ! grep -q '^State:.*Z' /proc/$_kp/status 2>/dev/null \
               && grep -qa '/data/gw/dial_keeper.sh' /proc/$_kp/cmdline 2>/dev/null; then
                kill -9 "$_kp" 2>/dev/null
            fi
            export LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib
            export PATH=/data/gw/sbin:/data/gw/bin:/usr/sbin:/usr/bin:/sbin:/bin:/fhrom/bin:/fhrom/fhshell
            nohup sh /data/gw/dial_keeper.sh >/dev/null 2>&1 &
        else
            log "SKIP  dial_keeper recovery (confirmation 1/3)"
        fi
    fi

    # ---- dnsmasq: process + :53 listener, restart from cached cmdline ----
    _dp=$(pidof dnsmasq 2>/dev/null)
    if [ -n "$_dp" ] && port_listen 53; then
        set_state dnsmasq 0 "DHCP/DNS"
        strike_clear dnsmasq
        save_cmdline "${_dp%% *}" /tmp/watchdog_dnsmasq.cmd 2>/dev/null
    else
        set_state dnsmasq 1 "DHCP/DNS"
        FAILS=$((FAILS+1))
        log "WARN  dnsmasq unhealthy (pid=${_dp:-none} :53=$(port_listen 53 && echo y || echo n))"
        if strike dnsmasq; then
            if rl_ok dnsmasq; then
                [ -n "$_dp" ] && kill -9 $_dp 2>/dev/null
                if [ -s /tmp/watchdog_dnsmasq.cmd ]; then
                    log "EVT restart dnsmasq (cached cmdline)"
                    spawn dnsmasq /tmp/dnsmasq.out sh -c "$(cat /tmp/watchdog_dnsmasq.cmd)"
                else
                    log "EVT restart dnsmasq (rc19 recipe)"
                    . /data/gw/defaults.conf 2>/dev/null; . /data/gw/settings.conf 2>/dev/null
                    spawn dnsmasq /tmp/dnsmasq.out sh -c "dnsmasq -p 53 --no-resolv --server=223.5.5.5 --server=119.29.29.29 --stop-dns-rebind --bogus-priv -i br-lan -I lo -F ${DHCP_R1:-192.168.9.100},${DHCP_R2:-192.168.9.200},255.255.255.0,${DHCP_LEASE:-12h} --dhcp-option=3,192.168.9.1 --dhcp-option=6,192.168.9.1 --dhcp-leasefile=/tmp/dnsmasq_br.leases -x /var/run/dnsmasd_br.pid"
                fi
            else
                log "WARN  dnsmasq restart budget exhausted (3/h) — alert only"
            fi
        else
            log "SKIP  dnsmasq recovery (confirmation 1/3)"
        fi
    fi

    # ---- dropbear: process + :22 listener ----
    if pidof dropbear >/dev/null 2>&1 && port_listen 22; then
        set_state dropbear 0 "SSH"
        strike_clear dropbear
        _dbp=$(pidof dropbear 2>/dev/null)
        [ -n "$_dbp" ] && save_cmdline "${_dbp%% *}" /tmp/watchdog_dropbear.cmd 2>/dev/null
    else
        set_state dropbear 1 "SSH"
        FAILS=$((FAILS+1))
        log "WARN  dropbear unhealthy (pid=$(pidof dropbear 2>/dev/null || echo none) :22=$(port_listen 22 && echo y || echo n))"
        if strike dropbear; then
            if rl_ok dropbear; then
                _old=$(pidof dropbear 2>/dev/null)
                [ -n "$_old" ] && kill -9 $_old 2>/dev/null
                if [ -s /tmp/watchdog_dropbear.cmd ]; then
                    log "EVT restart dropbear (cached cmdline)"
                    spawn dropbear /dev/null sh -c "$(cat /tmp/watchdog_dropbear.cmd)"
                else
                    log "EVT restart dropbear (rc.extend recipe)"
                    [ -s /data/gw/dropbear_keys/rsa ] || \
                        /usr/bin/dropbearkey -t rsa -f /data/gw/dropbear_keys/rsa -s 2048 2>/dev/null
                    spawn dropbear /dev/null /usr/sbin/dropbear -r /data/gw/dropbear_keys/rsa -p 22
                fi
            else
                log "WARN  dropbear restart budget exhausted (3/h) — alert only"
            fi
        else
            log "SKIP  dropbear recovery (confirmation 1/3)"
        fi
    fi

    # ---- v3httpd: process + :80 listener ----
    if pidof v3httpd >/dev/null 2>&1 && port_listen 80; then
        set_state v3httpd 0 "GUI httpd"
        strike_clear v3httpd
    else
        set_state v3httpd 1 "GUI httpd"
        FAILS=$((FAILS+1))
        log "WARN  v3httpd unhealthy (pid=$(pidof v3httpd 2>/dev/null || echo none) :80=$(port_listen 80 && echo y || echo n))"
        if strike v3httpd; then
            if rl_ok v3httpd; then
                _old=$(pidof v3httpd 2>/dev/null)
                [ -n "$_old" ] && kill -9 $_old 2>/dev/null
                log "EVT restart v3httpd"
                spawn v3httpd /dev/null /data/gw/v3httpd
            else
                log "WARN  v3httpd restart budget exhausted (3/h) — alert only"
            fi
        else
            log "SKIP  v3httpd recovery (confirmation 1/3)"
        fi
    fi

    # ---- uplink auth (generic AUTHD_CMD; no private syntax here) ----
    _aen=$(sed -n 's/^ENABLE=//p' /data/gw/uplink.conf 2>/dev/null | tail -1)
    _acmd=$(sed -n 's/^AUTHD_CMD=//p' /data/gw/uplink.conf 2>/dev/null | tail -1)
    if [ "$_aen" = "1" ] && [ -n "$_acmd" ]; then
        _apid=$(pidof authd 2>/dev/null | awk '{print $1}')
        _ast=$(awk '{print $2}' /tmp/authd_state 2>/dev/null)
        case "$_ast" in ''|*[!0-9]*) _ast="" ;; esac
        if [ -n "$_apid" ] && [ -n "$_ast" ] && [ $((_NOW - _ast)) -lt 300 ]; then
            set_state authd 0 "uplink auth"
            strike_clear authd
        elif [ "$UP" -lt 240 ]; then
            set_state authd 0 "uplink auth (boot pending)"
        else
            set_state authd 1 "uplink auth"
            FAILS=$((FAILS+1))
            log "WARN  authd unhealthy (pid=${_apid:-none} state_age=$((_NOW - ${_ast:-_NOW}))s)"
            if strike authd; then
                if rl_ok authd; then
                    [ -n "$_apid" ] && kill -9 "$_apid" 2>/dev/null
                    log "EVT restart authd"
                    spawn authd /dev/null sh -c "$_acmd"
                else
                    log "WARN  authd restart budget exhausted (3/h) — alert only"
                fi
            else
                log "SKIP  authd recovery (confirmation 1/3)"
            fi
        fi
    fi

    # ---- unified script-daemon table (v1.27) ----
    while IFS='|' read -r _n _p _t _r _hb _mx; do
        [ -z "$_n" ] && continue
        svc_supervise "$_n" "$_p" "$_t" "$_r" "$_hb" "$_mx"
    done <<EOF
$(printf '%s\n' "$SVC_TABLE" | sed '/^[[:space:]]*$/d')
EOF

    # ---- hostapd: WPA layer; 3-strike + tool-fault separation ----
    _ha=0; _htool=0; _hrc=0
    if pgrep -f 'hostapd -B' >/dev/null 2>&1; then
        _try=1
        while [ "$_try" -le 3 ]; do
            _hs=$(tmo 5 "hostapd_cli -i ra0 status"); _hrc=$?
            printf '%s' "$_hs" | grep -q '^state=ENABLED' && { _ha=1; break; }
            is_toolfault "$_hrc" || break
            _htool=1
            toolfault hostapd_cli "$_hrc" "hostapd_cli -i ra0 status" "retry=$_try"
            sleep 2
            _try=$((_try + 1))
        done
    fi
    if [ "$_ha" = 1 ]; then
        set_state hostapd 0 "hostapd WPA layer"
        strike_clear hostapd
    elif [ "$_htool" = 1 ] && pgrep -f 'hostapd -B' >/dev/null 2>&1; then
        # control path unusable but daemon alive: retry-safe, alert-only
        set_state hostapd 1 "hostapd WPA layer (control tool failed)"
        FAILS=$((FAILS + 1)); TOOLFAILS=$((TOOLFAILS + 1))
        log "SKIP  hostapd recovery (control tool timeout/segv rc=$_hrc; alert only)"
    elif pgrep -f 'wifi_up[.]sh' >/dev/null 2>&1 || [ "$UP" -lt 240 ]; then
        set_state hostapd 1 "hostapd WPA layer"
        FAILS=$((FAILS+1))
        log "SKIP  hostapd recovery (boot or wifi_up in progress)"
    else
        set_state hostapd 1 "hostapd WPA layer"
        FAILS=$((FAILS+1))
        log "WARN  hostapd not ENABLED (pid=$(pgrep -f 'hostapd -B' | tr '\n' ' '))"
        if strike hostapd; then
            _hn=0; _ht=0
            [ -r /tmp/watchdog_hostapd.rec ] && read _hn _ht < /tmp/watchdog_hostapd.rec
            _now2=$(date +%s)
            case "$_hn" in ''|*[!0-9]*) _hn=0 ;; esac
            case "$_ht" in ''|*[!0-9]*) _ht=$_now2 ;; esac
            [ $((_now2 - _ht)) -gt 3600 ] && { _hn=0; _ht=$_now2; }
            # independent confirmation before touching the radios
            _sock=0
            for _s in /var/run/hostapd/ra0 /var/run/hostapd/rai0 /var/run/wpa_supplicant/ra0; do
                [ -S "$_s" ] && _sock=1
            done
            _clients=$(iw dev ra0 station dump 2>/dev/null | grep -c '^Station')
            if [ "$_hn" -lt 3 ] && [ "$_sock" = 1 ]; then
                _hn=$((_hn + 1)); echo "$_hn $_ht" > /tmp/watchdog_hostapd.rec
                log "EVT recover hostapd (attempt $_hn/3 this hour; clients=$_clients ctrl_sock=$_sock live=$(pgrep -f 'hostapd -B' | tr '\n' ' '))"
                for _p in $(pgrep -f 'hostapd -B' 2>/dev/null); do kill $_p 2>/dev/null; done
                for _v in ra0 rai0 ra1 rai1; do ifconfig $_v down 2>/dev/null; done
                sleep 3
                brctl addif br-lan ra0 2>/dev/null
                brctl addif br-lan rai0 2>/dev/null
                LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib \
                    hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf >>/tmp/watchdog.log 2>&1
                sleep 5
                for _v in ra0 rai0; do mwctl dev $_v set no_bcn 0 >/dev/null 2>&1; done
                _hs=$(tmo 5 "hostapd_cli -i ra0 status"); _hrc=$?
                if printf '%s' "$_hs" | grep -q '^state=ENABLED'; then
                    log "OK    hostapd recovered (ra0 ENABLED; clients=$_clients must re-associate)"
                    set_state hostapd 0 "hostapd WPA layer"
                elif is_toolfault "$_hrc"; then
                    log "WARN  hostapd recovery verification tool failed rc=$_hrc — alert only"
                    TOOLFAILS=$((TOOLFAILS + 1))
                else
                    log "FAIL  hostapd recovery did not reach ENABLED"
                fi
            elif [ "$_sock" = 0 ]; then
                log "WARN  hostapd down but no control socket — refusing RF bounce (alert only)"
            else
                log "WARN  hostapd down; recovery budget exhausted (3/h) — alert only"
            fi
        else
            log "SKIP  hostapd recovery (confirmation 1/3)"
        fi
    fi

    # ---- wan_agg: wan_alive freshness + boot grace (v1.25 semantics) ----
    _wa_ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' /tmp/wan_alive 2>/dev/null)
    _wa_age=999999
    [ -n "$_wa_ts" ] && _wa_age=$(( _NOW - _wa_ts ))
    _wastale=0
    [ "$UP" -gt 240 ] && [ "$_wa_age" -gt 120 ] && _wastale=1
    if [ "$_wastale" = 0 ] && alive 'wan_agg[.]sh' wan_agg wan_agg.sh; then
        set_state wan_agg 0 "aggregation supervisor"
        strike_clear wan_agg
    elif [ "$UP" -lt 240 ]; then
        set_state wan_agg 0 "aggregation supervisor (boot pending)"
        log "SKIP  wan_agg recovery (boot in progress; rc19 owns startup)"
    else
        set_state wan_agg 1 "aggregation supervisor"
        FAILS=$((FAILS+1))
        log "WARN  wan_agg unhealthy (stale=$_wastale age=${_wa_age}s wan_alive=$(cat /tmp/wan_alive 2>/dev/null))"
        if strike wan_agg; then
            if rl_ok wan_agg; then
                _wap=$(cat /tmp/wan_agg.lock 2>/dev/null)
                if [ -n "$_wap" ] && kill -0 "$_wap" 2>/dev/null \
                   && grep -qa '/data/gw/wan_agg.sh' /proc/$_wap/cmdline 2>/dev/null; then
                    kill -9 "$_wap" 2>/dev/null
                fi
                log "EVT restart wan_agg (stale=$_wastale age=${_wa_age}s)"
                spawn wan_agg /tmp/wagg.out sh /data/gw/wan_agg.sh
                logger -t watchdog "restarted wan_agg"
            else
                log "WARN  wan_agg restart budget exhausted (3/h) — alert only"
            fi
        else
            log "SKIP  wan_agg recovery (confirmation 1/3)"
        fi
    fi

    # ---- boot health gate supervision (v1.27) ----
    # Before boot.healthy exists the gate is boot-critical: restart it if dead.
    # Once healthy, re-verify at the 10-minute mark; drift is reported only
    # (services are repaired by their own supervision; TRY_A is not re-cleared).
    if [ ! -f "$HEALTHY" ] && [ "$UP" -lt 900 ]; then
        if alive 'boot_gate[.]sh' bootgate boot_gate.sh; then
            set_state bootgate 0 "boot health gate"
        else
            set_state bootgate 1 "boot health gate"
            FAILS=$((FAILS+1))
            if strike bootgate; then
                log "EVT restart boot_gate (no live instance before healthy)"
                spawn bootgate /tmp/boot_gate.out sh /data/gw/boot_gate.sh
            else
                log "SKIP  boot_gate recovery (confirmation 1/3)"
            fi
        fi
    fi
    if [ -f "$HEALTHY" ] && [ "$UP" -ge 600 ] && [ "$UP" -lt 690 ] && [ ! -f /tmp/watchdog_bootrecheck ]; then
        : > /tmp/watchdog_bootrecheck
        _gate=$(tmo 60 "/data/gw/boot_gate.sh --check"); _grc=$?
        if [ "$_grc" -eq 0 ]; then
            log "OK    boot.healthy re-check at ${UP}s: all gate checks still pass"
        else
            log "WARN  boot.healthy drift at ${UP}s rc=$_grc: $(printf '%s' "$_gate" | tr '\n' ' ' | head -c 200)"
        fi
    fi

    # ql_wifi_sample 卡死清除(L28): stdin EOF 后死循环刷 syslog(实测 3700 行/s,
    #   日志环被冲至 18s 深)。CPU 累计 >=120s 即杀(交互等待不耗 CPU, 不误伤)
    for _p in $(pgrep -f ql_wifi_sampl[e] 2>/dev/null); do
        _cpu=$(awk '{print int(($14 + $15) / 100)}' /proc/$_p/stat 2>/dev/null)
        if [ -n "$_cpu" ] && [ "$_cpu" -ge 120 ]; then
            kill $_p 2>/dev/null
            log "WARN  killed stuck ql_wifi_sample pid=$_p (cpu=${_cpu}s)"
        fi
    done
    # atcid: AT 通道本体; 死则拉起 (替代厂商 procd respawn)
    if pidof atcid >/dev/null 2>&1; then
        set_state atcid 0 "atcid daemon"
    else
        set_state atcid 1 "atcid daemon"
        FAILS=$((FAILS+1))
        log "EVT restart atcid (no live instance)"
        /usr/bin/atcid >/var/atcid.log 2>&1 &
    fi
    # CFUN 探测同时充当通道活性探针; airplane(CFUN:4)时跳过注册态断言
    CFUNR=$(mto --at_cmd 'AT+CFUN?' 2>/dev/null)
    case "$CFUNR" in
    *"CFUN: 4"*)
        set_state at_chan 0 "AT channel (airplane, probe-only)"
        set_state modem_reg 0 "modem registered (airplane, skipped)"
        ;;
    *"CFUN: "*)
        set_state at_chan 0 "AT channel (CFUN responds)"
        # 注册态: +COPS: <mode>,<fmt>,"<numeric>"  -- 含引号即已注册
        COPSR=$(mto --at_cmd 'AT+COPS?' 2>/dev/null)
        case "$COPSR" in
        *'"'*) set_state modem_reg 0 "modem registered" ;;
        *)     set_state modem_reg 1 "modem NOT registered"
               log "FAIL detail modem_reg out=$(printf '%s' "$COPSR" | tr '\n' ' ' | head -c 160)"
               FAILS=$((FAILS+1)) ;;
        esac
        ;;
    *)  # 连 CFUN 都不回 = 通道死
        set_state at_chan 1 "AT channel DEAD (no CFUN response)"
        log "FAIL detail at_chan out=$(printf '%s' "$CFUNR" | tr '\n' ' ' | head -c 160)"
        FAILS=$((FAILS+1))
        set_state modem_reg 1 "modem state unknown (AT dead)"
        log "FAIL detail modem_reg out=AT channel dead"
        FAILS=$((FAILS+1))
        ;;
    esac

    # ---- incremental events ----
    BCN=$(dmesg | grep -cE 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
    BCN_PREV=$(grep '^beacon=' $STATE 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$BCN_PREV" ] && [ "$BCN" -gt "$BCN_PREV" ] 2>/dev/null; then
        log "WARN  beacon events +$((BCN-BCN_PREV))"
    fi
    grep -v '^beacon=' $STATE 2>/dev/null > $STATE.tmp
    echo "beacon=$BCN" >> $STATE.tmp
    mv $STATE.tmp $STATE

    # ---- v1.20: SIGSEGV 家族可见化 ----
    FLT=$(dmesg | grep -c 'unhandled exception')
    FLT_PREV=$(cat /tmp/watchdog_faultcount 2>/dev/null)
    if [ -n "$FLT_PREV" ] && [ "$FLT" -gt "$FLT_PREV" ] 2>/dev/null; then
        log "WARN  user-fault +$((FLT-FLT_PREV)) (ring total $FLT) — SIGSEGV family"
    fi
    echo "$FLT" > /tmp/watchdog_faultcount

    # ---- v1.22: aee NE 台账增量 (P4) + v1.27 census 进程名 ----
    AEEH=/data/log/aee_exp/db_history
    if [ -r "$AEEH" ]; then
        AEE_N=$(wc -l < "$AEEH" 2>/dev/null)
        AEE_PREV=$(cat /tmp/watchdog_aeecount 2>/dev/null)
        case "$AEE_N" in ''|*[!0-9]*) AEE_N=0 ;; esac
        case "$AEE_PREV" in ''|*[!0-9]*) AEE_PREV=$AEE_N ;; esac
        if [ "$AEE_N" -gt "$AEE_PREV" ]; then
            _cen=$(tail -n 1 /data/gw/logs/ne_census.tsv 2>/dev/null | tr '\t' ' ')
            log "WARN  aee NE +$((AEE_N-AEE_PREV)) (total $AEE_N): $(tail -n 1 "$AEEH" 2>/dev/null) census=[${_cen:-pending}]"
        fi
        echo "$AEE_N" > /tmp/watchdog_aeecount
    fi

    # ---- wifi channel consistency (v1.5) ----
    for _b in 2g 5g; do
        [ "$_b" = 2g ] && _vif=ra0 || _vif=rai0
        _cfc=/var/wlan/hap_$_b.conf
        [ -r "$_cfc" ] || continue
        _lc=$(iw dev $_vif info 2>/dev/null | awk '/channel/{print $2}')
        _cc=$(grep -m1 '^channel=' $_cfc 2>/dev/null | cut -d= -f2)
        if [ -n "$_lc" ] && [ -n "$_cc" ] && [ "$_lc" != "$_cc" ]; then
            sed -i "s/^channel=.*/channel=$_lc/" $_cfc 2>/dev/null
            log "WARN  wifi $_b channel drift: conf=$_cc live=$_lc -> adopted live"
        fi
    done

    # ---- cellular stats divergence guard (v1.10) ----
    CIF=$(ip -o -4 addr show 2>/dev/null | grep -m1 'ccmni.*inet' | awk '{print $2}')
    if [ -n "$CIF" ]; then
        CN=$(cat /sys/class/net/$CIF/statistics/tx_bytes 2>/dev/null || echo 0)
        CQ=$(tc -s qdisc show dev $CIF 2>/dev/null | awk '/Sent/{print $2; exit}')
        if [ -z "$CQ" ]; then
            CQ=$CN
            [ "$QNODISC" = 1 ] || { log "WARN qdisc Sent missing on $CIF (cold boot/no qdisc) -> netdev fallback"; QNODISC=1; }
        else
            [ "$QNODISC" = 1 ] && { log "EVT qdisc Sent restored on $CIF"; QNODISC=""; }
        fi
        if [ -r /tmp/cellstat_prev ]; then
            . /tmp/cellstat_prev
            DN=$((CN - PN)); [ $DN -lt 0 ] && DN=$CN
            DQ=$((CQ - PQ)); [ $DQ -lt 0 ] && DQ=$CQ
            GAP=$((DN - DQ))
            [ "$GAP" -gt 262144 ] && \
                log "WARN  cell stats divergence on $CIF: netdev +${DN}B vs linux-path +${DQ}B (gap ${GAP}B)"
        fi
        echo "PN=$CN; PQ=$CQ" > /tmp/cellstat_prev
    fi

    # ---- cellular query path liveness (v1.11) ----
    CQ_TICK=$(( ${CQ_TICK:-0} + 1 ))
    if [ $((CQ_TICK % 10)) -eq 1 ]; then
        _co=$(tmo 10 "/data/gw/mipc_cellular cells"); _crc=$?
        printf '%s' "$_co" | grep -q '"serving"' || \
            log "WARN  cell query path dead (rc=$_crc len=${#_co} out=$(printf '%s' "$_co" | tr '\n' ' ' | head -c 100)) — 直连 MIPC 查询失败(数据面可能正常); 恢复见 docs/FINDINGS §27/§29"
    fi

    # ---- v1.15: periodic summaries (24h 分析主干) ----
    CYC_TICK=$((CYC_TICK + 1))
    if [ $((CYC_TICK % 2)) -eq 0 ] || [ "$FAILS" -gt 0 ]; then
        log "TICK epoch=$(date +%s) fails=$FAILS toolfails=${TOOLFAILS:-0} up=${UP}s healthy=$([ -f "$HEALTHY" ] && echo y || echo n) state=[$(tr '\n' ' ' < $STATE 2>/dev/null)]"
    fi
    if [ $((CYC_TICK % 10)) -eq 0 ]; then
        _load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
        _mf=$(awk '/^MemFree:/{print $2}' /proc/meminfo 2>/dev/null)
        _ma=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
        _df=$(df -k /data 2>/dev/null | tail -1 | awk '{print $4}')
        _tf=$(df -k /tmp 2>/dev/null | tail -1 | awk '{print $4}')
        _np=$(ls /proc 2>/dev/null | grep -c '^[0-9]')
        _nz=$(ps 2>/dev/null | awk '$4 ~ /^Z/{n++} END{print n+0}')
        _ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
        log "HEALTH epoch=$(date +%s) up=${UP}s load=$_load memfree=${_mf:-?}KB memavail=${_ma:-?}KB data_free=${_df:-?}KB tmp_free=${_tf:-?}KB procs=$_np zombies=$_nz conntrack=${_ct:-n/a} cell_if=${CIF:-none} netdev=${CN:-0} qdisc=${CQ:-0}"
        [ "${_df:-0}" -lt 102400 ] 2>/dev/null && log "WARN /data free low: ${_df}KB (<100MB)"
    fi

    # ---- visual alert ----
    if [ "$FAILS" -gt 0 ]; then
        for i in 1 2 3; do
            alert_led_set 1; sleep 1
            alert_led_set 0; sleep 1
        done
        log "WARN  visual alert: $FAILS check(s) failing"
    fi

    # v1.27: independent liveness beacon (healthdog.sh second-level supervisor)
    echo "$UP" > /tmp/watchdog.beat 2>/dev/null

    # ---- log truncation ----
    LINES=$(wc -l < $LOG 2>/dev/null || echo 0)
    if [ "$LINES" -gt "$MAX_LOG" ]; then
        tail -n $((MAX_LOG/2)) $LOG > $LOG.tmp 2>/dev/null && mv $LOG.tmp $LOG
    fi
}

# ---- main ----
touch $LOG $STATE
# v1.20: 看门狗单实例 — 双实例会重复自愈/告警(现场曾出现 2 个)
_wp=$(cat /tmp/watchdog.lock 2>/dev/null)
if [ -n "$_wp" ] && [ "$_wp" != "$$" ] && kill -0 "$_wp" 2>/dev/null && \
   ! grep -q '^State:.*Z' /proc/$_wp/status 2>/dev/null && \
   grep -qa '/data/gw/watchdog.sh' /proc/$_wp/cmdline 2>/dev/null; then
    echo "watchdog: already running pid=$_wp" >&2
    exit 0
fi
echo $$ > /tmp/watchdog.lock
log "===== watchdog v1.27 start (bounded checks + 3-strike recovery + unified service table + /proc port probes + boot.healthy recheck; alert LED 5G orange) ====="
logger -t watchdog "watchdog v1.27 start"
# initialize state to current (suppress initial alarms)
run_cycle  # first run logs transitions but that's fine
while :; do
    sleep $CYCLE
    run_cycle
done
