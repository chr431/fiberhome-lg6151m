#!/bin/sh
# ntp_keeper.sh v1.0 -- 守时器 (每小时对时; 设备无RTC电池, 冷启动时间漂移大)
# 通道: ntpclient -> 223.5.5.5 DNS兜底直连IP; 2026-10-04 用户对时事件驱动
LOG=/tmp/ntp_keeper.log
ng() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
[ -s /etc/resolv.conf ] || echo "nameserver 223.5.5.5" > /etc/resolv.conf
ng "start"
while :; do
    OK=0
    for S in ntp.aliyun.com 203.107.6.88 119.28.63.197; do
        ntpclient -h "$S" -c 1 -s >/dev/null 2>&1 && { OK=1; ng "sync via $S"; break; }
    done
    [ $OK -eq 0 ] && ng "sync failed all sources"
    sleep 3600
done
