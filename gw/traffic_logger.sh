#!/bin/sh
# traffic_logger.sh v1.6 — 蜂窝/以太网流量采样器(5 分钟粒度, /data 持久)
# 输出: /data/gw/traffic_hist.tsv  每行: epoch drx_c dtx_c drx_e dtx_e (字节增量)
# 语义: 增量为"距上次采样"; 计数器回绕/接口重建(ccmni 漂移)/重启(新值<旧值)
#       按新值计(=计数器自身纪元的累计, 自洽); prev 存 /tmp(重启后首拍即
#       "自计数器归零以来", 语义连续)
# v1.5b: tc 用绝对路径 /sbin/tc —— PATH 里的 /data/gw/sbin/tc 是 busybox 的, 不支持
#   "-s qdisc show", 于是 qdisc 口径一直在静默回退 netdev(见 toolchain_init 同轮修复)。
# v1.6 (2026-10-29 GUI 聚合轮): 每拍同时维护**小时/日汇总**(traffic_hour.tsv /
#   traffic_day.tsv)。GUI 的 traffic_hist 原来每次请求都用 awk 扫 6000 行原始采样 ——
#   那条 awk 是崩溃家族里最常见的一个落点(18h 内 4 次)。汇总后 API 只读 ≤960/≤400 行。
# v1.5 (2026-10-29 蜂窝少计): 承载口选择改为"**活的** ccmni"(IFF_UP + 有 inet),
#   原规则 `ip -o -4 addr show | grep -m1 'ccmni.*inet'` 取**第一个**带 IP 的 ccmni ——
#   实弹: ccmni2 已 DOWN 但仍挂着陈旧 IP(10.48.121.46), 活的承载是 ccmni3;
#   于是整段只统计了一个停摆的网卡, 蜂窝流量恒 ~0(运营商侧每天都有消耗)。
#   同时把接口名并入基线标记(S=qdisc:ccmni3) —— 承载切换时重建基线, 而不是把
#   "旧口基线 vs 新口现值"记成一行假增量。
# v1.2(2026-10-15): 蜂窝**上行**数据源 netdev tx_bytes → qdisc(Linux 发送路径)。
#   网卡计数会被厂商卸载路径的记账灌入无法佐证的批量增量(实测: 1 秒内 +1,221,373B
#   /813 包, 同期 qdisc 仅 +29B/1 包、ccmni2 抓包只有 6 个探针包; 无 IP/无路由且
#   DOWN 的 ccmni1 也记了 47MB), 用作流量统计会长期高估并把"蜂窝用量"变成假象。
#   qdisc 对真实流量逐字节精确(已知量注入实测一致), 且不含该幻影; qdisc 缺失时
#   回退 netdev。**下行**仍用 netdev rx(实测准确: 1MB 下载 → +1.08MB)。
#   **口径切换点**: 本版之前的历史行是"网卡报告值"(被高估), 之后是"Linux 路径值"。
#   历史不改写(留作设备当时报告的存证), 跨切换点的周/月聚合会混合两种口径。
# v1.2b: 基线文件带数据源标记(S=qdisc|netdev), 源变即重建基线 —— 否则切换源时
#   "旧源基线 vs 新源现值"会把绝对差记成一行假增量(实弹: 切换瞬间记了 22MB 尖峰)。
# 接口漂移: ccmni* 每拍动态解析(与 get_traffic 同法); eth0 固定
# 尺寸守护: 超 40 天(~11520 行)裁剪保留 30 天
LOG=/data/gw/traffic_hist.tsv
HOURF=/data/gw/traffic_hour.tsv
DAYF=/data/gw/traffic_day.tsv
_TC=/sbin/tc; [ -x "$_TC" ] || _TC=tc
ST=/tmp/traffic_prev
# v1.4 (batch3): shared single-instance lock + heartbeat primitives.
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else echo "traffic_logger: svc_lib.sh missing" >&2; exit 1; fi
_rc=0; svc_lock traffic_logger /data/gw/traffic_logger.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    [ "$_rc" = 1 ] && echo "traffic_logger: already running" >&2 || echo "traffic_logger: lost lock race" >&2
    exit 0
