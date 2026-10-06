#!/bin/sh
# wifi_up.sh — v3 WiFi bring-up (v1.22: 访客iface显式入桥(动态BSS不自动加bridge,dnsmasq盲根因); v1.21: MLO访客静态单链路组17/18; v1.20: MLO单次AP启动; v1.19: MLO真双链路 — 两带 dat 各写 MldGroup=1;0;x6
#   (RE实证: stock be_init_wlan_apcfg_file 同款形态, 1基组号配对成MLD; 全零表=v1.15
#   事故形态禁写; MldAddr/ApcliMloDisable 勿写; MLD生效需冷启动(FW锁存); 纯MLO不需wapp);
#   v1.18: 访客独立配置; v1.16: F3单进程hostapd; v1.10: 自动信道扫描选道),
# replicating FH fac_start_wifi_BE5000.sh (mt7992 path)
# without FH userspace. Driver = MTK hwifi softap: profile /var/wlan/apcfg{,_5} +
# `ifconfig raX up` is the whole activation (ap_inf_open is ndo_open; apcfg is read
# at interface-open, MACs come from profile MacAddress=).
#
# Prereqs (verified present on this box):
#   - /etc/wireless/mediatek/{mt7992.1.dat,b0.dat,b1.dat,e2p} + /fhdata/wlan/e2p
#   - modules loaded: compat cfg80211 mt_wifi_cmn mt_wifi mtk_hwifi connac_if mtk_pci mt7992
#   - phys phy0/phy1 + netdevs ra0/rai0 exist (probe OK, addr all-zero = profile not applied)
B=$(cd "$(dirname "$0")" && pwd)   # v1.12: /data/gw 与 /data/gw 皆可
LOG=/tmp/wifi_up.log
exec >"$LOG" 2>&1
echo "== wifi_up start $(date)"

mkdir -p /var/wlan /var/ctcwifi
echo -n /etc/wireless > /sys/module/firmware_class/parameters/path 2>/dev/null

# ---- MAC plan (factory algorithm from brmac) ----
brmac=$(uci get /fhdata/factory_conf.brmac.value 2>/dev/null)
# 兜底1: 出厂档案不可读时由 eth0 原生MAC反推基址(第二字节-1, 与出厂算法互逆)
if [ -z "$brmac" ]; then
    E0=$(cat /sys/class/net/eth0/address 2>/dev/null)
    if [ -n "$E0" ]; then
        b0=$(printf %d 0x$(echo $E0 | cut -d: -f2)); b0=$(( (b0 + 255) % 256 ))
        brmac="$(echo $E0 | cut -d: -f1):$(printf %02X $b0):$(echo $E0 | cut -d: -f3-)"
    fi
fi
# 兜底2: 合成本地管理地址(不可路由, 非任何真实设备)
[ -z "$brmac" ] && brmac=02:03:7F:00:00:00
mac1=${brmac:0:2}; mac2=${brmac:3:2}; mac3=${brmac:6:2}
mac4=${brmac:9:2};  mac5=${brmac:12:2}; mac6=${brmac:15:2}
mac2="0x${mac2}"; mac2=$(printf %d ${mac2})
[ $mac2 -eq 255 ] && mac2=0 || mac2=$((mac2+1))
mac2=$(printf %02X ${mac2})
rai0_mac6="0x${mac6}"; rai0_mac6=$(printf %d ${rai0_mac6}); rai0_mac6=$((rai0_mac6+8))
[ $rai0_mac6 -gt 255 ] && rai0_mac6=$((rai0_mac6-255))
rai0_mac6=$(printf %02X ${rai0_mac6})
ra0_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${mac6}"
rai0_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${rai0_mac6}"
# v1.18: 访客 BSSID 按厂测 mbss 规则从各自射频基址 +1 派生 (逐机唯一, 替换 v1.4 的全机型固定样例MAC)
g6="0x${mac6}";    g6=$(printf %d $g6);    g6=$(( (g6+1)%256 ));    g6=$(printf %02X $g6)
gi6="0x${rai0_mac6}"; gi6=$(printf %d $gi6); gi6=$(( (gi6+1)%256 )); gi6=$(printf %02X $gi6)
ra1_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${g6}"
rai1_mac="${mac1}:${mac2}:${mac3}:${mac4}:${mac5}:${gi6}"
echo "brmac=$brmac ra0=$ra0_mac rai0=$rai0_mac ra1=$ra1_mac rai1=$rai1_mac"

