# api_sys.sh v1.5 — 系统/状态域模块 (被 api.sh 按端点懒加载; 依赖核心的 helpers)
# v1.3 (2026-10-17 日志加密轮): traffic 选口回退/qdisc 缺失留痕(api.log)。
# v1.2: /api/traffic 增 if 字段; v1.1: 探活实证选口。
# v1.0 (2026-10-17 架构轮): 自 api.sh v2.74 拆出 — status/clients/sys/logs/sse/fan/
#   led/ntp/reboot_sched/traffic 族端点。域历史(自 api.sh 头注迁入):
# v2.73(2026-10-16 宵断实弹): status 的 home.dp/wan5g.dp 改消费 wan_agg 发布的
#   /tmp/wan_alive — 原先各探 223.5.5.5/120.53.53.53, 被上行接入网夜间切断白名单
#   放行 → GUI 谎报家宽正常。
# v2.72: get_traffic 蜂窝上行改取 qdisc(Linux 发送路径) — netdev tx_bytes 被厂商
#   卸载记账灌入无佐证增量, 用作流量展示=假象(见 traffic_logger v1.2)。
# v2.69: get_logs 增 diag 字段(诊断包尾部, token/pass/凭据脱敏)。
# v2.66: 时区入自管配置(apply_ntp gw_set TZ + get_ntp 读持有效值)。
# v2.64: status 增数据面实测 home.dp/wan5g.dp — carrier=1 只说明物理层在。
# v2.59: NTP 自管配置(树退役后 cfg_cmd 恒失败); 同步链全源失败显性 jerr。
# 依赖: status/clients 的 WiFi 卡片复用 wifi 域的实况读取(wifi_state/stations)。
. $APID/api_wifi.sh

# -- 流量统计 (ubus 活方法; 限额自管) --
get_traffic() {
    # v2.34: 蜂窝口字节数直读; v2.72: 蜂窝**上行**改取 qdisc(Linux 发送路径)——
    #   netdev tx_bytes 会被厂商卸载路径的记账灌入无佐证的批量增量(实测 1 秒
    #   +1.22MB/813 包而 qdisc/抓包为 0; 见 traffic_logger v1.2 长注释), 用作
    #   流量展示=假象。qdisc 对真实流量逐字节精确; 缺失时回退 netdev。下行用
    #   netdev rx(实测准确)。
    # v1.1 (RIL 清零轮): 选**探活实证的**承载口 — 多口并存时"第一个有 IP"常是
    #   旧 PDN 僵尸口(有 IP 无数据), 会导致流量/GUI 显示错口。
    IF=""
    for _c in $(ip -o -4 addr show 2>/dev/null | grep ccmni | grep inet | awk '{print $2}'); do
        for _t in 180.76.76.76 119.29.29.29 8.8.8.8; do
            ping -4 -I $_c -c1 -W1 -s1 $_t 2>/dev/null | grep -q ttl && { IF=$_c; break 2; }
        done
    done
    if [ -z "$IF" ]; then
        IF=$(ip -o -4 addr show 2>/dev/null | grep -m1 'ccmni.*inet' | awk '{print $2}')
        [ -n "$IF" ] && alog "WARN traffic iface fallback=$IF (no probe-passing ccmni)"
    fi
    RX=0; TX=0; ERX=0; ETX=0
    if [ -n "$IF" ]; then
        RX=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)
        TX=$(tc -s qdisc show dev $IF 2>/dev/null | awk '/Sent/{print $2; exit}')
        [ -n "$TX" ] || { TX=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null); \
            alog "WARN traffic qdisc Sent missing on $IF -> netdev tx"; }
    fi
    ERX=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null)
    ETX=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null)
    [ -r $GWDATA/traffic.conf ] && . $GWDATA/traffic.conf
    # v1.2: +if 字段(本次统计实际取样的蜂窝口) — 多 ccmni 并存时消费方可同口比对
    printf '{"if":"%s","rx":"%s","tx":"%s","erx":"%s","etx":"%s","day_limit_mb":"%s","month_limit_mb":"%s","ts":%d}' \
        "${IF:-}" "${RX:-0}" "${TX:-0}" "${ERX:-0}" "${ETX:-0}" "${DAY_LIMIT_MB:-0}" "${MONTH_LIMIT_MB:-0}" "$(date +%s)"
}
# v2.56: 流量历史聚合 — span=week(168 小时桶)/month(30 天桶), 本地时区(+8)对齐
# 数据源 /data/gw/traffic_hist.tsv (epoch drx_c dtx_c drx_e dtx_e, 5min 增量)
# 输出 {"span","step","buckets":[{"t","c","e"}...],"today":{"c","e"}} (c=蜂窝 e=以太, 字节)
get_traffic_hist() {
    SPAN=$(form_kv span)
    # v1.5: 读 traffic_logger 维护的**小时/日汇总**(v1.6 起), 不再每次请求 awk 扫 6000 行
    #   原始采样 —— 那条 awk 是崩溃家族里最常见的落点之一(18h 内 4 次)。
    case "$SPAN" in
        month) STEP=86400; N=30;  F=$GWDATA/traffic_day.tsv ;;
        *)     SPAN=week;  STEP=3600; N=168; F=$GWDATA/traffic_hour.tsv ;;
    esac
    NOW=$(date +%s)
    if [ ! -r "$F" ]; then
        printf '{"span":"%s","step":%s,"buckets":[],"today":{"c":0,"e":0}}' "$SPAN" "$STEP"
        return
    fi
    awk -v step=$STEP -v n=$N -v now=$NOW -v span=$SPAN '
        { tl = $1; c[tl] = $2; e[tl] = $3
          if (tl > mx) mx = tl
          tod0 = int((now + 28800) / 86400) * 86400
          if (tl >= tod0) { tc += $2; te += $3 } }
        END {
          if (mx <= 0) {
              printf "{\"span\":\"%s\",\"step\":%d,\"buckets\":[],\"today\":{\"c\":0,\"e\":0}}", span, step
              exit
          }
          start = tod0 - (span == "week" ? 6 : 29) * 86400
          if (start > mx) start = mx - step * (n - 1)
          printf "{\"span\":\"%s\",\"step\":%d,\"buckets\":[", span, step
          for (t = start; t <= mx; t += step)
              printf "%s{\"t\":%d,\"c\":%.6g,\"e\":%.6g}", (t > start ? "," : ""), t - 28800, c[t] + 0, e[t] + 0
          printf "],\"today\":{\"c\":%.6g,\"e\":%.6g}}", tc + 0, te + 0
        }' "$F"
}
apply_traffic_limit() {
    D=$(form_kv day); M=$(form_kv month)
    echo "$D$M" | grep -qE '[^0-9]' && jerr bad_num
    printf 'DAY_LIMIT_MB=%s\nMONTH_LIMIT_MB=%s\n' "$D" "$M" > $GWDATA/traffic.conf
    ok_json
}

