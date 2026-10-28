#!/bin/sh
# api_avail.sh v1.2 -- API 可用性域模块 (AVAILABILITY_DESIGN §4.1)
# v1.2 (SIGSEGV Phase 1): 数值聚合(今日实时 + 24h 覆盖率)改纯 shell 单遍累加,
#   不再使用 awk 的 printf 路径 —— 该聚合每次 GUI 轮询都跑, 崩一次就往
#   ne_events.tsv 记一笔(origin=our-tree), 直接污染可用性基线; 2026-10-25 台账
#   最后一行即此段 awk 崩溃。仅保留两处不带 printf 的 awk 过滤/计数。
# GET avail: 组件名单/当前态/90 天日条/事件表 — 只读聚合, 无写路径。
# 数据源: /tmp/avail_last(名单+now, sampler 写) + avail_daily.tsv(历史日)
#        + avail_hourly.tsv(今日实时) + avail_transitions.tsv(事件)
# 纪律: busybox awk 仅标量累加(无数组); ash 无子壳变量回传 — 循环一律
#       `while ... done < 文件` 重定向式(当前 shell), 不用 `cmd | while`。

HIST=/data/gw/logs/avail_hourly.tsv
DAILY=/data/gw/logs/avail_daily.tsv
TRANS=/data/gw/logs/avail_transitions.tsv
LAST=/tmp/avail_last
T=/tmp/avail_api.$$

lvl_cn() { case "$1" in op) echo 正常 ;; deg) echo 降级 ;; down) echo 故障 ;; nodata) echo 无数据 ;; mai) echo 维护 ;; off) echo 停用 ;; *) echo "$1" ;; esac; }
worst_rank() { case "$1" in down) echo 0 ;; deg) echo 1 ;; nodata) echo 2 ;; op) echo 3 ;; *) echo 4 ;; esac; }

# day_pct ok deg down nod mai → "pct cls" (degraded 半权; 维护/无数据不进分母)
day_pct() {
    _den=$(( $1 + $2 + $3 ))
    if [ "$_den" -le 0 ]; then
        if [ "$5" -gt 0 ]; then echo "0 mai"; else echo "0 nod"; fi
        return
    fi
    _pct=$(( ( $1 * 100 + $2 * 50 ) / _den ))
    if [ "$3" -gt 0 ]; then echo "$_pct dn"
    elif [ "$2" -gt 0 ] || [ "$_pct" -lt 100 ]; then echo "$_pct dg"
    else echo "100 ok"; fi
}

