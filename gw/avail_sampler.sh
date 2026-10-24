#!/bin/sh
# avail_sampler.sh v1.4 -- 组件可用性采样器 (AVAILABILITY_DESIGN §3, 防假绿轮)
#
# 由 log_keeper v2.9 每 10min 调用 (CYC%20 + CYC=1 首采); 单遍有界、无循环、
# 无守护 —— 崩溃只留一行 NE 台账, 下一窗自愈, 覆盖率指标如实扣分。
#
# v1.2 (防假绿轮) —— 历史上四次"全绿撒谎"(L28 WiFi 死 5.7h / v3.44 数据面
#   死载波在 / hostapd 信标停发 / NE 无声发生)的共同根因: 存在性判据冒充
#   结果判据, 且迁移式快照+稀疏采样漏掉短时 outage。本版四类修复:
#   ① 窗口 FAIL 迁移捕获: watchdog_state 是"最后已知态", 采样间隔内发生过
#      又自愈的故障会让快照回绿 —— 用行数游标扫窗口内 watchdog.log 的
#      "FAIL detail <key>" 行, 命中即该窗记 deg (短时不达标也记账);
#   ② 结果探针组合: dp5g/dpeth(IP 在但不通=v3.44 型谎言→deg, 双路皆死→
#      wan.agg 记 down)、http200/dnssvc(监听≠在服务; 实测 127 探测不可达,
#      必须打 LAN 地址 192.168.9.1)、authd_state 会话态(进程在≠会话活);
#   ③ 管线/内核活性: dpclamp sweeps 计数不前进→kernel deg、stability_metrics
#      停更>16min→logging deg (进程在≠管线在);
#   ④ WiFi 结果信号: wifi_guard 告警窗 / dmesg reason=3 风暴(L28"连上即断")
#      → 双频组件 deg; usb 未启用记 off(不冒充绿)。
#
# 纪律: busybox awk 只用标量累加 (数组清理缺陷教训, 见 log_keeper v2.7);
#       NE 归属三规则 (§2): args 含守护脚本名 / exe==守护本体 / 其余不归属。

DIR=/data/gw/logs
ST=/tmp/watchdog_state
LASTF=/tmp/avail_last
SESS=/tmp/avail_sess
HB=/tmp/avail_sampler.hb
HF=$DIR/avail_hourly.tsv
DF=$DIR/avail_daily.tsv
TF=$DIR/avail_transitions.tsv

NOW=$(date +%s)
HOUR=$(date +%Y%m%d%H)
TODAY=$(date +%Y%m%d)
touch "$HF" "$DF" "$TF" 2>/dev/null   # 首采即存在 (内容仍只在小时/跨日边界写入)

cut -d. -f1 /proc/uptime > "$HB" 2>/dev/null

kv() { grep "^$1=" "$ST" 2>/dev/null | tail -1 | cut -d= -f2; }
lk() { # watchdog 键 → 级别
    case "$(kv "$1")" in
        0) echo op ;;
        1) echo down ;;
        *) echo nodata ;;
    esac
}
lks() { # 多键 AND: 任一 down→down, 任一 nodata→nodata, 全 op→op
    _r=op
    for _k in "$@"; do
        _v=$(lk "$_k")
        [ "$_v" = down ] && { echo down; return; }
        [ "$_v" = nodata ] && _r=nodata
    done
    echo "$_r"
}

# ---- 监督层新鲜度 (watchdog cycle 键, >120s = 监督失明) ----
CY=$(kv cycle); FRESH=0
case "$CY" in ''|*[!0-9]*) ;; *) [ $((NOW - CY)) -le 120 ] && FRESH=1 ;; esac

# ---- 窗口信号: 行数游标 (rotation 收缩时取 head 近似, 覆盖率自会体现) ----
lc() { wc -l < "$1" 2>/dev/null || echo 0; }
WL=$(lc /tmp/watchdog.log); SL=$(lc "$DIR/syslog.log")
NL=$(lc "$DIR/ne_events.tsv"); RL=$(lc "$DIR/netcfg_repairs.tsv")
AL=$(lc /tmp/api.log); DL=$(lc "$DIR/dmesg.log")
oWL=$(sed -n '2p' "$SESS" 2>/dev/null); oSL=$(sed -n '3p' "$SESS" 2>/dev/null)
oNL=$(sed -n '4p' "$SESS" 2>/dev/null); oRL=$(sed -n '5p' "$SESS" 2>/dev/null)
oTS=$(sed -n '6p' "$SESS" 2>/dev/null); oSW=$(sed -n '8p' "$SESS" 2>/dev/null)
oAL=$(sed -n '9p' "$SESS" 2>/dev/null); oDL=$(sed -n '10p' "$SESS" 2>/dev/null)
[ -n "$oWL" ] || { oWL=$WL; oSL=$SL; oNL=$NL; oRL=$RL; oAL=$AL; oDL=$DL; }

