#!/bin/sh
# rc19.sh v2 (=local v3_rc10.extend.sh) v2.28 -- Frankenstein v3.1: br-lan world + WiFi.
# v2.28: +log_keeper 日志持久化守护接线; v2.26: 中性命名清扫(注释去私有语境词, 零功能改动)
# v2.25: 流量采样器接线(traffic_logger.sh)
# v2.22(P1): static 档案补写 /tmp/wan.gw — wan_agg 表200默认路由与 eth_prio
#   主表切换以此为 BB_GW 源, 静态形态无人写 = 表200恒空(与 wan_agg v2.19 键链
#   修复配套, "有线宽带优先"对静态上行形同虚设的第二天键)。
# v2.20(P2): dnsmasq +rebind protection; DHCP range read from settings (fix reboot drift).
# Boot: FH init loads wifi modules (mt7992 chain) + daemon subset; netifd (if it
# starts) builds br-lan per uci (lan.ipaddr=192.168.9.1 committed 2026-10-01).
# Timeline (dispatcher S98zz runs this at ~26.5s):
#   t0 (~27s):  babysitter race fix + auto_adapt neutralization (proven)
#   t0+45=72s:  rmmod FH net ko + hw_nat (flow first: fdb/forward depend order),
#               insmod healthdog+v3_fix (proven)
#   t0+50:      LAN = br-lan enforce (v2.5: eth1 in as LAN; eth0 OUT as WAN)
#   t0+55+:     WiFi via wifi_up.sh (waits for rai0, profiles, ifup, bridge,
#               netifd autonomy guard) -- validated 2026-10-01 live
#   t0+95:      dual-mode WAN (wan_policy2, with to-LAN policy fix)
# Known quirk: after bridge churn TCP/UDP to a wifi client can die while ICMP
# lives (BA/TX-agg wedge); recovery = ifconfig rai0 down/up + client reconnect.
KLOG() { echo "RC19: $*" > /dev/kmsg 2>/dev/null; }

# --- babysitter boot.done race fix (marker must mean verified-healthy)
rm -f /tmp/boot.done
( sleep 120; touch /tmp/boot.done ) &

# --- auto_adapt: embedded DHCP client -> bridge ops -> FH br deadlock
printf '#!/bin/sh\nexit 0\n' > /tmp/stub.sh
chmod +x /tmp/stub.sh
if [ -e /usr/bin/auto_adapt ]; then
    killall auto_adapt 2>/dev/null
    mount -o bind /tmp/stub.sh /usr/bin/auto_adapt 2>/dev/null
    killall auto_adapt 2>/dev/null
    KLOG "auto_adapt stubbed+double-killed"
else
    KLOG "auto_adapt not found"
fi

sleep 45

# --- v2.3: FH mode gate (route A). With /data/gw/MODE.fh present the FH
#     modem stack (rc_netfh.sh: cfgmgr/logmgr/mobilenetwork + plumbing) owns
#     dialing and modules -- keep FH net modules loaded, skip our dialer.
FHMODE=0; [ -f /data/gw/MODE.fh ] && FHMODE=1
KLOG "FHMODE=$FHMODE"

# --- remove FH net modules (flow first; fdb->forward dep order matters --
#     v1's order left fdb/forward loaded silently for 9h)
#     SKIPPED in FH mode (mobilenetwork stack may need them).
if [ $FHMODE -eq 0 ]; then
  for m in fhdrv_net_flow fhdrv_net_quecadp fhdrv_net_fdb fhdrv_net_ondemand \
           fhdrv_net_userlimit fhdrv_net_forward fhdrv_eth_hook hw_nat; do
      rmmod $m 2>/dev/null
  done
  KLOG "rmmods done"
fi

# --- our modules
insmod /data/gw/healthdog.ko forensic=1 armed=0 2>/dev/null
insmod /data/gw/v3_fix.ko wan_if=ccmni2 ttl_mode=1 unhook=1 2>/dev/null
insmod /data/gw/v3_steth.ko bias=0x08110000 interval_s=5 2>/dev/null
KLOG "mods hd=$(grep -c healthdog /proc/modules) fix=$(grep -c v3_fix /proc/modules) steth=$(grep -c v3_steth /proc/modules)"

