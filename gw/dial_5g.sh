#!/bin/sh
# dial_5g.sh v1.4 — production 5G dialer for v3 (recipe proven live 2026-10-02).
#
# v1.4 (2026-10-17 netagent 摘除试验轮): 拨号+落地统一改走 ccmni_up.sh —
# 实证 mtk_netagent 才是 ccmni IP 执行者, 且厂商 proto(mipc.sh)同样不含落地
# 语句(旧注释"IP already applied by the proto"系错误归属, 实为 netagent 兜的);
# 它退役后 proto 路径与裸调用都会得到 result:0 + 僵尸 IP。proto 驱动段
# (打补丁副本+XTRACE 解析)随之退役 — dial_keeper 同款配方自 2026-10-06 起
# 每日实弹验证, check_ia/apn_type 时代的"三秘密"已不再必要。
# ubus 引导段保留(Frankenstein boot 的 ubusd 空转问题仍在)。
# History: 2026-10-02 手工 mipc 拨号 result:2 数小时, set -x 直跑 proto 揭出
# 三秘密(act JSON 形态/check_ia 前置/netagent 门); 该配方服务于 proto 路径。
# Post-dial plumbing: 落地后的默认路由(仅探活 metric 250)、LAN NAT 与 v3_fix
# TTL 伪装重载。Idempotent: re-running deacts+acts fresh. Log: /tmp/dial_5g.log
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

# --- 1+2+3. dial + land via ccmni_up (v1.4; APN 取自 SIM 档案, keeper 同源) ---
APN=$(mipc_wan_cli --apn_provision_by_sim 2>/dev/null | grep -oE '"apn": *"[^"]+"' | cut -d'"' -f4)
[ -n "$APN" ] || APN=cbnet
IF=$(sh /data/gw/ccmni_up.sh "$APN")
rc=$?
glog "ccmni_up apn=$APN rc=$rc if=$IF"
[ $rc -eq 0 ] && [ -n "$IF" ] || { KLOG "dial FAILED rc=$rc"; exit 2; }
glog "iface=$IF"

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
KLOG "5G UP on $IF"

# --- 4. routes + NAT + TTL masquerade ---
# v2.31: main 表默认路由由 wan_agg 的 main_primary_apply() **独占**维护(按聚合
#   模式+权重+真实存活推导, v4/v6 同源)。本脚本不再写 metric 50 主默认 ——
#   那会把蜂窝插进家宽主默认(0)与备用(200)之间, 一旦主默认被冲刷, 未打标流量
#   会静默改走蜂窝(2026-10-15 实测复核的地雷)。此处只保证"可探活": 装一条劣于
#   家宽备用的 metric 250。需要蜂窝当主路时由聚合模式决定, 不再写死。
ip route replace default dev $IF metric 250 2>/dev/null
iptables -t nat -C POSTROUTING -s $LAN_NET -o $IF -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s $LAN_NET -o $IF -j MASQUERADE
# TTL masquerade follows the live data iface (was hardcoded ccmni2-era)
rmmod v3_fix 2>/dev/null
insmod /data/gw/v3_fix.ko wan_if=$IF ttl_mode=1 unhook=1
glog "route+NAT+TTL done on $IF"
KLOG "5G stack complete on $IF"
exit 0