WINT=/tmp/avail_win.$$
new_lines() { # $1=file $2=old $3=cur
    if [ "$3" -ge "$2" ] 2>/dev/null; then
        tail -n +$(( $2 + 1 )) "$1" 2>/dev/null
    else
        head -n "$3" "$1" 2>/dev/null
    fi
}
new_lines /tmp/watchdog.log "$oWL" "$WL"       > "$WINT.wl"
new_lines "$DIR/syslog.log" "$oSL" "$SL"       > "$WINT.sl"
new_lines "$DIR/ne_events.tsv" "$oNL" "$NL"    > "$WINT.ne"
new_lines "$DIR/netcfg_repairs.tsv" "$oRL" "$RL" > "$WINT.rl"
new_lines /tmp/api.log "$oAL" "$AL"            > "$WINT.al"
new_lines "$DIR/dmesg.log" "$oDL" "$DL"        > "$WINT.dl"

# ① 窗口 FAIL 迁移: 采样间隔内发生过又自愈的故障, 快照已回绿, 此处记账
sed -n 's/.*FAIL detail \([a-z0-9_]*\).*/\1/p' "$WINT.wl" | sort -u > "$WINT.fk"

# 守护重启信号 (EVT restart 行 + logger "restarted X" 行)
{ sed -n 's/.*EVT restart \([a-z_0-9]*\).*/\1/p' "$WINT.wl"
  sed -n 's/.*restarted \([a-z_0-9]*\).*/\1/p' "$WINT.sl"; } | sort -u > "$WINT.rst"

# NE 窗口行数 + 可归属组件 (三规则; 未归属 → 全局噪声, 不摊派)
NE_N=$(wc -l < "$WINT.ne" 2>/dev/null || echo 0)
: > "$WINT.nea"
while IFS= read -r _l; do
    case "$_l" in
        *"/data/gw/led_mgr.sh"*)    echo feat.led ;;
        *"/data/gw/fan_mgr.sh"*)    echo feat.fan ;;
        *"/data/gw/ntp_keeper.sh"*) echo feat.ntp ;;
        *"/data/gw/dial_keeper.sh"*) echo wan.cellular ;;
        *"/data/gw/wan_eth.sh"*)    echo wan.ethernet ;;
        *"/data/gw/wan_agg.sh"*)    echo wan.agg ;;
        *"/data/gw/log_keeper.sh"*) echo sys.logging ;;
        *"/data/gw/healthdog.sh"*)  echo sys.kernel ;;
        *"/data/gw/watchdog.sh"*)   echo sys.supervisor ;;
        *"/data/gw/reboot_sched.sh"*) echo feat.reboot ;;
        *"/data/gw/usb_mgr.sh"*)    echo feat.usb ;;
        *"/data/gw/traffic_logger.sh"*) echo sys.logging ;;
        *"hostapd"*)                echo lan.wifi2g ;;
        *"dnsmasq"*)                echo lan.bridge ;;
    esac
done < "$WINT.ne" >> "$WINT.nea"
sort -u "$WINT.nea" -o "$WINT.nea" 2>/dev/null

# v1.4: grep -c 无匹配时输出 0 且 exit 1, "|| echo 0" 会拼出两行坏数值
# (bad number 实弹); 计数变量一律 case 守卫归零
num0() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
# 两步式取数: 避免 "$(... "$x" ...)" 双层嵌套引号(ash 解析器分歧点)
_t=$(wc -l < "$WINT.rl" 2>/dev/null);               REP_N=$(num0 "$_t")
_t=$(grep -c 'sms send failed' "$WINT.al" 2>/dev/null); SMS_FAIL=$(num0 "$_t")
_t=$(grep -c 'wifi_guard' "$WINT.sl" 2>/dev/null);  WIFI_GUARD_WARN=$(num0 "$_t")
_t=$(grep -c 'reason=3' "$WINT.dl" 2>/dev/null);    DEAUTH_N=$(num0 "$_t")
NE_N=$(num0 "$NE_N")

