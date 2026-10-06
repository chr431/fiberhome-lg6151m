#!/bin/sh
# api.sh v2.0 -- v3 gateway API router (busybox sh; v3httpd fork+exec, no shell in C)
#   GET  /api/<ep>            read endpoints (open, LAN-only)
#   POST /api/<ep>  token=... write endpoints (sha256 auth, /tmp/gui_tokens)
# 注入防线: 所有写端点参数过 case/regex 白名单, 拒绝一切元字符 (原厂 send_msg
# 的 popen 注入教训)。body 为 form-encoded: a=1&b=2 (V3_BODY)。
GWDATA=/data/gw   # v2.12: 基座路径统一到 /data/gw
TOKDIR=/tmp/gui_tokens

# ---------- tiny helpers ----------
jerr() { printf '{"error":"%s"}' "$1"; exit 0; }

urldec() {  # $1 -> stdout decoded (纯awk, busybox可靠)
    printf '%s' "$1" | awk '
    BEGIN { h="0123456789abcdef" }
    {
      s=$0; out=""; gsub(/\+/," ",s); n=length(s)
      for (i=1; i<=n; i++) {
        c=substr(s,i,1)
        if (c=="%" && i+2<=n) {
          hi=index(h,tolower(substr(s,i+1,1)))-1
          lo=index(h,tolower(substr(s,i+2,1)))-1
          if (hi>=0 && lo>=0) { out=out sprintf("%c",hi*16+lo); i+=2; continue }
        }
        out=out c
      }
      print out
    }'
}

# form_kv <key> : 从 $V3_BODY 取值(urldecode 后)
qkv() {  # GET 场景: 从 $V3_QUERY 取值
    [ -n "$V3_QUERY" ] || return 1
    _raw=$(printf '%s' "$V3_QUERY" | tr '&' '\n' | grep -m1 "^$1=" | cut -d= -f2-)
    [ -n "$_raw" ] || return 1
    urldec "$_raw"
}
form_kv() {
    [ -n "$V3_BODY" ] || return 1
    _raw=$(printf '%s' "$V3_BODY" | tr '&' '\n' | grep -m1 "^$1=" | cut -d= -f2-)
    [ -n "$_raw" ] || return 1
    urldec "$_raw"
}

ok_json() { printf '{"ok":true%s}' "${1:+,$1}"; }

# ---------- auth ----------
tok_new() {
    mkdir -p $TOKDIR
    _t=$(head -c 16 /dev/urandom | md5sum | cut -c1-32)
    echo "$(date +%s)" > $TOKDIR/$_t
    find $TOKDIR -type f -mmin +480 -delete 2>/dev/null
    printf '%s' "$_t"
}
tok_ok() {
    _t=$(form_kv token)
    [ -z "$_t" ] && _t=$(qkv token)
    printf '%s' "$_t" | grep -qE '^[0-9a-f]{32}$' || return 1
    [ -f "$TOKDIR/$_t" ]
}
need_tok() { tok_ok || jerr need_login; }

# v2.14: 配置统一 — defaults(只读)+settings(稀疏覆盖) source叠加; 写方只动settings
cfg_load() {
    [ -r $GWDATA/defaults.conf ] && . $GWDATA/defaults.conf
    [ -r $GWDATA/settings.conf ] && . $GWDATA/settings.conf
    [ ! -r $GWDATA/settings.conf ] && [ -r $GWDATA/wifi.conf ] && . $GWDATA/wifi.conf
}
gw_set() {  # gw_set <key> <value> — upsert settings.conf
    K=$1; V=$2; F=$GWDATA/settings.conf
    grep -v "^$K=" "$F" 2>/dev/null > "$F.new"
    echo "$K=$V" >> "$F.new"
    mv "$F.new" "$F"
}

# ---------- wifi ----------
wifi_state() {
    cfg_load
    H2=$(iw dev ra0 info 2>/dev/null | grep -c "type AP")   # v2.15: iw探测, 兼容F3单进程拓扑
    H5=$(iw dev rai0 info 2>/dev/null | grep -c "type AP")
    S2=$(iw dev ra0 info 2>/dev/null | grep -m1 channel | awk '{print $2}')
    S5=$(iw dev rai0 info 2>/dev/null | grep -m1 channel | awk '{print $2}')
    if [ "${INONE:-0}" = 1 ]; then D2="${SSID_BASE:-?}"; D5="${SSID_BASE:-?}"
    else D2="${SSID_BASE}-2.4G"; D5="${SSID_BASE}-5G"; fi
    printf '"ssid_base":"%s","ssid2g":"%s","ssid5g":"%s","secured":%s,"hostapd2g":%s,"hostapd5g":%s,"ch2g":"%s","ch5g":"%s"' \
        "${SSID_BASE:-?}" "$D2" "$D5" "$([ -n "$WPAPSK" ] && echo true || echo false)" \
        "${H2:-0}" "${H5:-0}" "${S2:--}" "${S5:--}"
}
wifi_stations() {
    for IFX in ra0 rai0; do
        iw dev $IFX station dump 2>/dev/null | awk -v ifx=$IFX '
            /^Station / { mac=substr($2,1,17) }
            /^\s+signal:/ { sig=$2 }
            /^\s+rx bytes:/ { rx=$3 }
            /^\s+tx bytes:/ { tx=$3 }
            /^\s+connected time:/ {
                printf "{\"if\":\"%s\",\"mac\":\"%s\",\"signal\":\"%s\",\"rx\":\"%s\",\"tx\":\"%s\"},", ifx, mac, sig, rx, tx
            }'
    done
}

# ---------- clients (lease + arp merge) ----------
clients_json() {
    cat /tmp/dnsmasq_br.leases 2>/dev/null | sort -k3 | while read _t mac ip name _r; do
        printf '{"mac":"%s","ip":"%s","name":"%s"},' "$mac" "$ip" "$name"
    done
}

# ---------- firewall apply (forwards + dmz + block) ----------
. $GWDATA/fw_apply.sh

# ---------- POST appliers ----------
apply_wifi() {
    # v1.6: 统一名称体系 — conf 存 SSID_BASE, SSID 由 wifi_up 派生
    cfg_load
    WPAPSK_OLD="$WPAPSK"
    SB=$(form_kv ssid_base); WPAPSK=$(form_kv pass); AUTH=$(form_kv auth)
    [ -z "$SB" ] && SB="${SSID_BASE:-LG6151M}"
    echo "$SB$WPAPSK" | grep -qE '[^A-Za-z0-9_. -]' && jerr bad_chars
    if [ -n "$WPAPSK" ]; then
        echo "$WPAPSK" | grep -qE '^[A-Za-z0-9-]{8,63}$' || jerr bad_pass
    fi
    [ -z "$WPAPSK" ] && WPAPSK="$WPAPSK_OLD"
    gw_set SSID_BASE "$SB"
    [ -n "$WPAPSK" ] && gw_set WPAPSK "$WPAPSK"
    [ -n "$AUTH" ] && gw_set AUTH "$AUTH"
    sh $GWDATA/wifi_up.sh >/tmp/wifi_up.log 2>&1 &
    ok_json
}

