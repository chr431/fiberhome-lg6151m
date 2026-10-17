#!/bin/sh
# wan_agg_lib.sh v1.0 — 聚合引擎落地层 + conf 管理 (库; 被 wan_agg.sh source, 不独立运行)
# v1.0 (2026-10-17 架构轮): 自 wan_agg v2.34 拆出 — 本库只含"读全局状态 -> 幂等写内核"
#   的映射层与 agg.conf/钉死表管理, 不含决策逻辑(探活/FSM/主路推导留在 wan_agg)。
#   单进程 source = 单写方纪律不变(所有内核写方仍在 wan_agg 进程内)。
#   顺带消除真实重复: MODE 白名单与 W1_PCT 钳位校验原在启动/迁移/热载三处各写一份。
#
# ===== 引擎历史(自 wan_agg 迁入, 证据注释原样保留) =====
# 原厂架构 (subagent RE 2026-10-04, 证据: protocolmgr@0x5e850, wancc@0x9688a,
# mobilenetwork@0x2f191, quecadp.ko netfilter hook):
#   内核:  fhdrv_net_quecadp 按五元组 hash%100 < w1_pct 选 WAN, ct->mark 粘性
#   路由:  wancc 式 "ip rule add fwmark 0x4000000/0xfc000000 table N"
#   探活:  mobilenetwork 式 ping -I <if> -c1 -W3 -s1 <dst> | grep ttl
# v1.1: 实测 /proc/multi_wan/{mode,weight,mac_config} 写入全部失败(仅 debug 可写,
#   0644/root 无权限问题 -> 该驱动版 proc 写处理器残废, 真通道=/dev/fhdrv_net_dev
#   ioctl cmd=5)。故双引擎:
#   ENGINE=vendor: ioctl(multiwan_ctl+fhstub) 成功且回读 mode=1 -> 用内核模块分流(最优)
#   ENGINE=iptables: mangle WANAGG 链源端口区间分流+CONNMARK 粘性(语义等价) —— 实际主力
# v2.17: 免插件配方 — 本机 iptables 内建 tcp/udp/mark/connmark 匹配, 而
#   libxt_statistic.so 缺 libxtables.so.12 不可用, libxt_mac 根本不存在; 分流改
#   源端口区间确定性(v6 同款), 钉死改源 IP(pin MAC 经邻居表解析)。
# v2.4: v6 自建分流引擎(RE方案b落地) — 对照实验实锤: 模块对 v4 完美分流(16/16)
#   但对 v6 全标 wan2(76/76, 常数哈希, 运行时缺陷; 静态逆向两族同码看不出)。
#   低8位标记体系(RE共处配方): W1=0x65 W2=0x66 mask 0xff —— 模块只写高6位,互不干扰;
#   本链 mangle(-150) 后手覆盖模块当包 skb 标记, CONNMARK 低8位存取做粘性。
# v2.6 规则分层修正 + 真相更正(2026-10-05 终局判别实验):
#   [更正] 模块v6引擎完全正常(哈希%100读权重; 摘钉后100/0→4/4全WAN1实证)。
#   早前"v6常数哈希缺陷"结论系MAC钉死自污染 — 钉死旁路哈希(v4/v6同样),
#   而v6测试全用被钉PC发流。用户当日判断"原厂可能无辜"最终完全成立。
#   [缺陷] 同优先级下高位v6规则先装先匹配 → 模块判WAN1的目的绕过低8位
#   源端口分流(半数目的分流失效) → 低8位规则降优先级90/91, 双活时自建
#   引擎全权路由; 死侧摘除后回落模块高位规则(其failover翻转已实证)。
#   另: conntrack二进制在v3上relocation损坏, 所有 conntrack -D 从未生效 —
#   已移除死代码, 断而必破完全由fwmark摘除承担。
#
# WAN1 = 5G  ccmni (vendor 语义 WANDevice.1=nb5g)  mark 0x4000000
# WAN2 = 有线宽带 eth0 DHCP (静态IP形态见 uplink.conf) mark 0x8000000
case "$0" in *wan_agg_lib.sh) echo "wan_agg_lib: library, not executable" >&2; exit 2 ;; esac

