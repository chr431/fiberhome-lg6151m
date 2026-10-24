#!/bin/sh
# usb_mgr.sh v1.0 -- USB-C(设备模式)服务管理: 总开关 + 数据/ADB/控制台三个子功能
#
# 硬件/软件事实(2026-10-24 实测定案, 见私有仓 docs):
#   - 机身 USB-C = 仅设备(peripheral)能力的 USB-C 母座: 板上 TCPC(HD3SS3220)/
#     PS5169/buck-boost 均未贴装(i2c 总线实测无应答), host 模式电气死路;
#   - 厂商遗留链(只读镜像内 /etc/init.d/usb.init S30 + /etc/restart_usb.sh
#     keepalive)已把 configfs 复合设备 g1(0x2c7c:7006, RNDIS+ADB+2xACM,
#     MSFT100 描述符)绑到 UDC 11201000.usb 并强制 device 模式 —— 本脚本
#     不重建该链, 只做服务补完(rndis0 桥入 br-lan)与开关/状态矫正;
#   - rndis0 = RNDIS 数据口(usb_net.ko 建), 桥入 br-lan 后 PC 即 LAN 客户端,
#     DHCP/DNS/GUI/SSH 与网口客户完全同权;
#   - ADB = /sbin/adbd_usb(procd 常驻), 由 /data/config/usb 的
#     service_adb_enable 门控(0=CNXN 拒绝); 翻位后重启进程生效;
#   - 控制台 = ttyGS0(ACM 串口), getty 登录口令体系与机身串口一致
#     (物理接触面等价, 默认关闭).
#
# 配置键(defaults.conf 出厂默认 叠 settings.conf 用户覆盖, GUI 可改):
#   USB_ENABLED  总开关  1=服务在(默认)  0=口全灭(停 keepalive+解绑 UDC;
#                    注意开机 S30usb 到 rc19 之间仍有约 30-40s 枚举窗口,
#                    根除需固件镜像级裁剪, 属后续镜像构建轮)
#   USB_ADB      ADB 子开关(默认 0, 保持厂商门控姿态)
#   USB_CONSOLE  ttyGS0 控制台(默认 0)
#
# 用法: usb_mgr.sh daemon|apply|status
. /data/gw/svc_lib.sh 2>/dev/null

G=/config/usb_gadget/g1
UDC=11201000.usb
IF=rndis0
BR=br-lan
ADBD=adbd_usb
GATE=/data/config/usb

LOG() { echo "usb_mgr: $*" > /dev/kmsg 2>/dev/null
        echo "$(date +%m-%d\ %H:%M:%S) $*" >> /tmp/usb_mgr.log 2>/dev/null; }

conf_val() { # $1=key $2=factory default; 值域强制 0|1, 异常回退默认
    V=$(sed -n "s/^$1=//p" /data/gw/settings.conf 2>/dev/null | tail -1)
    [ -n "$V" ] || V=$(sed -n "s/^$1=//p" /data/gw/defaults.conf 2>/dev/null | tail -1)
    case "$V" in 0|1) echo "$V" ;; *) echo "$2" ;; esac
}

gate_get() { sed -n "s/[[:space:]]*option service_adb_enable '\([01]\)'.*/\1/p" "$GATE" 2>/dev/null | head -1; }

gate_set() { # $1=0|1; 改位后重启 adbd 使其重读配置(数秒内由 procd 回带)
    [ -f "$GATE" ] || return 0
    CUR=$(gate_get)
    [ "$CUR" = "$1" ] && return 0
    sed -i "s/\(option service_adb_enable '\)[01]\('\)/\1$1\2/" "$GATE" 2>/dev/null || return 1
    P=$(pidof $ADBD 2>/dev/null)
    [ -n "$P" ] && kill "$P" 2>/dev/null
    LOG "adb gate $CUR -> $1 (adbd restarting)"
}

console_start() {
    P=$(cat /tmp/usb_console.pid 2>/dev/null)
    [ -n "$P" ] && kill -0 "$P" 2>/dev/null && return 0
    ( while :; do
          /sbin/getty -L ttyGS0 115200 vt100 >/dev/null 2>&1
          sleep 2
      done ) &
    echo $! > /tmp/usb_console.pid
    LOG "console getty on ttyGS0 (keeper $!)"
}
console_stop() {
    P=$(cat /tmp/usb_console.pid 2>/dev/null)
    [ -n "$P" ] && kill "$P" 2>/dev/null
    rm -f /tmp/usb_console.pid
    pkill -f "getty -L ttyGS0" 2>/dev/null
    return 0
}