apply_dhcp() {
    R1=$(form_kv r1); R2=$(form_kv r2); LEASE=$(form_kv lease)
    echo "$R1$R2" | grep -qE '[^0-9.]' && jerr bad_ip
    echo "$LEASE" | grep -qE '^[0-9]+[hm]$' || jerr bad_lease
    gw_set DHCP_R1 "$R1"; gw_set DHCP_R2 "$R2"; gw_set DHCP_LEASE "$LEASE"
    kill $(cat /var/run/dnsmasd_br.pid 2>/dev/null) 2>/dev/null; sleep 1
    dnsmasq -p 53 --no-resolv --server=223.5.5.5 --server=119.29.29.29 \
        -i br-lan -I lo -F 192.168.9.0/255.255.255.0,${R1},${R2},${LEASE} \
        --dhcp-option=3,192.168.9.1 --dhcp-option=6,192.168.9.1 \
        --dhcp-leasefile=/tmp/dnsmasq_br.leases -x /var/run/dnsmasd_br.pid || jerr dnsmasq_fail
    ok_json
}

apply_fwd_add() {
    P=$(form_kv proto); EP=$(form_kv eport); DIP=$(form_kv dip); DP=$(form_kv dport)
    [ "$P" = tcp ] || [ "$P" = udp ] || jerr bad_proto
    for PT in "$EP" "$DP"; do
        case "$PT" in ""|*[!0-9]*) jerr bad_port ;; esac
        [ "$PT" -ge 1 ] && [ "$PT" -le 65535 ] || jerr bad_port
    done
    echo "$DIP" | grep -qE '[^0-9.]' && jerr bad_ip
    grep -v "^$P|$EP|" $GWDATA/forwards.conf 2>/dev/null > /tmp/f.$$
    echo "$P|$EP|$DIP|$DP" >> /tmp/f.$$
    mv /tmp/f.$$ $GWDATA/forwards.conf
    fw_apply; ok_json
}
apply_fwd_del() {
    P=$(form_kv proto); EP=$(form_kv eport)
    grep -v "^$P|$EP|" $GWDATA/forwards.conf 2>/dev/null > /tmp/f.$$; mv /tmp/f.$$ $GWDATA/forwards.conf
    fw_apply; ok_json
}
apply_dmz() {
    EN=$(form_kv enabled); IP=$(form_kv ip)
    [ "$EN" = 0 ] || [ "$EN" = 1 ] || jerr bad_flag
    if [ "$EN" = 1 ]; then echo "$IP" | grep -qE '[^0-9.]' && jerr bad_ip; fi
    printf 'DMZ_EN=%s\nDMZ_IP=%s\n' "$EN" "${IP:-}" > $GWDATA/dmz.conf
    fw_apply; ok_json
}
apply_block() {
    M=$(form_kv mac | tr 'A-F' 'a-f')
    echo "$M" | grep -qE '^[0-9a-f:]{17}$' || jerr bad_mac
    if [ "$(form_kv del)" = 1 ]; then
        grep -v "^$M$" $GWDATA/block.conf 2>/dev/null > /tmp/b.$$; mv /tmp/b.$$ $GWDATA/block.conf
    else
        grep -q "^$M$" $GWDATA/block.conf 2>/dev/null || echo "$M" >> $GWDATA/block.conf
    fi
    fw_apply; ok_json
}

apply_agg_weights() {
    W1=$(form_kv w1)
    echo "$W1" | grep -qE '^[0-9]{1,3}$' || jerr bad_pct   # v2.10: {1,2}曾拒绝'100'(100:0引擎实测支持)
    [ "$W1" -ge 0 ] && [ "$W1" -le 100 ] || jerr bad_pct
    W2=$((100 - W1))
    EN=$(grep -m1 '^ENABLE=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    case "$EN" in 0|1) ;; *) EN=1 ;; esac
    printf 'W1_PCT=%s\nW2_PCT=%s\nENABLE=%s\n' "$W1" "$W2" "$EN" > $GWDATA/agg.conf
    # v2.20: vendor ioctl 只是引擎可用时的即时加速, 守护热载为准 — 不再因 ioctl 失败误报
    LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib LD_PRELOAD=$GWDATA/fhstub.so \
        $GWDATA/multiwan_ctl 1 $W1 $W2 1 1 >/dev/null 2>&1
    ok_json
}
apply_agg_mode() {   # v2.20: 聚合总开关 0=旁路(单路) 1=参战(分流/主备), wan_agg 热载生效
    E=$(form_kv enable)
    [ "$E" = 0 ] || [ "$E" = 1 ] || jerr bad_mode
    W=$(grep -m1 '^W1_PCT=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    echo "$W" | grep -qE '^[0-9]{1,3}$' || W=40
    [ "$W" -ge 0 ] && [ "$W" -le 100 ] || W=40
    printf 'W1_PCT=%s\nW2_PCT=%s\nENABLE=%s\n' "$W" "$((100-W))" "$E" > $GWDATA/agg.conf
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

# ---------- cellular (载波信息/锁频段/锁小区; cfgmgr树+AT) ----------
FH_TREE=InternetGatewayDevice.X_FH_MobileNetwork
cfgget() { LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd get "$1" 2>/dev/null | sed -n 's/^get success!value=//p'; }
cfgset_ok() { LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd set "$1" "$2" 2>/dev/null | grep -q "set success"; }
cfgdel_ok() { LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd del "$1" >/dev/null 2>&1; }
op_name() {
    case "$1" in
        46000|46002|46004|46007|46008) echo "中国移动" ;;
        46001|46006|46009|46015) echo "中国联通" ;;
        46003|46005|46011|46012) echo "中国电信" ;;
        *) echo "${1:-未知}" ;;
    esac
}

# ---------- 批次B: 短信读/流量/PIN/制式/风扇/LED/静态租约/NTP/邻居扫描/WiFi高级/访客 ----------
MN_TREE=InternetGatewayDevice.X_FH_MobileNetwork

