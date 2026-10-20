#!/bin/sh
# core_meta.sh v1.0 -- core_pattern metadata wrapper (stability P1-2/P1-5).
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
# /data/gw/logs/ne_events.tsv (watchdog reads it for WARN messages).
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
PARGS=$(tr '\0' ' ' < /proc/$PPID_/cmdline 2>/dev/null | head -c 300)
ARGS=$(tr '\0' ' ' < /proc/$PID/cmdline 2>/dev/null | head -c 600)

{
    echo "# core metadata (core_meta v1.0)"
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

# one-line census (watchdog appends this to its WARN when aee NE increments)
[ -s "$F" ] && echo "$_ts	$PID	${COMM:-?}	sig=$SIG	exe=${EXE:-?}	args=${ARGS:-?}" >> "$TSV" 2>/dev/null

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
