# api_lan.sh v1.0 — LAN 服务域模块: DHCP + 静态租约 + 防火墙(映射/DMZ/禁网)
# v1.0 (2026-10-17 架构轮): 自 api.sh v2.74 拆出。fw_apply.sh 改在本域内懒加载
#   (原 api.sh 对所有请求无条件 source)。域历史(自 api.sh 头注迁入):
# v2.49(P2/M-5): 严格点分十进制/MAC 校验 — 原 [^0-9.] 放行 "1.2.3.4.5" 类垃圾值,
#   非法值致 dnsmasq 拒启(DHCP 自杀至重启)或 iptables 规则静默失效。
# ---------- firewall apply (forwards + dmz + block) ----------
. $GWDATA/fw_apply.sh

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

# ---------- DHCP ----------
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

get_dhcp() {
    cfg_load
    printf '{"r1":"%s","r2":"%s","lease":"%s"}' "${R1:-192.168.9.100}" "${R2:-192.168.9.200}" "${LEASE:-12h}"
}

get_fw() {
    # v2.82: JSON 由 shell 拼(原 awk) —— 逐行读配置文件
    F=""
    if [ -r $GWDATA/forwards.conf ]; then
        while IFS='|' read -r _p _e _d _dp; do
            case "$_p" in ''|'#'*) continue ;; esac
            F="$F${F:+,}{\"proto\":\"$_p\",\"eport\":\"$_e\",\"dip\":\"$_d\",\"dport\":\"$_dp\"}"
        done < $GWDATA/forwards.conf
    fi
    [ -r $GWDATA/dmz.conf ] && . $GWDATA/dmz.conf    # busybox ash: . 缺失文件=致命退出,必须守卫
    B=""
    if [ -r $GWDATA/block.conf ]; then
        while IFS= read -r _m; do
            [ ${#_m} -eq 17 ] || continue
            case "$_m" in *[!0-9a-f:]*) continue ;; esac
            B="$B${B:+,}\"$_m\""
        done < $GWDATA/block.conf
    fi
    printf '{"forwards":[%s],"dmz":{"enabled":"%s","ip":"%s"},"blocked":[%s],"ts":%d}' \
        "${F:-}" "${DMZ_EN:-0}" "${DMZ_IP:-}" "${B:-}" "$(date +%s)"
}
