#!/bin/sh
# core_trap.sh v1.3 -- DEPRECATED / 默认停用 (SIGSEGV Phase 0, 2026-10-25).
#
# 停用理由(三条实测结论, 见 docs/SIGSEGV_ANALYSIS.md):
#   1) 从未抓到家族 core: 窗口开过的 600s 里, 族成员(grep/awk/sh/ip/...)的崩溃
#      一次也没落进 /tmp/core.%p; 唯一捕获到的 core 是模拟演练自造的;
#   2) 每日制造 600s 元数据盲窗: 窗口内 core_pattern 被改成文件模式
#      /tmp/core.%p(本文件 :168 set_pattern), core_meta.sh 整条链(元数据落盘 + aee
#      记账 + dpclamp 探测)被完全绕过 —— 台账归零不等于修好, 恰是"看不见了";
#   3) 使厂商子树失明: 文件模式下内核强制 cprm.limit=RLIMIT_CORE
#      (fs/coredump.c:716), 而本脚本的 ulimit 只覆盖自身(rc.extend.sh:73 同理
#      只覆盖其后代), 由 procd 拉起的厂商守护 RLIMIT_CORE 仍可能是 0 → 窗口内
#      它们崩溃连 core 文件都不落; 管道模式相反, 内核强制 RLIM_INFINITY
#      (fs/coredump.c:675), 不看 RLIMIT_CORE。两相比较文件窗口是纯亏损。
#
# 处置: 文件与代码保留(取证/复现用), 调度点已全部摘除 ——
#   gw/v3_rc10.extend.sh(部署为 /data/gw/rc19.sh) 不再拉起本脚本;
#   gw/svc_lib.sh 的 SVC_TABLE 不再登记(否则 watchdog 会把它拉回来)。
# 手动复现窗口: CORETRAP_ENABLE=1 sh /data/gw/core_trap.sh
# 停用后 core_pattern 由 rc.extend.sh:85 常驻管道 |/data/gw/core_meta.sh ...
#
# 历史设计(v1.2 及以前, 现默认停用):
# v1.2 -- daily user-space core capture window (SIGSEGV P3).
# v1.1 (2026-10-20 stability P1-5): restore target is now the core_meta.sh
#   wrapper (which execs aee, so behaviour is unchanged); a start-up check
#   warns when core_pattern was not wrapped by rc.extend.  Heartbeat for the
#   watchdog supervision table + quota index (files/bytes) for the kept cores.
#
# aee owns /proc/sys/kernel/core_pattern in normal operation.  This daemon
# opens a short daily window (default 03:20 local, 600 s) during which
# core_pattern points at /tmp/core.%p, then moves any captured cores to
# /data/gw/logs/cores/YYYYMMDD/ and restores the aee forwarder.  The goal is
# to close the remaining gap in docs/SIGSEGV_ANALYSIS.md §6: the family
# members (grep/awk/sh/ip/...) crash on specific inputs, but no family core
# has ever been captured.  RLIMIT_CORE is raised to unlimited at boot by
# rc.extend.sh so the daemons' children inherit it.
#
# Safety:
#   - the previous core_pattern is saved before the switch; any exit path
#     (normal, signal, reboot-time stale file) restores it;
#   - the window closes early if /tmp is >80% full;
#   - if this daemon is killed -9 mid-window, the next start (watchdog
#     restarts it) sees /tmp/core_trap.active and restores the pattern first.
set -u

START=${CORETRAP_START:-03:20}
SECS=${CORETRAP_SECS:-600}
AEE_PATTERN='|/data/gw/core_meta.sh %p %s %u %g'
CORE_QUOTA_FILES=${CORE_QUOTA_FILES:-60}
CORE_QUOTA_MB=${CORE_QUOTA_MB:-200}
SAVED=/tmp/core_trap.saved
ACTIVE=/tmp/core_trap.active
AEE0=/tmp/core_trap.aee0
COREDIR=/data/gw/logs/cores
LOG=/tmp/core_trap.log
PAT=/proc/sys/kernel/core_pattern
HIST=/data/log/aee_exp/db_history

# static musl tools read TZ (not /etc/TZ); inherit the image's POSIX TZ string
[ -z "${TZ:-}" ] && [ -r /etc/TZ ] && TZ=$(cat /etc/TZ 2>/dev/null) && export TZ

# single-instance / watchdog liveness lock (v1.2 batch3: svc_lib)
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else echo "core_trap: svc_lib.sh missing" >&2; exit 1; fi
_rc=0; svc_lock core_trap /data/gw/core_trap.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    [ "$_rc" = 1 ] && echo "core_trap: already running" >&2 || echo "core_trap: lost lock race" >&2
    exit 0
fi

say() {
	echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"
	logger -t core_trap "$*" 2>/dev/null
}

num() { # strip leading zeros so ash arithmetic never treats "08" as octal
	v=$(echo "$1" | sed 's/^0*//')
	[ -z "$v" ] && v=0
	echo "$v"
}

in_window() {
	_h=$(num "$(date +%H)")
	_m=$(num "$(date +%M)")
	_s=$(num "$(date +%S)")
	_sh=$(num "${START%%:*}")
	_sm=$(num "${START#*:}")
	_now=$((_h * 3600 + _m * 60 + _s))
	_st=$((_sh * 3600 + _sm * 60))
	_end=$((_st + SECS))
	if [ "$_end" -le 86400 ]; then
		[ "$_now" -ge "$_st" ] && [ "$_now" -lt "$_end" ]
	else
		# window crosses midnight
		[ "$_now" -ge "$_st" ] || [ "$_now" -lt $((_end - 86400)) ]
	fi
}