get_avail() {
    if [ ! -s "$LAST" ]; then
        printf '{"ok":true,"warming":true,"components":[]}'
        return
    fi
    TODAY=$(date +%Y%m%d)
    YDAY=$(date +%Y%m%d -d "yesterday" 2>/dev/null || date -v-1d +%Y%m%d 2>/dev/null || echo "$TODAY")

    # overall: 上行组最差优先, 其余组仅在更差时接管
    OV="op"; OVR=9
    while IFS='|' read -r id name grp lv; do
        [ -n "$id" ] || continue
        r=$(worst_rank "$lv")
        if [ "$grp" = "上行" ]; then
            if [ "$r" -lt "$OVR" ]; then OV="$lv"; OVR=$r; fi
        elif [ "$r" -lt "$OVR" ] && [ "$OVR" -gt 2 ]; then OV="$lv"; OVR=$r; fi
    done < "$LAST"

    # 近 24h 覆盖率 (nodata 占比反向; v1.1: 并入当前小时在累计的 avail_hist)
    # v1.2 (SIGSEGV Phase 1): 同样改纯 shell, 覆盖率用整数运算出一位小数
    #   (四舍五入), 不再借 awk 的 printf —— 与下面组件聚合同一个理由。
    _ok=0; _dg=0; _dn=0; _nd=0
    while IFS='|' read -r _d _c _a _b _e _f _g; do
        case "$_d" in "$TODAY"*|"$YDAY"*) ;; *) continue ;; esac
        case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
        case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
        case "$_e" in ''|*[!0-9]*) _e=0 ;; esac
        case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
        _ok=$((_ok + _a)); _dg=$((_dg + _b)); _dn=$((_dn + _e)); _nd=$((_nd + _f))
    done < "$HIST"
    if [ -r /tmp/avail_hist ]; then
        while IFS='|' read -r _c _a _b _e _f _g; do
            case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
            case "$_b" in ''|*[!0-9]*) _b=0 ;; esac
            case "$_e" in ''|*[!0-9]*) _e=0 ;; esac
            case "$_f" in ''|*[!0-9]*) _f=0 ;; esac
            _ok=$((_ok + _a)); _dg=$((_dg + _b)); _dn=$((_dn + _e)); _nd=$((_nd + _f))
        done < /tmp/avail_hist
    fi
    _tot=$((_ok + _dg + _dn + _nd))
    if [ "$_tot" -gt 0 ]; then
        _x=$(( ((_tot - _nd) * 1000 + _tot / 2) / _tot ))
        COV="$((_x / 10)).$((_x % 10))"
    else
        COV=0
    fi

    printf '{"ok":true,"overall":"%s","overall_cn":"%s","coverage":%s,"components":[' \
        "$OV" "$(lvl_cn "$OV")" "${COV:-0}"

    first=1
    while IFS='|' read -r id name grp lv; do
        [ -n "$id" ] || continue
        [ "$first" = 1 ] || printf ','
        first=0
        # 天条: 历史日(DF, 排除今日) — 落临时文件后重定向读(避免管道子壳)
        : > "$T.days"
        grep "^[0-9]\{8\}|$id|" "$DAILY" 2>/dev/null | \
            awk -v t="$TODAY" -F'|' '$1!=t' > "$T.rows" 2>/dev/null
        tail -n 89 "$T.rows" > "$T.rows2" 2>/dev/null
        while IFS='|' read -r d c ok dg dn nd mi; do
            set -- $(day_pct "$ok" "$dg" "$dn" "$nd" "$mi")
            printf '{"d":"%s","pct":%s,"cls":"%s"},' "$d" "$1" "$2" >> "$T.days"
        done < "$T.rows2"
        # 今日实时 = 已落盘小时行 + 当前小时在累计的 /tmp/avail_hist (v1.1:
        # 首个小时边界前页面也有真实今日条, 而非灰条等到整点)
        # v1.2 (SIGSEGV Phase 1): 数值聚合改纯 shell 单遍累加, 不再用 awk 的
        #   printf 路径。awk 是本设备 SIGSEGV 家族的头号受害者(审计: awk 27 起
        #   居首), 而这段聚合每次 GUI 轮询都跑一遍、每个组件一次 —— 崩一次就往
        #   ne_events.tsv 记一笔(origin=our-tree), 直接污染可用性基线。2026-10-25
        #   的台账最后一行就是这段 awk 崩的。
        #   注: 本文件另有两处 awk 只做过滤/计数(日条过滤 $1!=t、事件计数
        #   $2==c|wc -l), 不走 printf, 风险面不同, 本轮不动。
        _ok=0; _dg=0; _dn=0; _nd=0; _mi=0
        while IFS='|' read -r _hd _hc _h1 _h2 _h3 _h4 _h5; do
            case "$_hd" in "$TODAY"*) ;; *) continue ;; esac
            [ "$_hc" = "$id" ] || continue
            case "$_h1" in ''|*[!0-9]*) _h1=0 ;; esac
            case "$_h2" in ''|*[!0-9]*) _h2=0 ;; esac
            case "$_h3" in ''|*[!0-9]*) _h3=0 ;; esac
            case "$_h4" in ''|*[!0-9]*) _h4=0 ;; esac
            case "$_h5" in ''|*[!0-9]*) _h5=0 ;; esac
            _ok=$((_ok + _h1)); _dg=$((_dg + _h2)); _dn=$((_dn + _h3))
            _nd=$((_nd + _h4)); _mi=$((_mi + _h5))
        done < "$HIST"
        if [ -r /tmp/avail_hist ]; then
            while IFS='|' read -r _hc _h1 _h2 _h3 _h4 _h5; do
                [ "$_hc" = "$id" ] || continue
                case "$_h1" in ''|*[!0-9]*) _h1=0 ;; esac
                case "$_h2" in ''|*[!0-9]*) _h2=0 ;; esac
                case "$_h3" in ''|*[!0-9]*) _h3=0 ;; esac
                case "$_h4" in ''|*[!0-9]*) _h4=0 ;; esac
                case "$_h5" in ''|*[!0-9]*) _h5=0 ;; esac
                _ok=$((_ok + _h1)); _dg=$((_dg + _h2)); _dn=$((_dn + _h3))
                _nd=$((_nd + _h4)); _mi=$((_mi + _h5))
            done < /tmp/avail_hist
        fi
        set -- "$_ok" "$_dg" "$_dn" "$_nd" "$_mi"
        _p=$(day_pct "$@"); _pct=${_p% *}; _cls=${_p#* }
        printf '{"d":"%s","pct":%s,"cls":"%s"}' "$TODAY" "$_pct" "$_cls" >> "$T.days"
        # 近 90 天事件计数
        _inc=$(awk -v c="$id" -F'\t' '$2==c' "$TRANS" 2>/dev/null | wc -l)
        printf '{"id":"%s","name":"%s","group":"%s","now":"%s","now_cn":"%s","inc":%s,"days":[%s]}' \
            "$id" "$name" "$grp" "$lv" "$(lvl_cn "$lv")" "${_inc:-0}" \
            "$(sed 's/,$//' "$T.days" 2>/dev/null)"
    done < "$LAST"

    # 事件表: 近 30 条倒序 (sed -n Np 逐行取, 免 tail -r/tac 依赖)
    printf '],"incidents":['
    tail -n 30 "$TRANS" > "$T.inc" 2>/dev/null
    n=$(wc -l < "$T.inc" 2>/dev/null || echo 0)
    i=$n; first=1
    while [ "$i" -ge 1 ]; do
        IFS='	' read -r ts c chg cause <<EOF
$(sed -n "${i}p" "$T.inc" 2>/dev/null)
EOF
        [ "$first" = 1 ] || printf ','
        first=0
        cause=$(printf '%s' "${cause:-"-"}" | tr -d '"\\')
        printf '{"ts":%s,"comp":"%s","chg":"%s","cause":"%s"}' \
            "${ts:-0}" "$c" "$(printf '%s' "$chg" | tr -d '"\\')" "$cause"
        i=$((i - 1))
    done
    printf ']}\n'
    rm -f "$T".* 2>/dev/null
}