sig_has() { grep -qx "$2" "$1" 2>/dev/null; }
ne_attr() { sig_has "$WINT.nea" "$1"; }
fail_key_hit() { # $1=该组件主判据键集(空格分隔), 任一在窗口内 FAIL 过
    for _k in $1; do
        grep -qx "$_k" "$WINT.fk" 2>/dev/null && return 0
    done
    return 1
}
rst_attr() {
    case "$1" in
        led_mgr) echo feat.led ;; fan_mgr) echo feat.fan ;;
        ntp_keeper) echo feat.ntp ;; dial_keeper) echo wan.cellular ;;
        wan_eth) echo wan.ethernet ;; wan_agg) echo wan.agg ;;
        log_keeper) echo sys.logging ;; healthdog) echo sys.kernel ;;
        reboot_sched) echo feat.reboot ;; usb_mgr) echo feat.usb ;;
        traffic_logger) echo sys.logging ;; wifi_guard) echo lan.wifi2g ;;
        core_trap) echo sys.kernel ;; boot_gate) echo sys.boot ;;
        atcid) echo feat.cellctl ;;
        *) echo "" ;;
    esac
}
RST_COMPS=""
while IFS= read -r _d; do
    _c=$(rst_attr "$_d")
    [ -n "$_c" ] && RST_COMPS="$_c
$RST_COMPS"
done < "$WINT.rst"

# ---- 配置态 (off 判定) ----
. /data/gw/defaults.conf 2>/dev/null
. /data/gw/settings.conf 2>/dev/null
GUEST_ON=0; [ "${GUEST:-0}" = 1 ] && GUEST_ON=1
AUTH_ON=0; [ -f /data/gw/uplink.conf ] && AUTH_ON=1
USB_ON=0;  [ "${USB_ENABLED:-0}" = 1 ] && USB_ON=1

# ---- ③ 管线/内核活性 ----
# dpclamp sweep 计数前进 (修复栈 kthread 活着且在巡检; 计数不动=卡死)
SW=$(sed -n 's/^dpclamp v1.[0-9]* sweeps=\([0-9]*\).*/\1/p' /proc/dpclamp 2>/dev/null)
SW_STUCK=0
if [ -n "$SW" ] && [ -n "$oSW" ] && [ "$SW" = "$oSW" ]; then SW_STUCK=1; fi
# 日志管线结果: stability_metrics 停更 (5min 节拍, >16min 视为断流)
# v1.3: 活性时刻读台账末行首列 epoch —— busybox date -r 是 RFC2822 输出语义
#       非文件 mtime(演练轮实测 bad number), 设备又无 stat; 台账自带 epoch。
MET_STALE=0
_mt=$(tail -1 "$DIR/stability_metrics.tsv" 2>/dev/null | cut -f1)
case "$_mt" in ''|*[!0-9]*) _mt=0 ;; esac
[ "$_mt" -gt 0 ] && [ $((NOW - _mt)) -gt 960 ] && MET_STALE=1
# authd 会话态 (进程在≠会话活; 静默切断型故障的会话级判据)
AUTH_DOWN=0
if [ "$AUTH_ON" = 1 ]; then
    _as=$(head -1 /tmp/authd_state 2>/dev/null | cut -d' ' -f1)
    [ "$_as" = "down" ] && AUTH_DOWN=1
fi

# ---- 组件表 (id|显示名|组|判据) — 单点维护, api 侧 roster 与此同源 ----
TABLE='
sys.boot|启动链|系统|K:bootgate+boot
sys.kernel|内核/修复栈|系统|s:kernel
sys.supervisor|监督层|系统|s:supervisor
sys.logging|日志管线|系统|s:logging
sys.gui|网关 GUI|系统|s:gui
sys.ssh|SSH 管理|系统|k:port22
lan.bridge|LAN/DHCP/DNS|局域网|s:bridge
lan.wifi2g|WiFi 2.4G|局域网|s:wifi2g
lan.wifi5g|WiFi 5G|局域网|s:wifi5g
lan.guest|访客网络|局域网|s:guest
lan.radvd|IPv6 通告|局域网|s:radvd6
wan.cellular|5G 蜂窝|上行|s:cell5g
wan.ethernet|以太 WAN|上行|s:ethdp
wan.agg|聚合引擎|上行|s:aggdp
wan.auth|上行认证|上行|s:auth
wan.nat|NAT/防火墙|上行|k:nat
feat.cellctl|蜂窝控制面|功能|s:cellctl
feat.sms|短信|功能|s:sms
feat.usb|USB 设备模式|功能|s:usb
feat.led|LED 指示|功能|k:led_mgr
feat.fan|温控/风扇|功能|k:fan_mgr
feat.ntp|NTP 守时|功能|k:ntp_keeper
feat.reboot|定时重启|功能|k:reboot_sched
qual.coverage|观测覆盖|数据质量|s:coverage
'