LAN_NET=192.168.9.0/24
W1_MARK=0x4000000; W2_MARK=0x8000000; W_MASK=0xfc000000
T1=100; T2=200
# v2.30(A1): 蜂窝侧 main 表默认路由只作"探活可达"用途(ping -I 需该表有路),
#   metric 必须劣于家宽备用默认(200)。旧值 50 插在家宽主默认(0)与备用(200)
#   之间 —— 主默认被外力冲刷后, 未打标流量会静默改走蜂窝且长期滞留(实测复核)。
W1_PRB_METRIC=250
# v2.31: 未打标主路的 v6 显式条目 metric —— 优于两侧 RA 默认(蜂窝 RA 1024 /
#   家宽 RA 2048), 使 v6 与 v4 走同一主路; 对侧的 RA 默认留作自动兜底。
V6_PRI_METRIC=50
# v2.4: v6 低8位标记(模块只写高6位, 互不干扰)
M6_LOW1=0x65; M6_LOW2=0x66
LOG=/tmp/wan_agg.log
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }

# v2.18: 五模式(MODE 键, 对齐原厂语义) —
#   weight    按权重分流 (W1_PCT 5..95; pmode 0)
#   cell_prio 蜂窝优先   (5G 主力, 家宽待命 failover; pmode 1)
#   eth_prio  以太优先   (家宽主力, 5G 待命 failover; pmode 2)
#   cell_only 仅蜂窝     (5G 全量, 家宽不参战无failover; pmode 4)
#   eth_only  仅以太     (家宽全量, 5G 不参战无failover; pmode 3)
# legacy 派生(无 MODE 键): 100->cell_prio; 0->eth_prio; 否则 weight
pmode_of_mode() {
    case "$1" in
        weight)    echo 0 ;;
        cell_prio) echo 1 ;;
        eth_prio)  echo 2 ;;
        eth_only)  echo 3 ;;
        cell_only) echo 4 ;;
        *)         echo 0 ;;
    esac
}

# ---------- agg.conf / 钉死表管理 ----------
AGG_CONF=/data/gw/agg.conf
# v2.34: 钉死表**缺省播种** —— 活文件 /data/gw/agg_pins.conf 是设备侧自管(不入库,
#   含个人 MAC, EXTRA_KEEP 不参与部署/体检比对), 但"文件缺失"会让重放循环报错且
#   机制静默失效(weight 模式下该报错每环循重复)。故从随版本部署的只读基线
#   agg_pins.default 播种: **缺省才写**, 已有钉死永不覆盖(与 uplink.conf 同法)。
# v2.18: agg.conf 无文件时从 defaults 播种; 旧格式(无 MODE 键)迁移到五模式格式。
agg_conf_seed() {
    [ -r /data/gw/agg_pins.conf ] || cp /data/gw/agg_pins.default /data/gw/agg_pins.conf 2>/dev/null
    if [ ! -r $AGG_CONF ] && [ -r /data/gw/defaults.conf ]; then
        DM=$(grep -m1 '^AGG_MODE=' /data/gw/defaults.conf 2>/dev/null | cut -d= -f2)
        DW=$(grep -m1 '^AGG_W1_PCT=' /data/gw/defaults.conf 2>/dev/null | cut -d= -f2)
        case "$DM" in weight|cell_prio|eth_prio|cell_only|eth_only) ;; *) DM=weight ;; esac
        case "$DW" in ''|*[!0-9]*) DW=30 ;; esac
        [ "$DW" -ge 5 ] && [ "$DW" -le 95 ] || DW=30
        printf 'MODE=%s
W1_PCT=%s
W2_PCT=%s
ENABLE=1
' "$DM" "$DW" "$((100-DW))" > $AGG_CONF
        log "agg.conf seeded from defaults: MODE=$DM W1=$DW"
    fi
    if [ -r $AGG_CONF ] && ! grep -q '^MODE=' $AGG_CONF; then
        . $AGG_CONF
        case "$W1_PCT" in 100) MODE=cell_prio ;; 0) MODE=eth_prio ;; *) MODE=weight ;; esac
        [ "$MODE" = weight ] || W1_PCT=30
        printf 'MODE=%s
