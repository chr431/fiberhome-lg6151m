#!/bin/sh
# api_avail.sh v1.0 -- API 可用性域模块 (AVAILABILITY_DESIGN §4.1)
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

    # 近 24h 覆盖率 (nodata 占比反向)
    COV=$(awk -v t="$TODAY" -v y="$YDAY" -F'|' \
        'substr($1,1,8)==t || substr($1,1,8)==y {ok+=$3; dg+=$4; dn+=$5; nd+=$6}
         END {tot=ok+dg+dn+nd; if (tot>0) printf "%.1f", (tot-nd)*100/tot; else print "0"}' \
        "$HIST" 2>/dev/null)

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
        # 今日实时 (从小时行标量聚合)
        set -- $(awk -v t="$TODAY" -v c="$id" -F'|' \
            'substr($1,1,8)==t && $2==c {ok+=$3; dg+=$4; dn+=$5; nd+=$6; mi+=$7}
             END {printf "%d %d %d %d %d", ok, dg, dn, nd, mi}' "$HIST" 2>/dev/null)
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
