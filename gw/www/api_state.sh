#!/bin/sh
# api_state.sh v1.0 -- API 状态总线域模块 (M2; R2.1/R2.3/R2.5)
# 端点(GET, 均需 token):
#   /api/state             读 /data/gw/run/state.json + /tmp/fast_watch.beat(新鲜度), 原样转发
#   /api/render?v=&a=      GUI 回传"我渲染了哪个版本 + 渲染时数据已有多旧"(R2.5)
#   /api/lag               lag_audit.tsv 的 p50/p99/max 统计(按 stage: detect/publish/gui/led)
#   /api/state_ev?n=       最近迁移(状态总线页用)
# 纪律:
#   * 单一状态源: 本模块**不计算**任何状态, 只转发 fast_watch 的产物(禁止第二套判据);
#   * 时钟无关: GUI 回传的是**数据年龄(ms)**而不是客户端本地时刻 —— 设备无 RTC、PC 与设备
#     时钟可能差几分钟, 传本地时刻会引入跨源对齐误差(AGENTS 陷阱表"跨源时间轴对齐");
#   * 零解析: state.json 由发布方一次性写成完整 JSON, 这里只包一层新鲜度外壳, 不做 JSON 解析;
#   * 写路径只有一条(render 追加 lag 行), 幂等无状态。
STATE=/data/gw/run/state.json
BEAT=/tmp/fast_watch.beat
LAG=/data/gw/logs/lag_audit.tsv
EVT=/data/gw/logs/state_events.tsv
TAB=$(printf '\t')

# 读心跳: -> BCS(厘秒) BV(ver) BT(tick) AGE_MS(数据年龄)
beat_read() {
    BCS=0; BV=0; BT=0; AGE_MS=999999
    if [ -r "$BEAT" ]; then
        IFS=' ' read -r _bu BCS _bep BV BT < "$BEAT" 2>/dev/null
    fi
    case "$BCS" in ''|*[!0-9]*) BCS=0 ;; esac
    case "$BV" in ''|*[!0-9]*) BV=0 ;; esac
    case "$BT" in ''|*[!0-9]*) BT=0 ;; esac
    IFS= read -r _raw < /proc/uptime
    _i=${_raw%%.*}
    _t=${_raw#*.}
    _f=${_t%%[!0-9]*}
    case "$_f" in ??) ;; ?) _f=${_f}0 ;; *) _f=00 ;; esac
    case "$_i" in ''|*[!0-9]*) _i=0 ;; esac
    _nowcs=$(( _i * 100 + 10#${_f:-0} ))   # P0: 10# 防 08/09 被当八进制
    if [ "$BCS" -gt 0 ]; then
        AGE_MS=$(( (_nowcs - BCS) * 10 ))
        [ "$AGE_MS" -lt 0 ] && AGE_MS=999999
    fi
}

get_state() {
    beat_read
    if [ ! -s "$STATE" ]; then
        printf '{"ok":true,"warming":true,"age_ms":%s,"beat_ver":%s,"tick":%s}\n' "$AGE_MS" "$BV" "$BT"
        return
    fi
    _st=$(cat "$STATE" 2>/dev/null)
    case "$_st" in
        \{*) ;;
        *) printf '{"ok":true,"warming":true,"corrupt":1,"age_ms":%s}\n' "$AGE_MS"; return ;;
    esac
    _stale=0
    [ "$AGE_MS" -gt 3000 ] && _stale=1
    printf '{"ok":true,"age_ms":%s,"beat_ver":%s,"tick":%s,"stale":%s,"st":%s}\n' \
        "$AGE_MS" "$BV" "$BT" "$_stale" "$_st"
}