# -- 风扇/LED --
get_fan() {
    cfg_load
    MODE=${FAN_MODE:-performance}
    DUTY=$(cat /sys/class/hwmon/hwmon1/pwm1 2>/dev/null)
    RPM=$(cat /sys/class/hwmon/hwmon2/pwm1_rpm 2>/dev/null)
    T=""
    for zd in /sys/class/thermal/thermal_zone*; do
        [ "$(cat $zd/type 2>/dev/null)" = soc_max ] && T=$(cat $zd/temp 2>/dev/null)
    done
    printf '{"mode":"%s","duty":"%s","rpm":"%s","soc_temp":"%s","ts":%d}' \
        "$MODE" "${DUTY:-0}" "${RPM:-0}" "${T:--}" "$(date +%s)"
}
apply_fan() {
    M=$(form_kv mode)
    [ "$M" = performance ] || [ "$M" = silent ] || jerr bad_mode
    gw_set FAN_MODE "$M"
    # fan_mgr 周期重读 conf(若实现); 保险: 发信号量文件
    touch /tmp/fan_mode.changed
    ok_json
}
get_led() {
    cfg_load   # v2.75: 拆分后 cfg_load 收进模块(原在路由行内)
    printf '{"night":"%s","ts":%d}' "${LED_NIGHT:-0}" "$(date +%s)"
}
apply_led() {
    V=$(form_kv night)
    [ "$V" = 0 ] || [ "$V" = 1 ] || jerr bad_flag
    gw_set LED_NIGHT "$V"
    touch /tmp/led_mode.changed
    ok_json
}