set_pattern() {
	echo "$1" > "$PAT" 2>/dev/null
}

restore_pattern() {
	if [ -s "$SAVED" ]; then
		set_pattern "$(cat "$SAVED")"
	else
		set_pattern "$AEE_PATTERN"
	fi
	rm -f "$SAVED"
}

# v1.1: global core quota across day dirs (flash is finite)
quota() {
	_n=$(ls $COREDIR/*/core.* 2>/dev/null | wc -l)
	case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
	if [ "$_n" -gt "$CORE_QUOTA_FILES" ]; then
		ls -t $COREDIR/*/core.* 2>/dev/null | tail -n +$((CORE_QUOTA_FILES + 1)) | \
			while read -r _old; do rm -f "$_old"; done
		say "quota: files ${_n} > ${CORE_QUOTA_FILES}, oldest removed"
	fi
	_kb=$(du -sk "$COREDIR" 2>/dev/null | awk '{print $1}')
	case "$_kb" in ''|*[!0-9]*) _kb=0 ;; esac
	if [ "$_kb" -gt $((CORE_QUOTA_MB * 1024)) ]; then
		ls -t $COREDIR/*/core.* 2>/dev/null | while read -r _old; do
			rm -f "$_old"
			_kb=$(du -sk "$COREDIR" 2>/dev/null | awk '{print $1}')
			[ "${_kb:-0}" -le $((CORE_QUOTA_MB * 1024)) ] && break
		done
		say "quota: size exceeded ${CORE_QUOTA_MB}MB, oldest removed"
	fi
	echo "$(date +%s)	$(ls $COREDIR/*/core.* 2>/dev/null | wc -l) files	$(du -sk "$COREDIR" 2>/dev/null | awk '{print $1}') KB" >> "$COREDIR/quota.tsv" 2>/dev/null
}

end_window() {
	[ -f "$ACTIVE" ] || return 0
	restore_pattern
	D=$COREDIR/$(date +%Y%m%d)
	_n=0
	if ls /tmp/core.* >/dev/null 2>&1; then
		mkdir -p "$D" 2>/dev/null
		for f in /tmp/core.*; do
			[ -f "$f" ] || continue
			mv "$f" "$D/" 2>/dev/null && _n=$((_n + 1))
		done
		# keep the newest 20 cores only (flash is finite)
		if [ "$_n" -gt 0 ]; then
			ls -t "$D"/core.* 2>/dev/null | tail -n +21 | while read -r old; do
				rm -f "$old"
			done
		fi
	fi
	_a0=$(cat "$AEE0" 2>/dev/null)
	_a1=$(wc -l < "$HIST" 2>/dev/null)
	rm -f "$ACTIVE" "$AEE0"
	quota
	say "window closed: cores=$_n dir=$D aee_lines=${_a0:-?}->${_a1:-?}"
}

begin_window() {
	# save the current (aee) pattern exactly once; a stale /tmp pattern from
	# a previous crashed window is not a valid restore target.
	if [ ! -s "$SAVED" ]; then
		_cur=$(cat "$PAT" 2>/dev/null)
		case "$_cur" in
		'/tmp/core.%p'|'') _cur="$AEE_PATTERN" ;;
		esac
		printf '%s\n' "$_cur" > "$SAVED"
	fi
	set_pattern '/tmp/core.%p'
	wc -l < "$HIST" > "$AEE0" 2>/dev/null
	: > "$ACTIVE"
	_corelim=$(ulimit -c 2>/dev/null)
	say "window open: core_pattern=/tmp/core.%p cores_lim=${_corelim:-?} aee_lines=$(cat "$AEE0" 2>/dev/null)"
}

# ---- stale-window recovery (killed -9 or reboot while active) --------------
if [ -f "$ACTIVE" ]; then
	restore_pattern
	rm -f "$ACTIVE" "$AEE0"
	say "stale window recovered; core_pattern restored"
fi

# ---- v1.3: 默认停用(理由见文件头) -----------------------------------------
# 位置有讲究: 必须排在上面 stale-window 恢复之后 —— 若上次窗口没关就停了调度,
# core_pattern 会永久停在 /tmp/core.%p(文件模式), 元数据链就永远断着。
case "${CORETRAP_ENABLE:-0}" in
1|yes|on) ;;
*)
	say "DEPRECATED: disabled (CORETRAP_ENABLE=${CORETRAP_ENABLE:-0}); core_pattern untouched"
	exit 0
	;;
esac

# v1.1: core_pattern must be the core_meta wrapper (which execs aee); if some
# vendor script rewrote it, say so loudly — attribution would be lost.
_cur=$(cat "$PAT" 2>/dev/null)
case "$_cur" in
*core_meta.sh*) ;;
*) say "WARN core_pattern not wrapped: [$_cur] (rc.extend v2.6 should own it)" ;;
esac
svc_hb core_trap

trap 'end_window; exit 0' INT TERM HUP

while :; do
	svc_hb core_trap
	if in_window; then
		[ -f "$ACTIVE" ] || begin_window
		_use=$(df /tmp 2>/dev/null | awk 'NR==2{gsub("%","",$5); print $5}')
		case "$_use" in ''|*[!0-9]*) _use=0 ;; esac
		if [ "$_use" -ge 80 ]; then
			say "tmp ${_use}% full -- closing window early"
			end_window
		fi
	else
		[ -f "$ACTIVE" ] && end_window
	fi
	sleep 30
done
