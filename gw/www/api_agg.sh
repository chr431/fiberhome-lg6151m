# api_agg.sh v1.0 — 聚合+上行域模块 (被 api.sh 按端点懒加载; 依赖核心的 helpers/cfg 助手)
# v1.0 (2026-10-17 架构轮): 自 api.sh v2.74 拆出 — agg/agg_weights/agg_mode/agg_pin +
#   uplink/uplink_set/uplink_form 端点族。域历史(自 api.sh 头注迁入):
# v2.48(P1-B): AUTHD_CMD 收权 root 通道 — GUI/API 不再可写(原字符集校验仍放行
#   "telnetd -p 2323" 类现成 root 二进制 = 一键 root 化); 仅经 SSH 手编 uplink.conf。
# v2.51: AUTHD_CMD 带空格(二进制+iface 参数)引号落盘 — 裸 KEY=v1 v2 被 `. conf`
#   按 POSIX 解析为"env 前缀赋值+执行 v2", 冷启动 authd 永不拉起(实弹)。
# v2.45: 五模式聚合选择(对齐原厂), wan_agg 热载生效; 权重滑块限 5..95。
# 另外: apply_uplink_form 的 eth0 原生 MAC 还原改调 wifi_macplan.sh 统一实现
#   (原内联副本缺 brmac 档案不可读时的两级兜底 = 算法漂移实例, 本轮收敛)。
apply_agg_weights() {
    W1=$(form_kv w1)
    echo "$W1" | grep -qE '^[0-9]{1,3}$' || jerr bad_pct
    # v2.45: 按权重分流滑块限 5..95 (极端值语义由显式模式承担, 引擎不再解释 0/100)
    [ "$W1" -ge 5 ] && [ "$W1" -le 95 ] || jerr bad_pct
    W2=$((100 - W1))
    MD=$(grep -m1 '^MODE=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    case "$MD" in weight|cell_prio|eth_prio|cell_only|eth_only) ;; *) MD=weight ;; esac
    printf 'MODE=%s\nW1_PCT=%s\nW2_PCT=%s\nENABLE=1\n' "$MD" "$W1" "$W2" > $GWDATA/agg.conf
    # v2.20: vendor ioctl 只是引擎可用时的即时加速, 守护热载为准 — 不再因 ioctl 失败误报
    LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib LD_PRELOAD=$GWDATA/fhstub.so \
        $GWDATA/multiwan_ctl 1 $W1 $W2 1 1 >/dev/null 2>&1
    ok_json
}
apply_agg_mode() {   # v2.45: 聚合模式选择(对齐原厂五模式), wan_agg 热载生效
    M=$(form_kv mode)
    case "$M" in
        weight|cell_prio|eth_prio|cell_only|eth_only) ;;
        *) # legacy enable=0/1 兼容(GUI 旧版/脚本)
           E=$(form_kv enable)
           case "$E" in
               0) M=cell_only ;;
               1) M=weight ;;
               *) jerr bad_mode ;;
           esac ;;
    esac
    W=$(grep -m1 '^W1_PCT=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    echo "$W" | grep -qE '^[0-9]{1,3}$' || W=30
    [ "$W" -ge 5 ] && [ "$W" -le 95 ] || W=30
    printf 'MODE=%s\nW1_PCT=%s\nW2_PCT=%s\nENABLE=1\n' "$M" "$W" "$((100-W))" > $GWDATA/agg.conf
    ok_json
}
apply_agg_pin() {
    M=$(form_kv mac | tr 'A-F' 'a-f')
    echo "$M" | grep -qE '^[0-9a-f:]{17}$' || jerr bad_mac
    OP=$(form_kv op)
    [ "$OP" = 0 ] || [ "$OP" = 1 ] || [ "$OP" = 2 ] || jerr bad_op
    grep '^#' $GWDATA/agg_pins.conf 2>/dev/null > /tmp/p.$$
    grep -vE "^#|^$M " $GWDATA/agg_pins.conf 2>/dev/null >> /tmp/p.$$
    [ "$OP" != 0 ] && echo "$M $OP" >> /tmp/p.$$
    mv /tmp/p.$$ $GWDATA/agg_pins.conf
    LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib LD_PRELOAD=/data/gw/fhstub.so \
        $GWDATA/multiwan_ctl mac "$M" "$OP" >/dev/null 2>&1 || jerr ioctl_fail
    ok_json
}

