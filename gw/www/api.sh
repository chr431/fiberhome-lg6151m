#!/bin/sh
# api.sh v2.53 (CMGL→CMGR 逐条读: ql_ril CMGL 未读列表路径段错误; CMGF 读后还原 0: 入信自动存储疑似 0 态才可靠; AUTHD_CMD 引号落盘: 裸 KEY=v1 v2 被 . conf 按 env 前缀赋值解析=赋值丢弃, 冷启动 authd 永不拉起; SMS 实弹修复: CMGF=1 文本模式前置(modem 出厂 PDU 态 CMGL 报 CME 100 = 页面恒空), UCS2-BE 十六进制正文解码 UTF-8 + UDH 多段合并; 历史版本见git) -- v3 gateway API router (busybox sh; v3httpd fork+exec, no shell in C)
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
    # v2.47 (审计P0): settings.conf 会被 root 身份 source — 换行/控制字符可注入
    # 整行(含裸命令), 一票否决; 各端点的值域白名单仍为第一道防线(纵深第二道)。
    printf '%s' "$V" | LC_ALL=C grep -q '[^ -~]' && jerr bad_chars
    grep -v "^$K=" "$F" 2>/dev/null > "$F.new"
    echo "$K=$V" >> "$F.new"
    mv "$F.new" "$F"
    chmod 600 "$F"   # v2.49(P2/L-2): 明文PSK/口令类收紧
}
gw_del() {  # v2.37: gw_del <key> — 从 settings.conf 删除键(回退派生值语义)
    K=$1; F=$GWDATA/settings.conf
    grep -v "^$K=" "$F" 2>/dev/null > "$F.new"
    mv "$F.new" "$F"
}

# v2.49(P2/M-5): 严格点分十进制/MAC 校验 — 原 [^0-9.] 放行 "1.2.3.4.5" 类垃圾值,
# 非法值致 dnsmasq 拒启(DHCP 自杀至重启)或 iptables 规则静默失效。
ip_ok() {
    printf '%s' "$1" | grep -qE '^(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])){3}$'
}
mac_ok() {
    printf '%s' "$1" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$'
}
form_has() {  # v2.37: form_has <key> — 键是否出现在POST body(区分"未提交"与"空值")
    [ -n "$V3_BODY" ] || return 1
    printf '%s' "$V3_BODY" | tr '&' '\n' | grep -q "^$1="
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
    # v2.47 (审计P0): auth 补白名单 — 原样落盘 settings.conf 会被 root source,
    # `x$(cmd)` 类值即命令注入(与 apply_wifi_adv :AUTHV 同范式)
    case "$AUTH" in ""|WPA2PSK|WPA2PSKWPA3PSK) ;; *) jerr bad_auth ;; esac
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
    ip_ok "$R1" && ip_ok "$R2" || jerr bad_ip   # v2.49(P2/M-5): 严格点分十进制
    echo "$LEASE" | grep -qE '^[0-9]+[hm]$' || jerr bad_lease
    gw_set DHCP_R1 "$R1"; gw_set DHCP_R2 "$R2"; gw_set DHCP_LEASE "$LEASE"
    kill $(cat /var/run/dnsmasd_br.pid 2>/dev/null) 2>/dev/null; sleep 1
    # v2.49(P2/M-5): +rebind防护(与rc19 v2.20同源); 启动失败回落默认参数复活DHCP
    # (原实现直接 jerr, DHCP 死到重启), GUI 提示失败但服务不灭。
    dnsmasq -p 53 --no-resolv --server=223.5.5.5 --server=119.29.29.29 --stop-dns-rebind --bogus-priv \
        -i br-lan -I lo -F 192.168.9.0/255.255.255.0,${R1},${R2},${LEASE} \
        --dhcp-option=3,192.168.9.1 --dhcp-option=6,192.168.9.1 \
        --dhcp-leasefile=/tmp/dnsmasq_br.leases -x /var/run/dnsmasd_br.pid || {
        dnsmasq -p 53 --no-resolv --server=223.5.5.5 --server=119.29.29.29 --stop-dns-rebind --bogus-priv \
            -i br-lan -I lo -F 192.168.9.100,192.168.9.200,255.255.255.0,12h \
            --dhcp-option=3,192.168.9.1 --dhcp-option=6,192.168.9.1 \
            --dhcp-leasefile=/tmp/dnsmasq_br.leases -x /var/run/dnsmasd_br.pid
        jerr dnsmasq_fail
    }
    ok_json
}

