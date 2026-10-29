# api_cell.sh v1.1 — 蜂窝域模块 (被 api.sh 按端点懒加载; 依赖核心的 helpers/cfg 助手)
# v1.1 (2026-10-17 日志加密轮): cells 成败/耗时、锁频/锁小区/制式/飞行/扫描/PIN 动作
#   全部写 /tmp/api.log(PIN 值脱敏) — GUI 操作与模组实际响应可对照。
# v1.0 (2026-10-17 架构轮): 自 api.sh v2.74 拆出 — cellular/sim/pin/netmode/airplane/
#   plmn_scan/bandlock/celllock 端点族 + cfgmgr 树访问助手。域历史(自 api.sh 头注迁入):
# v2.63: netmode_set 变更时后台自动重附(cfun循环) — 实弹实证 LTE→NR-SA 不自发重选,
#   重发 nwmode 也不触发, 不重附则改完驻留 LTE 不生效; 幂等重应用不重附。
# v2.62: 组网模式 ENDC: netmode 增 endc 字段(1=SA 2=NSA 3=SA+NSA, 存 cellular.conf
#   ENDC_MODE), apply_netmode 照抄官方联动规则(仅5G强制SA/仅4G-3G不下发)经
#   mipc_cellular endc 下发。
# v2.61: sim reg 推导修正: 本模组 AT CEREG?/CREG? 恒 0,0(数据畅通仍报未注册, 实测)
#   — 改由 COPS 是否返回 PLMN 推导。
# v2.60: 蜂窝 conf 写方统一 upsert(cell_set): 原频段锁整文件覆盖冲掉 NM_MODE/CELL_i、
#   celllock del 压实丢 NM_MODE、clear 重复键 — 同文件多写方互毁全消。
# v2.35 (P3 终章): mipc 引擎下服务小区+CA 列表直取 ql_nw_get_cell_info
#   (mipc_cellular cells) — 不再依赖树回填; 树路径仅在 engine=tree 时使用。
# v2.33 (P3.5): 制式/飞行/PIN AT 直发(A 组逆向的官方映射): mode 0→AT+erat=3 ...
#   飞行 ON: 停拨号 + AT+cfun=0; OFF: AT+cfun=1(dial_keeper 自动重拨)。
# v2.31 (P4.1): plmn_scan = ql_nw_network_scan 原生扫描(mipc_cellular 封装, 10-60s)。
# v2.26 (P3.5): 小区锁 AT 直发引擎 EMMCHLCK=1,<AcT>,0,<arfcn>,<pci>,0 与频段锁互斥。
# ---------- cellular (载波信息/锁频段/锁小区; 树+AT 双引擎) ----------
FH_TREE=InternetGatewayDevice.X_FH_MobileNetwork
MN_TREE=InternetGatewayDevice.X_FH_MobileNetwork
cfgget() { LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd get "$1" 2>/dev/null | sed -n 's/^get success!value=//p'; }
cfgset_ok() { LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd set "$1" "$2" 2>/dev/null | grep -q "set success"; }
cfgdel_ok() { LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd del "$1" >/dev/null 2>&1; }
op_name() {
    case "$1" in
        46000|46002|46004|46007|46008) echo "中国移动" ;;
        46001|46006|46009) echo "中国联通" ;;
        46003|46005|46011|46012) echo "中国电信" ;;
        46015|46016) echo "中国广电" ;;   # v2.54: 46015 误入联通组(192 号段卡实测显示错误); 46016 同属广电
        *) echo "${1:-未知}" ;;
    esac
}

