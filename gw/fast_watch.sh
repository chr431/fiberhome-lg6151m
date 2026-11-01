#!/bin/sh
# fast_watch.sh v1.1 -- 1s 状态真值总线 (M2 传感器 / M3 数据源 / GUI+LED 状态源)
# v1.1: ① 每 60 拍限时驱动 M3 消费者 svc_outage.sh tick(单次带 tail 增量游标, 幂等; 没这个调用点设备侧 svc_outages.tsv 永不产生);
#   ② 每 30 拍往 lag_audit.tsv 写一行 stage=beat 心跳(不带 lag_ms= 故不进 p50/p99) —— 审计管道自证在记账, 否则「没有迁移」与「审计坏了」无法区分
#
# 为什么存在(RELIABILITY_SPEC R2.1-R2.7, AVAILABILITY_DESIGN §8.1 病理):
#   旧链路最坏滞后是分钟级: watchdog 30s 周期判据 -> /tmp/watchdog_state(迁移式快照)
#   -> avail_sampler 10min -> avail_watch 2s 边缘 -> GUI 3s/8s 轮询 -> led_mgr 2s 但输入陈旧。
#   四次"账面全绿而实际已死"的共同根因是 **检测太慢 + 判据只有存在性**: 采样间隔内
#   死过又自愈的故障, 采样时快照已回绿, 账面恒绿。本守护把"检测"压到 1s 节拍,
#   把每拍事实落成可复核台账; GUI/LED/API 一律只读它的产物(单一状态源, 禁止各自另算)。
#
# 产出(全部由本进程独占写入, 其它进程只读):
#   /data/gw/run/state.json          状态真值(原子 rename; 迁移时 + 启动时写)
#   /data/gw/run/state.led           state.json 的 LED 投影(同一次发布, 原子 rename)
#   /data/gw/logs/state_events.tsv   迁移流(每次迁移一行, 持久)
#   /data/gw/logs/lag_audit.tsv      时延审计(stage=detect/publish/gui/led; append-only)
#   /data/gw/logs/fast_facts.tsv     每拍每探针判定(失败全记 + 60s 心跳行; M3 消费)
#   /data/gw/logs/avail_edges.tsv    边缘行(供 avail_sampler 窗口收割, 沿用其字段位置)
#   /tmp/fast_watch.beat             每拍心跳(新鲜度判据; tmpfs, 零闪存磨损)
#
# 判据分级(R2.6, AVAILABILITY_DESIGN §8.2): 每组件带 crit=L1|L2|L2+|L3 并随状态发布。
#   L1=存在性(进程/端口/IP 在) —— L1-only 组件不得显示为绿, GUI 渲染为"仅存在性"。
#   L2=协议真实应答; L3=端到端数据面/结果。级别由 GUI 与审计共同消费, 不在这里渲染。
#
# 设计纪律(本项目血泪):
#   * ash 无 local —— 所有 helper 变量用固定前缀(_fw_ _sm_ _pb_ _lg_ _ev_ _fd_), 禁止裸变量名
#     (avail_watch v1.4 实弹: 轮转计数踩掉事实名 -> 状态写回错位, 重复 down 永无 up);
#   * 每拍成本有界: 廉价事实走 shell 内建 read + **单次 awk** 扫 4 个 /proc; 网络探针
#     按不同节拍错峰(tcp80 每拍 / dns 2 拍 / icmp 6 拍 / http200 10 拍 / ssh banner 300 拍);
#   * 探针目标只用 192.168.9.1 —— v3httpd 只绑 LAN IP, 127.0.0.1:80 恒拒连(实弹教训);
#   * 磁滞: 文件/监听类事实确定性, 1 拍即认; 网络探针 2 拍确认(滤单包抖动)。
#     磁滞只延后"宣告", 不延后"检测" —— 两者在 lag_audit 分别记账, 不混淆;
#   * 判活权威唯一: 上行/蜂窝的 L3 只消费 wan_agg 的 /tmp/wan_alive, 本进程不另起判据;
#   * 时间: 设备无 RTC, /tmp/ntp_synced 缺失时 fast_facts 行带 pre=1(与 sampler/NE 台账同款),
#     避免假日期桶污染跨源对齐。
#
# 用法:
#   sh fast_watch.sh            常驻(由 watchdog 经 svc_lib SVC_TABLE 监督)
#   sh fast_watch.sh --once     采样一次, 打印状态 JSON 到 stdout(不写任何文件)
#   sh fast_watch.sh --dry N    跑 N 拍, 每拍打印摘要(不写任何文件; 现场零副作用)

BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=busybox
TCP=/data/gw/bin/tcpok
D=/data/gw
RUN=$D/run
LOGD=$D/logs
STATE=$RUN/state.json
LEDF=$RUN/state.led
EVT=$LOGD/state_events.tsv
LAG=$LOGD/lag_audit.tsv
FACTS=$LOGD/fast_facts.tsv
EDGES=$LOGD/avail_edges.tsv
BEAT=/tmp/fast_watch.beat
GUI_IP=192.168.9.1
INT=100
# 边缘台账契约的唯一实现(字段位置 + id 常量 + 解析/写入); 与 avail_sampler 共用一份
if [ -r "$D/state_edge_lib.sh" ]; then . "$D/state_edge_lib.sh"; else
    echo "fast_watch: state_edge_lib.sh missing -- refusing (edge contract would drift)" >&2
    exit 1
fi

# ---- 组件键表(发布顺序即 GUI 顺序) --------------------------------------
KEYS="supervisor observability boot gui ssh bridge wifi2g wifi5g ethernet cellular led fan ntp netlock usb logging"
c_id()   { case "$1" in supervisor) echo sys.supervisor;; observability) echo sys.observability;;
    boot) echo sys.boot;; gui) echo sys.gui;; ssh) echo sys.ssh;; bridge) echo lan.bridge;;
    wifi2g) echo lan.wifi2g;; wifi5g) echo lan.wifi5g;; ethernet) echo wan.ethernet;;
    cellular) echo wan.cellular;; led) echo feat.led;; fan) echo feat.fan;; ntp) echo feat.ntp;;
    netlock) echo sys.netlock;; usb) echo feat.usb;; logging) echo sys.logging;; esac; }
c_name() { case "$1" in supervisor) echo "监督层";; observability) echo "观测层(状态总线)";;
    boot) echo "启动链";; gui) echo "网关 GUI";; ssh) echo "SSH 管理";; bridge) echo "LAN 桥/DHCP/DNS";;
    wifi2g) echo "WiFi 2.4G";; wifi5g) echo "WiFi 5G";; ethernet) echo "以太 WAN";;
    cellular) echo "5G 蜂窝";; led) echo "指示灯";; fan) echo "温控/风扇";; ntp) echo "NTP 守时";;
    netlock) echo "配置写锁";; usb) echo "USB 设备模式";; logging) echo "日志管线";; esac; }
c_grp()  { case "$1" in supervisor|observability|boot|gui|ssh|netlock|logging) echo "系统";;
    bridge|wifi2g|wifi5g) echo "局域网";; ethernet|cellular) echo "上行";;
    led|fan|ntp|usb) echo "功能面";; esac; }
c_crit() { case "$1" in
    gui) echo "L2+";; ssh) echo "L2";; supervisor) echo "L2";; observability) echo "L2";;
    boot) echo "L2";; bridge) echo "L2";; wifi2g|wifi5g) echo "L2+";;
    ethernet|cellular) echo "L3";; led) echo "L3";; logging) echo "L2";; netlock) echo "L2";;
    fan) echo "L1";; usb) echo "L1";; ntp) echo "L2";; *) echo "L1";; esac; }
c_det()  { case "$1" in
    gui) echo "tcp80@1s+l80listen@1s+http200@10s";; ssh) echo "l22listen@1s+banner@300s";;
    supervisor) echo "watchdog.beat@1s";; observability) echo "avail_sampler.hb@1s";;
    boot) echo "boot.healthy+bootgate键@5s";; bridge) echo "brflags@1s+l53listen@1s+dns@2s";;
    wifi2g) echo "hostapd-sock@1s+ra0flags@1s";; wifi5g) echo "hostapd-sock@1s+rai0flags@1s";;
    ethernet) echo "carrier@1s+wan_alive@1s";; cellular) echo "ccmni-route@1s+wan_alive@1s";;
    led) echo "led_mgr.hb@1s+gpio读回";; fan) echo "fan_mgr.hb@1s";;
    ntp) echo "ntp_synced+ntp_keeper.hb@1s";; netlock) echo "netlock键@5s";;
    usb) echo "usb_mgr.hb@1s";; logging) echo "log_keeper.hb@1s";; esac; }

