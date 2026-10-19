#!/bin/sh
# watchdog.sh v1.21 -- on-device continuous invariant monitor.
# v1.21 (2026-10-19): 用户态 fault 计数移出 $STATE(独立 /tmp/watchdog_faultcount) —
#   放进 state 会被 selftest 当 0/1 故障键误判(faults=1 报"未恢复故障")。
# v1.20 (2026-10-19 单实例/风扇轮): ① 自愈拉起统一走 alive() 双判据(pgrep 失败时
#   回退锁文件 pid + /proc cmdline 复核) — SIGSEGV 家族会打死 pgrep 自身, 仅凭
#   pgrep 会重复拉起(现场 3×wan_eth / 2×log_keeper / 2×watchdog); ② 看门狗自身
#   单实例锁; ③ fan_mgr 只检不拉补齐(现场停 PWM 60, 高温不升挡); ④ 内核用户态
#   fault 计数增量进 WARN(SIGSEGV 家族可见化)。
# v1.19 (2026-10-19 wan_agg 静默死亡实弹): wan_agg 只检不拉 — 16:26 其子命令连续
#   SIGSEGV 后脚本退出, /tmp/wan_alive 停更; led_mgr 按 30s 新鲜度灭 WAN 灯、
#   GUI 判有线离线, 而 eth0 carrier=1/有 IP/默认路由/实际有流量。现补自愈拉起。
# v1.18 (2026-10-19 hostapd 崩溃实弹): hostapd 只检不拉 — 12:41 SIGSEGV 后无人
#   重启, ra0/rai0 仍按驱动 apcfg 发信标, 手机 assoc 成功但 4-way 无 EAPOL
#   (authorized:no) → 10s 后 reason=3 自断重试, 静默 3.5h。现补崩溃自愈:
#   按 wifi_up.sh v1.23 的 MLO 在线重应用配方(两带接口下电→冷启动等价态→
#   单进程 hostapd -B 双 conf→no_bcn 0 重装订信标), 限频 3 次/小时。
# v1.17 (2026-10-17 日志加密轮补): modem_reg/at_chan 分支此前绕过 check() 直接
#   set_state, 失败没有 rc/输出证据; 现补 FAIL detail(COPS/CFUN 原文)。
# v1.15 (2026-10-17 日志加密轮): 失败检查附 rc/输出摘要; 每 2 环循(60s)一行
#   TICK 全量状态; 每 10 环循(5min)一行 HEALTH(load/mem//data//tmp/进程/僵尸/
#   conntrack/蜂窝统计双口径); 自愈重启记录原因与旧 PID; cells 查询失败附
#   rc/输出长度; qdisc Sent 缺失(冷启动)显式留痕。
# v1.14 (RIL 清零轮): cell 查询恢复提示改直连语义(ql_ril_service 已退役)。
# v1.13 (RIL 收尾轮): cell 查询面恢复消息修正 — ql_netd 已退役, 恢复只需
#   restart ql_ril_service。
# L13: "feature silently broken until manual inspection" countermeasure.
# Runs every 30s; failures log + ALERT LED flash (5G orange); recovers silently.
# Started by rc19.sh (pgrep guard); single instance.
# v1.12 (2026-10-17 架构轮): +wan_eth 检查+自愈拉(有线 WAN 接口管理守护, 自 wan_agg
#       ensure_lease 拆出 — 其为 eth0 租约续订/NAT 看门狗唯一写方, 静默死亡 = 家宽侧
#       静默劣化: 租约到期/规则被冲刷后无人补)。
# v1.11 (2026-10-15 蜂窝查询面失效实弹): +蜂窝查询路径活性告警 — 厂商 RIL 的
#       ql_nw 子服务会静默失效(守护活着/数据面正常, 但 cells/endc 恒返
#       -2147024889, GUI 小区与组网卡片静默报错)。告警不自动重启: 蜂窝为主力时
#       重启 RIL 会打断数据面, 代价高于收益; 恢复路径已文档化。
# v1.10 (2026-10-15 流量口径实弹): +蜂窝统计偏差护栏 — 每周期比对 ccmni 网卡
#       tx_bytes 与 qdisc(真实发送路径)增量, 超阈值记 WARN。价值在"可见化":
#       网卡计数会被厂商卸载记账灌入无佐证增量(1s +1.22MB 而 qdisc/抓包为 0),
#       该信号此前只能靠事后翻采样日志才看得见。
# v1.9 (2026-10-15 WAN 灯不亮实弹): 告警闪烁从 WAN 灯(gpio292/5g_evb_voice)
#       迁到 5G 橙灯(gpio473)。原实现的病灶不是"闪"而是"闪完停在 0":
#       led_mgr v1.x 边沿触发(只写状态变化), watchdog 抢写后状态串不变 →
#       WAN 灯被闪灭后永不纠回。家宽数据面通而灯灭 = "eth0 有网 WAN 灯不亮"。
#       写权单一化后此族 bug 结构性消除; led_mgr v2.0 改绝对电平驱动兜底。
# v1.8 (2026-10-14 部署实测): dial_keeper 实例定位改 PID 锁(/tmp/dial_keeper.lock,
#       cmdline 复核) — 旧 pgrep -f 判据与"杀所有匹配"在启动者 argv 含脚本路径时
#       自匹配/误伤旁观 shell(实测两次)。
# v1.7 (2026-10-14 模组 EE 事故): ① 所有 mipc 探针过 mto() 硬超时(无 timeout
#       命令的纯 shell 封装) — 探针本身卡死会让整个看门狗停摆(事故窗口里
#       任何守护重启都不会发生); ② dial_keeper 心跳陈旧(>90s)判死重启 —
#       "进程在而守护死"(卡在 mipc 调用里)旧判据看不见; ③ led_mgr 自愈拉
#       (原只检不拉, LED 是"显示反映实际"的仪器, 静默死亡=无声谎报)。
# v1.6: +log_keeper 自愈 + ql_wifi_sample 卡死清除(L28 死循环刷 syslog 冲垮日志环)。
# v1.5: +wifi 信道一致性(驱动 IDC 可自行搬道 → 生成配置漂移时以实况回写+记警)。
# v1.4: agg 规则检查模式无关(weight/优先/仅模式); v1.3: +dial_keeper 兜底自愈。
# v1.2 (L14): +cellular control plane -- atcid 自愈, AT 通道(CFUN/CSQ),
#       模组注册态。第一阶段裁剪曾杀 atcid 而 3 天无人知晓 (数据面测试全绿)。