apply_fwd_add() {
    P=$(form_kv proto); EP=$(form_kv eport); DIP=$(form_kv dip); DP=$(form_kv dport)
    [ "$P" = tcp ] || [ "$P" = udp ] || jerr bad_proto
    for PT in "$EP" "$DP"; do
        case "$PT" in ""|*[!0-9]*) jerr bad_port ;; esac
        [ "$PT" -ge 1 ] && [ "$PT" -le 65535 ] || jerr bad_port
    done
    ip_ok "$DIP" || jerr bad_ip   # v2.49(P2/M-5)
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
    if [ "$EN" = 1 ]; then ip_ok "$IP" || jerr bad_ip; fi   # v2.49(P2/M-5)
    printf 'DMZ_EN=%s\nDMZ_IP=%s\n' "$EN" "${IP:-}" > $GWDATA/dmz.conf
    fw_apply; ok_json
}
apply_block() {
    M=$(form_kv mac | tr 'A-F' 'a-f')
    mac_ok "$M" || jerr bad_mac   # v2.49(P2/M-5): 严格格式(原正则放行 ":::::::::::")
    if [ "$(form_kv del)" = 1 ]; then
        grep -v "^$M$" $GWDATA/block.conf 2>/dev/null > /tmp/b.$$; mv /tmp/b.$$ $GWDATA/block.conf
    else
        grep -q "^$M$" $GWDATA/block.conf 2>/dev/null || echo "$M" >> $GWDATA/block.conf
    fi
    fw_apply; ok_json
}

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

# -- 短信(只读收件: CMGR 逐条; 发送走 mipc_cellular sendsms) --
# v2.53(2026-10-07 实弹): CMGL 全线弃用 — ql_ril 的 CMGL 未读列表路径段错误
#   (新到未读短信在存储时, CMGL="ALL"/"REC UNREAD" 必崩 mipc_wan_cli, "REC READ"
#   空返回不崩; CMGR 逐条完全正常)。改为 CPMS 计数 + CMGR 1..N 循环(CMGR 读后
#   自动转已读 = 顺带绕开崩溃路径)。索引可能因删除有洞, 洞位返回 CMS ERROR 跳过。
# v2.50(2026-10-07 实弹修复): modem 出厂 CMGF=0(PDU 模式)下字符串 stat 参数必报
#   +CME ERROR:100 = GUI 短信页恒空。现每次先 AT+CMGF=1(易失配置, modem 重启回
#   0, 故幂等设置), 读毕还原 0(11:5x 入信丢失窗口与 1 态重合, 宁可信其有)。
#   正文: 中文运营商短信是 UCS2-BE 十六进制(多段带 UDH 头 050003|ref|n|seq),
#   原样透传=乱码; 现解码 UCS2->UTF-8 并按 (oa,ref) 合并多段, GSM7 可读正文
#   原样透传。busybox awk 无 strtonum -> h2d 手工换算; 无区间量词 -> 显式判长。
get_sms() {
    mipc_wan_cli --at_cmd "AT+CMGF=1" >/dev/null 2>&1
    N=$(mipc_wan_cli --at_cmd "AT+CPMS?" 2>/dev/null | grep -oE '\+CPMS: "[A-Z]+", [0-9]+' | grep -oE '[0-9]+$')
    case "$N" in ''|*[!0-9]*) N=0;; esac
    [ "$N" -gt 30 ] && N=30
    OUT=""
    i=1
    while [ "$i" -le "$N" ]; do
        OUT="$OUT+IDX: $i
$(mipc_wan_cli --at_cmd "AT+CMGR=$i" 2>/dev/null)
"
        i=$((i+1))
    done
    mipc_wan_cli --at_cmd "AT+CMGF=0" >/dev/null 2>&1
    # +IDX: <i> 块内 +CMGR: "stat","<oa>",[...],"<time>"\n<text>
    echo "$OUT" | awk '
