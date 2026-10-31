#!/bin/sh
# led_mgr.sh v4.0 -- 指示灯执行器 (M2 R2.4: 由状态总线驱动 + 每次写 GPIO 读回校验)
#
# v4.0 变更(状态真值总线轮, 2026-11-01) —— 判据权彻底交出去:
#   旧版(<=v3.1)自己判 wifi/cell/wan: 每轮 probe() 读 sysfs//proc 再决定点灯。那是**第二套判据**,
#   与 GUI/watchdog 各算一套 —— 正是"账面全绿而灯还亮着"这类不一致的结构性来源。
#   现在: 唯一状态源 = /data/gw/run/state.led(fast_watch 由 state.json 同一次发布投影而来),
#   本脚本**只执行不判断**; 状态总线陈旧(>3s)或缺失时按"未知"处理 = 全灭(宁可灭灯, 不谎报绿)。
#   并新增: 每轮对每个灯做**读回校验**(write->read->比对), 不符记 READBACK-FAIL 并发布
#   /tmp/led_mgr.verify 供状态总线把 feat.led 判为 deg(R2.4 的"读回校验记录")。
#   呈现滞后: 每次状态版本变化, 写完+校验通过后向 lag_audit.tsv 追加一行 stage=led(R2.5)。
#
# 保留自旧版的关键修复(勿回退):
#   v2.0 绝对电平驱动: 每轮无条件把"应为值"写到每个灯(已是该值则跳过), 外部写方(内核 trigger/
#     watchdog 抢写)最多 1 拍即被纠正 —— 旧版只在状态串变化时写, 一次外部覆写即永久错值。
#   v2.6/v2.7 单实例锁判据收紧 + 排除自身 pid(watchdog spawn 预写子 pid)。
#   v1.6 信标看门狗: dmesg 权威事件增量 -> mwctl set no_bcn 0 重装(与 wifi_up F2 同原语)。
#   v2.1 家宽判活只消费 wan_agg 结论 —— 现在更进一步: 连"消费"都不在本脚本, 由状态总线统一。
#
# 通道: WiFi/5G = sysfs gpio(467/474/475/473); WAN = /sys/class/leds/5g_evb_voice(gpio292 被
#   leds-gpio 占用); 4G 三色(472/470/471)本机不驻留, 恒灭。全部高电平点亮(1=亮)。
LOG=/tmp/led_mgr.log
MAXL=400
llog() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
log_rot() { [ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt $MAXL ] && \
    { tail -n $((MAXL/2)) $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }; }
B=/data/gw
SYS=/sys/class/gpio
WANLED=/sys/class/leds/5g_evb_voice
LEDF=$B/run/state.led
BEAT=/tmp/fast_watch.beat
LAG=$B/logs/lag_audit.tsv
VERIFY=/tmp/led_mgr.verify
W=467; G5R=474; G5G=475; G5O=473; WAN=292
G4R=472; G4G=470; G4O=471
TAB=$(printf '\t')
POLL=${LED_POLL:-1}