get_cellular() {
    # v2.35 (P3 终章): mipc 引擎下服务小区+CA 列表直取 ql_nw_get_cell_info
    # (mipc_cellular v0.5 cells, cellraw 实证布局) — 不再依赖树回填, mobilenetwork
    # 至此零消费者。树路径仅在 engine=tree 时使用。
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$CELL_ENGINE" = mipc ] && [ -x /data/gw/mipc_cellular ]; then
        _t0=$(date +%s)
        CJ=$(/data/gw/mipc_cellular cells 2>/dev/null | head -1)
        _ms=$(( $(date +%s) - _t0 ))
        case "$CJ" in
        '"serving"'*|'{"serving"'*)
            [ "$_ms" -ge 2 ] && alog "INFO cellular cells ok ${_ms}s"
            CSQ=$(mipc_wan_cli --at_cmd "AT+CSQ" 2>/dev/null | grep -oE "[0-9]+, ?99" | cut -d, -f1)
            RSSI=""; case "$CSQ" in ''|0) RSSI="未知";; *) RSSI="$(( -113 + CSQ * 2 )) dBm";; esac
            CJ=${CJ#\{}; CJ=${CJ%\}}
            CJ=$(printf '%s' "$CJ" | sed "s/\"bw\"/\"rssi\":\"$RSSI\",\"bw\"/")
            COPSR=$(mipc_wan_cli --at_cmd "AT+COPS?" 2>/dev/null | grep -oE '"[0-9]{5,6}"' | tr -d '"')
            [ -r $GWDATA/cellular.conf ] && . $GWDATA/cellular.conf
            # v2.46: bandlock/celllock 须经 %s 展开 — 原写在单引号格式串里,
            # ${BAND_EN:-0} 等字面量直接发给了 GUI(输入框显示 shell 变量原文,
            # 部署后 GUI 抽检抓获); mipc 分支同时回读 CELL_i 锁定表(原恒空)。
            ENTRIES=""
            i=1
            while [ $i -le 20 ]; do
                eval "E=\${CELL_$i:-}"
                [ -z "$E" ] && break
                AC=${E%%:*}; REST=${E#*:}; A=${REST%%:*}; PC=${REST##*:}
                ENTRIES="$ENTRIES{\"idx\":$i,\"act\":\"$AC\",\"arfcn\":\"$A\",\"pci\":\"$PC\"},"
                i=$((i+1))
            done
            ENTRIES=${ENTRIES%,}
            printf '{"operator":{"plmn":"%s","name":"%s"},%s,"bandlock":{"enable":"%s","lte":"%s","nr":"%s"},"celllock":{"enable":"%s","entries":[%s]},"engine":"mipc","ts":%d}'                 "${COPSR:-}" "$(op_name "$COPSR")" "$CJ" "${BAND_EN:-0}" "${LTE_MASK:-}" "${NR_MASK:-}" "${CELL_EN:-0}" "$ENTRIES" "$(date +%s)"
            return ;;
        *)
            alog "WARN cellular cells failed ${_ms}s out=$(printf '%s' "$CJ" | head -c 120)" ;;
        esac
    fi
    R=$FH_TREE.RadioSignalParameter
    PLMN=$(cfgget $R.PLMN)
    BANDS=$(cfgget $R.BAND_NBR); ARFCN=$(cfgget $R.EARFCN_NBR)
    PCI=$(cfgget $R.PCI_NBR); RSRP=$(cfgget $R.RSRP_NBR); SINR=$(cfgget $R.SINR_NBR)
    # v2.26: 锁状态读自管 conf(mipc 引擎; 树为陈旧快照) -- BAND_EN/CELL_EN/CELL_i
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    [ -r $GWDATA/cellular.conf ] && . $GWDATA/cellular.conf
    if [ "$CELL_ENGINE" = mipc ]; then
        BAND_EN=${BAND_EN:-0}; LTE_M=${LTE_MASK:-}; NR_M=${NR_MASK:-}
        CELL_EN=${CELL_EN:-0}
    else
        NS=$FH_TREE.NetworkSettings
        BAND_EN=$(cfgget $NS.LockBandEnable); LTE_M=$(cfgget $NS.LTELockBAND); NR_M=$(cfgget $NS.NRLockBAND)
        CELL_EN=$(cfgget $FH_TREE.LockCellList.LockEnable)
    fi
    ENTRIES=""
    i=1
    while [ $i -le 20 ]; do
        if [ "$CELL_ENGINE" = mipc ]; then
            eval "E=\${CELL_$i:-}"
            [ -z "$E" ] && break
            AC=${E%%:*}; REST=${E#*:}; A=${REST%%:*}; PC=${REST##*:}
        else
            A=$(cfgget $FH_TREE.LockCellList.LockCell.$i.arfcn)
            [ -z "$A" ] && break
            AC=$(cfgget $FH_TREE.LockCellList.LockCell.$i.act); PC=$(cfgget $FH_TREE.LockCellList.LockCell.$i.pci)
        fi
        ENTRIES="$ENTRIES{\"idx\":$i,\"act\":\"$AC\",\"arfcn\":\"$A\",\"pci\":\"$PC\"},"
        i=$((i+1))
    done
    ENTRIES=${ENTRIES%,}
    # 服务小区 = 数组首个; CA 列表计数
    SB=${BANDS%%,*}; SA=${ARFCN%%,*}; SP=${PCI%%,*}
    SR=${RSRP%%,*}; SS=${SINR%%,*}
    # v2.82: 逗号计数改 shell(原 awk -F, NF)
    case "$BANDS" in
        '') NC="" ;;
        *)  NC=$(( $(printf '%s' "$BANDS" | tr -cd ',' | wc -c) + 1 )) ;;
    esac
    CSQ=$(mipc_wan_cli --at_cmd "AT+CSQ" 2>/dev/null | grep -oE "[0-9]+, ?99" | cut -d, -f1)
    RSSI=""; case "$CSQ" in ''|0) RSSI="未知";; *) RSSI="$(( -113 + CSQ * 2 )) dBm";; esac
    # v2.24 (P3): mipc/AT 直读优先, 树值为回退 -- RSRP 实时化 + PLMN/RAT 直查。
    #   树值由 mobilenetwork 周期回填(有滞后), 直读消除断供风险(树死也有活数据)。
    MR=$(mipc_wan_cli --nw_get_signal 2>/dev/null | grep -oE 'RSRP=-?[0-9]+')
    [ -n "$MR" ] && SR="${MR#RSRP=}"
    COPSR=$(mipc_wan_cli --at_cmd "AT+COPS?" 2>/dev/null | grep -oE '\+COPS: [^
]*')
    CNUM=$(printf '%s' "$COPSR" | grep -oE '"[0-9]{5,6}"' | tr -d '"')
    [ -n "$CNUM" ] && PLMN="$CNUM"
    # v2.82: 取 +COPS 末字段(acT)里的数字(原 awk)
    _act=${COPSR##*,}
    ACT=$(printf '%s' "$_act" | tr -cd '0-9')
    case "$ACT" in
        0|1|3) RAT="GSM" ;;
        2|4|5|6) RAT="3G" ;;
        7|13) RAT="LTE" ;;
        11|12) RAT="5G NR" ;;
        *) [ -n "$SB" ] && RAT="5G NR" || RAT="--" ;;
    esac
    cat <<EOF4
{"operator":{"plmn":"${PLMN:-}","name":"$(op_name "$PLMN")"},
"serving":{"band":"${SB:--}","arfcn":"${SA:--}","pci":"${SP:--}","rsrp":"${SR:--}","sinr":"${SS:--}","rssi":"$RSSI","rat":"$RAT"},
"cells":{"band":"${BANDS:-}","arfcn":"${ARFCN:-}","pci":"${PCI:-}","rsrp":"${RSRP:-}","sinr":"${SINR:-}","n":"$NC"},
"bandlock":{"enable":"${BAND_EN:-0}","lte":"${LTE_M:-}","nr":"${NR_M:-}"},
"celllock":{"enable":"${CELL_EN:-0}","entries":[$ENTRIES]},
"ts":$(date +%s)}
EOF4
}

