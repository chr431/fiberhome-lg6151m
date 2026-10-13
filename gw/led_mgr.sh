#!/bin/sh
# led_mgr.sh v1.9 — 原厂风格指示灯状态守护 (2026-10-04 实测引脚映射)
# 全部高电平点亮(1=亮 0=灭)。复刻原厂语义(v1.0 简化态):
#   WiFi(467)   : AP 在线常亮
#   5G(475/473/474 = 绿/橙/红): v1.9 判据收敛数据面唯一 — ccmni 有 IPv4=绿常亮,
#     其余(未注册/无承载/模组离线)三色全灭; 细分态只进日志不点灯
#   4G(472/470/471 = 红/绿/橙): 全灭(本机不驻留4G)
#   WAN(292 顶部网口绿): 家宽(eth0)**数据面通**=亮, 载波在但不通=橙, 否则灭
#   电源(356): bootloader 默认态, 本脚本不管
# 控制通道 v1.4: sysfs /sys/class/gpio (export->direction=out->value)。
#   旧通道 fhled_ctl(kdrv ioctl) 已随 sysmgr 中和而失效——kdrv 模块由
#   sysmgr 加载, v4.1 不跑 sysmgr; 且 fhled_ctl 二进制与源码均未留存。
#   sysfs 由内核 pinctrl_paris(gpiochip276, 276-511) 提供并自带方向设置。
# WAN 通道 v1.5: gpio292 被 leds-gpio 占用(export=EBUSY; debugfs 实证
#   gpio-292 = 5g_evb_voice —— 厂商 EVB 设备树名, 实物即顶部网口绿灯)，
#   走 /sys/class/leds/5g_evb_voice/brightness, sysfs 为后备。
# v1.9 (2026-10-14 模组 EE 事故实弹): 5G 灯判据收敛到数据面唯一。旧语义"无承载=
#   橙常亮"在模组崩溃离线期仍点亮 —— 10-13 夜 01:07 模组 Fatal(EE) 后 ccmni2 被拆,
#   用户看到 5G 灯仍亮 = 谎报"5G 在"。现: 绿=ccmni 有 IPv4; 其余一律全灭;
#   未注册/无承载/模组离线三态只写日志。+ --once/--dry-state 干跑入口
#   (selftest 直接断言映射, 不点灯不动现场)。
# v1.8 (2026-10-09 21:30 事件): WAN 灯判据 carrier → **数据面实测**。
#   载波在≠能上网: 21:30 家宽链路"通而不通"数分钟, 载波始终为 1 而实际断网,
#   灯照亮=误导。与 wan_agg v2.26 同源判据(网关优先+公网兜底 ICMP, 键链同款)。
#   三态: 绿=数据面通; 橙=载波在但数据面不通; 灭=无载波。
LOG=/tmp/led_mgr.log
llog() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
B=$(cd "$(dirname "$0")" && pwd)   # /data/gw 或 /data/gw 皆可
SYS=/sys/class/gpio
WANLED=/sys/class/leds/5g_evb_voice
W=467; G5R=474; G5G=475; G5O=473; WAN=292
# v1.8: 顶部网口灯三态 — 该节点单极性(只绿), 橙态借用 5G 橙灯之外的
#   "闪烁"表达不可靠, 故: 数据面通=绿亮, 载波在但不通=绿灭(不再谎称已连),
#   判定日志留痕。物理无载波同样灭 = 与"通了但上游死"区分靠 GUI 状态页。
set_led() {
    g=$1; v=$2; d=$SYS/gpio$1; bad=""
    [ -d "$d" ] || echo $g > $SYS/export 2>>$LOG || bad="export"
    if [ -z "$bad" ]; then
        echo out > $d/direction 2>>$LOG || bad="direction"
        echo $v > $d/value 2>>$LOG || bad="value"
    fi
    [ -n "$bad" ] && llog "gpio$g $bad FAIL"
}
set_wan() {
    if [ -d $WANLED ]; then
        echo $1 > $WANLED/brightness 2>>$LOG || llog "wan brightness FAIL"
    else
        set_led $WAN $1
    fi
}
# v1.8: 家宽数据面探活(与 wan_agg v2.26 w2_data_alive 同判据同键链)
bb_data_alive() {
    BB_GW=$(head -1 /tmp/wan.gw 2>/dev/null)
    if [ -r $B/uplink.conf ] && grep -q '^FORM=static' $B/uplink.conf 2>/dev/null; then
        [ -z "$BB_GW" ] && BB_GW=$(grep -m1 '^PROBE_GW=' $B/uplink.conf | cut -d= -f2)
        [ -z "$BB_GW" ] && BB_GW=$(grep -m1 '^AUTH_GW=' $B/uplink.conf | cut -d= -f2)
    fi
    [ -n "$BB_GW" ] && ping -4 -I eth0 -c1 -W2 -s1 "$BB_GW" 2>/dev/null | grep -q ttl && return 0
    ping -4 -I eth0 -c1 -W2 -s1 223.5.5.5 2>/dev/null | grep -q ttl && return 0
    ping -4 -I eth0 -c1 -W2 -s1 120.53.53.53 2>/dev/null | grep -q ttl && return 0
    return 1
}
ST=""   # 上次状态串, 变化才写

