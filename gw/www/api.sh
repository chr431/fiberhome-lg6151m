#!/bin/sh
# api.sh v2.78 (v2.77, 2026-10-24 USB 轮: +usb/usb_set 域模块(api_usb.sh, USB-C
#   设备模式三开关: 总开关/ADB/控制台, 状态含 UDC/桥接/载波/门位); v2.76, 2026-10-17
#   日志加密轮: +请求级日志 /tmp/api.log — 写端点
#   全记、读端点仅慢请求/错误, 只含端点/方法/耗时/错误码, 不记 body/token/口令;
#   v2.75, 2026-10-17 架构轮: 模块化拆分 — 本文件收敛为 核心(helpers/
#   认证/配置助手) + 路由表, 六个域模块按端点懒加载($APID/api_{sys,wifi,lan,agg,
#   cell,sms}.sh); 每请求只解析所需域(原整文件 ~1550 行全解析); 域历史随域迁入
#   各模块头注。模块与 api.sh 同目录, v3httpd v2.6 静态面已拒 *.sh 直出(GET 返回
#   404) — 服务端逻辑唯一动态入口仍是 /api/<ep>。端点与 JSON 契约零变化。
#   v2.74: 命名中性化; v2.73: status 消费 /tmp/wan_alive; v2.72: 蜂窝上行 qdisc
#   口径; 历史见各域模块头注与 git) -- v3 gateway API router (busybox sh; v3httpd
#   fork+exec, no shell in C)
#   GET  /api/<ep>            read endpoints (open, LAN-only)
#   POST /api/<ep>  token=... write endpoints (sha256 auth, /tmp/gui_tokens)
# 注入防线: 所有写端点参数过 case/regex 白名单, 拒绝一切元字符 (原厂 send_msg
# 的 popen 注入教训)。body 为 form-encoded: a=1&b=2 (V3_BODY)。
GWDATA=/data/gw   # v2.12: 基座路径统一到 /data/gw
APID=$GWDATA/www  # v2.75: 域模块目录(与 api.sh 同目录; 静态面被 v3httpd 拒直出)
TOKDIR=/tmp/gui_tokens

# ---------- v2.76: 请求级日志 (24h 分析用) ----------
# 只记端点/方法/耗时/错误码, 绝不记 body/token/口令。写端点全记(低频); GET 仅
# 慢请求(>=2s)或错误记 — 状态页 2s 轮询不刷屏。本文件日志自轮转 512KB→1000 行。
API_LOG=/tmp/api.log
API_T0=$(date +%s)
API_EP="${1:-?}"
API_M="${V3_METHOD:-GET}"
alog() {
    echo "$(date '+%m-%d %H:%M:%S') epoch=$(date +%s) $*" >> $API_LOG
    [ "$(wc -c < $API_LOG 2>/dev/null || echo 0)" -gt 524288 ] && {
        tail -n 1000 $API_LOG > $API_LOG.tmp && mv $API_LOG.tmp $API_LOG; }
}

# ---------- tiny helpers ----------
jerr() {
    alog "ERR ep=$API_EP m=$API_M code=$1 ms=$(( $(date +%s) - API_T0 ))"
    printf '{"error":"%s"}' "$1"; exit 0
}

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

ok_json() {
    _ms=$(( $(date +%s) - API_T0 ))
    # v2.76: 写端点全记; 读端点只记慢请求(>=2s) — 保持日志低噪
    if [ "$API_M" = POST ] || [ "$_ms" -ge 2 ]; then
        alog "OK ep=$API_EP m=$API_M ms=$_ms"
    fi
    printf '{"ok":true%s}' "${1:+,$1}"
}

esc() { sed 's/\\/\\\\/g;s/"/\\"/g;s/\t/\\t/g;s/\r//g;s/$/\\n/' | tr -d '\n'; }

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

# ---------- 配置助手 (v2.14: defaults只读 + settings稀疏覆盖; 写方只动 settings) ----------
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
# v2.60: cellular.conf 统一 upsert — 原多写方混用整文件覆盖(频段锁 `>` 冲掉 NM_MODE/
#   CELL_i)与 grep+append(重复键), 全部收敛到本助手(gw_set 同款原子语义)。
cell_set() {  # cell_set <key> <value>
    K=$1; V=$2; F=$GWDATA/cellular.conf
    grep -v "^$K=" "$F" 2>/dev/null > "$F.new.$$"
    echo "$K=$V" >> "$F.new.$$"
    mv "$F.new.$$" "$F"
}

# ---------- 管理密码 (auth 域) ----------
apply_pass_set() {
    OLD=$(form_kv old); NEW=$(form_kv new)
    printf '%s' "$NEW" | grep -qE '^[A-Za-z0-9@#%^&*_.-]{8,63}$' || jerr bad_pass
    OH=$(printf '%s' "$OLD" | sha256sum | cut -d" " -f1)
    [ "$OH" = "$(cat $GWDATA/gui_auth.conf 2>/dev/null)" ] || jerr bad_old
    printf '%s' "$NEW" | sha256sum | cut -d" " -f1 > $GWDATA/gui_auth.conf
    chmod 600 $GWDATA/gui_auth.conf
    ok_json
}

