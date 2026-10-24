#!/bin/sh
# avail_sampler.sh v1.0 -- 组件可用性采样器 (docs/AVAILABILITY_DESIGN.md §3)
#
# 由 log_keeper v2.9 每 10min 调用 (CYC%20 + CYC=1 首采); 单遍有界、无循环、
# 无守护 —— 崩溃只留一行 NE 台账, 下一窗自愈, 覆盖率指标如实扣分。
#
# 输入 (判据全部复用监督面, 本脚本不发明第二套探针):
#   /tmp/watchdog_state   0=ok/1=fail 迁移式快照 + cycle=<epoch> 新鲜度键
#   /data/gw/settings.conf, /proc/dpquar, /proc/dpclamp, lsmod
#   窗口信号: ne_events.tsv / netcfg_repairs.tsv / watchdog EVT (行数游标法)
# 输出:
#   /data/gw/logs/avail_hourly.tsv     小时直方图 (rotate 2400 行 ≈100 天)
#   /data/gw/logs/avail_daily.tsv      日滚动 (跨日首采时从 hourly 归并)
#   /data/gw/logs/avail_transitions.tsv 状态迁移事件 (rotate 2000)
#   /tmp/avail_last                    当前快照 id|名|组|level (API roster/now)
#   /tmp/avail_sess                    游标+直方图会话态
#   /tmp/avail_sampler.hb              svc_hb 兼容心跳
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

# ---- 监督层新鲜度 (watchdog v1.31 cycle 键, >120s = 监督失明) ----
CY=$(kv cycle); FRESH=0
case "$CY" in ''|*[!0-9]*) ;; *) [ $((NOW - CY)) -le 120 ] && FRESH=1 ;; esac

# ---- 窗口信号: 行数游标 (rotation 收缩时取 head 近似, 覆盖率自会体现) ----
lc() { wc -l < "$1" 2>/dev/null || echo 0; }
WL=$(lc /tmp/watchdog.log); SL=$(lc "$DIR/syslog.log")
NL=$(lc "$DIR/ne_events.tsv"); RL=$(lc "$DIR/netcfg_repairs.tsv")
oWL=$(sed -n '2p' "$SESS" 2>/dev/null); oSL=$(sed -n '3p' "$SESS" 2>/dev/null)
oNL=$(sed -n '4p' "$SESS" 2>/dev/null); oRL=$(sed -n '5p' "$SESS" 2>/dev/null)
oTS=$(sed -n '6p' "$SESS" 2>/dev/null)
[ -n "$oWL" ] || { oWL=$WL; oSL=$SL; oNL=$NL; oRL=$RL; }   # 首采零窗

WINT=/tmp/avail_win.$$
new_lines() { # $1=file $2=old $3=cur → 窗口切片落 $WINT.<tag>
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

REP_N=$(wc -l < "$WINT.rl" 2>/dev/null || echo 0)

sig_has() { # $1=信号文件 $2=词
    grep -qx "$2" "$1" 2>/dev/null
}
ne_attr() { sig_has "$WINT.nea" "$1"; }
rst_attr() { # EVT 守护名 → 组件 id 映射
    case "$1" in
        led_mgr) echo feat.led ;; fan_mgr) echo feat.fan ;;
        ntp_keeper) echo feat.ntp ;; dial_keeper) echo wan.cellular ;;
        wan_eth) echo wan.ethernet ;; wan_agg) echo wan.agg ;;
        log_keeper) echo sys.logging ;; healthdog) echo sys.kernel ;;
        reboot_sched) echo feat.reboot ;; usb_mgr) echo feat.usb ;;
        traffic_logger) echo sys.logging ;; wifi_guard) echo lan.wifi2g ;;
        core_trap) echo sys.kernel ;; boot_gate) echo sys.boot ;;
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

# ---- 组件表 (id|显示名|组|判据) — 单点维护, api 侧 roster 与此同源 ----
# 判据: k:key  K:k1+k2(AND)  s:kernel  s:supervisor  s:guest  s:auth  s:coverage
#       wifi 频段键缺时回退合并键 bss (旧 watchdog 兼容)
TABLE='
sys.boot|启动链|系统|K:bootgate+boot
sys.kernel|内核/修复栈|系统|s:kernel
sys.supervisor|监督层|系统|s:supervisor
sys.logging|日志管线|系统|k:log_keeper
sys.gui|网关 GUI|系统|k:port80
sys.ssh|SSH 管理|系统|k:port22
lan.bridge|LAN/DHCP/DNS|局域网|K:dnsmasq+lan_ip+lo_up
lan.wifi2g|WiFi 2.4G|局域网|s:wifi2g
lan.wifi5g|WiFi 5G|局域网|s:wifi5g
lan.guest|访客网络|局域网|s:guest
lan.radvd|IPv6 通告|局域网|k:radvd
wan.cellular|5G 蜂窝|上行|K:ccmni_up+dial_keeper
wan.ethernet|以太 WAN|上行|k:wan_eth
wan.agg|聚合引擎|上行|K:wan_agg+agg_rules+fwmark
wan.auth|上行认证|上行|s:auth
wan.nat|NAT/防火墙|上行|k:nat
feat.cellctl|蜂窝控制面|功能|k:mipc_tool
feat.sms|短信|功能|k:mipc_tool
feat.usb|USB 设备模式|功能|k:usb_mgr
feat.led|LED 指示|功能|k:led_mgr
feat.fan|温控/风扇|功能|k:fan_mgr
feat.ntp|NTP 守时|功能|k:ntp_keeper
feat.reboot|定时重启|功能|k:reboot_sched
qual.coverage|观测覆盖|数据质量|s:coverage
'