LOG=/tmp/watchdog.log
STATE=/tmp/watchdog_state
# v1.9: 告警灯 = 5G 橙灯(gpio473)。语义上恒灭(5G 无数据=全灭), 借它闪烁不
#   误导数据面; WAN 灯(292/5g_evb_voice)写权归 led_mgr 独占, 本脚本不再碰。
ALED=/sys/class/gpio/gpio473/value
CYCLE=30
MAX_LOG=500
CYC_TICK=0; QNODISC=""; LAST_EPOCH=""; LAST_UP=""

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

# v1.20: 单实例判活 — SIGSEGV 家族里 pgrep/grep 自身也会被打死(实测), 仅凭 pgrep
#   会重复拉起(现场: 3×wan_eth / 2×log_keeper / 2×watchdog)。锁文件记的 pid 活着
#   且 /proc cmdline 复核匹配 → 视为在跑, 不再起第二个。
alive() { # $1=pgrep pattern  $2=lock name  $3=cmdline token
    pgrep -f "$1" >/dev/null 2>&1 && return 0
    _ap=$(cat /tmp/$2.lock 2>/dev/null)
    [ -n "$_ap" ] && kill -0 "$_ap" 2>/dev/null && \
        grep -qa "$3" /proc/$_ap/cmdline 2>/dev/null && return 0
    return 1
}
spawn() { # $1=lock name  $2=log file  $3...=command
    _sl=$1; _so=$2; shift 2
    nohup "$@" >"$_so" 2>&1 &
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

# v1.7: timeout 语义的 mipc 探针封装(设备无 timeout/coreutils; 输出经临时文件
#   回显保 stdout 语义; 超时 SIGKILL 并记警, 返回 124)
MTO=10
mto() {
    mipc_wan_cli "$@" >/tmp/mto.$$ 2>&1 & _mp=$!
    _i=0
    while [ "$_i" -lt "$MTO" ] && kill -0 $_mp 2>/dev/null; do
        sleep 1; _i=$((_i + 1))
    done
    if kill -0 $_mp 2>/dev/null; then
        kill -9 $_mp 2>/dev/null
        rm -f /tmp/mto.$$
        log "WARN  mipc probe timeout(${MTO}s): $1"
        return 124
    fi
    wait $_mp; _rc=$?
    cat /tmp/mto.$$ 2>/dev/null
    rm -f /tmp/mto.$$
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

check() {  # $1=key $3=label, $2=check command
    KEY=$1; CMD=$2; LABEL=$3
    _out=$(eval "$CMD" 2>&1); _rc=$?
    if [ $_rc -eq 0 ]; then
        set_state "$KEY" 0 "$LABEL"
    else
        set_state "$KEY" 1 "$LABEL"
        FAILS=$((FAILS+1))
        # v1.15: 失败证据 — 命令输出/rc 一并留痕(此前只有 label, 排障需重跑)
        log "FAIL detail $KEY rc=$_rc out=$(printf '%s' "$_out" | tr '\n' ' ' | head -c 160)"
    fi
}

run_cycle() {
    FAILS=0
    # v1.15: 时钟跳变检测 — NTP 校时/回拨会让本地时间戳不可跨段比较; epoch 与
    #   uptime 增量不一致即留痕(设备无 RTC, 开机曾出现 8h 跳变)。
    _NOW=$(date +%s); _UP=$(cut -d. -f1 /proc/uptime)
    if [ -n "$LAST_EPOCH" ] && [ -n "$LAST_UP" ]; then
        _de=$(( _NOW - LAST_EPOCH )); _du=$(( _UP - LAST_UP ))
        _dd=$(( _de - _du )); [ $_dd -lt 0 ] && _dd=$(( -_dd ))
        [ "$_dd" -gt 5 ] && log "EVT clock jump: epoch +${_de}s vs uptime +${_du}s (skew ${_dd}s)"
    fi
    LAST_EPOCH=$_NOW; LAST_UP=$_UP

    # ---- process invariants (pidof 比 pgrep -x 更可靠, busybox -x 有怪癖) ----
    # hostapd 不走 check(): v1.18 起由下方自愈块负责(存活+控制面 ENABLED 双判据)
    check v3httpd   "netstat -tln 2>/dev/null | grep -q ':80.*LISTEN'"  "GUI httpd"
    check dnsmasq   "pidof dnsmasq"                  "DHCP/DNS"
    check dropbear  "netstat -tln 2>/dev/null | grep -q ':22.*LISTEN'"  "SSH"
    # wan_agg / fan_mgr 不走 check(): v1.19/v1.20 起由下方自愈块负责
    check wan_eth   "pgrep -f wan_eth.sh"            "wired-WAN iface keeper"
    # v1.15: 自研工具在位性 — 缺失时相关功能会静默降级(ccmni 落地/蜂窝直连)
    check mipc_tool "[ -x /data/gw/mipc_cellular ]"  "cellular direct tool"
    check ccmni_up  "[ -x /data/gw/ccmni_up.sh ]"    "ccmni landing tool"

    # ---- data plane invariants ----
    # v1.4: 模式无关 — weight 模式有 sport 分界, 优先/仅模式为单路 MARK 规则
    check agg_rules "iptables -t mangle -S WANAGG 2>/dev/null | grep -q MARK" "split rules installed"
    check fwmark    "ip rule | grep -q fwmark"       "fwmark policy routing"
    check nat       "iptables -t nat -S POSTROUTING | grep -q MASQ"  "NAT masquerade"
    check bss       "[ \$(iw dev 2>/dev/null | grep -c 'type AP') -ge 2 ]"  "2+ BSS active"
    check port80    "netstat -tln 2>/dev/null | grep -q ':80.*LISTEN'"  "GUI :80 reachable"
    check port22    "netstat -tln 2>/dev/null | grep -q ':22.*LISTEN'"  "SSH :22 reachable"
    check boot      "[ -f /tmp/boot.done ]"          "boot chain complete"
    check lan_ip    "ip -4 addr show br-lan | grep -q inet"  "LAN IP present"

    # ---- cellular control plane (L14) ----
    # dial_keeper: 拨号兜底守护 (P2); 死则带环境拉起
    # v1.7: 进程在 ≠ 守护活 — 卡死在一次 mipc 调用里时进程仍存活(10-14 模组 EE
    #   事故疑似形态)。心跳 /tmp/dial_keeper.hb(uptime 秒, 守护每 ≤5s 刷)陈旧
    #   >90s 即杀+拉起; 无心跳文件且已过开机宽限(300s)同样判异常。
    # v1.8: 实例定位改 PID 锁(/tmp/dial_keeper.lock; cmdline 复核防 PID 复用) —
    #   旧 pgrep -f 判据在"启动者 argv 含脚本路径"时自匹配, 且"杀所有匹配"会
    #   误伤旁观 shell(08:00 部署实测两次); 无锁文件时回退括号法 pgrep(旧版过渡)。
    _dhb=$(cat /tmp/dial_keeper.hb 2>/dev/null)
    _dup=$(cut -d. -f1 /proc/uptime)
    _dstale=0
    case "$_dhb" in
    ''|*[!0-9]*) [ "${_dup:-0}" -gt 300 ] && _dstale=1 ;;
    *) [ $((_dup - _dhb)) -gt 90 ] && _dstale=1 ;;
    esac
    _kp=$(cat /tmp/dial_keeper.lock 2>/dev/null)
    _kalive=0
    if [ -n "$_kp" ] && kill -0 "$_kp" 2>/dev/null \
       && grep -qa dial_keeper /proc/$_kp/cmdline 2>/dev/null; then
        _kalive=1
    elif pgrep -f 'dial_keepe[r].sh' >/dev/null 2>&1; then
        _kalive=1   # 回退判据(旧版实例无锁文件)
    fi
    if [ "$_kalive" = 1 ] && [ "$_dstale" = 0 ]; then
        set_state keeper 0 "dial keeper"
    else
        if [ "$_dstale" = 1 ]; then
            log "WARN  stale dial_keeper heartbeat (hb=${_dhb:-none} up=${_dup}) — restart"
            logger -t watchdog "stale dial_keeper heartbeat (hb=${_dhb:-none}) — restart"
        fi
        set_state keeper 1 "dial keeper"
        FAILS=$((FAILS+1))
        log "EVT restart dial_keeper (alive=$_kalive stale=$_dstale old_pid=${_kp:-none} hb=${_dhb:-none} up=${_dup})"
        # 只杀锁指向的实例(cmdline 复核) — 不打模式匹配, 防误伤旁观进程
        if [ -n "$_kp" ] && kill -0 "$_kp" 2>/dev/null \
           && grep -qa dial_keeper /proc/$_kp/cmdline 2>/dev/null; then
            kill -9 "$_kp" 2>/dev/null
        fi
        export LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/fhrom/bin:/fhrom/fhshell
        nohup sh /data/gw/dial_keeper.sh >/dev/null 2>&1 &
    fi
    # log_keeper: 日志持久化(专项轮); 死则拉起 — 日志连续性=诊断生命线
    if alive 'log_keeper[.]sh' log_keeper log_keeper.sh; then
        set_state logk 0 "log keeper"
    else
        set_state logk 1 "log keeper"
        FAILS=$((FAILS+1))
        log "EVT restart log_keeper (no live instance; lock=$(cat /tmp/log_keeper.lock 2>/dev/null || echo none))"
        spawn log_keeper /dev/null sh /data/gw/log_keeper.sh
    fi
    # led_mgr: 显示器守护(v1.7 自愈拉) — 静默死亡=指示灯无声谎报(10-14 事故
    # 里用户对"灯还亮着"的判读是第一手症状, 灯不能哑)
    if alive 'led_mgr[.]sh' led_mgr led_mgr.sh; then
        set_state led_mgr 0 "LED manager"
    else
        set_state led_mgr 1 "LED manager"
        FAILS=$((FAILS+1))
        log "EVT restart led_mgr (no live instance; lock=$(cat /tmp/led_mgr.lock 2>/dev/null || echo none))"
        spawn led_mgr /dev/null sh /data/gw/led_mgr.sh
        logger -t watchdog "restarted led_mgr"
    fi
    # fan_mgr: 4 线风扇梯度温控(v1.20 自愈) — 死则 PWM 停在最后挡位, 高温不再
    #   升挡(实测现场停在 60=1663rpm), 属散热静默劣化; 原实现只 check 不拉。
    if alive 'fan_mgr[.]sh' fan_mgr fan_mgr.sh; then
        set_state fan_mgr 0 "fan manager"
    else
        set_state fan_mgr 1 "fan manager"
        FAILS=$((FAILS+1))
        log "EVT restart fan_mgr (no live instance; pwm=$(cat /sys/devices/platform/pwm-fan@1/hwmon/hwmon1/pwm1 2>/dev/null))"
        spawn fan_mgr /dev/null sh /data/gw/fan_mgr.sh
        logger -t watchdog "restarted fan_mgr"
    fi
    # hostapd: WPA 安全面(v1.18 崩溃自愈) — 实弹 2026-10-19 12:41 SIGSEGV 后无人
    #   拉起: ra0/rai0 仍按驱动 apcfg 发信标, 手机看得见且 assoc 成功, 但 4-way
    #   无 EAPOL(authorized:no) → 10s 后 reason=3 自断重试, 直到人工发现(3.5h)。
    #   配方 = wifi_up.sh v1.23 的 MLO 在线重应用等价态(接口已 UP 时直接 -B 必死):
    #   两带接口下电 3s → 单进程 hostapd -B 双 conf → no_bcn 0 重装订信标。
    #   限频 3 次/小时(tmpfs 窗口文件, 重启清零), 超限只告警不动射频。
    _ha=0
    if pgrep -f 'hostapd -B' >/dev/null 2>&1; then
        hostapd_cli -i ra0 status 2>/dev/null | grep -q '^state=ENABLED' && _ha=1
    fi
    if [ "$_ha" = 1 ]; then
        set_state hostapd 0 "hostapd WPA layer"
    elif pgrep -f 'wifi_up[.]sh' >/dev/null 2>&1 || [ "$(cut -d. -f1 /proc/uptime)" -lt 180 ]; then
        # 开机/在线重应用进行中: 不与之抢射频, 只记录
        set_state hostapd 1 "hostapd WPA layer"
        FAILS=$((FAILS+1))
        log "SKIP  hostapd recovery (boot or wifi_up in progress)"
    else
        set_state hostapd 1 "hostapd WPA layer"
        FAILS=$((FAILS+1))
        _hn=0; _ht=0
        [ -r /tmp/watchdog_hostapd.rec ] && read _hn _ht < /tmp/watchdog_hostapd.rec
        _now2=$(date +%s)
        case "$_hn" in ''|*[!0-9]*) _hn=0 ;; esac
        case "$_ht" in ''|*[!0-9]*) _ht=$_now2 ;; esac
        [ $((_now2 - _ht)) -gt 3600 ] && { _hn=0; _ht=$_now2; }
        if [ "$_hn" -lt 3 ]; then
            _hn=$((_hn + 1))
            echo "$_hn $_ht" > /tmp/watchdog_hostapd.rec
            log "EVT recover hostapd (attempt $_hn/3 this hour; live=$(pgrep -f 'hostapd -B' | tr '\n' ' '))"
            for _p in $(pgrep -f 'hostapd -B' 2>/dev/null); do kill $_p 2>/dev/null; done
            for _v in ra0 rai0 ra1 rai1; do ifconfig $_v down 2>/dev/null; done
            sleep 3
            brctl addif br-lan ra0 2>/dev/null
            brctl addif br-lan rai0 2>/dev/null
            LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib \
                hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf >>/tmp/watchdog.log 2>&1
            sleep 5
            for _v in ra0 rai0; do mwctl dev $_v set no_bcn 0 >/dev/null 2>&1; done
            if hostapd_cli -i ra0 status 2>/dev/null | grep -q '^state=ENABLED'; then
                log "OK    hostapd recovered (ra0 ENABLED; clients must re-associate)"
                set_state hostapd 0 "hostapd WPA layer"
            else
                log "FAIL  hostapd recovery did not reach ENABLED"
            fi
        else
            log "WARN  hostapd down; recovery budget exhausted (3/h) — alert only"
        fi
    fi
    # wan_agg: 双上行聚合主管(v1.19 崩溃自愈) — 实弹 2026-10-19 16:26: 子命令
    #   连续 SIGSEGV 后脚本静默退出, /tmp/wan_alive 过期 → led_mgr(30s 新鲜度)
    #   灭 WAN 灯、GUI 线路状态判"离线", 而 eth0 carrier=1/有 IP/默认路由/实际有流量。
    #   原实现只 check 不拉(与 hostapd v1.18 前的缺口同型)。死则按启动配方拉起。
    if alive 'wan_agg[.]sh' wan_agg wan_agg.sh; then
        set_state wan_agg 0 "aggregation supervisor"
    else
        set_state wan_agg 1 "aggregation supervisor"
        FAILS=$((FAILS+1))
        log "EVT restart wan_agg (no live instance; wan_alive=$(cat /tmp/wan_alive 2>/dev/null))"
        spawn wan_agg /tmp/wagg.out sh /data/gw/wan_agg.sh
        logger -t watchdog "restarted wan_agg"
    fi
    # wan_eth: 有线 WAN 接口管理守护(v1.12, 架构轮拆分自 wan_agg ensure_lease);
    #   死则拉起 — eth0 租约续订/NAT/FORWARD 看门狗停摆 = 家宽侧静默劣化
    if alive 'wan_eth[.]sh' wan_eth wan_eth.sh; then
        set_state wan_eth 0 "wired-WAN iface keeper"
    else
        set_state wan_eth 1 "wired-WAN iface keeper"
        FAILS=$((FAILS+1))
        log "EVT restart wan_eth (no live instance)"
        spawn wan_eth /dev/null sh /data/gw/wan_eth.sh
        logger -t watchdog "restarted wan_eth"
    fi
    # ql_wifi_sample 卡死清除(L28): stdin EOF 后死循环刷 syslog(实测 3700 行/s,
    #   日志环被冲至 18s 深)。CPU 累计 >=120s 即杀(交互等待不耗 CPU, 不误伤;
    #   stat 14+15=utime+stime tick, busybox HZ 按 100 计, 阈值语义随 HZ 平移无害)
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
    # v1.7: 探针过 mto() 硬超时 — 探针卡死不再让整轮看门狗停摆
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
    # 未根除(厂商 syslog 管线/短命工具随机 SIGSEGV), 至少让"又崩了"进日志:
    # 内核 fault 行计数增量; dmesg 环回卷导致计数回退时只重置不告警。
    FLT=$(dmesg | grep -c 'unhandled exception')
    FLT_PREV=$(cat /tmp/watchdog_faultcount 2>/dev/null)
    if [ -n "$FLT_PREV" ] && [ "$FLT" -gt "$FLT_PREV" ] 2>/dev/null; then
        log "WARN  user-fault +$((FLT-FLT_PREV)) (ring total $FLT) — SIGSEGV family"
    fi
    # v1.21: 计数走独立文件 — 放 state 会被 selftest 当 0/1 故障键误判(faults=1)
    echo "$FLT" > /tmp/watchdog_faultcount

    # ---- wifi channel consistency (v1.5) ----
    # 驱动 IDC(LTE 共存避让)可在运行期自行搬道(实测), hostapd 生成配置的 channel=
    # 会与实况脱节("配置写 ch1 而实况 ch11")。实况为权威: 漂移时回写生成配置
    # (hostapd 下次重启读到的即真相)并记警; 不闪 LED(非服务性故障)。
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
    # ccmni 网卡 tx_bytes 会被厂商卸载路径的记账灌入无佐证的批量增量(实测:
    #   1 秒 +1,221,373B/813 包, 而同期 qdisc 仅 +29B/1 包、ccmni2 抓包只有 6 个
    #   探针包; 无 IP/无路由且 DOWN 的 ccmni1 也记了 47MB)。流量统计已改用 qdisc
    #   口径(traffic_logger v1.2/api v2.72), 这里只做**可见化**: 每周期比对两者
    #   增量, 超阈值记警。原则是不猜修、只取证 —— 信号出现即说明"统计与实际不符"
    #   在持续发生, 而不是静默污染流量账。
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
            # 阈值 256KB/30s: 真实流量下网卡与 Linux 路径增量**逐字节相等**(实测
            #   已知量注入 gap=0), 故任何正差都属厂商侧记账异常; 取 256KB 既远高于
            #   两次读取间的毫秒级错位, 也能抓住单次 1.22MB 的跳变(2MiB 阈值曾漏)。
            [ "$GAP" -gt 262144 ] && \
                log "WARN  cell stats divergence on $CIF: netdev +${DN}B vs linux-path +${DQ}B (gap ${GAP}B)"
        fi
        echo "PN=$CN; PQ=$CQ" > /tmp/cellstat_prev
    fi

    # ---- cellular query path liveness (v1.11) ----
    # 实弹(2026-10-15): ql_ril_service 活着、蜂窝数据面完全正常(有 IP/可 ping),
    #   但 cells/endc 查询恒返 -2147024889 —— 厂商 RIL 的 ql_nw 子服务静默失效,
    #   无任何守护察觉, GUI 的小区/邻区/组网模式卡片会静默报错(状态与实际不符)。
    #   恢复 = 项目自身路径清栈重启 RIL(dial_5g/rc_netfh 同法)。
    #   只**告警不自动重启**: 蜂窝是主力时重启 RIL 会打断数据面(需重拨 ~40s),
    #   代价高于收益; 可见化 + 文档化手工恢复是当前最稳做法。每 10 环循(~5min)探一次。
    CQ_TICK=$(( ${CQ_TICK:-0} + 1 ))
    if [ $((CQ_TICK % 10)) -eq 1 ]; then
        _co=$(/data/gw/mipc_cellular cells 2>&1); _crc=$?
        printf '%s' "$_co" | grep -q '"serving"' || \
            log "WARN  cell query path dead (rc=$_crc len=${#_co} out=$(printf '%s' "$_co" | tr '\n' ' ' | head -c 100)) — 直连 MIPC 查询失败(数据面可能正常); 恢复: 检查 /dev/ttyCMIPC 端口占用与 modem 状态, 见 docs/FINDINGS §27/§29"
    fi

    # ---- v1.15: periodic summaries (24h 分析主干) ----
    CYC_TICK=$((CYC_TICK + 1))
    if [ $((CYC_TICK % 2)) -eq 0 ] || [ "$FAILS" -gt 0 ]; then
        log "TICK epoch=$(date +%s) fails=$FAILS up=$(cut -d. -f1 /proc/uptime)s state=[$(tr '\n' ' ' < $STATE 2>/dev/null)]"
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
        log "HEALTH epoch=$(date +%s) up=$(cut -d. -f1 /proc/uptime)s load=$_load memfree=${_mf:-?}KB memavail=${_ma:-?}KB data_free=${_df:-?}KB tmp_free=${_tf:-?}KB procs=$_np zombies=$_nz conntrack=${_ct:-n/a} cell_if=${CIF:-none} netdev=${CN:-0} qdisc=${CQ:-0}"
        [ "${_df:-0}" -lt 102400 ] 2>/dev/null && log "WARN /data free low: ${_df}KB (<100MB)"
    fi

    # ---- visual alert ----
    # v1.9 (2026-10-15 实弹): 告警闪烁不再用 WAN 灯。两个写方抢同一物理灯是
    #   "灯不符实际"的直接成因: watchdog 闪 3 次后停在 0, 而 led_mgr v1.x 只在
    #   状态串变化时写灯 → 家宽数据面明明通着, WAN 灯被闪灭后永久停在误值
    #   (实弹: 06:05 状态 b1 起 5 小时内 led_mgr 一次都没再写)。
    #   改闪 5G 橙灯(gpio473): 该灯在 v1.9 语义下"无数据一律全灭", 恒为 0,
    #   借它闪烁不误导任何数据面语义(led_mgr v2.0 绝对电平驱动每 2s 纠回, 闪
    #   完即复原)。WAN 灯写权自此单一化 = led_mgr 独占。
    # v1.9b: 原 sleep 0.1 是死代码 —— busybox sleep 只吃整数秒(实测
    #   "invalid number '0.1'"), 告警闪烁自 v1.x 起从未真的执行过。改用
    #   1s 亮/1s 灭(肉眼可辨, 且不拖长 30s 周期)。
    if [ "$FAILS" -gt 0 ]; then
        for i in 1 2 3; do
            alert_led_set 1; sleep 1
            alert_led_set 0; sleep 1
        done
        log "WARN  visual alert: $FAILS check(s) failing"
    fi

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
   grep -qa watchdog.sh /proc/$_wp/cmdline 2>/dev/null; then
    echo "watchdog: already running pid=$_wp" >&2
    exit 0
fi
echo $$ > /tmp/watchdog.lock
log "===== watchdog v1.21 start (alert LED 5G orange; WAN LED owned by led_mgr; +hostapd/wan_agg/fan_mgr recovery +single-instance locks +user-fault counter; fine-log TICK/HEALTH) ====="
logger -t watchdog "watchdog v1.16 start"
# initialize state to current (suppress initial alarms)
run_cycle  # first run logs transitions but that's fine
while :; do
    sleep $CYCLE
    run_cycle
done
