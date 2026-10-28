#!/bin/sh
# netlock.sh v1.1 -- serialize route/firewall/address writers + REPAIR ledger.
# v1.1 (2026-10-28 时钟轮): 台账行尾加 pre=1 标记 —— 设备无 RTC, 开机到 NTP 首
#   同步之间 date +%s 是构建日, 那一段的 epoch 不可信(实弹: 118 行 2026-09-09)。
#   标记依据 = /tmp/ntp_synced(ntp_keeper 写) 缺失, 兼 epoch<2025-01-01 兜底。
#
# Batch 3 (stability P2-4 structural): several daemons legitimately write the
# same kernel objects (rc_netfh at boot, wan_agg every cycle, wan_eth every 5s,
# fw_apply from boot/API, ccmni_up on dial, guest_fw on WiFi sync).  Before
# this library the only coordination was "one writer per object by convention";
# a supervised restart or a hot reload could interleave two writers.
#
# Contract:
#   * netcfg_lock / netcfg_unlock are re-entrant inside one process (depth
#     counter), so a caller may hold the lock and call a library function that
#     also locks.
#   * the lock is a flock(2) on /tmp/netcfg.lock via the static busybox
#     (fallback: atomic mkdir + pid staleness when busybox is unavailable).
#   * a waiter times out after NETCFG_TO seconds (default 3) and the caller
#     logs + skips the write; the level-driven loops retry next cycle, so a
#     lock timeout never stalls the state machine.
#   * netcfg_repair appends one durable line per repair to
#     /data/gw/logs/netcfg_repairs.tsv (epoch, what, rc, verified).  The
#     watchdog reports the rolling-hour count as a REPAIR-rate metric.
#
# Sourced as: . /data/gw/netlock.sh
NETCFG_LOCK=${NETCFG_LOCK:-/tmp/netcfg.lock}
NETCFG_TO=${NETCFG_TO:-3}
NETCFG_DEPTH=${NETCFG_DEPTH:-0}
BB=${BB:-/data/gw/bin/busybox}
[ -x "$BB" ] || BB=

netcfg_log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> /tmp/netcfg.log; }

netcfg_lock() { # $1=timeout seconds (default NETCFG_TO)
    _to=${1:-$NETCFG_TO}
    if [ "${NETCFG_DEPTH:-0}" -gt 0 ]; then
        NETCFG_DEPTH=$((NETCFG_DEPTH + 1))
        return 0
    fi
    if [ -n "$BB" ]; then
        exec 9>>"$NETCFG_LOCK" 2>/dev/null || return 1
        # This busybox build has flock -n but no -w: bounded retry loop instead.
        if "$BB" flock -n 9 2>/dev/null; then
            NETCFG_DEPTH=1
            return 0
        fi
        _i=0
        while [ "$_i" -lt "$_to" ]; do
            sleep 1
            _i=$((_i + 1))
            if "$BB" flock -n 9 2>/dev/null; then
                NETCFG_DEPTH=1
                return 0
            fi
        done
        exec 9>&-
        echo $(( $(cat /tmp/netcfg_lock_timeouts 2>/dev/null || echo 0) + 1 )) > /tmp/netcfg_lock_timeouts
        return 1
    fi
    # fallback: atomic mkdir + pid staleness (only when busybox is absent)
    _d=$NETCFG_LOCK.d
    _i=0
    while ! mkdir "$_d" 2>/dev/null; do
        _p=$(cat "$_d/pid" 2>/dev/null)
        if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
            rm -rf "$_d"
            continue
        fi
        _i=$((_i + 1))
        [ "$_i" -ge "$_to" ] && {
            echo $(( $(cat /tmp/netcfg_lock_timeouts 2>/dev/null || echo 0) + 1 )) > /tmp/netcfg_lock_timeouts
            return 1
        }
        sleep 1
    done
    echo $$ > "$_d/pid"
    NETCFG_DEPTH=1
    return 0
}

netcfg_unlock() {
    if [ "${NETCFG_DEPTH:-0}" -gt 1 ]; then
        NETCFG_DEPTH=$((NETCFG_DEPTH - 1))
        return 0
    fi
    NETCFG_DEPTH=0
    if [ -n "$BB" ]; then
        exec 9>&- 2>/dev/null
    else
        rm -rf "$NETCFG_LOCK.d"
    fi
}

with_netlock() { # $@=command/function to run under the lock
    if ! netcfg_lock "${NETCFG_TO}"; then
        netcfg_log "WARN netcfg lock timeout (${NETCFG_TO}s): $*"
        return 1
    fi
    "$@"
    _rc=$?
    netcfg_unlock
    return $_rc
}

# Durable repair ledger.  $1=what, $2=rc, $3=verified (ok|fail|?)
netcfg_repair() {
    _f=/data/gw/logs/netcfg_repairs.tsv
    [ -d /data/gw/logs ] || _f=/tmp/netcfg_repairs.tsv
    _ts=$(date +%s); _pre=""
    { [ ! -s /tmp/ntp_synced ] || [ "$_ts" -lt 1735689600 ]; } 2>/dev/null && _pre=" pre=1"
    echo "$_ts $1 rc=${2:-0} verified=${3:-?}$_pre" >> "$_f" 2>/dev/null
    _n=$(wc -l < "$_f" 2>/dev/null || echo 0)
    if [ "${_n:-0}" -gt 4000 ]; then
        tail -n 2000 "$_f" > "$_f.tmp" 2>/dev/null && mv "$_f.tmp" "$_f"
    fi
}

# Verify a write after the fact; logs only when the check fails.
netcfg_verify() { # $1=what $2=shell test command
    if sh -c "$2" >/dev/null 2>&1; then
        return 0
    fi
    netcfg_log "WARN verify failed: $1"
    return 1
}