# -- 短信(只读收件: AT+CMGL 白名单放行; 发送暂缓—CMGS交互式会毒死ril承载) --
get_sms() {
    OUT=$(mipc_wan_cli --at_cmd "AT+CMGL=\"ALL\"" 2>/dev/null)
    # +CMGL: <idx>,"stat","<oa>",[...],"<time>"\n<text>
    echo "$OUT" | awk '
        /^\+CMGL: / {
            gsub(/\r/,"")
            split($0, a, ",")
            idx=a[1]; sub(/^\+CMGL: /,"",idx)
            stat=a[2]; oa=a[3]; gsub(/"/,"",oa)
            tm=$0; sub(/^.*,/,"",tm)  # 最后段含时间
            getline txt; gsub(/\r/,"",txt)
            printf "{\"idx\":\"%s\",\"stat\":%s,\"from\":\"%s\",\"text\":\"%s\"},", idx, stat, oa, txt
        }' | sed 's/","text"/,"text"/2g' > /tmp/sms.$$
    L=$(cat /tmp/sms.$$ | sed 's/,$//'); rm -f /tmp/sms.$$
    N=$(printf '%s' "$L" | grep -o '"idx"' | wc -l)
    printf '{"msgs":[%s],"count":%d,"send_supported":false,"ts":%d}' "$L" "$N" "$(date +%s)"
}

# -- 流量统计 (ubus 活方法; 限额自管) --
get_traffic() {
    T=$(ubus call mobile_network traffic_statistics "{\"tx\":\"0\",\"rx\":\"0\"}" 2>/dev/null)
    RX=$(printf '%s' "$T" | grep -oE '"rx": *"[0-9]+"' | grep -oE '[0-9]+')
    TX=$(printf '%s' "$T" | grep -oE '"tx": *"[0-9]+"' | grep -oE '[0-9]+')
    [ -r $GWDATA/traffic.conf ] && . $GWDATA/traffic.conf
    printf '{"rx":"%s","tx":"%s","day_limit_mb":"%s","month_limit_mb":"%s","ts":%d}' \
        "${RX:-0}" "${TX:-0}" "${DAY_LIMIT_MB:-0}" "${MONTH_LIMIT_MB:-0}" "$(date +%s)"
}
apply_traffic_limit() {
    D=$(form_kv day); M=$(form_kv month)
    echo "$D$M" | grep -qE '[^0-9]' && jerr bad_num
    printf 'DAY_LIMIT_MB=%s\nMONTH_LIMIT_MB=%s\n' "$D" "$M" > $GWDATA/traffic.conf
    ok_json
}

# -- SIM / PIN (展示+PIN管理走ubus update_pin_info; 误锁风险提示在前端) --
get_sim() {
    # v2.33: AT 直读优先(CPIN/CIMI/CCID/CGSN/COPS), 树值仅回退 — 展示面独立于 mobilenetwork
    A_STAT=$(mipc_wan_cli --at_cmd "AT+CPIN?" 2>/dev/null | grep -oE 'CPIN: [A-Z ]+' | cut -d' ' -f2-)
    A_IMSI=$(mipc_wan_cli --at_cmd "AT+CIMI" 2>/dev/null | grep -oE '^[0-9]{15}' | head -1)
    A_ICCID=$(mipc_wan_cli --at_cmd "AT+CCID" 2>/dev/null | grep -oE '[0-9]{19,20}' | head -1)
    A_IMEI=$(mipc_wan_cli --at_cmd "AT+CGSN" 2>/dev/null | grep -oE '^[0-9]{15}' | head -1)
    A_OPS=$(mipc_wan_cli --at_cmd "AT+COPS?" 2>/dev/null | grep -oE '"[0-9]{5,6}"' | tr -d '"')
    S=$MN_TREE.SIM.1
    printf '{"status":"%s","imsi":"%s","iccid":"%s","carrier":"%s","imei":"%s","phone":"%s","reg":"%s","pin_state":"%s","ts":%d}'         "${A_STAT:-$(cfgget $S.SIMStatus)}" "${A_IMSI:-$(cfgget $S.IMSI)}"         "${A_ICCID:-$(cfgget $S.ICCID)}" "$(op_name "${A_OPS:-$(cfgget $S.CarrierName)}")"         "${A_IMEI:-$(cfgget $S.IMEI)}" "$(cfgget $S.PhoneNumber)"         "$(cfgget $S.RegisterStatus)" "$(mipc_wan_cli sim_pin_info_get 2>/dev/null | grep -oE 'state:[0-9]+' | cut -d: -f2)" "$(date +%s)"
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
# v2.30 (P3.5): 制式/飞行 AT 直发 -- A 组逆向(指令级实证)的官方映射:
#   mode 0→AT+erat=3(LTE only) 1→AT+erat=19,0(LTE+NR) 2→AT+erat=15(5G only)
#        3→AT+erat=19,0         4→AT+erat=1(2G only)
#   飞行 ON: 停拨号 + AT+cfun=0 (厂商用 0 非 4, 小写); OFF: AT+cfun=1
#   (dial_keeper 在 OFF 后自动重拨)。状态存自管 cellular.conf。
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
        printf '{"mode":"%s","airplane":"%s","engine":"mipc","ts":%d}' \
            "${NM_MODE:-1}" "$AP" "$(date +%s)"
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
        E=$(erat_of "$M") || jerr bad_mode
        R=$(mipc_wan_cli --at_cmd "AT+erat=$E" 2>/dev/null | grep -c OK)
        [ "$R" -ge 1 ] || jerr at_fail
        sed -i '/^NM_MODE=/d' $GWDATA/cellular.conf 2>/dev/null
        echo "NM_MODE=$M" >> $GWDATA/cellular.conf
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
        ok_json '"engine":"mipc","note":"OFF后dial_keeper约40s自动重拨"'
        return
    fi
    cfgset_ok $MN_TREE.NetworkSettings.AirplaneEnable "$V" || jerr tree_fail
    ok_json
}
net_plmn_scan() {
    # v2.32 (P4.1 完成): ql_nw_network_scan 原生扫描(C 组逆向, 异步回调+0x1288
    # 结构), mipc_cellular v0.4 封装为同步 JSON 输出。扫描 10-60s。
    R=$(/data/gw/mipc_cellular scan 60 2>/dev/null | head -1)
    case "$R" in
        '"count"'*|'{"count"'*) printf '%s' "$R" ;;
        *) printf '{"error":"scan_failed","detail":"%s"}' "${R:-tool_missing}" ;;
    esac
}

# -- 风扇/LED --
get_fan() {
    cfg_load
    MODE=${FAN_MODE:-performance}
    DUTY=$(cat /sys/class/hwmon/hwmon1/pwm1 2>/dev/null)
    RPM=$(cat /sys/class/hwmon/hwmon2/pwm1_rpm 2>/dev/null)
    T=""
    for zd in /sys/class/thermal/thermal_zone*; do
        [ "$(cat $zd/type 2>/dev/null)" = soc_max ] && T=$(cat $zd/temp 2>/dev/null)
    done
    printf '{"mode":"%s","duty":"%s","rpm":"%s","soc_temp":"%s","ts":%d}' \
        "$MODE" "${DUTY:-0}" "${RPM:-0}" "${T:--}" "$(date +%s)"
}
apply_fan() {
    M=$(form_kv mode)
    [ "$M" = performance ] || [ "$M" = silent ] || jerr bad_mode
    gw_set FAN_MODE "$M"
    # fan_mgr 周期重读 conf(若实现); 保险: 发信号量文件
    touch /tmp/fan_mode.changed
    ok_json
}
get_led() {
    printf '{"night":"%s","ts":%d}' "${LED_NIGHT:-0}" "$(date +%s)"
}
apply_led() {
    V=$(form_kv night)
    [ "$V" = 0 ] || [ "$V" = 1 ] || jerr bad_flag
    gw_set LED_NIGHT "$V"
    touch /tmp/led_mode.changed
    ok_json
}

