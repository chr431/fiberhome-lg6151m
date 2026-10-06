#!/bin/sh
# cellular_replay.sh v2.0 -- 开机重放蜂窝锁定 (频段/小区)
# v2.0 (P1): 频段锁双引擎 -- BAND_ENGINE=mipc(缺省)时经 /data/gw/mipc_cellular
#   直发模组(168B 结构, 不经树/不经 mobilenetwork 翻译), tree 时走原厂 cfg 树。
#   小区锁仍走树 (mobilenetwork 在跑, EMMCHLCK 翻译可靠)。
# 由 rc_netfh 在 modem 栈就绪后调用。
CONF=/data/gw/cellular.conf
[ -r "$CONF" ] || exit 0
. "$CONF"
export LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib
C=/fhrom/bin/cfg_cmd
T=InternetGatewayDevice.X_FH_MobileNetwork
NS=$T.NetworkSettings
CL=$T.LockCellList
BAND_ENGINE=mipc
[ -r /data/gw/cellular_engine.conf ] && . /data/gw/cellular_engine.conf

# 频段锁
if [ "${BAND_EN:-0}" = 1 ]; then
    if [ "$BAND_ENGINE" = mipc ] && [ -x /data/gw/mipc_cellular ]; then
        /data/gw/mipc_cellular setlock lte="${LTE_MASK:-all}" nr="${NR_MASK:-all}" \
            >/tmp/bandlock_replay.log 2>&1
        echo "cellular_replay: bandlock(mipc) 1 lte=[$LTE_MASK] nr=[$NR_MASK] rc=$?" >> /tmp/rc_netfh.log
    else
        $C set $NS.LockBandEnable 0 >/dev/null 2>&1      # 先关再开, 触发完整应用路径
        $C set $NS.LTELockBAND "$LTE_MASK" >/dev/null 2>&1
        $C set $NS.NRLockBAND "$NR_MASK" >/dev/null 2>&1
        $C set $NS.LockBandEnable 1 >/dev/null 2>&1
        echo "cellular_replay: bandlock(tree) 1 lte=[$LTE_MASK] nr=[$NR_MASK]" >> /tmp/rc_netfh.log
    fi
fi

# 小区锁
if [ "${CELL_EN:-0}" = 1 ]; then
    if [ "$BAND_ENGINE" = mipc ] && [ -x /data/gw/mipc_cellular ]; then
        i=1; N=0
        while [ $i -le 20 ]; do
            eval "E=\${CELL_$i:-}"
            [ -z "$E" ] && break
            ACT=${E%%:*}; REST=${E#*:}; ARF=${REST%%:*}; PC=${REST##*:}
            case "$ACT" in lte) R=7 ;; nr) R=11 ;; *) R=11 ;; esac
            mipc_wan_cli --at_cmd "AT+EMMCHLCK=1,$R,0,$ARF,$PC,0" >/dev/null 2>&1
            N=$((N+1)); i=$((i+1))
        done
        [ $N -eq 0 ] && mipc_wan_cli --at_cmd "AT+EMMCHLCK=0" >/dev/null 2>&1
        echo "cellular_replay: celllock(mipc) 1 entries=$N" >> /tmp/rc_netfh.log
    else
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
        echo "cellular_replay: celllock(tree) 1 entries=$((i-1))" >> /tmp/rc_netfh.log
    fi
fi