# ---- 读状态总线(免 fork) ------------------------------------------------
# state.led 字段: ver ms wifi cell wan night overall ts (fast_watch 原子 rename 发布)
S_ver=0; S_ms=0; S_wifi=0; S_cell=0; S_wan=0; S_night=0; S_ok=0
read_state() {
    S_ver=0; S_ms=0; S_wifi=0; S_cell=0; S_wan=0; S_night=0; S_ok=0
    [ -r "$LEDF" ] || return 1
    while IFS= read -r _ld_l; do
        case "$_ld_l" in
            ver=*)     S_ver=${_ld_l#ver=} ;;
            ms=*)      S_ms=${_ld_l#ms=} ;;
            wifi=*)    S_wifi=${_ld_l#wifi=} ;;
            cell=*)    S_cell=${_ld_l#cell=} ;;
            wan=*)     S_wan=${_ld_l#wan=} ;;
            night=*)   S_night=${_ld_l#night=} ;;
        esac
    done < "$LEDF"
    case "$S_ver" in ''|*[!0-9]*) S_ver=0 ;; esac
    case "$S_wifi" in 0|1) ;; *) S_wifi=0 ;; esac
    case "$S_cell" in 0|1) ;; *) S_cell=0 ;; esac
    case "$S_wan" in 0|1) ;; *) S_wan=0 ;; esac
    case "$S_night" in 0|1) ;; *) S_night=0 ;; esac
    S_ok=1
    return 0
}
# 状态总线新鲜度: >3s 或缺失 -> 未知(全灭), 与 GUI 的"陈旧/未知"同一条判据
BUS_STALE=0
bus_fresh() {
    BUS_STALE=1
    [ -r "$BEAT" ] || return 1
    _ld_bcs=0
    IFS=' ' read -r _ld_bu _ld_bcs _ld_bep _ld_bv _ld_bt < "$BEAT" 2>/dev/null
    case "$_ld_bcs" in ''|*[!0-9]*) return 1 ;; esac
    IFS= read -r _ld_raw < /proc/uptime
    _ld_i=${_ld_raw%%.*}
    _ld_t=${_ld_raw#*.}
    _ld_f=${_ld_t%%[!0-9]*}
    case "$_ld_f" in ??) ;; ?) _ld_f=${_ld_f}0 ;; *) _ld_f=00 ;; esac
    case "$_ld_i" in ''|*[!0-9]*) return 1 ;; esac
    _ld_now=$(( _ld_i * 100 + _ld_f ))
    _ld_age=$(( (_ld_now - _ld_bcs) * 10 ))
    [ "$_ld_age" -lt 0 ] && return 1
    [ "$_ld_age" -le 3000 ] || return 1
    BUS_STALE=0
    return 0
}