get_agg() {
    PINS=$(grep -v '^#' $GWDATA/agg_pins.conf 2>/dev/null | tr '\n' ';' | sed 's/;$/\n/')
    MACS=$(grep -A9 'Current configuration:' /proc/multi_wan/mac_config 2>/dev/null | grep -E '^[0-9a-f]{2}:' | tr '\n' ';' | sed 's/;$//')
    AGG_EN=$(grep -m1 '^ENABLE=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    case "$AGG_EN" in 0|1) ;; *) AGG_EN=1 ;; esac
    AGG_MODE=$(grep -m1 '^MODE=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    case "$AGG_MODE" in weight|cell_prio|eth_prio|cell_only|eth_only) ;; *) AGG_MODE=weight ;; esac
    cat <<EOF3
{"enable":"$AGG_EN",
"mode":"$AGG_MODE",
"engine":"$(cat /tmp/wan_engine 2>/dev/null)",
"weights":{"w1":"$(grep "WAN1 weight" /proc/multi_wan/weight 2>/dev/null | grep -oE "[0-9]+" | tail -1)"},
"wanmode":"$(cat /tmp/wan_mode 2>/dev/null)",
"pins_conf":"${PINS}",
"pins_live":"${MACS}",
"log":"$(tail -8 /tmp/wan_agg.log 2>/dev/null | tail -1 | sed 's/"/\\"/g')",
"ts":$(date +%s)}
EOF3
}

# ---------- 可插拔上行认证 (uplink) ----------
# 固件只提供"插座": 配置持久化 + AUTHD_CMD 拉起/杀停 + eth0 档案切换 + MAC/TTL
# 伪装。具体认证程序(任意 802.1X/Portal 客户端)由用户自行部署到 AUTHD_CMD 路径。
# uplink.conf 键: ENABLE/AUTH_USER/AUTH_PASS/AUTH_IP/AUTH_MASK/AUTH_GW/PROBE_GW/
# AUTHD_CMD/MAC_SPOOF/SPOOF_MAC/TTL_SPOOF/TTL_VALUE/FORM(home|static)
# v1.1: TTL 伪装 — static档案+开启时 FORWARD 出向 TTL 统一改写(防多终端共享检测)
spoof_ttl_apply() {
    # xt_TTL 未编入此内核(实测 unknown option) — 用 nft 等效改写
    nft delete table ip spf 2>/dev/null
    if [ "$1" = static ] && [ -r $GWDATA/uplink.conf ]; then
        . $GWDATA/uplink.conf
        if [ "${TTL_SPOOF:-0}" = 1 ]; then
            nft add table ip spf 2>/dev/null
            nft add chain ip spf c "{ type filter hook forward priority -150; }" 2>/dev/null
            nft add rule ip spf c oifname eth0 ip ttl set "${TTL_VALUE:-64}" 2>/dev/null
        fi
    fi
}

apply_uplink() {
    U=$(form_kv user); PW=$(form_kv pass); IP=$(form_kv ip); MASK=$(form_kv mask); GW=$(form_kv gw)
    echo "$U$PW" | grep -qE '[^A-Za-z0-9@_.\-]' && jerr bad_chars
    echo "$IP$MASK$GW" | grep -qE '[^0-9.]' && jerr bad_ip
    [ "$(form_kv enable)" = 1 ] && EN=1 || EN=0
    MSP=$(form_kv mac_spoof); SMA=$(form_kv spoof_mac | tr 'A-F' 'a-f')
    TSP=$(form_kv ttl_spoof); TVA=$(form_kv ttl_value)
    [ "$MSP" = 1 ] || MSP=0
    [ "$TSP" = 1 ] || TSP=0
    if [ "$MSP" = 1 ]; then
        echo "$SMA" | grep -qE '^[0-9a-f:]{17}$' || jerr bad_mac
    fi
    case "$TVA" in 64|65|128) ;; *) TVA=64 ;; esac
    # AUTHD_CMD 表单不传则保留 conf 现值; PROBE_GW 供探活(与认证程序解耦)
    OLD=""; [ -r $GWDATA/uplink.conf ] && OLD=$(grep '^FORM=' $GWDATA/uplink.conf)
    # v2.51: 读旧值剥引号(见下) — conf 值现以引号落盘
    OAC=""; [ -r $GWDATA/uplink.conf ] && OAC=$(grep -m1 '^AUTHD_CMD=' $GWDATA/uplink.conf | cut -d= -f2- | sed "s/^'//;s/'\$//")
    # v2.48(P1-B): AUTHD_CMD 收权 root 通道 — GUI/API 不再可写。原实现字符集校验
    # 仍放行 "telnetd -p 2323" / "/bin/sh <conf>" 等现成 root 二进制 = 一键 root 化;
    # 该字段自此仅经 SSH/install.py 手编 uplink.conf(与插件部署同特权层)。
    form_has authd_cmd && jerr bad_cmd
    AC="${OAC:-/data/gw/authd eth0}"
    # v2.51: AUTHD_CMD 带空格(二进制+iface 参数), 裸 KEY=v1 v2 被 rc19 `. conf`
    # 按 POSIX 解析为"env 前缀赋值+执行 v2" — 赋值丢弃, authd 永不启动
    # (2026-10-07 冷启动实弹: eth0: not found, AUTHD_CMD 空)。落盘加引号。
    printf 'ENABLE=%s\nAUTH_USER=%s\nAUTH_PASS=%s\nAUTH_IP=%s\nAUTH_MASK=%s\nAUTH_GW=%s\nPROBE_GW=%s\nAUTHD_CMD='"'"'%s'"'"'\nMAC_SPOOF=%s\nSPOOF_MAC=%s\nTTL_SPOOF=%s\nTTL_VALUE=%s\n%s\n' \
        "$EN" "$U" "$PW" "$IP" "$MASK" "$GW" "$GW" "$AC" "$MSP" "$SMA" "$TSP" "$TVA" "${OLD:-FORM=home}" > $GWDATA/uplink.conf
    chmod 600 $GWDATA/uplink.conf
    ok_json
}