# ---- 时钟: 厘秒(10ms)与 epoch_ms 同源, 全部免 fork -----------------------
# /proc/uptime 只有 2 位小数 -> 10ms 分辨率; epoch 秒每 10 拍用 date 校准,
# 中间用 uptime 差值内插(NTP 跳变 10s 内自愈; 跨源对齐仍需共同锚点, 见 STATE_BUS.md)
CS=0; EP=0; EP_CS=0; UPS=0
now_cs() {
    # /proc/uptime 形如 18512.69 66330.05 —— 必须只取小数部分前两位;
    # 直接 IFS=. read 会把第二字段读成 "69 66330"(含负载值), 厘秒算错(自查实弹抓获)。
    IFS= read -r _fw_raw < /proc/uptime
    _fw_i=${_fw_raw%%.*}
    _fw_t=${_fw_raw#*.}
    _fw_f=${_fw_t%%[!0-9]*}
    case "$_fw_f" in ??) ;; ?) _fw_f=${_fw_f}0 ;; *) _fw_f=00 ;; esac
    case "$_fw_i" in ''|*[!0-9]*) _fw_i=0 ;; esac
    # ⚠ P0 根因(2026-11-01 03:05, svc-probe 实弹定位): busybox ash 把**前导 0 的数当八进制**。
    #   uptime 小数前两位为 08/09 时 $(( )) 报 arithmetic syntax error 并让整个脚本退出(2),
    #   每 100s 命中 2 次(实测 ~50s 一次) —— 这就是 M2 P0 全部「神秘退出」的真因。
    #   修法: 进 $(( )) 一律 10# 强制十进制 + 空值兜底。
    # shell 无关归一(不依赖 10#): 去掉前导零, 使任何 ash 都不会当八进制。
    #   设备上有两个 busybox: /bin/sh(厂商, **不支持 10#**) 与 /data/gw/bin/busybox(自建, 支持);
    #   依赖 10# 就会依赖 PATH 顺序, 很脆。
    _fw_f=${_fw_f#0}; [ -n "$_fw_f" ] || _fw_f=0
    CS=$(( _fw_i * 100 + _fw_f ))
    UPS=$_fw_i
}
ep_ms() { _fw_ms=$(( EP * 1000 + ( $1 - EP_CS ) * 10 )); }
now_ep() { EP=$(date +%s); EP_CS=$CS; }

# ---- 有界文件读取(免 fork) ----------------------------------------------
# rd <file> -> _fw_v; 空 = 缺失/读失败(不保留旧值, 避免陈旧变量冒充事实)
rd() { _fw_v=""; { IFS= read -r _fw_v < "$1"; } 2>/dev/null || _fw_v=""; }

# ---- 台账工具 -----------------------------------------------------------
rotate_if() {  # $1=file $2=maxlines
    [ -r "$1" ] || return 0
    _fw_n=$("$BB" wc -l < "$1" 2>/dev/null)
    case "$_fw_n" in ''|*[!0-9]*) return 0 ;; esac
    [ "$_fw_n" -gt "$2" ] || return 0
    "$BB" tail -n $(( $2 / 2 )) "$1" > "$1.tmp" 2>/dev/null && mv -f "$1.tmp" "$1"
}

# ---- 采样: 每拍廉价事实 ------------------------------------------------
# 单次 awk 扫 4 个 /proc(1 fork): hostapd 活套接字 / 默认路由承载口 / 监听位 / accept 队列
F_s0=0; F_s1=0; F_l80=0; F_l22=0; F_l53=0; F_bl22=0; F_r_eth=0; F_r_ccm=0
scan_proc() {
    _fw_out=$("$BB" awk '
      FNR==1 { next }
      FILENAME=="/proc/net/unix" {
        if ($NF=="/var/run/hostapd/ra0") s0=1
        else if ($NF=="/var/run/hostapd/rai0") s1=1
        next
      }
      FILENAME=="/proc/net/route" {
        if ($2=="00000000" && $8=="00000000") {
          if ($1=="eth0") re=1
          else if (substr($1,1,5)=="ccmni") rc=1
        }
        next
      }
      {
        if ($4=="0A") {
          p=substr($2,length($2)-3)
          if (p=="0050") l80++
          else if (p=="0016") { l22++; if ($5!="00000000:00000000") bl22++ }
          else if (p=="0035") l53++
        }
      }
      END { printf "%d %d %d %d %d %d %d %d\n", s0+0, s1+0, l80+0, l22+0, l53+0, bl22+0, re+0, rc+0 }
    ' /proc/net/unix /proc/net/route /proc/net/tcp /proc/net/tcp6 2>/dev/null)
    case "$_fw_out" in ''|*[!0-9\ ]*) return 1 ;; esac
    set -- $_fw_out
    [ $# -eq 8 ] || return 1
    F_s0=$1; F_s1=$2; F_l80=$3; F_l22=$4; F_l53=$5; F_bl22=$6; F_r_eth=$7; F_r_ccm=$8
    return 0
}

# ---- tier-A 快车道(客户端面 ≤10s) ----------------------------------------
#   实测约束(2026-11-01 实弹):
#     * v3httpd 是 **fork-per-connection**(gw/src/v3httpd.c L389), fork 出来的 handler 子进程
#       cmdline 与父进程相同 -> pgrep/pidof 会数到 N+1, 不能用来判死; 判据必须是 **:80 有 LISTEN**。
#     * dnsmasq 单进程, 用进程存在 + :53 listener。
#     * hostapd 用**我方实例**(argv 带 /var/wlan/hap_*.conf), 厂商全局实例常驻, pidof 会假绿。
#   动作方式: 本函数**只踢 watchdog**(写 /tmp/watchdog.kick), 不自己重启 ——
#     重启配方只存在于 watchdog 一处, 避免两套监督逻辑打架/双实例; watchdog 收到 kick 立即跑一轮,
#     档A(进程不存在=强证据)保证同一拍重启。预算(rl_ok 3/h)仍由 watchdog 统一把关。
#   2 拍确认: 连续 FL_CONFIRM 拍判定死亡才踢, 防 fork 瞬态/端口回收窗口误判。
FL_CONFIRM=2
fl_check() { # $1=key $2=alive(1=活/0=死)
    eval "_fl_n=\${FLN_$1:-0}"
    if [ "$2" = 1 ]; then
        [ "$_fl_n" != 0 ] && printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "recovered after ${_fl_n}ticks" >> "$LOGD/fast_kick.tsv"
        eval "FLN_$1=0"
        return 0
    fi
    _fl_n=$(( _fl_n + 1 ))
    eval "FLN_$1=$_fl_n"
    if [ "$_fl_n" -eq "$FL_CONFIRM" ]; then
        : > /tmp/watchdog.kick
        printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "absent ${_fl_n}ticks -> kick watchdog" >> "$LOGD/fast_kick.tsv"
    fi
}
fast_lane() {
    [ "$DRY" = 1 ] && return 0
    # 判据必须用**已有的真实量**, 不能写想当然的变量名——
    #   实弹(自查): 初版写了 F_dnsmasq/F_hostapd, 而这两个变量根本不存在 ->
    #   每拍都读到空串 = 判死 = 每 2 拍踢一次 watchdog(会把 30s 循环变成 1s 循环并反复重启真服务)。
    #   scan_proc 已经给出权威量: F_l80(:80 LISTEN) F_l53(:53 LISTEN)
    #   F_s0(/var/run/hostapd/ra0 活套接字) F_s1(/var/run/hostapd/rai0 活套接字)。
    fl_check v3httpd "$F_l80"      # :80 有 LISTEN 才算活(fork 出来的 handler 子进程不算)
    fl_check dnsmasq "$F_l53"      # :53 有 LISTEN 才算活
    fl_check hostapd "$(( F_s0 & F_s1 ))"  # 两个 AP 控制套接字都在才算活
}
F_car0=0; F_br=0; F_ra0=0; F_rai0=0; F_lo=0
scan_links() {
    rd /sys/class/net/eth0/carrier;  case "$_fw_v" in 1) F_car0=1 ;; *) F_car0=0 ;; esac
    rd /sys/class/net/br-lan/flags
    case "$_fw_v" in 0x*|0X*) if [ $(( _fw_v & 1 )) -ne 0 ]; then F_br=1; else F_br=0; fi ;; *) F_br=0 ;; esac
    rd /sys/class/net/ra0/flags
    case "$_fw_v" in 0x*|0X*) if [ $(( _fw_v & 1 )) -ne 0 ]; then F_ra0=1; else F_ra0=0; fi ;; *) F_ra0=0 ;; esac
    rd /sys/class/net/rai0/flags
    case "$_fw_v" in 0x*|0X*) if [ $(( _fw_v & 1 )) -ne 0 ]; then F_rai0=1; else F_rai0=0; fi ;; *) F_rai0=0 ;; esac
    rd /sys/class/net/lo/flags
    case "$_fw_v" in 0x*|0X*) if [ $(( _fw_v & 9 )) -eq 9 ]; then F_lo=1; else F_lo=0; fi ;; *) F_lo=0 ;; esac
}
# 上行判活的唯一权威: wan_agg 发布的 /tmp/wan_alive(本进程只消费, 不另立判据)
F_home=0; F_cell=0; F_wanage=999999
scan_wan() {
    rd /tmp/wan_alive
    case "$_fw_v" in *home=1*) F_home=1 ;; *) F_home=0 ;; esac
    case "$_fw_v" in *cell=1*) F_cell=1 ;; *) F_cell=0 ;; esac
    F_wanage=999999
    for _fw_w in $_fw_v; do
        case "$_fw_w" in
            hb=*) _fw_hb=${_fw_w#hb=}
                  case "$_fw_hb" in ''|*[!0-9]*) ;; *) F_wanage=$(( UPS - _fw_hb )); [ "$F_wanage" -lt 0 ] && F_wanage=999999 ;; esac ;;
        esac
    done
}
# hb_of <file> -> _fw_hba (守护心跳年龄; 缺失/坏值=999999)
hb_of() {
    _fw_hba=999999
    rd "$1"
    case "$_fw_v" in ''|*[!0-9]*) return 0 ;; esac
    _fw_hba=$(( UPS - _fw_v ))
    [ "$_fw_hba" -lt 0 ] && _fw_hba=999999
}
# watchdog_state 键(每 5 拍读一次: netlock/bootgate; 40 行 shell 遍历约 4ms)
F_netlock=0; F_bootgate=0; WD_OK=0
scan_wd() {
    WD_OK=0; F_netlock=0; F_bootgate=0
    [ -r /tmp/watchdog_state ] || return 0
    WD_OK=1
    while IFS= read -r _fw_l; do
        case "$_fw_l" in
            netlock=*)  F_netlock=${_fw_l#netlock=} ;;
            bootgate=*) F_bootgate=${_fw_l#bootgate=} ;;
        esac
    done < /tmp/watchdog_state
    case "$F_netlock" in 0|1) ;; *) F_netlock=0 ;; esac
    case "$F_bootgate" in 0|1) ;; *) F_bootgate=0 ;; esac
}
# LED 读回校验结果(led_mgr 每次写 GPIO 后发布; R2.4)
F_ledver=0; F_ledok=1; F_ledage=999999
scan_led() {
    F_ledage=999999
    rd /tmp/led_mgr.verify
    case "$_fw_v" in
        ver=*)
            for _fw_w in $_fw_v; do
                case "$_fw_w" in
                    ver=*) F_ledver=${_fw_w#ver=} ;;
                    ok=*)  F_ledok=${_fw_w#ok=} ;;
                    up=*)  _fw_u=${_fw_w#up=}; F_ledage=$(( UPS - _fw_u )); [ "$F_ledage" -lt 0 ] && F_ledage=999999 ;;
                esac
            done ;;
    esac
    case "$F_ledok" in 0|1) ;; *) F_ledok=1 ;; esac
}

