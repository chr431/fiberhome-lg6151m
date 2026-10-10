#!/bin/sh
# reboot_sched.sh v1.1 -- 定时重启守护(出厂默认: 每日 04:00)
# 配置: defaults.conf(只读出厂) 叠 settings.conf(用户稀疏覆盖), 与 NTP/WiFi 族同源;
#   每轮重读 → GUI 改配置无需重启本守护。
# v1.1: 每轮先自应用时区(/etc/TZ→/tmp/TZ 重启即失) — 本守护按本地时间比对窗口,
#   不能依赖别的守护的时序(ntp_keeper 也做, 幂等双保险)。
# 护栏(缺一不发; 每一条都对应一种真实故障):
#   1) REBOOT_EN=1                      -- 用户可停用
#   2) 时钟可信: 年份 >= 2024           -- 设备无 RTC, 冷启动时钟可能停在 1970/2000,
#      否则 "00:xx 命中 04:00" 类假命中会变成重启循环
#   3) 已运行 >= 300s                   -- 重启后本守护再启动, 时钟未校准时也不复触发
#   4) 命中窗口 [目标时刻, +5min)       -- 容忍 30s 轮询抖动与对时跳变
#   5) 当日未执行(last 文件比对)        -- 跨重启持久(/data), 杜绝同日二次重启
# 触发序: 落盘 last → sync → reboot。reboot 即 api.sh sys_reboot 同一命令(手动
#   重启按钮同源), 槽位保活由 rc.extend.sh 开机清 TRY_A 承担, 无需额外处理。
LOG=/tmp/reboot_sched.log
LAST=/data/gw/reboot_sched.last
rg() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
rg "start"
while :; do
    REBOOT_EN=0; REBOOT_TIME=04:00; TZ=""
    [ -r /data/gw/defaults.conf ] && . /data/gw/defaults.conf
    [ -r /data/gw/settings.conf ] && . /data/gw/settings.conf
    case "${REBOOT_TIME:-}" in [0-2][0-9]:[0-5][0-9]) ;; *) REBOOT_TIME=04:00 ;; esac
    if [ -n "${TZ:-}" ] && [ "$(cat /etc/TZ 2>/dev/null)" != "$TZ" ]; then
        echo "$TZ" > /etc/TZ
    fi
    if [ "${REBOOT_EN:-0}" = 1 ]; then
        Y=$(date +%Y); U=$(cut -d. -f1 /proc/uptime 2>/dev/null)
        H=$(date +%H); M=$(date +%M); D=$(date +%F)
        TH=${REBOOT_TIME%%:*}; TM=${REBOOT_TIME#*:}
        # busybox ash: 前导零按八进制解析(08/09 直接报错) -- 去零再算术
        H=$(( ${H#0} + 0 )); M=$(( ${M#0} + 0 ))
        TH=$(( ${TH#0} + 0 )); TM=$(( ${TM#0} + 0 ))
        DIFF=$(( H * 60 + M - TH * 60 - TM ))
        if [ "${Y:-0}" -ge 2024 ] && [ "${U:-0}" -ge 300 ] \
           && [ $DIFF -ge 0 ] && [ $DIFF -lt 5 ] \
           && [ "$(cat $LAST 2>/dev/null)" != "$D" ]; then
            echo "$D" > $LAST
            sync
            rg "REBOOT now=$(date '+%H:%M') target=$REBOOT_TIME (late=${DIFF}min)"
            reboot
            sleep 120   # reboot 未生效(极少)则当日不再重复发; last 已挡
        fi
    fi
    sleep 30
done