apply_uplink_form() {  # 档案切换: home(DHCP) <-> static(静态IP; 认证由 AUTHD_CMD 程序补)
    F=$(form_kv form)
    [ "$F" = home ] || [ "$F" = static ] || jerr bad_form
    [ -r $GWDATA/uplink.conf ] && . $GWDATA/uplink.conf
    if [ "$F" = static ]; then
        [ -n "$AUTH_IP" ] && [ -n "$AUTH_GW" ] || jerr uplink_no_conf
        ip addr flush dev eth0 2>/dev/null
        # MAC 伪装需先 ifdown 才能改 MAC(内核限制), 改完与 IP 一起 up
        if [ "${MAC_SPOOF:-0}" = 1 ] && [ -n "$SPOOF_MAC" ]; then
            ip link set eth0 down 2>/dev/null
            ip link set eth0 address "$SPOOF_MAC" 2>/dev/null || jerr mac_fail
        fi
        ip addr add "$AUTH_IP/${AUTH_MASK:-255.255.255.128}" dev eth0 2>/dev/null || jerr addr_fail
        ip link set eth0 up
        ip route replace default via "$AUTH_GW" dev eth0 metric 200 2>/dev/null
        # 认证守护: 杀旧拉新, 命令来自 AUTHD_CMD(任意可执行认证程序)
        pkill -f "[a]uthd" 2>/dev/null
        [ -n "${AUTHD_CMD:-}" ] && pkill -f "$AUTHD_CMD" 2>/dev/null
        sleep 1
        [ "$(grep -c "^ENABLE=1" $GWDATA/uplink.conf 2>/dev/null)" = 1 ] && \
            nohup ${AUTHD_CMD:-/data/gw/authd eth0} >/dev/null 2>&1 &
    else
        ip addr flush dev eth0 2>/dev/null
        # 还原原生MAC(伪装只在 static 档案下生效; 内核改MAC需 ifdown)
        # v1.0(架构轮): 原生值改调 wifi_macplan.sh 统一实现(出厂 brmac 算法) —
        #   原内联副本缺"brmac 档案不可读"的两级兜底(eth0 反推/合成地址), 档案
        #   不可读时静默不还原 = 同一算法两处实现的漂移实例; eth0 原生 MAC 与
        #   macplan 的 ra0 值同源(基址第二字节+1, 255 回绕)。
        NATIVE=$(cat /sys/class/net/eth0/address 2>/dev/null)
        if [ "${MAC_SPOOF:-0}" = 1 ] && [ -n "$SPOOF_MAC" ] && [ "$NATIVE" = "$SPOOF_MAC" ]; then
            eval "$(sh /data/gw/wifi_macplan.sh 2>/dev/null)"
            if [ -n "${ra0_mac:-}" ]; then
                ip link set eth0 down 2>/dev/null
                ip link set eth0 address "$ra0_mac" 2>/dev/null
            fi
        fi
        ip link set eth0 up
        pkill -f "[a]uthd" 2>/dev/null
        # wan_eth 下一周期自动 udhcpc 重取租约
    fi
    spoof_ttl_apply "$F"
    sed -i "s/^FORM=.*/FORM=$F/" $GWDATA/uplink.conf
    ok_json '"form":"'$F'"'
}

get_uplink() {
    [ -r $GWDATA/uplink.conf ] && . $GWDATA/uplink.conf
    D=$(ps | grep -c "[a]uthd")
    EM=$(cat /sys/class/net/eth0/address 2>/dev/null)
    TR="无"
    nft list ruleset 2>/dev/null | grep -q "ttl set" && TR="已生效"
    printf '{"enable":"%s","user":"%s","ip":"%s","gw":"%s","form":"%s","daemon":"%s","authd_cmd":"%s","mac_spoof":"%s","spoof_mac":"%s","ttl_spoof":"%s","ttl_value":"%s","eth0_mac":"%s","ttl_rule":"%s","ts":%d}' \
        "${ENABLE:-0}" "${AUTH_USER:-}" "${AUTH_IP:-}" "${AUTH_GW:-}" "${FORM:-home}" "$D" "${AUTHD_CMD:-}" \
        "${MAC_SPOOF:-0}" "${SPOOF_MAC:-}" "${TTL_SPOOF:-0}" "${TTL_VALUE:-64}" "$EM" "$TR" "$(date +%s)"
}
