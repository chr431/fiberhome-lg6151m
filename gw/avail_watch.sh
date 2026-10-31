#!/bin/sh
# avail_watch.sh v1.0 — 秒级边缘侦测器(启发式可用性层)
#
# 设计动机(2026-10-31 判据审计轮): 采样器 10min 快照 + watchdog 30s 键控对
# <30s 的自愈型中断存在"零面包屑"盲区 —— dnsmasq/hostapd 秒级死亡-重启、eth0
# 载波抖动、GUI 秒级停服: 事件不进任何日志也不落在快照上, GUI 与台账双失真。
# 本守护以 2s 节奏轮询 6 个廉价事实, 仅在状态翻转(2 拍确认=4s 磁滞, 滤单读
# 抖动)时写一行边缘事件; 采样器窗口收割边缘行 → 组件窗口降级 + 合成事件表
# 行(带精确时长), 秒级问题从"不可见"变为"计数+时长+时间戳"。
#
# 启发式取舍(性能优先):
#   - 每轮仅 /proc//sys 小文件读 + 2 个 grep(CPU 可忽略; 2s 节拍折中"秒级
#     可见性"与"零意义轮询");
#   - 真实 HTTP GET 30s 一次(静态路径, 不触发 CGI fork), 顺带轮转 v3httpd.log;
#   - SSH banner 600s 一次(dropbear 每次会记 authpriv 行, 高频=日志污染);
#   - 边缘台账 4000 行上限轮转(采样器游标对收缩已有 head 近似分支)。
#
# 事实集 → 组件映射(采样器侧 EDGE_COMPS 同源):
#   gui.serve   GET / = 200            → sys.gui
#   ssh.banner  :22 banner 可读         → sys.ssh    (关闭 2026-10-31 前的
#                                                "仅监听不可验证"盲区)
#   dns.pids    dnsmasq 进程在          → lan.bridge
#   br.up       br-lan IFF_UP           → lan.bridge
#   wpa.ra0     hostapd ra0 活控制套接字 → lan.wifi2g
#   wpa.rai0    hostapd rai0 活控制套接字 → lan.wifi5g
#   eth.carrier eth0 carrier=1          → wan.ethernet
#
# 边缘行格式(可用性边缘台账 /data/gw/logs/avail_edges.tsv):
#   epoch  iso8601  id  edge_down|edge_up  detail
# 首次观测为基线(不出边缘)—— 开机服务依次拉起不产生噪声; 未拉起由快照层如实
# 扣分。boot 窗口(<120s)同样只建基线不判翻转(拨号/载波建立期抖动属正常序列)。
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=busybox
EDGES=/data/gw/logs/avail_edges.tsv
HTTPDLOG=/tmp/v3httpd.log
INT=2          # 轮询节拍(秒)
CONFIRM=2      # 翻转确认拍数(磁滞 4s)
mkdir -p /data/gw/logs 2>/dev/null
# batch3 单实例原语; hb 每 15 拍(30s)写一次(SVC_TABLE max 120s)
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else echo "avail_watch: svc_lib.sh missing" >&2; exit 1; fi
_rc=0; svc_lock avail_watch /data/gw/avail_watch.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    [ "$_rc" = 1 ] && echo "avail_watch: already running" >&2 || echo "avail_watch: lost lock race" >&2
    exit 0
fi
touch "$EDGES" 2>/dev/null   # 健康态(零翻转)也要让台账在位(采样器游标/selftest 护栏)

logf() { echo "$(date +%s) $(date '+%F %T') $*" >> "$EDGES"; }
edge() { # $1=id $2=event $3=detail
    logf "$1 $2 $3"
    _n=$(wc -l < "$EDGES" 2>/dev/null)
    case "$_n" in *[!0-9]*) _n=0 ;; esac
    [ "$_n" -gt 4000 ] && { tail -n 2000 "$EDGES" > "$EDGES.tmp" 2>/dev/null && mv -f "$EDGES.tmp" "$EDGES"; }
}

