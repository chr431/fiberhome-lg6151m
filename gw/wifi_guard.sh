#!/bin/sh
# wifi_guard.sh v1.4 — BA-stall auto-recovery + telemetry for the wifi TX quirk.
# v1.4: 每轮重写自己的锁(启动竞态残留自愈).
# v1.3: stations/txbacklog 探针经静态 timeout(卡死不再拖住守卫循环).
#
# v1.2 (2026-10-20 stability P1-4): the old trigger counted *episode
#   increments*: one continuous stall (episodes fixed at 1) could never reach
#   3 strikes, while three separate idle blips bounced the radio within 45s.
#   Field data: 520 episodes / 11 bounces in one boot, every bounce dropping
#   every client.  New rule:
#     * recovery needs 4 consecutive stall samples (15s each = 60s confirmed);
#     * preconditions: >=1 associated station, no wifi_up/hostapd recovery
#       running; the qdisc backlog is recorded as evidence;
#     * at most 2 bounces per rolling hour and 10 per boot, always logged with
#       the affected client count; otherwise alert-only;
#     * single-instance lock + /tmp/wifi_guard.hb heartbeat for the watchdog
#       supervision table.
#
# Mechanism (2026-10-01): after bridge churn, unicast TCP/UDP to a wifi client
# dies while ICMP flows (SYN-ACKs queued at dev level, never on air; wed_task1
# permanently D-state). Kernel-side detection: v3_steth.ko flags TX-stall
# episodes (rx advancing + tx frozen + iface running) in /proc/v3_steth.
# This guard polls that flag (with a userspace heuristic fallback when the
# module is absent) and performs the PROVEN recovery: bounce rai0. All actions
# timestamped to /tmp/wifi_guard.log — evidence, not guessing.
LOG=/tmp/wifi_guard.log
glog() { echo "$(date -u +%FT%TZ) $*" >> $LOG; }
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=

# single instance (watchdog may restart us)
_lp=$(cat /tmp/wifi_guard.lock 2>/dev/null)
if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && kill -0 "$_lp" 2>/dev/null && \
   grep -qa '/data/gw/wifi_guard.sh' /proc/$_lp/cmdline 2>/dev/null; then
    echo "wifi_guard: already running pid=$_lp" >&2
    exit 0
fi
echo $$ > /tmp/wifi_guard.lock

STREAK=0
LAST_EP=0
BOUNCED=0
BOUNCE_TIMES=""
STALL_RUN=0
glog "wifi_guard v1.2 start (pid $$)"

# v1.3: probes bounded — a wedged vendor iw/tc must not stall the guard loop
stations() {
    if [ -n "$BB" ]; then
        "$BB" timeout -s KILL 5 iw dev rai0 station dump 2>/dev/null | grep -c '^Station'
    else
        iw dev rai0 station dump 2>/dev/null | grep -c '^Station'
    fi
}
txbacklog() { # bytes queued on rai0 (qdisc backlog, evidence only)
    if [ -n "$BB" ]; then
        "$BB" timeout -s KILL 5 tc -s qdisc show dev rai0 2>/dev/null
    else
        tc -s qdisc show dev rai0 2>/dev/null
    fi | sed -n 's/.*backlog \([0-9]*\).*/\1/p' | head -1
}

while true; do
    sleep 15
    cut -d. -f1 /proc/uptime > /tmp/wifi_guard.hb 2>/dev/null
    echo $$ > /tmp/wifi_guard.lock 2>/dev/null   # v1.4: owner re-asserts the lock

    # ---- primary signal: kernel stethoscope ----
    STALL=0; EP=0
    if [ -r /proc/v3_steth ]; then
        line=$(grep 'if rai0' /proc/v3_steth 2>/dev/null)
        STALL=$(echo "$line" | sed -n 's/.*stall=\([0-9]*\).*/\1/p')
        EP=$(echo "$line"   | sed -n 's/.*episodes=\([0-9]*\).*/\1/p')
        [ -z "$STALL" ] && STALL=0
        [ -z "$EP" ] && EP=0
    fi

    # ---- telemetry every ~5min: wed_task1 D-state + counters ----
    if [ $(( $(date -u +%s) % 300 )) -lt 16 ]; then
        WED=$(grep -c "wed_task1" /proc/[0-9]*/comm 2>/dev/null | grep -c ":1")
        glog "tick stall=$STALL streak=$STREAK episodes=$EP stations=$(stations) txbacklog=$(txbacklog) wed_task1_procs=$WED $(grep 'if ra' /proc/v3_steth 2>/dev/null | tr '\n' ' ')"
    fi

    # ---- episode transition is telemetry only (never a recovery trigger) --
    if [ "$EP" -gt "$LAST_EP" ]; then
        glog "STALL EPISODE #$EP: $(grep 'if rai0' /proc/v3_steth)"
        LAST_EP=$EP
    fi

    # ---- consecutive-sample confirmation (P1-4) ----
    if [ "$STALL" = "1" ]; then
        STREAK=$((STREAK + 1)); STALL_RUN=$((STALL_RUN + 1))
    else
        STREAK=0
        [ "$STALL_RUN" -gt 0 ] && glog "stall ended after ${STALL_RUN} sample(s)"
        STALL_RUN=0
    fi

    [ "$STREAK" -lt 4 ] && continue

    # ---- preconditions: clients, backlog, no competing radio work ----
    CLI=$(stations)
    BL=$(txbacklog)
    case "$BL" in ''|*[!0-9]*) BL=0 ;; esac
    if [ "${CLI:-0}" -lt 1 ]; then
        glog "CONFIRMED stall (${STREAK} samples) but 0 stations — idle false positive, no action"
        STREAK=0
        continue
    fi
    if pgrep -f 'wifi_up[.]sh' >/dev/null 2>&1; then
        glog "CONFIRMED stall but wifi_up in progress — defer"
        STREAK=0
        continue
    fi
    if grep -q 'recover hostapd' /tmp/watchdog.log 2>/dev/null; then
        _mlog=$(stat -c %Y /tmp/watchdog.log 2>/dev/null || echo 0)
        if [ $(( $(date +%s) - _mlog )) -lt 120 ]; then
            glog "CONFIRMED stall but recent hostapd recovery — defer"
            STREAK=0
            continue
        fi
    fi

    # ---- rate limit: 2/rolling hour, 10 per boot ----
    NOW=$(date +%s)
    _keep=""; _n=0
    for _t in $BOUNCE_TIMES; do
        [ $((NOW - _t)) -lt 3600 ] && { _keep="$_keep $_t"; _n=$((_n + 1)); }
    done
    BOUNCE_TIMES=$_keep
    if [ "$_n" -ge 2 ] || [ "$BOUNCED" -ge 10 ]; then
        glog "CONFIRMED stall (${STREAK} samples, stations=$CLI backlog=$BL) but bounce budget exhausted (hour=$_n boot=$BOUNCED) — alert only"
        STREAK=0
        continue
    fi

    glog "RECOVERY: bouncing rai0 (samples=$STREAK stations=$CLI backlog=$BL ep=$EP boot_bounces=$BOUNCED)"
    ifconfig rai0 down 2>>$LOG
    sleep 2
    ifconfig rai0 up 2>>$LOG
    brctl addif br-lan rai0 2>>$LOG
    BOUNCED=$((BOUNCED + 1))
    BOUNCE_TIMES="$BOUNCE_TIMES $NOW"
    STREAK=0
    glog "RECOVERY done (boot_bounces=$BOUNCED) — $CLI client(s) must re-associate"
done