apply_bandlock() {
    EN=$(form_kv enable); LTE=$(form_kv lte); NR=$(form_kv nr)
    [ "$EN" = 0 ] || [ "$EN" = 1 ] || jerr bad_flag
    echo "$LTE$NR" | grep -qE '[^0-9,]' && jerr bad_bands
    case "$LTE$NR" in *,,*|,*) jerr bad_bands;; esac
    [ "$EN" = 1 ] && [ -z "$LTE$NR" ] && jerr empty_bands
    NS=$FH_TREE.NetworkSettings
    # v2.21 (P1): 频段锁双引擎 -- mipc=自研直连(libqlril ql_nw_set_band_mode,
    # 168B 结构已逆向+实弹验证, 不经 mobilenetwork/cfgmgr); tree=原厂树路径。
    # 切换: /data/gw/cellular_engine.conf 写 BAND_ENGINE=tree|mipc (缺省 mipc)。
    BAND_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$BAND_ENGINE" = mipc ] && [ -x /data/gw/mipc_cellular ]; then
        [ "$EN" = 1 ] && LTES=${LTE:-all} && NRS=${NR:-all} || { LTES=all; NRS=all; }
        R=$(/data/gw/mipc_cellular setlock lte="$LTES" nr="$NRS" 2>&1)
        RET=$(printf '%s' "$R" | grep -oE 'ret=[0-9-]+' | tail -1 | cut -d= -f2)
        alog "INFO bandlock en=$EN lte=${LTE:-all} nr=${NR:-all} ret=${RET:-?}"
        [ "$RET" = 0 ] || jerr mipc_fail
        # 状态持久化到自管 conf (mipc 模式不写树; 树同步由 mobilenetwork 上报被动跟随)
        # v2.60: 整文件覆盖改 cell_set upsert — 原写法冲掉 NM_MODE 与 CELL_i 表(跨功能状态互毁)
        cell_set BAND_EN "$EN"; cell_set LTE_MASK "$LTE"; cell_set NR_MASK "$NR"
        cell_set CELL_EN 0
        ok_json '"engine":"mipc","note":"modem重扫约20-60s"'
        return
    fi
    # 互斥: 开频段锁 -> 关小区锁 (原厂同款约束, 服务端强制)
    if [ "$EN" = 1 ]; then
        cfgset_ok $FH_TREE.LockCellList.LockEnable 0 || jerr tree_fail
    fi
    cfgset_ok $NS.LockBandEnable "$EN" || jerr tree_fail
    cfgset_ok $NS.LTELockBAND "$LTE" || jerr tree_fail
    cfgset_ok $NS.NRLockBAND "$NR"    || jerr tree_fail
    cell_persist
    ok_json '"engine":"tree"'
}

