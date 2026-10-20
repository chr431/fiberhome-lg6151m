#!/bin/sh
# boot_gate.sh v1.0 -- real boot health gate (replaces the rc19 120s timer).
#
# Problem (2026-10-19 stability analysis P0-2): rc19 used
#     ( sleep 120; touch /tmp/boot.done ) &
# so "boot complete" was a timer, not a health verdict: the marker appeared
# even when every step after it failed.  selftest/watchdog/babysit all trusted
# that file, and rc.extend cleared LK's TRY_A counter seconds into the boot,
# so four bad boots never accumulated and the A/B fallback was dead.
#
# This daemon is started by rc19 at the very beginning and probes the real
# boot chain.  Only when the chain is verified does it:
#   * write /tmp/boot.done        (critical set: LAN IP + SSH + DHCP/DNS + GUI
#                                  listeners + rc19 finished) -> disarms babysit;
#   * write /data/gw/boot.healthy (full set: + 2 BSS + agg rules + uplink auth
#                                  + one uplink with default route) -> this is
#                                  what healthdog.sh requires before arming the
#                                  kernel wedge reset;
#   * clear LK TRY_A in misc[2061] and read it back (vendor S99 semantics, but
#     gated on a proven-healthy boot instead of a fixed sleep).
# Then it keeps observing until 10 minutes: a second full pass stamps
# stable=1 into boot.healthy (healthdog requires it before arming).
#
# "Critical" deliberately excludes uplink/WAN state: a cold boot with the
# home cable unplugged is still a healthy *firmware* boot, and must not be
# rolled back to slot B.  Uplink/authd/agg are service-level concerns owned by
# watchdog supervision; they are still recorded in the gate log and the
# healthy file carries degraded=1 when they are missing.
#
# Usage: boot_gate.sh          daemon (rc19)
#        boot_gate.sh --check  one-shot verdict for watchdog (no side effects)
#        boot_gate.sh --status last decision + current check table
set -u
# v1.0: the gate can be run by hand (no static PATH inherited); every probe
# below resolves to the static toolchain first.
PATH=/data/gw/sbin:/data/gw/bin:$PATH
export PATH

HERE=/data/gw
BB=$HERE/bin/busybox
[ -x "$BB" ] || BB=
TMO() { # $1=secs $2...=cmd
    _s=$1; shift
    if [ -n "$BB" ]; then "$BB" timeout -s KILL "$_s" sh -c "$*" 2>/dev/null; else sh -c "$*" 2>/dev/null; fi
}
LOG=/tmp/boot_gate.log
HEALTHY=$HERE/boot.healthy
PROG=/tmp/boot.progress
DONE=/tmp/boot.done
ATTEMPTS=$HERE/boot_attempts.tsv
MISC=/dev/mmcblk0p1
UP() { cut -d. -f1 /proc/uptime; }
say() { echo "$(date '+%m-%d %H:%M:%S') [$(UP)s] $*" >> "$LOG"; }
prog() { echo "$(date +%s) $(UP) $*" >> "$PROG"; say "$*"; }

PORT() { # $1=port -> 0 when a listener exists (hex local_address in /proc/net/tcp*)
    _hx=$(printf '%04X' "$1" 2>/dev/null)
    [ -n "$_hx" ] || return 1
    for _f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$_f" ] || continue
        awk -v p=":$_hx" '$4=="0A" && substr($2,length($2)-4)==p{f=1} END{exit(f?0:1)}' "$_f" 2>/dev/null && return 0
    done
    return 1
}

