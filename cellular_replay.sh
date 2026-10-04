#!/bin/sh
# cellular_replay.sh v1.0 -- 开机重放蜂窝锁定 (频段/小区) 到 cfgmgr 树
# 树每次开机由出厂档案重建(param.pdt.enc), 锁定状态存 /data/gw/cellular.conf
# 由 rc_netfh 在 mobilenetwork 启动后调用 (mobilenetwork 的 lockband/celllock
# 线程监听树变化并下发 ql_nw 到模组)
CONF=/data/gw/cellular.conf
[ -r "$CONF" ] || exit 0
. "$CONF"
export LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib
C=/fhrom/bin/cfg_cmd
T=InternetGatewayDevice.X_FH_MobileNetwork
NS=$T.NetworkSettings
CL=$T.LockCellList

# 频段锁
if [ "${BAND_EN:-0}" = 1 ]; then
    $C set $NS.LockBandEnable 0 >/dev/null 2>&1      # 先关再开, 触发完整应用路径
    $C set $NS.LTELockBAND "$LTE_MASK" >/dev/null 2>&1
    $C set $NS.NRLockBAND "$NR_MASK" >/dev/null 2>&1
    $C set $NS.LockBandEnable 1 >/dev/null 2>&1
    echo "cellular_replay: bandlock 1 lte=[$LTE_MASK] nr=[$NR_MASK]" >> /tmp/rc_netfh.log
fi

# 小区锁
if [ "${CELL_EN:-0}" = 1 ]; then
    i=1
    while [ $i -le 20 ]; do
        eval "E=\${CELL_$i:-}"
        [ -z "$E" ] && break
        ACT=${E%%:*}; REST=${E#*:}; ARF=${REST%%:*}; PC=${REST##*:}
        $C set $CL.LockCell.$i.act "$ACT" >/dev/null 2>&1
        $C set $CL.LockCell.$i.arfcn "$ARF" >/dev/null 2>&1
        $C set $CL.LockCell.$i.pci "$PC" >/dev/null 2>&1
        i=$((i+1))
    done
    $C set $CL.LockEnable 1 >/dev/null 2>&1
    echo "cellular_replay: celllock 1 entries=$((i-1))" >> /tmp/rc_netfh.log
fi