# ---- 网络探针(按节拍错峰; 只有这 5 个探针会 fork) ---------------------
F_tcp80=0; FL_tcp80=0
F_dns=1;   FL_dns=0;   AGE_dns=999
F_icmp=1;  FL_icmp=0;  AGE_icmp=999
F_http=1;  FL_http=0;  AGE_http=999
F_ssh2=1;  FL_ssh2=0;  AGE_ssh2=999
GW_NH=""
probe_tcp80() {
    _fw_c0=$CS
    if "$TCP" "$GUI_IP" 80 400 >/dev/null 2>&1; then F_tcp80=1; else F_tcp80=0; fi
    now_cs; FL_tcp80=$(( (CS - _fw_c0) * 10 ))
}
probe_dns() {
    # 判据 = DNS 服务接受连接(L2)。v1.9(实弹定位): 原实现每两拍嵌套两层 busybox
    # (timeout + nslookup)。实测周期性 exit=2 退出全部落在奇数拍(31/37/69), 而奇数拍恰好
    # 就是 probe_dns 的拍; v1.8 的 STEP 台账定位到 step=sample。现改用与 tcp80 同款的静态件
    # tcpok(裸 TCP connect, 无嵌套 busybox、无信号)。判据降为 L2(接受连接); 真实 DNS
    # 应答仍由 watchdog 的 dnssvc 键(30s, 已入窗口收割)覆盖 —— 分工与 gui 的 tcp80/http200 同款。
    _fw_c0=$CS
    if "$TCP" "$GUI_IP" 53 400 >/dev/null 2>&1; then F_dns=1; else F_dns=0; fi
    now_cs; FL_dns=$(( (CS - _fw_c0) * 10 )); AGE_dns=0
}
probe_icmp() {
    # 上行下一跳 ICMP: 只作归因事实(wan.icmp), 不单独决定任何组件级别
    [ -n "$GW_NH" ] || return 0
    _fw_c0=$CS
    if "$BB" ping -c1 -W1 "$GW_NH" >/dev/null 2>&1; then F_icmp=1; else F_icmp=0; fi
    now_cs; FL_icmp=$(( (CS - _fw_c0) * 10 )); AGE_icmp=0
}
probe_http() {
    # 真实 HTTP 200(L2+): 10 拍一次(每次 GET 在 v3httpd 侧留一行日志; 10s 节拍约 8.6k 行/日)
    _fw_c0=$CS
    if "$BB" wget -q -T 1 -O /dev/null "http://$GUI_IP/" >/dev/null 2>&1; then F_http=1; else F_http=0; fi
    now_cs; FL_http=$(( (CS - _fw_c0) * 10 )); AGE_http=0
}
probe_ssh2() {
    # SSH L2(协议真实应答): 读 banner。300 拍一次 —— dropbear 每次连接记一条 authpriv 行,
    # 高频探测=日志污染(沿用 avail_watch 600s 取舍, 这里 300s 换更短盲区)。
    _fw_c0=$CS
    _fw_b=$("$BB" timeout -s KILL 1 "$BB" nc 127.0.0.1 22 </dev/null 2>/dev/null | "$BB" head -c 4)
    case "$_fw_b" in SSH-*) F_ssh2=1 ;; *) F_ssh2=0 ;; esac
    now_cs; FL_ssh2=$(( (CS - _fw_c0) * 10 )); AGE_ssh2=0
}
nexthop() {
    GW_NH=$("$BB" awk 'NR>1 && $2=="00000000" && $8=="00000000" && $1=="eth0" {g=$3}
      END { if (g!="") printf "%d.%d.%d.%d", ("0x" substr(g,7,2))+0, ("0x" substr(g,5,2))+0, ("0x" substr(g,3,2))+0, ("0x" substr(g,1,2))+0 }' /proc/net/route 2>/dev/null)
    case "$GW_NH" in *[!0-9.]*|"") GW_NH="" ;; esac
}