# v2.26 (P3.5): 小区锁 AT 直发引擎 -- EMMCHLCK=1,<AcT>,0,<arfcn>,<pci>,0
#   (AcT: lte=7, nr=11, 3GPP TS 27.007 语义; =? 实测参数域 {0,2,7,11})
#   与频段锁互斥(原厂同款); 空表=EMMCHLCK=0 解锁。CELL_ENGINE 切换同
#   cellular_engine.conf, 缺省 mipc, 树路径保留为回退。
celllock_forget_env() {  # 清掉此前 source 残留的 CELL_* 环境变量(防重发旧锁)
    for _k in $(set | cut -d= -f1 | grep -E '^CELL_[0-9]+$'); do unset "$_k"; done
}

celllock_send_all() {  # 从 cellular.conf 的 CELL_i 全量下发
    N=0; FIRST=1
    i=1
    while [ $i -le 20 ]; do
        eval "E=\${CELL_$i:-}"
        [ -z "$E" ] && break
        ACT=${E%%:*}; REST=${E#*:}; ARF=${REST%%:*}; PC=${REST##*:}
        case "$ACT" in lte) R=7 ;; nr) R=11 ;; *) R=11 ;; esac
        mipc_wan_cli --at_cmd "AT+EMMCHLCK=1,$R,0,$ARF,$PC,0" >/dev/null 2>&1
        N=$((N+1)); i=$((i+1))
    done
    [ $N -eq 0 ] && mipc_wan_cli --at_cmd "AT+EMMCHLCK=0" >/dev/null 2>&1
    echo $N
}