function h2d(c){ return index("0123456789ABCDEF", c)-1 }
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\r\n\t]/," ",s); return s }
function dec(h,  i,cp,b1,b2,b3,o){
  o=""; h=toupper(h)
  for(i=1;i+3<=length(h);i+=4){
    cp=h2d(substr(h,i,1))*4096+h2d(substr(h,i+1,1))*256+h2d(substr(h,i+2,1))*16+h2d(substr(h,i+3,1))
    if(cp<128) o=o sprintf("%c",cp)
    else if(cp<2048){ b1=192+int(cp/64); b2=128+cp%64; o=o sprintf("%c%c",b1,b2) }
    else { b1=224+int(cp/4096); b2=128+int(cp/64)%64; b3=128+cp%64; o=o sprintf("%c%c%c",b1,b2,b3) }
  }
  return o
}
BEGIN{ n=0; cidx="?" }
/^\+IDX: /{
  gsub(/\r/,"")
  cidx=$0; sub(/^\+IDX: /,"",cidx)
}
/^\+CMGR: /{
  gsub(/\r/,"")
  idx=cidx
  oa=$0; sub(/^[^,]*,/,"",oa); sub(/^[^,]*,/,"",oa); sub(/,.*/,"",oa); gsub(/"/,"",oa)
  tm=$0; sub(/^.*,/,"",tm); gsub(/"/,"",tm)
  getline raw; gsub(/\r/,"",raw)
  if(raw == "" || raw ~ /^(AT response|OK|\+CMS|\+CME)/) next   # 洞位/错误块
  ref=""; body=raw
  if(body ~ /^050003/ && length(body) >= 12){
    ref=substr(body,7,4)
    k=oa "|" ref
    if(k in txt){ txt[k]=txt[k] substr(body,13); next }
    body=substr(body,13)
  } else k="i" idx
  order[++n]=k; koa[k]=oa; ktm[k]=tm; kidx[k]=idx
  txt[k]=body
}
END{
  for(i=1;i<=n;i++){ k=order[i]
    h=txt[k]
    if(h ~ /^[0-9A-Fa-f]+$/ && length(h)%2==0 && length(h)>=4) t=dec(h); else t=h
    printf "{\"idx\":\"%s\",\"from\":\"%s\",\"time\":\"%s\",\"text\":\"%s\"},", kidx[k], koa[k], ktm[k], esc(t)
  }
}' > /tmp/sms.$$
    L=$(sed 's/,$//' /tmp/sms.$$); rm -f /tmp/sms.$$
    N=$(printf '%s' "$L" | grep -o '"idx"' | wc -l)
    printf '{"msgs":[%s],"count":%d,"send_supported":true,"ts":%d}' "$L" "$N" "$(date +%s)"
}

# -- 流量统计 (ubus 活方法; 限额自管) --
get_traffic() {
    # v2.34: /proc/net/dev 直读(与 mobilenetwork 同源做法) — 蜂窝口字节数
    IF=$(ip -o -4 addr show 2>/dev/null | grep -m1 'ccmni.*inet' | awk '{print $2}')
    RX=0; TX=0
    if [ -n "$IF" ]; then
        RX=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null)
        TX=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null)
    fi
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


# -- SSE 事件流 (v2.44): v3httpd v2.4 已发流式响应头, 本端点只持续输出事件。
# 事件 = 服务小区信号(3s节奏); 570s 自退(双保险, EventSource 自动重连)。
get_sse() {
    # v2.48(P1): 全局 SSE 并发上限 — 每连接常驻 570s, 占用 = httpd子进程+api.sh+
    # 周期性 mipc 子进程; 上限 8 足够真实客户端(GUI 单开), 挡批量资源耗尽。
    _n=$(ps | grep -c "[a]pi.sh sse")
    [ "$_n" -gt 8 ] && { printf '{"error":"sse_busy"}'; exit 0; }
    _t=0
    while :; do
        CJ=$(/data/gw/mipc_cellular cells 2>/dev/null | head -1)
        SIG=""
        case "$CJ" in
            '{"serving"'*) SIG=$(printf '%s' "$CJ" | sed 's/^{"serving"://; s/,"cells".*//') ;;
        esac
        [ -z "$SIG" ] && SIG='null'
        printf 'data: {"sig":%s,"ts":%s}

' "$SIG" "$(date +%s)"
        sleep 3
        _t=$((_t+3)); [ $_t -ge 570 ] && exit 0
    done
}