# ---- 演练标记(drills.tsv: start/end/kind/target/owner/note; end=0 表示进行中) ----
# lead v1.2 契约: 与演练窗口重叠的迁移/时延行打 drill=1(不影响 GUI 实时显示, 只影响验收统计)
DRILL=0
scan_drill() {
    DRILL=0
    [ -r "$LOGD/drills.tsv" ] || return 0
    _fw_now=$(date +%s)
    _dr_need=0
    _dr_warned="${_dr_warned:-}"
    while IFS="$TAB" read -r _fw_s _fw_e _fw_k _fw_t _fw_o _fw_n; do
        # 消费方加固(lead 2026-11-01 10:10, 今天第四个"集合比目标大"实例):
        #   空行 / CR 残片 / 碎片行一律跳过 —— 判据 = 至少 5 列 且 $1/$2 都是纯数字。
        #   绝不能把"$2 非数字"默认成 0: 那会把 CR 残片当成"未闭合演练窗口",
        #   误把整段时间标成 drill=1(排除真实故障), 也会阻塞 drill.py 开窗。
        case "$_fw_s" in ''|*[!0-9]*) continue ;; esac
        case "$_fw_e" in ''|*[!0-9]*) continue ;; esac
        [ -n "$_fw_o" ] || continue
        # ⚠ v2.7 (2026-11-01 10:09 P0 止血): **自动闭合功能已彻底移除**。
        #   事故: 该逻辑每 5 拍用 awk 重写整张 drills.tsv, 与其它流的并发追加竞争,
        #   把台账写坏(874 行空行, 全部历史演练窗口丢失, M3 排除层失效)。
        #   教训: **共享台账文件禁止整文件重写** —— 多写方场景下只有「只追加」是安全的。
        #   现在的行为: 只读判断(下面那行 DRILL 标志), 绝不写 drills.tsv。
        if [ "$_fw_e" -eq 0 ] && [ $(( _fw_now - _fw_s )) -gt 3600 ]; then
            # 只记一次告警(不重写台账), 让"忘记回填"可见而不是静默
            case " $_dr_warned " in
            *" $_fw_s "*) ;;
            *) _dr_warned="$_dr_warned $_fw_s"
               printf '%s	WARN	open window start=%s older than 3600s (no rewrite; fix by hand)
' "$_fw_now" "$_fw_s" >> "$LOGD/drills_autoclose.log" ;;
            esac
            continue
        fi
        if [ "$_fw_now" -ge "$_fw_s" ]; then
            if [ "$_fw_e" -eq 0 ] || [ "$_fw_now" -le "$_fw_e" ]; then DRILL=1; fi
        fi
    done < "$LOGD/drills.tsv"
}

# ---- 状态机 -------------------------------------------------------------
# LV_<k> 当前级别 / PV_<k> 上一级别 / SI_<k> since(cs) / CN_<k> 连续候选计数 /
# CD_<k> 候选级别 / LG_<k> 最近一次"与当前级别一致"的采样(cs) / CF_<k> 候选首现(cs)
BASE=1; DIRTY=1; FLAGS="-"; VER=1
TAB=$(printf '\t')

ev_iso() { _ev_i=$("$BB" date '+%F %T' 2>/dev/null); [ -z "$_ev_i" ] && _ev_i="-"; }
ev_iso_c() { _ev_c=$("$BB" date '+%FT%T' 2>/dev/null); [ -z "$_ev_c" ] && _ev_c="-"; }
ev_of() {  # 组件可复核证据串(只在迁移/发布时调用; 允许 fork)
    case "$1" in
    supervisor)    echo "wdbeat_age=${F_wdage}s";;
    observability) echo "sampler_age=${F_smage}s";;
    boot)          echo "healthy=${F_healthy},bootgate=${F_bootgate}";;
    gui)           echo "tcp80=${F_tcp80},l80=${F_l80},http200=${F_http},http_age=${AGE_http}t,ms=${FL_tcp80}";;
    ssh)           echo "l22=${F_l22},bl=${F_bl22},banner=${F_ssh2},banner_age=${AGE_ssh2}t";;
    bridge)        echo "br=${F_br},l53=${F_l53},dns=${F_dns},dns_age=${AGE_dns}t";;
    wifi2g)        echo "sock=${F_s0},ra0=${F_ra0}";;
    wifi5g)        echo "sock=${F_s1},rai0=${F_rai0}";;
    ethernet)      echo "carrier=${F_car0},home=${F_home},wan_age=${F_wanage}s,icmp=${F_icmp}";;
    cellular)      echo "ccmni_route=${F_r_ccm},cell=${F_cell},wan_age=${F_wanage}s";;
    led)           echo "hb=${F_ledhb}s,verify_age=${F_ledage}s,verify_ok=${F_ledok},ver=${F_ledver}";;
    fan)           echo "hb=${F_fanhb}s";;
    ntp)           echo "synced=${F_ntpsync},hb=${F_ntphb}s";;
    netlock)       echo "lock=${F_netlock}";;
    usb)           echo "hb=${F_usbhb}s";;
    logging)       echo "hb=${F_lkhb}s";;
    *)             echo "-";; esac
}
# emit_lag <key> <stage> <t_ref_cs> <t_cs> <note>
emit_lag() {
    ep_ms "$3"; _lg_r=$_fw_ms
    ep_ms "$4"; _lg_t=$_fw_ms
    [ "$DRY" = 1 ] && return 0
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_lg_t" "$VER" "$(c_id "$1")" "$2" "$_lg_r" "$_lg_t" "$5" >> "$LAG"
}
# emit_trans <key> <from> <to> <lastgood_cs> <detect_cs>
emit_trans() {
    ep_ms "$5"; _ev_d=$_fw_ms
    ep_ms "$4"; _ev_g=$_fw_ms
    ep_ms "$CS"; _ev_p=$_fw_ms
    ev_iso
    if [ "$DRY" = 1 ]; then
        echo "[dry] TRANS $1 $2->$3 detect_ms=$(( _ev_d - _ev_g )) pub_ms=$(( _ev_p - _ev_d ))" >&2
        return 0
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$(( _ev_d / 1000 ))" "$_ev_i" "$VER" "$(c_id "$1")" "$2" "$3" "$(c_crit "$1")" "$FLAGS" "$(ev_of "$1")" >> "$EVT"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_ev_d" "$VER" "$(c_id "$1")" "detect" "$_ev_g" "$_ev_d" "lag_ms=$(( _ev_d - _ev_g ))" >> "$LAG"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_ev_p" "$VER" "$(c_id "$1")" "publish" "$_ev_g" "$_ev_p" "lag_ms=$(( _ev_p - _ev_g ))" >> "$LAG"
}
# setlvl <key> <candidate> <confirm_n>
setlvl() {
    _sm_k=$1; _sm_c=$2; _sm_n=$3
    eval "_sm_cur=\$LV_$_sm_k"
    if [ -z "$_sm_cur" ]; then
        eval "LV_$_sm_k=\$_sm_c PV_$_sm_k=\$_sm_c SI_$_sm_k=$CS LG_$_sm_k=$CS CN_$_sm_k=0 CD_$_sm_k="
        return 0
    fi
    if [ "$_sm_cur" = "$_sm_c" ]; then
        eval "CN_$_sm_k=0 CD_$_sm_k= LG_$_sm_k=$CS"
        return 0
    fi
    eval "_sm_cd=\$CD_$_sm_k _sm_cn=\$CN_$_sm_k _sm_cf=\$CF_$_sm_k _sm_lg=\$LG_$_sm_k"
    case "$_sm_cn" in ''|*[!0-9]*) _sm_cn=0 ;; esac
    if [ "$_sm_cd" = "$_sm_c" ]; then
        _sm_cn=$(( _sm_cn + 1 ))
    else
        _sm_cd=$_sm_c; _sm_cn=1; _sm_cf=$CS
        eval "CF_$_sm_k=$CS"
    fi
    eval "CD_$_sm_k=\$_sm_cd CN_$_sm_k=\$_sm_cn"
    [ "$_sm_cn" -lt "$_sm_n" ] && return 0
    if [ "$BASE" != 1 ]; then
        emit_trans "$_sm_k" "$_sm_cur" "$_sm_c" "$_sm_lg" "$_sm_cf"
    fi
    VER=$(( VER + 1 ))
    eval "LV_$_sm_k=\$_sm_c PV_$_sm_k=\$_sm_cur SI_$_sm_k=$CS LG_$_sm_k=$CS CN_$_sm_k=0 CD_$_sm_k="
    DIRTY=1
}