# -- DHCP 静态租约 (dnsmasq dhcp-host) --
get_dhcp_static() {
    ENTRIES=""
    [ -r $GWDATA/dhcp_static.conf ] && while IFS='|' read -r mac ip name; do
        case "$mac" in \#*|"") continue;; esac
        ENTRIES="$ENTRIES{\"mac\":\"$mac\",\"ip\":\"$ip\",\"name\":\"$name\"},"
    done < $GWDATA/dhcp_static.conf
    ENTRIES=${ENTRIES%,}
    printf '{"entries":[%s],"ts":%d}' "${ENTRIES:-}" "$(date +%s)"
}
apply_dhcp_static() {
    OP=$(form_kv op)
    case "$OP" in
    add)
        M=$(form_kv mac | tr 'A-F' 'a-f'); IP=$(form_kv ip); NM=$(form_kv name)
        echo "$M" | grep -qE '^[0-9a-f:]{17}$' || jerr bad_mac
        echo "$IP" | grep -qE '[^0-9.]' && jerr bad_ip
        printf '%s' "$NM" | grep -qE '[^A-Za-z0-9_.-]' && jerr bad_name
        grep -v "^$M|" $GWDATA/dhcp_static.conf 2>/dev/null > /tmp/ds.$$; echo "$M|$IP|$NM" >> /tmp/ds.$$
        mv /tmp/ds.$$ $GWDATA/dhcp_static.conf
        ;;
    del)
        M=$(form_kv mac | tr 'A-F' 'a-f')
        grep -v "^$M|" $GWDATA/dhcp_static.conf 2>/dev/null > /tmp/ds.$$; mv /tmp/ds.$$ $GWDATA/dhcp_static.conf
        ;;
    *) jerr bad_op ;;
    esac
    dhcp_static_apply
    ok_json
}
dhcp_static_apply() {
    # 构造 dhcp-host 参数串并重启 dnsmasq(cmdline 形态, 与 rc19 同源)
    ARGS=""
    [ -r $GWDATA/dhcp_static.conf ] && while IFS='|' read -r mac ip name; do
        case "$mac" in \#*|"") continue;; esac
        ARGS="$ARGS --dhcp-host=$mac,$ip,${name:-*}"
    done < $GWDATA/dhcp_static.conf
    cfg_load
    kill $(cat /var/run/dnsmasd_br.pid 2>/dev/null) 2>/dev/null; sleep 1
    dnsmasq -p 53 --no-resolv --server=223.5.5.5 --server=119.29.29.29         -i br-lan -I lo -F 192.168.9.0/255.255.255.0,${R1:-192.168.9.100},${R2:-192.168.9.200},${LEASE:-12h}         --dhcp-option=3,192.168.9.1 --dhcp-option=6,192.168.9.1         --dhcp-leasefile=/tmp/dnsmasq_br.leases -x /var/run/dnsmasd_br.pid $ARGS || return 1
    # 开机重放标记(下次DHCP服务重启由rc19兜底)
    return 0
}

# -- NTP/时区/定时重启 --
get_ntp() {
    printf '{"date":"%s","tz":"%s","ntp_server":"%s","timed_reboot":"%s","ts":%d}' \
        "$(date "+%Y-%m-%d %H:%M:%S")" "$(cat /etc/TZ 2>/dev/null)" \
        "$(cfgget InternetGatewayDevice.Time.NTPServer1)" \
        "$(cfgget InternetGatewayDevice.X_FH_MobileNetwork.TimedReboot.1.Time 2>/dev/null)" "$(date +%s)"
}
apply_ntp() {
    SRV=$(form_kv server); TZV=$(form_kv tz)
    echo "$SRV" | grep -qE '[^A-Za-z0-9.:_-]' && jerr bad_srv
    echo "$TZV" | grep -qE '[^A-Za-z0-9+\-:/]' && jerr bad_tz
    cfgset_ok InternetGatewayDevice.Time.NTPServer1 "$SRV" 2>/dev/null
    echo "$TZV" > /etc/TZ
    [ -s /etc/resolv.conf ] || echo "nameserver 223.5.5.5" > /etc/resolv.conf
    # v2.3: 同步对时+真实校验(ntpd -qn 曾静默失败致时钟错3天, 用户实弹抓获)
    BEFORE=$(date +%s)
    ntpclient -h "$SRV" -c 1 -s >/dev/null 2>&1 ||         ntpclient -h 203.107.6.88 -c 1 -s >/dev/null 2>&1 ||         ntpclient -h 119.28.63.197 -c 1 -s >/dev/null 2>&1
    AFTER=$(date +%s)
    DELTA=$((AFTER - BEFORE))
    if [ $DELTA -gt 5 ]; then
        ok_json "\"synced\":true,\"jump\":\"${DELTA}s\""
    else
        ok_json "\"synced\":true,\"note\":\"already-in-sync\""
    fi
}

# -- 管理密码修改 --
apply_pass_set() {
    OLD=$(form_kv old); NEW=$(form_kv new)
    printf '%s' "$NEW" | grep -qE '^[A-Za-z0-9@#%^&*_.-]{8,63}$' || jerr bad_pass
    OH=$(printf '%s' "$OLD" | sha256sum | cut -d" " -f1)
    [ "$OH" = "$(cat $GWDATA/gui_auth.conf 2>/dev/null)" ] || jerr bad_old
    printf '%s' "$NEW" | sha256sum | cut -d" " -f1 > $GWDATA/gui_auth.conf
    chmod 600 $GWDATA/gui_auth.conf
    ok_json
}