BSSIDNUM=8
SN=4           # mt7992 stream num
# v1.6: SSID 体系 — conf 只存 SSID_BASE=<统一名称>, 派生规则:
#   独立双频: <名>-2.4G / <名>-5G
#   双频合一: <名> (两频同名)
#   访客:    独立名 GUEST_SSID, 未设则派生 <名>-Guest (v1.18 前的唯一行为)
# v1.18: 访客独立化 — GUEST_SSID(名称)/GUEST_BAND(频段 2g|5g|both)/GUEST_PASS(密码)三项独立;
#   both=双频同名双BSS(同名漫游)。
# v1.19: MLO — MLO=1 时两带主BSS(ra0/rai0)入同一 MLD 组(真 802.11be 多链路):
#   - 两带 dat 各写 MldGroup=1;0;0;0;0;0;0;0 (token=BSS序号, 1基组号; 访客BSS token=0
#     为 stock 实证的非成员形态; 全零表是 v1.15 事故形态, 绝不写)
#   - MldAddr 不写(全固件无人写, MLD地址驱动自派生=接口MAC+local bit);
#     ApcliMloDisable 不写(EasyMesh 回程专用)
#   - hostapd conf 无 MLO 键, 仅要求两链路同名同密(MLO=1 强制同名)
#   - 生效需冷启动: profile 在模块加载/接口open时读, MLD状态在 FW 锁存;
#     切换 MLO 后必须 reboot (恢复原语同)
# v1.13: 配置统一 — defaults(只读出厂) + settings(用户稀疏覆盖) source叠加;
#   过渡期回退旧 wifi.conf(迁移脚本生成 settings.conf 后不再命中)
CFG_D=$B/defaults.conf; CFG_S=$B/settings.conf; WIFI_CONF=$B/wifi.conf
SSID_BASE="LG6151M"
WPAPSK=""; AUTHM="WPA2PSK"
CH2G=6; CH5G=149; BW2G=20; BW5G=80; POWER=100; HIDDEN=0; GUEST=0; INONE=0; MLO=0
if [ -r "$CFG_D" ]; then . "$CFG_D"; fi          # v1.13: 只读出厂默认
if [ -r "$CFG_S" ]; then . "$CFG_S"; fi          # v1.13: 用户稀疏覆盖
if [ ! -r "$CFG_S" ] && [ -r "$WIFI_CONF" ]; then
    . "$WIFI_CONF"       # 过渡回退: 旧wifi.conf(迁移后不再命中)
fi
[ -n "$AUTH" ] && AUTHM="$AUTH"
# 兼容: 旧conf可能仍存 SSID2=/SSID5= (无 SSID_BASE 时从中提取)
if [ -z "$SSID_BASE" ]; then
    if [ -n "$SSID5" ]; then SSID_BASE=$(echo "$SSID5" | sed 's/-5[Gg]$//')
    elif [ -n "$SSID2" ]; then SSID_BASE=$(echo "$SSID2" | sed 's/-2\.4[Gg]$//;s/-5[Gg]$//')
    fi
fi
# 派生
if [ "$INONE" = 1 ] || [ "$MLO" = 1 ]; then
    SSID2="$SSID_BASE"; SSID5="$SSID_BASE"
else
    SSID2="${SSID_BASE}-2.4G"; SSID5="${SSID_BASE}-5G"
