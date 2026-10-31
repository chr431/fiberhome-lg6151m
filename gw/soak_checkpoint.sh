#!/bin/sh
# soak_checkpoint.sh v1.3 -- 30d soak 装置: 每日资源 checkpoint + 每次开机记账 + 漂移告警
# (RELIABILITY_SPEC M4 R4.2/R4.3; 验收口径见 docs/ACCEPTANCE.md)
#
# 为什么是"被 fork 驱动"而不是常驻守护:
#   Lead 裁决 v1.1 + 项目铁律(不新增第二套高频探针/不扩 NE 暴露面) --
#   本脚本由 log_keeper 的 5min 块 fork 驱动(--tick), 自身节流到 24h 一次,
#   不持锁不常驻。--tick 稳态开销 = 读 /proc 两个文件 + tail 一行台账(<20ms)。
#
# 三个台账(append-only, 首行列名, 格式见 docs/ACCEPTANCE.md):
#   /data/gw/logs/soak_daily.tsv   每日一行: 资源/重启/NE/中断三档/判定
#   /data/gw/logs/soak_boots.tsv   每次开机一行: boot_id/btime/原因/证据源
#   /data/gw/logs/soak_alerts.tsv  漂移告警: 每条规则每天最多一行(去重)
#
# 诚实性纪律(spec 0):
#   * 数据源缺失一律写 -1(未知), 绝不写 0 冒充零发生;
#   * 每个重启原因都带证据源(reboots.log / pstore 文件名 / ramoops 尾行);
#     判不出来就写 unknown, 不猜;
#   * 计划重启该来没来必须能被发现 -- scheduled_missed 列(负证据也记账)。
#
# 用法:
#   sh soak_checkpoint.sh --tick     # log_keeper 5min 块调用: 记账+节流到每日一次
#   sh soak_checkpoint.sh --once     # 立刻写一条每日行(幂等, 当日已有则跳过)
#   sh soak_checkpoint.sh --once --force
#   sh soak_checkpoint.sh --boot     # 立刻记一次开机(幂等)
#   sh soak_checkpoint.sh --status   # 打印最近台账(排障用)
#   sh soak_checkpoint.sh --version
#
# v1.1 (2026-11-01 冷启动前修根): 数值列归一 —— busybox awk 偶发返回空串,
#   zombies 列被写成空 -> 后续 [ "" -gt 20 ] 报 out of range 且台账出现空列。
#   现在所有参与比较的量都过 num_or 兜底(实测证据: 00:35 那条 2026-11-01 行)。
# v1.2 (2026-11-01 演练轮): 阈值改环境变量可覆盖 —— 判据类改动必须有假状态演练,
#   没有覆盖入口就没法演练(制造故障->判据变红->恢复->回绿)。
# v1.3 (2026-11-01 冷启动验收): today_done 增加 boot_id 比对 —— 原实现只比日期,
#   04:00 冷启动后当日行仍是重启前写的, 重启后的资源/判定永远进不了日台账(假绿风险)。
#
# 退出码: 0=正常(含跳过), 非 0 只表示参数错误。运行期异常不得影响调用方。

VER=1.3
DIR=/data/gw/logs
DAILY=$DIR/soak_daily.tsv
BOOTS=$DIR/soak_boots.tsv
ALERTS=$DIR/soak_alerts.tsv
REBOOTS=$DIR/reboots.log
PSTORE=$DIR/pstore
LOCKDIR=/tmp/soak_checkpoint.lock
# 漂移阈值(集中一处)
# v1.2: 阈值可用环境变量覆盖 —— 这是假状态演练(制造故障->判据必须变红)的唯一入口。
#   例: TH_DATA_FREE_KB=99999999 sh soak_checkpoint.sh --once --force -> 必须 FAIL
#   正常运行不设这些变量, 走下面缺省值。
TH_DATA_FREE_KB=${TH_DATA_FREE_KB:-102400}
TH_FD_PCT=${TH_FD_PCT:-90}
TH_ZOMBIES=${TH_ZOMBIES:-20}
TH_UP_MIN=${TH_UP_MIN:-600}
TH_CRASH=${TH_CRASH:-1}

