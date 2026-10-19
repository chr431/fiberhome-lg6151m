#!/bin/sh
# core_trap.sh v1.0 -- daily user-space core capture window (SIGSEGV P3).
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
AEE_PATTERN='|/sbin/aee_core_forwarder /tmp %p %s %u %g'
SAVED=/tmp/core_trap.saved
ACTIVE=/tmp/core_trap.active
AEE0=/tmp/core_trap.aee0
COREDIR=/data/gw/logs/cores
LOG=/tmp/core_trap.log
PAT=/proc/sys/kernel/core_pattern
HIST=/data/log/aee_exp/db_history

# static musl tools read TZ (not /etc/TZ); inherit the image's POSIX TZ string
[ -z "${TZ:-}" ] && [ -r /etc/TZ ] && TZ=$(cat /etc/TZ 2>/dev/null) && export TZ

# single-instance / watchdog liveness lock
echo $$ > /tmp/core_trap.lock

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

trap 'end_window; exit 0' INT TERM HUP

while :; do
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
