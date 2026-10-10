#!/bin/sh
# ntp_keeper.sh v1.2 -- 守时器 (每小时对时; 设备无RTC电池, 冷启动时间漂移大)
# 首选源 = 自管配置 NTP_SERVER (defaults.conf 出厂默认叠 settings.conf 用户覆盖, 与 GUI
# 时间同步卡片同源); 其后硬编码 IP 兜底; 223.5.5.5 兜底 resolv.conf 语义不变。
# v1.1: 原硬编码列表与 GUI 设置脱钩 = 用户设置了也不用于守时; 现每小时重读配置,
#       改动无需重启脚本(应用时另有 api 立即同步)。
# v1.2: 时区自愈 — /etc/TZ 是指向 /tmp/TZ 的 tmpfs 符号链接, 重启即失(回落 UTC),
#       而原实现只在 GUI 应用时写运行态 = 每次重启后时钟显示与定时重启窗口全部
#       偏移。现每轮从自管配置重应用(首轮即开机后数秒内生效)。
LOG=/tmp/ntp_keeper.log
ng() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s /etc/resolv.conf ] || echo "nameserver 223.5.5.5" > /etc/resolv.conf
ng "start"
while :; do
    NTP_SERVER=""; TZ=""
    [ -r /data/gw/defaults.conf ] && . /data/gw/defaults.conf
    [ -r /data/gw/settings.conf ] && . /data/gw/settings.conf
    if [ -n "${TZ:-}" ] && [ "$(cat /etc/TZ 2>/dev/null)" != "$TZ" ]; then
        echo "$TZ" > /etc/TZ && ng "TZ applied: $TZ"
    fi
    OK=0
    for S in "${NTP_SERVER:-ntp.aliyun.com}" 203.107.6.88 119.28.63.197; do
        ntpclient -h "$S" -c 1 -s >/dev/null 2>&1 && { OK=1; ng "sync via $S"; break; }
    done
    [ $OK -eq 0 ] && ng "sync failed all sources"
    sleep 3600
done
