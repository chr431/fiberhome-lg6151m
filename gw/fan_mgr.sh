#!/bin/sh
# fan_mgr.sh v1.5 -- 原厂梯度温控风扇守护 (2026-10-04 破案后固化)
# v1.5 (P1-1): 单实例锁 + 心跳(v1.4) — 看门狗重启不会拉出双实例.
# v1.4 (2026-10-20 stability batch1): 每轮写 /tmp/fan_mgr.hb — watchdog 用
#   心跳识别“进程活但 PWM 卡死”; 散热件不允许静默停摆。
# 破案要点(RE+实测): 该4线扇 pwm 255(100%占空比)会罢工! 原厂挡位表只有 60-140.
# 实测: 60→1663rpm 85→2117 105→2446 130→2872 140→3046 (hwmon1=pwm-fan@1)
# 温度取 soc_max; 模式: performance(默认)/silent(+6°C偏移) via /data/gw/fan_mode.conf
FAN=/sys/devices/platform/pwm-fan@1/hwmon/hwmon1/pwm1
RPM=/sys/devices/platform/pwm-fan-cap/hwmon/hwmon2/pwm1_rpm
LOG=/tmp/fan_mgr.log
flog() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

temp() {  # soc_max 温度(°C)
    for z in /sys/class/thermal/thermal_zone*; do
        [ "$(cat $z/type 2>/dev/null)" = "soc_max" ] && { cat $z/temp; return; }
    done
    echo 0
}

lvl_pwm() {  # 梯度表: performance
    case $1 in
        1) echo 60;;  2) echo 85;;  3) echo 105;; 4) echo 130;; 5) echo 140;;
    esac
}
lvl_temp() { # 各挡进入阈值(°C), 降挡需低于阈值-3(滞回)
    case $1 in
        1) echo 55;; 2) echo 61;; 3) echo 67;; 4) echo 73;; 5) echo 79;;
    esac
}

flog "===== fan_mgr v1.5 start (unified config; +heartbeat) ====="
# v1.5 (P1-1): single instance (watchdog may restart a stalled fan manager)
_lp=$(cat /tmp/fan_mgr.lock 2>/dev/null)
if [ -n "$_lp" ] && [ "$_lp" != "$$" ] && kill -0 "$_lp" 2>/dev/null && \
   grep -qa '/data/gw/fan_mgr.sh' /proc/$_lp/cmdline 2>/dev/null; then
    echo "fan_mgr: already running pid=$_lp" >&2
    exit 0
fi
echo $$ > /tmp/fan_mgr.lock
CUR=0
while :; do
    cut -d. -f1 /proc/uptime > /tmp/fan_mgr.hb 2>/dev/null
    # v1.3: 配置统一 + 修复v1.2双/data/gw路径bug(GUI静音切换从未生效的根因)
    [ -r /data/gw/defaults.conf ] && . /data/gw/defaults.conf
    [ -r /data/gw/settings.conf ] && . /data/gw/settings.conf
    MODE=${FAN_MODE:-performance}
    OFF=52; [ "$MODE" = "silent" ] && OFF=58
    T=$(( $(temp) / 1000 ))
    # 选挡: 从高到低找第一个 达到阈值 的挡; 低于OFF全关; 滞回-3°C
    NL=0
    i=5
    while [ $i -ge 1 ]; do
        TH=$(lvl_temp $i); [ "$MODE" = "silent" ] && TH=$((TH+6))
        if [ $T -ge $((TH - 3)) ] && [ $CUR -ge $i ]; then NL=$i; break; fi
        if [ $T -ge $TH ]; then NL=$i; break; fi
        i=$((i-1))
    done
    [ $T -lt $OFF ] && NL=0
    # v1.1: 清理外力遗留(如手工重放/原厂自检留下的pwm): 该关而没关就补写0
    CURPWM=$(cat $FAN 2>/dev/null)
    if [ $NL -eq 0 ] && [ "$CURPWM" != "0" ] && [ -n "$CURPWM" ]; then
        echo 0 > $FAN; CUR=0
        flog "temp=${T}C force-off (pwm was $CURPWM, mode=$MODE)"
    fi
    if [ $NL -ne $CUR ]; then
        if [ $NL -eq 0 ]; then
            echo 0 > $FAN
            flog "temp=${T}C level 0 (off, mode=$MODE)"
        else
            echo 0 > $FAN; sleep 3          # 原厂 kick: 先0停3秒
            echo $(lvl_pwm $NL) > $FAN
            sleep 6
            flog "temp=${T}C level $NL pwm=$(lvl_pwm $NL) rpm=$(cat $RPM 2>/dev/null) mode=$MODE"
        fi
        CUR=$NL
    fi
    sleep 10
done