W1_PCT=%s
W2_PCT=%s
ENABLE=1
' "$MODE" "$W1_PCT" "$((100-W1_PCT))" > $AGG_CONF
        log "agg.conf migrated to v2.18 format: MODE=$MODE W1=$W1_PCT"
    fi
}
# source agg.conf 并规范化到全局(启动与热载共用; 原三处重复校验收敛于此)。
#   $1 = W1_PCT 兜底值(缺省=当前值): 启动传 30(与旧启动分支一致), 热载不传=保现值。
#   MODE 非法 -> 保持当前; W1_PCT 非法/越界(5..95) -> 兜底值。
agg_conf_load() {
    _fb=${1:-${W1_PCT:-30}}; _om=${MODE:-weight}
    [ -r $AGG_CONF ] && . $AGG_CONF
    case "$MODE" in weight|cell_prio|eth_prio|cell_only|eth_only) ;; *) MODE=$_om ;; esac
    case "$W1_PCT" in ''|*[!0-9]*) W1_PCT=$_fb ;; esac
    [ "$W1_PCT" -ge 5 ] && [ "$W1_PCT" -le 95 ] || W1_PCT=$_fb
    W2_PCT=$((100 - W1_PCT))
    PMODE=$(pmode_of_mode "$MODE")
}

# v1.8: MAC 钉死表重放(内核模块状态不跨重启, 游戏PC等需开机重新钉)
pin_replay() {
    while read -r MAC OP; do
        case "$MAC" in \#*|"") continue;; esac
        LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib LD_PRELOAD=/data/gw/fhstub.so \
            /data/gw/multiwan_ctl mac "$MAC" "$OP" >>$LOG 2>&1
        log "pin: $MAC op=$OP rc=$?"
    done < /data/gw/agg_pins.conf
}

# v3.1: 活跃 ccmni 选口(探活实证) — 多口并存时旧 PDN 常留僵尸口(有 IP 无数据),
#   按"第一个有 IP"取会选到它(GUI 流量/状态、selftest 护栏都曾因此假红/谎报)。
#   $1=ccmni 名输出; 全部不通时回退第一候选(由 FSM 判死转移)。
#   纯 ICMP 单目标×3(不做 TCP 兜底, 保调用方节奏)。
cell_iface_pick() {
    _cand=$(ip -o -4 addr show 2>/dev/null | grep ccmni | grep 'inet ' | awk '{print $2}')
    for _c in $W1_IF $_cand; do
        [ -n "$_c" ] || continue
        for _t in 180.76.76.76 119.29.29.29 8.8.8.8; do
            ping -4 -I $_c -c1 -W1 -s1 $_t 2>/dev/null | grep -q ttl && { echo $_c; return 0; }
        done
    done
    echo $_cand | awk '{print $1}'
}

# ---------- data plane ----------
dp_setup() {
    # 双表: T1 恒走 5G; T2 走家宽 gw (拿到租约后由 wan_eth 侧刷新)
    ip route replace default dev $W1_IF table $T1 2>/dev/null
    ip rule del fwmark $W1_MARK/$W_MASK table $T1 2>/dev/null
    ip rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
    ip rule del fwmark $W2_MARK/$W_MASK table $T2 2>/dev/null
    ip rule add fwmark $W2_MARK/$W_MASK table $T2 priority 102 2>/dev/null
    # 旧 wan_policy2 规则退役 (源地址策略=全量单路, 与聚合互斥)
    ip rule del priority 101 from $LAN_NET 2>/dev/null
    ip rule del priority 101 from 192.168.8.0/24 2>/dev/null
    # v2.0: v6 双栈策略路由 — quecadp 内核模块双栈打标, 规则镜像 v4
    ip -6 rule del fwmark $W1_MARK/$W_MASK table $T1 2>/dev/null
    ip -6 rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101
    ip -6 rule del fwmark $W2_MARK/$W_MASK table $T2 2>/dev/null
    ip -6 rule add fwmark $W2_MARK/$W_MASK table $T2 priority 102
    ip -6 rule del priority 50 2>/dev/null
    ip -6 rule add to fd42:9ac1:7e50::/64 lookup main priority 50   # 入向LAN护盾(v6)
    ip -6 route replace default dev $W1_IF table $T1 2>/dev/null
    log "dp: v4+v6 rules+t1 ready"
}