# ---- 级别计算(每拍; 显式书写, 便于逐条对照 STATE_BUS.md 判据表) ----
F_smage=999999; F_wdage=999999; F_lkhb=999999; F_ledhb=999999; F_fanhb=999999
F_ntphb=999999; F_usbhb=999999; F_healthy=0; F_ntpsync=0
L_WIFI=0; L_CELL=0; L_WAN=0; NIGHT=0; MAINT=0; BOOTFLAG=0; OVR=ok
compute_levels() {
    # 监督层(L2): watchdog 每 30s 写 /tmp/watchdog.beat(循环起点), 龄>3*CYCLE 即失明
    hb_of /tmp/watchdog.beat; F_wdage=$_fw_hba
    if [ "$F_wdage" -le 90 ]; then _lg_c=ok
    elif [ "$F_wdage" -le 600 ]; then _lg_c=deg
    else _lg_c=down; fi
    setlvl supervisor "$_lg_c" 1
    # 观测层(L2): 采样器(log_keeper 5min 驱动, 10min 节拍) —— 观测本身也要可见
    hb_of /tmp/avail_sampler.hb; F_smage=$_fw_hba
    if [ "$F_smage" -le 600 ]; then _lg_c=ok
    elif [ "$F_smage" -le 1800 ]; then _lg_c=deg
    else _lg_c=down; fi
    setlvl observability "$_lg_c" 2
    # 启动链(L2)
    F_healthy=0; [ -f "$D/boot.healthy" ] && F_healthy=1
    if [ "$F_healthy" = 0 ]; then _lg_c=unknown
    elif [ "$F_bootgate" = 0 ]; then _lg_c=ok
    else _lg_c=down; fi
    setlvl boot "$_lg_c" 1
    # 证据层级(2026-11-01 04:00 冷启动实弹): tcp80 探针瞬断而 l80/http200 都正常 -> 被误判 down(假红)。
    #   原理: **HTTP 200 蕴含 TCP 接受连接** —— 一个完成的 HTTP 请求同时证明了"监听在"与"服务在服务"。
    #   所以 http200 成功时, tcp80 失败只可能是探针自身问题(设备连自己 LAN IP 的瞬态), 不能反判 down;
    #   反向(tcp80 通但 http200 不通)= 在接受但不应答 -> deg。tcp80 探针**保留**: 它是 1s 节拍的
    #   快速失败信号, 只是没有能力覆盖更强的证据。
    if [ "$F_l80" = 0 ]; then _lg_c=down
    elif [ "$AGE_http" -gt 300 ]; then _lg_c=unknown
    elif [ "$F_http" = 1 ]; then _lg_c=ok
    elif [ "$F_tcp80" = 1 ]; then _lg_c=deg
    else _lg_c=down; fi
    setlvl gui "$_lg_c" 1
    # SSH(L2): 监听位 1s + banner 300s; 无新鲜 L2 证据时判 unknown, 不显示绿(R2.6)
    if [ "$F_l22" = 0 ]; then _lg_c=down
    elif [ "$AGE_ssh2" -le 900 ] && [ "$F_ssh2" = 1 ]; then _lg_c=ok
    else _lg_c=unknown; fi
    setlvl ssh "$_lg_c" 1
    # LAN 桥/DHCP/DNS(L2): 桥 UP + :53 在听 + DNS 真的应答
    if [ "$F_br" = 0 ] || [ "$F_l53" = 0 ]; then _lg_c=down
    elif [ "$F_dns" = 1 ]; then _lg_c=ok
    else _lg_c=deg; fi
    setlvl bridge "$_lg_c" 1
    # WiFi 分频(L2+): 活控制套接字 + 链路 UP(旧判据只看 netdev 存在, 曾谎报 5.5h)
    if [ "$F_s0" = 1 ] && [ "$F_ra0" = 1 ]; then _lg_c=ok; else _lg_c=down; fi
    setlvl wifi2g "$_lg_c" 1
    if [ "$F_s1" = 1 ] && [ "$F_rai0" = 1 ]; then _lg_c=ok; else _lg_c=down; fi
    setlvl wifi5g "$_lg_c" 1
    # 以太 WAN(L3): 载波(1s) + wan_agg 的 L3 结论(新鲜度门; 过期=未知, 不猜)
    if [ "$F_car0" = 0 ]; then _lg_c=down
    elif [ "$F_wanage" -gt 30 ]; then _lg_c=unknown
    elif [ "$F_home" = 1 ]; then _lg_c=ok
    else _lg_c=deg; fi
    setlvl ethernet "$_lg_c" 1
    # 5G 蜂窝(L3)
    if [ "$F_r_ccm" = 0 ]; then _lg_c=down
    elif [ "$F_wanage" -gt 30 ]; then _lg_c=unknown
    elif [ "$F_cell" = 1 ]; then _lg_c=ok
    else _lg_c=deg; fi
    setlvl cellular "$_lg_c" 1
    # 指示灯(L3: 每次写 GPIO 后的读回校验是结果级证据)
    hb_of /tmp/led_mgr.hb; F_ledhb=$_fw_hba
    if [ "$F_ledhb" -gt 60 ] || [ "$F_ledage" -gt 60 ]; then _lg_c=down
    elif [ "$F_ledok" = 0 ]; then _lg_c=deg
    else _lg_c=ok; fi
    setlvl led "$_lg_c" 1
    # 温控(L1: 只有守护心跳, 无温度结果判据 -> GUI 不得显示为绿)
    hb_of /tmp/fan_mgr.hb; F_fanhb=$_fw_hba
    if [ "$F_fanhb" -le 60 ]; then _lg_c=ok; else _lg_c=down; fi
    setlvl fan "$_lg_c" 1
    # NTP(L2): 未对时前"时间不可信", 记 unknown 而不是绿
    F_ntpsync=0; [ -f /tmp/ntp_synced ] && F_ntpsync=1
    hb_of /tmp/ntp_keeper.hb; F_ntphb=$_fw_hba
    if [ "$F_ntpsync" = 0 ]; then _lg_c=unknown
    elif [ "$F_ntphb" -le 4200 ]; then _lg_c=ok
    else _lg_c=down; fi
    setlvl ntp "$_lg_c" 2
    # 配置写锁(L2): netcfg 锁被长持会让全写方超时(AGENTS 陷阱表)
    if [ "$F_netlock" = 0 ]; then _lg_c=ok; else _lg_c=deg; fi
    setlvl netlock "$_lg_c" 1
    # USB 设备模式(L1)
    hb_of /tmp/usb_mgr.hb; F_usbhb=$_fw_hba
    if [ "$F_usbhb" -le 180 ]; then _lg_c=ok; else _lg_c=down; fi
    setlvl usb "$_lg_c" 1
    # 日志管线(L2)
    hb_of /tmp/log_keeper.hb; F_lkhb=$_fw_hba
    if [ "$F_lkhb" -le 180 ]; then _lg_c=ok; else _lg_c=down; fi
    setlvl logging "$_lg_c" 1
}
# LED 投影: 由**已发布的状态**推导, led_mgr 只执行不判断(R2.4)
compute_led() {
    L_WIFI=0
    if [ "$F_s0" = 1 ] && [ "$F_ra0" = 1 ]; then L_WIFI=1; fi
    if [ "$L_WIFI" = 0 ] && [ "$F_s1" = 1 ] && [ "$F_rai0" = 1 ]; then L_WIFI=1; fi
    L_CELL=0
    if [ "$F_r_ccm" = 1 ] && [ "$F_wanage" -le 30 ] && [ "$F_cell" = 1 ]; then L_CELL=1; fi
    L_WAN=0
    if [ "$F_car0" = 1 ] && [ "$F_wanage" -le 30 ] && [ "$F_home" = 1 ]; then L_WAN=1; fi
}
scan_night() {
    NIGHT=0
    _nn_f=$D/settings.conf
    [ -r "$_nn_f" ] || _nn_f=$D/defaults.conf
    [ -r "$_nn_f" ] || return 0
    while IFS= read -r _nn_l; do
        case "$_nn_l" in LED_NIGHT=*) NIGHT=${_nn_l#LED_NIGHT=} ;; esac
    done < "$_nn_f"
    case "$NIGHT" in 0|1) ;; *) NIGHT=0 ;; esac
}
# 总体状态: 数据面(上行组)最差优先; 上行全绿再取其余最差(AVAILABILITY_DESIGN §2)
overall_calc() {
    _ov_r=9; OVR=ok
    for _pb_k in $KEYS; do
        case "$_pb_k" in ethernet|cellular) ;; *) continue ;; esac
        eval "_pb_l=\$LV_$_pb_k"
        case "$_pb_l" in down) _pb_r=0 ;; unknown) _pb_r=1 ;; deg) _pb_r=2 ;; ok) _pb_r=3 ;; *) _pb_r=4 ;; esac
        if [ "$_pb_r" -lt "$_ov_r" ]; then _ov_r=$_pb_r; OVR=$_pb_l; fi
    done
    [ "$_ov_r" -ge 3 ] || return 0
    _ov_r=9
    for _pb_k in $KEYS; do
        case "$_pb_k" in ethernet|cellular) continue ;; esac
        eval "_pb_l=\$LV_$_pb_k"
        case "$_pb_l" in down) _pb_r=0 ;; unknown) _pb_r=1 ;; deg) _pb_r=2 ;; ok) _pb_r=3 ;; *) _pb_r=4 ;; esac
        if [ "$_pb_r" -lt "$_ov_r" ]; then _ov_r=$_pb_r; OVR=$_pb_l; fi
    done
}
# ---- 发布(原子 rename; 单一状态源) -------------------------------------
publish() {
    overall_calc
    ep_ms "$CS"; _pb_ms=$_fw_ms
    _pb_ep=$(( EP + ( CS - EP_CS ) / 100 ))
    _pb_j=""
    for _pb_k in $KEYS; do
        eval "_pb_l=\$LV_$_pb_k _pb_s=\$SI_$_pb_k"
        case "$_pb_s" in ''|*[!0-9]*) _pb_s=$CS ;; esac
        _pb_se=$(( EP + ( _pb_s - EP_CS ) / 100 ))
        _pb_j="$_pb_j{\"id\":\"$(c_id "$_pb_k")\",\"n\":\"$(c_name "$_pb_k")\",\"g\":\"$(c_grp "$_pb_k")\",\"lv\":\"$_pb_l\",\"crit\":\"$(c_crit "$_pb_k")\",\"since\":$_pb_se,\"det\":\"$(c_det "$_pb_k")\",\"ev\":\"$(ev_of "$_pb_k")\"},"
    done
    _pb_json="{\"schema\":1,\"ver\":$VER,\"ms\":$_pb_ms,\"ts\":$_pb_ep,\"tick\":$TICK,\"overall\":\"$OVR\",\"maint\":$MAINT,\"boot\":$BOOTFLAG,\"drill\":$DRILL,\"led\":{\"wifi\":$L_WIFI,\"cell\":$L_CELL,\"wan\":$L_WAN,\"night\":$NIGHT},\"comps\":[${_pb_j%,}]}"
    if [ "$DRY" = 1 ]; then printf '%s\n' "$_pb_json"; return 0; fi
    printf '%s\n' "$_pb_json" > "$STATE.tmp" && mv -f "$STATE.tmp" "$STATE"
    printf 'ver=%s\nms=%s\nwifi=%s\ncell=%s\nwan=%s\nnight=%s\noverall=%s\nts=%s\n' \
        "$VER" "$_pb_ms" "$L_WIFI" "$L_CELL" "$L_WAN" "$NIGHT" "$OVR" "$_pb_ep" > "$LEDF.tmp" \
        && mv -f "$LEDF.tmp" "$LEDF"
}
# ---- fast_facts.tsv(M3 数据源) -----------------------------------------
# 语义: ok 变化即写 / 每探针 60s 心跳 / 服务探针失败期每拍写(1s 时长精度)
FW_tcp80=""; FW_tcp22=""; FW_dns=""; FW_icmp=""; FW_http=""; FW_ssh2=""
FW_eth0=""; FW_brlan=""; FW_ra0=""; FW_rai0=""; FW_hd2g=""; FW_hd5g=""; FW_ccmni=""; FW_wan=""
FT_tcp80=0; FT_tcp22=0; FT_dns=0; FT_icmp=0; FT_http=0; FT_ssh2=0
FT_eth0=0; FT_brlan=0; FT_ra0=0; FT_rai0=0; FT_hd2g=0; FT_hd5g=0; FT_ccmni=0; FT_wan=0
PRE=""
f_one() {  # $1=key $2=probeid $3=ok $4=lat $5=extra $6=flood(1=失败期每拍写)
    eval "_fd_l=\$FW_$1 _fd_t=\$FT_$1"
    case "$_fd_t" in ''|*[!0-9]*) _fd_t=0 ;; esac
    if [ "$_fd_l" != "$3" ] || [ $(( CS - _fd_t )) -ge 6000 ] || { [ "$6" = 1 ] && [ "$3" = 0 ]; }; then
        _fd_x=$5
        if [ -n "$PRE" ]; then
            if [ "$_fd_x" = "-" ]; then _fd_x="pre=1"; else _fd_x="${_fd_x},pre=1"; fi
        fi
        ep_ms "$CS"; _fd_ms=$_fw_ms
        [ "$DRY" = 1 ] || printf '%s\t%s\t%s\t%s\t%s\n' "$_fd_ms" "$2" "$3" "$4" "$_fd_x" >> "$FACTS"
        eval "FW_$1=\$3 FT_$1=$CS"
    fi
}
emit_facts() {
    PRE=""
    [ -f /tmp/ntp_synced ] || PRE="1"
    _fd_ok22=0; [ "$F_l22" -gt 0 ] && _fd_ok22=1
    _fd_wok=0; if [ "$F_home" = 1 ] && [ "$F_wanage" -le 30 ]; then _fd_wok=1; fi
    f_one tcp80  gw.tcp80       "$F_tcp80"   "$FL_tcp80" "-" 1
    f_one tcp22  gw.tcp22       "$_fd_ok22"  0           "bl=$F_bl22" 1
    f_one dns    gw.dns         "$F_dns"     "$FL_dns"   "-" 1
    f_one icmp   wan.icmp       "$F_icmp"    "$FL_icmp"  "-" 1
    f_one http   gw.http200     "$F_http"    "$FL_http"  "-" 1
    f_one ssh2   gw.ssh_l2      "$F_ssh2"    "$FL_ssh2"  "-" 0
    f_one eth0   net.eth0       "$F_car0"    0           "-" 0
    f_one brlan  net.brlan      "$F_br"      0           "-" 0
    f_one ra0    net.ra0        "$F_ra0"     0           "-" 0
    f_one rai0   net.rai0       "$F_rai0"    0           "-" 0
    f_one hd2g   net.hostapd2g  "$F_s0"      0           "-" 0
    f_one hd5g   net.hostapd5g  "$F_s1"      0           "-" 0
    f_one ccmni  net.ccmni      "$F_r_ccm"   0           "-" 0
    f_one wan    wan.alive      "$_fd_wok"   0           "home=$F_home,cell=$F_cell,age=$F_wanage" 1
}
# ---- avail_edges.tsv(avail_sampler 窗口收割; 字段契约见 STATE_BUS.md) ----
# 格式: epoch <ISO带T无空格> <sampler_id> <edge_down|edge_up> <flags>
#       -> $1=epoch $3=id $4=ev (与 avail_sampler 的 awk 解析严格一致)
EL_gui=""; EL_ssh=""; EL_dns=""; EL_br=""; EL_wpa2=""; EL_wpa5=""; EL_eth=""
e_one() {  # $1=key $2=sampler_id $3=ok
    eval "_ed_l=\$EL_$1"
    if [ -z "$_ed_l" ]; then eval "EL_$1=\$3"; return 0; fi
    [ "$_ed_l" = "$3" ] && return 0
    [ "$DRY" = 1 ] || edge_emit "$2" "$3" "$FLAGS" "$EDGES"
    eval "EL_$1=\$3"
}
emit_edges() {
    _ed_w2=0; if [ "$F_s0" = 1 ] && [ "$F_ra0" = 1 ]; then _ed_w2=1; fi
    _ed_w5=0; if [ "$F_s1" = 1 ] && [ "$F_rai0" = 1 ]; then _ed_w5=1; fi
    _ed_d53=0; [ "$F_l53" -gt 0 ] && _ed_d53=1
    e_one gui  "$EDGE_ID_GUI"  "$F_tcp80"
    e_one ssh  "$EDGE_ID_SSH"  "$F_ssh2"
    e_one dns  "$EDGE_ID_DNS"  "$_ed_d53"
    e_one br   "$EDGE_ID_BR"   "$F_br"
    e_one wpa2 "$EDGE_ID_WPA2" "$_ed_w2"
    e_one wpa5 "$EDGE_ID_WPA5" "$_ed_w5"
    e_one eth  "$EDGE_ID_ETH"  "$F_car0"
}
emit_beat() { [ "$DRY" = 1 ] && return 0; printf '%s %s %s %s %s\n' "$UPS" "$CS" "$EP" "$VER" "$TICK" > "$BEAT"; }
# ---- 标志位(boot/maint/drill) ------------------------------------------
flags_upd() {
    # v1.6(实弹): F_healthy 在这里重算—— 原来 flags_upd 跑在 compute_levels 之前,
    # 首拍读到的是初值 0, 于是首个 state.json 永远带 boot=1; 而 publish 只在迁移时写,
    # 稳定设备上 GUI 会一直显示「启动中」—— 这是一种假状态(实测 00:55 首包 boot=1 而 设备已跑 6h)。
    F_healthy=0; [ -f "$D/boot.healthy" ] && F_healthy=1
    BOOTFLAG=0
    if [ "$UPS" -lt 180 ] || [ "$F_healthy" = 0 ]; then BOOTFLAG=1; fi
    if [ $(( TICK % 30 )) -eq 1 ]; then
        _hm=$("$BB" date +%H%M 2>/dev/null)
        case "$_hm" in ''|*[!0-9]*) _hm=0 ;; esac
        if [ "$_hm" -ge 357 ] && [ "$_hm" -le 410 ]; then MAINT=1; else MAINT=0; fi
    fi
    FLAGS=""
    [ "$BOOTFLAG" = 1 ] && FLAGS=boot
    if [ "$MAINT" = 1 ]; then
        if [ -z "$FLAGS" ]; then FLAGS=maint; else FLAGS="$FLAGS,maint"; fi
    fi
    if [ "$DRILL" = 1 ]; then
        if [ -z "$FLAGS" ]; then FLAGS=drill; else FLAGS="$FLAGS,drill"; fi
    fi
    [ -z "$FLAGS" ] && FLAGS="-"
    # 实弹(04:00 冷启动): state.json 只在迁移时发布, 而 maint/drill 是标志不是级别——
    #   标志变化不触发发布, 于是 maint 过了 04:10 仍显示维护、drill 关闭后仍显示演练中(永久粘住)。
    #   标志变化必须重新发布。
    [ "$FLAGS" != "$_fw_prev_flags" ] && DIRTY=1
    _fw_prev_flags=$FLAGS
}
rotate_all() {
    [ "$DRY" = 1 ] && return 0
    rotate_if "$FACTS" 60000
    rotate_if "$EDGES" 4000
    rotate_if "$LAG" 40000
    rotate_if "$EVT" 40000
    if [ -f /tmp/v3httpd.log ]; then
        _ro_sz=$("$BB" wc -c < /tmp/v3httpd.log 2>/dev/null)
        case "$_ro_sz" in ''|*[!0-9]*) _ro_sz=0 ;; esac
        if [ "$_ro_sz" -gt 262144 ]; then
            "$BB" tail -n 2000 /tmp/v3httpd.log > /tmp/v3httpd.log.tmp 2>/dev/null \
                && mv -f /tmp/v3httpd.log.tmp /tmp/v3httpd.log
        fi
    fi
}
# ---- 每拍采样 ----------------------------------------------------------
sample_all() {
    scan_proc
    scan_links
    scan_wan
    scan_led
    if [ $(( TICK % 5 )) -eq 1 ]; then scan_wd; scan_drill; fi
    if [ $(( TICK % 30 )) -eq 1 ]; then scan_night; fi
    if [ $(( TICK % 600 )) -eq 1 ]; then nexthop; fi
    probe_tcp80
    # 首拍(TICK=1)就把所有探针跑一次: 否则启动后头 10s 内 http200 证据缺失,
    # gui 会被 AGE_http>300 规则误判为 deg(假红), 且基线晚 10s。
    if [ $(( TICK % 2 )) -eq 1 ]; then probe_dns; fi
    if [ $(( TICK % 6 )) -eq 1 ]; then probe_icmp; fi
    if [ $(( TICK % 10 )) -eq 1 ]; then probe_http; fi
    if [ $(( TICK % 300 )) -eq 1 ]; then probe_ssh2; fi
    AGE_dns=$(( AGE_dns + 1 )); AGE_icmp=$(( AGE_icmp + 1 ))
    AGE_http=$(( AGE_http + 1 )); AGE_ssh2=$(( AGE_ssh2 + 1 ))
}
# ---- 主循环(绝对对齐 1s 边界; 超拍留痕) --------------------------------
DRY=0; TICK=0; OVRUN=0; STEP=init
run_loop() {
    while :; do
        TICK=$(( TICK + 1 ))
        now_cs; _rl_t0=$CS
        if [ $(( TICK % 10 )) -eq 1 ]; then now_ep; fi
        # ⚠ v2.6 回滚(lead 10:03): fast_lane **停用**。实弹证据: kick 只能叫醒 watchdog,
        #   而 watchdog 对 v3httpd/dnsmasq/hostapd 走的是**定制块 + strike 2-of-3**(不是档A), 所以 kick 不能加速重启;
        #   更糟: kick 让 watchdog 多跑几轮, 而每轮的检查在“进程在但不应答”窗口会记 PASS -> strike_clear 把 2-of-3 计数清零,
        #   反而把 90s 拉长到 6min(09:55-10:01 真实 DNS 中断)。重新上线前必须先证明不干扰计数。
        STEP=sample; sample_all        STEP=flags; flags_upd
        STEP=levels; compute_levels
        STEP=led; compute_led
        if [ "$DIRTY" = 1 ]; then STEP=publish; publish; DIRTY=0; fi
        STEP=facts; emit_facts
        STEP=edges; emit_edges
        STEP=beat; emit_beat
        # M3 消费者 tick(幂等, 测试钩子: 文件不存在则不调)
        if [ $(( TICK % 60 )) -eq 0 ] && [ -r "$D/svc_outage.sh" ]; then
            "$BB" timeout -s KILL 5 sh "$D/svc_outage.sh" tick >/dev/null 2>&1 || true
        fi
        # M4/G2 配置漂移自愈(cfg-heal, cfg_heal.sh): 每 5 拍(5s)一次。
        # 硬超时取 3s 而非它们建议的 8s: 同步调用下 8s 会让一拍最长停 8s,
        # 直接违反 R2.2 的 1s 检测。实际成本 = 6 fork + 纯 shell 匹配(百毫秒级),
        # 3s 已是 30 倍余量; 万一超拍会记入 fast_watch.overrun.tsv(可复核)。
        if [ $(( TICK % 5 )) -eq 0 ] && [ -r "$D/cfg_heal.sh" ]; then
            "$BB" timeout -s KILL 3 sh "$D/cfg_heal.sh" --tick >/dev/null 2>&1 || true
        fi
        # 审计心跳: 证明 lag_audit 在写(不带 lag_ms=, 不污染 p50/p99)
        if [ $(( TICK % 30 )) -eq 0 ]; then
            ep_ms "$CS"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$_fw_ms" "$VER" "-" beat "$_fw_ms" "$_fw_ms" "beat" >> "$LAG"
        fi
        if [ $(( TICK % 15 )) -eq 0 ]; then STEP=hb; svc_hb fast_watch; fi
        if [ $(( TICK % 300 )) -eq 0 ]; then STEP=rotate; rotate_all; fi
        now_cs
        _rl_used=$(( CS - _rl_t0 ))
        STEP=sleep
        if [ "$_rl_used" -lt "$INT" ]; then
            "$BB" usleep $(( (INT - _rl_used) * 10000 ))
        else
            OVRUN=$(( OVRUN + 1 ))
            if [ $(( OVRUN % 30 )) -eq 1 ]; then
                printf '%s\t%s\t%s\n' "$EP" "$TICK" "$_rl_used" >> "$LOGD/fast_watch.overrun.tsv"
            fi
        fi
        BASE=0
    done
}
# ---- 入口 --------------------------------------------------------------
case "${1:-}" in
--selftest)
    # 契约往返自检(lead v1.2: 写一条合成边缘行 -> 消费方必须解析出预期组件):
    # 对每个 id 写 down/up 各一行到临时文件, 用共享解析器读回, 断言 id/事件/组件三者一致。
    # 这条自检直接针对"字段位置假设"这类静默失效 —— 它在 2026-11-01 之前整整坏了一版。
    _st_f=/tmp/fast_watch.selftest.$$
    : > "$_st_f"
    _st_fail=0; _st_n=0
    for _st_id in $EDGE_IDS; do
        _st_n=$(( _st_n + 1 ))
        edge_emit "$_st_id" 0 "-" "$_st_f" || { echo "FAIL emit $_st_id"; _st_fail=1; continue; }
        edge_emit "$_st_id" 1 "-" "$_st_f" || { echo "FAIL emit(up) $_st_id"; _st_fail=1; continue; }
    done
    _st_ok=0
    while IFS= read -r _st_line; do
        if ! edge_parse_line "$_st_line"; then
            echo "FAIL parse: [$_st_line]"; _st_fail=1; continue
        fi
        _st_c=$(edge_comp_of "$EDGE_ID")
        if [ -z "$_st_c" ]; then
            echo "FAIL comp mapping for id=$EDGE_ID"; _st_fail=1; continue
        fi
        case "$EDGE_EV" in edge_down|edge_up) ;; *) echo "FAIL ev=$EDGE_EV"; _st_fail=1 ;; esac
        _st_ok=$(( _st_ok + 1 ))
    done < "$_st_f"
    _st_expect=$(( _st_n * 2 ))
    if [ "$_st_ok" != "$_st_expect" ]; then
        echo "FAIL roundtrip parsed=$_st_ok expect=$_st_expect"; _st_fail=1
    fi
    rm -f "$_st_f"
    _st_fc=0
    if [ -s "$FACTS" ]; then
        _st_bad=$(tail -n 200 "$FACTS" | "$BB" awk -F'\t' 'NF!=5{b++} END{print b+0}')
        [ "$_st_bad" = 0 ] || { echo "FAIL fast_facts NF!=5 rows=$_st_bad"; _st_fail=1; }
        _st_fc=1
    fi
    if [ "$_st_fail" = 0 ]; then
        echo "SELFTEST OK: edge_roundtrip ids=$_st_n parsed=$_st_ok facts_nf5=$_st_fc"
        exit 0
    fi
    echo "SELFTEST FAILED"
    exit 1 ;;
