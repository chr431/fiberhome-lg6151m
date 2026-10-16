#!/bin/sh
# wifi_autoch.sh v1.0 — WiFi 自动选道 (自 wifi_up v1.28 拆出, 2026-10-17 架构轮)
# usage: wifi_autoch.sh <want2> <want5> <bw5>
#   want2/want5: 0=该频段自动选道; 非 0=跳过该频段(不输出该行)
#   bw5: 5G 带宽(20/40/80/160), 用于邻道重叠评估
# 输出(stdout): "RCH2G=<ch>" / "RCH5G=<ch>" 行 —— 调用方(wifi_up)重定向落盘
#   /tmp/wifi_autoch(GUI wifi_adv 端点回读展示的契约保持不变)后 source;
#   过程信息走 stderr(调用方 exec 已重定向到 wifi_up.log)。
# 历史证据(自 wifi_up 迁入):
# v1.7: hwifi 内部 ACS(AutoChannelSelect=1)在 hostapd 接管安全的架构下从未验证可用,
#   改为拉起 apcli0/apclii0 扫描(与 GUI wifiscan 同配方), 对候选道按线性功率(mW)
#   和评分取最小: 2.4G 邻道±4重叠+经典道(1/6/11)偏好; 5G 80M 按整组(36-48/149-161)。
# v1.27: IDC(LTE 共存避让)安全掩码 — 驱动 IDC 武装时(bEnabled=1, 每秒轮询模组频段)
#   会把 AP 从"不安全"信道自行搬走(实测 n41@2644: ch1-8 安全/9-10 降功率/11-14 避让)。
#   选道必须只在安全集内, 否则必然出现"配置道≠实况道"。
#   掩码源: mwctl show 输出进内核日志; SafeChnBitmask 首段 bit=信道号(1fe=ch1-8)。
#   读不到(模组未起/命令不支持) → 回退全量候选, 由 watchdog 漂移护栏兜底。
# v1.28: 候选收敛到安全集深部 {1,6} — 实弹(2026-10-12): 开机模组未起时掩码不可用,
#   回退全量候选选出边界道 ch9(功率压缩区), 驱动 IDC 整晚反复搬运 2↔3↔9(客户端每
#   30-60s 被踢一次)。{1,6} 是经典不重叠中心且在 n41 安全集深部(掩码 1fe/1fc 两种
#   形态下 ch6 恒安全), 从根上消除边界振荡。
WANT2=${1:-0}; WANT5=${2:-0}; BW5=${3:-80}
echo "== auto-channel: scan for best channel (CH2G=$WANT2 CH5G=$WANT5) ==" >&2
IDC_SAFE=""
/usr/sbin/mwctl dev ra0 show unsafeinfo >/dev/null 2>&1
_M=$(dmesg 2>/dev/null | tail -60 | grep -o 'SafeChnBitmask=[0-9a-f]*' | tail -1 | cut -d= -f2)
[ -n "$_M" ] && IDC_SAFE=$((0x$_M))
CAND2=""
if [ -n "$IDC_SAFE" ] && [ "$IDC_SAFE" -gt 0 ] 2>/dev/null; then
    for c in 1 6; do
        [ $(( (IDC_SAFE >> c) & 1 )) = 1 ] && CAND2="$CAND2 $c"
    done
    [ -z "$CAND2" ] && for c in 1 2 3 4 5 6 7 8 9 10 11 12 13; do
        [ $(( (IDC_SAFE >> c) & 1 )) = 1 ] && CAND2="$CAND2 $c"
    done
fi
[ -z "$CAND2" ] && CAND2="1 6"
echo "== IDC safe mask: ${_M:-unavailable} cand2g=$CAND2 ==" >&2
ifconfig apcli0 up 2>/dev/null; ifconfig apclii0 up 2>/dev/null; sleep 3
ASCAN=$(iw apcli0 scan 2>/dev/null; iw apclii0 scan 2>/dev/null)
ifconfig apcli0 down 2>/dev/null; ifconfig apclii0 down 2>/dev/null
echo "$ASCAN" | awk -v want2="$WANT2" -v want5="$WANT5" -v bw5="$BW5" -v cand2="$CAND2" '
    function ch_of(f) {
        if (f == 2484) return 14
        if (f < 4000)  return int((f - 2407 + 2) / 5)
        return int((f - 5000 + 2) / 5)
    }
    function store() {
        if (fr == "" || sig == "") { fr = ""; sig = ""; return }
        if (sig + 0 > -90) {
            if (fr + 0 < 4000) p24[ch_of(fr + 0)] += 10 ^ (sig / 10)
            else               p5[ch_of(fr + 0)]  += 10 ^ (sig / 10)
        }
        fr = ""; sig = ""
    }
    function abs(v) { return v < 0 ? -v : v }
    /^BSS /       { store() }
    /^[ \t]+signal:/ { sig = $2 }
    /^[ \t]+freq:/   { fr = $2 }
    END {
        store()
        if (want2 == 0) {
            best = 1; bs = 1e30
            n = split(cand2, CA, " ")   # v1.27: 候选=IDC 安全集深部(无掩码时=经典{1,6})
            for (i = 1; i <= n; i++) {
                c = CA[i] + 0
                s = 0
                for (d = 1; d <= 13; d++) if (abs(d - c) <= 4) s += p24[d]
                if (c != 1 && c != 6 && c != 11) s *= 1.15   # 非经典道轻惩罚
                if (s < bs) { bs = s; best = c }
            }
            print "RCH2G=" best
        }
        if (want5 == 0) {
            # busybox awk 实测不解析跨行嵌套三元 -> 全部展开成 if/else
            split("36 40 44 48 149 153 157 161", C, " ")
            best = 149; bs = 1e30
            for (i = 1; i <= 8; i++) {
                c = C[i]; s = 0
                if (bw5 >= 160) half = 14
                else if (bw5 >= 80) half = 8
                else if (bw5 == 40) half = 1
                else half = 0
                for (d = 36; d <= 165; d++) {
                    if (!(d in p5)) continue
                    ov = 0
                    if (bw5 >= 160) {
                        # 160: 整个 36-64 块(含DFS)为一组; 149 组不可能连续160
                        if (c < 100) { if (d >= 36 && d <= 64) ov = 1 }
                        else         { if (d >= 149) ov = 1 }
                    } else if (bw5 >= 80) {
                        if (c < 100) { if (d >= 36 && d <= 48) ov = 1 }
                        else         { if (d >= 149) ov = 1 }
                    } else {
                        if (d >= c - half && d <= c + half) ov = 1
                    }
                    if (ov) s += p5[d]
                }
                if (s < bs) { bs = s; best = c }
            }
            print "RCH5G=" best
        }
    }'
