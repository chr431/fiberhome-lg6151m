#!/bin/sh
# state_edge_lib.sh v1.0 -- 秒级边缘台账的**唯一契约实现**(生产方与消费方共用)
#
# 背景(2026-11-01 M2 状态真值总线轮, 实测缺陷):
#   avail_sampler 的窗口收割按 "ts=$1; id=$3; ev=$4" 解析, 而 avail_watch 的 logf 写的是
#   "epoch <YYYY-MM-DD> <HH:MM:SS> <id> <ev>" —— $3 变成时间戳、$4 变成 id, 映射永远 NOMATCH。
#   实测 /data/gw/logs/avail_edges.tsv 全文 8 行, 按 sampler 的 awk 回放 6 行 NOMATCH, 仅 2 行
#   (历史遗留的 "x gui.serve" 格式)命中。也就是说"秒级边缘 -> 窗口降级"这条防假绿机制
#   **自日志格式改动起静默失效**, 采样器窗口里从来没有边缘降级记录。
#   根因是"字段位置假设"被写死在两个文件里各一份(本项目通病)。
#
# 本文件是该契约的唯一事实源: 字段顺序、id 常量、id->组件映射、解析函数、写入函数。
#   生产方: gw/fast_watch.sh(唯一 1s 循环) -> edge_emit
#   消费方: gw/avail_sampler.sh(10min 窗口收割) -> edge_parse_line + edge_comp_of
#   自检:   sh /data/gw/fast_watch.sh --selftest (往返: 写一行 -> 解析回来 -> 断言 id/组件)
#
# 文件格式(avail_edges.tsv, TAB 分隔, append-only, 4000 行轮转):
#   $1 epoch(秒)  $2 ISO8601(带 T, **不含空格** —— 带空格会把字段位置整体右移一格,
#                    正是上面那次静默失效的直接原因)
#   $3 id(见 EDGE_ID_* 常量)  $4 event(edge_down|edge_up)  $5 flags(boot/maint/drill/-)
EDGE_TAB=$(printf '\t')

# ---- id 常量(唯一事实源; 改名只改这里) ---------------------------------
EDGE_ID_GUI=gui.serve
EDGE_ID_SSH=ssh.banner
EDGE_ID_DNS=dns.pids
EDGE_ID_BR=br.up
EDGE_ID_WPA2=wpa.ra0
EDGE_ID_WPA5=wpa.rai0
EDGE_ID_ETH=eth.carrier
EDGE_IDS="$EDGE_ID_GUI $EDGE_ID_SSH $EDGE_ID_DNS $EDGE_ID_BR $EDGE_ID_WPA2 $EDGE_ID_WPA5 $EDGE_ID_ETH"

# ---- id -> 组件(采样器窗口降级口径; 与 avail_sampler 的组件命名一致) ----
edge_comp_of() {
    case "$1" in
        "$EDGE_ID_GUI")               echo sys.gui ;;
        "$EDGE_ID_SSH")               echo sys.ssh ;;
        "$EDGE_ID_DNS"|"$EDGE_ID_BR") echo lan.bridge ;;
        "$EDGE_ID_WPA2")              echo lan.wifi2g ;;
        "$EDGE_ID_WPA5")              echo lan.wifi5g ;;
        "$EDGE_ID_ETH")               echo wan.ethernet ;;
        *)                            echo "" ;;
    esac
}

# ---- 解析一行(唯一解析实现) --------------------------------------------
# edge_parse_line "<line>" -> 设置 EDGE_TS/EDGE_ISO/EDGE_ID/EDGE_EV/EDGE_FL
#   返回 0=合法; 1=字段不足/时间戳非数字/事件名非法
EDGE_TS=""; EDGE_ISO=""; EDGE_ID=""; EDGE_EV=""; EDGE_FL=""
edge_parse_line() {
    EDGE_TS=""; EDGE_ISO=""; EDGE_ID=""; EDGE_EV=""; EDGE_FL=""
    IFS="$EDGE_TAB" read -r EDGE_TS EDGE_ISO EDGE_ID EDGE_EV EDGE_FL <<EOF
$1
EOF
    case "$EDGE_TS" in ''|*[!0-9]*) EDGE_TS=""; return 1 ;; esac
    case "$EDGE_EV" in edge_down|edge_up) ;; *) EDGE_EV=""; return 1 ;; esac
    [ -n "$EDGE_ID" ] || return 1
    return 0
}

# ---- 写入一行(唯一写入实现) --------------------------------------------
# edge_emit <id> <ok 0|1> <flags> [file]   (默认追加到 /data/gw/logs/avail_edges.tsv)
#   返回 0=写入; 1=参数非法(不写)
edge_emit() {
    _ee_id=$1; _ee_ok=$2; _ee_fl=${3:--}
    _ee_f=${4:-/data/gw/logs/avail_edges.tsv}
    [ -n "$_ee_id" ] || return 1
    case "$_ee_ok" in 0|1) ;; *) return 1 ;; esac
    if [ "$_ee_ok" = 1 ]; then _ee_ev=edge_up; else _ee_ev=edge_down; fi
    _ee_iso=$("$BB" date '+%FT%T' 2>/dev/null)
    [ -n "$_ee_iso" ] || _ee_iso="-"
    case "$_ee_iso" in *" "*) _ee_iso="-" ;; esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$_ee_iso" "$_ee_id" "$_ee_ev" "$_ee_fl" >> "$_ee_f"
    return 0
}
