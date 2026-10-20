#!/bin/sh
# log_keeper.sh v2.0 -- 日志持久化守护（日志改善专项轮）
#   v2.0 (2026-10-20 stability P1-5): ① 单实例锁(cmdline 复核) — 看门狗监督表
#   会重启本守护, 双实例会重复追加镜像; ② ne_census.tsv — 从 syslog 新增行抽取
#   aee 的 "pid: N >>> comm <<<" 记录(时间/pid/comm/原文), 补上 db_history 无
#   进程名的盲区, watchdog 的 NE WARN 直接引用末条; ③ logc 崩溃留痕 — 读
#   /tmp/logc.crash(SIGSEGV 面包屑) 并复制到 logs/logc_crash/; ④ resync 文案
#   改为 ring 语义(不再提厂商 logread); ⑤ 心跳/btime BOOT 门禁沿用 v1.9.
#   v1.9 (2026-10-20 stability batch1): ① logc 退出码在 `if !` 前保存(原
#   `$?` 在 then 分支恒为 0, 崩溃被记成 rc=0); ② BOOT 分隔行以 /proc/stat
#   btime 为门禁 — 守护被 watchdog 重启时不再写假 BOOT(现场已有 up=59808s
#   的假 BOOT 混在真重启里); ③ dmesg 镜像降噪新增 healthdog FORENSIC D/
#   wdtk/hang_detect/SPM 噪声(占持久 dmesg 75%, 也是内核环只剩 ~22min 的
#   主因); ④ 每轮写 /tmp/log_keeper.hb 供 watchdog 判“进程活但日志停摆”。
#   v1.8 (2026-10-19 SIGSEGV P1): syslog 环读取改用自建静态采集器
#   /data/gw/bin/logc（同 ubus fd 流, 帧校验+全量重同步+时间戳范围断言,
#   静态链接=零厂商 musl 耦合）。logread 的帧同步缺陷/ctime 崩溃路径从
#   本守护的读环路径物理消失; logc 异常计数（bad_frames/resyncs）非零时
#   写一条 WARN 进本日志。logd 清环保留: 唯一目的是让 aee 转储器内置的
#   厂商 logread 也读不到开机期毒记录（其无法替换）。
#   v1.7 (2026-10-19 logread 崩溃轮): 开机后一次性清 syslog 环。厂商 logread 在
#   含开机期记录的 10MB 环上约 1%/次运行 SIGSEGV(libc ctime→asctime_r→snprintf→
#   vfprintf 路径, 三份未加密 core 同签名)。实测: 旧环 2500 次读取崩溃约 29 次量级,
#   重启 logd 清环后 2500 次 0 崩; 触发记录随开机日志进入环并长期驻留(10MB 环
#   数周才回卷)。uptime>=300s(boot 日志已落盘)时重启一次 logd 清环, 以
#   /proc/stat btime 标记本 boot 已执行; logd 由 procd respawn(5 1 -1) 兜底。
#   v1.6 (2026-10-18 日志降噪轮): 镜像层降噪 — 24h 实测 syslog 78% 音量来自
#   thermal_core 5s 温度行 + mipc_cli 每调用 2 行 + mtk_monitor_hang; dmesg 字节
#   大头是 cci 计数器 dump(rxq/isr 全列表)、SPM MCUSYSOFF 寄存器 dump(~900B/行)、
#   mtk_eth MAC 表 debug。这些行在**持久镜像**落盘前丢弃(丢弃量计数进 5min 汇总,
#   不静默); RAM 环(logread/dmesg 实时)不受影响, 现场排查仍可实时看。dmesg 镜像
#   容量 2MB->4MB(滤后同容量可留 ~2 天)。OOPS/panic/authpriv/自研守护日志全保留。
#   v1.5 (2026-10-18): BOOT 标记附 boot.reason(cmdline; 04:00 复位源排查的教训) —
#   软件重启与异常复位在持久日志里同样零指纹, reason 是少数可区分线索。
#   v1.3 (2026-10-17 日志加密轮): /tmp/*.log 由"tail 32K 覆盖快照"改为**增量追加**
#   (锚行定位; 本文件被本地轮转/截断 → resync 标记 + tail 120 重同步)。此前
#   /data/gw/logs/tmp 只保留每个日志的最后 32K, 加密后的 TICK/EVT 会被迅速覆盖,
#   24h 分析不可行。现每文件独立 1MB 上限, 超限轮转 .1(单代), 上一 boot 整体
#   转存 tmp.prev 的语义不变。非 .log 状态文件(*.out/wifi_autoch/watchdog_state/
#   dial_keeper.hb)仍用覆盖快照(它们要的是当前态, 不是历史)。
#   v1.2: 上一 boot 的 /tmp 快照转存 logs/tmp.prev — v1.1"变化才写"会让新 boot 的
#   守护日志在 +90s 内覆盖事故现场(10-14 模组 EE 事故: dial_keeper/watchdog 现场
#   因此丢失); 心跳文件入快照清单。
#   v1.1: 轮转后重写 boot 上下文 — selftest 实弹抓获轮转后 BOOT 分隔丢失）
# 痛点：/tmp 日志重启即失（信道取证丢失）；logread 环被刷爆（ql_wifi_sample 实测
#   18 秒深）；dmesg 被蜂窝噪声淹没；日志散落二十余处无统一现场。
# 机制（每 30s 一轮；增量为空不落盘，flash 友好）：
#   1) syslog 镜像  → /data/gw/logs/syslog.log（增量：以 .syslog.last 为锚，
#      只追加环内新增行；环溢出找不到锚 → 记 resync 标记 + tail 400 重同步）
#   2) dmesg 镜像   → /data/gw/logs/dmesg.log（同算法）
#   3) /tmp 快照    → /data/gw/logs/tmp/<name>（tail 32K，cmp 变化才写）；新 boot
#      首轮把上一 boot 的整目录转存 → logs/tmp.prev（单代，事故现场不再被覆盖）
#   4) boot 分隔    → 启动时与检出 uptime 回退时，向两个镜像写 BOOT 分隔行
#   5) 容量护栏     → syslog 4MB / dmesg 2MB 触发轮转(.1，仅留一代)；单轮追加
#      上限 512K（洪泛时限流，保 flash）
#   6) 每次开机 +180s 生成一份诊断包（diag_dump.sh → diag_boot.txt）
LOG=/tmp/log_keeper.log
DIR=/data/gw/logs
LOGC=/data/gw/bin/logc
lk() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
# v1.6: 镜像降噪模式(仅作用于持久镜像; busybox grep -E 实测兼容)
SYSLOG_DROP='thermal_core\[[0-9]+\]: interval=|mipc_cli\[[0-9]+\]: main:mipc operation (start|end)|mtk_monitor_hang\[[0-9]+\]:|\[ccci[0-9]+/(net|dpmaif|cif)\]|\[ccci[0-9]+/chr\]port ttyCMIPC[0-9]+ (open|close)'
DMESG_DROP='\[ccci[0-9]+/(net|dpmaif|cif)\]|MCUSYSOFF wake up|mtk_eth_search_port_by_mac_table|mt7992_apply_dpd_flatness_data|\[ccci[0-9]+/chr\]port ttyCMIPC[0-9]+ (open|close)|FORENSIC D:|wdtk-[0-9]+:|\[wdk-[a-z]+\]|hang_detect:|\[thread:[0-9]+\] [0-9-]+ [0-9:.]+ UTC|\[name:spm&\]'
DROP_S=0; DROP_D=0; DROP_S0=0; DROP_D0=0
# 增量抽取: 以 last 锚行在环内定位, 输出其后全部新增行(标准 busybox awk)
delta() { # $1=ring file $2=last-anchor
    grep -Fqx "$2" "$1" 2>/dev/null || return 1
    awk -v last="$2" '
        index($0, last) == 1 && length($0) == length(last) { n = 0; split("", B); hold = 1; next }
        hold { B[++n] = $0 }
        END { if (hold) for (i = 1; i <= n; i++) print B[i] }' "$1"
}
append_cap() { # stdin → $1 镜像, 单轮限流 512K, 容量轮转 $2; $3=noboot 跳过 BOOT 重写
    tail -c 524288 >> "$1"
    SZ=$(wc -c < "$1" 2>/dev/null)
    if [ "${SZ:-0}" -gt "$2" ]; then
        mv "$1" "$1.1"
        : > "$1"
        # v1.1: 轮转后重写 boot 上下文 — 否则新生代无 BOOT 分隔行(取证分界丢失;
        #   selftest 护栏实弹抓获: syslog 4MB 轮转后 boot_marks=0)
        echo "-- rotated ($SZ B → .1) --" >> "$1"
        [ "$3" = noboot ] || bootmark
        lk "rotate $1 (${SZ}B)"
    fi
}
# v1.3: 增量追加一个 /tmp 日志 → logs/tmp/<name>(锚行定位, 本地轮转即重同步)
STREAM_CAP=1048576
stream() { # $1=/tmp/xxx.log
    f=$1; [ -s "$f" ] || return 0
    b=$(basename "$f"); dst=$DIR/tmp/$b; anchor=$DIR/.last.$b
    LAST=$(cat "$anchor" 2>/dev/null)
    if [ -n "$LAST" ] && grep -Fqx "$LAST" "$f" 2>/dev/null; then
        NEW=$(delta "$f" "$LAST")
        [ -n "$NEW" ] && printf '%s\n' "$NEW" | append_cap "$dst" $STREAM_CAP noboot
    else
        { echo "-- resync $b $(date '+%F %T') (anchor missing: local rotate/truncate) --"; \
          tail -n 120 "$f"; } | append_cap "$dst" $STREAM_CAP noboot
        lk "stream resync $b"
    fi
    tail -n 1 "$f" > "$anchor"
}
bootmark() {
    # v1.5: 附 boot.reason(cmdline, LK 传入; 空=未知) — 复位源取证的免费证据
    B="===== BOOT epoch=$(date +%s) $(date '+%F %T %z') up=$(cut -d. -f1 /proc/uptime)s slot=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^bootslot=//p') reason=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^boot.reason=//p' | tr -d ' ') kern=$(uname -r) ====="
    echo "$B" >> $DIR/syslog.log
    echo "$B" >> $DIR/dmesg.log
    lk "$B"
}
mkdir -p $DIR/tmp
touch $DIR/syslog.log $DIR/dmesg.log $DIR/.prevup
# v2.0: single instance — a supervised restart must never double-append
_lp=$(cat /tmp/log_keeper.lock 2>/dev/null)
if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && kill -0 "$_lp" 2>/dev/null && \
   ! grep -q '^State:.*Z' /proc/$_lp/status 2>/dev/null && \
   grep -qa '/data/gw/log_keeper.sh' /proc/$_lp/cmdline 2>/dev/null; then
    echo "log_keeper: already running pid=$_lp" >&2
    exit 0