# -- WiFi 高级 (信道/带宽/功率/隐藏) + 访客(独立名称/频段/密码) + 双频合一 --
get_wifi_adv() {
    cfg_load
    H2=$(grep -m1 "^HideSSID" /var/wlan/apcfg 2>/dev/null | cut -d= -f2 | cut -d\; -f1)
    RCH2G=""; RCH5G=""
    [ -r /tmp/wifi_autoch ] && . /tmp/wifi_autoch   # wifi_up 自动选道落点(信道=0时)
    GS_RAW="${GUEST_SSID:-}"
    GS_EFF="${GUEST_SSID:-${SSID_BASE:-}-Guest}"
    printf '{"ssid_base":"%s","ch2g":"%s","ch5g":"%s","bw2g":"%s","bw5g":"%s","power":"%s","hidden2g":"%s","hidden5g":"%s","auth":"%s","guest":"%s","guest_ssid":"%s","guest_ssid_eff":"%s","guest_band":"%s","guest_pass":"%s","inone":"%s","mlo":"%s","res2g":"%s","res5g":"%s","ts":%d}' \
        "${SSID_BASE:-}" "${CH2G:-6}" "${CH5G:-149}" "${BW2G:-20}" "${BW5G:-80}" "${POWER:-100}" \
        "${H2:-0}" "0" "${AUTH:-WPA2PSK}" "${GUEST:-0}" "$GS_RAW" "$GS_EFF" "${GUEST_BAND:-5g}" "${GUEST_PASS:+1}" "${INONE:-0}" "${MLO:-0}" "${RCH2G:-}" "${RCH5G:-}" "$(date +%s)"
}
apply_wifi_adv() {
    # v1.2: 先源旧conf(保留SSID/密码等非本表单字段), 再读表单值覆盖同名项
    # — 曾因source放在form_kv之后, INONE/GUEST被旧值覆盖致"选项弹回"(用户实弹)
    # v2.37: 换 cfg_load(默认+settings全叠加), 访客独立项存 settings.conf 也可见
    cfg_load
    # v1.6: 统一名称 — 表单传 ssid_base
    SB=$(form_kv ssid_base); [ -z "$SB" ] && SB="${SSID_BASE:-LG6151M}"
    echo "$SB" | grep -qE '[^A-Za-z0-9_. -]' && jerr bad_chars
    CH2=$(form_kv ch2); CH5=$(form_kv ch5); BW2=$(form_kv bw2); BW5=$(form_kv bw5)
    PW=$(form_kv power); HID=$(form_kv hidden); GUEST=$(form_kv guest)
    GSTP=$(form_kv guest_pass); INONE=$(form_kv inone); MLOV=$(form_kv mlo)
    # v2.37: 访客独立项 — 名称(present但可空=回退派生)/频段(2g|5g|both)
    GSS=""; form_has guest_ssid && GSS=$(form_kv guest_ssid)
    GBAND=$(form_kv guest_band)
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
    # v2.39: MLO(真双链路) — 开启时强制双频同名(INONE=1); 生效需重启网关(FW锁存)
    [ "$MLOV" = 0 ] || [ "$MLOV" = 1 ] || jerr bad_flag
    [ "$MLOV" = 1 ] && INONE=1
    # 访客名称: 与主名称同字符集(防注入 settings.conf 被 source), ≤32字节(802.11上限)
    if [ -n "$GSS" ]; then
        echo "$GSS" | grep -qE '[^A-Za-z0-9_. -]' && jerr bad_chars
        [ "${#GSS}" -gt 32 ] && jerr bad_len
    fi
    case "$GBAND" in ""|2g|5g|both) ;; *) jerr bad_band ;; esac
    [ -z "$GBAND" ] && GBAND=5g
    if [ -n "$GSTP" ]; then
        printf '%s' "$GSTP" | grep -qE '^[A-Za-z0-9-]{8,63}$' || jerr bad_pass
    fi
    # v2.38: 主WiFi密码/加密并入(原"无线设置"卡移除, 主WiFi卡一站式); 留空=不修改
    MPW=""; form_has pass && MPW=$(form_kv pass)
    AUTHV=$(form_kv auth)
    if [ -n "$MPW" ]; then
        printf '%s' "$MPW" | grep -qE '^[A-Za-z0-9-]{8,63}$' || jerr bad_pass
    fi
    case "$AUTHV" in ""|WPA2PSK|WPA2PSKWPA3PSK) ;; *) jerr bad_auth ;; esac
    # v2.37: 开访客必须存在密码(旧存或本次提交), 杜绝"静默无访客"困惑
    if [ "$GUEST" = 1 ] && [ -z "$GSTP" ] && [ -z "$GUEST_PASS" ]; then
        jerr need_guest_pass
    fi
    # v1.2: source已提前到函数头, 此处不再重复(旧位置曾覆盖INONE/GUEST表单值)
    gw_set SSID_BASE "$SB"
    gw_set CH2G "$CH2"; gw_set CH5G "$CH5"; gw_set BW2G "$BW2"; gw_set BW5G "$BW5"
    gw_set POWER "$PW"; gw_set HIDDEN "$HID"; gw_set GUEST "$GUEST"; gw_set INONE "$INONE"
    gw_set MLO "$MLOV"
    gw_set GUEST_BAND "$GBAND"
    gw_del GUEST_ISOLATE   # v2.47: 访客隔离强制开启(开关已删), 清残留键
    if [ -n "$GSS" ]; then gw_set GUEST_SSID "$GSS"; elif form_has guest_ssid; then gw_del GUEST_SSID; fi
    if [ -n "$GSTP" ]; then gw_set GUEST_PASS "$GSTP"; fi
    [ -n "$MPW" ] && gw_set WPAPSK "$MPW"
    [ -n "$AUTHV" ] && gw_set AUTH "$AUTHV"
    # v2.43: 撤销 v2.41 的 mlo_reboot 纪律 — wifi_up v1.23 修复在线重应用(MLO 下
    # 接口已UP时先下电回冷启动等价态, T1-T5 受控实验矩阵实证; 原 -B 后台化子进程
    # 在接口UP+MLD武装继承态必死)。MLO 下改动恢复即时生效。
    # (ok_json 的 ${1:+,$1} 自带逗号前缀, NOTE 勿再带 — 逗号bug四犯防御)
    MLO_NOTE=""
    [ "$MLOV" != "${MLO:-0}" ] && MLO_NOTE='"mlo_changed":1'
    sh $GWDATA/wifi_up.sh >/tmp/wifi_up.log 2>&1 &
    ok_json "$MLO_NOTE"
}