DAILY_HDR='day	epoch	up_s	boot_id	boot_epoch	boots_24h	boots_sched_24h	boots_unplanned_24h	scheduled_missed	data_used_kb	data_free_kb	data_used_pct	tmp_free_kb	logs_kb	procs	zombies	fd_used	fd_max	mem_avail_kb	mem_total_kb	load1	ne_24h	ne_total	repairs_24h	svc_lt5_24h	svc_5_20_24h	svc_gt20_24h	incidents_24h	sev1_24h	sev2_24h	sev3_24h	verdict	notes'
BOOTS_HDR='epoch	iso	boot_id	btime	up_at_record_s	prev_boot_id	cause	cause_evidence'

BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=

now_s() { date +%s; }
uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null; }
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
btime_s() { awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null; }
hour_now() { date +%H | awk '{print $1+0}'; }
df_free_kb() {
    if [ -n "$BB" ]; then "$BB" df -k "$1" 2>/dev/null | tail -1 | awk '{print $4}'
    else df -k "$1" 2>/dev/null | tail -1 | awk '{print $4}'; fi
}
df_used_kb() {
    if [ -n "$BB" ]; then "$BB" df -k "$1" 2>/dev/null | tail -1 | awk '{print $3}'
    else df -k "$1" 2>/dev/null | tail -1 | awk '{print $3}'; fi
}
num_or() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }
count_24h() {
    [ -r "$1" ] || { echo -1; return; }
    awk -v t="$2" '$1 ~ /^[0-9]+$/ && $1 >= t { c++ } END { print c + 0 }' "$1" 2>/dev/null || echo -1
}
today() { date +%F; }
today_done() {
    [ -r "$DAILY" ] || return 1
    _l=$(tail -1 "$DAILY" 2>/dev/null)
    [ -n "$_l" ] || return 1
    [ "$(printf %s "$_l" | cut -f1)" = "$(today)" ] || return 1
    # v1.3: 同一天但换了 boot(冷启动/非计划重启)必须补一行 —— 否则 04:00 重启后的状态
    # 永远进不了日台账, 设备起不来时台账仍显示重启前的"正常" = 假绿。
    [ "$(printf %s "$_l" | cut -f4)" = "$(boot_id)" ] || return 1
    return 0
}
last_boot_id() {
    [ -r "$BOOTS" ] || { echo ''; return; }
    tail -1 "$BOOTS" 2>/dev/null | cut -f3
}

