#!/bin/sh
# led_mgr.sh v2.0 — 原厂风格指示灯状态守护 (绝对电平驱动 + 自愈 + 全灯覆盖)
# 全部高电平点亮(1=亮 0=灭)。复刻原厂语义:
#   WiFi(467)        : AP 在线常亮 (任一 ra* vif operstate != down)
#   5G(475/473/474 = 绿/橙/红): 数据面唯一 — ccmni 有 IPv4=绿常亮,
#                       其余(未注册/无承载/模组离线)三色全灭; 细分态只进日志不点灯
#   4G(472/470/471 = 红/绿/橙): 未 present(未注册引脚), 本机不驻留 4G, 空操作
#   WAN(292 顶部网口绿, class 5g_evb_voice): 家宽(eth0)**数据面通**=亮, 否则灭
#   电源(356): bootloader 默认态, 本脚本不管
#
# ============ v2.0 修复: 边沿触发 → 绝对电平驱动 (2026-10-15 实弹) ============
# v1.x 只在状态串变化时写灯(if [ "$NS" != "$ST" ])。这是"反馈型"执行:
#   任何外部写方把灯改掉后, 状态串不变 → 永不纠回。实弹取证: eth0 数据面全程
#   通(b1), 但 06:05:39 后 5 小时内 led_mgr 再没写过一次灯 —— 因为状态串
#   一直是同一个。watchdog 的告警闪烁(v1.x 抢写 WAN 灯)或内核 trigger 一次
#   覆写即让 LED 永久停在错值。这就是"历史上多次修 LED 不符"的病灶: v1.5→
#   v1.8→v1.9 都在改判据, 执行方式始终是边沿的。
# v2.0 改**绝对电平驱动**: 每轮无条件把"应为值"写到每个灯(只读当前值不写,
#   已在正确值即跳过 = 免磨损); 外部扰动最大 2s 内纠正(轮询 2s)。判据不变。
#   selftest 的"容忍一拍"语义同步放宽为无条件一致。
#
# 控制通道 v1.4: sysfs /sys/class/gpio (export->direction=out->value)。
#   旧通道 fhled_ctl(kdrv ioctl) 已随 sysmgr 中和而失效——kdrv 模块由
#   sysmgr 加载, v4.1 不跑 sysmgr; 且 fhled_ctl 二进制与源码均未留存。
#   sysfs 由内核 pinctrl_paris(gpiochip276, 276-511) 提供并自带方向设置。
# WAN 通道 v1.5: gpio292 被 leds-gpio 占用(export=EBUSY; debugfs 实证
#   gpio-292 = 5g_evb_voice —— 厂商 EVB 设备树名, 实物即顶部网口绿灯)，
#   走 /sys/class/leds/5g_evb_voice/brightness, sysfs 为后备。
# v1.8: WAN 灯判据 carrier → **数据面实测**。载波在≠能上网: 21:30 家宽链路
#   "通而不通"数分钟, 载波始终为 1 而实际断网, 灯照亮=误导。与 wan_agg v2.26
#   同源判据(网关优先+公网兜底 ICMP, 键链同款)。
# v1.9: 5G 灯判据收敛到数据面唯一。旧语义"无承载=橙常亮"在模组崩溃离线期仍
#   点亮 —— 10-13 夜 01:07 模组 Fatal(EE) 后 ccmni2 被拆, 用户看到 5G 灯仍亮
#   = 谎报"5G 在"。现: 绿=ccmni 有 IPv4; 其余一律全灭; 未注册/无承载/模组
#   离线三态只写日志。
LOG=/tmp/led_mgr.log
llog() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
B=$(cd "$(dirname "$0")" && pwd)   # /data/gw
SYS=/sys/class/gpio
WANLED=/sys/class/leds/5g_evb_voice
W=467; G5R=474; G5G=475; G5O=473; WAN=292
# v2.0: 4G 三色(红472/绿470/橙471)按 470/471/472 序号预留 —— 实测未 claim
#   (debugfs 无登记, export 空操作)。本机不驻留 4G, 记一次"no pin"即退出。
G4R=472; G4G=470; G4O=471
G4_NOPIN_LOGGED=""

