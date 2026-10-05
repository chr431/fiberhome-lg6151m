#!/bin/sh
# rc_netfh.sh v1.7 -- route A: FH modem-stack environment (minimal army).
# Mission: give the 5G dialer its full stock environment so the modem builds
# the IA bearer, WITHOUT the daemons that fight our v3 flight layer.
# KEEP   (process_start_list order): cfgmgr, logmgr, mobilenetwork
#        (rc.d order): mtk_netagent(S22) < ql_netd+ql_ril_service(S85) < mipc_submonitor(S99)
#        (ccci_fsd/mdinit/rpcd_com already run in v3's partial rcS -- verified)
# EXCLUDE (troublemakers): secmgr(firewall reloads) eventmgr protocolmgr
#        wancc(WAN state fights) lancc(ifconfig-down port flapping!) wifimgr
#        (fights wifi_up.sh) auto_adapt(E1 deadlock root) process_check
#        (respawn chaos) web trafficmgr adaptmgr iotagtd peripheral link_detection
# Mode gate: /data/gw/MODE.fh (removed = plain frankenstein mode)
LOG=/tmp/rc_netfh.log
glog() { echo "$(date -u +%FT%TZ) $*" >> $LOG; }
# v1.1: FH binaries+libs live outside the default PATH/loader path
export PATH=$PATH:/fhrom/bin:/fhrom/fhshell
export LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib
glog "===== rc_netfh v1.7 start ====="

# 1. config base (mobilenetwork's declared deps)
# v1.8: cfg_tool 先建 16MB cfgmgr shm(webs/树/信号上报的根, key=0x7539);
#       无此段则 cfgmgr 降级运行, RadioSignalParameter 恒空
if ! awk 'NR>1 && $3==16777216' /proc/sysvipc/shm 2>/dev/null | grep -q .; then
    LD_LIBRARY_PATH=/lib:/fhrom/lib /fhrom/bin/cfg_tool /fhrom/fhconf/param.pdt.enc >/dev/null 2>&1
    glog "cfg_tool shm built"
    # v1.9: 树快照整体恢复(锁频段/锁小区等全部树状态; 127KB gzip)
    if [ -s /data/gw/cfgtree.snap.gz ]; then
        gunzip -c /data/gw/cfgtree.snap.gz > /tmp/cfgtree.snap 2>/dev/null &&             /data/gw/shmsnap load /tmp/cfgtree.snap >/dev/null 2>&1 &&             glog "cfgtree snapshot restored" && rm -f /tmp/cfgtree.snap
    fi
fi
pidof cfgmgr >/dev/null || { /fhrom/bin/cfgmgr >/dev/null 2>&1 & sleep 2; }
pidof logmgr >/dev/null || { /fhrom/bin/logmgr -syslog /fhconf/message_syslog >/dev/null 2>&1 & sleep 2; }
glog "cfgmgr=$(pidof cfgmgr) logmgr=$(pidof logmgr)"

# 2. net plumbing, fresh MIPC sessions, stock order
[ "$(cat /sys/kernel/ccci/boot 2>/dev/null | head -c 5)" = "md1:4" ] || glog "WARN cci=$(cat /sys/kernel/ccci/boot 2>/dev/null)"
# v1.7 (L14): atci 对复活 -- 第一阶段裁剪误伤 S96atci_service/S96atcid 后
#       mipc_wan_cli --at_cmd 全灭 (SMS读/CSQ/锁下发通道), 数据面正常故
#       selftest 3 天未察觉。atcid 是 AT 通道本体, atci_service 为厂商伴生
#       (一并拉起保持原厂形态)。必须在 mobilenetwork 前就绪。
pidof atcid >/dev/null || { /usr/bin/atci_service >/dev/null 2>&1 & sleep 1; /usr/bin/atcid >/var/atcid.log 2>&1 & sleep 1; }
glog "atcid=$(pidof atcid) at_ch=$(mipc_wan_cli --at_cmd 'AT+CSQ' 2>/dev/null | grep -c '+CSQ:')"
kill $(pidof mtk_netagent ql_netd ql_ril_service mipc_submonitor) 2>/dev/null
sleep 2
/usr/bin/mtk_netagent >/dev/null 2>&1 &
sleep 2
/usr/bin/ql_netd        >/dev/null 2>&1 &
/usr/bin/ql_ril_service >/dev/null 2>&1 &
sleep 4
/usr/bin/mipc_submonitor >/dev/null 2>&1 &
sleep 2
glog "plumbing netagent=$(pidof mtk_netagent) ql_netd=$(pidof ql_netd) ril=$(pidof ql_ril_service) submon=$(pidof mipc_submonitor)"

# 3. THE stock dialer (army spawn form, taskset like process_start_list)
pidof mobilenetwork >/dev/null || taskset -c 0,2 /fhrom/bin/mobilenetwork >/tmp/mn_boot.log 2>&1 &
# v2.2 (P2): 拨号自持兜底 — mobilenetwork 死亡后 35s 内由本守护接管重拨
pgrep -f dial_keeper.sh >/dev/null || nohup sh /data/gw/dial_keeper.sh >/dev/null 2>&1 &
# v1.8: mobilenetwork 就绪后重放蜂窝锁定(频段/小区)
( sleep 20; sh /data/gw/cellular_replay.sh ) >/dev/null 2>&1 &
sleep 10
glog "mobilenetwork=$(pidof mobilenetwork) mn_boot=$(wc -c </tmp/mn_boot.log 2>/dev/null || echo 0)B"
glog "ubus ql-netd=$(ubus list 2>/dev/null | grep -c '^ql-netd$') ril=$(ubus list 2>/dev/null | grep -c '^ril$')"

