#!/bin/sh
# dial_5g.sh — production 5G dialer for v3 (recipe proven live 2026-10-02).
#
# History in one line: manual mipc dials failed with result 2 for hours; a
# set -x direct-run of the stock mipc proto revealed the three secrets —
#   1. the winning act JSON differs from every guess: apn_type=1 mode=1
#      bearer_bitmask="0xfffdffff" (from check_ia's real args, rattype=21)
#   2. check_ia must run FIRST with its true 9-arg form
#   3. the proto hard-blocks on `ubus call service list | grep mtk_netagent`
#      (procd's service object never registers in our hand-started ubusd)
#      -> patch the gate out of a tmpfs working copy and drive that.
#
# Post-dial plumbing: IP already applied by the proto; we add default route,
# NAT for the LAN subnet, and reload v3_fix TTL masquerade on the data iface.
# Idempotent: re-running deacts+acts fresh. Log: /tmp/dial_5g.log
LOG=/tmp/dial_5g.log
LAN_NET=192.168.9.0/24
KLOG() { echo "DIAL5G: $*" > /dev/kmsg 2>/dev/null; }

glog() { echo "$(date -u +%FT%TZ) $*" >> $LOG; }

# --- 0. ubus bootstrap (nothing starts ubusd in the Frankenstein boot; the
#        ql daemons registered nothing without it -> every dial returns -1) ---
if ! pidof ubusd >/dev/null; then
    mkdir -p /var/run
    /sbin/ubusd >/dev/null 2>&1 &
    sleep 2
    # re-register the MIPC providers (they predate ubusd, never connected)
    kill $(pidof ql_netd ql_ril_service logd) 2>/dev/null
    sleep 1
    /sbin/logd -S 10240 >/dev/null 2>&1 &
    /usr/bin/ql_ril_service >/dev/null 2>&1 &
    /usr/bin/ql_netd >/dev/null 2>&1 &
    sleep 4
    glog "ubusd bootstrapped + ql daemons re-registered"
fi

work=/tmp/protowrap/mipc.dial.sh
mkdir -p /tmp/protowrap

# --- 1. build patched proto copy (gate -> pidof check; intent-equivalent) ---
cp /lib/netifd/proto/mipc.sh "$work" || { glog "FATAL: no pristine mipc.sh"; exit 1; }
sed -i 's#ubus call service list | grep mtk_netagent#pidof mtk_netagent#' "$work"

# --- 2. drive it with netifd's exact argv (from the successful trace) ---
CFG='{"device":"ccmni","proto":"mipc","apn":"cbnet","iptype":3,"roamingtype":3,"mtu":1400,"plmn":"460015","sim":1,"mtu":1400}'
rm -f /tmp/5g_dial_trace.log
cd /lib/netifd/proto
sh -x "$work" mipc setup wan "$CFG" >/tmp/5g_dial_out.log 2>/tmp/5g_dial_trace.log
rc=$?
grep -q "Connect OK" /tmp/5g_dial_out.log 2>/dev/null && ok=1 || ok=0
glog "dial rc=$rc ok=$ok"
[ $ok -eq 1 ] || { tail -5 /tmp/5g_dial_out.log >> $LOG; KLOG "dial FAILED rc=$rc"; exit 2; }

# --- 3. extract iface + gw (result JSON lands in the XTRACE stream, not
#        stdout — 2026-10-02 lesson: parsing stdout yielded empty gw and a
#        stale iface; also fall back to detecting the IP-bearing ccmni) ---
IF=$(sed -n 's/.*"ifname": "\([^"]*\)".*/\1/p' /tmp/5g_dial_trace.log | tail -1)
GW=$(sed -n 's/.*"v4_gw": "\([^"]*\)".*/\1/p' /tmp/5g_dial_trace.log | tail -1)
if [ -z "$IF" ] || ! ip -o addr show "$IF" 2>/dev/null | grep -q "inet "; then
    IF=$(ip -o addr show 2>/dev/null | grep "ccmni" | grep "inet " | head -1 | sed 's/:.*//;s/^[0-9]*: //;s/ .*//')
fi
[ -z "$GW" ] && GW=""
glog "iface=$IF gw=$GW"

# --- 3b. bearer sanity: a result-0 dial can still be dead (2026-10-02 night:
#         CEREG 0,0 attach-refused while MIPC returns success). Verify, don't hope.
if [ -n "$IF" ]; then
    BRX1=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null || echo 0)
    if ping -c 2 -W 3 -I $IF 43.239.172.1 >/dev/null 2>&1; then
        glog "bearer VERIFIED (carrier DNS answers)"
    else
        sleep 8
        ping -c 2 -W 3 -I $IF 43.239.172.1 >/dev/null 2>&1 || \
            glog "WARN: bearer DEAD after dial (attach refused? check AT+CEREG?)"
    fi
fi
KLOG "5G UP on $IF via $GW"

# --- 4. routes + NAT + TTL masquerade ---
if [ -n "$GW" ]; then
    ip route replace default via $GW dev $IF metric 50
else
    ip route replace default dev $IF metric 50
fi
iptables -t nat -C POSTROUTING -s $LAN_NET -o $IF -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s $LAN_NET -o $IF -j MASQUERADE
# TTL masquerade follows the live data iface (was hardcoded ccmni2-era)
rmmod v3_fix 2>/dev/null
insmod /data/gw/v3_fix.ko wan_if=$IF ttl_mode=1 unhook=1
glog "route+NAT+TTL done on $IF"
KLOG "5G stack complete on $IF"
exit 0