# -- NTP/时区 --
get_ntp() {
    # v2.59: 树退役(KEEP_TREE=0; cfg_cmd 恒 shm_attach rc=-1)后原 cfgget(NTPServer1) 恒空
    #   = "手动设置过, 页面永远空白"的根因; 改自管配置: defaults.conf 叠 settings.conf
    #   (与 WiFi 族同源)。timed_reboot 死读删除(树键, 无消费方)。
    # v2.66: tz 读自管配置(原读 /etc/TZ→/tmp/TZ tmpfs, 重启即回落 UTC = 页面显示
    #   UTC 且定时重启窗口随 TZ 偏移); /etc/TZ 仅作无配置时兜底。
    cfg_load
    printf '{"date":"%s","tz":"%s","ntp_server":"%s","ts":%d}' \
        "$(date "+%Y-%m-%d %H:%M:%S")" "${TZ:-$(cat /etc/TZ 2>/dev/null)}" \
        "${NTP_SERVER:-ntp.aliyun.com}" "$(date +%s)"
}
apply_ntp() {
    SRV=$(form_kv server); TZV=$(form_kv tz)
    echo "$SRV" | grep -qE '[^A-Za-z0-9.:_-]' && jerr bad_srv
    echo "$TZV" | grep -qE '[^A-Za-z0-9+\-:/]' && jerr bad_tz
    # v2.59: 写自管配置(树退役后原 cfgset_ok 恒败且被 2>/dev/null 吞掉 = 设置了也存不下来);
    #   留空 = gw_del 回退出厂默认(gw_del 语义: 删除键=回退派生值)
    if [ -n "$SRV" ]; then gw_set NTP_SERVER "$SRV"; EFF=$SRV
    else gw_del NTP_SERVER; cfg_load; EFF=${NTP_SERVER:-ntp.aliyun.com}
    fi
    # v2.66: 时区入自管配置 — /etc/TZ→/tmp/TZ(tmpfs) 重启即失, 原仅写运行态 =
    #   每次重启后时钟显示回落 UTC(定时重启窗口随 TZ 偏移); 空=gw_del 回退出厂默认
    if [ -n "$TZV" ]; then gw_set TZ "$TZV"; else gw_del TZ; cfg_load; fi
    echo "${TZ:-CST-8}" > /etc/TZ
    [ -s /etc/resolv.conf ] || echo "nameserver 223.5.5.5" > /etc/resolv.conf
    # v2.3: 同步对时+真实校验(ntpd -qn 曾静默失败致时钟错3天, 用户实弹抓获)
    # v2.59: 全源失败显性报错(原链失败后照报 synced:true = 假成功); 设置已先落盘,
    #   服务器暂时不可达不清除用户设置, keeper 每小时自动重试
    BEFORE=$(date +%s)
    OK=0
    for S in "$EFF" 203.107.6.88 119.28.63.197; do
        ntpclient -h "$S" -c 1 -s >/dev/null 2>&1 && { OK=1; break; }
    done
    [ $OK -eq 1 ] || jerr sync_fail
    AFTER=$(date +%s)
    DELTA=$((AFTER - BEFORE))
    if [ $DELTA -gt 5 ]; then
        ok_json "\"synced\":true,\"jump\":\"${DELTA}s\""
    else
        ok_json "\"synced\":true,\"note\":\"already-in-sync\""
    fi
}

# -- 定时重启 (v2.65) --
get_reboot() {
    # 与 reboot_sched 守护同源: defaults 叠 settings; last=守护落盘的执行日期
    # (跨重启持久); 下次执行时刻由 GUI 侧按 today/last 推导显示。
    cfg_load
    RT="${REBOOT_TIME:-04:00}"
    case "$RT" in [0-2][0-9]:[0-5][0-9]) ;; *) RT=04:00 ;; esac
    printf '{"en":"%s","time":"%s","last":"%s","today":"%s","now":"%s"}' \
        "${REBOOT_EN:-1}" "$RT" "$(cat /data/gw/reboot_sched.last 2>/dev/null)" "$(date +%F)" "$(date +%H:%M)"
}
apply_reboot() {
    EN=$(form_kv en); RT=$(form_kv time)
    case "$EN" in 0|1) ;; *) jerr bad_val ;; esac
    # 留空时间 = gw_del 回退出厂默认 04:00 (与 NTP 端点同语义)
    [ -z "$RT" ] || echo "$RT" | grep -qE '^([01][0-9]|2[0-3]):[0-5][0-9]$' || jerr bad_time
    gw_set REBOOT_EN "$EN"
    if [ -n "$RT" ]; then gw_set REBOOT_TIME "$RT"; else gw_del REBOOT_TIME; fi
    cfg_load
    ok_json "\"en\":\"${REBOOT_EN:-1}\",\"time\":\"${REBOOT_TIME:-04:00}\""
}

