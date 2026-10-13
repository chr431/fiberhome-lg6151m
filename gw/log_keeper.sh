#!/bin/sh
# log_keeper.sh v1.2 -- 日志持久化守护（日志改善专项轮; v1.2: 上一 boot 的 /tmp 快照
#   转存 logs/tmp.prev — v1.1"变化才写"会让新 boot 的守护日志在 +90s 内覆盖事故现场
#   (10-14 模组 EE 事故: dial_keeper/watchdog 现场因此丢失); 心跳文件入快照清单。
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
lk() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
# 增量抽取: 以 last 锚行在环内定位, 输出其后全部新增行(标准 busybox awk)
delta() { # $1=ring file $2=last-anchor
    grep -Fqx "$2" "$1" 2>/dev/null || return 1
    awk -v last="$2" '
        index($0, last) == 1 && length($0) == length(last) { n = 0; split("", B); hold = 1; next }
        hold { B[++n] = $0 }
        END { if (hold) for (i = 1; i <= n; i++) print B[i] }' "$1"
}
append_cap() { # stdin → $1 镜像, 单轮限流 512K, 容量轮转 $2
    tail -c 524288 >> "$1"
    SZ=$(wc -c < "$1" 2>/dev/null)
    if [ "${SZ:-0}" -gt "$2" ]; then
        mv "$1" "$1.1"
        : > "$1"
        # v1.1: 轮转后重写 boot 上下文 — 否则新生代无 BOOT 分隔行(取证分界丢失;
        #   selftest 护栏实弹抓获: syslog 4MB 轮转后 boot_marks=0)
        echo "-- rotated ($SZ B → .1), boot context re-marked --" >> "$1"
        bootmark
        lk "rotate $1 (${SZ}B)"
    fi
}
bootmark() {
    B="===== BOOT $(date '+%F %T %z') up=$(cut -d. -f1 /proc/uptime)s slot=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^bootslot=//p') kern=$(uname -r) ====="
    echo "$B" >> $DIR/syslog.log
    echo "$B" >> $DIR/dmesg.log
    lk "$B"
}
mkdir -p $DIR/tmp
touch $DIR/syslog.log $DIR/dmesg.log $DIR/.prevup
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
fi
echo "${U0:-0}" > $DIR/.snap_up
lk "start"
bootmark
PREV_UP=$(cut -d. -f1 /proc/uptime)
DIAG_DONE=""
while :; do
    sleep 30
    # -- boot 检出: uptime 回退 → 分隔行 + 重置锚(环已全新) --
    U=$(cut -d. -f1 /proc/uptime)
    if [ "${PREV_UP:-0}" -gt "$U" ] 2>/dev/null; then
        bootmark
        rm -f $DIR/.syslog.last $DIR/.dmesg.last
    fi
    PREV_UP=$U

    # -- syslog 镜像 --
    logread 2>/dev/null > /tmp/lk_ring
    if [ -s /tmp/lk_ring ]; then
        LAST=$(cat $DIR/.syslog.last 2>/dev/null)
        if [ -n "$LAST" ]; then
            if NEW=$(delta /tmp/lk_ring "$LAST"); then
                [ -n "$NEW" ] && printf '%s\n' "$NEW" | append_cap $DIR/syslog.log 4194304
            else
                { echo "-- logread 环溢出/轮转, resync --"; tail -n 400 /tmp/lk_ring; } | append_cap $DIR/syslog.log 4194304
                lk "syslog ring resync"
            fi
        else
            tail -c 65536 /tmp/lk_ring >> $DIR/syslog.log
        fi
        tail -n 1 /tmp/lk_ring > $DIR/.syslog.last
    fi

    # -- dmesg 镜像 --
    dmesg 2>/dev/null > /tmp/lk_ring
    if [ -s /tmp/lk_ring ]; then
        LAST=$(cat $DIR/.dmesg.last 2>/dev/null)
        if [ -n "$LAST" ]; then
            if NEW=$(delta /tmp/lk_ring "$LAST"); then
                [ -n "$NEW" ] && printf '%s\n' "$NEW" | append_cap $DIR/dmesg.log 2097152
            else
                { echo "-- dmesg 环溢出/轮转, resync --"; tail -n 400 /tmp/lk_ring; } | append_cap $DIR/dmesg.log 2097152
                lk "dmesg ring resync"
            fi
        else
            tail -c 65536 /tmp/lk_ring >> $DIR/dmesg.log
        fi
        tail -n 1 /tmp/lk_ring > $DIR/.dmesg.last
    fi

    # -- /tmp 快照(变化才写) --
    for f in /tmp/*.log /tmp/*.out /tmp/wifi_autoch /tmp/watchdog_state /tmp/dial_keeper.hb; do
        [ -s "$f" ] || continue
        b=$(basename "$f")
        tail -c 32768 "$f" > /tmp/lk_snap
        cmp -s /tmp/lk_snap $DIR/tmp/$b || { mv /tmp/lk_snap $DIR/tmp/$b; }
    done

    # -- 每次开机一份诊断包(+180s, 只做一次) --
    if [ -z "$DIAG_DONE" ] && [ "$U" -ge 180 ]; then
        DIAG_DONE=1
        [ -f /data/gw/diag_dump.sh ] && sh /data/gw/diag_dump.sh > $DIR/diag_boot.txt 2>&1 && lk "diag_boot.txt generated"
    fi
done