fw6_rules() {
    ip -6 rule del fwmark $W1_MARK/$W_MASK table $T1 2>/dev/null
    ip -6 rule del fwmark $W2_MARK/$W_MASK table $T2 2>/dev/null
    # v2.6: 低8位规则优先级90/91 — 先于高位规则(101/102)匹配, 双活时自建
    # 引擎全权路由(否则模块判WAN1的目的绕过源端口分流)
    ip -6 rule del fwmark $M6_LOW1/0xff table $T1 2>/dev/null
    ip -6 rule add fwmark $M6_LOW1/0xff table $T1 priority 90
    ip -6 rule del fwmark $M6_LOW2/0xff table $T2 2>/dev/null
    ip -6 rule add fwmark $M6_LOW2/0xff table $T2 priority 91
}
fw6_setup() {  # $1=w2_on(1=双路分流, 0=家宽死全走5G); 5G死时用 fw6_setup_alive2
    ip6tables -t mangle -D PREROUTING -i br-lan -j WANAGG6 2>/dev/null
    ip6tables -t mangle -F WANAGG6 2>/dev/null
    ip6tables -t mangle -X WANAGG6 2>/dev/null
    ip6tables -t mangle -N WANAGG6
    ip6tables -t mangle -A WANAGG6 -m conntrack --ctstate ESTABLISHED,RELATED \
        -j CONNMARK --restore-mark --mask 0xff
    # v6 钉死家宽(与v4 cmd6钉死对齐): 从 agg_pins.conf 取所有 op=2 的 MAC
    # (v2.11: 原为单MAC硬编码; v2.12: 主备模式下跳过 — 待命侧不该收到任何流量)
    if [ "$PMODE" = 0 ]; then
        while read -r PIN_MAC PIN_OP; do
            case "$PIN_MAC" in "#"*|"") continue ;; esac
            [ "$PIN_OP" = "2" ] || continue
            ip6tables -t mangle -A WANAGG6 -m mac --mac-source "$PIN_MAC" \
                -j MARK --set-mark $M6_LOW2/0xff
        done < /data/gw/agg_pins.conf
    fi
    if [ "$1" = "0" ]; then
        # 家宽死: 全部新流 -> W1(5G)
        ip6tables -t mangle -A WANAGG6 -m conntrack --ctstate NEW \
            -j MARK --set-mark $M6_LOW1/0xff
    else
        # 双路: 源端口区间确定性分流(xt_statistic无ipv6; OS随机sport≈均匀)
        # v2.8: 全部规则加低8位==0守卫 — MARK覆盖语义下, 无守卫时①链尾catchall
        # 吞掉sport规则刚写的0x65 ②sport规则吞掉链头MAC钉死的0x66(v2.4起钉死
        # 实际失效, 只因Windows临时端口多落高端段与钉值同路而未被暴露)
        ip6tables -t mangle -A WANAGG6 -p tcp -m conntrack --ctstate NEW \
            -m mark --mark 0/0xff --sport 0:26213 -j MARK --set-mark $M6_LOW1/0xff
        ip6tables -t mangle -A WANAGG6 -p tcp -m conntrack --ctstate NEW \
            -m mark --mark 0/0xff --sport 26214:65535 -j MARK --set-mark $M6_LOW2/0xff
        ip6tables -t mangle -A WANAGG6 -p udp -m conntrack --ctstate NEW \
            -m mark --mark 0/0xff --sport 0:26213 -j MARK --set-mark $M6_LOW1/0xff
        ip6tables -t mangle -A WANAGG6 -p udp -m conntrack --ctstate NEW \
            -m mark --mark 0/0xff --sport 26214:65535 -j MARK --set-mark $M6_LOW2/0xff
        # v2.7: catchall 同守卫 — 只兜底未被上游规则标记的包
        ip6tables -t mangle -A WANAGG6 -m conntrack --ctstate NEW \
            -m mark --mark 0/0xff -j MARK --set-mark $M6_LOW2/0xff
    fi
    ip6tables -t mangle -A WANAGG6 -j CONNMARK --save-mark --mask 0xff
    ip6tables -t mangle -A PREROUTING -i br-lan -j WANAGG6
}
fw6_setup_alive2() {  # 5G死: 全部新流 -> W2(家宽)
    ip6tables -t mangle -D PREROUTING -i br-lan -j WANAGG6 2>/dev/null
    ip6tables -t mangle -F WANAGG6 2>/dev/null
    ip6tables -t mangle -X WANAGG6 2>/dev/null
    ip6tables -t mangle -N WANAGG6
    ip6tables -t mangle -A WANAGG6 -m conntrack --ctstate ESTABLISHED,RELATED \
        -j CONNMARK --restore-mark --mask 0xff
    ip6tables -t mangle -A WANAGG6 -m conntrack --ctstate NEW \
        -j MARK --set-mark $M6_LOW2/0xff
    ip6tables -t mangle -A WANAGG6 -j CONNMARK --save-mark --mask 0xff
    ip6tables -t mangle -A PREROUTING -i br-lan -j WANAGG6
}