# ---- 开机记账 ----
# 用"本次 boot 的 pstore 文件名"定位上一次死亡现场: 文件名里带的是**当前** boot_id
# (ramoops 在本次启动时保存上一 boot 的 console), 精确对应, 无需时间窗猜测。
boot_cause() {
    _bid=$1
    _pf=$PSTORE/console-ramoops.$_bid.txt
    _be=$(btime_s)
    if [ -r "$REBOOTS" ] && [ -n "$_be" ]; then
        _hit=$(awk -v b="$_be" '
            { cmd = "date -d \"" $1 " " $2 "\" +%s"; cmd | getline e; close(cmd)
              if (e ~ /^[0-9]+$/ && b - e >= 0 && b - e <= 600) { print "yes"; exit } }' "$REBOOTS" 2>/dev/null)
        [ "$_hit" = "yes" ] && { printf 'scheduled\t%s\n' 'reboots.log(<=600s)'; return; }
    fi
    if [ -r "$_pf" ]; then
        _t=$(tail -8 "$_pf" 2>/dev/null | tr -d '\000')
        case "$_t" in
        *'Kernel panic'*|*'Unable to handle kernel'*|*'Internal error'*)
            printf 'crash\t%s\n' "pstore/console-ramoops.$_bid.txt(tail:panic/oops)"; return ;;
        *'SMP: stopping secondary CPUs'*)
            printf 'sysrq\t%s\n' "pstore/console-ramoops.$_bid.txt(tail:sysrq-b)"; return ;;
        *'procd: reboot'*|*'Restarting system'*)
            printf 'clean\t%s\n' "pstore/console-ramoops.$_bid.txt(tail:procd/reboot)"; return ;;
        esac
        printf 'unknown\t%s\n' "pstore/console-ramoops.$_bid.txt(tail:unmatched)"
        return
    fi
    printf 'unknown\t%s\n' 'no pstore file for boot_id'
}
record_boot() {
    _bid=$(boot_id)
    [ -n "$_bid" ] || return 0
    _prev=$(last_boot_id)
    [ "$_bid" = "$_prev" ] && return 0
    _u=$(num_or "$(uptime_s)" 0)
    _bt=$(num_or "$(btime_s)" 0)
    _ce=$(boot_cause "$_bid")
    _c=$(printf '%s' "$_ce" | cut -f1)
    _ev=$(printf '%s' "$_ce" | cut -f2)
    [ -n "$_prev" ] || _prev=none
    [ -r "$BOOTS" ] || printf '%s\n' "$BOOTS_HDR" >> "$BOOTS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(now_s)" "$(date '+%F %T')" "$_bid" "$_bt" "$_u" "$_prev" "$_c" "$_ev" >> "$BOOTS"
    return 0
}

alert() {
    _d=$(today)
    [ -r "$ALERTS" ] && grep -q "	$_d	$1	" "$ALERTS" 2>/dev/null && return 0
    printf '%s\t%s\t%s\t%s\n' "$(now_s)" "$_d" "$1" "$2" >> "$ALERTS"
    logger -t soak "ALERT $1 $2" 2>/dev/null
    return 0
}

