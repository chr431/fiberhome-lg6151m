#!/bin/sh
# svc_lib.sh v1.0 -- shared supervision, lock, heartbeat and minimal-parser library.
#
# Batch 3 (stability P0/P1 structural): one implementation for the primitives
# that had been copied into every daemon and into watchdog:
#   * single-instance lock with cmdline + zombie verification (svc_lock);
#   * uptime heartbeat writer (svc_hb);
#   * 2-of-3 failure confirmation, per-service restart budget, lock-first
#     liveness, /proc/net/tcp listener probe (strike/strike_clear/rl_ok/alive/
#     port_listen) -- unchanged semantics, now shared;
#   * minimal static parsers for the remaining safety probes: link flags from
#     sysfs, BSS/hostapd from control sockets, zombies from /proc/*/stat,
#     disk free via the static busybox, dmesg via the static busybox;
#   * the declarative script-daemon table (SVC_TABLE) consumed by watchdog.
#
# Design rules:
#   * source-only, no side effects (safe for the daemons and for watchdog);
#   * no dependency on bash; busybox ash only;
#   * every parser is read-only and bounded (no unbounded wait, no vendor tool
#     in a destructive decision path).
#
# Sourced as: . /data/gw/svc_lib.sh
BB=${BB:-/data/gw/bin/busybox}
[ -x "$BB" ] || BB=
IP=${IP:-/data/gw/bin/ip}
[ -x "$IP" ] || IP=ip

# ---- liveness / confirmation primitives (moved from watchdog v1.28) -------
hb_age() { # $1=heartbeat file (uptime seconds); 999999 if missing/non-numeric
    _v=$(cat "$1" 2>/dev/null)
    _u=$(cut -d. -f1 /proc/uptime)
    case "$_v" in ''|*[!0-9]*) echo 999999 ;; *) echo $((_u - _v)) ;; esac
}
# Listener liveness from /proc/net/tcp{,6} (hex local_address), never netstat.
port_listen() { # $1=port
    _hx=$(printf '%04X' "$1" 2>/dev/null)
    [ -n "$_hx" ] || return 1
    for _f in /proc/net/tcp /proc/net/tcp6; do
        [ -r "$_f" ] || continue
        awk -v p=":$_hx" '$4=="0A" && substr($2,length($2)-4)==p{f=1} END{exit(f?0:1)}' "$_f" 2>/dev/null && return 0
    done
    return 1
}
# Lock-first liveness: the pid lock is authoritative (exact pid + cmdline
# verification); pgrep -f is only the legacy fallback.
alive() { # $1=pgrep pattern  $2=lock name  $3=cmdline token
    _ap=$(cat /tmp/$2.lock 2>/dev/null)
    [ -n "$_ap" ] && kill -0 "$_ap" 2>/dev/null && \
        ! grep -q '^State:.*Z' /proc/$_ap/status 2>/dev/null && \
        [ -n "$3" ] && grep -qa "/data/gw/$3" /proc/$_ap/cmdline 2>/dev/null && return 0
    pgrep -f "/data/gw/$3" >/dev/null 2>&1 && return 0
    return 1
}
# 2-of-3 sample confirmation: 3-character history ("1"=failure, "0"=pass).
strike() { # $1=key; 0 when at least 2 of the last 3 samples failed
    _f=/tmp/watchdog_strike_$1
    _h=$(cat "$_f" 2>/dev/null | tr -d ' \n')
    case "$_h" in ???*) _h="${_h#?}" ;; esac
    _h="${_h}1"; echo "$_h" > "$_f"
    _n=$(echo "$_h" | awk '{n=gsub(/1/,"1"); print n+0}')
    [ "$_n" -ge 2 ] && { rm -f "$_f"; return 0; }
    return 1
}
strike_clear() { # $1=key; records a PASS sample
    _f=/tmp/watchdog_strike_$1
    _h=$(cat "$_f" 2>/dev/null | tr -d ' \n')
    case "$_h" in ???*) _h="${_h#?}" ;; esac
    echo "${_h}0" > "$_f"
}
# Per-service restart budget: max 3 per hour (tmpfs; reboot resets).
rl_ok() { # $1=name
    _f=/tmp/watchdog_svc_$1.rec; _n=0; _t=0
    [ -r "$_f" ] && read _n _t < "$_f"
    _now=$(date +%s)
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    case "$_t" in ''|*[!0-9]*) _t=$_now ;; esac
    [ $((_now - _t)) -gt 3600 ] && { _n=0; _t=$_now; }
    [ "$_n" -ge 3 ] && return 1
    echo "$((_n + 1)) $_t" > "$_f"
    return 0
}