--once)
    DRY=1; TICK=1
    now_cs; now_ep
    nexthop
    scan_proc; scan_links; scan_wan; scan_led; scan_wd; scan_drill; scan_night
    probe_tcp80; probe_dns; probe_icmp; probe_http; probe_ssh2
    flags_upd; compute_levels; compute_led; publish
    exit 0 ;;
--dry)
    DRY=1; TICK=0
    now_cs; now_ep; nexthop
    _dry_n=${2:-5}
    while [ "$TICK" -lt "$_dry_n" ]; do
        TICK=$(( TICK + 1 ))
        now_cs; _rl_t0=$CS
        if [ $(( TICK % 10 )) -eq 1 ]; then now_ep; fi
        sample_all; fast_lane; flags_upd; compute_levels; compute_led
        eval "_d_gui=\$LV_gui _d_br=\$LV_bridge _d_w2=\$LV_wifi2g _d_eth=\$LV_ethernet _d_cell=\$LV_cellular _d_ssh=\$LV_ssh _d_led=\$LV_led _d_sup=\$LV_supervisor"
        printf 't=%s up=%s ver=%s ovr=%s gui=%s br=%s w2=%s eth=%s cell=%s ssh=%s led=%s sup=%s ledflat=%s/%s/%s ok80=%s l22=%s dns=%s\n' \
            "$TICK" "$UPS" "$VER" "$OVR" "$_d_gui" "$_d_br" "$_d_w2" "$_d_eth" "$_d_cell" "$_d_ssh" "$_d_led" "$_d_sup" \
            "$L_WIFI" "$L_CELL" "$L_WAN" "$F_tcp80" "$F_l22" "$F_dns"
        emit_facts
        now_cs
        _rl_used=$(( CS - _rl_t0 ))
        STEP=sleep
        if [ "$_rl_used" -lt "$INT" ]; then "$BB" usleep $(( (INT - _rl_used) * 10000 )); fi
        BASE=0
    done
    exit 0 ;;