# --- LAN: br-lan world (eth0 real bridge port; no more forward-hack)
# power-loss boot 2026-10-02 proved netifd does NOT reliably build br-lan:
# create it ourselves if absent (idempotent).
ip link show br-lan >/dev/null 2>&1 || ip link add br-lan type bridge
ip link set br-lan up 2>/dev/null
ip addr add 192.168.9.1/24 dev br-lan 2>/dev/null
# v2.5 (2026-10-03): role swap per case silkscreen -- eth0 (丝印 LAN1/WAN 口)
#     = WAN role for wan_policy2; eth1 (2.5G-designed PHY) = LAN bridge member.
#     Legacy (<=v2.4): eth0 was LAN, eth1 was the (never-carriered) WAN probe.
# v2.6: eth1 MAC pinning -- root cause found: NOT a driver bug; legacy
#     restore_wan.sh (static-uplink one-shot) MAC-CLONED eth1 to FC:5C:EE..
#     (the registered terminal NIC!) and ran "ip link set eth1 nomaster"
#     on every boot's static-uplink path -> bridge member + host shared one MAC ->
#     total L2 blackhole. restore_wan is quarantined (attic/) and wan_policy2
#     v1.3 removed the branch; this pin stays as defense-in-depth.
ip link set eth1 down 2>/dev/null
M0=$(cat /sys/class/net/eth0/address 2>/dev/null)
LAST=$(printf '%02x' $(( 0x${M0##*:} + 1 )) 2>/dev/null)
[ -n "$LAST" ] && [ "$LAST" != "00" ] && ip link set dev eth1 address "${M0%:*}:$LAST" 2>/dev/null
ip link set eth1 up 2>/dev/null   # netifd unreliable in de-FH world; ensure carrier
brctl addif br-lan eth1 2>/dev/null
brctl delif br-lan eth0 2>/dev/null   # eth0 = WAN (wan_policy2 v1.2 udhcpc)
iptables -C INPUT -i br-lan -j ACCEPT 2>/dev/null || iptables -I INPUT -i br-lan -j ACCEPT
kill -9 $(pidof dnsmasq) 2>/dev/null; sleep 1   # stale ranges from earlier boots
# v2.1: leasefile -> /tmp (default /var/lib/misc may not exist on tmpfs ->
#       dnsmasq DHCP silently never served; fix 2026-10-03)
# v2.4: -p 0 was DHCP-only: option 6 handed clients DNS=192.168.9.1 but nothing
#       answered :53 (PC nslookup timed out; phone survived on cache/fallback).
#       Device resolv.conf is empty, so pin public upstreams -- both verified
#       38ms through the ccmni2 NAT path (2026-10-03). stderr kept (no 2>null).
. /data/gw/defaults.conf 2>/dev/null; . /data/gw/settings.conf 2>/dev/null   # v2.20: DHCP range configurable via GUI (fix reboot drift)
dnsmasq -p 53 --no-resolv --server=223.5.5.5 --server=119.29.29.29 \
    --stop-dns-rebind --bogus-priv \
    -i br-lan -I lo \
    -F ${DHCP_R1:-192.168.9.100},${DHCP_R2:-192.168.9.200},255.255.255.0,${DHCP_LEASE:-12h} \
    --dhcp-option=3,192.168.9.1 --dhcp-option=6,192.168.9.1 \
    --dhcp-leasefile=/tmp/dnsmasq_br.leases \
    -x /var/run/dnsmasd_br.pid 2>>/tmp/rc19_dnsmasq.err
echo "dnsmasq: pid=$(pidof dnsmasq)" > /tmp/rc19_dnsmasq.state
pidof dropbear >/dev/null || /usr/sbin/dropbear -p 22 2>/dev/null
KLOG "LAN br-lan ok addr=$(ip -o addr show br-lan | grep -c 192.168.9.1)"

# --- WiFi: wait for FH init to finish loading the mt7992 chain, then APs up
i=0
while [ $i -lt 30 ] && [ ! -d /sys/class/net/rai0 ]; do sleep 5; i=$((i+1)); done
sh /data/gw/wifi_up.sh >/tmp/wifi_up.log 2>&1
KLOG "wifi: aps=$(iw dev 2>/dev/null | grep -c 'type AP') log=/tmp/wifi_up.log"

# --- wifi TX-stall auto-recovery guard (consumes /proc/v3_steth)
pgrep -f wifi_guard.sh >/dev/null || nohup sh /data/gw/wifi_guard.sh >/dev/null 2>&1 &

# --- stock-style LED state supervisor (v2.9: 开机自启, 2026-10-04 肉眼映射的GPIO)
pgrep -f led_mgr.sh >/dev/null || nohup sh /data/gw/led_mgr.sh >/dev/null 2>&1 &

# --- gateway GUI (v2.10+: v3httpd 192.168.9.1:80) + thermal fan supervisor
pgrep -f v3httpd >/dev/null || nohup /data/gw/v3httpd >/dev/null 2>&1 &
# --- v4 (RP0103 rebase): dropbear 自拉起 + 持久 host key
#   RP0103 纯净树的 /etc/dropbear/*_host_key 是 0 字节占位, rc.local 路径不再
#   可靠 → key 落 /data/gw/dropbear_keys (dropbearkey 生成), rc19 直接带 -r 启动
pgrep -x dropbear >/dev/null || {
    [ -s /data/gw/dropbear_keys/rsa ] || /usr/bin/dropbearkey -t rsa -f /data/gw/dropbear_keys/rsa >/dev/null 2>&1
    /usr/sbin/dropbear -r /data/gw/dropbear_keys/rsa -p 22 >/dev/null 2>&1
}
# v2.18: FH-App 后端(webs/nginx:8080 + 冗余 cfgmgr -L 4)不再自启 —— 外围裁剪第一阶段;
#        需要烽火终端App时手动: sh /data/gw/webs_revive.sh
pgrep -f fan_mgr.sh >/dev/null || nohup sh /data/gw/fan_mgr.sh >/dev/null 2>&1 &
pgrep -f ntp_keeper >/dev/null || nohup sh /data/gw/ntp_keeper.sh >/dev/null 2>&1 &
# v2.27: 定时重启守护(出厂默认每日 04:00; 配置 defaults+settings, 改配置免重启)
pgrep -f reboot_sched.sh >/dev/null || nohup sh /data/gw/reboot_sched.sh >/dev/null 2>&1 &
# v2.25: 流量采样器(5min 粒度, 蜂窝/以太网分别, /data 持久供周/月图表)
pgrep -f traffic_logger >/dev/null || nohup sh /data/gw/traffic_logger.sh >/dev/null 2>&1 &
# v2.19: 持续不变量看门狗 (L13: 部署后静默失效问题制度化对策)
pgrep -f watchdog.sh >/dev/null || nohup sh /data/gw/watchdog.sh >/dev/null 2>&1 &
# v2.28: 日志持久化守护(专项轮: /tmp 重启即失 + logread/dmesg 环被刷爆 →
#   syslog/dmesg 增量镜像落 /data/gw/logs + /tmp 快照 + 开机诊断包)
pgrep -f log_keeper.sh >/dev/null || nohup sh /data/gw/log_keeper.sh >/dev/null 2>&1 &

# --- dual-uplink aggregation last (v2.8: wan_agg supersedes wan_policy2;
#     vendor quecadp kernel split via /proc/multi_wan + fwmark policy routing;
#     5G+家宽 both active, per-flow 40/60, ~15s failover)
sleep 15
nohup sh /data/gw/wan_agg.sh >/tmp/wagg.out 2>&1 &

# --- v2.16: 可插拔上行认证守护 — conf 里 AUTHD_CMD 为任意认证程序
# v2.21: static 档案开机重应用 — MAC 伪装与静态 IP 是运行态, 断电/重启即丢
#   (2026-10-07 实弹: 断电重启后 eth0 回原生 MAC+无 IP, authd 带错 MAC 反复重试
#    且无人察觉; 现开机先恢复伪装与 IP 再拉认证, 与 apply_uplink_form 同配方)
if [ -r /data/gw/uplink.conf ] && grep -q '^ENABLE=1' /data/gw/uplink.conf; then
    . /data/gw/uplink.conf 2>/dev/null
    if [ "${FORM:-home}" = "static" ] && [ -n "${AUTH_IP:-}" ]; then
        ip addr flush dev eth0 2>/dev/null
        if [ "${MAC_SPOOF:-0}" = "1" ] && [ -n "${SPOOF_MAC:-}" ]; then
            ip link set eth0 down 2>/dev/null
            ip link set eth0 address "$SPOOF_MAC" 2>/dev/null
        fi
        ip addr add "$AUTH_IP/${AUTH_MASK:-255.255.255.128}" dev eth0 2>/dev/null
        ip link set eth0 up
        ip route replace default via "$AUTH_GW" dev eth0 metric 200 2>/dev/null
        # v2.22: wan.gw 喂给 wan_agg — 其表200默认路由与 eth_prio 主表切换
        # 均以此为 BB_GW 源(静态形态 udhcpc 不跑, 此文件原本无人写 = 表200恒空)
        echo "$AUTH_GW" > /tmp/wan.gw
    fi
    [ -n "${AUTHD_CMD:-}" ] && nohup $AUTHD_CMD >/dev/null 2>&1 &
fi

# --- production 5G dialer (ubus bootstrap + proven mipc recipe; runs late
#     so the modem is settled; wan_policy2 still prefers eth1 when present)
#     SKIPPED in FH mode: mobilenetwork (rc_netfh) owns the stock dial.
if [ $FHMODE -eq 0 ]; then
  (sleep 90; sh /data/gw/dial_5g.sh >>/tmp/dial_5g.out 2>&1) &
fi
KLOG "rc19v2 complete"
exit 0