kernel_apply() {  # $1=s1(5G) $2=s2(家宽) — vendor ioctl via multiwan_ctl+fhstub
    LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib LD_PRELOAD=/data/gw/fhstub.so \
        /data/gw/multiwan_ctl 1 $W1_PCT $W2_PCT $1 $2 >>$LOG 2>&1
    grep -q "Current mode: 1" /proc/multi_wan/mode 2>/dev/null
}

# iptables 引擎: WANAGG 链重建 (v2.17 免插件配方)
pin_ip() {  # $1=mac -> 当前IP(空=未解析)
    ip neigh | grep -i "$1" | awk '{print $1}' | grep -E '^[0-9.]+$' | head -1
}
fw_setup() {  # $1=w2_pct(家宽份额 0-100, 死侧归零后的有效值)
    iptables -t mangle -D PREROUTING -i br-lan -j WANAGG 2>/dev/null
    iptables -t mangle -F WANAGG 2>/dev/null
    iptables -t mangle -X WANAGG 2>/dev/null
    iptables -t mangle -N WANAGG
    # 已建流: 恢复 ct mark (粘性; ctmark 0 无害)
    iptables -t mangle -A WANAGG -m conntrack --ctstate ESTABLISHED,RELATED \
        -j CONNMARK --restore-mark --mask $W_MASK
    # 钉死(源IP; MAC->IP 邻居解析, 未上线则跳过留待下轮重建; 主备模式跳过)
    if [ "$PMODE" = 0 ]; then
        while read -r PIN_MAC PIN_OP; do
            case "$PIN_MAC" in "#"*|"") continue ;; esac
            if [ "$PIN_OP" = 1 ]; then PIN_MK=$W1_MARK; elif [ "$PIN_OP" = 2 ]; then PIN_MK=$W2_MARK; else continue; fi
            PIN_IP=$(pin_ip "$PIN_MAC")
            if [ -n "$PIN_IP" ]; then
                iptables -t mangle -A WANAGG -s "$PIN_IP" -j MARK --set-mark $PIN_MK/$W_MASK
                echo "$PIN_IP" > /tmp/pin_${PIN_MAC//:/}.ip
            else
                log "pin: $PIN_MAC 邻居未解析, 本轮跳过"
            fi
        done < /data/gw/agg_pins.conf
    fi
    # 新流: 源端口区间确定性分流(OS 临时端口近似均匀; 与 v6 引擎同款设计)
    if [ "$1" = "0" ]; then
        iptables -t mangle -A WANAGG -m conntrack --ctstate NEW -m mark --mark 0/$W_MASK \
            -j MARK --set-mark $W1_MARK/$W_MASK
    elif [ "$1" = "100" ]; then
        iptables -t mangle -A WANAGG -m conntrack --ctstate NEW -m mark --mark 0/$W_MASK \
            -j MARK --set-mark $W2_MARK/$W_MASK
    else
        CUT=$(( (65535 * $1) / 100 ))
        for PR in tcp udp; do
            iptables -t mangle -A WANAGG -p $PR -m conntrack --ctstate NEW -m mark --mark 0/$W_MASK \
                --sport 0:$CUT -j MARK --set-mark $W2_MARK/$W_MASK
            iptables -t mangle -A WANAGG -p $PR -m conntrack --ctstate NEW -m mark --mark 0/$W_MASK \
                --sport $((CUT+1)):65535 -j MARK --set-mark $W1_MARK/$W_MASK
        done
        # catchall: 未标记的非 tcp/udp 新流 -> 5G
        iptables -t mangle -A WANAGG -m conntrack --ctstate NEW -m mark --mark 0/$W_MASK \
            -j MARK --set-mark $W1_MARK/$W_MASK
    fi
    # 保存 ct mark 供后续包恢复
    iptables -t mangle -A WANAGG -j CONNMARK --save-mark --mask $W_MASK
    iptables -t mangle -A PREROUTING -i br-lan -j WANAGG
}