keepalive_alive() { pgrep -f "restart_usb[.]sh" >/dev/null 2>&1; }

usb_on() {
    keepalive_alive || nohup /etc/restart_usb.sh >/dev/null 2>&1 &
    pidof $ADBD >/dev/null 2>/dev/null || /etc/init.d/usb.init start >/dev/null 2>&1
    # UDC 绑定(已绑跳过; 重绑会让主机重新枚举)
    [ "$(cat $G/UDC 2>/dev/null)" = "$UDC" ] || echo "$UDC" > "$G/UDC" 2>/dev/null
    # 数据口: up + 桥入 LAN(防火墙 INPUT -i br-lan 已在 rc19 放行)
    if [ -d /sys/class/net/$IF ]; then
        ip link set $IF up 2>/dev/null
        brctl show $BR 2>/dev/null | grep -qw "$IF" || brctl addif $BR $IF 2>/dev/null
    else
        LOG "WARN: $IF absent (usb_net not loaded?)"
    fi
}
usb_off() {
    console_stop
    gate_set 0
    /etc/init.d/usb.init stop >/dev/null 2>&1
    pkill -f "restart_usb[.]sh" 2>/dev/null   # 必须先于解绑(否则 1s 内自动重绑)
    kill $(pidof $ADBD) 2>/dev/null
    echo "" > "$G/UDC" 2>/dev/null            # 解绑 = 主机侧设备消失
    if [ -d /sys/class/net/$IF ]; then
        brctl delif $BR $IF 2>/dev/null
        ip link set $IF down 2>/dev/null
    fi
    LOG "usb OFF (port dead)"
}

apply_state() {
    E=$(conf_val USB_ENABLED 1)
    A=$(conf_val USB_ADB 0)
    C=$(conf_val USB_CONSOLE 0)
    if [ "$E" = "1" ]; then
        usb_on
        gate_set "$A"
        if [ "$C" = "1" ]; then console_start; else console_stop; fi
    else
        usb_off
    fi
    echo "$E $A $C" > /tmp/usb_mgr.state
    LOG "apply: enabled=$E adb=$A console=$C"
}

cmd_status() {
    E=$(conf_val USB_ENABLED 1); A=$(conf_val USB_ADB 0); C=$(conf_val USB_CONSOLE 0)
    U=$(cat $G/UDC 2>/dev/null)
    S=$(cat /sys/class/udc/$UDC/state 2>/dev/null)
    BRM=0; brctl show $BR 2>/dev/null | grep -qw "$IF" && BRM=1
    FL=$(cat /sys/class/net/$IF/flags 2>/dev/null)
    IUP=0; case "$FL" in 0x*|0X*) [ $(( FL & 1 )) -ne 0 ] && IUP=1 ;; esac
    CARR=$(cat /sys/class/net/$IF/carrier 2>/dev/null)
    AD=0; pidof $ADBD >/dev/null 2>&1 && AD=1
    GT=$(gate_get); [ -n "$GT" ] || GT=-
    CG=0; pgrep -f "getty -L ttyGS0" >/dev/null 2>&1 && CG=1
    echo "enabled=$E adb=$A console=$C"
    echo "udc=${U:-none} state=${S:-none} bridge=$BRM ifup=$IUP carrier=${CARR:--} adbd=$AD gate=$GT getty=$CG"
}

case "$1" in
daemon)
    svc_lock usb_mgr /data/gw/usb_mgr.sh || exit 0
    LOG "daemon start"
    apply_state
    while :; do
        svc_hb usb_mgr
        if [ "$(conf_val USB_ENABLED 1)" = "1" ]; then
            # 矫正漂移: 主机反复插拔 / keepalive 崩溃 / 控制台 keeper 退出
            [ "$(cat $G/UDC 2>/dev/null)" = "$UDC" ] || echo "$UDC" > "$G/UDC" 2>/dev/null
            if [ -d /sys/class/net/$IF ]; then
                ip link set $IF up 2>/dev/null
                brctl show $BR 2>/dev/null | grep -qw "$IF" || brctl addif $BR $IF 2>/dev/null
            fi
            keepalive_alive || nohup /etc/restart_usb.sh >/dev/null 2>&1 &
            [ "$(conf_val USB_CONSOLE 0)" = "1" ] && console_start
        fi
        sleep 15
    done
    ;;
apply)  apply_state ;;
status) cmd_status ;;
*) echo "usage: $0 daemon|apply|status" >&2; exit 2 ;;
esac