fi
echo $$ > /tmp/log_keeper.lock
# v2.0: aee NE census — db_history has no process name; the vendor syslog line
# does.  Called with the newly mirrored syslog text on stdin.
census() {
    awk -v out="$DIR/ne_census.tsv" -v ts="$(date +%s)" '
        />>>/ {
            pid = ""; comm = ""
            if (match($0, /pid: [0-9]+/)) { pid = substr($0, RSTART + 5, RLENGTH - 5) }
            if (match($0, />>>.*<<</)) {
                comm = substr($0, RSTART + 4, RLENGTH - 7)
                gsub(/^ +| +$/, "", comm)
            }
            if (comm != "") print ts "\t" pid "\t" comm "\t" $0 >> out
        }'
    # keep the census bounded (one line per crash; 2000 lines is plenty)
    _n=$(wc -l < "$DIR/ne_census.tsv" 2>/dev/null || echo 0)
    [ "${_n:-0}" -gt 2000 ] && { tail -n 1000 "$DIR/ne_census.tsv" > "$DIR/ne_census.tsv.tmp"; mv "$DIR/ne_census.tsv.tmp" "$DIR/ne_census.tsv"; }
}
# v1.2: 上一 boot 的 /tmp 快照转存 — 以 .snap_up(uptime 秒)记录快照归属的 boot;
#   uptime 回退(或首跑无标记) = 新 boot → tmp → tmp.prev(单代, 覆盖旧代);
#   同一 boot 内的 log_keeper 重启(看门狗自愈)不转存, 现场留在 tmp。
U0=$(cut -d. -f1 /proc/uptime 2>/dev/null)
PU0=$(cat $DIR/.snap_up 2>/dev/null)
case "$PU0" in
''|*[!0-9]*) _rot=1 ;;
*) _rot=0; [ "${U0:-0}" -lt "$PU0" ] 2>/dev/null && _rot=1 ;;
esac
if [ "$_rot" = 1 ]; then
    [ -d $DIR/tmp ] && { rm -rf $DIR/tmp.prev; mv $DIR/tmp $DIR/tmp.prev; }
    mkdir -p $DIR/tmp
    rm -f $DIR/.last.*   # v1.3: 锚点属于上一 boot 的 /tmp 文件, 必须失效
    lk "new boot: tmp -> tmp.prev, anchors reset"