# -- 终端频段锁定 (v2.47: 承接原访客"兼容机模式"需求 — 主 WiFi 按 MAC 钉死单频段,
#    避免终端在双频间频繁切换; 访客隔离改强制开启后的兼容出口。wifi_up 消费
#    band_pins.conf 在对侧频段 main BSS 挂 deny ACL。写配置不重启 — 由 GUI 显式
#    应用(调 wifi_restart), 批量增删只付一次重启代价) --
get_band_pin() {
    [ -r $GWDATA/band_pins.conf ] || { printf '{"pins":[]}'; return; }
    PINS=$(grep -v '^#' $GWDATA/band_pins.conf | awk -F'|' '$1!=""&&$2!=""{printf "{\"mac\":\"%s\",\"band\":\"%s\"},",$1,$2}')
    printf '{"pins":[%s]}' "${PINS%,}"
}
apply_band_pin_add() {
    M=$(form_kv mac | tr 'A-F' 'a-f'); B=$(form_kv band)
    printf '%s' "$M" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || jerr bad_mac
    case "$B" in 2g|5g) ;; *) jerr bad_band ;; esac
    F=$GWDATA/band_pins.conf
    grep -v "^$M|" $F 2>/dev/null > /tmp/bp.$$    # 同 MAC 再加 = 改频段
    echo "$M|$B" >> /tmp/bp.$$
    mv /tmp/bp.$$ $F
    ok_json
}
apply_band_pin_del() {
    M=$(form_kv mac | tr 'A-F' 'a-f')
    printf '%s' "$M" | grep -qE '^[0-9a-f]{2}(:[0-9a-f]{2}){5}$' || jerr bad_mac
    grep -v "^$M|" $GWDATA/band_pins.conf 2>/dev/null > /tmp/bp.$$
    mv /tmp/bp.$$ $GWDATA/band_pins.conf
    ok_json
}