# ---- individual checks: 0 = pass ---------------------------------------
c_lan()    { TMO 4 "ip -4 addr show br-lan | grep -q 'inet 192.168.9.1'"; }
c_lo()     { TMO 4 "ip link show lo" | grep -q 'LOOPBACK,UP'; }
c_ssh()    { pidof dropbear >/dev/null 2>&1 && PORT 22; }
c_dns()    { pidof dnsmasq >/dev/null 2>&1 && PORT 53; }
c_gui()    { pidof v3httpd >/dev/null 2>&1 && PORT 80; }
c_ubus()   { [ -S /var/run/ubus/ubus.sock ] || [ -S /var/run/ubus.sock ]; }
c_wifi()   { [ "$(TMO 6 "iw dev" | grep -c 'type AP')" -ge 2 ]; }
c_agg()    { TMO 5 "iptables -t mangle -S WANAGG 2>/dev/null | grep -q MARK"; }
c_rc19()   { [ -f /tmp/rc19.done ]; }
c_authd() {
    _en=$(sed -n 's/^ENABLE=//p' $HERE/uplink.conf 2>/dev/null | tail -1)
    [ "$_en" = "1" ] || return 0
    _st=$(awk '{print $2}' /tmp/authd_state 2>/dev/null)
    case "$_st" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$(pidof authd 2>/dev/null)" ] && [ $(( $(date +%s) - _st )) -lt 300 ]
}
c_uplink() { # at least one uplink interface with an address + a default route
    TMO 5 "ip route show default 2>/dev/null | grep -q default" || return 1
    TMO 5 "ip -o -4 addr show 2>/dev/null" | grep -qE ' (eth0|ccmni[0-9]+) +inet '
}
c_wanalive() { # wan_agg's own timestamp, when the daemon is up
    pgrep -f 'wan_agg[.]sh' >/dev/null 2>&1 || return 1
    _ts=$(sed -n 's/.* ts=\([0-9][0-9]*\).*/\1/p' /tmp/wan_alive 2>/dev/null)
    case "$_ts" in ''|*[!0-9]*) return 1 ;; esac
    [ $(( $(date +%s) - _ts )) -lt 120 ]
}

# critical = boot chain itself (boot.done).  healthy = critical + firmware
# capabilities that do not depend on the outside world (boot.healthy, TRY_A,
# stable, healthdog arming).  full = healthy + environmental items (uplink /
# authd / wan_alive), recorded as degraded= but never required: an unplugged
# cable must not look like a broken boot.
CRIT="lan lo ssh dns gui rc19"
REQ="lan lo ssh dns gui rc19 wifi ubus agg"
ENV="authd uplink wanalive"
run_checks() { # $1 = "crit"|"healthy"|"full" -> prints key=ok/fail; rc = failures
    case "$1" in
    crit)    _list=$CRIT ;;
    healthy) _list=$REQ ;;
    *)       _list="$REQ $ENV" ;;
    esac
    _bad=0
    for _k in $_list; do
        if [ "$_k" = wanalive ] && ! pgrep -f 'wan_agg[.]sh' >/dev/null 2>&1; then
            echo "$_k=skip"; continue
        fi
        if "c_$_k" >/dev/null 2>&1; then
            echo "$_k=ok"
        else
            echo "$_k=fail"; _bad=$((_bad + 1))
        fi
    done
    return "$_bad"
}

CHECK_ONCE() { # --check: healthy verdict, no side effects
    _out=$(run_checks healthy); _rc=$?
    echo "$_out" | tr '\n' ' '; echo
    return "$_rc"
}

clear_try_a() {
    [ -b "$MISC" ] || { say "TRY_A: $MISC absent — cannot clear"; return 1; }
    _pre=$(dd if="$MISC" bs=1 skip=2060 count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
    dd if=/dev/zero of="$MISC" bs=1 seek=2061 count=1 conv=notrunc 2>/dev/null
    sync
    _post=$(dd if="$MISC" bs=1 skip=2060 count=10 2>/dev/null | od -An -tx1 | tr -d ' \n')
    _b1=$(dd if="$MISC" bs=1 skip=2061 count=1 2>/dev/null | od -An -tu1 | tr -d ' ')
    say "TRY_A clear: pre=$_pre post=$_post byte1=${_b1:-?}"
    [ "$_b1" = 0 ]
}

write_healthy() { # $1=stable(0|1) $2=degraded(0|1) $3=reason
    _tmp=$HEALTHY.tmp
    {
        echo "# boot health verdict (boot_gate v1.0)"
        echo "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
        echo "btime=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)"
        echo "epoch=$(date +%s)"
        echo "uptime=$(UP)"
        echo "stable=$1"
        echo "degraded=$2"
        echo "reason=$3"
        echo "checks=$(run_checks full | tr '\n' ' ')"
    } > "$_tmp" 2>/dev/null
    mv "$_tmp" "$HEALTHY"
    sync
}

mark_attempt() { # $1=result $2=note
    [ -f "$ATTEMPTS" ] || return 0
    _bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
    sed -i "s/^btime=$_bt result=pending.*/btime=$_bt result=$1 note=$2/" "$ATTEMPTS" 2>/dev/null
}

# ---- one-shot modes ------------------------------------------------------
case "${1:-}" in
--check) CHECK_ONCE; exit $? ;;
--status)
    if [ -f "$HEALTHY" ]; then sed -n '1,12p' "$HEALTHY"; else echo "no boot.healthy"; fi
    echo "done=$([ -f "$DONE" ] && echo y || echo n) rc19_done=$([ -f /tmp/rc19.done ] && echo y || echo n) up=$(UP)"
    run_checks full; exit $?
    ;;
