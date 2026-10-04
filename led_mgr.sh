#!/bin/sh
# led_mgr.sh v1.0 — 原厂风格指示灯状态守护 (2026-10-04 实测引脚映射)
# 全部高电平点亮(1=亮 0=灭)。复刻原厂语义(v1.0 简化态):
#   WiFi(467)   : AP 在线常亮
#   5G(474/475/473 = 红/绿/橙): 有承载=绿常亮; 无承载=橙; 其余灭
#   4G(472/470/471 = 红/绿/橙): 全灭(本机不驻留4G)
#   WAN(292 顶部网口绿): 家宽(eth0)有租约=亮, 否则灭
#   电源(356): bootloader 默认态, 本脚本不管
# 控制通道: fhled_ctl g <gpio> <0|1> (set_mode 切输出方向后写值 — 经实测
# kdrv gpio write 只写数据不置方向, 必须走 set_mode 路径)
LOG=/tmp/led_mgr.log
llog() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
W=467; G5R=474; G5G=475; G5O=473; WAN=292
set_led() { /data/gw/fhled_ctl g $1 $2 >/dev/null 2>&1; }
ST=""   # 上次状态串, 变化才写

llog "===== led_mgr v1.3 start (night mode) ====="
while :; do
    # v1.3: 夜间模式(/data/gw/led_mode.conf=1) — 全灭; 电源灯归bootloader不管
    NIGHT=$(cat /data/gw/led_mode.conf 2>/dev/null || echo 0)
    if [ "$NIGHT" = "1" ]; then
        if [ "$ST" != "night" ]; then
            set_led $W 0; set_led $G5G 0; set_led $G5O 0; set_led $G5R 0; set_led $WAN 0
            llog "state: night (all off)"
            ST="night"
        fi
        sleep 10
        continue
    fi
    # WiFi: AP 接口存在且未 down (v1.2: 只查目录存在检测不到 ifdown)
    WIFI=0
    [ -d /sys/class/net/rai0 ] && [ "$(cat /sys/class/net/rai0/operstate 2>/dev/null)" != "down" ] && WIFI=1
    # 5G: 任一 ccmni 有 v4 地址
    CELL=$(ip -4 addr show 2>/dev/null | grep -A0 ccmni | grep -c "inet " || true)
    [ "$CELL" -gt 0 ] && C5=1 || C5=0
    # 家宽: eth0 载波(拔线IP不会消失——udhcpc钩子加的是永久地址,v1.0错盯IP)
    BB=0
    [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ] && BB=1
    NS="w$WIFI c$C5 b$BB"
    if [ "$NS" != "$ST" ]; then
        set_led $W $WIFI
        if [ $C5 -eq 1 ]; then set_led $G5G 1; set_led $G5O 0; set_led $G5R 0
        else set_led $G5G 0; set_led $G5O 1; set_led $G5R 0; fi
        set_led $WAN $BB
        llog "state: $NS (applied)"
        ST=$NS
    fi
    sleep 10
done