esac

# ---- 常驻 --------------------------------------------------------------
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else
    echo "fast_watch: svc_lib.sh missing -- refusing to run unsupervised" >&2
    exit 1
fi
mkdir -p "$RUN" "$LOGD" 2>/dev/null
_rc=0; svc_lock fast_watch /data/gw/fast_watch.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    if [ "$_rc" = 1 ]; then echo "fast_watch: already running" >&2; else echo "fast_watch: lost lock race" >&2; fi
    exit 0
fi
touch "$EVT" "$LAG" "$FACTS" "$EDGES" 2>/dev/null
# VER 用启动 epoch 起跳: 跨重启全局单调, GUI 不会把"重启后的小版本号"当成旧数据
now_cs; now_ep; VER=$EP
# v1.7(实弹取证): 记下每一次退出的原因 —— 实测 01:00:50 左右有一次无记录退出(无 NE 无 dmesg),
# 而 SIGKILL 拿不到 trap —— 因此有这行台账就能区分「被 SIGKILL」与「自己退出」，不再靠猜。
# v2.0(定位 P0): 分信号 trap —— 区分「自己退出(EXIT, 带 rc)」与「被 TERM/INT/HUP 杀」。
# 旧实现把 TERM 也记成 exit=<上一个命令的状态>, 导致 exit=2 看起来像自退, 实际可能是信号。
trap 'printf "%s\tSIGTERM\ttick=%s\tstep=%s\tpid=%s\tup=%s\n" "$(date +%s)" "$TICK" "$STEP" "$$" "$(cut -d. -f1 /proc/uptime)" >> /tmp/fast_watch.exit.tsv 2>/dev/null' TERM
trap 'printf "%s\tSIGINT\ttick=%s\tstep=%s\tpid=%s\tup=%s\n" "$(date +%s)" "$TICK" "$STEP" "$$" "$(cut -d. -f1 /proc/uptime)" >> /tmp/fast_watch.exit.tsv 2>/dev/null' INT
trap 'printf "%s\tSIGHUP\ttick=%s\tstep=%s\tpid=%s\tup=%s\n" "$(date +%s)" "$TICK" "$STEP" "$$" "$(cut -d. -f1 /proc/uptime)" >> /tmp/fast_watch.exit.tsv 2>/dev/null' HUP
trap 'printf "%s\tEXIT\trc=%s\ttick=%s\tstep=%s\tpid=%s\tup=%s\n" "$(date +%s)" "$?" "$TICK" "$STEP" "$$" "$(cut -d. -f1 /proc/uptime)" >> /tmp/fast_watch.exit.tsv 2>/dev/null' EXIT
BASE=1; DIRTY=1
printf '%s\t%s\t%s\n' "$EP" "boot" "ver=$VER up=$UPS" >> "$LOGD/fast_watch.boot.tsv" 2>/dev/null
run_loop
