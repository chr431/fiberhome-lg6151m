#!/bin/sh
# healthdog.sh v1.3 -- userspace half of healthdog + second-level supervisor.
#
# v1.3 (2026-10-20): loopback was measured DOWN on this image (state DOWN,
#   ping 127.0.0.1 fails, on-device connects to 192.168.9.1 time out).  Bring
#   lo up here as well: the heartbeat predicate below requires loopback, and an
#   armed kernel watchdog with a dead lo would reset the box every 90s.
# v1.2 (2026-10-20 stability P0-1): the kernel module used to be armed only by
#   a manual marker, so in practice `armed=0 / heartbeats=0` (no kernel-level
#   wedge reset at all).  This version is a supervisor:
#     * waits for boot_gate to stamp boot.healthy with stable=1 (a 10-minute
#       observation window) — the same boot_id, not a stale file;
#     * watches watchdog's own beacon (/tmp/watchdog.beat).  Stale >120s:
#       restart watchdog once, dump tasks (sysrq-t) for forensics, and if it
#       is still stale after another 60s, ARM the kernel module so a D-state
#       wedge that kills every userspace loop still forces a reset;
#     * refuses to arm when the last boots were unhealthy or the previous arm
#       happened <10 min ago (reboot-loop guard);
#     * copies /sys/fs/pstore/console-ramoops-0 to /data/gw/logs/pstore/ once
#       per boot (P1-5: the only crash record that survives a hard reset).
# HEARTBEAT = loopback answers AND the watchdog beacon is fresh.  External
# reachability is logged but deliberately NOT part of the predicate: an ISP
# outage must never trigger a kernel reset.  If the loop itself stalls
# (D-storm), heartbeats stop naturally -> kernel resets.
# Manual override: /data/gw/healthdog.disarmed disables arming entirely.
PATH=/data/gw/sbin:/data/gw/bin:$PATH
export PATH
[ -z "${TZ:-}" ] && [ -r /etc/TZ ] && TZ=$(cat /etc/TZ 2>/dev/null) && export TZ
LOG=/tmp/healthdog.log
HB=/tmp/healthdog.hb
HEALTHY=/data/gw/boot.healthy
BEAT=/tmp/watchdog.beat
ATTEMPTS=/data/gw/boot_attempts.tsv
ARM_LOG=/data/gw/healthdog.armlog
DISARM=/data/gw/healthdog.disarmed
PSDIR=/data/gw/logs/pstore
hd() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> $LOG; }
up() { cut -d. -f1 /proc/uptime; }
now() { date +%s; }
bid() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }

if [ ! -e /proc/healthdog ]; then
    MOD=/data/gw/healthdog.ko
    [ -f "$MOD" ] && insmod "$MOD" forensic=0 armed=0 2>/dev/null
    [ -e /proc/healthdog ] || { hd "module not loaded"; exit 1; }
fi
echo $$ > /tmp/healthdog.lock 2>/dev/null
# v1.3: loopback is required by the heartbeat predicate (and was DOWN)
ip link set lo up 2>/dev/null
hd "start v1.3 pid=$$ boot_id=$(bid) up=$(up)s lo=$(ip link show lo 2>/dev/null | head -1)"

# ---- pstore: rescue the previous boot's console log (P1-5) ---------------
collect_pstore() {
    P=/sys/fs/pstore/console-ramoops-0
    [ -s "$P" ] || return 0
    _bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
    mkdir -p "$PSDIR" 2>/dev/null
    O=$PSDIR/console-ramoops.$_bt.txt
    [ -s "$O" ] && return 0
    cp "$P" "$O" 2>/dev/null && hd "pstore saved: $O ($(wc -c < "$O" 2>/dev/null) bytes)"
}

# ---- boot-loop guard ----------------------------------------------------
recent_unhealthy() { # 0 when the last 3 attempts contain no healthy
    [ -r "$ATTEMPTS" ] || return 1
    _tail=$(tail -n 3 "$ATTEMPTS" 2>/dev/null)
    case "$_tail" in *result=healthy*) return 1 ;; esac
    [ -n "$_tail" ] && return 0
    return 1
}
arm_recent() { # 0 when an arm happened <600s ago
    [ -r "$ARM_LOG" ] || return 1
    _t=$(tail -n 1 "$ARM_LOG" 2>/dev/null | awk '{print $1}')
    case "$_t" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $(now) - _t )) -lt 600 ]
}
healthy_ok() { # 0 when boot.healthy is for THIS boot and stable=1
    [ -r "$HEALTHY" ] || return 1
    _id=$(sed -n 's/^boot_id=//p' "$HEALTHY" 2>/dev/null | tail -1)
    _st=$(sed -n 's/^stable=//p' "$HEALTHY" 2>/dev/null | tail -1)
    [ -n "$_id" ] && [ "$_id" = "$(bid)" ] && [ "$_st" = 1 ]
}