fi
GUEST_SSID="${GUEST_SSID:-${SSID_BASE}-Guest}"
GUEST_BAND="${GUEST_BAND:-5g}"
case "$GUEST_BAND" in 2g|5g|both) ;; *) GUEST_BAND=5g ;; esac
HT2=""
[ "$BW2G" = 40 ] && HT2="[HT40+]"
# v1.7: 自动信道 (CH2G/CH5G=0) — 上层显式扫描选道。
# hwifi 内部 ACS(AutoChannelSelect=1)在 hostapd 接管安全的架构下从未验证可用,
# 改为拉起 apcli0/apclii0 扫描(与 GUI wifiscan 同配方), 对候选道按
# 线性功率(mW)和评分取最小: 2.4G 邻道±4重叠+经典道(1/6/11)偏好;
# 5G 80M按整组(36-48/149-161), 20/40M按±(bw/40+... )邻道。
# 结果落 /tmp/wifi_autoch (RCH2G=/RCH5G=), GUI wifi_adv 端点回读展示。
rm -f /tmp/wifi_autoch; RCH2G=""; RCH5G=""
if [ "$CH2G" = 0 ] || [ "$CH5G" = 0 ]; then
    echo "== auto-channel: scan for best channel (CH2G=$CH2G CH5G=$CH5G) =="
    ifconfig apcli0 up 2>/dev/null; ifconfig apclii0 up 2>/dev/null; sleep 3
    ASCAN=$(iw apcli0 scan 2>/dev/null; iw apclii0 scan 2>/dev/null)
    ifconfig apcli0 down 2>/dev/null; ifconfig apclii0 down 2>/dev/null
    echo "$ASCAN" | awk -v want2="$CH2G" -v want5="$CH5G" -v bw5="$BW5G" '
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
                for (c = 1; c <= 13; c++) {
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
        }
    ' > /tmp/wifi_autoch
    [ -s /tmp/wifi_autoch ] && . /tmp/wifi_autoch
    [ -n "$RCH2G" ] && [ "$CH2G" = 0 ] && CH2G=$RCH2G
    [ -n "$RCH5G" ] && [ "$CH5G" = 0 ] && CH5G=$RCH5G
    echo "== auto-channel resolved: 2.4G=$CH2G 5G=$CH5G ($(tr '\n' ' ' < /tmp/wifi_autoch 2>/dev/null))"
    # 兜底: awk全空输出时退回安全默认, 绝不让 Channel=0 进 hwifi/hostapd
    case "$CH2G" in ''|0) CH2G=6 ;; esac
    case "$CH5G" in ''|0) CH5G=149 ;; esac
fi
# v1.4/v1.9: 5G 中心频点映射(带宽->vht_oper_centr_freq_seg0_idx)
# 160MHz: 仅 36-64 连续块可行(含DFS 52-64, hostapd 开 D 段+CAC), seg0=50
case "$BW5G" in
    20)  VHTW=0; SEG=0 ;;
    40)  VHTW=0; case "$CH5G" in 36|40) SEG=38;; 44|48) SEG=46;; 149|153) SEG=151;; 157|161) SEG=159;; *) SEG=151;; esac ;;
    160) VHTW=2; SEG=50 ;;
    *)   VHTW=1; case "$CH5G" in 3[6-9]|4[0-8]) SEG=42;; 5[2-9]|6[0-4]) SEG=58;; 10[0-9]|11[0-2]) SEG=106;; 11[6-9]|12[0-8]) SEG=122;; *) SEG=155;; esac ;;
esac
# 160 强制低块信道(hwifi dat Channel 须在 36-64 内, 否则整块不连续)
[ "$BW5G" = 160 ] && case "$CH5G" in 3[6-9]|4[0-9]|5[0-9]|6[0-4]) ;; *) CH5G=36 ;; esac
# 有密码->WPA; 无密码->保持开放(过渡期兼容, GUI 永远写密码)
if [ -n "$WPAPSK" ]; then
    AUTH1="$AUTHM"; ENC1="AES"; PSK1="WPAPSK1=$WPAPSK"
    REKEY1="TIME"
else
    AUTH1="OPEN"; ENC1="NONE"; PSK1=""; REKEY1="DISABLE"
fi