# -- 邻居 AP 扫描 (apclii0 短暂 up 扫 5G; ra0/apcli0 扫 2.4G) --
get_wifiscan() {
    # v2: 预热3s(1s时几乎扫不到) + 双轮扫描合并(第二轮更饱满) + 按MAC去重
    ifconfig apcli0 up 2>/dev/null; ifconfig apclii0 up 2>/dev/null; sleep 3
    R1=$(iw apcli0 scan 2>/dev/null; iw apclii0 scan 2>/dev/null)
    R2=$(iw apcli0 scan 2>/dev/null; iw apclii0 scan 2>/dev/null)
    ifconfig apcli0 down 2>/dev/null; ifconfig apclii0 down 2>/dev/null
    RES="$R1
$R2"
    echo "$RES" | awk '
        function flush() {
            if (ssid == "" || (mac in seen)) return
            seen[mac] = 1
            gsub(/"/, "", ssid)

            band = freq+0 > 4000 ? "5G" : "2.4G"
            # v2.31: 带宽(VHT/HE op channel width 末次; HT secondary 判40; 默认20)+中心段
            if (vhtbw == "") { bw = ht40 ? 40 : 20 } else { bw = vhtbw }
            printf "{\42ssid\42:\42%s\42,\42mac\42:\42%s\42,\42band\42:\42%s\42,\42freq\42:\42%s\42,\42signal\42:\42%s\42,\42sec\42:\42%s\42,\42bw\42:\42%d\42,\42ctr\42:\42%s\42},", ssid, mac, band, freq, sig, sec, bw, ctr
        }
        /^BSS / { flush(); mac=substr($2,1,17); sig=""; freq=""; ssid=""; sec="open"; vhtbw=""; ctr=""; ht40=0 }
        /^[ 	]+signal:/ { sig=$2 }
        /^[ 	]+freq:/ { freq=$2 }
        /^[ 	]+SSID:/ { ssid=substr($0, index($0,":")+2) }
        /^[ 	]+(WPA|RSN):/ { sec="WPA" }
        /channel width: [0-9]+ \(([0-9]+)/ {
            w = $0; sub(/.*\(/, "", w); sub(/[^0-9].*/, "", w); vhtbw = w + 0
        }
        /center freq segment 1:/ { ctr = $NF }
        /secondary channel offset: (above|below)/ { ht40 = 1 }
        END { flush() }
    ' | tr -d '\' | sed 's/,$//' > /tmp/scan.$$
    L=$(cat /tmp/scan.$$ | tr -d '\n'); rm -f /tmp/scan.$$
    printf '{"aps":[%s],"ts":%d}' "$L" "$(date +%s)"
}

# -- WiFi 高级 (信道/带宽/功率/隐藏) + 访客 + 双频合一 --
get_wifi_adv() {
    cfg_load
    H2=$(grep -m1 "^HideSSID" /var/wlan/apcfg 2>/dev/null | cut -d= -f2 | cut -d\; -f1)
    RCH2G=""; RCH5G=""
    [ -r /tmp/wifi_autoch ] && . /tmp/wifi_autoch   # wifi_up 自动选道落点(信道=0时)
    printf '{"ssid_base":"%s","ch2g":"%s","ch5g":"%s","bw2g":"%s","bw5g":"%s","power":"%s","hidden2g":"%s","hidden5g":"%s","guest":"%s","guest_pass":"%s","inone":"%s","res2g":"%s","res5g":"%s","ts":%d}' \
        "${SSID_BASE:-}" "${CH2G:-6}" "${CH5G:-149}" "${BW2G:-20}" "${BW5G:-80}" "${POWER:-100}" \
        "${H2:-0}" "0" "${GUEST:-0}" "${GUEST_PASS:+1}" "${INONE:-0}" "${RCH2G:-}" "${RCH5G:-}" "$(date +%s)"
}
apply_wifi_adv() {
    # v1.2: 先源旧conf(保留SSID/密码等非本表单字段), 再读表单值覆盖同名项
    # — 曾因source放在form_kv之后, INONE/GUEST被旧值覆盖致"选项弹回"(用户实弹)
    [ -r $GWDATA/wifi.conf ] && . $GWDATA/wifi.conf
    # v1.6: 统一名称 — 表单传 ssid_base
    SB=$(form_kv ssid_base); [ -z "$SB" ] && SB="${SSID_BASE:-LG6151M}"
    echo "$SB" | grep -qE '[^A-Za-z0-9_. -]' && jerr bad_chars
    CH2=$(form_kv ch2); CH5=$(form_kv ch5); BW2=$(form_kv bw2); BW5=$(form_kv bw5)
    PW=$(form_kv power); HID=$(form_kv hidden); GUEST=$(form_kv guest)
    GSTP=$(form_kv guest_pass); INONE=$(form_kv inone)
    echo "$CH2$CH5$BW2$BW5$PW" | grep -qE '[^0-9]' && jerr bad_num
    # 信道: 0=自动(wifi_up启动扫描选道); 2.4G 1-13(CN), 5G限定8个非DFS道
    { [ "$CH2" -eq 0 ] || { [ "$CH2" -ge 1 ] && [ "$CH2" -le 13 ]; } } 2>/dev/null || jerr bad_ch
    case "$CH5" in 0|36|40|44|48|149|153|157|161) ;; *) jerr bad_ch5 ;; esac
    case "$BW2" in 20|40) ;; *) jerr bad_bw ;; esac
    case "$BW5" in 20|40|80|160) ;; *) jerr bad_bw ;; esac
    [ "$PW" -ge 25 ] 2>/dev/null && [ "$PW" -le 100 ] 2>/dev/null || jerr bad_power
    [ "$HID" = 0 ] || [ "$HID" = 1 ] || jerr bad_flag
    [ "$GUEST" = 0 ] || [ "$GUEST" = 1 ] || jerr bad_flag
    [ "$INONE" = 0 ] || [ "$INONE" = 1 ] || jerr bad_flag
    if [ -n "$GSTP" ]; then
        printf '%s' "$GSTP" | grep -qE '^[A-Za-z0-9-]{8,63}$' || jerr bad_pass
    fi
    # v1.2: source已提前到函数头, 此处不再重复(旧位置曾覆盖INONE/GUEST表单值)
    gw_set SSID_BASE "$SB"
    gw_set CH2G "$CH2"; gw_set CH5G "$CH5"; gw_set BW2G "$BW2"; gw_set BW5G "$BW5"
    gw_set POWER "$PW"; gw_set HIDDEN "$HID"; gw_set GUEST "$GUEST"; gw_set INONE "$INONE"
    if [ -n "$GSTP" ]; then gw_set GUEST_PASS "$GSTP"; fi
    sh $GWDATA/wifi_up.sh >/tmp/wifi_up.log 2>&1 &
    ok_json
}