collect_pstore

ARMED=0
WATCHDOG_TRIES=0
LAST_RESTART=0
while :; do
    echo "$(up)" > "$HB" 2>/dev/null
    u=$(up)

    if [ -f "$DISARM" ]; then
        [ "$ARMED" = 1 ] && { echo disarm > /proc/healthdog 2>/dev/null; ARMED=0; }
        hd "disarmed by marker ($(cat "$DISARM" 2>/dev/null | head -c 80))"
        sleep 30
        continue
    fi

    # kernel-armed path: heartbeat while the loop itself and the primary
    # supervisor answer.  Deliberately NOT gated on internet/WAN reachability:
    # an armed watchdog that withholds heartbeats when the ISP is down would
    # reboot a perfectly healthy box every 90s.  External reachability is
    # logged, never used to withhold.
    if [ "$ARMED" = 1 ]; then
        lo=0; ext=0
        ping -c1 -W2 127.0.0.1 >/dev/null 2>&1 && lo=1
        ping -c1 -W3 223.5.5.5 >/dev/null 2>&1 && ext=1
        ping -c1 -W2 192.168.9.101 >/dev/null 2>&1 && ext=1
        _ba=$(cat "$BEAT" 2>/dev/null)
        case "$_ba" in ''|*[!0-9]*) _wage=999999 ;; *) _wage=$((u - _ba)) ;; esac
        # a live-but-slow watchdog gets 300s (probes can time out); a watchdog
        # whose pid is gone gets 120s.
        _wpid=$(cat /tmp/watchdog.lock 2>/dev/null)
        _limit=120
        if [ -n "$_wpid" ] && kill -0 "$_wpid" 2>/dev/null && \
           grep -qa '/data/gw/watchdog.sh' /proc/$_wpid/cmdline 2>/dev/null; then
            _limit=300
        fi
        if [ "$lo" = 1 ] && [ "$_wage" -le "$_limit" ]; then
            echo hb > /proc/healthdog 2>/dev/null
            [ $(( $(now) % 300 )) -lt 10 ] && hd "armed heartbeat ok up=${u}s wd_age=${_wage}s ext=$ext"
            WBAD=0; WATCHDOG_TRIES=0
        elif [ "$lo" = 1 ] && [ "$_wage" -gt "$_limit" ] && [ "$WATCHDOG_TRIES" -lt 1 ]; then
            # one grace restart: keep heartbeating while the primary recovers
            WATCHDOG_TRIES=1
            hd "armed: watchdog stale ${_wage}s — restarting once (heartbeat kept)"
            _wp=$(cat /tmp/watchdog.lock 2>/dev/null)
            if [ -n "$_wp" ] && kill -0 "$_wp" 2>/dev/null && \
               grep -qa '/data/gw/watchdog.sh' /proc/$_wp/cmdline 2>/dev/null; then
                kill -9 "$_wp" 2>/dev/null
            fi
            nohup sh /data/gw/watchdog.sh >/dev/null 2>&1 </dev/null &
            echo hb > /proc/healthdog 2>/dev/null
            sleep 45
            echo hb > /proc/healthdog 2>/dev/null
        else
            if [ "${WBAD:-0}" = 0 ]; then
                WBAD=1
                hd "ARMED HEALTH FAIL up=${u}s lo=$lo wd_age=${_wage}s ext=$ext — heartbeat withheld (reset in 90s)"
                echo t > /proc/sysrq-trigger 2>/dev/null
            fi
        fi
        sleep 10
        continue
    fi

    # not armed: arm once the boot has been healthy and stable for the window,
    # then keep supervising from the armed branch above.  Arming proactively is
    # the point: a wedged userspace cannot arm itself later.
    if [ "$u" -lt 600 ]; then
        sleep 10
        continue
    fi
    if ! healthy_ok; then
        [ $((u % 300)) -lt 10 ] && hd "not arming: no stable boot.healthy for this boot (up=${u}s)"
        sleep 10
        continue
    fi
    if recent_unhealthy; then
        hd "ARM REFUSED: recent boot attempts are not healthy (reboot-loop guard)"
        sleep 60
        continue
    fi
    if arm_recent; then
        hd "ARM REFUSED: an arm happened <600s ago (reboot-loop guard)"
        sleep 60
        continue
    fi
    if echo arm > /proc/healthdog 2>/dev/null; then
        ARMED=1
        echo "$(now) arm up=${u}s stable-healthy" >> "$ARM_LOG" 2>/dev/null
        hd "KERNEL ARMED after stable window (up=${u}s; timeout=$(sed -n 's/.*timeout_s=\([0-9]*\).*/\1/p' /proc/healthdog 2>/dev/null)s)"
        echo hb > /proc/healthdog 2>/dev/null
    else
        hd "ARM FAILED: /proc/healthdog not writable"
        sleep 30
    fi
    sleep 10
done