# ---- 每日 checkpoint ----
do_daily() {
    _force=0
    [ -n "$1" ] && _force=$1
    if [ "$_force" != 1 ] && today_done; then return 0; fi
    _now=$(now_s); _u=$(num_or "$(uptime_s)" 0); _bid=$(boot_id)
    _bt=$(num_or "$(btime_s)" 0)
    _y=$((_now - 86400))
    _b24=$(count_24h "$BOOTS" "$_y")
    _bsched=0; _bunp=0; _crash24=0
    if [ -r "$BOOTS" ]; then
        _bsched=$(awk -v t="$_y" '$1 ~ /^[0-9]+$/ && $1 >= t && $7=="scheduled" { c++ } END { print c+0 }' "$BOOTS" 2>/dev/null)
        _bunp=$(awk -v t="$_y" '$1 ~ /^[0-9]+$/ && $1 >= t && $7!="scheduled" { c++ } END { print c+0 }' "$BOOTS" 2>/dev/null)
        _crash24=$(awk -v t="$_y" '$1 ~ /^[0-9]+$/ && $1 >= t && $7=="crash" { c++ } END { print c+0 }' "$BOOTS" 2>/dev/null)
    fi
    _sm=0
    _h=$(hour_now)
    if [ "$_h" -ge 4 ]; then
        _ts=0
        [ -r "$REBOOTS" ] && grep -q "^$(today) .*REBOOT" "$REBOOTS" 2>/dev/null && _ts=1
        [ "$_ts" = 0 ] && _sm=1
    fi
    _du=$(num_or "$(df_used_kb /data)" -1)
    _df=$(num_or "$(df_free_kb /data)" -1)
    _pct=-1
    if [ "$_du" -ge 0 ] && [ "$_df" -ge 0 ] && [ $((_du + _df)) -gt 0 ]; then _pct=$(( _du * 100 / (_du + _df) )); fi
    _tf=$(num_or "$(df_free_kb /tmp)" -1)
    _lk=-1
    [ -d "$DIR" ] && _lk=$(num_or "$(du -sk "$DIR" 2>/dev/null | awk '{print $1}')" -1)
    _pr=$(ls /proc 2>/dev/null | grep -c '^[0-9]')
    _zo=$(awk '{ sub(/^.*\) /, ""); if (substr($0,1,1)=="Z") n++ } END { print n+0 }' /proc/[0-9]*/stat 2>/dev/null)
    _fu=$(num_or "$(awk '{print $1}' /proc/sys/fs/file-nr 2>/dev/null)" -1)
    _fm=$(num_or "$(awk '{print $3}' /proc/sys/fs/file-nr 2>/dev/null)" -1)
    _ma=$(num_or "$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)" -1)
    _mt=$(num_or "$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)" -1)
    _l1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)
    [ -n "$_l1" ] || _l1=0
    _ne24=$(count_24h "$DIR/ne_events.tsv" "$_y")
    _netot=-1
    [ -r "$DIR/ne_events.tsv" ] && _netot=$(grep -c '' "$DIR/ne_events.tsv" 2>/dev/null)
    _rep24=$(count_24h "$DIR/netcfg_repairs.tsv" "$_y")
    _l5=-1; _m5=-1; _g5=-1
    if [ -r "$DIR/svc_daily.tsv" ]; then
        _l5=$(tail -1 "$DIR/svc_daily.tsv" 2>/dev/null | awk -F'|' '{print $3+0}')
        _m5=$(tail -1 "$DIR/svc_daily.tsv" 2>/dev/null | awk -F'|' '{print $4+0}')
        _g5=$(tail -1 "$DIR/svc_daily.tsv" 2>/dev/null | awk -F'|' '{print $5+0}')
    fi
    _inc=-1; _s1=-1; _s2=-1; _s3=-1
    if [ -r "$DIR/incidents.tsv" ]; then
        _inc=$(count_24h "$DIR/incidents.tsv" "$_y")
        _s1=$(awk -v t="$_y" '$1>=t && $2=="SEV1"{c++} END{print c+0}' "$DIR/incidents.tsv" 2>/dev/null)
        _s2=$(awk -v t="$_y" '$1>=t && $2=="SEV2"{c++} END{print c+0}' "$DIR/incidents.tsv" 2>/dev/null)
        _s3=$(awk -v t="$_y" '$1>=t && $2=="SEV3"{c++} END{print c+0}' "$DIR/incidents.tsv" 2>/dev/null)
    fi
    # 数值归一: busybox awk 偶发返回空串(实测 2026-11-01 00:35 zombies 列写空 ->
    # 后续 [ "" -gt 20 ] 报 "out of range", 台账出现空列)。所有参与比较的量
    # 在这里一次性兜底, 保证台账每一列都有确定值。
    _zo=$(num_or "$_zo" 0); _pr=$(num_or "$_pr" 0)
    _bsched=$(num_or "$_bsched" 0); _bunp=$(num_or "$_bunp" 0)
    _crash24=$(num_or "$_crash24" 0); _b24=$(num_or "$_b24" -1)
    _s1=$(num_or "$_s1" -1); _s2=$(num_or "$_s2" -1); _s3=$(num_or "$_s3" -1)
    _l5=$(num_or "$_l5" -1); _m5=$(num_or "$_m5" -1); _g5=$(num_or "$_g5" -1)
    _ne24=$(num_or "$_ne24" -1); _rep24=$(num_or "$_rep24" -1)
    _v=PASS; _notes=
    if [ "$_df" -ge 0 ] && [ "$_df" -lt "$TH_DATA_FREE_KB" ]; then _v=FAIL; alert data_free "$_df KB"; fi
    if [ "$_fu" -ge 0 ] && [ "$_fm" -gt 0 ] && [ $(( _fu * 100 / _fm )) -ge "$TH_FD_PCT" ]; then _v=FAIL; alert fd_exhaust "$_fu/$_fm"; fi
    if [ "$_zo" -gt "$TH_ZOMBIES" ]; then _v=FAIL; alert zombies "$_zo"; fi
    if [ "$_u" -lt "$TH_UP_MIN" ]; then _v=FAIL; alert boot_loop "up $_u s"; fi
    if [ "$_crash24" -ge "$TH_CRASH" ]; then _v=FAIL; alert crash_reboot "$_crash24 in 24h"; fi
    if [ "$_sm" = 1 ]; then
        [ "$_v" = PASS ] && _v=DEGRADED
        alert scheduled_missed 'no scheduled reboot observed today'
        _notes=scheduled_missed
    fi
    if [ "$_bunp" -gt 0 ] && [ "$_v" = PASS ]; then
        _v=DEGRADED
        if [ -n "$_notes" ]; then _notes="$_notes,unplanned_reboot"; else _notes=unplanned_reboot; fi
    fi
    if [ "$_ne24" -gt 0 ] && [ "$_v" = PASS ]; then
        _v=DEGRADED
        if [ -n "$_notes" ]; then _notes="$_notes,ne"; else _notes=ne; fi
    fi
    if [ "$_g5" -gt 0 ] && [ "$_v" = PASS ]; then
        _v=DEGRADED
        if [ -n "$_notes" ]; then _notes="$_notes,svc_gt20s"; else _notes=svc_gt20s; fi
    fi
    if [ "$_inc" = -1 ] || [ "$_g5" = -1 ]; then
        if [ -n "$_notes" ]; then _notes="$_notes,src_partial"; else _notes=src_partial; fi
    fi
    [ -n "$_notes" ] || _notes=ok
    [ -r "$DAILY" ] || printf '%s\n' "$DAILY_HDR" >> "$DAILY"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(today)" "$_now" "$_u" "$_bid" "$_bt" "$_b24" "$_bsched" "$_bunp" "$_sm" \
        "$_du" "$_df" "$_pct" "$_tf" "$_lk" "$_pr" "$_zo" "$_fu" "$_fm" \
        "$_ma" "$_mt" "$_l1" "$_ne24" "$_netot" "$_rep24" \
        "$_l5" "$_m5" "$_g5" "$_inc" "$_s1" "$_s2" "$_s3" "$_v" "$_notes" >> "$DAILY"
    return 0
}

