#!/bin/sh
# v2_access v6.0 -- MINIMAL fallback (2026-10-03 subtraction mandate): v2 =
#   stock FH firmware running natively (its own WiFi/5G/web all intact) PLUS a
#   pure ACCESS layer. Zero management-rights contention with FH daemons.
#   Subtracted vs v5.4: E6 br0-enforce (misdiagnosis artifact; stock configures
#   br0=8.1 fine), E7 arp-sysctl zeroing (user's call, RE-proven: stock values
#   work -- bridge local-delivery lands on br0 which owns the IP), telnetd,
#   guard's port-23/arp duties. Kept: iptables 22, dropbear, DHCP(E8, approved),
#   consfeed serial, quieting+sysrq, log rotation, evidence logging.
#   Lineage: v1 keygen / v2 keycopy-miss / v3 massacre / v4 kill-only+setsid-miss
#   / v4.1 poll / v5.0-5.2 no-kill+fw+coexist+br0 / v5.3 guard+rotation+sysrq
#   / v5.4 +E7+E8 / v6.0 subtraction.
# Evidence-driven rewrite (raw-shell forensic pass 2026-10-02, lk_diag_v2b):
#   E1 dropbear -r /data/gw/dropbear/rsa listens EVERY boot (p22=2 in every
#      v2access.log section; keys were generated fine back in the v1 era).
#   E2 PC still sees port 22 CLOSED -> FH iptables REJECTs 22 from LAN
#      (README-era finding: vendor chain REJECTs port 22 until a LAN accept
#      is inserted). FIX: iptables -I INPUT 1 ACCEPT for br0/eth0, 22+23.
#   E3 busybox has NO setsid -> v3/v4 sole-shell never spawned (log: "setsid:
#      not found" line 75/76). FIX: plain backgrounded sh -i, no setsid.
#   E4 killing console holders is an unwinnable respawn war: login.sh pid
#      7659 -> reborn as 8948 seconds later; daemon army fds re-opened too.
#      FIX: kill NOTHING. login.sh never reads input (sleeps in loop), so a
#      coexisting reader gets every keystroke (v1-era consfeed proved this).
#   E5 telnetd binary exists but -p is unsupported (bound default 23).
# Lineage: v1 keygen+dropbear / v2 259:7 keycopy(miss) / v3 kill-all(massacre)
#          / v4 kill-login.sh-only(+setsid-miss) / v4.1 poll / v5.0-5.2 no-kill+fw+coexist+br0
#          / v5.3 fallback hardening: access_guard supervision + log rotation
#            + sysrq levers restored (mask was 1 = loglevel-only; sysrq-b was dead)
# Everything logs to /data/gw/v2access.log (persists across reboots).
LOG=/data/gw/v2access.log
# log rotation guard: the v5.0 consfeed crash-loop once spammed this file;
# keep the last 2000 lines if it ever exceeds 100KB (before appending)
SZ=$(wc -c < $LOG 2>/dev/null || echo 0)
[ "$SZ" -gt 100000 ] && { tail -2000 $LOG > $LOG.trunc && mv $LOG.trunc $LOG; }
exec >>$LOG 2>&1
echo "===== v2_access v6.0 start $(date -u +%FT%TZ) ====="

# settle poll (max 180s): login.sh is among the last FH spawns; once present
# the army is up and we can act. No blind sleeps (discipline R4).
i=0
while [ $i -lt 90 ] && [ -z "$(pidof login.sh)" ]; do sleep 2; i=$((i+1)); done
echo "login.sh after $((i*2))s: $(pidof login.sh)"

# 1) console quieting WITHOUT killing the emergency levers: dmesg -n 1 stops
#    kernel spam; sysrq mask -> 1 (ALL enabled) restores sysrq-b/sync etc.
#    (v5.2-era field value was mask=1 loglevel-only: sysrq-b was DEAD.)
dmesg -n 1 2>/dev/null
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo "printk=$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null) sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)"

# 2) THE reachability fix (E2): vendor chain REJECTs 22/23 from LAN
echo "-- iptables INPUT before:"
iptables -L INPUT -n --line-numbers
for IF in br0 eth0; do
    for PORT in 22; do
        iptables -C INPUT -i $IF -p tcp --dport $PORT -j ACCEPT 2>/dev/null || \
            iptables -I INPUT 1 -i $IF -p tcp --dport $PORT -j ACCEPT
    done
done
echo "-- iptables INPUT after:"
iptables -L INPUT -n --line-numbers

echo "-- LAN: $(ip -o addr show br0 2>/dev/null | head -1)"