level_of() { # $1=判据串 → 级别 (op/deg/down/nodata/off)
    case "$1" in
    s:kernel)
        lsmod 2>/dev/null | grep -q '^dpquar ' || { echo down; return; }
        lsmod 2>/dev/null | grep -q '^dpclamp ' || { echo down; return; }
        head -1 /proc/dpquar 2>/dev/null | grep -q 'patched=1' || { echo down; return; }
        if [ "${NE_N:-0}" -ge 4 ]; then echo deg; else echo op; fi
        ;;
    s:supervisor)
        [ "$FRESH" = 1 ] && echo op || echo down
        ;;
    s:guest)
        [ "$GUEST_ON" = 1 ] || { echo off; return; }
        lk bss_guest
        ;;
    s:auth)
        [ "$AUTH_ON" = 1 ] || { echo off; return; }
        lk authd
        ;;
    s:coverage)
        # 上一采龄 >25min = 有窗丢失 (本采自己在跑, 至少 op)
        if [ -n "$oTS" ] && [ $((NOW - oTS)) -gt 1500 ]; then echo deg; else echo op; fi
        ;;
    s:wifi2g)
        _v=$(lk bss2g); [ "$_v" = nodata ] && _v=$(lk bss); echo "$_v"
        ;;
    s:wifi5g)
        _v=$(lk bss5g); [ "$_v" = nodata ] && _v=$(lk bss); echo "$_v"
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
    # 落上一小时直方图 (若有累计)
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

# ---- 主循环: 组件表 → 级别 → 降级信号 → 迁移/直方图/快照 ----
PREV=/tmp/avail_prev.$$
cp "$LASTF" "$PREV" 2>/dev/null
: > "$LASTF"
: > /tmp/avail_inc.$$

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
    # 降级信号叠加 (只降 op→deg)
    if [ "$lv" = op ]; then
        if ne_attr "$id" || printf '%s\n' "$RST_COMPS" | grep -qx "$id"; then
            lv=deg
        fi
        if [ "$id" = wan.nat ] && [ "${REP_N:-0}" -gt 5 ]; then lv=deg; fi
    fi
    # 维护窗: 计划重启后 4 分钟内的非故障态记 mai (不充绿)
    if [ "$MAI_WIN" = 1 ] && [ "$lv" != down ]; then lv=mai; fi
    bump "$id" "$lv"
    echo "$id|$name|$grp|$lv" >> "$LASTF"
    # 迁移检测 (跳过首采/无前值; off 不出事件)
    pv=$(grep "^$id|" "$PREV" 2>/dev/null | head -1 | cut -d'|' -f4)
    if [ -n "$pv" ] && [ "$pv" != "$lv" ] && [ "$lv" != off ] && [ "$pv" != off ]; then
        cause="-"
        ne_attr "$id" && cause="NE"
        printf '%s\n' "$RST_COMPS" | grep -qx "$id" && cause="restart"
        [ "$id" = wan.nat ] && [ "${REP_N:-0}" -gt 5 ] && cause="repair"
        [ "$lv" = mai ] || [ "$pv" = mai ] && cause="maint"
        echo "$NOW	$id	$pv->$lv	$cause" >> "$TF"
    fi
done
# 注意: 上面的 while 在管道子壳里, 直方图/计数 side-effect 需在父壳 —
# 故 bump 与 TF 写入均在子壳内完成 (文件 append 天然跨子壳可见), 计数器
# 变量不跨子壳 — 本设计里子壳只做文件写, 无父壳回读, 成立。

# ---- 会话态原子更新 (7 行: hour/WL/SL/NL/RL/last_ts/day) ----
S=/tmp/avail_sess.$$
oDAY=$(sed -n '7p' "$SESS" 2>/dev/null)
{ echo "$HOUR"; echo "$WL"; echo "$SL"; echo "$NL"; echo "$RL"; echo "$NOW"; echo "$TODAY"; } > "$S"
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

rm -f "$WINT".* "$PREV" /tmp/avail_inc.$$ 2>/dev/null
exit 0