# 4. settle watch: does the stock dial produce an IP + rx?
i=0
while [ $i -lt 12 ]; do
    sleep 10
    IP=$(ip -o addr show 2>/dev/null | grep 'ccmni' | grep 'inet ' | head -1)
    [ -n "$IP" ] && break
    i=$((i+1))
done
glog "ccmni ip: ${IP:-none after 120s}"
IF=$(echo "$IP" | awk '{print $2}')
if [ -n "$IF" ]; then
    # v1.2: stock's netagent didn't add the v4 default route in our env -- the
    # ONE thing we add ourselves. Verified live 2026-10-03: route+NAT =>
    # PC->br-lan->NAT->ccmni1->5G->internet (traceroute hop1=192.168.9.1, 0% loss).
    ip route show default | grep -q "dev $IF" || ip route add default dev $IF
    iptables -t nat -C POSTROUTING -s 192.168.9.0/24 -o $IF -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s 192.168.9.0/24 -o $IF -j MASQUERADE
    iptables -C FORWARD -i br-lan -o $IF -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i br-lan -o $IF -j ACCEPT
    iptables -C FORWARD -i $IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i $IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
    glog "route+nat on $IF ok"

    # v1.4: IPv6 LAN -- cellular WAN is /128 (no PD delegated), so real routing
    # is impossible; ULA + NAT66 + radvd SLAAC instead. dnsmasq (rc19) already
    # serves DNS on :::53 = the RDNSS address below. Verified live 2026-10-03:
    # PC SLAAC addr in 5s, ping6 21ms 0% loss, v6 HTTPS 200/128ms.
    # v1.5: forwarding 重启丢失回归修复(手动设置不跨重启, 2026-10-04 排查家宽v6时发现)
    sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null 2>&1
    # v1.5: 家宽口接受 RA(forwarding=1 下需 accept_ra=2; 不取默认路由护 NAT66 出向)
    sysctl -w net.ipv6.conf.eth0.accept_ra=2 >/dev/null 2>&1
    # v1.6: 家宽RA默认路由做热备(metric 2048<ccmni的1024, 5G v6死自动顶上)
    # 实测强绑ULA验证: 杀ccmni默认后LAN v6经eth0 NAT66无感切换(2026-10-05)
    sysctl -w net.ipv6.conf.eth0.accept_ra_defrtr=1 >/dev/null 2>&1
    sysctl -w net.ipv6.conf.eth0.ra_defrtr_metric=2048 >/dev/null 2>&1
    # v1.6: LAN v6 经 WAN(eth0) 出口的 NAT66 + 转发(夜间v4断网场景刚需)
    ip6tables -t nat -C POSTROUTING -s fd42:9ac1:7e50::/64 -o eth0 -j MASQUERADE 2>/dev/null ||         ip6tables -t nat -A POSTROUTING -s fd42:9ac1:7e50::/64 -o eth0 -j MASQUERADE
    ip6tables -C FORWARD -i br-lan -o eth0 -j ACCEPT 2>/dev/null ||         ip6tables -I FORWARD -i br-lan -o eth0 -j ACCEPT
    ip6tables -C FORWARD -i eth0 -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||         ip6tables -I FORWARD -i eth0 -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
    if ip -6 addr show $IF 2>/dev/null | grep -q 'scope global'; then
        # rc19 builds br-lan at ~t+50s; settle-watch usually outlasts it, but
        # guard the race anyway (bounded poll, no blind sleep)
        [ -d /sys/class/net/br-lan ] || { j=0; while [ $j -lt 12 ] && [ ! -d /sys/class/net/br-lan ]; do sleep 5; j=$((j+1)); done; }
        ip -6 addr add fd42:9ac1:7e50::1/64 dev br-lan 2>/dev/null
        # netagent RA-learns the v6 default route, but re-assert idempotently
        ip -6 route show default | grep -q "dev $IF" || ip -6 route add default dev $IF
        ip6tables -t nat -C POSTROUTING -s fd42:9ac1:7e50::/64 -o $IF -j MASQUERADE 2>/dev/null || \
            ip6tables -t nat -A POSTROUTING -s fd42:9ac1:7e50::/64 -o $IF -j MASQUERADE
        ip6tables -C FORWARD -i br-lan -o $IF -j ACCEPT 2>/dev/null || \
            ip6tables -I FORWARD -i br-lan -o $IF -j ACCEPT
        ip6tables -C FORWARD -i $IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            ip6tables -I FORWARD -i $IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
        pidof radvd >/dev/null || /fhrom/bin/radvd -C /data/gw/radvd.conf -p /tmp/radvd.pid -m logfile -l /tmp/radvd.log
        glog "v6: ula+nat66+radvd=$(pidof radvd) on $IF"
    else
        glog "v6: no global v6 on $IF (bearer v4-only?) -- LAN v6 skipped"
    fi

    R1=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
    sleep 10
    R2=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
    glog "bearer probe $IF rx=$R1->$R2"
    # bearer health: FH's own criterion (60s tx>10 && rx==0 => dead PDN) --
    # on failure run stock's tier-2 ladder once (EGREA re-attach) and re-probe
    TX=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null)
    if [ "$R2" = "0" ] && [ "${TX:-0}" -gt 10 ]; then
        glog "PDN dead (tx=$TX rx=0) -- stock tier-2 ladder"
        for at in AT+EGREA=1 AT+EGTYPE=0,1 AT+EGREA=0 AT+EGTYPE=4; do
            mipc_wan_cli --at_cmd "$at" >/dev/null 2>&1; sleep 2
        done
        sleep 20
        R3=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null)
        glog "post-ladder rx=$R3"
    fi
fi
sh /data/gw/fw_apply.sh apply 2>/dev/null && glog "fw_apply ok" ; glog "===== rc_netfh v1.4 done ====="