# ---- 绝对电平写入 + 读回校验 --------------------------------------------
# set_led <gpio> <want>: 写后必读回; 不符置 _ld_bad=1 并记 READBACK-FAIL
_ld_bad=0
set_led() {
    _ld_g=$1; _ld_w=$2; _ld_d=$SYS/gpio$1
    _ld_old=""
    [ -r "$_ld_d/value" ] && IFS= read -r _ld_old < "$_ld_d/value"
    if [ "$_ld_old" != "$_ld_w" ]; then
        [ -d "$_ld_d" ] || echo "$_ld_g" > $SYS/export 2>>$LOG
        echo out > "$_ld_d/direction" 2>>$LOG
        echo "$_ld_w" > "$_ld_d/value" 2>>$LOG
        [ -n "$_ld_old" ] && llog "DRIFT gpio$_ld_g $_ld_old->$_ld_w"
    fi
    _ld_rb=""
    [ -r "$_ld_d/value" ] && IFS= read -r _ld_rb < "$_ld_d/value"
    if [ "$_ld_rb" != "$_ld_w" ]; then
        _ld_bad=1
        llog "READBACK-FAIL gpio$_ld_g want=$_ld_w got=${_ld_rb:-none}"
    fi
}
set_wan() {
    _ld_w=$1
    if [ -d "$WANLED" ]; then
        _ld_old=""
        [ -r "$WANLED/brightness" ] && IFS= read -r _ld_old < "$WANLED/brightness"
        if [ "$_ld_old" != "$_ld_w" ]; then
            echo "$_ld_w" > "$WANLED/brightness" 2>>$LOG
            [ -n "$_ld_old" ] && llog "DRIFT wan_led $_ld_old->$_ld_w"
        fi
        _ld_rb=""
        [ -r "$WANLED/brightness" ] && IFS= read -r _ld_rb < "$WANLED/brightness"
        if [ "$_ld_rb" != "$_ld_w" ]; then
            _ld_bad=1
            llog "READBACK-FAIL wan_led want=$_ld_w got=${_ld_rb:-none}"
        fi
    else
        set_led $WAN "$_ld_w"
    fi
}
set_4g_off() {
    for _ld_x in $G4G $G4O $G4R; do
        [ -r "$SYS/gpio$_ld_x/value" ] || continue
        set_led "$_ld_x" 0
    done
}
apply() {  # $1=wifi $2=cell $3=wan
    _ld_bad=0
    set_led $W $1
    if [ "$2" = 1 ]; then set_led $G5G 1; set_led $G5O 0; set_led $G5R 0
    else set_led $G5G 0; set_led $G5O 0; set_led $G5R 0; fi
    set_4g_off
    set_wan "$3"
}
# 发布时间(ms): 与 fast_watch 同源口径(uptime 厘秒 + epoch 秒)
now_ms() {
    IFS= read -r _ld_raw < /proc/uptime
    _ld_i=${_ld_raw%%.*}
    _ld_t=${_ld_raw#*.}
    _ld_f=${_ld_t%%[!0-9]*}
    case "$_ld_f" in ??) ;; ?) _ld_f=${_ld_f}0 ;; *) _ld_f=00 ;; esac
    case "$_ld_i" in ''|*[!0-9]*) _ld_i=0 ;; esac
    _ld_cs=$(( _ld_i * 100 + _ld_f ))
    _ld_s=$(date +%s)
    _ld_ms=$(( _ld_s * 1000 + (_ld_cs % 100) * 10 ))
}
# 该版本迁移的 t_change(取 lag_audit 里该 ver 的 detect 行 t_ref) —— 用于算 led 滞后
lag_ref() {  # $1=ver -> _ld_ref (ms; 0=找不到)
    _ld_ref=0
    [ -r "$LAG" ] || return 0
    while IFS="$TAB" read -r _ld_ts _ld_v _ld_c _ld_stage _ld_tr _ld_t _ld_note; do
        if [ "$_ld_v" = "$1" ] && [ "$_ld_stage" = detect ]; then _ld_ref=$_ld_tr; fi
    done < "$LAG"
}

case "$1" in
--dry-state)   # 映射干跑(不点灯不动现场): 供 selftest/部署自检断言用。
    # v4.2(测试腐化回归): v4.1 把判据交给状态总线后删掉了 --dry-state,
    # 而 selftest 的两条灯映射断言依赖它。恢复并同时支持旧式
    # 'w1 c0 b1 p1'(历史语法, 保证断言不弱化)与 state.led 字段式。
    # 输出字段与 v2.x 完全一致(g5g/g5o/g5r/g4*/wan), 不改测试。
    _ds=$2
    [ -n "$_ds" ] || { echo "usage: led_mgr.sh --dry-state 'w1 c0 b1 p1' | 'wifi=1 cell=0 wan=1'"; exit 2; }
    DS_W=0; DS_C=0; DS_B=0
    case "$_ds" in
    *wifi=*|*cell=*|*wan=*)
        for _ds_kv in $_ds; do
            case "$_ds_kv" in
                wifi=*) DS_W=${_ds_kv#wifi=} ;;
                cell=*) DS_C=${_ds_kv#cell=} ;;
                wan=*)  DS_B=${_ds_kv#wan=} ;;
            esac
        done ;;
    *)
        for _ds_kv in $_ds; do
            case "$_ds_kv" in
                w*) DS_W=${_ds_kv#w} ;;
                c*) DS_C=${_ds_kv#c} ;;
                b*) DS_B=${_ds_kv#b} ;;
            esac
        done ;;
    esac
    case "$DS_W" in 0|1) ;; *) DS_W=0 ;; esac
    case "$DS_C" in 0|1) ;; *) DS_C=0 ;; esac
    case "$DS_B" in 0|1) ;; *) DS_B=0 ;; esac
    printf 'wifi=%s g5g=%s g5o=%s g5r=%s g4g=%s g4o=%s g4r=%s wan=%s carrier=%s\n'         "$DS_W" "$DS_C" 0 0 0 0 0 "$DS_B" "$DS_B"
    exit 0 ;;
