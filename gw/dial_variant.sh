#!/bin/sh
# dial_variant.sh v1.0 -- 5G dial parameter experiments (bearer-dead probe).
# Usage: dial_variant.sh <iptype> [apn] [plmn] [roamingtype]
#   e.g. sh /data/gw/dial_variant.sh 1            # pure IPv4 (phone mode)
#        sh /data/gw/dial_variant.sh 3 cbnet 460015 3
# Reuses dial_5g's proven machinery (ubus bootstrap assumed already done by
# dial_5g at boot; re-bootstrap if needed). Logs to /tmp/dial_variant.log.
IPT=${1:-3}
APN=${2:-cbnet}
PLMN=${3:-460015}
ROAM=${4:-3}
BBM=${5:-0xfffdffff}
LOG=/tmp/dial_variant.log
echo "===== dial_variant iptype=$IPT apn=$APN plmn=$PLMN roam=$ROAM bbm=$BBM $(date -u +%FT%TZ) =====" >> $LOG

# ubus bootstrap (idempotent, mirrors dial_5g)
if ! pidof ubusd >/dev/null; then
    mkdir -p /var/run
    /sbin/ubusd >/dev/null 2>&1 &
    sleep 2
    kill $(pidof ql_netd ql_ril_service logd) 2>/dev/null
    sleep 1
    /sbin/logd -S 10240 >/dev/null 2>&1 &
    /usr/bin/ql_ril_service >/dev/null 2>&1 &
    /usr/bin/ql_netd >/dev/null 2>&1 &
    sleep 4
    echo "ubus bootstrapped" >> $LOG
fi

mkdir -p /tmp/protowrap
cp /lib/netifd/proto/mipc.sh /tmp/protowrap/mipc.var.sh
sed -i 's#ubus call service list | grep mtk_netagent#pidof mtk_netagent#' /tmp/protowrap/mipc.var.sh

CFG="{\"device\":\"ccmni\",\"proto\":\"mipc\",\"apn\":\"$APN\",\"iptype\":$IPT,\"roamingtype\":$ROAM,\"mtu\":1400,\"plmn\":\"$PLMN\",\"sim\":1,\"bearer_bitmask\":\"$BBM\"}"
cd /lib/netifd/proto
sh -x /tmp/protowrap/mipc.var.sh mipc setup wan "$CFG" >/tmp/dv_out.log 2>/tmp/dv_trace.log
RC=$?
OK=$(grep -c "Connect OK" /tmp/dv_out.log 2>/dev/null)
IF=$(sed -n 's/.*"ifname": "\([^"]*\)".*/\1/p' /tmp/dv_trace.log | tail -1)
[ -z "$IF" ] && IF=$(ip -o addr show 2>/dev/null | grep ccmni | grep 'inet ' | head -1 | sed 's/:.*//;s/^[0-9]*: //;s/ .*//')
RX1=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null || echo 0)
TX1=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null || echo 0)
# wait 8s for modem chatter then re-sample
sleep 8
RX2=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null || echo 0)
GW=$(sed -n 's/.*"v4_gw": "\([^"]*\)".*/\1/p' /tmp/dv_trace.log | tail -1)
PINGGW=skip
[ -n "$GW" ] && { ping -c 3 -W 2 $GW >/dev/null 2>&1 && PINGGW=ok || PINGGW=dead; }
echo "rc=$RC ok=$OK iface=$IF gw=$GW pinggw=$PINGGW rx=$RX1->$RX2 tx=$TX1" >> $LOG
tail -2 /tmp/dv_out.log >> $LOG
echo "RESULT rc=$RC ok=$OK if=$IF gw=$GW pinggw=$PINGGW rx=$RX2"