# 每组件的主判据键集 (供 fail_key_hit 匹配窗口 FAIL 迁移)
KEYS_OF() {
    case "$1" in
    sys.boot)       echo "bootgate boot" ;;
    sys.kernel)     echo "" ;;
    sys.supervisor) echo "" ;;
    sys.logging)    echo "log_keeper" ;;
    sys.gui)        echo "port80 http200" ;;
    sys.ssh)        echo "port22" ;;
    lan.bridge)     echo "dnsmasq lan_ip lo_up dnssvc" ;;
    lan.wifi2g)     echo "bss2g bss hostapd wifi_guard" ;;
    lan.wifi5g)     echo "bss5g bss hostapd wifi_guard" ;;
    lan.guest)      echo "bss_guest" ;;
    lan.radvd)      echo "radvd" ;;
    wan.cellular)   echo "ccmni_up dial_keeper modem_reg dp5g" ;;
    wan.ethernet)   echo "wan_eth dpeth" ;;
    wan.agg)        echo "wan_agg agg_rules fwmark" ;;
    wan.auth)       echo "authd" ;;
    wan.nat)        echo "nat" ;;
    feat.cellctl)   echo "mipc_tool atcid" ;;
    feat.sms)       echo "" ;;
    feat.usb)       echo "usb_mgr" ;;
    feat.led)       echo "led_mgr" ;;
    feat.fan)       echo "fan_mgr" ;;
    feat.ntp)       echo "ntp_keeper" ;;
    feat.reboot)    echo "reboot_sched" ;;
    qual.coverage)  echo "" ;;
    esac
}

level_of() { # $1=判据串 → 级别 (op/deg/down/nodata/off)
    case "$1" in
    s:kernel)
        lsmod 2>/dev/null | grep -q '^dpquar ' || { echo down; return; }
        lsmod 2>/dev/null | grep -q '^dpclamp ' || { echo down; return; }
        head -1 /proc/dpquar 2>/dev/null | grep -q 'patched=1' || { echo down; return; }
        if [ "$SW_STUCK" = 1 ] || [ "${NE_N:-0}" -ge 4 ]; then echo deg; else echo op; fi
        ;;
    s:supervisor)
        [ "$FRESH" = 1 ] && echo op || echo down
        ;;
    s:logging)
        _v=$(lk log_keeper)
        if [ "$_v" = op ] && [ "$MET_STALE" = 1 ]; then echo deg; else echo "$_v"; fi
        ;;
    s:gui)
        # v1.33+: 监听(port80) AND 在服务(http200); 旧 watchdog 无该键时回退 port80
        case "$(kv http200)" in 0|1) lks port80 http200 ;; *) lk port80 ;; esac
        ;;
    s:bridge)
        case "$(kv dnssvc)" in 0|1) lks dnsmasq lan_ip lo_up dnssvc ;; *) lks dnsmasq lan_ip lo_up ;; esac
        ;;
    s:guest)
        [ "$GUEST_ON" = 1 ] || { echo off; return; }
        lk bss_guest
        ;;
    s:auth)
        [ "$AUTH_ON" = 1 ] || { echo off; return; }
        [ "$AUTH_DOWN" = 1 ] && { echo down; return; }
        lk authd
        ;;
    s:radvd6)
        ip -6 addr show br-lan 2>/dev/null | grep -q 'fd42:9ac1:7e50' || { echo off; return; }
        lk radvd
        ;;
    s:usb)
        [ "$USB_ON" = 1 ] || { echo off; return; }
        lk usb_mgr
        ;;
    s:coverage)
        if [ -n "$oTS" ] && [ $((NOW - oTS)) -gt 1500 ]; then echo deg; else echo op; fi
        ;;
    s:wifi2g)
        _v=$(lk bss2g); [ "$_v" = nodata ] && _v=$(lk bss); echo "$_v"
        ;;
    s:wifi5g)
        _v=$(lk bss5g); [ "$_v" = nodata ] && _v=$(lk bss); echo "$_v"
        ;;
    s:cell5g)
        _v=$(lks ccmni_up dial_keeper modem_reg)
        # v3.44 型谎言: IP 在(键绿)但数据面探针死 → deg; 双路全死由 agg 记 down
        if [ "$_v" = op ] && [ "$(kv dp5g)" = 1 ]; then echo deg; else echo "$_v"; fi
        ;;
    s:ethdp)
        _v=$(lk wan_eth)
        if [ "$_v" = op ] && [ "$(kv dpeth)" = 1 ]; then echo deg; else echo "$_v"; fi
        ;;
    s:aggdp)
        _v=$(lks wan_agg agg_rules fwmark)
        if [ "$_v" = op ] && [ "$(kv dp5g)" = 1 ] && [ "$(kv dpeth)" = 1 ]; then echo down
        else echo "$_v"; fi
        ;;
    s:cellctl)
        lks mipc_tool atcid
        ;;
    s:sms)
        lk mipc_tool
        ;;
    k:*)  lk "${1#k:}" ;;
    K:*)  lks $(echo "${1#K:}" | tr '+' ' ') ;;
    *)    echo nodata ;;
    esac
}