fi
_bump() { # $1=file $2=key $3=c $4=e —— 同键累加(小文件整写, 每 5 分钟两次)
    _bf=$1; _bk=$2; _bc=$3; _be=$4
    _oc=0; _oe=0
    _orow=$(grep "^$_bk " "$_bf" 2>/dev/null | head -1)
    if [ -n "$_orow" ]; then
        _oc=$(printf '%s' "$_orow" | cut -d' ' -f2)
        _oe=$(printf '%s' "$_orow" | cut -d' ' -f3)
    fi
    case "$_oc" in ''|*[!0-9]*) _oc=0 ;; esac
    case "$_oe" in ''|*[!0-9]*) _oe=0 ;; esac
    grep -v "^$_bk " "$_bf" 2>/dev/null > "$_bf.t"
    echo "$_bk $((_oc + _bc)) $((_oe + _be))" >> "$_bf.t"
    mv "$_bf.t" "$_bf"
}

while :; do
    svc_hb traffic_logger
    # v1.5: 只认**活的**承载口 —— IFF_UP(flags bit0) 且带 inet; 陈旧 IP 的 DOWN 口不算
    CIF=""
    for _ci in ccmni0 ccmni1 ccmni2 ccmni3; do
        [ -d /sys/class/net/$_ci ] || continue
        _cf=$(cat /sys/class/net/$_ci/flags 2>/dev/null)
        case "$_cf" in 0x*|0X*) ;; *) continue ;; esac
        [ $((_cf & 1)) -ne 0 ] || continue
        ip -4 addr show $_ci 2>/dev/null | grep -q 'inet ' || continue
        CIF=$_ci; break
    done
    # 兜底: 没有 UP 的(理论上不该发生)仍取第一个带 IP 的, 保证不断流
    [ -n "$CIF" ] || CIF=$(ip -o -4 addr show 2>/dev/null | grep -m1 'ccmni.*inet' | awk '{print $2}')
    CRC=0; CTC=0; SRC=none
    [ -n "$CIF" ] && {
        CRC=$(cat /sys/class/net/$CIF/statistics/rx_bytes 2>/dev/null || echo 0)
        CTC=$($_TC -s qdisc show dev $CIF 2>/dev/null | awk '/Sent/{print $2; exit}')
        SRC=qdisc
        [ -n "$CTC" ] || { CTC=$(cat /sys/class/net/$CIF/statistics/tx_bytes 2>/dev/null || echo 0); SRC=netdev; }
    }
    ERC=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
    ETC=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0)
    PC=0; PT=0; PE=0; PF=0
    # v1.2b: 首次(无 prev)只建基线不入账 — 否则首拍 = 计数器纪元总量, 3GB 级假尖峰。
    #   基线文件带**数据源标记**(S=qdisc|netdev): 源变了(口径切换/升级)必须重建基线,
    #   否则"旧源基线 vs 新源现值"会算出一行假增量(实测切换瞬间记了 22MB 假尖峰)。
    if [ ! -r $ST ] || ! grep -q "^S=$SRC:$CIF;" $ST 2>/dev/null; then
        echo "S=$SRC:$CIF; PC=$CRC; PT=$CTC; PE=$ERC; PF=$ETC" > $ST
        sleep 300
        continue
    fi
    . $ST
    DC=$((CRC-PC)); [ $DC -lt 0 ] && DC=$CRC
    DT=$((CTC-PT)); [ $DT -lt 0 ] && DT=$CTC
    DE=$((ERC-PE)); [ $DE -lt 0 ] && DE=$ERC
    DF=$((ETC-PF)); [ $DF -lt 0 ] && DF=$ETC
    _now=$(date +%s)
    echo "$_now $DC $DT $DE $DF" >> $LOG
    # v1.6: 小时/日汇总累加(键 = 本地对齐的 epoch; 与 API 的桶键同约定)
    _bump "$HOURF" "$(( (_now + 28800) / 3600 * 3600 ))"  "$((DC + DT))" "$((DE + DF))"
    _bump "$DAYF"  "$(( (_now + 28800) / 86400 * 86400 ))" "$((DC + DT))" "$((DE + DF))"
    [ "$(wc -l < $HOURF 2>/dev/null || echo 0)" -gt 1000 ] && { tail -n 960 $HOURF > $HOURF.t 2>/dev/null && mv $HOURF.t $HOURF; }
    [ "$(wc -l < $DAYF 2>/dev/null || echo 0)" -gt 400 ] && { tail -n 380 $DAYF > $DAYF.t 2>/dev/null && mv $DAYF.t $DAYF; }
    echo "S=$SRC:$CIF; PC=$CRC; PT=$CTC; PE=$ERC; PF=$ETC" > $ST
    L=$(wc -l < $LOG 2>/dev/null || echo 0)
    [ "$L" -gt 11520 ] && { tail -8640 $LOG > $LOG.t 2>/dev/null && mv $LOG.t $LOG; }
    sleep 300
done
