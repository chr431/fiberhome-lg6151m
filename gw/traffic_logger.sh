#!/bin/sh
# traffic_logger.sh v1.0 — 蜂窝/以太网流量采样器(5 分钟粒度, /data 持久)
# 输出: /data/gw/traffic_hist.tsv  每行: epoch drx_c dtx_c drx_e dtx_e (字节增量)
# 语义: 增量为"距上次采样"; 计数器回绕/接口重建(ccmni 漂移)/重启(新值<旧值)
#       按新值计(=计数器自身纪元的累计, 自洽); prev 存 /tmp(重启后首拍即
#       "自计数器归零以来", 语义连续)
# 接口漂移: ccmni* 每拍动态解析(与 get_traffic 同法); eth0 固定
# 尺寸守护: 超 40 天(~11520 行)裁剪保留 30 天
LOG=/data/gw/traffic_hist.tsv
ST=/tmp/traffic_prev
while :; do
    CIF=$(ip -o -4 addr show 2>/dev/null | grep -m1 'ccmni.*inet' | awk '{print $2}')
    CRC=0; CTC=0
    [ -n "$CIF" ] && {
        CRC=$(cat /sys/class/net/$CIF/statistics/rx_bytes 2>/dev/null || echo 0)
        CTC=$(cat /sys/class/net/$CIF/statistics/tx_bytes 2>/dev/null || echo 0)
    }
    ERC=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null || echo 0)
    ETC=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null || echo 0)
    PC=0; PT=0; PE=0; PF=0
    [ -r $ST ] && . $ST
    DC=$((CRC-PC)); [ $DC -lt 0 ] && DC=$CRC
    DT=$((CTC-PT)); [ $DT -lt 0 ] && DT=$CTC
    DE=$((ERC-PE)); [ $DE -lt 0 ] && DE=$ERC
    DF=$((ETC-PF)); [ $DF -lt 0 ] && DF=$ETC
    echo "$(date +%s) $DC $DT $DE $DF" >> $LOG
    echo "PC=$CRC; PT=$CTC; PE=$ERC; PF=$ETC" > $ST
    L=$(wc -l < $LOG 2>/dev/null || echo 0)
    [ "$L" -gt 11520 ] && { tail -8640 $LOG > $LOG.t 2>/dev/null && mv $LOG.t $LOG; }
    sleep 300
done