# ---- 会话直方图 (当前小时累计; 换小时落盘) ----
CUR_HOUR=$(sed -n '1p' "$SESS" 2>/dev/null)
HIST=/tmp/avail_hist
[ "$CUR_HOUR" = "$HOUR" ] || {
    if [ -s "$HIST" ]; then
        while IFS='|' read -r _id _ok _deg _down _nod _mai; do
            [ -n "$_id" ] && echo "$CUR_HOUR|$_id|$_ok|$_deg|$_down|$_nod|$_mai" >> "$HF"
        done < "$HIST"
    fi
    : > "$HIST"
    CUR_HOUR=$HOUR
}
bump() { # $1=id $2=level → 直方图 +1
    _f=/tmp/avail_h.$$
    grep -v "^$1|" "$HIST" 2>/dev/null > "$_f"
    _l=$(grep "^$1|" "$HIST" 2>/dev/null | head -1)
    _ok=0; _deg=0; _down=0; _nod=0; _mai=0
    [ -n "$_l" ] && { _ok=$(echo "$_l" | cut -d'|' -f2); _deg=$(echo "$_l" | cut -d'|' -f3)
        _down=$(echo "$_l" | cut -d'|' -f4); _nod=$(echo "$_l" | cut -d'|' -f5); _mai=$(echo "$_l" | cut -d'|' -f6); }
    case "$2" in
        op) _ok=$((_ok + 1)) ;; deg) _deg=$((_deg + 1)) ;;
        down) _down=$((_down + 1)) ;; nodata) _nod=$((_nod + 1)) ;;
        mai) _mai=$((_mai + 1)) ;;
    esac
    echo "$1|$_ok|$_deg|$_down|$_nod|$_mai" >> "$_f"
    mv "$_f" "$HIST"
}

# ---- 主循环: 组件表 → 级别 → 窗口信号 → 迁移/直方图/快照 ----
PREV=/tmp/avail_prev.$$
cp "$LASTF" "$PREV" 2>/dev/null
: > "$LASTF"

# 维护窗: 今日 reboots.log 有定时重启行 → 该 boot 前 4 分钟记 mai
MAI_BOOT=0
_rb=$(tail -1 "$DIR/reboots.log" 2>/dev/null)
case "$_rb" in
    "$(date +%Y-%m-%d)"*REBOOT*) MAI_BOOT=1 ;;
esac
_up=$(cut -d. -f1 /proc/uptime)
[ "$MAI_BOOT" = 1 ] && [ "$_up" -lt 240 ] && MAI_WIN=1 || MAI_WIN=0