get_cellular() {
    # v2.35 (P3 终章): mipc 引擎下服务小区+CA 列表直取 ql_nw_get_cell_info
    # (mipc_cellular v0.5 cells, cellraw 实证布局) — 不再依赖树回填, mobilenetwork
    # 至此零消费者。树路径仅在 engine=tree 时使用。
    CELL_ENGINE=mipc
    [ -r $GWDATA/cellular_engine.conf ] && . $GWDATA/cellular_engine.conf
    if [ "$CELL_ENGINE" = mipc ] && [ -x /data/gw/mipc_cellular ]; then
        CJ=$(/data/gw/mipc_cellular cells 2>/dev/null | head -1)
        case "$CJ" in
        '"serving"'*|'{"serving"'*)
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
            return
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
    NC=$(printf '%s' "$BANDS" | awk -F, '{print NF}')
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
    ACT=$(printf '%s' "$COPSR" | awk -F, '{gsub(/
/,"");n=NF; gsub(/[^0-9]/,"",$n); print $n}')
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
    # v2.42: w1pct 三级回退 — iptables 引擎态 /proc/multi_wan/* 不存在(quecadp 专属),
    # 旧读法永远"?"致 GUI 滑块停在中间不与实配同步。顺序: agg.conf(权威,即写即读)
    # → proc(quecadp 态) → wan_agg 日志 pct=(引擎实跑值)
    AGG_W=$(grep -m1 '^W1_PCT=' $GWDATA/agg.conf 2>/dev/null | cut -d= -f2)
    [ -z "$AGG_W" ] && AGG_W=$(grep "WAN1 weight" /proc/multi_wan/weight 2>/dev/null | grep -oE "[0-9]+" | tail -1)
    [ -z "$AGG_W" ] && AGG_W=$(tail -1 /tmp/wan_agg.log 2>/dev/null | grep -oE 'pct=[0-9]+' | head -1 | cut -d= -f2)
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
    printf '{"enable":"%s","user":"%s","ip":"%s","gw":"%s","form":"%s","daemon":"%s","authd_cmd":"%s","mac_spoof":"%s","spoof_mac":"%s","ttl_spoof":"%s","ttl_value":"%s","eth0_mac":"%s","ttl_rule":"%s","ts":%d}' \
        "${ENABLE:-0}" "${AUTH_USER:-}" "${AUTH_IP:-}" "${AUTH_GW:-}" "${FORM:-home}" "$D" "${AUTHD_CMD:-}" \
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
    cellular)  need_tok; get_cellular ;;
    sse)       need_tok; get_sse ;;   # v2.48(P1): +token 门(原为路由表唯一未认证读端点, 泄蜂窝身份/信号=位置侧信道); EventSource 走 ?token=
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
        # v2.47 (审计P0): 失败锁定 — 连续 10 次失败锁 15 分钟(全局单管理员, 无按源
        # 区分: LAN 内伪造源地址成本低, 全局足够)。成功即清零; 窗口滑动(每次失败
        # 刷新时间戳)。文件只存"次数 时间戳", 无敏感内容。
        FAILF=/tmp/gui_auth.fails; FC=0; FL=0
        read FC FL < $FAILF 2>/dev/null
        case "$FC" in ''|*[!0-9]*) FC=0 ;; esac
        case "$FL" in ''|*[!0-9]*) FL=0 ;; esac
        NOW=$(date +%s)
        { [ "$FC" -ge 10 ] && [ $((NOW - FL)) -lt 900 ]; } && jerr locked
        H=$(printf '%s' "$P" | sha256sum | cut -d' ' -f1)
        if [ "$H" != "$(cat $GWDATA/gui_auth.conf 2>/dev/null)" ]; then
            echo "$((FC + 1)) $NOW" > $FAILF
            jerr bad_login
        fi
        rm -f $FAILF
        _D=0; [ "$H" = "$(printf '%s' "lg6151m" | sha256sum | cut -d' ' -f1)" ] && _D=1
        printf '{"ok":true,"token":"%s","default":%s}' "$(tok_new)" "$_D"
        ;;
    logout)
        need_tok; rm -f $TOKDIR/$(form_kv token); ok_json ;;
    # write POST (token)
    wifi_set)     need_tok; apply_wifi ;;
    band_pin)     need_tok; get_band_pin ;;
    band_pin_add) need_tok; apply_band_pin_add ;;
    band_pin_del) need_tok; apply_band_pin_del ;;
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