# v1.9: 数据面探测(全部判据的唯一来源; 干跑/一次性入口复用)
probe() {
    # WiFi: AP 接口存在且未 down (v1.2: 只查目录存在检测不到 ifdown)
    WIFI=0
    [ -d /sys/class/net/rai0 ] && [ "$(cat /sys/class/net/rai0/operstate 2>/dev/null)" != "down" ] && WIFI=1
    # 5G: 任一 ccmni 有 v4 地址 = 数据面在(v1.9: 唯一判据)
    CELL=$(ip -4 addr show 2>/dev/null | grep -A0 ccmni | grep -c "inet " || true)
    [ "$CELL" -gt 0 ] && C5=1 || C5=0
    # 家宽: v1.8 数据面实测判活(carrier 只作"物理在"的辅助信息)
    BB=0; BBP=0
    [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ] && BBP=1
    bb_data_alive && BB=1
}
# v1.9: 蜂窝细分态 — 仅用于日志, 不再点灯(旧"无承载=橙"即谎报根源)
cell_sub() {
    case "$(cat /sys/kernel/ccci/boot 2>/dev/null)" in
    md1:4*)
        if [ "$C5" = 1 ]; then echo bearer; else echo reg_no_bearer; fi ;;
    *) echo md_offline ;;
    esac
}
# v1.9: 状态串 → 引脚写入($2=1 真写 / 0 只打印映射, selftest 断言用)
apply_state() {
    _st=$1; _wr=${2:-1}
    WIFI=0; C5=0; BB=0; BBP=0
    for _kv in $_st; do
        case ${_kv%[01]} in
        w) WIFI=${_kv#w} ;; c) C5=${_kv#c} ;; b) BB=${_kv#b} ;; p) BBP=${_kv#p} ;;
        esac
    done
    if [ "$_wr" = 1 ]; then
        set_led $W $WIFI
        # v1.9: 绿=数据面在; 无数据一律全灭(橙/红不再表达"5G 下线")
        if [ "$C5" = 1 ]; then set_led $G5G 1; set_led $G5O 0; set_led $G5R 0
        else set_led $G5G 0; set_led $G5O 0; set_led $G5R 0; fi
        # v1.8: 灯=数据面通才亮(载波在但不通不再谎称已连接)
        set_wan $BB
    else
        printf 'wifi=%s g5g=%s g5o=%s g5r=%s wan=%s carrier=%s\n' \
            "$WIFI" "$C5" 0 0 "$BB" "$BBP"
    fi
}
# v1.9: 干跑/一次性入口(部署自检与 selftest 用; 不改现场)
case "$1" in
--dry-state)
    [ -n "$2" ] || { echo "usage: led_mgr.sh --dry-state 'w1 c0 b1 p1'"; exit 2; }
    apply_state "$2" 0; exit 0 ;;
--once)
    probe; apply_state "w$WIFI c$C5 b$BB p$BBP" 1; exit 0 ;;
esac

llog "===== led_mgr v1.9 start (sysfs WAN + data-plane probe + beacon watchdog) ====="
BCN_LAST=""   # v1.6: 固件信标事件计数(RE实证三条权威标志)
while :; do
    # v1.3: 夜间模式($B/led_mode.conf=1) — 全灭; 电源灯归bootloader不管
    # v1.6: 配置统一 — defaults+settings 叠加(回退旧led_mode.conf)
    [ -r $B/defaults.conf ] && . $B/defaults.conf
    [ -r $B/settings.conf ] && . $B/settings.conf
    NIGHT=${LED_NIGHT:-$(cat $B/led_mode.conf 2>/dev/null || echo 0)}
    if [ "$NIGHT" = "1" ]; then
        if [ "$ST" != "night" ]; then
            set_led $W 0; set_led $G5G 0; set_led $G5O 0; set_led $G5R 0; set_wan 0
            llog "state: night (all off)"
            ST="night"
        fi
        sleep 10
        continue
    fi
    probe
    NS="w$WIFI c$C5 b$BB p$BBP"
    if [ "$NS" != "$ST" ]; then
        apply_state "$NS" 1
        llog "state: $NS (applied) 5g=$(cell_sub) wan_led=$BB (carrier=$BBP)"
        ST=$NS
    fi
    # v1.6: 信标看门狗 — 驱动固件权威事件增量触发 no_bcn 重装(与wifi_up F2同原语)
    # v1.7: vif枚举动态化(访客可开在 ra1/rai1 任一/双频, 不再硬编码)
    BCN_NOW=$(dmesg 2>/dev/null | grep -cE 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
    if [ -n "$BCN_LAST" ] && [ "$BCN_NOW" -gt "$BCN_LAST" ]; then
        llog "beacon-loss event ($BCN_LAST->$BCN_NOW) — re-arming beacons"
        for vif in $(iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E '^ra'); do
            mwctl dev $vif set no_bcn 0 >/dev/null 2>&1
        done
    fi
    BCN_LAST=$BCN_NOW
    sleep 10
done