# GUI 回传渲染 (R2.5): v=渲染的 state 版本, a=渲染瞬间的数据年龄(ms, 设备侧口径)
apply_render() {
    # GUI 走 POST(app.js api() 带 body), 脚本/探测器走 GET —— 两种都支持
    _v=$(form_kv v); [ -z "$_v" ] && _v=$(qkv v)
    _a=$(form_kv a); [ -z "$_a" ] && _a=$(qkv a)
    case "$_v" in ''|*[!0-9]*) jerr bad_v; return ;; esac
    case "$_a" in ''|*[!0-9]*) _a=0 ;; esac
    [ "$_a" -gt 600000 ] && _a=600000
    _tpub=""; _tref=""; _comp="-"
    if [ -r "$LAG" ]; then
        while IFS="$TAB" read -r _ts _ver _c _stage _tr _t _note; do
            [ "$_ver" = "$_v" ] || continue
            if [ "$_stage" = publish ]; then _tpub=$_t; _tref=$_tr; _comp=$_c; fi
        done < "$LAG"
    fi
    if [ -z "$_tpub" ]; then jerr no_such_ver; return; fi
    _trender=$(( _tpub + _a ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_trender" "$_v" "$_comp" gui "$_tref" "$_trender" \
        "lag_ms=$(( _trender - _tref )) age_ms=$_a" >> "$LAG"
    printf '{"ok":true,"ver":%s,"lag_ms":%s}\n' "$_v" "$(( _trender - _tref ))"
}

# lag 统计(detect/publish/gui/led 四阶段 p50/p99/max)
get_lag() {
    _n=$(qkv n)
    case "$_n" in ''|*[!0-9]*) _n=2000 ;; esac
    if [ ! -r "$LAG" ]; then printf '{"ok":true,"rows":0,"stages":[]}\n'; return; fi
    _rows=$(wc -l < "$LAG" 2>/dev/null)
    case "$_rows" in ''|*[!0-9]*) _rows=0 ;; esac
    _js=$(tail -n "$_n" "$LAG" 2>/dev/null | awk -F'\t' '
      {
        if ($4 == "") next
        note = $7; v = ""
        if (match(note, /lag_ms=[0-9]+/)) v = substr(note, RSTART + 7, RLENGTH - 7) + 0
        else next
        c[$4]++
        arr[$4, c[$4]] = v
      }
      END {
        first = 1
        printf "["
        for (s in c) {
          n = c[s]
          for (i = 2; i <= n; i++) {
            key = arr[s, i]; j = i - 1
            while (j >= 1 && arr[s, j] > key) { arr[s, j+1] = arr[s, j]; j-- }
            arr[s, j+1] = key
          }
          p50 = arr[s, int((n+1)/2)] + 0
          p99 = arr[s, int(n*99/100)] + 0
          if (p99 < p50) p99 = arr[s, n] + 0
          if (!first) printf ","
          first = 0
          printf "{\"s\":\"%s\",\"n\":%d,\"p50\":%d,\"p99\":%d,\"max\":%d}", s, n, p50, p99, arr[s, n] + 0
        }
        printf "]"
      }')
    printf '{"ok":true,"rows":%s,"stages":%s}\n' "$_rows" "${_js:-[]}"
}

# 最近迁移(状态总线页; 倒序 N 条)
get_events() {
    _n=$(qkv n)
    case "$_n" in ''|*[!0-9]*) _n=20 ;; esac
    printf '{"ok":true,"ev":['
    if [ -r "$EVT" ]; then
        _tot=$(wc -l < "$EVT" 2>/dev/null)
        case "$_tot" in ''|*[!0-9]*) _tot=0 ;; esac
        _i=$_tot; _first=1; _cnt=0
        while [ "$_i" -ge 1 ] && [ "$_cnt" -lt "$_n" ]; do
            _ln=$(sed -n "${_i}p" "$EVT" 2>/dev/null)
            IFS="$TAB" read -r _ts _iso _ver _comp _from _to _crit _flags _ev <<EOF
$_ln
EOF
            if [ -n "$_comp" ]; then
                [ "$_first" = 1 ] || printf ','
                _first=0
                case "$_ts" in ''|*[!0-9]*) _ts=0 ;; esac
                case "$_ver" in ''|*[!0-9]*) _ver=0 ;; esac
                printf '{"ts":%s,"iso":"%s","ver":%s,"c":"%s","f":"%s","t":"%s","crit":"%s","fl":"%s"}' \
                    "$_ts" "$_iso" "$_ver" "$_comp" "$_from" "$_to" "$_crit" "$_flags"
                _cnt=$(( _cnt + 1 ))
            fi
            _i=$(( _i - 1 ))
        done
    fi
    printf ']}\n'
}