apply_celllock() {
    OP=$(form_kv op)
    CL=$FH_TREE.LockCellList
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$CELL_ENGINE" = mipc ]; then
        CONF=$GWDATA/cellular.conf
        [ -r "$CONF" ] && . "$CONF"
        case "$OP" in
        add)
            ACT=$(form_kv act); ARF=$(form_kv arfcn); PC=$(form_kv pci)
            [ "$ACT" = lte ] || [ "$ACT" = nr ] || jerr bad_act
            echo "$ARF$PC" | grep -qE '[^0-9]' && jerr bad_num
            [ "$ARF" -ge 0 ] 2>/dev/null && [ "$ARF" -le 875000 ] 2>/dev/null || jerr bad_arfcn
            [ "$PC" -ge 0 ] 2>/dev/null && [ "$PC" -le 2000 ] 2>/dev/null || jerr bad_pci
            # 找空位(重号拒绝)
            i=1; while [ $i -le 20 ]; do
                eval "E=\${CELL_$i:-}"
                [ -z "$E" ] && break
                [ "$E" = "$ACT:$ARF:$PC" ] && jerr dup_cell
                i=$((i+1))
            done
            [ $i -gt 20 ] && jerr list_full
            cell_set "CELL_$i" "$ACT:$ARF:$PC"
            ;;
        del)
            IDX=$(form_kv idx); echo "$IDX" | grep -qE '^[0-9]+$' || jerr bad_idx
            [ "$IDX" -ge 1 ] && [ "$IDX" -le 20 ] || jerr bad_idx
            grep -v "^CELL_$IDX=" "$CONF" 2>/dev/null > "$CONF.new.$$" && mv "$CONF.new.$$" "$CONF"
            # 压实槽位(防空洞); v2.60: 保留其余键(NM_MODE 等) — 原 awk 白名单
            #   只回写 CELL_*/锁键, del 一次就把 NM_MODE 冲掉
            grep -v '^CELL_' "$CONF" 2>/dev/null > "$CONF.new.$$"
            n=1; grep -oE '^CELL_[0-9]+=[^[:space:]]+' "$CONF" | cut -d= -f2- | while read -r e; do
                [ -n "$e" ] && { echo "CELL_$n=$e" >> "$CONF.new.$$"; n=$((n+1)); }
            done
            mv "$CONF.new.$$" "$CONF"
            ;;
        clear)
            grep -v '^CELL_' "$CONF" 2>/dev/null > "$CONF.new.$$" || true
            mv "$CONF.new.$$" "$CONF"
            cell_set CELL_EN 0
            ;;
        *) jerr bad_op ;;
        esac
        celllock_forget_env
        . "$CONF"
        # 全量下发 + 互斥(开小区锁时解锁频段); v2.60: sed/裸 append 改 cell_set(防重复键)
        if [ "$OP" = add ]; then
            [ "${BAND_EN:-0}" = 1 ] && { /data/gw/mipc_cellular unlock >/dev/null 2>&1; cell_set BAND_EN 0; }
            cell_set CELL_EN 1
        elif [ "$OP" = clear ]; then
            [ "${BAND_EN:-0}" = 1 ] && /data/gw/mipc_cellular setlock lte="${LTE_MASK:-all}" nr="${NR_MASK:-all}" >/dev/null 2>&1
        fi
        celllock_forget_env
        . "$CONF"
        N=$(celllock_send_all)
        alog "INFO celllock op=$OP entries=$N band_en=${BAND_EN:-0}"
        ok_json '"engine":"mipc","cells":'$N',"note":"modem重扫约20-60s"'
        return
    fi
    case "$OP" in
    add)
        ACT=$(form_kv act); ARF=$(form_kv arfcn); PC=$(form_kv pci)
        [ "$ACT" = lte ] || [ "$ACT" = nr ] || jerr bad_act
        echo "$ARF$PC" | grep -qE '[^0-9]' && jerr bad_num
        [ "$ARF" -ge 0 ] 2>/dev/null && [ "$ARF" -le 875000 ] 2>/dev/null || jerr bad_arfcn
        [ "$PC" -ge 0 ] 2>/dev/null && [ "$PC" -le 2000 ] 2>/dev/null || jerr bad_pci
        i=1; while [ $i -le 20 ] && [ -n "$(cfgget $CL.LockCell.$i.arfcn)" ]; do i=$((i+1)); done
        [ $i -gt 20 ] && jerr list_full
        cfgset_ok $CL.LockCell.$i.act "$ACT"   || jerr tree_fail
        cfgset_ok $CL.LockCell.$i.arfcn "$ARF" || jerr tree_fail
        cfgset_ok $CL.LockCell.$i.pci "$PC"    || jerr tree_fail
        # 互斥: 开小区锁 -> 关频段锁
        cfgset_ok $FH_TREE.NetworkSettings.LockBandEnable 0 || jerr tree_fail
        cfgset_ok $CL.LockEnable 1 || jerr tree_fail
        ;;
    del)
        IDX=$(form_kv idx); echo "$IDX" | grep -qE '^[0-9]+$' || jerr bad_idx
        cfgset_ok $CL.LockCell.$IDX.act ""   || jerr tree_fail
        cfgset_ok $CL.LockCell.$IDX.arfcn "" || jerr tree_fail
        cfgset_ok $CL.LockCell.$IDX.pci ""   || jerr tree_fail
        ;;
    clear)
        # cfg_cmd del 是残废 — 清字段代替删实例(槽位恒存于快照)
        i=1; while [ $i -le 20 ]; do
            cfgset_ok $CL.LockCell.$i.act ""   2>/dev/null
            cfgset_ok $CL.LockCell.$i.arfcn "" 2>/dev/null
            cfgset_ok $CL.LockCell.$i.pci ""   2>/dev/null
            i=$((i+1))
        done
        cfgset_ok $CL.LockEnable 0 || jerr tree_fail
        ;;
    *) jerr bad_op ;;
    esac
    cell_persist
    ok_json
}

