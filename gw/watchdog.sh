#!/bin/sh
# watchdog.sh v1.0 -- on-device continuous invariant monitor.
# Design: L13 -- run every cycle, check things that MUST be true, alert on
# violation. Complements selftest.py (PC-side, thorough) with lightweight
# continuous monitoring. Failures write to /tmp/watchdog.log and toggle the
# WAN LED as a visual indicator.
# Started by rc19.sh; single instance (pgrep guard).

LOG=/tmp/watchdog.log
LED_WAN=/sys/class/leds/5g_evb_voice/brightness
LED_WLAN=/sys/kernel/debug/gpio  # can't directly write; use led_mgr path
CYCLE=30
MAX_LOG=200    # lines before truncate

log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

# --- invariant checkers (each returns 0=ok 1=fail, logs on transition) ---

CHK=""

defchk() {  # $1=name  $2=check_command (must exit 0)
    CHK="$CHK $1:$2"
}

defchk hostapd   "pgrep -f 'hostapd -B' >/dev/null"
defchk v3httpd   "pgrep -x v3httpd >/dev/null"
defchk dnsmasq   "pidof dnsmasq >/dev/null"
defchk dropbear  "pgrep -x dropbear >/dev/null"
defchk wan_agg   "pgrep -f wan_agg.sh >/dev/null"
defchk led_mgr   "pgrep -f led_mgr.sh >/dev/null"
defchk fan_mgr   "pgrep -f fan_mgr.sh >/dev/null"
defchk wanagg_rules "iptables -t mangle -S WANAGG 2>/dev/null | grep -q sport"
defchk fwmark_v4  "ip rule | grep -q fwmark"
defchk boot_done  "[ -f /tmp/boot.done ]"
defchk nat_masq   "iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQ"
defchk bss_count  "[ \"\$(iw dev 2>/dev/null | grep -c 'type AP')\" -ge 2 ]"
defchk gui_80     "netstat -tln 2>/dev/null | grep -q ':80 .*LISTEN'"
defchk ssh_22     "netstat -tln 2>/dev/null | grep -q ':22 .*LISTEN'"
defchk lan_ip     "ip -4 addr show br-lan 2>/dev/null | grep -q inet"

# state tracking (prevent log spam: only log on state TRANSITION)
STATE_FILE=/tmp/watchdog_state
touch $STATE_FILE 2>/dev/null

run_cycle() {
    FAIL_NOW=0
    for pair in $CHK; do
        NAME=${pair%%:*}
        CMD=${pair#*:}
        PREV=$(grep "^$NAME=" $STATE_FILE 2>/dev/null | cut -d= -f2)
        if eval "$CMD" >/dev/null 2>&1; then
            NOW=0
        else
            NOW=1
            FAIL_NOW=$((FAIL_NOW+1))
        fi
        if [ "$NOW" != "$PREV" ]; then
            if [ "$NOW" = 1 ]; then
                log "FAIL  $NAME (was ok)"
            else
                log "OK    $NAME (recovered)"
            fi
            sed -i "s/^$NAME=.*/$NAME=$NOW/" $STATE_FILE 2>/dev/null
            grep -q "^$NAME=" $STATE_FILE 2>/dev/null || echo "$NAME=$NOW" >> $STATE_FILE
        fi
    done

    # 信标错误事件检测 (增量)
    BCN=$(dmesg | grep -cE 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
    BCN_PREV=$(grep '^beacon=' $STATE_FILE 2>/dev/null | cut -d= -f2)
    if [ -n "$BCN_PREV" ] && [ "$BCN" -gt "$BCN_PREV" ] 2>/dev/null; then
        log "WARN  beacon events +$((BCN-BCN_PREV)) (total=$BCN)"
    fi
    sed -i "s/^beacon=.*/beacon=$BCN/" $STATE_FILE 2>/dev/null
    grep -q '^beacon=' $STATE_FILE 2>/dev/null || echo "beacon=$BCN" >> $STATE_FILE

    # 5G 探活 (非旁路模式才查)
    if [ "$(cat /tmp/wan_mode 2>/dev/null)" != "off" ]; then
        if ! ping -4 -I ccmni2 -c1 -W3 -s1 223.5.5.5 >/dev/null 2>&1; then
            5G_FAIL=$((5G_FAIL+1))
        else
            5G_FAIL=0
        fi
        if [ "$5G_FAIL" -ge 3 ]; then
            log "WARN  5G probe dead x$5G_FAIL"
            5G_FAIL=3  # cap
        fi
    fi

    # 视觉指示: 有失败 -> WAN LED 闪烁 (led_mgr 会覆盖, 短暂闪烁即够)
    if [ "$FAIL_NOW" -gt 0 ]; then
        # 3 快闪
        for i in 1 2 3; do
            echo 1 > $LED_WAN 2>/dev/null; sleep 0.1
            echo 0 > $LED_WAN 2>/dev/null; sleep 0.1
        done
    fi

    # 日志截断
    LINES=$(wc -l < $LOG 2>/dev/null || echo 0)
    if [ "$LINES" -gt "$MAX_LOG" ]; then
        tail -n $((MAX_LOG/2)) $LOG > $LOG.tmp 2>/dev/null && mv $LOG.tmp $LOG
    fi
}

# --- main loop ---
log "===== watchdog v1.0 start ====="
# 初始化状态 (首次全部标 ok, 不发初始告警)
for pair in $CHK; do
    NAME=${pair%%:*}
    echo "$NAME=0" >> $STATE_FILE 2>/dev/null
done
echo "beacon=0" >> $STATE_FILE
5G_FAIL=0

while :; do
    run_cycle
    sleep $CYCLE
done
