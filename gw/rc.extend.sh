#!/bin/sh
# rc.extend.sh v1.7 -- slot-aware dispatcher (shared /data between v2/v3)
# v1.6: route A -- FH modem-stack environment (MODE.fh gate)
# v1.8 = v1.7 + 启动行去&(同步启动); v1.7: A槽保活 + dropbear唯一属主
#   - bootslot=a 时清 misc TRY_A(offset 2061)=厂商S99语义(v4.1删S99致LK回退B的
#     根治); 无条件恢复 hnat_qos 两行(同为S99误伤)
#   - dropbear 由此处统一先启(带/data/gw/dropbear_keys), 消除 v2_access/rc19
#     并行启动的TOCTOU双实例; 下游各启动点本就带 pgrep 守卫, 自然短路
# v1.4 SUBTRACTION mandate (2026-10-03): slot-B (v2) is the MINIMAL fallback --
#   stock firmware + pure access layer, zero contention with FH daemons.
#   b-branch reduced to v2_access.sh only. wan_policy2/v3_fix/hnat/healthdog
#   moved to slot-a (v3) where the sharing mission lives.
# v1.5: flag-gated one-shot capture launch (capture_ubus.sh) BEFORE slot case
#   -- must precede FH's mobilenetwork dial to record the stock datacall blob.
grep -q healthdog /proc/modules 2>/dev/null || true

# --- v1.7: dropbear single-owner (race-proof; downstream pgrep guards short-circuit)
mkdir -p /data/gw/dropbear_keys
[ -f /data/gw/dropbear_keys/rsa ] || /usr/bin/dropbearkey -t rsa -f /data/gw/dropbear_keys/rsa -s 2048 2>/dev/null
pgrep -x dropbear >/dev/null || /usr/sbin/dropbear -r /data/gw/dropbear_keys/rsa -p 22 >/dev/null 2>&1  # v1.8: 无&, dropbear自daemonize, 同步返回即监听, 杜绝rc19守卫竞态

# --- v1.7: A-slot keepalive (vendor S99 semantics, lost when S99 was removed)
case "$(cat /proc/cmdline)" in *bootslot=a*)
    [ -b /dev/mmcblk0p1 ] && dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek=2061 count=1 conv=notrunc 2>/dev/null
    echo 0 1 > /proc/hnat/hnat_qos 2>/dev/null
    echo 2 1 > /proc/hnat/hnat_qos 2>/dev/null
    logger -t rc.extend "slot=a: TRY_A cleared + hnat_qos"
    ;; esac
[ -f /data/gw/DO_UBUS_CAP ] && nohup sh /data/gw/capture_ubus.sh >/dev/null 2>&1 &
slot=$(cat /proc/cmdline | tr ' ' '\n' | sed -n 's/^bootslot=//p')
case "$slot" in
  b) # v2: access layer ONLY (serial/SSH/DHCP/firewall-22 + logging)
     logger -t rc.extend "slot=b (v2 minimal): v2_access only"
     nohup sh /data/gw/v2_access.sh >/dev/null 2>&1 &
     ;;
  *) # v3: full stack (forensics, flight rc19, TTL/hnat are v3 duties)
     logger -t rc.extend "slot=$slot: v3 rc19.sh"
     # v1.6: route A -- FH modem-stack environment parallel to our layer
     # (dial: mobilenetwork 过渡期 + dial_keeper 兜底; rc19 skips rmmod+dial_5g via MODE.fh gate)
     # v1.7 (D2 开箱审查): MODE.fh 首刷自建 — kit 从不创建该标志, 纯原厂直刷时
     #       rc_netfh 不跑 = 无蜂窝栈。缺省即路由A(5G CPE 必须有 modem); 移除
     #       该文件可回 frankenstein 模式(与原语义一致)。
     if [ ! -f /data/gw/MODE.fh ]; then
         touch /data/gw/MODE.fh
         echo "$(date -u +%FT%TZ) MODE.fh auto-provisioned (first boot)" >> /tmp/rc.extend.log
     fi
     [ -f /data/gw/MODE.fh ] && nohup sh /data/gw/rc_netfh.sh >/tmp/netfh.out 2>&1 &
     insmod /data/gw/healthdog.ko forensic=1 armed=0 2>/dev/null
     nohup sh /data/gw/rc19.sh >/tmp/rc19.log 2>&1 &
     # healthdog stack + RCU-stall panic
     echo 1 > /proc/sys/kernel/panic_on_rcu_stall 2>/dev/null
     [ -e /proc/healthdog ] || insmod /data/gw/healthdog.ko 2>/dev/null
     pgrep -f healthdog.sh >/dev/null || nohup /data/gw/healthdog.sh >/dev/null 2>&1 &
     ;;
esac
