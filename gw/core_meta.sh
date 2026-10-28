#!/bin/sh
# core_meta.sh v1.4 -- core_pattern metadata wrapper (stability P1-2/P1-5).
# v1.4 (2026-10-28 时钟轮): unsync 判据改为 /tmp/ntp_synced 缺失(权威) + 原年份
#   阈值兜底。原判据 epoch<2025-01-01 在构建日 2026-09-09 下永远不成立, 开机窗
#   口的 NE 行因此全部没有标记(实测 9 行 17889xxxxxx 无 unsync)。
# v1.3 (SIGSEGV §8.13): 旧内核修复栈退役 —— 删除 v1.1 加的 NE 探针(崩溃时向旧栈
#   /proc 节点写 deep 的那一行)。本脚本此后只做元数据落盘, 不再触碰任何模块。
# v1.2 (SIGSEGV Phase 0): ne_events.tsv 行尾增 origin 列
#   (our-tree/vendor-tree/unknown) —— 台账"归零"时区分"修好了"与"看不见了";
#   判定只看祖先链 comm/cmdline(静态农场 exe 全同, 不可判), 见 _origin()。
# v1.1: Census hygiene: argv newlines/tabs are squashed (multi-line args broke
#   TSV rows) and pre-NTP-sync epochs get an unsync=1 marker column.
#
# aee owns /proc/sys/kernel/core_pattern as
#     |/sbin/aee_core_forwarder /tmp %p %s %u %g
# and its dumps are encrypted: no process name, no registers, no map.  The
# 2026-10-19 crashes (logc twice, awk/ip/sh/grep/netstat) therefore had no
# attributable evidence (analysis §4).
#
# This wrapper keeps aee's behaviour intact -- after taking a snapshot it
# exec()s the very same forwarder with the same argv, and never touches stdin
# (the kernel streams the core there) -- but first records:
#   * pid/comm/signal/uid/gid, exe, cwd, parent, argv
#   * /proc/<pid>/status (Vm/task/threads/stack) and maps (capped)
#   * PATH only from environ (no other env vars: credentials must not land)
#   * the persistent dmesg mirror tail + aee db_history tail
# One file per crash in /data/gw/logs/cores/meta/, one TSV census line in
# /data/gw/logs/ne_events.tsv. 读取方 = avail_sampler.sh:74/92(行数游标)与
# :107-124(整行子串归属), 都不按列取值 —— 故新列只许追加在行尾。
#
# Safety: <=120 files kept; every command is absolute; failure to record must
# never prevent aee from getting the core (so no `set -e`, all errors ignored).

# core_pattern helpers run with a minimal kernel-provided environment: set PATH.
PATH=/data/gw/sbin:/data/gw/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ -z "${TZ:-}" ] && [ -r /etc/TZ ] && TZ=$(cat /etc/TZ 2>/dev/null) && export TZ
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=
DIR=/data/gw/logs/cores/meta
TSV=/data/gw/logs/ne_events.tsv
PID=${1:-0}
SIG=${2:-0}
UID_=${3:-0}
GID=${4:-0}
case "$PID" in ''|*[!0-9]*) exit 0 ;; esac
[ "$PID" -gt 0 ] || exit 0

uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null; }
rlink() { if [ -n "$BB" ]; then "$BB" readlink "$1" 2>/dev/null; else readlink "$1" 2>/dev/null; fi; }
catf() { if [ -n "$BB" ]; then "$BB" cat "$1" 2>/dev/null; else cat "$1" 2>/dev/null; fi; }

mkdir -p "$DIR" 2>/dev/null
_bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
_ts=$(date +%s)
F=$DIR/${_bt}-${PID}-${_ts}.txt
COMM=$(catf /proc/$PID/comm)
EXE=$(rlink /proc/$PID/exe)
PPID_=$(awk '{print $4}' /proc/$PID/stat 2>/dev/null)
PCOMM=$(catf /proc/$PPID_/comm)
PARGS=$(tr '\0' ' ' 2>/dev/null < /proc/$PPID_/cmdline | head -c 300)
ARGS=$(tr '\0' ' ' 2>/dev/null < /proc/$PID/cmdline | head -c 600)