# v1.10: hwifi dat 带宽语义(逆向 wifimgr be_init_wlan_apcfg_file 实证):
#   VHT_BW: 0=20/40, 1=80, 2=160
#   EHT_ApBw: 0=20, 1=20/40, 2=80, 3=160  (与 VHT_BW 错位一档!)
#   驱动最终带宽 = min(VHT派生, EHT派生) — 只设 VHT_BW=2 而 EHT=2 时被钳 80。
#   dat 关键字是 EHT_ApBw(非 EHT_BW); 160 需 DFS 段信道(52-64)配合 hostapd CAC。
VHTBW_DAT=0; EHTAPBW_DAT=1
[ "$BW5G" = 40 ]  && { VHTBW_DAT=0; EHTAPBW_DAT=1; }
[ "$BW5G" = 80 ]  && { VHTBW_DAT=1; EHTAPBW_DAT=2; }
[ "$BW5G" = 160 ] && { VHTBW_DAT=2; EHTAPBW_DAT=3; }

# v1.19: MLO 组表 — token按BSS序号: BSS1(主)入组1。MLO=0 时键整体缺失(键缺失=
#   驱动不走MLD分支, 最安全形态; 全零表=v1.15 事故形态绝对禁止)。
#   MLO=1 时 hap 两链路同名(上方派生已强制)。
# v1.21(E4): 访客BSS显式静态单链路组(2.4G访客=17, 5G访客=18) — E1/E2实证访客
#   BSS动态创建时其mlo-info查询会扰动主组(rai0被重定向进临时组18), E3实证无访客
#   时主组纯净。驱动本就给非成员BSS分配17+临时组, 静态化=消除创建时竞态。
GB2=0; GB5=0
if [ "$GUEST" = 1 ] && [ -n "$GUEST_PASS" ]; then
    case "$GUEST_BAND" in
        2g)   GB2=1 ;;
        5g)   GB5=1 ;;
        both) GB2=1; GB5=1 ;;
    esac
fi
MLDLINE=""; MLDLINE5=""
if [ "$MLO" = 1 ]; then
    _T2="1;0;0;0;0;0;0;0"; _T5="1;0;0;0;0;0;0;0"
    [ "$GB2" = 1 ] && _T2="1;17;0;0;0;0;0;0"
    [ "$GB5" = 1 ] && _T5="1;18;0;0;0;0;0;0"
    MLDLINE="MldGroup=$_T2"; MLDLINE5="MldGroup=$_T5"
fi

# ---- /var/wlan/apcfg (2G band0) : factory template, mt7992 values ----
cat > /var/wlan/apcfg <<EOF2G
Default
CountryCode=CN
CountryRegion=1
CountryRegionABand=0
BssidNum=${BSSIDNUM}
DBDC_MODE=1
MacAddress=${ra0_mac}
${MLDLINE}
SSID1=${SSID2}
SSID2=fh_v3_ssid2
SSID3=fh_v3_ssid3
SSID4=fh_v3_ssid4
SSID5=fh_v3_ssid5
SSID6=fh_v3_ssid6
SSID7=fh_v3_ssid7
SSID8=fh_v3_ssid8
EnableSSID=1;0;0;0;0;0;0;0
HideSSID=${HIDDEN};0;0;0;0;0;0;0
AuthMode=${AUTH1};OPEN;OPEN;OPEN;OPEN;OPEN;OPEN;OPEN
EncrypType=${ENC1};NONE;NONE;NONE;NONE;NONE;NONE;NONE
${PSK1}
WmmCapable=1;1;1;1;1;1;1;1
Channel=${CH2G}
WirelessMode=22
PMFMFPC=0
PMFMFPR=0
PMFSHA256=0
HT_BW=0
HT_BSSCoexistence=1
HT_EXTCHA=0
VHT_BW=0
HT_GI=1
HT_STBC=1
HT_LDPC=1
VHT_LDPC=1
VHT_STBC=1
HT_TxStream=${SN}
HT_RxStream=${SN}
HT_MCS=33;33;33;33;33;33;33;33
HT_AutoBA=1
HT_MpduDensity=5
HT_AMSDU=1
HT_BAWinSize=256
TxPower=${POWER}
TxPreamble=1
BasicRate=15
BeaconPeriod=100
DtimPeriod=1
RTSThreshold=2347
FragThreshold=2346
IgmpSnEnable=1;1;1;1;1;1;1;1
MbssMaxStaNum=32;32;32;32;32;32;32;32
NoForwarding=0;0;0;0
NoForwardingBTNBSSID=0
APSDCapable=0
APAifsn=3;7;1;1
APCwmin=4;4;3;2
APCwmax=6;10;4;3
APTxop=0;0;94;47
BSSAifsn=3;7;2;2
BSSCwmin=4;4;3;2
BSSCwmax=10;10;4;3
BSSTxop=0;0;94;47
AckPolicy=0;0;0;0
ShortSlot=1
TxBurst=1
PktAggregate=0
IEEE8021X=0;0;0;0
IEEE80211H=1
AutoChannelSelect=0
AutoChannelSkipList=
WdsEnable=0
WscConfMode=0;0;0;0
WscConfStatus=2;1;1;1
WscV2Support=0;0;0;0
RekeyMethod=${REKEY1};TIME;TIME;TIME;TIME;TIME;TIME;TIME
RekeyInterval=3600;0;0;0;0;0;0;0
DefaultKeyID=1;1;1;1;1;1;1;1
EAPifname=br-lan
PreAuthifname=br-lan
EfuseBufferMode=1
WirelessEvent=1
VOW_Airtime_Fairness_En=1
VOW_RX_En=1
RED_Enable=1
MuOfdmaDlEnable=1
MuOfdmaUlEnable=1
MuMimoDlEnable=1
MuMimoUlEnable=1
TWTSupport=1
SREnable=1
SRMode=0
SRSDEnable=1
MboSupport=1
FtSupport=0
FtOtd=0
EDCCAEnable=1
CP_SUPPORT=2
AMSDU_NUM=4
TxCmdMode=1
StationKeepAlive=0
ReloadFlag=1
RRMEnable=1
ProbeHideSSID=1
PERCENTAGEenable=0
RROSupport=1
HT_AutoBA=0
BAWinSize=64
EOF2G

