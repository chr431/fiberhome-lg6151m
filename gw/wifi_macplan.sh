#!/bin/sh
# wifi_macplan.sh v1.0 — 出厂 MAC 派生计划 (自 wifi_up v1.28 拆出, 2026-10-17 架构轮)
# 输出(stdout, eval 友好): brmac=<基址> ra0_mac=<..> rai0_mac=<..> ra1_mac=<..> rai1_mac=<..>
# 算法(出厂 brmac → 各接口): ra0 = 基址第二字节+1(255 回绕); rai0 = 基址末字节+8(回绕);
#   访客 ra1/rai1 = 各自射频基址末字节+1(厂测 mbss 规则, 逐机唯一)。
#   eth0 原生 MAC 与 ra0_mac 同源(基址第二字节+1) — api 的 uplink 档案还原消费此值。
# 兜底链: 出厂档案不可读 → eth0 原生 MAC 反推基址(第二字节-1, 与出厂算法互逆)
#   → 合成本地管理地址 02:03:7F:00:00:00(不可路由, 非任何真实设备)。
# 消费方: wifi_up(接口 BSSID)、api_agg(eth0 原生 MAC 还原 — 原内联副本缺两级
#   兜底, brmac 档案不可读时静默不还原 = 同一算法两处实现的漂移实例, 本轮收敛)。
brmac=$(uci get /fhdata/factory_conf.brmac.value 2>/dev/null)
# 兜底1: 出厂档案不可读时由 eth0 原生MAC反推基址(第二字节-1, 与出厂算法互逆)
if [ -z "$brmac" ]; then
    E0=$(cat /sys/class/net/eth0/address 2>/dev/null)
    if [ -n "$E0" ]; then
        b0=$(printf %d 0x$(echo $E0 | cut -d: -f2)); b0=$(( (b0 + 255) % 256 ))
        brmac="$(echo $E0 | cut -d: -f1):$(printf %02X $b0):$(echo $E0 | cut -d: -f3-)"
    fi
fi
# 兜底2: 合成本地管理地址(不可路由, 非任何真实设备)
[ -z "$brmac" ] && brmac=02:03:7F:00:00:00
mac1=${brmac:0:2}; mac2=${brmac:3:2}; mac3=${brmac:6:2}
mac4=${brmac:9:2};  mac5=${brmac:12:2}; mac6=${brmac:15:2}
mac2="0x${mac2}"; mac2=$(printf %d ${mac2})
[ $mac2 -eq 255 ] && mac2=0 || mac2=$((mac2+1))
mac2=$(printf %02X ${mac2})
rai0_mac6="0x${mac6}"; rai0_mac6=$(printf %d ${rai0_mac6}); rai0_mac6=$((rai0_mac6+8))
[ $rai0_mac6 -gt 255 ] && rai0_mac6=$((rai0_mac6-255))
rai0_mac6=$(printf %02X ${rai0_mac6})
ra0_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${mac6}"
rai0_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${rai0_mac6}"
# v1.18: 访客 BSSID 按厂测 mbss 规则从各自射频基址 +1 派生 (逐机唯一, 替换 v1.4 的全机型固定样例MAC)
g6="0x${mac6}";    g6=$(printf %d $g6);    g6=$(( (g6+1)%256 ));    g6=$(printf %02X $g6)
gi6="0x${rai0_mac6}"; gi6=$(printf %d $gi6); gi6=$(( (gi6+1)%256 )); gi6=$(printf %02X $gi6)
ra1_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${g6}"
rai1_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${gi6}"
echo "brmac=$brmac ra0_mac=$ra0_mac rai0_mac=$rai0_mac ra1_mac=$ra1_mac rai1_mac=$rai1_mac"