esac

# ---- daemon --------------------------------------------------------------
_myid=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
_mp=$(cat /tmp/boot_gate.lock 2>/dev/null)
if [ -n "$_mp" ] && [ "$_mp" != "$$" ] && kill -0 "$_mp" 2>/dev/null; then
    echo "boot_gate: already running pid=$_mp" >&2
    exit 0
fi
echo $$ > /tmp/boot_gate.lock
say "start pid=$$ boot_id=$_myid btime=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null) core_pattern=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)"
prog "boot_gate start"

DONE_WRITTEN=0
HEALTHY_WRITTEN=0
STABLE=0
ROUND=0
while :; do
    ROUND=$((ROUND + 1))
    _up=$(UP)

    # critical verdict -> boot.done (this is what babysit waits for)
    if [ "$DONE_WRITTEN" = 0 ]; then
        _crit=$(run_checks crit); _crc=$?
        if [ "$_crc" -eq 0 ]; then
            printf 'boot_id=%s up=%s epoch=%s\n' "$_myid" "$_up" "$(date +%s)" > "$DONE.tmp"
            mv "$DONE.tmp" "$DONE"
            DONE_WRITTEN=1
            prog "CRITICAL PASS -> /tmp/boot.done up=${_up}s [$(echo "$_crit" | tr '\n' ' ')]"
            echo "$_up boot.done" > /tmp/watchdog.beat 2>/dev/null
        else
            prog "critical pending [$(echo "$_crit" | tr '\n' ' ')]"
        fi
    fi

    # full verdict -> boot.healthy + TRY_A clear
    _full=$(run_checks healthy); _frc=$?
    if [ "$HEALTHY_WRITTEN" = 0 ] && [ "$_frc" -eq 0 ]; then
        _deg=0
        run_checks full >/dev/null 2>&1 || _deg=1
        write_healthy 0 "$_deg" "healthy pass at ${_up}s (degraded=$_deg)"
        HEALTHY_WRITTEN=1
        prog "HEALTHY PASS -> boot.healthy (up=${_up}s degraded=$_deg) checks=[$(echo "$_full" | tr '\n' ' ')]"
        clear_try_a
        mark_attempt healthy "gate ${_up}s"
        logger -t boot_gate "healthy at ${_up}s (degraded=$_deg); TRY_A cleared"
        # observation window: 10 minutes from health before stable=1
    elif [ "$HEALTHY_WRITTEN" = 1 ] && [ "$STABLE" = 0 ] && [ "$_up" -ge 600 ]; then
        if [ "$_frc" -eq 0 ]; then
            write_healthy 1 0 "stable at ${_up}s"
            STABLE=1
            prog "STABLE -> boot.healthy stable=1 at ${_up}s"
            logger -t boot_gate "stable at ${_up}s"
            for _i in 1 2 3; do echo hb > /proc/healthdog 2>/dev/null; sleep 1; done
        else
            _deg=1
            write_healthy 0 "$_deg" "degraded at ${_up}s: $(echo "$_full" | grep -v '=ok' | tr '\n' ' ')"
            prog "DEGRADED at ${_up}s [$(echo "$_full" | tr '\n' ' ')]"
        fi
    elif [ "$HEALTHY_WRITTEN" = 1 ] && [ "$_up" -ge 900 ]; then
        break   # observation done; watchdog takes over
    fi

    # progress heartbeat (babysit watches PROG mtime)
    [ $((ROUND % 6)) -eq 0 ] && echo "$(date +%s) $(UP) gate round=$ROUND done=$DONE_WRITTEN healthy=$HEALTHY_WRITTEN stable=$STABLE" >> "$PROG"

    [ "$_up" -lt 300 ] && sleep 10 || sleep 30
done
say "exit: observation window complete"
exit 0