# ---- /var/wlan/apcfg_5 (5G band1) ----
cat > /var/wlan/apcfg_5 <<EOF5G
Default
CountryCode=CN
CountryRegion=1
CountryRegionABand=0
BssidNum=${BSSIDNUM}
DBDC_MODE=1
MacAddress=${rai0_mac}
${MLDLINE5}
SSID1=${SSID5}
SSID2=fh_v3_ssid2_5G
SSID3=fh_v3_ssid3_5G
SSID4=fh_v3_ssid4_5G
SSID5=fh_v3_ssid5_5G
SSID6=fh_v3_ssid6_5G
SSID7=fh_v3_ssid7_5G
SSID8=fh_v3_ssid8_5G
EnableSSID=1;0;0;0;0;0;0;0
HideSSID=${HIDDEN};0;0;0;0;0;0;0
AuthMode=${AUTH1};OPEN;OPEN;OPEN;OPEN;OPEN;OPEN;OPEN
EncrypType=${ENC1};NONE;NONE;NONE;NONE;NONE;NONE;NONE
${PSK1}
WmmCapable=1;1;1;1;1;1;1;1
Channel=${CH5G}
WirelessMode=23
PMFMFPC=0
PMFMFPR=0
PMFSHA256=0
HT_BW=1
VHT_BW=${VHTBW_DAT}
EHT_ApBw=${EHTAPBW_DAT}
HT_EXTCHA=1
VHT_SGI=1
HT_GI=1
HT_STBC=1
HT_LDPC=1
VHT_LDPC=1
VHT_STBC=1
HT_TxStream=${SN}
HT_RxStream=${SN}
HT_MCS=33;33;33;33
HT_AutoBA=1
HT_MpduDensity=5
HT_AMSDU=1
HT_BAWinSize=256
TxPower=${POWER}
TxPreamble=0
BasicRate=15
BeaconPeriod=100
DtimPeriod=1
RTSThreshold=2347
FragThreshold=2346
IgmpSnEnable=1;1;1;1;1;1;1;1
MbssMaxStaNum=32;32;32;32;32;32;32;32
NoForwarding=0;0;0;0
NoForwardingBTNBSSID=0
APSDCapable=0
APAifsn=3;7;1;1
APCwmin=4;4;3;2
APCwmax=6;10;4;3
APTxop=0;0;94;47
BSSAifsn=3;7;2;2
BSSCwmin=4;4;3;2
BSSCwmax=10;10;4;3
BSSTxop=0;0;94;47
AckPolicy=0;0;0;0
ShortSlot=1
TxBurst=1
PktAggregate=0
IEEE8021X=0;0;0;0
IEEE80211H=1
AutoChannelSelect=0
AutoChannelSkipList=
WdsEnable=0
WscConfMode=0;0;0;0
WscConfStatus=2;1;1;1
WscV2Support=0;0;0;0
RekeyMethod=${REKEY1};TIME;TIME;TIME;TIME;TIME;TIME;TIME
RekeyInterval=3600;0;0;0;0;0;0;0
DefaultKeyID=1;1;1;1;1;1;1;1
EAPifname=br-lan
PreAuthifname=br-lan
EfuseBufferMode=1
WirelessEvent=1
VOW_Airtime_Fairness_En=1
VOW_RX_En=1
RED_Enable=1
MuOfdmaDlEnable=1
MuOfdmaUlEnable=1
MuMimoDlEnable=1
MuMimoUlEnable=1
TWTSupport=1
SREnable=1
SRMode=0
SRSDEnable=1
MboSupport=1
FtSupport=0
FtOtd=0
EDCCAEnable=1
CP_SUPPORT=2
AMSDU_NUM=4
TxCmdMode=1
StationKeepAlive=0
RadioON=1
LoadCodeMethod=0
ReloadFlag=1
ProbeHideSSID=1
PERCENTAGEenable=0
RROSupport=1
HT_AutoBA=0
BAWinSize=64
EOF5G