# ---- daemon side: lock + heartbeat ---------------------------------------
# svc_lock <lock-name> <absolute script path>
#   0 = acquired, 1 = duplicate (another live instance owns the lock),
#   2 = lost the check-then-write race (a supervisor/another instance won).
svc_lock() {
    _lk=/tmp/$1.lock
    _lp=$(cat "$_lk" 2>/dev/null)
    if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && kill -0 "$_lp" 2>/dev/null \
       && ! grep -q '^State:.*Z' "/proc/$_lp/status" 2>/dev/null \
       && [ -n "$2" ] && grep -qa -- "$2" "/proc/$_lp/cmdline" 2>/dev/null; then
        return 1
    fi
    echo $$ > "$_lk"
    # watchdog spawn() pre-writes the child pid; settle, then re-read so a
    # stale-pid race cannot produce two owners.
    sleep 0.2 2>/dev/null || sleep 1
    [ "$(cat "$_lk" 2>/dev/null)" = "$$" ] || return 2
    return 0
}
svc_lock_assert() { echo $$ > "/tmp/$1.lock" 2>/dev/null; }
svc_hb() { cut -d. -f1 /proc/uptime > "/tmp/$1.hb" 2>/dev/null; }

# ---- minimal static parsers ---------------------------------------------
# Link UP bit (IFF_UP=1) from sysfs; no iw/ip needed.
svc_link_up() { # $1=ifname
    _f=$(cat "/sys/class/net/$1/flags" 2>/dev/null) || return 1
    case "$_f" in 0x*|0X*) ;; *) return 1 ;; esac
    [ $((_f & 1)) -ne 0 ]
}
# loopback is UP and still carries IFF_LOOPBACK (8).  The old healthdog ping
# predicate failed forever on this image because lo was DOWN.
svc_loopback_up() {
    _f=$(cat /sys/class/net/lo/flags 2>/dev/null) || return 1
    case "$_f" in 0x*|0X*) ;; *) return 1 ;; esac
    [ $((_f & 1)) -ne 0 ] && [ $((_f & 8)) -ne 0 ]
}
# Active BSS = hostapd control socket present AND the BSS netdev is UP.
# This is stricter than "iw dev shows type AP": it also proves the WPA layer
# (hostapd) is serving the interface, which is the property we actually need.
svc_bss_count() {
    _n=0
    for _i in ra0 rai0 ra1 rai1; do
        [ -S "/var/run/hostapd/$_i" ] || continue
        svc_link_up "$_i" || continue
        _n=$((_n + 1))
    done
    echo $_n
}
# hostapd itself: process + both primary control sockets + both links UP.
# hostapd_cli is no longer part of the health decision (it segfaulted twice
# in the field); it stays available as a diagnostic only.
svc_hostapd_up() {
    pidof hostapd >/dev/null 2>&1 || return 1
    [ -S /var/run/hostapd/ra0 ] || return 1
    [ -S /var/run/hostapd/rai0 ] || return 1
    svc_link_up ra0 && svc_link_up rai0
}
# Zombie count from /proc/*/stat (state is the field after the last ')').
svc_zombies() {
    awk '{ sub(/^.*\) /, ""); if (substr($0, 1, 1) == "Z") n++ } END { print n + 0 }' \
        /proc/[0-9]*/stat 2>/dev/null
}
# Free KiB on a filesystem via the static busybox (df is a static applet).
svc_df_free() { # $1=path
    if [ -n "$BB" ]; then
        "$BB" df -k "$1" 2>/dev/null | tail -1 | awk '{print $4}'
    else
        df -k "$1" 2>/dev/null | tail -1 | awk '{print $4}'
    fi
}
# dmesg line count matching an ERE, via the static busybox dmesg.
svc_dmesg_count() { # $1=ERE
    if [ -n "$BB" ]; then
        "$BB" dmesg 2>/dev/null | grep -cE "$1"
    else
        dmesg 2>/dev/null | grep -cE "$1"
    fi
}
# Associated stations; iw is still a vendor binary, so this probe is bounded
# and advisory only (never part of a destructive decision).
svc_station_count() { # $1=ifname
    if [ -n "$BB" ]; then
        "$BB" timeout -s KILL 5 iw dev "$1" station dump 2>/dev/null | grep -c '^Station'
    else
        iw dev "$1" station dump 2>/dev/null | grep -c '^Station'
    fi
}
# Interfaces carrying an IPv4 default route, parsed from /proc/net/route.
svc_default_v4_ifaces() {
    awk 'NR > 1 && $2 == "00000000" && $8 == "00000000" { print $1 }' /proc/net/route 2>/dev/null | sort -u
}
svc_iface_has_v4() { # $1=ifname
    "$IP" -o -4 addr show dev "$1" 2>/dev/null | grep -q ' inet '
}
# REPAIR events in the last rolling hour, from netlock.sh's durable ledger.
svc_repairs_1h() {
    _f=/data/gw/logs/netcfg_repairs.tsv
    [ -r "$_f" ] || { echo 0; return; }
    awk -v n="$(date +%s)" '$1 ~ /^[0-9]+$/ && n - $1 <= 3600 { c++ } END { print c + 0 }' "$_f"
}