{
    echo "# core metadata (core_meta v1.2)"
    echo "epoch=$_ts date=$(date '+%Y-%m-%d %H:%M:%S') uptime=$(uptime_s) btime=$_bt"
    echo "pid=$PID comm=[$COMM] signal=$SIG uid=$UID_ gid=$GID_"
    echo "exe=[$EXE] ppid=$PPID_ pcomm=[$PCOMM]"
    echo "parent_args=[$PARGS]"
    echo "args=[$ARGS]"
    echo "--- status (selected) ---"
    if [ -n "$BB" ]; then
        "$BB" grep -E '^(Name|State|Tgid|Pid|PPid|Uid|Gid|Threads|SigQ|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt|CapEff|voluntary|nonvoluntary):' /proc/$PID/status 2>/dev/null
    else
        grep -E '^(Name|State|Tgid|Pid|PPid|Uid|Gid|Threads|SigQ|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt|CapEff|voluntary|nonvoluntary):' /proc/$PID/status 2>/dev/null
    fi
    echo "cwd=[$(rlink /proc/$PID/cwd)]"
    echo "fds=$(ls /proc/$PID/fd 2>/dev/null | wc -l)"
    # PATH only: environ can carry credentials, never copy it wholesale
    echo "env_path=[$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | grep '^PATH=' | head -1)]"
    echo "--- maps (first 80) ---"
    catf /proc/$PID/maps | head -n 80
    echo "--- maps tail (last 20) ---"
    catf /proc/$PID/maps | tail -n 20
    echo "--- dmesg mirror tail ---"
    tail -n 80 /data/gw/logs/dmesg.log 2>/dev/null
    echo "--- aee db_history tail ---"
    tail -n 5 /data/log/aee_exp/db_history 2>/dev/null
} > "$F" 2>/dev/null

# ---- v1.2: origin 归属 -----------------------------------------------------
# 静态农场下 exe 不可用于判定: 崩溃进程和它的祖先几乎都是同一个静态件
# (/data/gw/bin/busybox 或静态工具本体), exe 永远是那个二进制, 看不出崩在谁的
# 子树里。唯一可用信号是每一层的 comm 与 cmdline(脚本路径只出现在 cmdline)。
# 规则: 从崩溃进程自身(第 0 层)沿 /proc/<pid>/stat 的 ppid 向上最多 3 层,
#   任一层 comm/cmdline 命中自研件集合 → our-tree;
#   链走到 pid 1 (procd/init) 仍未命中     → vendor-tree;
#   链断(进程已被回收/ppid 读不成数字)或超 3 层 → unknown。
OURSET="rc19.sh rc.extend.sh v3_rc10.extend.sh boot_gate.sh log_keeper.sh \
watchdog.sh led_mgr.sh dial_keeper.sh wan_agg.sh healthdog.sh core_meta.sh \
avail_sampler.sh ntp_keeper.sh reboot_sched.sh traffic_logger.sh wifi_guard.sh \
fan_mgr.sh wan_eth.sh usb_mgr.sh v3httpd selftest"

_origin() { # $1=崩溃 pid; 输出 our-tree|vendor-tree|unknown
	_d=$1
	_lv=0
	while [ "$_lv" -le 3 ]; do
		case "$_d" in ''|*[!0-9]*) break ;; esac
		[ "$_d" -gt 0 ] || break
		_c=$(catf /proc/$_d/comm)
		_cl=$(tr '\0' ' ' 2>/dev/null < /proc/$_d/cmdline | head -c 300)
		for _p in $OURSET; do
			case "$_c" in *"$_p"*) echo our-tree; return 0 ;; esac
			case "$_cl" in *"$_p"*) echo our-tree; return 0 ;; esac
		done
		[ "$_d" = 1 ] && { echo vendor-tree; return 0; }
		_d=$(awk '{print $4}' /proc/$_d/stat 2>/dev/null)
		_lv=$((_lv + 1))
	done
	echo unknown
}

# one-line census; 列序固定(新列只许加在行尾):
#   ts / pid / comm / sig=N / exe=路径 / args=... / [unsync=1] / origin=归属
# v1.1: unsync marker when the clock is obviously pre-NTP (epoch < 2025-01-01)
# so boot-window NE rows can be told apart instead of landing in 1970 buckets
_us=""
{ [ ! -s /tmp/ntp_synced ] || [ "${_ts:-0}" -lt 1735689600 ]; } 2>/dev/null && _us="	unsync=1"
_or=$(_origin "$PID")
case "$_or" in our-tree|vendor-tree) ;; *) _or=unknown ;; esac
[ -s "$F" ] && echo "$_ts	$PID	${COMM:-?}	sig=$SIG	exe=${EXE:-?}	args=${ARGS:-?}$_us	origin=$_or" >> "$TSV" 2>/dev/null

# quota: keep the 120 newest metadata files
_n=$(ls "$DIR" 2>/dev/null | wc -l)
if [ "${_n:-0}" -gt 120 ]; then
    ls -t "$DIR" 2>/dev/null | tail -n +121 | while read -r _f; do rm -f "$DIR/$_f"; done
fi

# --- hand the core to aee exactly as before (stdin untouched) -------------
if [ -x /sbin/aee_core_forwarder ]; then
    exec /sbin/aee_core_forwarder /tmp "$PID" "$SIG" "$UID_" "$GID_"
fi
exit 0
