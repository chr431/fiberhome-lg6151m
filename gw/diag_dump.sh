#!/bin/sh
# diag_dump.sh v1.1 -- 一键诊断包（日志改善专项轮; v1.1: 结束行带生成时刻 — 尾部展示时"上次生成"可读)
# 用途: 问题诊断所需现场一次收集, 输出 stdout(GUI/SSH 重定向归档均可)。
#   log_keeper 每次开机 +180s 落 diag_boot.txt; api diag_gen 落 diag_last.txt。
# 脱敏(凭证红线): WPAPSK/GUEST_PASS/AUTHD_CMD/wpa_psk 等凭据行与 URL token
#   一律 <redacted>; gui_auth.conf/shadow 类文件整体不采集。
RED() {
    sed -e 's/^\(WPAPSK\)=.*/\1=<redacted>/' \
        -e 's/^\(GUEST_PASS\)=.*/\1=<redacted>/' \
        -e 's/^\(ApCliWPAPSK\)=.*/\1=<redacted>/' \
        -e 's/^\(AUTHD_CMD\)=.*/\1=<redacted>/' \
        -e 's/^\(wpa_psk\)=.*/\1=<redacted>/' \
        -e 's/token=[0-9a-f]*/token=<redacted>/g' \
        -e 's/pass=[^& ]*/pass=<redacted>/g'
}
echo "===== LG6151M 诊断包 $(date '+%F %T %z') up=$(cut -d. -f1 /proc/uptime)s ====="
echo "== 基础 =="
echo "slot=$(tr ' ' '\n' < /proc/cmdline | sed -n 's/^bootslot=//p') kern=$(uname -r) TZ=$(cat /etc/TZ 2>/dev/null)"
echo "TRY_A=$(dd if=/dev/mmcblk0p1 bs=1 skip=2060 count=2 2>/dev/null | hexdump -v -e '2/1 \"%02x\"')"
echo "load=$(cut -d' ' -f1-3 /proc/loadavg) mem=$(free 2>/dev/null | awk 'NR==2{print $3"KB used /"$2"KB"}')"
echo "disk=$(df /data 2>/dev/null | tail -1 | awk '{print $4"KB free"}')"
echo "== 配置(脱敏) =="
for f in /data/gw/defaults.conf /data/gw/settings.conf /data/gw/uplink.conf \
         /data/gw/cellular.conf /data/gw/fan_mode.conf /tmp/wifi_autoch; do
    [ -r "$f" ] && { echo "-- $f"; RED < "$f"; }
done
echo "== 无线 =="
iw dev 2>/dev/null
for f in /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf; do
    [ -r "$f" ] && { echo "-- $f"; RED < "$f"; }
done
echo "-- MLO 实况"; /usr/sbin/mwctl ra0 dump ap_mld all 2>&1
echo "-- IDC 安全掩码"; /usr/sbin/mwctl dev ra0 show unsafeinfo >/dev/null 2>&1; dmesg 2>/dev/null | grep 'SafeChnBitmask' | tail -1
echo "== 网络 =="
ip -o addr 2>/dev/null | grep -v 'scope host'
ip rule 2>/dev/null
ip route show 2>/dev/null; ip route show table 200 2>/dev/null
iptables -t nat -S POSTROUTING 2>/dev/null | head -6
iptables -S WANAGG 2>/dev/null | head -4
echo "== 日志 =="
echo "-- logread(ring tail 300)"
logread 2>/dev/null | tail -300
echo "-- dmesg(tail 200)"
dmesg 2>/dev/null | tail -200
for f in /tmp/*.log /tmp/*.out /tmp/rc19.log /tmp/watchdog_state /tmp/wifi_autoch; do
    [ -s "$f" ] || continue
    echo "-- $f (tail 60)"
    tail -60 "$f" | RED
done
echo "-- 持久镜像 syslog.log(tail 120)"
tail -120 /data/gw/logs/syslog.log 2>/dev/null | RED
echo "-- 上次开机 /tmp 快照"
ls -la /data/gw/logs/tmp/ 2>/dev/null
echo "===== 诊断包结束 $(date '+%F %T %z') up=$(cut -d. -f1 /proc/uptime)s ====="