# 持久化到自管 conf — v2.60: 仅 tree 引擎(兼容回滚路径)调用; upsert 保 NM_MODE 等他键
#   (原整文件覆盖); mipc 引擎的写方在各 apply 内联 cell_set。
cell_persist() {
    NS=$FH_TREE.NetworkSettings
    cell_set BAND_EN "$(cfgget $NS.LockBandEnable)"
    cell_set LTE_MASK "$(cfgget $NS.LTELockBAND)"
    cell_set NR_MASK "$(cfgget $NS.NRLockBAND)"
    cell_set CELL_EN "$(cfgget $FH_TREE.LockCellList.LockEnable)"
    i=1; while [ $i -le 20 ]; do
        A=$(cfgget $FH_TREE.LockCellList.LockCell.$i.arfcn); [ -z "$A" ] && break
        cell_set "CELL_$i" "$(cfgget $FH_TREE.LockCellList.LockCell.$i.act):$A:$(cfgget $FH_TREE.LockCellList.LockCell.$i.pci)"
        i=$((i+1))
    done
    # 树快照(16MB→~127KB): 开机 cfg_tool 建出厂树后整体恢复, 锁定跨重启
    # v2.60: shm 不在(树退役态)时跳过 — 原静默失败留误导性假快照链
    # v2.82: 找 key 为 0x1000000(16MB) 的 shm 段(原 awk NR>1 && $4==16777216)
    _shm=0
    while read -r _sk _sid _sperm _ssz _srest; do
        case "$_ssz" in ''|*[!0-9]*) continue ;; esac
        [ "$_ssz" = 16777216 ] && { _shm=1; break; }
    done < /proc/sysvipc/shm 2>/dev/null
    [ "$_shm" = 1 ] && \
    /data/gw/shmsnap save /tmp/cfgtree.snap >/dev/null 2>&1 &&         gzip -c /tmp/cfgtree.snap > /data/gw/cfgtree.snap.gz 2>/dev/null &&         rm -f /tmp/cfgtree.snap
}

# -- SIM / PIN (展示+PIN管理; 误锁风险提示在前端) --
get_sim() {
    # v2.33: AT 直读优先(CPIN/CIMI/CCID/CGSN/COPS), 树值仅回退 — 展示面独立于 mobilenetwork
    # v2.60: 死树回退删除 + phone/reg 迁活源(CNUM/CEREG) — 树 v3.1 退役后 cfgget 恒空,
    #   "手机号/注册状态"两栏自退役起就恒空(与 NTP 卡片同族僵尸)。
    A_STAT=$(mipc_wan_cli --at_cmd "AT+CPIN?" 2>/dev/null | grep -oE 'CPIN: [A-Z ]+' | cut -d' ' -f2-)
    A_IMSI=$(mipc_wan_cli --at_cmd "AT+CIMI" 2>/dev/null | grep -oE '^[0-9]{15}' | head -1)
    A_ICCID=$(mipc_wan_cli --at_cmd "AT+CCID" 2>/dev/null | grep -oE '[0-9]{19,20}' | head -1)
    A_IMEI=$(mipc_wan_cli --at_cmd "AT+CGSN" 2>/dev/null | grep -oE '^[0-9]{15}' | head -1)
    A_OPS=$(mipc_wan_cli --at_cmd "AT+COPS?" 2>/dev/null | grep -oE '"[0-9]{5,6}"' | tr -d '"')
    # v2.60: CNUM=本机号(未开通即空=诚实显示)。注册态 v2.61 修正: 本模组 AT CEREG?/CREG?
    # 恒 0,0(实测数据畅通仍报未注册 — AT 语境注册≠数据栈注册), 改由 COPS 是否返回
    # 运营商数字标识推导(有 PLMN=已注册 1, 无=0)。
    A_NUM=$(mipc_wan_cli --at_cmd "AT+CNUM" 2>/dev/null | grep -oE '\+CNUM: *"[^"]*","[+0-9]+"' | sed 's/.*"\(+[0-9]*\)"$/\1/')
    A_REG=""; [ -n "$A_OPS" ] && A_REG=1
    printf '{"status":"%s","imsi":"%s","iccid":"%s","carrier":"%s","imei":"%s","phone":"%s","reg":"%s","pin_state":"%s","ts":%d}'         "${A_STAT:-}" "${A_IMSI:-}"         "${A_ICCID:-}" "$(op_name "${A_OPS:-}")"         "${A_IMEI:-}" "$A_NUM"         "${A_REG:-}" "$(mipc_wan_cli sim_pin_info_get 2>/dev/null | grep -oE 'state:[0-9]+' | cut -d: -f2)" "$(date +%s)"
}
apply_pin() {
    # v2.33 (P3.5): AT 直发引擎 — 厂商序列(mobilenetwork strings 实证):
    #   disable: at+clck="sc",0,"PIN"   enable: at+clck="sc",1,"PIN"
    #   change:  at+cpwd="sc","OLD","NEW"
    #   unblock: at+cpin="NEW","PUK"     verify: at+cpin="PIN"
    # 误锁风险提示在前端; AT 与 ubus 等价(同一模组面)。
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$CELL_ENGINE" = mipc ]; then
        ACT=$(form_kv action)
        P=$(form_kv pin); NP=$(form_kv new_pin); PUK=$(form_kv puk)
        for v in "$P" "$NP" "$PUK"; do
            printf '%s' "$v" | grep -qE '[^0-9]' && jerr bad_pin
        done
        case "$ACT" in
        disable) ATCMD=$(printf 'at+clck="sc",0,"%s"' "$P") ;;
        enable)  ATCMD=$(printf 'at+clck="sc",1,"%s"' "$P") ;;
        change)  ATCMD=$(printf 'at+cpwd="sc","%s","%s"' "$P" "$NP") ;;
        unblock) ATCMD=$(printf 'at+cpin="%s","%s"' "$NP" "$PUK") ;;
        *) jerr bad_action ;;
        esac
        OUT=$(mipc_wan_cli --at_cmd "$ATCMD" 2>/dev/null)
        printf '%s' "$OUT" | grep -qiE 'error|CME' && jerr pin_fail
        printf '%s' "$OUT" | grep -qi OK || jerr pin_fail
        alog "INFO pin action=$ACT ok (values redacted)"
        ok_json '"engine":"mipc"'
        return
    fi
    ACT=$(form_kv action)
    P=$(form_kv pin); NP=$(form_kv new_pin); PUK=$(form_kv puk)
    for v in "$P" "$NP" "$PUK"; do
        printf '%s' "$v" | grep -qE '[^0-9]' && jerr bad_pin
    done
    case "$ACT" in
    disable) ARGS="\"pin_lock\":\"0\",\"pin_code\":\"$P\"" ;;
    enable)  ARGS="\"pin_lock\":\"1\",\"pin_code\":\"$P\"" ;;
    change)  ARGS="\"pin_lock\":\"2\",\"pin_code\":\"$NP\",\"old_pin_code\":\"$P\"" ;;
    unblock) ARGS="\"pin_lock\":\"3\",\"pin_code\":\"$NP\",\"puk_code\":\"$PUK\"" ;;
    *) jerr bad_action ;;
    esac
    R=$(ubus call mobile_network update_pin_info "{$ARGS}" 2>&1 | head -c 100)
    case "$R" in
        "{"*) ok_json '"ubus":"'"$(printf '%s' "$R" | tr -d '\n')"'"' ;;
        *) jerr pin_fail ;;
    esac
}