--once)        # 一次性应用(不动守护; 部署自检用)
    read_state && bus_fresh
    if [ "$BUS_STALE" = 1 ]; then apply 0 0 0; else
        if [ "$S_night" = 1 ]; then apply 0 0 0; else apply "$S_wifi" "$S_cell" "$S_wan"; fi
    fi
    echo "applied wifi=$S_wifi cell=$S_cell wan=$S_wan night=$S_night stale=$BUS_STALE readback_bad=$_ld_bad"
    exit 0 ;;
esac

# v2.9(batch3): shared lock/heartbeat primitives
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else echo "led_mgr: svc_lib.sh missing" >&2; exit 1; fi
_rc=0; svc_lock led_mgr /data/gw/led_mgr.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    if [ "$_rc" = 1 ]; then llog "duplicate instance alive — exit (single-instance lock)"; else llog "lost lock race — exit"; fi
    exit 0
fi

llog "===== led_mgr v4.0 start (state-bus driven + readback verify + poll=$POLL s; pid=$$) ====="
BCN_LAST=""
LCYC=0
LASTVER=0
while :; do
    svc_hb led_mgr
    LCYC=$((LCYC + 1))
    [ $((LCYC % 60)) -eq 0 ] && log_rot
    read_state
    bus_fresh
    if [ "$BUS_STALE" = 1 ]; then
        apply 0 0 0
        _ld_note="stale"
    elif [ "$S_night" = 1 ]; then
        apply 0 0 0
        _ld_note="night"
    else
        apply "$S_wifi" "$S_cell" "$S_wan"
        _ld_note="w$S_wifi c$S_cell b$S_wan"
    fi
    now_ms
    _ld_vok=0; [ "$_ld_bad" = 0 ] && _ld_vok=1
    printf 'ver=%s ok=%s up=%s stale=%s ms=%s\n' \
        "$S_ver" "$_ld_vok" "$(( _ld_cs / 100 ))" "$BUS_STALE" "$_ld_ms" > "$VERIFY.tmp" 2>/dev/null \
        && mv -f "$VERIFY.tmp" "$VERIFY"
    if [ "$S_ver" != "$LASTVER" ] && [ "$S_ver" != 0 ] && [ "$BUS_STALE" = 0 ]; then
        lag_ref "$S_ver"
        if [ "$_ld_ref" -gt 0 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_ld_ms" "$S_ver" "-" led "$_ld_ref" "$_ld_ms" \
                "lag_ms=$(( _ld_ms - _ld_ref )) ok=$_ld_vok" >> "$LAG"
        fi
        llog "state v$S_ver applied ($_ld_note) readback=$_ld_vok"
        LASTVER=$S_ver
    fi
    # v4.3(实弹): 信标检查 10 拍 -> 60 拍。busybox dmesg|grep 是本循环最贵的一步,
    # 实测把 1s 循环拖到 hb 43s 陈旧 -> watchdog 判失效并重启(反复抖动)。
    # 信标事件本身是稀少事件, 60s 检一次足够(wifi_guard 另有独立监视)。
    if [ $((LCYC % 60)) -eq 0 ]; then
        BCN_NOW=$(svc_dmesg_count 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
        if [ -n "$BCN_LAST" ] && [ "$BCN_NOW" -gt "$BCN_LAST" ]; then
            llog "beacon-loss event ($BCN_LAST->$BCN_NOW) — re-arming beacons"
            for _ld_p in /sys/class/net/ra*; do
                [ -e "$_ld_p" ] || continue
                mwctl dev "${_ld_p##*/}" set no_bcn 0 >/dev/null 2>&1
            done
        fi
        BCN_LAST=$BCN_NOW
    fi
    sleep "$POLL"
done