echo "== profiles written:"
ls -la /var/wlan/

# ---- activate (factory sequence) ----
# v1.3: 安全面交 hostapd — 原厂 hwifi dat 档案的内部 WPA 引擎在 MLD 组网下
# 不发 EAPOL M1(非MLO客户端5s超时, assoc成功但4次握手死); 原厂魔改 hostapd
# 的 wpa_passphrase 会过 libfhcrypto(明文=乱码), 只吃 wpa_psk 原始 PMK,
# 由自带 wpapmk 工具现算(PBKDF2-SHA1 4096)。apcfg 只管射频参数, BSS 内部
# 保持 OPEN(被 hostapd 接管后无 OPEN 广播)。hostapd 起不来则射频关闭——
# 绝不回退开放模式。
# v1.20(E2): MLO=1 时跳过预启动 ifconfig up 与 hostapd 前的 down — E1实证双次AP启动
# 会让第二链路(rai0)在 hostapd 阶段无法回组1而落入临时单链路组18(dmesg:
# rai0 eht_ap_mld_create grp(18)(ML:0))。hostapd 的 nl80211 ADD_IF 本身完成
# profile 应用+AP启动, 作为 MLO 下唯一一次 AP start。非 MLO 维持工厂配方双次序列。
if [ "$MLO" != 1 ]; then
    ifconfig ra0 up
    ifconfig rai0 up
fi
sleep 3

echo "== bridge into br-lan"
brctl addif br-lan ra0 2>&1
brctl addif br-lan rai0 2>&1

# ---- netifd guard: FH netifd (if it ever registers with ubus) rebuilds br-lan
# from stock uci and strips wifi ports + changes LAN IP. v3 owns networking. ----
pkill -f 'sbin/netifd' 2>/dev/null && echo "netifd killed (v3 autonomy guard)"
sleep 1
brctl addif br-lan ra0 2>/dev/null
brctl addif br-lan rai0 2>/dev/null
ip link set br-lan up

# ---- v1.3: hostapd 安全面 ----
WIFI_ERR=0
if [ -n "$WPAPSK" ] && [ -x $B/wpapmk ]; then
    # 清理本脚本旧实例(精确匹配 -B 形态, 不动 /usr/sbin/hostapd -g 全局桩)
    for p in $(ps | grep "[h]ostapd -B" | awk '{print $1}'); do kill $p 2>/dev/null; done
    sleep 1
    PMK2=$($B/wpapmk "$SSID2" "$WPAPSK") || WIFI_ERR=1
    PMK5=$($B/wpapmk "$SSID5" "$WPAPSK") || WIFI_ERR=1
    if [ $WIFI_ERR -eq 0 ]; then
        cat > /var/wlan/hap_2g.conf <<H2G
