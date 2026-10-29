#!/bin/sh
# watchdog.sh v1.37 -- on-device continuous invariant monitor.
# v1.37 (2026-10-29 feat.usb 轮): 重启配方 "sh /data/gw/<script> <args>" 不再丢参数 ——
#   原快路径只取脚本路径, usb_mgr 的 "daemon" 被吃掉 -> 每次重启只打 usage 就退出 ->
#   3 次耗尽预算 -> 服务永久 down(实测 06:26-11:50)。
# v1.36 (2026-10-29 断网轮): +netlock 判决键 —— netcfg 写锁连续 3 轮(90s)被占即判
#   泄漏(正常写方最长 <1s), 记 FAIL detail + 轮转锁文件自救(每小时最多 3 次);
#   实弹: radvd 在锁内被 spawn 继承 flock fd 持锁 2h, 家宽断链时 failover 全超时。
# v1.35 (2026-10-28 探针误判修正): dp5g 改 3 包探针(-c3 -W1, 任一回即通) ——
#   实测蜂窝 SINR -11dB/5% 随机丢包, 单包探针每小时误判 ~10 次, 配合采样器的
#   '窗口内任一次 FAIL 即整窗 deg' 把 5% 丢包放大成 ~80% 时间降级; 3 包后随机
#   丢包误判率 5%->0.0125%, 真中断(连丢 3)仍判得出。radvd 键改由
#   v6_reconcile.sh check 判定(区分'配置关闭'与'该在没在'), 并每 4 轮兜底收敛。
# v1.34 (防假绿修正): dp5g 探针改"任一带 IP 的 ccmni 可通"(irat 承载切换实弹:
#   09:46 ccmni2→ccmni3, 探针锚死旧口=假红; 绝对路径去 PATH 变量)。
# v1.33 (防假绿轮): +http200/dnssvc/dp5g/dpeth 结果探针键(监听≠在服务/IP 在≠
#   数据面通 — 四次历史全绿谎言的判据级根治, 见 AVAILABILITY_DESIGN §8)。
# v1.32 (同轮修正): radvd 键无 ULA(未部署 v6)时 pass — 键=1 只表示已部署而
#   守护死(v4-only 上行不再误报)。
# v1.31 (2026-10-25 可用性轮): +bss2g/bss5g/bss_guest/radvd 判决键(纯 set_state
#   行, 供 avail_sampler 分频组件; 旧 bss 键保留)+每轮 cycle=<epoch> 新鲜度键
#   (set_state 迁移式写入使全绿时段文件不动, 采样器以此判监督层活着);
#   顺带修正 v1.30 轮遗漏的 --version/启动横幅版本串(仍写 v1.29)。
# v1.30 (2026-10-21 WiFi incident): hostapd liveness by LIVE control sockets
#   (/proc/net/unix) + our own config path; recovery removes stale sockets and
#   no longer refuses when none exist.
# v1.29 (2026-10-20 stability batch3): primitives moved to svc_lib.sh
#   (lock/heartbeat/2-of-3/rate-limit/port probe + minimal sysfs parsers);
#   SVC_TABLE moved there and now includes dial_keeper; remaining dynamic
#   probes replaced (ps->/proc, df/dmesg->static busybox, iw BSS->hostapd
#   ctrl sockets, hostapd_cli->process+socket+link); HEALTH carries long-term
#   metrics (logc anomalies, REPAIR rate, zombies, BSS).
# v1.28 (2026-10-20): 2-of-3 采样确认(P0-3/P1-3 原文语义) + 剩余内联探针
#   (dmesg/iw/ip/tc/df/ps/station dump)全部过静态 timeout + v3httpd HTTP 200
#   与 dnsmasq DNS 功能性探针(每 10 轮, 仅告警不重启).
# v1.27 (2026-10-20 stability P0/P1 batch2):
#   ① 每个外部检查/探针经静态 busybox timeout 限时(默认 8s; 超时/137/139 视为
#      "工具故障" — 重试 3 次, 仍失败只告警并记 toolfaults, 不再等价于服务死);
#   ② 破坏性自愈改为 2-of-3 采样确认(≥60s)才动作, 单次抖动不动射频/不杀进程;
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