# v2.15: 旁路模式 — 拆全部分流装置(mangle 链 + fwmark 策略规则 v4/v6 高/低
# 位), 流量回落 main 表 = 走状态机当前主路; NAT/租约/路由看门狗不受影响
agg_bypass() {
    iptables  -t mangle -D PREROUTING -i br-lan -j WANAGG 2>/dev/null
    iptables  -t mangle -F WANAGG 2>/dev/null;  iptables  -t mangle -X WANAGG 2>/dev/null
    ip6tables -t mangle -D PREROUTING -i br-lan -j WANAGG6 2>/dev/null
    ip6tables -t mangle -F WANAGG6 2>/dev/null; ip6tables -t mangle -X WANAGG6 2>/dev/null
    for R in "fwmark $W1_MARK/$W_MASK table $T1" "fwmark $W2_MARK/$W_MASK table $T2" \
             "fwmark $M6_LOW1/0xff table $T1" "fwmark $M6_LOW2/0xff table $T2"; do
        while ip rule del $R 2>/dev/null; do :; done
        while ip -6 rule del $R 2>/dev/null; do :; done
    done
}

# v2.5: fwmark策略规则存在性看门狗 — 只补活侧缺失, 不动存量。
#   病例(2026-10-05): 高位v6规则在运行中被外力蒸发(boot期home瞬断恢复后消失),
#   无看门狗=静默丢一半路由规则。调用方须已设置 S1/S2(当前有效态)。
ensure_rules() {
    if [ $S1 -eq 1 ]; then
        ip rule show | grep -q "$W1_MARK/$W_MASK lookup $T1" || \
            ip rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
        ip -6 rule show | grep -q "$W1_MARK/$W_MASK lookup $T1" || \
            ip -6 rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
        ip -6 rule show | grep -q "$M6_LOW1/0xff lookup $T1" || \
            ip -6 rule add fwmark $M6_LOW1/0xff table $T1 priority 90 2>/dev/null
    fi
    if [ $S2 -eq 1 ]; then
        ip rule show | grep -q "$W2_MARK/$W_MASK lookup $T2" || \
            ip rule add fwmark $W2_MARK/$W_MASK table $T2 priority 102 2>/dev/null
        ip -6 rule show | grep -q "$W2_MARK/$W_MASK lookup $T2" || \
            ip -6 rule add fwmark $W2_MARK/$W_MASK table $T2 priority 102 2>/dev/null
        ip -6 rule show | grep -q "$M6_LOW2/0xff lookup $T2" || \
            ip -6 rule add fwmark $M6_LOW2/0xff table $T2 priority 91 2>/dev/null
    fi
    # 入向LAN护盾(v6 版也纳入看门狗; v4版在 wan_eth)
    ip -6 rule show | grep -q "to fd42:9ac1:7e50::/64 lookup main" || \
        ip -6 rule add to fd42:9ac1:7e50::/64 lookup main priority 50
}