use_driver_iface_addr=1
interface=ra0
bridge=br-lan
driver=nl80211
ssid=${SSID2}
hw_mode=g
channel=${CH2G}
ieee80211n=1
ht_capab=${HT2}
ignore_broadcast_ssid=${HIDDEN}
auth_algs=1
wpa=2
wpa_psk=${PMK2}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=0
ctrl_interface=/var/run/hostapd
H2G
        cat > /var/wlan/hap_5g.conf <<H5G
use_driver_iface_addr=1
interface=rai0
bridge=br-lan
driver=nl80211
ssid=${SSID5}
hw_mode=a
channel=${CH5G}
ieee80211n=1
ieee80211ac=1
ieee80211ax=1
ht_capab=[HT40+]
vht_oper_chwidth=${VHTW}
vht_oper_centr_freq_seg0_idx=${SEG}
ignore_broadcast_ssid=${HIDDEN}
auth_algs=1
wpa=2
wpa_psk=${PMK5}
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=0
ctrl_interface=/var/run/hostapd
H5G
        # v1.9: 160MHz 含 DFS 信道(52-64) — 开 802.11d/h 让 hostapd 做 CAC;
        # AX/EHT 模式下 HE 操作元素看 he_oper_* (只设 vht_oper 实测仍 80MHz)
        [ "$BW5G" = 160 ] && cat >> /var/wlan/hap_5g.conf <<'HDFS'
