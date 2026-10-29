#!/bin/sh
# netlock.sh v1.4 -- serialize route/firewall/address writers + REPAIR ledger.
# v1.3 (2026-10-29 锁重写): 锁从 "flock on fd" 换成 **目录租约** ——
#   flock 的锁属于进程的文件描述符, 任何在持锁期间 spawn 的长驻子进程都会继承它,
#   锁的生命周期于是绑到"那个子进程活多久"(实弹: radvd 被在锁内 spawn, 持锁 2h08m,
#   家宽断链时所有写方超时 -> 无法 failover)。目录锁不是 fd, **结构上不可能被继承**;
#   持有者死亡由等待方立即回收, 卡死由 60s 租约过期回收, 不再依赖看门狗轮转。
#   接口(netcfg_lock/unlock/busy/holders/break/repair/verify/with_netlock)保持不变。
# v1.2 (2026-10-29 断网轮): +netcfg_busy/netcfg_holders/netcfg_break —— flock 泄漏时
#   看门狗要能发现并轮转锁文件自救。
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
#   * the lock is a **directory lease**: mkdir(2) is atomic and a directory is
#     not inherited by children, so a daemon spawned inside the critical section
#     can never hold it.  The holder writes "pid epoch" into owner; waiters
#     reclaim immediately when that pid is gone, or after NETCFG_TTL (60s) when
#     the lease looks stuck.
#   * a waiter times out after NETCFG_TO seconds (default 3) and the caller
#     logs + skips the write; the level-driven loops retry next cycle, so a
#     lock timeout never stalls the state machine.
#   * netcfg_repair appends one durable line per repair to
#     /data/gw/logs/netcfg_repairs.tsv (epoch, what, rc, verified[, pre=1]).
#
# Sourced as: . /data/gw/netlock.sh
NETCFG_LOCKD=${NETCFG_LOCKD:-/tmp/netcfg.lock.d}
NETCFG_TO=${NETCFG_TO:-3}
NETCFG_TTL=${NETCFG_TTL:-60}
NETCFG_DEPTH=${NETCFG_DEPTH:-0}

netcfg_log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> /tmp/netcfg.log; }

netcfg_owner() { # stdout: "pid epoch"; 空 = 目录里还没有 owner(刚建好)
    cat "$NETCFG_LOCKD/owner" 2>/dev/null
}

netcfg_lock() { # $1=timeout seconds (default NETCFG_TO)
    _to=${1:-$NETCFG_TO}
    if [ "${NETCFG_DEPTH:-0}" -gt 0 ]; then
        NETCFG_DEPTH=$((NETCFG_DEPTH + 1))
        return 0
    fi
    _i=0; _r=0
    while :; do
        if mkdir "$NETCFG_LOCKD" 2>/dev/null; then
            echo "$$ $(date +%s)" > "$NETCFG_LOCKD/owner"
            NETCFG_DEPTH=1
            return 0
        fi
        _own=$(netcfg_owner); _p=${_own%% *}; _t=${_own##* }
        case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
        case "$_t" in ''|*[!0-9]*) _t=0 ;; esac
        # 持有者已死 -> 立即回收(比 flock 的"等内核"更早, 也不需要看门狗)
        if [ "$_p" -gt 0 ] && ! kill -0 "$_p" 2>/dev/null && [ "$_r" -lt 3 ]; then
            _r=$((_r + 1))
            # v1.4: 回收前复核 owner 未变 —— 否则可能误删别人刚建好的锁(微秒级竞态)
            [ "$(netcfg_owner | cut -d' ' -f1)" = "$_p" ] && {
                netcfg_log "EVT reclaim: holder pid=$_p gone (attempt $_r)"
                rm -rf "$NETCFG_LOCKD" 2>/dev/null
            }
            continue
        fi
        # 租约过期 -> 视为卡死(正常临界区 <1s)
        if [ "$_t" -gt 0 ] && [ $(( $(date +%s) - _t )) -gt "$NETCFG_TTL" ] && [ "$_r" -lt 3 ]; then
            _r=$((_r + 1))
            [ "$(netcfg_owner | cut -d' ' -f1)" = "$_p" ] && {
                netcfg_log "EVT reclaim: lease expired holder=${_p:-?} age=$(( $(date +%s) - _t ))s"
                rm -rf "$NETCFG_LOCKD" 2>/dev/null
            }
            continue
        fi
        _i=$((_i + 1))
        if [ "$_i" -gt "$_to" ]; then
            echo $(( $(cat /tmp/netcfg_lock_timeouts 2>/dev/null || echo 0) + 1 )) > /tmp/netcfg_lock_timeouts
            netcfg_log "WARN lock timeout ${_to}s (holder=${_p:-?} age=$(( $(date +%s) - ${_t:-0} ))s)"
            return 1
        fi
        sleep 1
    done
}

netcfg_unlock() {
    if [ "${NETCFG_DEPTH:-0}" -gt 1 ]; then
        NETCFG_DEPTH=$((NETCFG_DEPTH - 1))
        return 0
    fi
    NETCFG_DEPTH=0
    # 只删自己那份: 若租约被回收后别人持有, 这里必须放手
    _own=$(netcfg_owner)
    [ "${_own%% *}" = "$$" ] && rm -rf "$NETCFG_LOCKD" 2>/dev/null
    return 0
}

netcfg_busy() { # 0=被活着的、租约未过期的持有者占用; 1=空闲/残留
    [ -d "$NETCFG_LOCKD" ] || return 1
    _own=$(netcfg_owner); _p=${_own%% *}; _t=${_own##* }
    case "$_p" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_p" 2>/dev/null || return 1
    case "$_t" in ''|*[!0-9]*) return 0 ;; esac
    [ $(( $(date +%s) - _t )) -gt "$NETCFG_TTL" ] && return 1
    return 0
}

netcfg_holders() { # stdout: 持锁进程 cmdline(仅诊断用)
    _own=$(netcfg_owner); _p=${_own%% *}
    case "$_p" in ''|*[!0-9]*) return 0 ;; esac
    tr '\0' ' ' < "/proc/$_p/cmdline" 2>/dev/null | head -c 60
}

netcfg_break() { # 回收"死掉或租约过期"的锁目录; 活着的持有者不动
    [ -d "$NETCFG_LOCKD" ] || return 1
    netcfg_busy && return 1
    _own=$(netcfg_owner)
    rm -rf "$NETCFG_LOCKD" 2>/dev/null
    netcfg_log "EVT netlock break: removed stale lease (was: ${_own:-none})"
    return 0
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