PATH=/data/gw/sbin:/data/gw/bin:$PATH
export PATH
[ -z "${TZ:-}" ] && [ -r /etc/TZ ] && TZ=$(cat /etc/TZ 2>/dev/null) && export TZ
LOG=/tmp/watchdog.log
# v1.29: one shared implementation of the supervision primitives.
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else
    echo "watchdog: svc_lib.sh missing -- refusing to run unsupervised" >&2
    exit 1
fi
STATE=/tmp/watchdog_state
# v1.36: netlock 原语(busy/holders/break)在 netlock.sh
[ -r /data/gw/netlock.sh ] && . /data/gw/netlock.sh 2>/dev/null
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
# v1.29: hb_age()/port_listen()/strike()/rl_ok()/alive() are in svc_lib.sh.
save_cmdline() { # $1=pid $2=file — cache a service restart recipe
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null | sed 's/ $//' > "$2"
}
# v1.29: 2-of-3 confirmation, restart budget and the /proc/net/tcp listener
# probe are shared primitives in svc_lib.sh (same semantics as v1.27/v1.28).

# v1.29: alive() (lock-first liveness) is in svc_lib.sh.
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
# v1.29: run an svc_lib function inside the bounded check() subshell.
check_lib() { # $1=key $2=body using svc_lib functions $3=label
    check "$1" ". /data/gw/svc_lib.sh 2>/dev/null; $2" "$3"
}