# -- 网络制式/飞行模式/手动选网 --
erat_of() {
    case "$1" in
        0) echo "3" ;;
        1|3) echo "19,0" ;;
        2) echo "15" ;;
        4) echo "1" ;;
        *) return 1 ;;
    esac
}
get_netmode() {
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    [ -r $GWDATA/cellular.conf ] && . $GWDATA/cellular.conf
    if [ "$CELL_ENGINE" = mipc ]; then
        CF=$(mipc_wan_cli --at_cmd "AT+CFUN?" 2>/dev/null | grep -oE 'CFUN: [0-9]' | grep -oE '[0-9]')
        AP=0; [ "$CF" = 0 ] && AP=1
        printf '{"mode":"%s","airplane":"%s","endc":"%s","engine":"mipc","ts":%d}' \
            "${NM_MODE:-1}" "$AP" "${ENDC_MODE:-3}" "$(date +%s)"
    else
        NS=$MN_TREE.NetworkSettings
        printf '{"mode":"%s","airplane":"%s","sms_disable":"%s","plmn_scan":"0","ts":%d}' \
            "$(cfgget $NS.NetworkMode)" "$(cfgget $NS.AirplaneEnable)" \
            "$(cfgget $NS.sms_disable)" "$(date +%s)"
    fi
}
apply_netmode() {
    M=$(form_kv mode)
    echo "$M" | grep -qE '^[0-4]$' || jerr bad_mode
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$CELL_ENGINE" = mipc ]; then
        [ -r $GWDATA/cellular.conf ] && . $GWDATA/cellular.conf
        OM=${NM_MODE:-1}; OE=${ENDC_MODE:-3}   # v2.63: 变更前值(供重附判定)
        E=$(erat_of "$M") || jerr bad_mode
        R=$(mipc_wan_cli --at_cmd "AT+erat=$E" 2>/dev/null | grep -c OK)
        [ "$R" -ge 1 ] || jerr at_fail
        cell_set NM_MODE "$M"   # v2.60: upsert(原 sed 删+append, 等价但统一助手)
        # v2.62: 组网模式 ENDC (1=SA 2=NSA 3=SA+NSA) — 官方 GUI 联动规则照抄:
        #   仅5G(2) 强制 SA(NSA 需 LTE 锚点); 仅4G/3G(0/4) 不适用(不下发不改存储)。
        # 下发经 mipc_cellular endc (厂商 fh_set_endc 同款序列, 工具内含写后读回)。
        EC=$(form_kv endc)
        case "$M" in
            2) EC=1 ;;
            0|4) EC="" ;;
        esac
        if [ -n "$EC" ]; then
            printf '%s' "$EC" | grep -qE '^[123]$' || jerr bad_mode
            ERC=$(/data/gw/mipc_cellular endc set "$EC" 2>&1)
            printf '%s' "$ERC" | grep -q '"ret":0' || jerr at_fail
            cell_set ENDC_MODE "$EC"
        fi
        # v2.63: 配置实际变化 -> 后台重附(cfun 循环)。实证: LTE 驻留时改 ENDC/制式,
        #   LTE→NR-SA 不自发重选, 重发 nwmode 也不触发, 不重附则新值不生效(2026-10-09 实弹);
        #   CFUN 循环=厂商飞行同款恢复路径, keeper 约 40s 自动重拨。幂等重应用不重附。
        if [ "$OM" != "$M" ] || { [ -n "$EC" ] && [ "$OE" != "$EC" ]; }; then
            alog "INFO netmode reattach (mode $OM->$M endc $OE->${EC:-keep})"
            ( sleep 2
              mipc_wan_cli --at_cmd "AT+cfun=0" >/dev/null 2>&1
              sleep 8
              mipc_wan_cli --at_cmd "AT+cfun=1" >/dev/null 2>&1 ) >/dev/null 2>&1 &
            ok_json '"engine":"mipc","erat":"'"$E"'","note":"reattaching"'
            return
        fi
        alog "INFO netmode mode=$M erat=$E (idempotent, no reattach)"
        ok_json '"engine":"mipc","erat":"'"$E"'"'
        return
    fi
    cfgset_ok $MN_TREE.NetworkSettings.NetworkMode "$M" || jerr tree_fail
    ok_json
}
apply_airplane() {
    V=$(form_kv on)
    [ "$V" = 0 ] || [ "$V" = 1 ] || jerr bad_flag
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$CELL_ENGINE" = mipc ]; then
        if [ "$V" = 1 ]; then
            APN=$(mipc_wan_cli --apn_provision_by_sim 2>/dev/null | grep -oE '"apn": *"[^"]+"' | cut -d'"' -f4)
            [ -n "$APN" ] && mipc_wan_cli --data_call_deact_apn "$APN" >/dev/null 2>&1
            R=$(mipc_wan_cli --at_cmd "AT+cfun=0" 2>/dev/null | grep -c OK)
        else
            R=$(mipc_wan_cli --at_cmd "AT+cfun=1" 2>/dev/null | grep -c OK)
        fi
        [ "$R" -ge 1 ] || jerr at_fail
        alog "INFO airplane on=$V (dial_keeper will re-dial after OFF)"
        ok_json '"engine":"mipc","note":"OFF后dial_keeper约40s自动重拨"'
        return
    fi
    cfgset_ok $MN_TREE.NetworkSettings.AirplaneEnable "$V" || jerr tree_fail
    ok_json
}
net_plmn_scan() {
    # v2.32 (P4.1 完成): ql_nw_network_scan 原生扫描(C 组逆向, 异步回调+0x1288
    #   结构), mipc_cellular v0.4 封装为同步 JSON 输出。扫描 10-60s。
    _t0=$(date +%s)
    R=$(/data/gw/mipc_cellular scan 60 2>/dev/null | head -1)
    _ms=$(( $(date +%s) - _t0 ))
    case "$R" in
        '"count"'*|'{"count"'*) alog "INFO plmn_scan ok ${_ms}s $R"; printf '%s' "$R" ;;
        *) alog "WARN plmn_scan failed ${_ms}s out=$(printf '%s' "$R" | head -c 120)"
           printf '{"error":"scan_failed","detail":"%s"}' "${R:-tool_missing}" ;;
    esac
}