# ---------- 状态页 ----------
get_status() {
    exec 2>/dev/null
    U=$(cut -d. -f1 /proc/uptime)
    UP_D=$((U/86400)); UP_H=$(( (U%86400)/3600 )); UP_M=$(( (U%3600)/60 ))
    LOAD=$(cut -d" " -f1-3 /proc/loadavg)
    MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d %d", t, a}' /proc/meminfo)
    W5G_IF=""
    for _c in $(ip -o -4 addr show 2>/dev/null | grep ccmni | grep inet | awk '{print $2}'); do
        for _t in 180.76.76.76 119.29.29.29 8.8.8.8; do
            ping -4 -I $_c -c1 -W1 -s1 $_t 2>/dev/null | grep -q ttl && { W5G_IF=$_c; break 2; }
        done
    done
    [ -n "$W5G_IF" ] || W5G_IF=$(ip -o -4 addr show 2>/dev/null | grep ccmni | grep -m1 inet | awk '{print $2}')
    W5G_IP=$(ip -o -4 addr show $W5G_IF 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    W5G_V6=$(ip -o -6 addr show $W5G_IF 2>/dev/null | grep -m1 global | awk '{print $4}' | cut -d/ -f1)
    ETH_IP=$(ip -o -4 addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    ETH_V6=$(ip -o -6 addr show eth0 2>/dev/null | grep -m1 global | awk '{print $4}' | cut -d/ -f1)
    ETH_C=$(cat /sys/class/net/eth0/carrier 2>/dev/null); ETH_C=${ETH_C:-0}
    # v2.73(2026-10-16 宵断实弹): 数据面判活改**消费 wan_agg 的结论**(/tmp/wan_alive,
    #   每环循实测并发布, 是唯一权威)。根因: 原先三处(wan_agg/led_mgr/api)各有一套
    #   判据且都用 223.5.5.5/120.53.53.53(+ 网关) —— 上行接入网夜间切断的白名单恰好放行
    #   这些, 于是"探测通过而客户端全死", GUI 与灯一起谎报家宽正常、转移也不触发。
    #   ts 过期(>30s, 守护异常)时按"未知"处理(0), 不用旧值猜。
    WAN_ALIVE=$(cat /tmp/wan_alive 2>/dev/null)
    _ah=$(printf '%s' "$WAN_ALIVE" | sed -n 's/.*home=\([01]\).*/\1/p')
    _ac=$(printf '%s' "$WAN_ALIVE" | sed -n 's/.*cell=\([01]\).*/\1/p')
    _at=$(printf '%s' "$WAN_ALIVE" | sed -n 's/.*ts=\([0-9]*\).*/\1/p')
    _fresh=0
    [ -n "$_at" ] && [ $(( $(date +%s) - _at )) -le 30 ] && _fresh=1
    ETH_DP=0; [ "$_fresh" = 1 ] && [ "$_ah" = 1 ] && ETH_DP=1
    C5G_DP=0; [ "$_fresh" = 1 ] && [ "$_ac" = 1 ] && C5G_DP=1
    AGG_M=$(grep -m1 "Current mode" /proc/multi_wan/mode 2>/dev/null | grep -oE "[0-9]+$")
    # v2.42: w1pct 三级回退 — iptables 引擎态 /proc/multi_wan/* 不存在(quecadp 专属),
    # 旧读法永远"?"致 GUI 滑块停在中间不与实配同步。顺序: agg.conf(权威,即写即读)
    # → proc(quecadp 态) → wan_agg 日志 pct=(引擎实跑值)
    AGG_W=$(grep -m1 '^W1_PCT=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    [ -z "$AGG_W" ] && AGG_W=$(grep "WAN1 weight" /proc/multi_wan/weight 2>/dev/null | grep -oE "[0-9]+" | tail -1)
    [ -z "$AGG_W" ] && AGG_W=$(tail -1 /tmp/wan_agg.log 2>/dev/null | grep -oE 'pct=[0-9]+' | head -1 | cut -d= -f2)
    WAN_MODE=$(cat /tmp/wan_mode 2>/dev/null)
    TEMPS=""
    for z in soc_max cpu_little0 cpu_big0 md1 nrpa_ntc ltepa_ntc; do
        for zd in /sys/class/thermal/thermal_zone*; do
            [ "$(cat $zd/type 2>/dev/null)" = "$z" ] && TEMPS="$TEMPS\"$z\":$(cat $zd/temp 2>/dev/null),"
        done
    done
    TEMPS=${TEMPS%,}
    TX5=$(cat /sys/class/net/${W5G_IF:-ccmni0}/statistics/tx_bytes 2>/dev/null); TX5=${TX5:-0}
    RX5=$(cat /sys/class/net/${W5G_IF:-ccmni0}/statistics/rx_bytes 2>/dev/null); RX5=${RX5:-0}
    TXE=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null); TXE=${TXE:-0}
    RXE=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null); RXE=${RXE:-0}
    cat <<EOF2
{"uptime":"${UP_D}天${UP_H}时${UP_M}分","load":"$LOAD","mem":{"total":${MEM%% *},"avail":${MEM##* }},
"wan5g":{"if":"$W5G_IF","ip":"${W5G_IP:-无}","v6":"${W5G_V6:-无}","dp":"$C5G_DP"},
"home":{"ip":"${ETH_IP:-无}","v6":"${ETH_V6:-无}","carrier":"$ETH_C","dp":"$ETH_DP"},
"agg":{"m5":"$(grep -m1 '^MODE=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)","mode":"${AGG_M:-0}","engine":"$(cat /tmp/wan_engine 2>/dev/null)","on":"$(grep -q '^off' /tmp/wan_mode 2>/dev/null && echo 0 || echo 1)","w1pct":"${AGG_W:-?}","state":"$(tail -1 /tmp/wan_agg.log 2>/dev/null | sed 's/"/\\"/g')","wanmode":"$WAN_MODE"},
"wifi":{$(wifi_state)},
"temps":{$TEMPS},
"counters":{"tx5g":"$TX5","rx5g":"$RX5","txeth":"$TXE","rxeth":"$RXE"},
"ts":$(date +%s)}
EOF2
}

# -- 客户端 (lease + arp merge) --
clients_json() {
    cat /tmp/dnsmasq_br.leases 2>/dev/null | sort -k3 | while read _t mac ip name _r; do
        printf '{"mac":"%s","ip":"%s","name":"%s"},' "$mac" "$ip" "$name"
    done
}
get_clients() {
    printf '{"clients":['
    clients_json | sed 's/,$//' | tr -d '\n'
    printf '],"stations":['
    wifi_stations | sed 's/,$//' | tr -d '\n'
    printf '],"ts":%d}' "$(date +%s)"
}

get_sys() {
    I=$(ubus call system info 2>/dev/null)
    [ -n "$I" ] && printf '%s' "$I" || printf '{"error":"ubus"}'
}

get_logs() {
    L=$(tail -20 /tmp/wan_agg.log 2>/dev/null | esc)
    W=$(tail -10 /tmp/wifi_up.log 2>/dev/null | esc)
    # v2.69: +diag — 诊断包尾部(日志改善轮; 脱敏: token/pass/凭据键)
    D=$(tail -c 12000 /data/gw/logs/diag_last.txt 2>/dev/null | tail -n +2 \
        | sed -e 's/token=[0-9a-f]*/token=<redacted>/g' \
              -e 's/pass=[^& ]*/pass=<redacted>/g' \
              -e 's/^\(WPAPSK\)=.*/\1=<redacted>/' \
              -e 's/^\(wpa_psk\)=.*/\1=<redacted>/' \
        | esc)
    printf '{"wan_agg":"%s","wifi":"%s","diag":"%s"}' "$L" "$W" "$D"
}

# -- SSE 事件流 (v2.44): v3httpd v2.4 已发流式响应头, 本端点只持续输出事件。
# 事件 = 服务小区信号(3s节奏); 570s 自退(双保险, EventSource 自动重连)。
get_sse() {
    # v2.48(P1): 全局 SSE 并发上限 — 每连接常驻 570s, 占用 = httpd子进程+api.sh+
    # 周期性 mipc 子进程; 上限 8 足够真实客户端(GUI 单开), 挡批量资源耗尽。
    _n=$(ps | grep -c "[a]pi.sh sse")
    [ "$_n" -gt 8 ] && { printf '{"error":"sse_busy"}'; exit 0; }
    _t=0
    while :; do
        CJ=$(/data/gw/mipc_cellular cells 2>/dev/null | head -1)
        SIG=""
        case "$CJ" in
            '{"serving"'*) SIG=$(printf '%s' "$CJ" | sed 's/^{"serving"://; s/,"cells".*//') ;;
        esac
        [ -z "$SIG" ] && SIG='null'
        printf 'data: {"sig":%s,"ts":%s}

' "$SIG" "$(date +%s)"
        sleep 3
        _t=$((_t+3)); [ $_t -ge 570 ] && exit 0
    done
}