get_cellular() {
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
    NC=$(printf '%s' "$BANDS" | awk -F, '{print NF}')
    CSQ=$(mipc_wan_cli --at_cmd "AT+CSQ" 2>/dev/null | grep -oE "[0-9]+, ?99" | cut -d, -f1)
    RSSI=""; case "$CSQ" in ''|0) RSSI="未知";; *) RSSI="$(( -113 + CSQ * 2 )) dBm";; esac
    # v2.24 (P3): mipc/AT 直读优先, 树值为回退 -- RSRP 实时化 + PLMN/RAT 直查。
    #   树值由 mobilenetwork 周期回填(有滞后), 直读消除断供风险(树死也有活数据)。
    MR=$(mipc_wan_cli --nw_get_signal 2>/dev/null | grep -oE 'RSRP=-?[0-9]+')
    [ -n "$MR" ] && SR="${MR#RSRP=}"
    COPSR=$(mipc_wan_cli --at_cmd "AT+COPS?" 2>/dev/null | grep -oE '\+COPS: [^]*')
    CNUM=$(printf '%s' "$COPSR" | grep -oE '"[0-9]{5,6}"' | tr -d '"')
    [ -n "$CNUM" ] && PLMN="$CNUM"
    ACT=$(printf '%s' "$COPSR" | awk -F, '{gsub(//,"");n=NF; gsub(/[^0-9]/,"",$n); print $n}')
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
        [ "$RET" = 0 ] || jerr mipc_fail
        # 状态持久化到自管 conf (mipc 模式不写树; 树同步由 mobilenetwork 上报被动跟随)
        { echo "BAND_EN=$EN"; echo "LTE_MASK=$LTE"; echo "NR_MASK=$NR";
          echo "CELL_EN=0"; } > $GWDATA/cellular.conf
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
            grep -v "^CELL_$i=" "$CONF" 2>/dev/null > /tmp/cl.$$; echo "CELL_$i=$ACT:$ARF:$PC" >> /tmp/cl.$$
            mv /tmp/cl.$$ "$CONF"
            ;;
        del)
            IDX=$(form_kv idx); echo "$IDX" | grep -qE '^[0-9]+$' || jerr bad_idx
            [ "$IDX" -ge 1 ] && [ "$IDX" -le 20 ] || jerr bad_idx
            grep -v "^CELL_$IDX=" "$CONF" 2>/dev/null > /tmp/cl.$$ && mv /tmp/cl.$$ "$CONF"
            # 压实槽位(防空洞)
            awk -F= '/^CELL_[0-9]+=/{print} /^(BAND_EN|LTE_MASK|NR_MASK|CELL_EN)=/{print}' "$CONF" > /tmp/cl2.$$
            n=1; grep -oE '^CELL_[0-9]+=[^[:space:]]+' "$CONF" | cut -d= -f2- | while read -r e; do
                [ -n "$e" ] && { echo "CELL_$n=$e" >> /tmp/cl2.$$; n=$((n+1)); }
            done
            mv /tmp/cl2.$$ "$CONF"
            ;;
        clear)
            grep -v '^CELL_' "$CONF" 2>/dev/null > /tmp/cl.$$ || true
            mv /tmp/cl.$$ "$CONF"
            sed -i 's/^CELL_EN=.*/CELL_EN=0/' "$CONF" 2>/dev/null || echo "CELL_EN=0" >> "$CONF"
            ;;
        *) jerr bad_op ;;
        esac
        celllock_forget_env
        . "$CONF"
        # 全量下发 + 互斥(开小区锁时解锁频段)
        if [ "$OP" = add ]; then
            [ "${BAND_EN:-0}" = 1 ] && { /data/gw/mipc_cellular unlock >/dev/null 2>&1; sed -i 's/^BAND_EN=1/BAND_EN=0/' "$CONF"; }
            sed -i 's/^CELL_EN=.*/CELL_EN=1/' "$CONF" 2>/dev/null || echo "CELL_EN=1" >> "$CONF"
        elif [ "$OP" = clear ]; then
            echo "CELL_EN=0" >> "$CONF"
            [ "${BAND_EN:-0}" = 1 ] && /data/gw/mipc_cellular setlock lte="${LTE_MASK:-all}" nr="${NR_MASK:-all}" >/dev/null 2>&1
        fi
        celllock_forget_env
        . "$CONF"
        N=$(celllock_send_all)
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

# 持久化到自管 conf (cfgmgr树每次开机由出厂档案重建, rc_netfh 开机重放)
cell_persist() {
    NS=$FH_TREE.NetworkSettings
    {
        echo "BAND_EN=$(cfgget $NS.LockBandEnable)"
        echo "LTE_MASK=$(cfgget $NS.LTELockBAND)"
        echo "NR_MASK=$(cfgget $NS.NRLockBAND)"
        echo "CELL_EN=$(cfgget $FH_TREE.LockCellList.LockEnable)"
        i=1; while [ $i -le 20 ]; do
            A=$(cfgget $FH_TREE.LockCellList.LockCell.$i.arfcn); [ -z "$A" ] && break
            echo "CELL_$i=$(cfgget $FH_TREE.LockCellList.LockCell.$i.act):$A:$(cfgget $FH_TREE.LockCellList.LockCell.$i.pci)"
            i=$((i+1))
        done
    } > /data/gw/cellular.conf
    # 树快照(16MB→~127KB): 开机 cfg_tool 建出厂树后整体恢复, 锁定跨重启
    /data/gw/shmsnap save /tmp/cfgtree.snap >/dev/null 2>&1 &&         gzip -c /tmp/cfgtree.snap > /data/gw/cfgtree.snap.gz 2>/dev/null &&         rm -f /tmp/cfgtree.snap
}