lock_try() {
    mkdir "$LOCKDIR" 2>/dev/null && return 0
    _la=$(date -r "$LOCKDIR" +%s 2>/dev/null)
    [ -n "$_la" ] || _la=0
    if [ $(( $(now_s) - _la )) -gt 300 ]; then
        rm -rf "$LOCKDIR" 2>/dev/null
        mkdir "$LOCKDIR" 2>/dev/null && return 0
    fi
    return 1
}
lock_drop() { rmdir "$LOCKDIR" 2>/dev/null; }

do_tick() {
    record_boot
    _h=$(hour_now)
    _u=$(num_or "$(uptime_s)" 0)
    if [ "$_h" -ge 4 ] || [ "$_u" -ge 300 ]; then do_daily 0; fi
    return 0
}

CMD=$1
case "$CMD" in
--version) echo "soak_checkpoint v$VER"; exit 0 ;;
--tick)
    lock_try || exit 0
    do_tick; lock_drop; exit 0 ;;
--once)
    _f=0
    [ "$2" = "--force" ] && _f=1
    lock_try || exit 0
    record_boot; do_daily "$_f"; lock_drop; exit 0 ;;
--boot)
    lock_try || exit 0
    record_boot; lock_drop; exit 0 ;;
--status)
    echo '== soak_daily.tsv (last 5) =='; tail -5 "$DAILY" 2>/dev/null
    echo '== soak_boots.tsv (last 8) =='; tail -8 "$BOOTS" 2>/dev/null
    echo '== soak_alerts.tsv (last 10) =='; tail -10 "$ALERTS" 2>/dev/null
    exit 0 ;;
*)
    echo "usage: $0 --tick|--once [--force]|--boot|--status|--version" >&2
    exit 2 ;;
esac