# ---- declarative script-daemon table ------------------------------------
# Columns: name|pgrep-pattern|lock-token|recipe|heartbeat|max-hb-age|env
# env is optional and is passed to "env" before the shell (dial_keeper needs
# the FH library/PATH environment when restarted by the supervisor).
SVC_TABLE='
ntp_keeper|ntp_keeper[.]sh|ntp_keeper.sh|sh /data/gw/ntp_keeper.sh|/tmp/ntp_keeper.hb|4200|
traffic_logger|traffic_logger[.]sh|traffic_logger.sh|sh /data/gw/traffic_logger.sh|/tmp/traffic_logger.hb|900|
wifi_guard|wifi_guard[.]sh|wifi_guard.sh|sh /data/gw/wifi_guard.sh|/tmp/wifi_guard.hb|90|
reboot_sched|reboot_sched[.]sh|reboot_sched.sh|sh /data/gw/reboot_sched.sh|/tmp/reboot_sched.hb|900|
led_mgr|led_mgr[.]sh|led_mgr.sh|sh /data/gw/led_mgr.sh|/tmp/led_mgr.hb|60|
fan_mgr|fan_mgr[.]sh|fan_mgr.sh|sh /data/gw/fan_mgr.sh|/tmp/fan_mgr.hb|60|
wan_eth|wan_eth[.]sh|wan_eth.sh|sh /data/gw/wan_eth.sh|/tmp/wan_eth.hb|150|
log_keeper|log_keeper[.]sh|log_keeper.sh|sh /data/gw/log_keeper.sh|/tmp/log_keeper.hb|180|
core_trap|core_trap[.]sh|core_trap.sh|sh /data/gw/core_trap.sh|/tmp/core_trap.hb|600|
healthdog|healthdog[.]sh|healthdog.sh|sh /data/gw/healthdog.sh|/tmp/healthdog.hb|60|
dial_keeper|dial_keeper[.]sh|dial_keeper.sh|sh /data/gw/dial_keeper.sh|/tmp/dial_keeper.hb|90|LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib PATH=/data/gw/sbin:/data/gw/bin:/usr/sbin:/usr/bin:/sbin:/bin:/fhrom/bin:/fhrom/fhshell
'