# ---- 事实读取(全部有界、只读) ----
r_gui() { $BB wget -q -O /dev/null -T 3 http://127.0.0.1/ && echo 1 || echo 0; }
r_ssh() { _b=$($BB timeout 3 $BB nc 127.0.0.1 22 </dev/null 2>/dev/null | head -c 4)
          case "$_b" in SSH-*) echo 1 ;; *) echo 0 ;; esac; }
r_dns() { [ -n "$($BB pidof dnsmasq 2>/dev/null)" ] && echo 1 || echo 0; }
r_wpa2() { grep -q " /var/run/hostapd/ra0\$" /proc/net/unix 2>/dev/null && echo 1 || echo 0; }
r_wpa5() { grep -q " /var/run/hostapd/rai0\$" /proc/net/unix 2>/dev/null && echo 1 || echo 0; }
r_eth() { case "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" in 1) echo 1 ;; *) echo 0 ;; esac; }
r_br()  { _f=$(cat /sys/class/net/br-lan/flags 2>/dev/null)
          case "$_f" in 0x*|0X*) [ $((_f & 1)) -ne 0 ] && echo 1 || echo 0 ;; *) echo 0 ;; esac; }

# ---- 通用磁滞状态机 ----
# st_*: 已确认状态(-1=未建基线); pv_*: 上一拍原始值; ct_*: 连续异值拍数
# update <name> <raw>: 翻转经 CONFIRM 拍确认后出边缘
update() {
    _n=$1 _r=$2
    eval "_s=\$st_$_n _p=\$pv_$_n _c=\$ct_$_n"
    [ -z "$_s" ] && _s=-1
    [ -z "$_p" ] && _p=$_r
    [ -z "$_c" ] && _c=0
    if [ "$_r" = "$_s" ]; then
        _c=0
    elif [ "$_r" = "$_p" ]; then
        _c=$((_c + 1))
    else
        _c=1
    fi
    if [ "$_s" != -1 ] && [ "$_c" -ge "$CONFIRM" ]; then
        if [ "$_r" = 1 ]; then edge "$_n" edge_up ""; else edge "$_n" edge_down ""; fi
        _s=$_r; _c=0
    fi
    eval "st_$_n=$_s pv_$_n=$_r ct_$_n=$_c"
}

BOOT_UNTIL=$(($(cut -d. -f1 /proc/uptime) + 120))
i=0
gui_v=1; ssh_v=1
while :; do
    i=$((i + 1))
    [ $((i % 15)) -eq 1 ] && svc_hb avail_watch
    # 高成本事实降频(30s / 600s), 间拍沿用上次值
    [ $((i % 15)) -eq 1 ] && gui_v=$(r_gui)
    [ $((i % 300)) -eq 1 ] && ssh_v=$(r_ssh)
    if [ "$(cut -d. -f1 /proc/uptime)" -lt "$BOOT_UNTIL" ]; then
        # boot 窗: 只建基线
        st_gui=$gui_v st_ssh=$ssh_v st_dns=$(r_dns) st_wpa2=$(r_wpa2)
        st_wpa5=$(r_wpa5) st_eth=$(r_eth) st_br=$(r_br)
    else
        update gui "$gui_v"
        update ssh  "$ssh_v"
        update dns  "$(r_dns)"
        update wpa2 "$(r_wpa2)"
        update wpa5 "$(r_wpa5)"
        update eth  "$(r_eth)"
        update br   "$(r_br)"
    fi
    # 顺带轮转 v3httpd.log(30s 一次的 GET 探测是它的主要写入方)
    if [ $((i % 450)) -eq 1 ] && [ -f "$HTTPDLOG" ]; then
        _sz=$(wc -c < "$HTTPDLOG" 2>/dev/null)
        case "$_sz" in *[!0-9]*) _sz=0 ;; esac
        [ "$_sz" -gt 262144 ] && { tail -n 2000 "$HTTPDLOG" > "$HTTPDLOG.tmp" 2>/dev/null && mv -f "$HTTPDLOG.tmp" "$HTTPDLOG"; }
    fi
    sleep "$INT"
done