ieee80211d=1
ieee80211h=1
country_code=CN
he_oper_chwidth=2
he_oper_centr_freq_seg0_idx=50
HDFS
        # v1.18: 访客网络 — 独立名称/频段/密码; hostapd 第二BSS(动态创建), 客户端隔离。
        # 频段: 2g->ra1(2.4G) / 5g->rai1(5G, v1.4默认) / both->双频同名双BSS(漫游)。
        # 隔离的强制面(hostapd ap_isolate + guest_fw.sh ebtables)在 hostapd 拉起后统一施加。
        # (GB2/GB5 计算已前移至 dat 生成段 — v1.21 MLO 组表需要)
        guest_bss() {  # guest_bss <conf> <ifname> <bssid> — 追加访客BSS段(须在各hap conf写完后)
            cat >> "$1" <<HGUEST
bss=$2
bssid=$3
ssid=${GUEST_SSID}
wpa=2
wpa_psk=$($B/wpapmk "${GUEST_SSID}" "$GUEST_PASS")
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=0
ap_isolate=1
HGUEST
        }
        [ "$GB2" = 1 ] && guest_bss /var/wlan/hap_2g.conf ra1  "$ra1_mac"
        [ "$GB5" = 1 ] && guest_bss /var/wlan/hap_5g.conf rai1 "$rai1_mac"
        # v1.20(E2): MLO 下不做 down/up 包夹(见函数头注), hostapd 即首次也是唯一 AP 启动
        if [ "$MLO" != 1 ]; then
            ifconfig ra0 down; ifconfig rai0 down; sleep 1
        fi
        # ---- v1.16 F3: 单进程多配置(stock同款拓扑) ----
        # RE实证根因: 双 hostapd -B 的 START_AP 重叠落入 bss_mngr_con_dev_reg
        # 无锁窗口, bss_idx<->FW 映射错乱致 rai0 信标槽被 rai1 内容占用。
        # 单进程单事件循环 => BeaconAdd/Set 天然串行, 竞态窗口用户态不可达。
        # 失败链: 摘guest(两频各自)重试单进程 -> 回退F4双实例(v1.14串行等待)。
        # (v1.15教训: apcfg MldGroup/ApcliMloDisable键被驱动开机锁存后
        #  rai0信标永久重定向进Multiple-BSSID模式, 剥离文件不回退——勿再写)
        strip_guest() {  # v1.18: 泛化 — 从两个 hap conf 摘除访客BSS段(bss=起至EOF)
            for f in /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf; do
                [ -r "$f" ] && grep -q "^bss=" "$f" && sed -i "/^bss=/,\$d" "$f"
            done
        }
        has_guest() { grep -q "^bss=" /var/wlan/hap_2g.conf 2>/dev/null || grep -q "^bss=" /var/wlan/hap_5g.conf 2>/dev/null; }
        HSTART=0
        LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf && HSTART=1
        if [ "$HSTART" = 0 ] && has_guest; then
            echo "== F3 failed, retry single-process without guest =="
            strip_guest
            LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf && HSTART=1
        fi
        if [ "$HSTART" = 0 ]; then
            echo "== fallback: F4 dual-instance serialized =="
            LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib hostapd -B -i ra0  /var/wlan/hap_2g.conf || WIFI_ERR=1
            # v1.14 F4: -B 在接口配置完成前就 daemonize 返回, 显式等 ENABLED
            _sw=0
            while [ $_sw -lt 20 ]; do
                hostapd_cli -i ra0 status 2>/dev/null | grep -q state=ENABLED && break
                sleep 0.5; _sw=$((_sw+1))
            done
            if ! LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib hostapd -B -i rai0 /var/wlan/hap_5g.conf; then
                if has_guest; then
                    echo "== guest bss failed, retry without guest =="
                    strip_guest
                    LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib hostapd -B -i rai0 /var/wlan/hap_5g.conf || WIFI_ERR=1
                else
                    WIFI_ERR=1
                fi
            fi
        fi
        [ "$MLO" = 1 ] || { ifconfig ra0 up; ifconfig rai0 up; }   # v1.20: MLO下hostapd已拉起, 幂等up也省
        # ---- v1.13 F2: 信标重装订(止血MLD注册竞态) ----
        # RE实证: 双hostapd -B的START_AP重叠落入 bss_mngr_con_dev_reg 无锁窗口,
        # 固件按错映射装订信标槽(rai0槽被rai1内容占用)。mwctl no_bcn 0 =
        # BcnStopHandle->UpdateBeaconHandler(reason5+6) 全量重装信标模板,
        # 与固件超时自愈同族原语, 幂等。等5s让动态BSS(ra1/rai1)创建先完成。
        sleep 5
        for vif in $(iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E '^ra'); do
            mwctl dev $vif set no_bcn 0 >/dev/null 2>&1
        done
        # ---- v1.22: 访客iface显式入桥 ----
        # 实证: hostapd 创建的动态BSS(ra1/rai1)不会自动加入 br-lan(brctl show 缺席),
        # 其帧以 indev=无IP接口 被本地收包后丢弃, dnsmasq 收不到 DISCOVER, 手机卡
        # "获取IP"(tcpdump: 全网只有入向DISCOVER无OFFER)。MLO 与否同样缺失。幂等。
        for gif in ra1 rai1; do
            [ -d /sys/class/net/$gif ] && brctl addif br-lan $gif 2>/dev/null
        done
        # ---- v1.18: 访客隔离防火墙(原厂 wifiguest.sh 配方复刻) 幂等同步 ----
        # 检测现存访客iface(ra1/rai1)施加ebtables/iptables隔离; 访客关闭则清链
        [ -x $B/guest_fw.sh ] && $B/guest_fw.sh sync
        # v1.22: MLD 建立证据快照 — ccmni 每秒多条日志会把 boot 期 MLD 行挤出
        # 内核环形缓冲区, selftest 改读此快照(dmesg 作回退)
        dmesg | grep -E 'Create AP MLD|join mld_grp|already affiliated' > /tmp/mld_boot.log 2>/dev/null
    fi
    if [ $WIFI_ERR -ne 0 ]; then
        echo "== FATAL: hostapd WPA setup failed — radios DOWN (no open fallback)"
        ifconfig ra0 down; ifconfig rai0 down
    fi
fi

echo "== state after up:"
iw dev 2>&1 | grep -E "Interface|channel" | head -8
ps | grep "[h]ostapd" | head -3
echo "== wifi_up done $(date)"