fi
echo "${U0:-0}" > $DIR/.snap_up
# v1.9: BOOT 分隔行只在真 boot(btime 变化)时写; watchdog 重启守护不写假 BOOT.
_bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
_pbt=$(cat $DIR/.boot_btime 2>/dev/null)
if [ -n "$_bt" ] && [ "$_bt" != "$_pbt" ]; then
    echo "$_bt" > $DIR/.boot_btime
    lk "start (new boot btime=$_bt)"
    bootmark
else
    lk "start (same boot btime=${_bt:-unknown}; daemon restart, no BOOT line)"
fi
cut -d. -f1 /proc/uptime > /tmp/log_keeper.hb 2>/dev/null
PREV_UP=$(cut -d. -f1 /proc/uptime)
DIAG_DONE=""
while :; do
    sleep 30
    cut -d. -f1 /proc/uptime > /tmp/log_keeper.hb 2>/dev/null
    # -- boot 检出: uptime 回退 → 分隔行 + 重置锚(环已全新) --
    U=$(cut -d. -f1 /proc/uptime)
    if [ "${PREV_UP:-0}" -gt "$U" ] 2>/dev/null; then
        _bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
        [ -n "$_bt" ] && echo "$_bt" > $DIR/.boot_btime
        bootmark
        rm -f $DIR/.syslog.last $DIR/.dmesg.last
    fi
    PREV_UP=$U

    # -- v1.7: 开机后一次性清 syslog 环 --
    # v1.8: 本守护自身已改用 logc(静态+全帧校验), 不再需要清环来保护自己;
    # 保留清环的唯一原因 = aee 转储器内置的厂商 logread 无法替换, 而开机期
    # 记录是它的已知触发源。uptime>=300s 时 boot 日志已落盘, 重启 logd 清环;
    # btime 标记保证每 boot 只做一次。
    _bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
    if [ "${U:-0}" -ge 300 ] && [ -n "$_bt" ] && [ "$(cat $DIR/.logd_reset_bt 2>/dev/null)" != "$_bt" ]; then
        _lp=$(pidof logd 2>/dev/null)
        if [ -n "$_lp" ]; then
            kill $_lp 2>/dev/null
            echo "$_bt" > $DIR/.logd_reset_bt
            lk "logd restart to clear boot-era ring (pid=$_lp btime=$_bt up=$U)"
            sleep 3
        fi
    fi

    # -- syslog 镜像(v1.6: 降噪 — 高频低值行不落盘, 丢弃量计数入汇总) --
    # v1.8: logc 取代 logread: 静态链接 + 帧校验 + 重同步 + 时间戳范围断言。
    # v1.9: 先保存退出码 — `if ! cmd; then $?` 在 then 分支恒为 0(原 bug).
    $LOGC --stats-file /tmp/logc.stats 2>/tmp/logc.err > /tmp/lk_ring
    _lc=$?
    if [ "$_lc" -ne 0 ]; then
        lk "WARN logc rc=$_lc err=$(tail -n 1 /tmp/logc.err 2>/dev/null)"
        # v2.0: SIGSEGV breadcrumb written by logc's signal handler
        if [ -s /tmp/logc.crash ]; then
            mkdir -p $DIR/logc_crash 2>/dev/null
            cp /tmp/logc.crash "$DIR/logc_crash/crash.$(date +%Y%m%d-%H%M%S).txt" 2>/dev/null
            lk "WARN logc crash breadcrumb: $(tr '\n' ' ' < /tmp/logc.crash | head -c 300)"
        fi
    fi
    _bad=$(grep -o 'bad_frames=[0-9]*' /tmp/logc.stats 2>/dev/null | cut -d= -f2)
    _rs=$(grep -o 'resyncs=[0-9]*' /tmp/logc.stats 2>/dev/null | cut -d= -f2)
    if [ "${_bad:-0}" -gt 0 ] 2>/dev/null || [ "${_rs:-0}" -gt 0 ] 2>/dev/null; then
        lk "WARN logc frame anomalies: $(cat /tmp/logc.stats 2>/dev/null)"
    fi
    if [ -s /tmp/lk_ring ]; then
        LAST=$(cat $DIR/.syslog.last 2>/dev/null)
        if [ -n "$LAST" ]; then
            if NEW=$(delta /tmp/lk_ring "$LAST"); then
                if [ -n "$NEW" ]; then
                    _d=$(printf '%s\n' "$NEW" | grep -cE "$SYSLOG_DROP")
                    [ "${_d:-0}" -gt 0 ] && { NEW=$(printf '%s\n' "$NEW" | grep -vE "$SYSLOG_DROP"); DROP_S=$((DROP_S + _d)); }
                    [ -n "$NEW" ] && printf '%s\n' "$NEW" | append_cap $DIR/syslog.log 4194304
                    printf '%s\n' "$NEW" | census
                fi
            else
                { echo "-- syslog ring overflow/rotate, resync --"; tail -n 400 /tmp/lk_ring | grep -vE "$SYSLOG_DROP"; } | append_cap $DIR/syslog.log 4194304
                lk "syslog ring resync"
            fi
        else
            tail -c 65536 /tmp/lk_ring | grep -vE "$SYSLOG_DROP" >> $DIR/syslog.log
        fi
        tail -n 1 /tmp/lk_ring > $DIR/.syslog.last
    fi

    # -- dmesg 镜像(v1.6: 降噪 + 容量 2MB->4MB: 噪声滤除后同容量可留 ~2 天) --
    dmesg 2>/dev/null > /tmp/lk_ring
    if [ -s /tmp/lk_ring ]; then
        LAST=$(cat $DIR/.dmesg.last 2>/dev/null)
        if [ -n "$LAST" ]; then
            if NEW=$(delta /tmp/lk_ring "$LAST"); then
                if [ -n "$NEW" ]; then
                    _d=$(printf '%s\n' "$NEW" | grep -cE "$DMESG_DROP")
                    [ "${_d:-0}" -gt 0 ] && { NEW=$(printf '%s\n' "$NEW" | grep -vE "$DMESG_DROP"); DROP_D=$((DROP_D + _d)); }
                    [ -n "$NEW" ] && printf '%s\n' "$NEW" | append_cap $DIR/dmesg.log 4194304
                fi
            else
                { echo "-- dmesg 环溢出/轮转, resync --"; tail -n 400 /tmp/lk_ring | grep -vE "$DMESG_DROP"; } | append_cap $DIR/dmesg.log 4194304
                lk "dmesg ring resync"
            fi
        else
            tail -c 65536 /tmp/lk_ring | grep -vE "$DMESG_DROP" >> $DIR/dmesg.log
        fi
        tail -n 1 /tmp/lk_ring > $DIR/.dmesg.last
    fi

    # -- /tmp 日志增量追加(v1.3: 24h 历史; 每文件 1MB → .1) --
    for f in /tmp/*.log; do stream "$f"; done
    # -- 非日志状态快照(变化才写; 它们要的是当前态不是历史) --
    for f in /tmp/*.out /tmp/wifi_autoch /tmp/watchdog_state /tmp/dial_keeper.hb; do
        [ -s "$f" ] || continue
        b=$(basename "$f")
        tail -c 32768 "$f" > /tmp/lk_snap
        cmp -s /tmp/lk_snap $DIR/tmp/$b || { mv /tmp/lk_snap $DIR/tmp/$b; }
    done
    # -- 每 10 轮(5min)落一行汇总: 持久化规模 + 降噪丢弃量可观测(不静默) --
    CYC=$(( ${CYC:-0} + 1 ))
    if [ $((CYC % 10)) -eq 0 ]; then
        _nf=$(ls $DIR/tmp/*.log 2>/dev/null | wc -l)
        _nb=$(cat $DIR/tmp/*.log 2>/dev/null | wc -c)
        _ds=$((DROP_S - DROP_S0)); _dd=$((DROP_D - DROP_D0))
        DROP_S0=$DROP_S; DROP_D0=$DROP_D
        lk "stream summary: files=$_nf bytes=$_nb denoise_dropped: syslog=$_ds dmesg=$_dd (cum s=$DROP_S d=$DROP_D)"
    fi

    # -- 每次开机一份诊断包(+180s, 只做一次) --
    if [ -z "$DIAG_DONE" ] && [ "$U" -ge 180 ]; then
        DIAG_DONE=1
        [ -f /data/gw/diag_dump.sh ] && sh /data/gw/diag_dump.sh > $DIR/diag_boot.txt 2>&1 && lk "diag_boot.txt generated"
    fi
done