# v2.0: 绝对电平写入。已在正确值即跳过(免无谓 flash 磨损); 仅在漂移时写+记痕。
#   这是自愈的核心: 不比较状态串, 只比较"应为值 vs 当前实况"。
set_led() {
    g=$1; v=$2; d=$SYS/gpio$1; bad=""
    if [ -r "$d/value" ] && [ "$(cat $d/value 2>/dev/null)" = "$v" ]; then
        return 0
    fi
    [ -d "$d" ] || echo $g > $SYS/export 2>>$LOG || bad="export"
    if [ -z "$bad" ]; then
        echo out > $d/direction 2>>$LOG || bad="direction"
        echo $v > $d/value 2>>$LOG || bad="value"
    fi
    [ -n "$bad" ] && llog "gpio$g $bad FAIL"
}
set_wan() {
    if [ -d $WANLED ]; then
        if [ -r $WANLED/brightness ] && [ "$(cat $WANLED/brightness 2>/dev/null)" = "$1" ]; then
            return 0
        fi
        echo $1 > $WANLED/brightness 2>>$LOG || llog "wan brightness FAIL"
    else
        set_led $WAN $1
    fi
}
# v2.0: 4G 灯恒灭。引脚未 claim 时 export 每轮都会失败 → 噪声日志; 只记一次
#   然后走 sysfs 目录写入(未 claim 的 gpio export 后仍可写, 但要先 export)。
#   若 export 也不可用, 记一次后不再尝试(本机无 4G, 无实际危害)。
set_4g_off() {
    for _g in $G4G $G4O $G4R; do
        _d=$SYS/gpio$_g
        [ -r "$_d/value" ] || continue
        [ "$(cat $_d/value 2>/dev/null)" = "0" ] && continue
        set_led $_g 0
    done
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

# v2.0: 探测(全部判据的唯一来源; 干跑/一次性入口复用)
probe() {
    # WiFi: 任一 AP vif 存在且未 down (v1.2 起: 只查目录存在检测不到 ifdown;
    #   v2.0: ra0/rai0 双频都要算, 任一在就是"AP 在线"—— 单频 down 另一频仍在)
    WIFI=0
    for vif in ra0 rai0; do
        [ -d /sys/class/net/$vif ] && [ "$(cat /sys/class/net/$vif/operstate 2>/dev/null)" != "down" ] && { WIFI=1; break; }
    done
    # 5G: 任一 ccmni 有 v4 地址 = 数据面在(v1.9 唯一判据)
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
# v2.0: 状态串 → 引脚写入($2=1 真写 / 0 只打印映射, selftest 断言用)
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
        # 5G: 绿=数据面在; 无数据一律全灭(橙/红不再表达"5G 下线")
        if [ "$C5" = 1 ]; then set_led $G5G 1; set_led $G5O 0; set_led $G5R 0
        else set_led $G5G 0; set_led $G5O 0; set_led $G5R 0; fi
        # 4G: 本机不驻留; 三色恒灭
        set_4g_off
        # WAN: 灯=数据面通才亮(载波在但不通不谎称已连接)
        set_wan $BB
    else
        printf 'wifi=%s g5g=%s g5o=%s g5r=%s g4g=%s g4o=%s g4r=%s wan=%s carrier=%s\n' \
            "$WIFI" "$C5" 0 0 0 0 0 "$BB" "$BBP"
    fi
}
# v2.0: 干跑/一次性入口(部署自检与 selftest 用; 不改现场)
case "$1" in
--dry-state)
    [ -n "$2" ] || { echo "usage: led_mgr.sh --dry-state 'w1 c0 b1 p1'"; exit 2; }
    apply_state "$2" 0; exit 0 ;;
--once)
    probe; apply_state "w$WIFI c$C5 b$BB p$BBP" 1; exit 0 ;;
esac

llog "===== led_mgr v2.0 start (absolute-level drive + self-heal + 2s poll) ====="
BCN_LAST=""   # v1.6: 固件信标事件计数(RE实证三条权威标志)
ST=""         # 仅用于日志: 状态串变化才写日志(灯写入已不依赖它)
POLL=${LED_POLL:-2}
while :; do
    # v1.3: 夜间模式($B/led_mode.conf=1) — 全灭; 电源灯归bootloader不管
    # v1.6: 配置统一 — defaults+settings 叠加(回退旧led_mode.conf)
    [ -r $B/defaults.conf ] && . $B/defaults.conf
    [ -r $B/settings.conf ] && . $B/settings.conf
    NIGHT=${LED_NIGHT:-$(cat $B/led_mode.conf 2>/dev/null || echo 0)}
    if [ "$NIGHT" = "1" ]; then
        # v2.0: 夜间模式也走绝对电平 —— 外部扰动后同样自愈回"全灭"
        if [ "$ST" != "night" ]; then
            llog "state: night (all off)"
            ST="night"
        fi
        set_led $W 0; set_led $G5G 0; set_led $G5O 0; set_led $G5R 0
        set_4g_off; set_wan 0
        sleep $POLL
        continue
    fi
    probe
    NS="w$WIFI c$C5 b$BB p$BBP"
    apply_state "$NS" 1
    if [ "$NS" != "$ST" ]; then
        llog "state: $NS 5g=$(cell_sub) wan_led=$BB (carrier=$BBP)"
        ST=$NS
    fi
    # v1.6: 信标看门狗 — 驱动固件权威事件增量触发 no_bcn 重装(与wifi_up F2同原语)
    # v1.7: vif枚举动态化(访客可开在 ra1/rai1 任一/双频, 不再硬编码)
    # v2.0: dmesg 全量 grep 每轮跑(此前 10s/次已够, 2s/次仍廉价; 且只在增量时动作)
    BCN_NOW=$(dmesg 2>/dev/null | grep -cE 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal')
    if [ -n "$BCN_LAST" ] && [ "$BCN_NOW" -gt "$BCN_LAST" ]; then
        llog "beacon-loss event ($BCN_LAST->$BCN_NOW) — re-arming beacons"
        for vif in $(iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E '^ra'); do
            mwctl dev $vif set no_bcn 0 >/dev/null 2>&1
        done
    fi
    BCN_LAST=$BCN_NOW
    sleep $POLL
done