# ---------- router (v2.75: 按端点懒加载域模块; 端点/契约与 v2.74 逐项一致) ----------
EP="$1"
case "$EP" in
    # auth (核心域)
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
    pass_set)   need_tok; apply_pass_set ;;
    # system 域 (状态/日志/流量/风扇/LED/NTP/定时重启/SSE)
    status)     need_tok; . $APID/api_sys.sh; get_status ;;
    clients)    need_tok; . $APID/api_sys.sh; get_clients ;;
    sys)        need_tok; . $APID/api_sys.sh; get_sys ;;
    logs)       need_tok; . $APID/api_sys.sh; get_logs ;;
    sse)        need_tok; . $APID/api_sys.sh; get_sse ;;   # v2.48(P1): +token 门(原为路由表唯一未认证读端点, 泄蜂窝身份/信号=位置侧信道); EventSource 走 ?token=
    fan)        need_tok; . $APID/api_sys.sh; get_fan ;;
    fan_set)    need_tok; . $APID/api_sys.sh; apply_fan ;;
    led)        need_tok; . $APID/api_sys.sh; get_led ;;
    led_set)    need_tok; . $APID/api_sys.sh; apply_led ;;
    ntp)        need_tok; . $APID/api_sys.sh; get_ntp ;;
    ntp_set)    need_tok; . $APID/api_sys.sh; apply_ntp ;;
    reboot_sched)     need_tok; . $APID/api_sys.sh; get_reboot ;;
    reboot_sched_set) need_tok; . $APID/api_sys.sh; apply_reboot ;;
    traffic)    need_tok; . $APID/api_sys.sh; get_traffic ;;
    traffic_hist)  need_tok; . $APID/api_sys.sh; get_traffic_hist ;;
    traffic_limit) need_tok; . $APID/api_sys.sh; apply_traffic_limit ;;
    sys_reboot) need_tok; ok_json; (sleep 1; reboot) & ;;
    diag_gen)   need_tok; (sh /data/gw/diag_dump.sh > /data/gw/logs/diag_last.txt 2>&1) & ok_json ;;
    # usb 域 (USB-C 设备模式; v2.78)
    usb)        need_tok; . $APID/api_usb.sh; get_usb ;;
    usb_set)    need_tok; . $APID/api_usb.sh; apply_usb ;;
    # wifi 域
    wifi)       need_tok; . $APID/api_wifi.sh; get_wifi ;;
    wifi_set)   need_tok; . $APID/api_wifi.sh; apply_wifi ;;
    wifi_adv)   need_tok; . $APID/api_wifi.sh; get_wifi_adv ;;
    wifi_adv_set) need_tok; . $APID/api_wifi.sh; apply_wifi_adv ;;
    band_pin)     need_tok; . $APID/api_wifi.sh; get_band_pin ;;
    band_pin_add) need_tok; . $APID/api_wifi.sh; apply_band_pin_add ;;
    band_pin_del) need_tok; . $APID/api_wifi.sh; apply_band_pin_del ;;
    wifiscan)   need_tok; . $APID/api_wifi.sh; get_wifiscan ;;
    wifi_restart) need_tok; sh $GWDATA/wifi_up.sh >/tmp/wifi_up.log 2>&1 & ok_json ;;
    # LAN 服务域 (DHCP + 防火墙)
    dhcp)       need_tok; . $APID/api_lan.sh; get_dhcp ;;
    dhcp_set)   need_tok; . $APID/api_lan.sh; apply_dhcp ;;
    dhcp_static)     need_tok; . $APID/api_lan.sh; get_dhcp_static ;;
    dhcp_static_set) need_tok; . $APID/api_lan.sh; apply_dhcp_static ;;
    fw)         need_tok; . $APID/api_lan.sh; get_fw ;;
    fwd_add)    need_tok; . $APID/api_lan.sh; apply_fwd_add ;;
    fwd_del)    need_tok; . $APID/api_lan.sh; apply_fwd_del ;;
    dmz_set)    need_tok; . $APID/api_lan.sh; apply_dmz ;;
    block_set)  need_tok; . $APID/api_lan.sh; apply_block ;;
    fw_apply)   need_tok; . $APID/api_lan.sh; fw_apply; ok_json ;;
    # 聚合+上行域
    agg)        need_tok; . $APID/api_agg.sh; get_agg ;;
    agg_weights) need_tok; . $APID/api_agg.sh; apply_agg_weights ;;
    agg_mode)   need_tok; . $APID/api_agg.sh; apply_agg_mode ;;
    agg_pin)    need_tok; . $APID/api_agg.sh; apply_agg_pin ;;
    uplink)     need_tok; . $APID/api_agg.sh; get_uplink ;;
    uplink_set) need_tok; . $APID/api_agg.sh; apply_uplink ;;
    uplink_form) need_tok; . $APID/api_agg.sh; apply_uplink_form ;;
    # 蜂窝域
    cellular)   need_tok; . $APID/api_cell.sh; get_cellular ;;
    sim)        need_tok; . $APID/api_cell.sh; get_sim ;;
    pin_set)    need_tok; . $APID/api_cell.sh; apply_pin ;;
    netmode)    need_tok; . $APID/api_cell.sh; get_netmode ;;
    netmode_set) need_tok; . $APID/api_cell.sh; apply_netmode ;;
    airplane_set) need_tok; . $APID/api_cell.sh; apply_airplane ;;
    plmn_scan)  need_tok; . $APID/api_cell.sh; net_plmn_scan ;;
    cell_bandlock) need_tok; . $APID/api_cell.sh; apply_bandlock ;;
    cell_lock)  need_tok; . $APID/api_cell.sh; apply_celllock ;;
    # 短信域
    sms)        need_tok; . $APID/api_sms.sh; get_sms ;;
    sms_send)   need_tok; . $APID/api_sms.sh; apply_sms_send ;;
    *) jerr unknown ;;
esac
