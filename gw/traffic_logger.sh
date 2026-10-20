#!/bin/sh
# traffic_logger.sh v1.4 — 蜂窝/以太网流量采样器(5 分钟粒度, /data 持久)
# 输出: /data/gw/traffic_hist.tsv  每行: epoch drx_c dtx_c drx_e dtx_e (字节增量)
# 语义: 增量为"距上次采样"; 计数器回绕/接口重建(ccmni 漂移)/重启(新值<旧值)
#       按新值计(=计数器自身纪元的累计, 自洽); prev 存 /tmp(重启后首拍即
#       "自计数器归零以来", 语义连续)
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
ST=/tmp/traffic_prev
# v1.4 (batch3): shared single-instance lock + heartbeat primitives.
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; else echo "traffic_logger: svc_lib.sh missing" >&2; exit 1; fi
_rc=0; svc_lock traffic_logger /data/gw/traffic_logger.sh || _rc=$?
if [ "$_rc" != 0 ]; then
    [ "$_rc" = 1 ] && echo "traffic_logger: already running" >&2 || echo "traffic_logger: lost lock race" >&2
    exit 0
fi
while :; do
    svc_hb traffic_logger
    CIF=$(ip -o -4 addr show 2>/dev/null | grep -m1 'ccmni.*inet' | awk '{print $2}')
    CRC=0; CTC=0; SRC=none
    [ -n "$CIF" ] && {
        CRC=$(cat /sys/class/net/$CIF/statistics/rx_bytes 2>/dev/null || echo 0)
        CTC=$(tc -s qdisc show dev $CIF 2>/dev/null | awk '/Sent/{print $2; exit}')
        SRC=qdisc
        [ -n "$CTC" ] || { CTC=$(cat /sys/class/net/$CIF/statistics/tx_bytes 2>/dev/null || echo 0); SRC=netdev; }
    }
    ERC=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
    ETC=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0)
    PC=0; PT=0; PE=0; PF=0
    # v1.2b: 首次(无 prev)只建基线不入账 — 否则首拍 = 计数器纪元总量, 3GB 级假尖峰。
    #   基线文件带**数据源标记**(S=qdisc|netdev): 源变了(口径切换/升级)必须重建基线,
    #   否则"旧源基线 vs 新源现值"会算出一行假增量(实测切换瞬间记了 22MB 假尖峰)。
    if [ ! -r $ST ] || ! grep -q "^S=$SRC;" $ST 2>/dev/null; then
        echo "S=$SRC; PC=$CRC; PT=$CTC; PE=$ERC; PF=$ETC" > $ST
        sleep 300
        continue
    fi
    . $ST
    DC=$((CRC-PC)); [ $DC -lt 0 ] && DC=$CRC
    DT=$((CTC-PT)); [ $DT -lt 0 ] && DT=$CTC
    DE=$((ERC-PE)); [ $DE -lt 0 ] && DE=$ERC
    DF=$((ETC-PF)); [ $DF -lt 0 ] && DF=$ETC
    echo "$(date +%s) $DC $DT $DE $DF" >> $LOG
    echo "S=$SRC; PC=$CRC; PT=$CTC; PE=$ERC; PF=$ETC" > $ST
    L=$(wc -l < $LOG 2>/dev/null || echo 0)
    [ "$L" -gt 11520 ] && { tail -8640 $LOG > $LOG.t 2>/dev/null && mv $LOG.t $LOG; }
    sleep 300
done