# 2d) E8 (v5.4): plug-and-play LAN. No DHCP server was serving br0 (udhcpd
#     dead; stock dnsmasq runs DNS-only) -> connecting a PC required manual
#     static IP. Serve DHCP on br0 ourselves (port=0: no DNS, avoids clashing
#     with the stock dnsmasq; same pattern as v3's rc19).
if ! netstat -lun 2>/dev/null | grep -q ':67 '; then
    dnsmasq --port=0 -i br0 -I lo \
        -F 192.168.8.100,192.168.8.200,255.255.255.0,12h \
        --dhcp-option=3,192.168.8.1 --dhcp-option=6,192.168.8.1 \
        -x /var/run/dnsmasq_gw.pid 2>/dev/null
    echo "dhcp: dnsmasq_gw pid=$(cat /var/run/dnsmasq_gw.pid 2>/dev/null)"
else
    echo "dhcp: port 67 already served"
fi

# 3) dropbear with /data keys (E1: proven listening every boot)
DK=/data/gw/dropbear
mkdir -p $DK
if [ -f $DK/rsa ]; then
    pgrep dropbear >/dev/null || /usr/sbin/dropbear -r $DK/rsa
    sleep 1
    echo "dropbear: pid=$(pidof dropbear) p22=$(netstat -ltn 2>/dev/null | grep -c ':22 ')"
else
    echo "dropbear: NO KEY at $DK/rsa"
    if [ -x /usr/bin/dropbearkey ]; then
        /usr/bin/dropbearkey -t rsa -f $DK/rsa -s 2048 && /usr/sbin/dropbear -r $DK/rsa
        echo "dropbear: keygen+start rc=$?"
    fi
fi

# 5) console reader WITHOUT setsid (E3/E4): consfeed wrapper respawns the
#    interactive shell if it ever exits; coexists with the sleeping login.sh.
# consfeed.sh comes from the deploy MANIFEST (repo truth). v5.0's [ ! -f ]
# guard skipped overwriting the v1-era file -> setsid crash-loop spammed the
# log. Never create it here; only spawn. stderr -> its own file, not this log.
if [ -f /data/gw/consfeed.sh ]; then
    ps | grep consfeed.sh | grep -v grep >/dev/null || /data/gw/consfeed.sh >/dev/null 2>/tmp/consfeed.err &
    sleep 2
    echo "consfeed: running=$(ps | grep consfeed.sh | grep -v grep | awk '{print $1}')"
else
    echo "consfeed: MISSING (deploy it: python tools/deploy.py push consfeed)"
fi

# 6) evidence snapshot: console fd holders (observation only -- E4: no kills)
#    plus: who owns port 23 (v5.1 said "telnetd not found" yet 23 listens)
echo "-- console fd holders now:"
for d in /proc/[0-9]*/fd; do
    ls -l $d 2>/dev/null | grep -q '/dev/console' || continue
    p=${d%/fd}; p=${p#/proc/}
    echo "   pid=$p comm=$(cat /proc/$p/comm 2>/dev/null)"
done
echo "-- port23 owner: $(netstat -ltnp 2>/dev/null | grep ':23 ' | head -2 | tr '\n' ' ')"

# 7) access_guard (v5.3 fallback hardening): a supervision loop that keeps
#    every channel alive against FH-side churn (firewall reloads by secmgr,
#    daemon deaths, bridge reconfiguration). Idempotent re-assert every 60s;
#    logs ONLY on repair + a 10-minute heartbeat (log stays small).
(
 _hb=0
 while true; do
    sleep 60
    _hb=$((_hb+1))
    M=""
    for PORT in 22; do
        iptables -C INPUT -i br0 -p tcp --dport $PORT -j ACCEPT 2>/dev/null || \
            { iptables -I INPUT 1 -i br0 -p tcp --dport $PORT -j ACCEPT; M="$M fw$PORT"; }
    done
    ip addr show br0 2>/dev/null | grep -q "192.168.8.1/" || \
        { ip addr add 192.168.8.1/24 dev br0 2>/dev/null; M="$M addr"; }
    pgrep dropbear >/dev/null || \
        { /usr/sbin/dropbear -r /data/gw/dropbear/rsa 2>/dev/null; M="$M dropbear"; }
    ps | grep consfeed.sh | grep -v grep >/dev/null || \
        { [ -f /data/gw/consfeed.sh ] && /data/gw/consfeed.sh >/dev/null 2>/tmp/consfeed.err & M="$M consfeed"; }
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
    if [ -n "$M" ]; then
        echo "guard $(date -u +%FT%TZ): repaired:$M"
    elif [ $((_hb % 10)) -eq 0 ]; then
        echo "guard $(date -u +%FT%TZ): alive (uptime $(cut -d. -f1 /proc/uptime)s)"
    fi
 done
) &
echo "access_guard: spawned (pid=$!)"

echo "===== v2_access v6.0 done $(date -u +%FT%TZ) ====="