echo "$TABLE" | while IFS='|' read -r id name grp src; do
    [ -n "$id" ] || continue
    lv=$(level_of "$src")
    # 窗口信号叠加 (只降 op→deg)
    if [ "$lv" = op ]; then
        _keys=$(KEYS_OF "$id")
        if ne_attr "$id" || printf '%s\n' "$RST_COMPS" | grep -qx "$id" \
           || fail_key_hit "$_keys"; then
            lv=deg
        fi
        [ "$id" = wan.nat ] && [ "${REP_N:-0}" -gt 5 ] && lv=deg
        [ "$id" = feat.sms ] && [ "${SMS_FAIL:-0}" -gt 0 ] && lv=deg
        # WiFi 面结果信号: 守卫告警窗 / 关联拒绝风暴 (L28 "连上即断 reason=3")
        if [ "$id" = lan.wifi2g ] || [ "$id" = lan.wifi5g ]; then
            [ "${WIFI_GUARD_WARN:-0}" -gt 0 ] && lv=deg
            [ "${DEAUTH_N:-0}" -gt 20 ] && lv=deg
        fi
    fi
    if [ "$MAI_WIN" = 1 ] && [ "$lv" != down ]; then lv=mai; fi
    bump "$id" "$lv"
    echo "$id|$name|$grp|$lv" >> "$LASTF"
    # 迁移检测 (跳过首采/无前值; off 不出事件)
    pv=$(grep "^$id|" "$PREV" 2>/dev/null | head -1 | cut -d'|' -f4)
    if [ -n "$pv" ] && [ "$pv" != "$lv" ] && [ "$lv" != off ] && [ "$pv" != off ]; then
        cause="-"
        ne_attr "$id" && cause="NE"
        printf '%s\n' "$RST_COMPS" | grep -qx "$id" && cause="restart"
        fail_key_hit "$(KEYS_OF "$id")" && cause="probe"
        [ "$id" = wan.nat ] && [ "${REP_N:-0}" -gt 5 ] && cause="repair"
        [ "$id" = feat.sms ] && [ "${SMS_FAIL:-0}" -gt 0 ] && cause="sms"
        { [ "$id" = lan.wifi2g ] || [ "$id" = lan.wifi5g ]; } && \
            { [ "${WIFI_GUARD_WARN:-0}" -gt 0 ] || [ "${DEAUTH_N:-0}" -gt 20 ]; } && cause="wifi"
        [ "$lv" = mai ] || [ "$pv" = mai ] && cause="maint"
        echo "$NOW	$id	$pv->$lv	$cause" >> "$TF"
    fi
done

# ---- 会话态原子更新 (10 行: hour/wl/sl/ne/rl/last_ts/day/sweeps/apiCur/dmesgCur) ----
S=/tmp/avail_sess.$$
oDAY=$(sed -n '7p' "$SESS" 2>/dev/null)
{ echo "$HOUR"; echo "$WL"; echo "$SL"; echo "$NL"; echo "$RL"
  echo "$NOW"; echo "$TODAY"; echo "${SW:-0}"; echo "$AL"; echo "$DL"; } > "$S"
mv "$S" "$SESS"

# ---- 跨日归并: 用更新前会话日, 从 HF 归并该日 → DF ----
if [ -n "$oDAY" ] && [ "$oDAY" != "$TODAY" ]; then
    YD=$oDAY
    echo "$TABLE" | while IFS='|' read -r id name grp src; do
        [ -n "$id" ] || continue
        awk -v d="$YD" -v c="$id" -F'|' \
            'substr($1,1,8)==d && $2==c {ok+=$3; deg+=$4; dn+=$5; nd+=$6; mi+=$7}
             END {if (ok+deg+dn+nd+mi > 0) printf "%s|%s|%d|%d|%d|%d|%d\n", d, c, ok, deg, dn, nd, mi}' \
            "$HF" >> "$DF"
    done
    tail -n 600 "$DF" > "$DF.tmp" 2>/dev/null && mv "$DF.tmp" "$DF"
fi

# ---- rotate ----
[ "$(wc -l < "$HF" 2>/dev/null || echo 0)" -gt 2400 ] && \
    { tail -n 2400 "$HF" > "$HF.tmp" && mv "$HF.tmp" "$HF"; }
[ "$(wc -l < "$TF" 2>/dev/null || echo 0)" -gt 2000 ] && \
    { tail -n 2000 "$TF" > "$TF.tmp" && mv "$TF.tmp" "$TF"; }

rm -f "$WINT".* "$PREV" 2>/dev/null
exit 0
