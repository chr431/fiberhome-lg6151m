# api_usb.sh v1.0 -- API USB 域模块(USB-C 设备模式)
# 端点: usb(状态) / usb_set(三开关, 立即生效 — 直接调 usb_mgr.sh apply)
# 状态数据源 = /data/gw/usb_mgr.sh status(单一事实源, 本模块只转 JSON);
# 硬件背景: 本口为仅设备模式 USB-C(host 电气死路), 服务语义见 usb_mgr.sh 头注。
get_usb() {
    O=$(sh /data/gw/usb_mgr.sh status 2>/dev/null)
    L=$(echo "$O" | sed -n 2p)
    _uv() { echo "$O" | sed -n "s/^$1=//p" | head -1; }
    _uw() { echo "$L" | sed -n "s/.*[[:space:]]$1=\([^ ]*\).*/\1/p" | head -1; }
    printf '{"enabled":"%s","adb":"%s","console":"%s","udc":"%s","state":"%s","bridge":"%s","ifup":"%s","carrier":"%s","adbd":"%s","gate":"%s","getty":"%s","ts":%d}\n' \
        "$(_uv enabled)" "$(_uv adb)" "$(_uv console)" \
        "$(_uw udc)" "$(_uw state)" "$(_uw bridge)" "$(_uw ifup)" "$(_uw carrier)" \
        "$(_uw adbd)" "$(_uw gate)" "$(_uw getty)" "$(date +%s)"
}
apply_usb() {
    E=$(form_kv enabled); A=$(form_kv adb); C=$(form_kv console)
    # 三键均可选但至少一个; 值域 0|1; 缺省键=不改现值
    if [ -z "$E" ] && [ -z "$A" ] && [ -z "$C" ]; then jerr bad_args; fi
    if [ -n "$E" ]; then { [ "$E" = 0 ] || [ "$E" = 1 ]; } || jerr bad_enabled
        gw_set USB_ENABLED "$E"; fi
    if [ -n "$A" ]; then { [ "$A" = 0 ] || [ "$A" = 1 ]; } || jerr bad_adb
        gw_set USB_ADB "$A"; fi
    if [ -n "$C" ]; then { [ "$C" = 0 ] || [ "$C" = 1 ]; } || jerr bad_console
        gw_set USB_CONSOLE "$C"; fi
    sh /data/gw/usb_mgr.sh apply >/dev/null 2>&1
    ok_json
}