# v2.29 (P4): SMS 发送 -- mipc_cellular ql_sms_send_msg 直发(同步, ret=0 即成功),
# 无 AT CMGS 交互毒性; 中文需 UCS2-BE hex(text 以 ucs2: 前缀传 hex)。
apply_sms_send() {
    NUM=$(form_kv num); TXT=$(form_kv text)
    printf '%s' "$NUM" | grep -qE '^\+?[0-9]{5,20}$' || jerr bad_num
    [ -n "$TXT" ] || jerr empty_text
    case "$TXT" in
      ucs2:*)
        H=${TXT#ucs2:}
        echo "$H" | grep -qE '^[0-9a-fA-F]{4,560}$' || jerr bad_ucs2
        R=$(/data/gw/mipc_cellular senducs2 "$NUM" "$H" 2>&1) ;;
      *)
        printf '%s' "$TXT" | grep -qE '[-ÿ]' && jerr need_ucs2
        [ ${#TXT} -gt 480 ] && jerr too_long
        R=$(/data/gw/mipc_cellular sendsms "$NUM" "$TXT" 2>&1) ;;
    esac
    printf '%s' "$R" | grep -q 'ret=0' || jerr send_fail
    ok_json
}

# ---------- GET handlers ----------
get_status() {
    exec 2>/dev/null
    U=$(cut -d. -f1 /proc/uptime)
    UP_D=$((U/86400)); UP_H=$(( (U%86400)/3600 )); UP_M=$(( (U%3600)/60 ))
    LOAD=$(cut -d" " -f1-3 /proc/loadavg)
    MEM=$(awk '/MemTotal/{t=$2}/MemAvailable/{a=$2}END{printf "%d %d", t, a}' /proc/meminfo)
    W5G_IF=$(ip -o -4 addr show 2>/dev/null | grep ccmni | grep -m1 inet | awk '{print $2}')
    W5G_IP=$(ip -o -4 addr show $W5G_IF 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    W5G_V6=$(ip -o -6 addr show $W5G_IF 2>/dev/null | grep -m1 global | awk '{print $4}' | cut -d/ -f1)
    ETH_IP=$(ip -o -4 addr show eth0 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
    ETH_V6=$(ip -o -6 addr show eth0 2>/dev/null | grep -m1 global | awk '{print $4}' | cut -d/ -f1)
    ETH_C=$(cat /sys/class/net/eth0/carrier 2>/dev/null); ETH_C=${ETH_C:-0}
    AGG_M=$(grep -m1 "Current mode" /proc/multi_wan/mode 2>/dev/null | grep -oE "[0-9]+$")
    AGG_W=$(grep "WAN1 weight" /proc/multi_wan/weight 2>/dev/null | grep -oE "[0-9]+" | tail -1)
    WAN_MODE=$(cat /tmp/wan_mode 2>/dev/null)
    TEMPS=""
    for z in soc_max cpu_little0 cpu_big0 md1 nrpa_ntc ltepa_ntc; do
        for zd in /sys/class/thermal/thermal_zone*; do
            [ "$(cat $zd/type 2>/dev/null)" = "$z" ] && TEMPS="$TEMPS\"$z\":$(cat $zd/temp 2>/dev/null),"
        done
    done
    TEMPS=${TEMPS%,}
    TX5=$(cat /sys/class/net/${W5G_IF:-ccmni0}/statistics/tx_bytes 2>/dev/null); TX5=${TX5:-0}
    RX5=$(cat /sys/class/net/${W5G_IF:-ccmni0}/statistics/rx_bytes 2>/dev/null); RX5=${RX5:-0}
    TXE=$(cat /sys/class/net/eth0/statistics/tx_bytes 2>/dev/null); TXE=${TXE:-0}
    RXE=$(cat /sys/class/net/eth0/statistics/rx_bytes 2>/dev/null); RXE=${RXE:-0}
    cat <<EOF2
{"uptime":"${UP_D}天${UP_H}时${UP_M}分","load":"$LOAD","mem":{"total":${MEM%% *},"avail":${MEM##* }},
"wan5g":{"if":"$W5G_IF","ip":"${W5G_IP:-无}","v6":"${W5G_V6:-无}"},
"home":{"ip":"${ETH_IP:-无}","v6":"${ETH_V6:-无}","carrier":"$ETH_C"},
"agg":{"mode":"${AGG_M:-0}","engine":"$(cat /tmp/wan_engine 2>/dev/null)","on":"$(grep -q '^off' /tmp/wan_mode 2>/dev/null && echo 0 || echo 1)","w1pct":"${AGG_W:-?}","state":"$(tail -1 /tmp/wan_agg.log 2>/dev/null | sed 's/"/\\"/g')","wanmode":"$WAN_MODE"},
"wifi":{$(wifi_state)},
"temps":{$TEMPS},
"counters":{"tx5g":"$TX5","rx5g":"$RX5","txeth":"$TXE","rxeth":"$RXE"},
"ts":$(date +%s)}
EOF2
}

get_clients() {
    printf '{"clients":['
    clients_json | sed 's/,$//' | tr -d '\n'
    printf '],"stations":['
    wifi_stations | sed 's/,$//' | tr -d '\n'
    printf '],"ts":%d}' "$(date +%s)"
}

get_agg() {
    PINS=$(grep -v '^#' $GWDATA/agg_pins.conf 2>/dev/null | tr '\n' ';' | sed 's/;$/\n/')
    MACS=$(grep -A9 'Current configuration:' /proc/multi_wan/mac_config 2>/dev/null | grep -E '^[0-9a-f]{2}:' | tr '\n' ';' | sed 's/;$//')
    AGG_EN=$(grep -m1 '^ENABLE=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    case "$AGG_EN" in 0|1) ;; *) AGG_EN=1 ;; esac
    cat <<EOF3
{"enable":"$AGG_EN",
"engine":"$(cat /tmp/wan_engine 2>/dev/null)",
"weights":{"w1":"$(grep "WAN1 weight" /proc/multi_wan/weight 2>/dev/null | grep -oE "[0-9]+" | tail -1)"},
"wanmode":"$(cat /tmp/wan_mode 2>/dev/null)",
"pins_conf":"${PINS}",
"pins_live":"${MACS}",
"log":"$(tail -8 /tmp/wan_agg.log 2>/dev/null | tail -1 | sed 's/"/\\"/g')",
"ts":$(date +%s)}
EOF3
}

get_fw() {
    F=$(grep -v '^#' $GWDATA/forwards.conf 2>/dev/null | awk -F'|' '{printf "{\"proto\":\"%s\",\"eport\":\"%s\",\"dip\":\"%s\",\"dport\":\"%s\"},",$1,$2,$3,$4}' | sed 's/,$//')
    [ -r $GWDATA/dmz.conf ] && . $GWDATA/dmz.conf    # busybox ash: . 缺失文件=致命退出,必须守卫
    B=$(grep -oE '^[0-9a-f:]{17}$' $GWDATA/block.conf 2>/dev/null | awk '{printf "\"%s\",",$1}' | sed 's/,$//')
    printf '{"forwards":[%s],"dmz":{"enabled":"%s","ip":"%s"},"blocked":[%s],"ts":%d}' \
        "${F:-}" "${DMZ_EN:-0}" "${DMZ_IP:-}" "${B:-}" "$(date +%s)"
}

get_wifi() { printf '{%s,"stations":[' "$(wifi_state)"; wifi_stations | sed 's/,$//'; printf '],"ts":%d}' "$(date +%s)"; }

# ---------- 可插拔上行认证 (uplink) ----------
# 固件只提供"插座": 配置持久化 + AUTHD_CMD 拉起/杀停 + eth0 档案切换 + MAC/TTL
# 伪装。具体认证程序(任意 802.1X/Portal 客户端)由用户自行部署到 AUTHD_CMD 路径。
# uplink.conf 键: ENABLE/AUTH_USER/AUTH_PASS/AUTH_IP/AUTH_MASK/AUTH_GW/PROBE_GW/
# AUTHD_CMD/MAC_SPOOF/SPOOF_MAC/TTL_SPOOF/TTL_VALUE/FORM(home|static)
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
    # AUTHD_CMD 表单不传则保留 conf 现值; PROBE_GW 供 wan_agg 探活(与认证程序解耦)
    OLD=""; [ -r $GWDATA/uplink.conf ] && OLD=$(grep '^FORM=' $GWDATA/uplink.conf)
    OAC=""; [ -r $GWDATA/uplink.conf ] && OAC=$(grep -m1 '^AUTHD_CMD=' $GWDATA/uplink.conf | cut -d= -f2-)
    AC=$(form_kv authd_cmd)
    [ -z "$AC" ] && AC="${OAC:-/data/gw/authd eth0}"
    echo "$AC" | grep -qE '[^A-Za-z0-9_ ./-]' && jerr bad_cmd
    printf 'ENABLE=%s\nAUTH_USER=%s\nAUTH_PASS=%s\nAUTH_IP=%s\nAUTH_MASK=%s\nAUTH_GW=%s\nPROBE_GW=%s\nAUTHD_CMD=%s\nMAC_SPOOF=%s\nSPOOF_MAC=%s\nTTL_SPOOF=%s\nTTL_VALUE=%s\n%s\n' \
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
        # 原生值 = 出厂brmac计算(wifi_up同款算法, 排除伪装态误存)
        NATIVE=$(cat /sys/class/net/eth0/address 2>/dev/null)
        if [ "${MAC_SPOOF:-0}" = 1 ] && [ -n "$SPOOF_MAC" ] && [ "$NATIVE" = "$SPOOF_MAC" ]; then
            # 出厂档案可读才还原(此刻 eth0 处于伪装态, 无法反推原生值; 读不到则跳过)
            BM=$(uci get /fhdata/factory_conf.brmac.value 2>/dev/null)
            if [ -n "$BM" ]; then
                b2=$(printf %d 0x$(echo $BM | cut -d: -f2)); b2=$(( (b2+1) % 256 )); b2=$(printf %02X $b2)
                ORIG="$(echo $BM | cut -d: -f1):$b2:$(echo $BM | cut -d: -f3-)"
                ip link set eth0 down 2>/dev/null
                ip link set eth0 address "$(echo $ORIG | tr 'A-F' 'a-f')" 2>/dev/null
            fi
        fi
        ip link set eth0 up
        pkill -f "[a]uthd" 2>/dev/null
        # wan_agg ensure_lease 下一周期自动 udhcpc 重取租约
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
    printf '{"enable":"%s","user":"%s","ip":"%s","gw":"%s","form":"%s","daemon":"%s","mac_spoof":"%s","spoof_mac":"%s","ttl_spoof":"%s","ttl_value":"%s","eth0_mac":"%s","ttl_rule":"%s","ts":%d}' \
        "${ENABLE:-0}" "${AUTH_USER:-}" "${AUTH_IP:-}" "${AUTH_GW:-}" "${FORM:-home}" "$D" \
        "${MAC_SPOOF:-0}" "${SPOOF_MAC:-}" "${TTL_SPOOF:-0}" "${TTL_VALUE:-64}" "$EM" "$TR" "$(date +%s)"
}


get_sys() {
    I=$(ubus call system info 2>/dev/null)
    [ -n "$I" ] && printf '%s' "$I" || printf '{"error":"ubus"}'
}

esc() { sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g;s/\r//g;s/$/\\n/' | tr -d '\n'; }
get_logs() {
    L=$(tail -20 /tmp/wan_agg.log 2>/dev/null | esc)
    W=$(tail -10 /tmp/wifi_up.log 2>/dev/null | esc)
    printf '{"wan_agg":"%s","wifi":"%s"}' "$L" "$W"
}

get_dhcp() {
    cfg_load
    printf '{"r1":"%s","r2":"%s","lease":"%s"}' "${R1:-192.168.9.100}" "${R2:-192.168.9.200}" "${LEASE:-12h}"
}

# ---------- router ----------
EP="$1"
case "$EP" in
    # open GET
    status)   need_tok; get_status ;;
    clients)  need_tok; get_clients ;;
    wifi)     need_tok; get_wifi ;;
    uplink)   need_tok; get_uplink ;;
    agg)      need_tok; get_agg ;;
    fw)       need_tok; get_fw ;;
    sys)      need_tok; get_sys ;;
    logs)     need_tok; get_logs ;;
    dhcp)     need_tok; get_dhcp ;;
    cellular) need_tok; get_cellular ;;
    sms)       need_tok; get_sms ;;
    sms_send)  need_tok; apply_sms_send ;;
    traffic)   need_tok; get_traffic ;;
    sim)       need_tok; get_sim ;;
    netmode)   need_tok; get_netmode ;;
    fan)       need_tok; get_fan ;;
    led)       need_tok; cfg_load; get_led ;;
    dhcp_static) need_tok; get_dhcp_static ;;
    ntp)       need_tok; get_ntp ;;
    wifiscan)  need_tok; get_wifiscan ;;
    wifi_adv)  need_tok; get_wifi_adv ;;
    # auth POST
    login)
        [ "$V3_METHOD" = POST ] || jerr post_only
        # v2.23: 首刷自举 -- payload 不带 gui_auth.conf(纯原厂直刷时 /data 无此文件),
        # 缺失时任何口令都不可能通过(sha256 恒非空) = 首启锁死。以文档化默认口令
        # 建档(README 有载), 并在响应标记 default=true 供 GUI 强制提醒改密。
        if [ ! -s $GWDATA/gui_auth.conf ]; then
            mkdir -p $GWDATA
            printf '%s' "lg6151m" | sha256sum | cut -d' ' -f1 > $GWDATA/gui_auth.conf
            chmod 600 $GWDATA/gui_auth.conf
        fi
        P=$(form_kv pass)
        H=$(printf '%s' "$P" | sha256sum | cut -d' ' -f1)
        [ "$H" = "$(cat $GWDATA/gui_auth.conf 2>/dev/null)" ] || jerr bad_login
        _D=0; [ "$H" = "$(printf '%s' "lg6151m" | sha256sum | cut -d' ' -f1)" ] && _D=1
        printf '{"ok":true,"token":"%s","default":%s}' "$(tok_new)" "$_D"
        ;;
    logout)
        need_tok; rm -f $TOKDIR/$(form_kv token); ok_json ;;
    # write POST (token)
    wifi_set)     need_tok; apply_wifi ;;
    dhcp_set)     need_tok; apply_dhcp ;;
    fwd_add)      need_tok; apply_fwd_add ;;
    fwd_del)      need_tok; apply_fwd_del ;;
    dmz_set)      need_tok; apply_dmz ;;
    block_set)    need_tok; apply_block ;;
    agg_weights)  need_tok; apply_agg_weights ;;
    agg_mode)     need_tok; apply_agg_mode ;;
    uplink_set)   need_tok; apply_uplink ;;
    uplink_form)  need_tok; apply_uplink_form ;;
    agg_pin)      need_tok; apply_agg_pin ;;
    cell_bandlock) need_tok; apply_bandlock ;;
    cell_lock)     need_tok; apply_celllock ;;
    traffic_limit) need_tok; apply_traffic_limit ;;
    pin_set)       need_tok; apply_pin ;;
    netmode_set)   need_tok; apply_netmode ;;
    airplane_set)  need_tok; apply_airplane ;;
    plmn_scan)     need_tok; net_plmn_scan ;;
    fan_set)       need_tok; apply_fan ;;
    led_set)       need_tok; apply_led ;;
    dhcp_static_set) need_tok; apply_dhcp_static ;;
    ntp_set)       need_tok; apply_ntp ;;
    wifi_adv_set)  need_tok; apply_wifi_adv ;;
    pass_set)      need_tok; apply_pass_set ;;
    sys_reboot)
        need_tok; ok_json; (sleep 1; reboot) & ;;
    wifi_restart)
        need_tok; sh $GWDATA/wifi_up.sh >/tmp/wifi_up.log 2>&1 & ok_json ;;
    fw_apply)
        need_tok; fw_apply; ok_json ;;
    *) jerr unknown ;;
esac