# v1.29: the script-daemon table lives in svc_lib.sh (one declaration shared
# by watchdog and the daemons).  Columns:
#   name|pgrep-pattern|lock-token|recipe|heartbeat|max-hb-age|env
# dial_keeper is in the table now; it needs the FH library/PATH environment,
# which the optional env column supplies on restart.
svc_supervise() { # $1=name $2=pattern $3=lock $4=recipe $5=hb $6=maxage $7=env
    _sn=$1; _sp=$2; _st=$3; _sc=$4; _shb=$5; _smax=$6; _sev=$7
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
    strike "$_sn" || { log "SKIP  $_sn recovery (failure sample recorded; need 2 of last 3)"; return 0; }
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
        # matches the pid the watchdog remembers.  v1.29: optional env prefix.
        case "$_sc" in
        "sh /data/gw/"*)
            # v1.37: 保留配方里的参数(原实现只取脚本路径, "daemon" 之类会被丢掉)
            _rest=${_sc#sh /data/gw/}
            _scr=${_rest%% *}
            _sargs=${_rest#"$_scr"}
            if [ -n "$_sev" ]; then
                spawn "$_sn" /tmp/$_sn.out env $_sev sh "/data/gw/$_scr" $_sargs
            else
                spawn "$_sn" /tmp/$_sn.out sh "/data/gw/$_scr" $_sargs
            fi ;;
        *) spawn "$_sn" /tmp/$_sn.out sh -c "$_sc" ;;
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
    # v1.31 (可用性轮): 每轮刷新 cycle 新鲜度键 — set_state 是迁移式写入,
    # 无此键则全绿时段 state 文件 mtime/内容不动, 采样器无法判监督层活着。
    grep -v '^cycle=' $STATE 2>/dev/null > $STATE.tmp
    echo "cycle=$(date +%s)" >> $STATE.tmp
    mv $STATE.tmp $STATE
    # v1.15: 时钟跳变检测 — NTP 校时/回拨会让本地时间戳不可跨段比较; epoch 与
    #   uptime 增量不一致即留痕(设备无 RTC, 开机曾出现 8h 跳变)。
    _NOW=$(date +%s)
    if [ -n "$LAST_EPOCH" ] && [ -n "$LAST_UP" ]; then
        _de=$(( _NOW - LAST_EPOCH )); _du=$(( UP - LAST_UP ))
        _dd=$(( _de - _du )); [ $_dd -lt 0 ] && _dd=$(( -_dd ))
        [ "$_dd" -gt 5 ] && log "EVT clock jump: epoch +${_de}s vs uptime +${_du}s (skew ${_dd}s)"
    fi
    LAST_EPOCH=$_NOW; LAST_UP=$UP
    # v1.27: liveness beacon at CYCLE START — proves the loop is running even
    # when an individual probe is slow (the end-of-cycle completion stamp goes
    # to /tmp/watchdog.done and is used for reporting only).
    echo "$UP" > /tmp/watchdog.beat 2>/dev/null

    # ---- process invariants (pidof 比 pgrep -x 更可靠, busybox -x 有怪癖) ----
    # v1.27: 服务本体统一走下方监督表/专用块; 这里只做静态不变量.
    check mipc_tool "[ -x /data/gw/mipc_cellular ]"  "cellular direct tool"
    check ccmni_up  "[ -x /data/gw/ccmni_up.sh ]"    "ccmni landing tool"
    check bootgate  "[ -x /data/gw/boot_gate.sh ]"   "boot health gate tool"
    check coremeta  "[ -x /data/gw/core_meta.sh ]"   "core metadata wrapper"

    # ---- v1.36: netcfg 写锁长持检测 + 自愈 ----
    #   正常写方(wan_agg/wan_eth/fw_apply/ccmni_up)持锁 <1s; 连续 3 轮(90s)仍被占
    #   只能是泄漏(长驻子进程继承了 flock fd)。发现即轮转锁文件: 泄漏者留在旧
    #   inode, 新写方用新 inode, 不需要杀任何进程。
    if netcfg_busy; then
        NETLOCK_BUSY=$(( ${NETLOCK_BUSY:-0} + 1 ))
        if [ "$NETLOCK_BUSY" -ge 3 ]; then
            _nlh=$(netcfg_holders)
            set_state netlock 1 "netcfg write lock"
            FAILS=$((FAILS+1))
            log "FAIL detail netlock busy=${NETLOCK_BUSY}x holders=[${_nlh:-?}]"
            if [ "${NETLOCK_BREAKS:-0}" -lt 3 ] && netcfg_break; then
                NETLOCK_BREAKS=$(( ${NETLOCK_BREAKS:-0} + 1 ))
                log "EVT netlock broken (rotation ${NETLOCK_BREAKS}/3)"
            fi
        fi
    else
        NETLOCK_BUSY=0
        set_state netlock 0 "netcfg write lock"
    fi

    # ---- data plane invariants ----
    check agg_rules "iptables -t mangle -S WANAGG 2>/dev/null | grep -q MARK" "split rules installed"
    check fwmark    "ip rule | grep -q fwmark"       "fwmark policy routing"
    check nat       "iptables -t nat -S POSTROUTING | grep -q MASQ"  "NAT masquerade"
    # v1.29: BSS liveness from hostapd control sockets + sysfs link flags
    # (the old iw probe counted AP-mode netdevs even when hostapd was dead).
    check_lib bss   "[ \$(svc_bss_count) -ge 2 ]"  "2+ BSS active"
    # v1.31 (可用性轮): 分频/访客/radvd 判决键 — 纯 set_state 行, 零决策逻辑;
    # bss2g/bss5g 供 avail_sampler 分频组件, 旧 bss 键保留(boot_gate 等消费者不变)
    check_lib bss2g  "svc_sock_live /var/run/hostapd/ra0  && svc_link_up ra0"  "WiFi 2.4G BSS live"
    check_lib bss5g  "svc_sock_live /var/run/hostapd/rai0 && svc_link_up rai0" "WiFi 5G BSS live"
    check_lib bss_guest ". /data/gw/defaults.conf 2>/dev/null; . /data/gw/settings.conf 2>/dev/null; [ \"\${GUEST:-0}\" = 1 ] || exit 0; _g=0; svc_sock_live /var/run/hostapd/ra1  && svc_link_up ra1  && _g=1; svc_sock_live /var/run/hostapd/rai1 && svc_link_up rai1 && _g=1; [ \"\$_g\" = 1 ]" "guest BSS live (when enabled)"
    # v1.35: radvd 判决移交 v6_reconcile.sh check —— 它区分"V6LAN=0 配置关闭"/
    #   "无 v6 上行(不该开)"/"该开而没开"(唯一失败态)。v1.32 的"无 ULA 即 pass"
    #   把 2026-10-28 的部署失败(承载口 v4-only 导致整块跳过)完全藏住了。
    check radvd  "sh /data/gw/v6_reconcile.sh check" "LAN v6 (ULA+radvd) when enabled"
    # v1.33 (防假绿轮): 结果探针 — 存在性键(端口监听/IP 在)历史上多次全绿撒谎
    # (L28 WiFi 死 5.7h / v3.44 数据面死载波在 / hostapd 信标停发)。
    # 实测注记: 本机 127.0.0.1 探测不可达(v3httpd 只绑 LAN IP/dnsmasq 不听
    # lo) — 探针必须打 192.168.9.1; 探针失败是"最后已知态", 窗口记账由
    # avail_sampler 的 FAIL-detail 游标捕获兜底。
    check http200 "export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib; [ \"\$(/fhrom/bin/curl -s -o /dev/null -w '%{http_code}' -m 4 http://192.168.9.1/)\" = 200 ]" "GUI serving HTTP 200 (not just listening)"
    check dnssvc "nslookup localhost 192.168.9.1 >/dev/null 2>&1" "DNS answering on LAN"
    # v1.34: 承载会 irat 切换(10-25 09:46 实弹 ccmni2→ccmni3, dial_keeper 跟随而
    # 探针锚死旧口=假红/假绿) — 改为"任一带 IP 的 ccmni 可通"=真 L3 语义; 绝对路径
    # v1.35: 3 包探针(任一回即通) —— 单包在 5% 随机丢包链路上每小时误判 ~10 次;
    #   3 包把随机丢包误判压到 0.0125%, 而连丢 3 包(真中断/切换)仍判失败。
    check dp5g   "_ok=1; for _c in ccmni0 ccmni1 ccmni2 ccmni3; do /data/gw/bin/ip -4 addr show \$_c 2>/dev/null | grep -q 'inet ' || continue; /data/gw/bin/busybox ping -4 -I \$_c -c3 -W1 223.5.5.5 >/dev/null 2>&1 && exit 0; done; exit 1" "5G data plane (any bearer with IP passes ICMP)"
    check dpeth  "ping -4 -I eth0 -c1 -W3 -s1 223.5.5.5 >/dev/null 2>&1" "eth data plane (ICMP via eth0)"
    check_port port80 80 "GUI :80 reachable"
    check_port port22 22 "SSH :22 reachable"
    if [ -f /tmp/boot.done ]; then
        set_state boot 0 "boot chain complete"
    elif [ "$UP" -lt 600 ]; then
        set_state boot 0 "boot chain in progress"
    else
        check boot "[ -f /tmp/boot.done ]" "boot chain complete"
    fi
    check_lib lan_ip "svc_iface_has_v4 br-lan"  "LAN IP present"
    check_lib lo_up  "svc_loopback_up"          "loopback up"

    # v1.29: dial_keeper moved into SVC_TABLE (svc_lib.sh); its env column
    # supplies LD_LIBRARY_PATH/PATH on supervisor restart.
    # ---- dnsmasq: process + :53 listener, restart from cached cmdline ----
    _dp=$(pidof dnsmasq 2>/dev/null)
    if [ -n "$_dp" ] && port_listen 53; then
        set_state dnsmasq 0 "DHCP/DNS"
        strike_clear dnsmasq
        save_cmdline "${_dp%% *}" /tmp/watchdog_dnsmasq.cmd 2>/dev/null
        # v1.27 (P0-3): functional DNS probe every 10 cycles, only when an
        # uplink exists (otherwise the failure is environmental, not dnsmasq).
        if [ $((CYC_TICK % 10)) -eq 0 ] && [ -n "$BB" ]; then
            if ! tmo 8 "$BB nslookup www.qq.com 192.168.9.1" >/dev/null 2>&1; then
                if tmo 5 "ip route show default" | grep -q default; then
                    log "WARN  dnsmasq functional probe failed (:53 up, uplink present)"
                fi
            fi
        fi
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
            log "SKIP  dnsmasq recovery (sample 1/3, need 2/3)"
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
            log "SKIP  dropbear recovery (sample 1/3, need 2/3)"
        fi
    fi

    # ---- v3httpd: process + :80 listener + periodic HTTP 200 probe ----
    if pidof v3httpd >/dev/null 2>&1 && port_listen 80; then
        set_state v3httpd 0 "GUI httpd"
        strike_clear v3httpd
        # v1.27 (P0-3): functional probe, warn-only — v3httpd is single-threaded
        # and a GUI SSE stream can legitimately delay a request; it must never
        # trigger a restart. Probe every 10 cycles (~5 min).
        if [ $((CYC_TICK % 10)) -eq 0 ] && [ -n "$BB" ]; then
            if ! tmo 8 "$BB wget -q -T 4 -O /dev/null http://192.168.9.1/"; then
                log "WARN  v3httpd functional probe failed (pid/:80 up; possible busy SSE stream)"
            fi
        fi
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
            log "SKIP  v3httpd recovery (sample 1/3, need 2/3)"
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
                log "SKIP  authd recovery (sample 1/3, need 2/3)"
            fi
        fi
    fi

    # ---- unified script-daemon table (v1.27; moved to svc_lib v1.29) ----
    while IFS='|' read -r _n _p _t _r _hb _mx _ev; do
        [ -z "$_n" ] && continue
        svc_supervise "$_n" "$_p" "$_t" "$_r" "$_hb" "$_mx" "$_ev"
    done <<EOF
$(printf '%s\n' "$SVC_TABLE" | sed '/^[[:space:]]*$/d')
EOF

    # ---- hostapd: WPA layer; 3-strike + tool-fault separation ----
    # v1.30 (2026-10-21 WiFi incident): liveness = OUR hostapd (config path
    # /var/wlan/hap_*) + LIVE control sockets from /proc/net/unix.  A crash
    # leaves the socket FILE behind, so the old -S test plus `pidof hostapd`
    # (which matched the vendor global instance) reported healthy for hours
    # while the AP was dead.  Recovery no longer refuses when no socket exists:
    # that is exactly the post-crash state, and refusing blocked every repair.
    _ha=0; _htool=0; _hrc=0
    if svc_hostapd_up; then
        _ha=1
    elif svc_our_hostapd >/dev/null 2>&1; then
        _hs=$(tmo 5 "hostapd_cli -i ra0 status"); _hrc=$?
        if printf '%s' "$_hs" | grep -q '^state=ENABLED'; then
            log "WARN  hostapd: cli ENABLED but live-socket predicate failed (bss=$(svc_bss_count) live=$(svc_live_socks))"
        fi
        if is_toolfault "$_hrc"; then
            _htool=1
            toolfault hostapd_cli "$_hrc" "hostapd_cli -i ra0 status" "diag=1"
        fi
    fi
    if [ "$_ha" = 1 ]; then
        set_state hostapd 0 "hostapd WPA layer"
        strike_clear hostapd
    elif [ "$_htool" = 1 ] && svc_our_hostapd >/dev/null 2>&1; then
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
        log "WARN  hostapd not serving (our_pid=$(svc_our_hostapd | tr '\n' ' ') live_socks=$(svc_live_socks) bss=$(svc_bss_count))"
        # A definitively absent process is not an ambiguous probe: repair it on
        # this cycle.  2-of-3 stays for "process alive but not serving" (and the
        # wifi_up/boot guards above still apply).
        _dead=0; svc_our_hostapd >/dev/null 2>&1 || _dead=1
        _fire=0
        if [ "$_dead" = 1 ]; then
            _fire=1
            log "EVT hostapd process absent — immediate repair (definitive)"
        else
            strike hostapd && _fire=1
        fi
        if [ "$_fire" = 1 ]; then
            _hn=0; _ht=0
            [ -r /tmp/watchdog_hostapd.rec ] && read _hn _ht < /tmp/watchdog_hostapd.rec
            _now2=$(date +%s)
            case "$_hn" in ''|*[!0-9]*) _hn=0 ;; esac
            case "$_ht" in ''|*[!0-9]*) _ht=$_now2 ;; esac
            [ $((_now2 - _ht)) -gt 3600 ] && { _hn=0; _ht=$_now2; }
            # independent confirmation before touching the radios: log the
            # live sockets and the affected clients, but never refuse because
            # the (stale) socket file is absent — a dead daemon must be repaired.
            _clients=$(svc_station_count ra0)
            if [ "$_hn" -lt 3 ]; then
                _hn=$((_hn + 1)); echo "$_hn $_ht" > /tmp/watchdog_hostapd.rec
                log "EVT recover hostapd (attempt $_hn/3 this hour; clients=$_clients live_socks=$(svc_live_socks) our_pid=$(svc_our_hostapd | tr '\n' ' '))"
                for _p in $(svc_our_hostapd 2>/dev/null); do kill $_p 2>/dev/null; done
                # a crashed daemon leaves a bound-socket file behind; the new
                # instance must be able to bind the control interface
                rm -f /var/run/hostapd/ra0 /var/run/hostapd/rai0
                for _v in ra0 rai0 ra1 rai1; do ifconfig $_v down 2>/dev/null; done
                sleep 3
                brctl addif br-lan ra0 2>/dev/null
                brctl addif br-lan rai0 2>/dev/null
                LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib \
                    hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf >>/tmp/watchdog.log 2>&1
                sleep 5
                for _v in ra0 rai0; do mwctl dev $_v set no_bcn 0 >/dev/null 2>&1; done
                if svc_hostapd_up; then
                    log "OK    hostapd recovered (bss=$(svc_bss_count); clients=$_clients must re-associate)"
                    set_state hostapd 0 "hostapd WPA layer"
                else
                    log "FAIL  hostapd recovery did not restore the live sockets (our_pid=$(svc_our_hostapd | tr '\n' ' ') live_socks=$(svc_live_socks) bss=$(svc_bss_count))"
                fi
            else
                log "WARN  hostapd down; recovery budget exhausted (3/h) — alert only"
            fi
        else
            log "SKIP  hostapd recovery (sample 1/3, need 2/3)"
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
            log "SKIP  wan_agg recovery (sample 1/3, need 2/3)"
        fi
    fi

    # ---- boot health gate supervision (v1.27) ----
    # Before boot.healthy exists the gate is boot-critical: restart it if dead.
    # Once healthy, re-verify at the 10-minute mark; drift is reported only
    # (services are repaired by their own supervision; TRY_A is not re-cleared).
    # v1.27: the gate is boot-critical until it stamps stable=1 (not merely
    # until boot.healthy exists) — a gate that dies between healthy and the
    # 10-minute observation would otherwise never arm healthdog.
    _gstable=$(sed -n 's/^stable=//p' "$HEALTHY" 2>/dev/null | tail -1)
    if [ "$_gstable" != 1 ] && [ "$UP" -lt 900 ]; then
        if alive 'boot_gate[.]sh' boot_gate boot_gate.sh; then
            set_state bootgate 0 "boot health gate"
        else
            set_state bootgate 1 "boot health gate"
            FAILS=$((FAILS+1))
            if strike bootgate; then
                log "EVT restart boot_gate (no live instance before healthy)"
                spawn bootgate /tmp/boot_gate.out sh /data/gw/boot_gate.sh
            else
                log "SKIP  boot_gate recovery (sample 1/3, need 2/3)"
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
    # v1.27 (P0-1): AT 探针降频 — 每 2 轮(60s)一次; 状态在两次之间保持,
    #   避免每次探针 ≥1s 把 30s 周期拖长(mipc 调用是历史停摆源)。
    AT_TICK=$(( ${AT_TICK:-0} + 1 ))
    if [ $((AT_TICK % 2)) -ne 0 ]; then
        :
    else
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
    fi

    # ---- incremental events ----
    # v1.29: static busybox dmesg (vendor dmesg is outside the toolchain farm).
    BCN=$(svc_dmesg_count 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
    BCN_PREV=$(grep '^beacon=' $STATE 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$BCN_PREV" ] && [ "$BCN" -gt "$BCN_PREV" ] 2>/dev/null; then
        log "WARN  beacon events +$((BCN-BCN_PREV))"
    fi
    grep -v '^beacon=' $STATE 2>/dev/null > $STATE.tmp
    echo "beacon=$BCN" >> $STATE.tmp
    mv $STATE.tmp $STATE

    # ---- v1.20: SIGSEGV 家族可见化 ----
    FLT=$(svc_dmesg_count 'unhandled exception')
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
        _lc=$(tmo 5 "iw dev $_vif info" | awk '/channel/{print $2}')
        _cc=$(grep -m1 '^channel=' $_cfc 2>/dev/null | cut -d= -f2)
        if [ -n "$_lc" ] && [ -n "$_cc" ] && [ "$_lc" != "$_cc" ]; then
            sed -i "s/^channel=.*/channel=$_lc/" $_cfc 2>/dev/null
            log "WARN  wifi $_b channel drift: conf=$_cc live=$_lc -> adopted live"
        fi
    done

    # ---- cellular stats divergence guard (v1.10) ----
    CIF=$(tmo 5 "ip -o -4 addr show" | grep -m1 'ccmni.*inet' | awk '{print $2}')
    if [ -n "$CIF" ]; then
        CN=$(cat /sys/class/net/$CIF/statistics/tx_bytes 2>/dev/null || echo 0)
        CQ=$(tmo 5 "tc -s qdisc show dev $CIF" | awk '/Sent/{print $2; exit}')
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

    # ---- v1.35: LAN v6 兜底收敛 (家宽/蜂窝 v6 后到、radvd 意外死亡; 2min 一次) ----
    V6_TICK=$(( ${V6_TICK:-0} + 1 ))
    if [ $((V6_TICK % 4)) -eq 1 ]; then
        _v6=$(tmo 20 "sh /data/gw/v6_reconcile.sh apply" 2>/dev/null)
        _v6m=$(printf '%s' "$_v6" | sed -n 's/.*mode=\([a-z]*\).*/\1/p')
        _v6p=$(cat /tmp/watchdog_v6mode 2>/dev/null)
        if [ -n "$_v6m" ] && [ "$_v6m" != "$_v6p" ]; then
            log "EVT v6 mode ${_v6p:-none}->${_v6m} ($_v6)"
            echo "$_v6m" > /tmp/watchdog_v6mode
        fi
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
        # v1.29: static busybox df, /proc zombie scan (no ps), long-term metrics.
        _df=$(svc_df_free /data)
        _tf=$(svc_df_free /tmp)
        _np=$(ls /proc 2>/dev/null | grep -c '^[0-9]')
        _nz=$(svc_zombies)
        _ct=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
        _lcs=$(cat /tmp/logc.stats 2>/dev/null)
        _lcbad=$(printf '%s' "$_lcs" | sed -n 's/.*bad_frames=\([0-9]*\).*/\1/p')
        _lcrs=$(printf '%s' "$_lcs" | sed -n 's/.*resyncs=\([0-9]*\).*/\1/p')
        _lcio=$(printf '%s' "$_lcs" | sed -n 's/.*io_errors=\([0-9]*\).*/\1/p')
        _lccrash=$(ls /data/gw/logs/logc_crash 2>/dev/null | wc -l)
        _rep=$(svc_repairs_1h)
        _nto=$(cat /tmp/netcfg_lock_timeouts 2>/dev/null || echo 0)
        _bss=$(svc_bss_count)
        log "HEALTH epoch=$(date +%s) up=${UP}s load=$_load memfree=${_mf:-?}KB memavail=${_ma:-?}KB data_free=${_df:-?}KB tmp_free=${_tf:-?}KB procs=$_np zombies=$_nz bss=$_bss conntrack=${_ct:-n/a} cell_if=${CIF:-none} netdev=${CN:-0} qdisc=${CQ:-0} logc_bad=${_lcbad:-?} logc_resync=${_lcrs:-?} logc_io=${_lcio:-?} logc_crash=${_lccrash:-0} repairs_1h=${_rep:-0} netlock_to=${_nto:-0}"
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

    # v1.27: completion stamp (healthdog uses the start beacon above)
    echo "$UP $(date +%s)" > /tmp/watchdog.done 2>/dev/null

    # ---- log truncation ----
    LINES=$(wc -l < $LOG 2>/dev/null || echo 0)
    if [ "$LINES" -gt "$MAX_LOG" ]; then
        tail -n $((MAX_LOG/2)) $LOG > $LOG.tmp 2>/dev/null && mv $LOG.tmp $LOG
    fi
}

# ---- main ----
case "${1:-}" in
--version) echo "watchdog v1.37"; exit 0 ;;
esac
touch $LOG $STATE
# v1.20: 看门狗单实例 — 双实例会重复自愈/告警(现场曾出现 2 个).
# v1.29: shared lock primitive (same cmdline + zombie verification).
_rc=0; svc_lock watchdog /data/gw/watchdog.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    echo "watchdog: another live instance owns the lock (rc=$_rc)" >&2
    exit 0
fi
log "===== watchdog v1.37 start (svc_lib primitives + minimal parsers + batch3 metrics; avail keys + outcome probes + bearer-follow dp; alert LED 5G orange) ====="
logger -t watchdog "watchdog v1.37 start"
# initialize state to current (suppress initial alarms)
run_cycle  # first run logs transitions but that's fine
while :; do
    sleep $CYCLE
    run_cycle
done
