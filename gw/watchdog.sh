#!/bin/sh
# watchdog.sh v1.1 -- on-device continuous invariant monitor.
# L13: "feature silently broken until manual inspection" countermeasure.
# Runs every 30s; failures log + WAN LED flash; recovers silently.
# Started by rc19.sh (pgrep guard); single instance.

LOG=/tmp/watchdog.log
STATE=/tmp/watchdog_state
LED=/sys/class/leds/5g_evb_voice/brightness
CYCLE=30
MAX_LOG=200

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

# state helpers (track transitions, not absolutes)
set_state() {  # $1=key $2=0(ok)|1(fail) $3=label
    PREV=$(grep "^$1=" $STATE 2>/dev/null | tail -1 | cut -d= -f2)
    if [ "$2" != "$PREV" ]; then
        if [ "$2" = 1 ]; then
            log "FAIL  $3"
        else
            log "OK    $3 (recovered)"
        fi
        # upsert
        grep -v "^$1=" $STATE 2>/dev/null > $STATE.tmp
        echo "$1=$2" >> $STATE.tmp
        mv $STATE.tmp $STATE
    fi
}

check() {  # $1=key $3=label, $2=check command
    KEY=$1; CMD=$2; LABEL=$3
    if eval "$CMD" >/dev/null 2>&1; then
        set_state "$KEY" 0 "$LABEL"
    else
        set_state "$KEY" 1 "$LABEL"
        FAILS=$((FAILS+1))
    fi
}

run_cycle() {
    FAILS=0

    # ---- process invariants (pidof 比 pgrep -x 更可靠, busybox -x 有怪癖) ----
    check hostapd   "pgrep -f 'hostapd -B'"         "hostapd F3 daemon"
    check v3httpd   "netstat -tln 2>/dev/null | grep -q ':80.*LISTEN'"  "GUI httpd"
    check dnsmasq   "pidof dnsmasq"                  "DHCP/DNS"
    check dropbear  "netstat -tln 2>/dev/null | grep -q ':22.*LISTEN'"  "SSH"
    check wan_agg   "pgrep -f wan_agg.sh"            "aggregation supervisor"
    check led_mgr   "pgrep -f led_mgr.sh"            "LED manager"
    check fan_mgr   "pgrep -f fan_mgr.sh"            "fan manager"

    # ---- data plane invariants ----
    check agg_rules "iptables -t mangle -S WANAGG 2>/dev/null | grep -q sport" "split rules installed"
    check fwmark    "ip rule | grep -q fwmark"       "fwmark policy routing"
    check nat       "iptables -t nat -S POSTROUTING | grep -q MASQ"  "NAT masquerade"
    check bss       "[ \$(iw dev 2>/dev/null | grep -c 'type AP') -ge 2 ]"  "2+ BSS active"
    check port80    "netstat -tln 2>/dev/null | grep -q ':80.*LISTEN'"  "GUI :80 reachable"
    check port22    "netstat -tln 2>/dev/null | grep -q ':22.*LISTEN'"  "SSH :22 reachable"
    check boot      "[ -f /tmp/boot.done ]"          "boot chain complete"
    check lan_ip    "ip -4 addr show br-lan | grep -q inet"  "LAN IP present"

    # ---- incremental events ----
    BCN=$(dmesg | grep -cE 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
    BCN_PREV=$(grep '^beacon=' $STATE 2>/dev/null | tail -1 | cut -d= -f2)
    if [ -n "$BCN_PREV" ] && [ "$BCN" -gt "$BCN_PREV" ] 2>/dev/null; then
        log "WARN  beacon events +$((BCN-BCN_PREV))"
    fi
    grep -v '^beacon=' $STATE 2>/dev/null > $STATE.tmp
    echo "beacon=$BCN" >> $STATE.tmp
    mv $STATE.tmp $STATE

    # ---- visual alert ----
    if [ "$FAILS" -gt 0 ]; then
        for i in 1 2 3; do
            echo 1 > $LED 2>/dev/null; sleep 0.1
            echo 0 > $LED 2>/dev/null; sleep 0.1
        done
    fi

    # ---- log truncation ----
    LINES=$(wc -l < $LOG 2>/dev/null || echo 0)
    if [ "$LINES" -gt "$MAX_LOG" ]; then
        tail -n $((MAX_LOG/2)) $LOG > $LOG.tmp 2>/dev/null && mv $LOG.tmp $LOG
    fi
}

# ---- main ----
touch $LOG $STATE
log "===== watchdog v1.1 start ====="
# initialize state to current (suppress initial alarms)
run_cycle  # first run logs transitions but that's fine
while :; do
    sleep $CYCLE
    run_cycle
done
