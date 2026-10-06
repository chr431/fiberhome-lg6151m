#!/bin/sh
# watchdog.sh v1.2 -- on-device continuous invariant monitor.
# L13: "feature silently broken until manual inspection" countermeasure.
# Runs every 30s; failures log + WAN LED flash; recovers silently.
# Started by rc19.sh (pgrep guard); single instance.
# v1.2 (L14): +cellular control plane -- atcid 自愈, AT 通道(CFUN/CSQ),
#       模组注册态。第一阶段裁剪曾杀 atcid 而 3 天无人知晓 (数据面测试全绿)。

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
    # v1.4: 模式无关 — weight 模式有 sport 分界, 优先/仅模式为单路 MARK 规则
    check agg_rules "iptables -t mangle -S WANAGG 2>/dev/null | grep -q MARK" "split rules installed"
    check fwmark    "ip rule | grep -q fwmark"       "fwmark policy routing"
    check nat       "iptables -t nat -S POSTROUTING | grep -q MASQ"  "NAT masquerade"
    check bss       "[ \$(iw dev 2>/dev/null | grep -c 'type AP') -ge 2 ]"  "2+ BSS active"
    check port80    "netstat -tln 2>/dev/null | grep -q ':80.*LISTEN'"  "GUI :80 reachable"
    check port22    "netstat -tln 2>/dev/null | grep -q ':22.*LISTEN'"  "SSH :22 reachable"
    check boot      "[ -f /tmp/boot.done ]"          "boot chain complete"
    check lan_ip    "ip -4 addr show br-lan | grep -q inet"  "LAN IP present"

    # ---- cellular control plane (L14) ----
    # dial_keeper: 拨号兜底守护 (P2); 死则带环境拉起
    if pgrep -f dial_keeper.sh >/dev/null 2>&1; then
        set_state keeper 0 "dial keeper"
    else
        set_state keeper 1 "dial keeper"
        FAILS=$((FAILS+1))
        export LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin:/fhrom/bin:/fhrom/fhshell
        nohup sh /data/gw/dial_keeper.sh >/dev/null 2>&1 &
    fi
    # atcid: AT 通道本体; 死则拉起 (替代厂商 procd respawn)
    if pidof atcid >/dev/null 2>&1; then
        set_state atcid 0 "atcid daemon"
    else
        set_state atcid 1 "atcid daemon"
        FAILS=$((FAILS+1))
        /usr/bin/atcid >/var/atcid.log 2>&1 &
    fi
    # CFUN 探测同时充当通道活性探针; airplane(CFUN:4)时跳过注册态断言
    CFUNR=$(mipc_wan_cli --at_cmd 'AT+CFUN?' 2>/dev/null)
    case "$CFUNR" in
    *"CFUN: 4"*)
        set_state at_chan 0 "AT channel (airplane, probe-only)"
        set_state modem_reg 0 "modem registered (airplane, skipped)"
        ;;
    *"CFUN: "*)
        set_state at_chan 0 "AT channel (CFUN responds)"
        # 注册态: +COPS: <mode>,<fmt>,"<numeric>"  -- 含引号即已注册
        COPSR=$(mipc_wan_cli --at_cmd 'AT+COPS?' 2>/dev/null)
        case "$COPSR" in
        *'"'*) set_state modem_reg 0 "modem registered" ;;
        *)     set_state modem_reg 1 "modem NOT registered"
               FAILS=$((FAILS+1)) ;;
        esac
        ;;
    *)  # 连 CFUN 都不回 = 通道死
        set_state at_chan 1 "AT channel DEAD (no CFUN response)"
        FAILS=$((FAILS+1))
        set_state modem_reg 1 "modem state unknown (AT dead)"
        FAILS=$((FAILS+1))
        ;;
    esac

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
log "===== watchdog v1.2 start ====="
# initialize state to current (suppress initial alarms)
run_cycle  # first run logs transitions but that's fine
while :; do
    sleep $CYCLE
    run_cycle
done
