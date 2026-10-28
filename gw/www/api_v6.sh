# api_v6.sh v1.0 -- API IPv6 LAN 域模块
# 端点: v6(状态) / v6_set(开关, 立即生效)
# 单一事实源 = v6_reconcile.sh status(它读 /tmp/v6_state + 实况 ip/pidof)。
#   本模块只转 JSON, 不自己判定 —— 状态页历史上硬编码 "ULA 已部署", 在 v6 全挂
#   时照样显示绿(2026-10-28 实弹), 那类"页面自算一套状态"的做法一律不再用。
get_v6() {
    O=$(sh /data/gw/v6_reconcile.sh status 2>/dev/null)
    _v() { printf '%s\n' "$O" | tr ' ' '\n' | sed -n "s/^$1=//p" | head -1; }
    M=$(_v mode); U=$(_v up); L=$(_v ula); R=$(_v radvd); E=$(_v v6lan)
    case "$M" in
        on)       T="运行中" ;;
        disabled) T="已关闭" ;;
        noup)     T="无 IPv6 上行（已暂停广播）" ;;
        wait)     T="等待 LAN 网桥" ;;
        nobr)     T="无 LAN 网桥" ;;
        *)        T="未初始化" ;;
    esac
    # on 但缺件 = 真故障, 文案不许报绿
    if [ "$M" = on ]; then
        [ "$L" = 1 ] || T="ULA 缺失"
        [ "$R" = - ] && T="RA 守护未运行"
    fi
    printf '{"enabled":"%s","mode":"%s","text":"%s","up":"%s","ula":"%s","radvd":"%s","prefix":"fd42:9ac1:7e50::/64","ts":%d}\n' \
        "${E:-1}" "${M:-unknown}" "$T" "${U:--}" "${L:-0}" "${R:--}" "$(date +%s)"
}
apply_v6() {
    E=$(form_kv enabled)
    { [ "$E" = 0 ] || [ "$E" = 1 ]; } || jerr bad_enabled
    gw_set V6LAN "$E"
    O=$(sh /data/gw/v6_reconcile.sh apply 2>&1)
    alog "v6_set enabled=$E -> $O"
    ok_json
}
