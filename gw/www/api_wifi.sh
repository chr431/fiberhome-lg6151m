# api_wifi.sh v1.1 — WiFi 域模块 (被 api.sh 按端点懒加载; 依赖核心的 helpers/cfg 助手)
# v1.1 (2026-10-21 WiFi 事故): wifi_state 的 hostapd2g/5g 改活控制套接字判据
#   (原 iw "type AP" 在 hostapd 死后仍为真, GUI 显示“正常”).
# v1.0 (2026-10-17 架构轮): 自 api.sh v2.74 拆出 — wifi/wifi_adv/band_pin/wifiscan/
#   wifi_set 端点族。域历史(自 api.sh 头注迁入):
# v2.68: wifi_state MLO 链路计数修正: 按 Affiliated AP[i] 索引去重 — 每 AP 3 行
#   明细按行数=3×N 错。
# v2.67: wifi_state 增 MLO 实况: mwctl dump ap_mld stdout 直读(RE: dump 段输出干净)
#   — 状态页 WiFi 卡片显示双链路实况。
# v2.58: wifiscan 中文 SSID: iw \xNN 转义解码为原始 UTF-8 字节 — 原样透传+tr去
#   反斜杠=页面显示 xe8xbf... 垃圾。
# v2.55: 补采 2.4G 40M 上/下侧信道方向(dir)。
# v2.47: 访客隔离强制开启(开关已删, GUEST_ISOLATE 残留键清除)。
# v2.43: MLO 在线重应用即时生效(wifi_up v1.23 修复后撤销重启纪律)。
# v2.39: MLO(真双链路) — 开启时强制双频同名(INONE=1)。
# ---------- wifi ----------
wifi_state() {
    cfg_load
    # v1.1 (2026-10-21 WiFi incident): "type AP" only proves the driver kept
    # AP mode — it stayed 1 for 5.5h after hostapd died and the GUI reported
    # "正常".  The WPA layer is real only when hostapd's control socket has a
    # LIVE bound endpoint (/proc/net/unix; a crashed daemon leaves the file).
    hap_live() {
        awk -v p="/var/run/hostapd/$1" '$NF==p{f=1} END{exit(f?0:1)}' /proc/net/unix 2>/dev/null \
            && echo 1 || echo 0
    }
    H2=$(hap_live ra0)   # v1.1: 活控制套接字 = WPA 层在服务
    H5=$(hap_live rai0)
    S2=$(iw dev ra0 info 2>/dev/null | grep -m1 channel | awk '{print $2}')
    S5=$(iw dev rai0 info 2>/dev/null | grep -m1 channel | awk '{print $2}')
    if [ "${INONE:-0}" = 1 ]; then D2="${SSID_BASE:-?}"; D5="${SSID_BASE:-?}"
    else D2="${SSID_BASE:-?}-2.4G"; D5="${SSID_BASE:-?}-5G"; fi
    # v2.67: MLO 实况 — mwctl dump ap_mld stdout 直读(RE: dump 段走 MTK vendor
    #   netlink 封装输出干净; show 段输出进 dmesg 不可脚本化)。0=未启用/未建立。
    # v2.68: 链路计数按索引去重 — 每 AP 3 行明细(BSSID/Link ID/STR), 按行数=3×N 错
    MLG=""; MLL=0
    _MO=$(/usr/sbin/mwctl ra0 dump ap_mld all 2>/dev/null)
    MLG=$(echo "$_MO" | grep -o 'AP MLD group id:[0-9]*' | head -1 | cut -d: -f2)
    MLL=$(echo "$_MO" | grep -o 'Affiliated AP\[[0-9]*\]' | sort -u | wc -l)
    printf '"ssid_base":"%s","ssid2g":"%s","ssid5g":"%s","secured":%s,"hostapd2g":%s,"hostapd5g":%s,"ch2g":"%s","ch5g":"%s","mlo_grp":"%s","mlo_links":%s' \
        "${SSID_BASE:-?}" "$D2" "$D5" "$([ -n "$WPAPSK" ] && echo true || echo false)" \
        "${H2:-0}" "${H5:-0}" "${S2:--}" "${S5:--}" "${MLG:-}" "${MLL:-0}"
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

get_wifi() { printf '{%s,"stations":[' "$(wifi_state)"; wifi_stations | sed 's/,$//'; printf '],"ts":%d}' "$(date +%s)"; }

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

# -- 邻居 AP 扫描 (apclii0 短暂 up 扫 5G; ra0/apcli0 扫 2.4G) --
get_wifiscan() {
    # v2.55: 补采 2.4G 40M 上/下侧信道方向(dir) — 信道图按真实占用频段绘制的前提
    # v2: 预热3s(1s时几乎扫不到) + 双轮扫描合并(第二轮更饱满) + 按MAC去重
    ifconfig apcli0 up 2>/dev/null; ifconfig apclii0 up 2>/dev/null; sleep 3
    R1=$(iw apcli0 scan 2>/dev/null; iw apclii0 scan 2>/dev/null)
    R2=$(iw apcli0 scan 2>/dev/null; iw apclii0 scan 2>/dev/null)
    ifconfig apcli0 down 2>/dev/null; ifconfig apclii0 down 2>/dev/null
    RES="$R1
$R2"
    echo "$RES" | awk '
        # v2.58: iw 把非打印/非 ASCII 字节转义为 \xNN(中文 SSID 必踩) — 原来原样透传,
        # 末端 tr -d "\" 去反斜杠后得到 "xe8xbfx9e..." 垃圾文本入 JSON;
        # 此处按字节解码回原始 UTF-8(v>=32 且 !=127), 控制字符丢弃。
        function unhex(c) { return index("0123456789abcdef", tolower(c)) - 1 }
        function unesc(s,   out, i, v, h, a, b) {
            out = ""
            while ((i = index(s, "\\x")) > 0) {
                out = out substr(s, 1, i - 1)
                h = tolower(substr(s, i + 2, 2))
                if (length(h) < 2) { out = out "x"; s = substr(s, i + 1); continue }
                a = unhex(substr(h, 1, 1)); b = unhex(substr(h, 2, 1))
                if (a < 0 || b < 0) { out = out "x" h; s = substr(s, i + 4); continue }
                v = a * 16 + b
                if (v >= 32 && v != 127) out = out sprintf("%c", v)
                s = substr(s, i + 4)
            }
            return out s
        }
        function flush() {
            if (ssid == "" || (mac in seen)) return
            seen[mac] = 1
            ssid = unesc(ssid)
            gsub(/"/, "", ssid)

            band = freq+0 > 4000 ? "5G" : "2.4G"
            # v2.31: 带宽(VHT/HE op channel width 末次; HT secondary 判40; 默认20)+中心段
            if (vhtbw == "") { bw = ht40 ? 40 : 20 } else { bw = vhtbw }
            printf "{\42ssid\42:\42%s\42,\42mac\42:\42%s\42,\42band\42:\42%s\42,\42freq\42:\42%s\42,\42signal\42:\42%s\42,\42sec\42:\42%s\42,\42bw\42:\42%d\42,\42ctr\42:\42%s\42,\42dir\42:\42%d\42},", ssid, mac, band, freq, sig, sec, bw, ctr, dir
        }
        /^BSS / { flush(); mac=substr($2,1,17); sig=""; freq=""; ssid=""; sec="open"; vhtbw=""; ctr=""; ht40=0; dir=0 }
        /^[ 	]+signal:/ { sig=$2 }
        /^[ 	]+freq:/   { freq=$2 }
        /^[ 	]+SSID:/   { ssid=substr($0, index($0,":")+2) }
        /^[ 	]+(WPA|RSN):/ { sec="WPA" }
        /channel width: [0-9]+ \(([0-9]+)/ {
            w = $0; sub(/.*\(/, "", w); sub(/[^0-9].*/, "", w); vhtbw = w + 0
        }
        /center freq segment 1:/ { ctr = $NF }
        /secondary channel offset: above/ { ht40 = 1; dir = 1 }
        /secondary channel offset: below/ { ht40 = 1; dir = -1 }
        END { flush() }
    ' | tr -d '\' | sed 's/,$//' > /tmp/scan.$$
    L=$(cat /tmp/scan.$$ | tr -d '\n'); rm -f /tmp/scan.$$
    printf '{"aps":[%s],"ts":%d}' "$L" "$(date +%s)"
}
