#!/bin/sh
# wan_agg.sh v2.10 — 双上行聚合主管 (vendor kernel engine + iptables fallback)
# v2.6 规则分层修正 + 真相更正(2026-10-05 终局判别实验):
#   [更正] 模块v6引擎完全正常(哈希%100读权重; 摘钉后100/0→4/4全WAN1实证)。
#   早前"v6常数哈希缺陷"结论系MAC钉死自污染 — 钉死旁路哈希(v4/v6同样),
#   而v6测试全用被钉PC发流。用户当日判断"原厂可能无辜"最终完全成立。
#   [缺陷] 同优先级下高位v6规则先装先匹配 → 模块判WAN1的目的绕过低8位
#   源端口分流(半数目的分流失效) → 低8位规则降优先级90/91, 双活时自建
#   引擎全权路由; 死侧摘除后回落模块高位规则(其failover翻转已实证)。
#   v2.5 死侧v6黑洞修复 + fwmark规则存在性看门狗(ensure_rules) 继续有效。
#   另: conntrack二进制在v3上relocation损坏, 所有 conntrack -D 从未生效 —
#   已移除死代码, 断而必破完全由fwmark摘除承担。
# v1.4 三洞齐修(2026-10-04 游戏登录排查中发现):
#   1. `ip link set $W2_IF up` 缺失(v1.3只热修未固化, 每次重启eth0 admin-down→租约死等)
#   2. 探活 `ping -I iface` 需接口在 main 表有路由; 现: 家宽侧装 metric 200 备用默认
#      (探活有路+故障兜底), 5G 侧 drift 块确保 main default 指向活跃 ccmni
#      (源IP绑定法被实测否决: 源192.168.3.x的包仍按目的走main→从ccmni出去=黑洞)
#   3. udhcpc one-shot 包 timeout 15 (链路异常时 busybox -n -q 可能无限等待, 实测挂死)
# v1.3: 5G 承载通道动态跟踪 — FH 拨号可能落在 ccmni1 或 ccmni2(实测 2026-10-04
#       冷启动落在 ccmni1, 而 v1.2 硬编码 ccmni2 → 表100指向死口, 40%流量黑洞)。
#
# 原厂架构 (subagent RE 2026-10-04, 证据: protocolmgr@0x5e850, wancc@0x9688a,
# mobilenetwork@0x2f191, quecadp.ko netfilter hook):
#   内核:  fhdrv_net_quecadp 按五元组 hash%100 < w1_pct 选 WAN, ct->mark 粘性
#   路由:  wancc 式 "ip rule add fwmark 0x4000000/0xfc000000 table N"
#   探活:  mobilenetwork 式 ping -I <if> -c1 -W3 -s1 <dst> | grep ttl
# v1.1: 实测 /proc/multi_wan/{mode,weight,mac_config} 写入全部失败(仅 debug 可写,
#   0644/root 无权限问题 -> 该驱动版 proc 写处理器残废, 真通道=/dev/fhdrv_net_dev
#   ioctl cmd=5, 参数格式待逆向最终报告)。故双引擎:
#   ENGINE=vendor: proc 写入成功且回读 mode=1 -> 用内核模块分流(最优)
#   ENGINE=iptables: mangle WANAGG 链 statistic 随机+CONNMARK 粘性(语义等价,
#   xt_statistic/xt_connmark 已在载) —— 当前实际生效引擎
#   ioctl 格式确认后切 vendor 引擎(v1.2)。
#
# WAN1 = 5G  ccmni2 (vendor 语义 WANDevice.1=nb5g)  mark 0x4000000
# WAN2 = 有线宽带 eth0 DHCP (静态IP形态见 uplink.conf) mark 0x8000000
# 实测基线 2026-10-04: 5G 258Mbps / 家宽 375Mbps (8并发 TUNA) -> 40/60
LAN_NET=192.168.9.0/24
W1_IF=ccmni2; W2_IF=eth0
W1_MARK=0x4000000; W2_MARK=0x8000000; W_MASK=0xfc000000
T1=100; T2=200
W1_PCT=40; W2_PCT=60
GW_FILE=/tmp/wan.gw
UDHCPC_PID=/tmp/udhcpc_wan.pid
UDHCPC_SCRIPT=/data/gw/udhcpc_wan.script
LOG=/tmp/wan_agg.log
MODE_FILE=/tmp/wan_mode
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
# v2.12: 主备模式 — 权重 100:0 -> 5G主力/家宽待命; 0:100 反之。
# 语义: 待命侧对引擎恒为逻辑down(真实探测照跑), 主力真死才接班, 恢复自动切回。
pmode_of() { case "$1" in 100) echo 1;; 0) echo 2;; *) echo 0;; esac; }
PMODE=0

# ---------- data plane ----------
dp_setup() {
    # 双表: T1 恒走 5G; T2 走家宽 gw (拿到租约后由 ensure_lease 侧刷新)
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

# v2.4: v6 自建分流引擎(RE方案b落地) — 对照实验实锤: 模块对 v4 完美分流(16/16)
# 但对 v6 全标 wan2(76/76, 常数哈希, 运行时缺陷; 静态逆向两族同码看不出)。
# 低8位标记体系(RE共处配方): W1=0x65 W2=0x66 mask 0xff —— 模块只写高6位,互不干扰;
# 本链 mangle(-150) 后手覆盖模块当包 skb 标记, CONNMARK 低8位存取做粘性。
# v6 规则改查低8位(0x65/0xff→T100, 0x66/0xff→T200); 游戏PC v6 MAC钉死在链头。
M6_LOW1=0x65; M6_LOW2=0x66
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
    # (v2.11: 原为单MAC硬编码; 钉死表 /data/gw/agg_pins.conf, 模板见仓库 example)
    # (v2.12: 主备模式下跳过 — 待命侧不该收到任何流量, 钉死语义不适用)
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
        # 双路: 源端口区间确定性分流(xt_statistic无ipv6; OS随机sport≈均匀, 40/60)
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

# iptables 引擎: WANAGG 链重建 (v2.17: 免插件配方 — 本机 iptables 内建 tcp/udp/mark/
# connmark 匹配, 而 libxt_statistic.so 缺 libxtables.so.12 不可用, libxt_mac 根本
# 不存在; 分流改源端口区间确定性(v6 同款), 钉死改源 IP(pin MAC 经邻居表解析))
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

# ---------- eth0 租约管理 (修 wan_policy2 v1.3 缺口: exec 路径不拉续租守护,
# ---------- deconfig flush 后无人补 IP -> 家宽静默失效) ----------
ensure_lease() {
    ip link set $W2_IF up 2>/dev/null   # v1.4: PHY 只在 ifup 后 attach, 别再裸 DOWN
    if [ -z "$(ip -4 addr show $W2_IF 2>/dev/null | grep inet)" ]; then
        # v1.6: 本机busybox无timeout(127静默失败的元凶); 载波守卫防链路断时udhcpc长挂
        if [ "$(cat /sys/class/net/$W2_IF/carrier 2>/dev/null)" = "1" ]; then
            log "lease: no IP on $W2_IF, one-shot udhcpc"
            # v1.5: 唯一所有者=本循环; 弃 renewal 守护(双udhcpc打架=全网黑洞根源)
            udhcpc -i $W2_IF -n -q -t 3 -T 3 -p $UDHCPC_PID -s $UDHCPC_SCRIPT >/dev/null 2>&1
        fi
    fi
    # v1.5: 双默认看门狗 — 每周期只补缺失, 不动存量; 谁冲刷都 5s 内自愈
    # v1.7: to-LAN 护盾同上看门狗(入向回包带ct-mark, 无此规则会被fwmark劫持回WAN表
    #       原路弹回公网 = 全LAN黑洞; 原属wan_policy2, 退役后重启即蒸发)
    ip rule show | grep -q "to $LAN_NET lookup main" || \
        ip rule add to $LAN_NET lookup main priority 50
    ip route show default | grep -q "dev $W1_IF" || \
        ip route add default dev $W1_IF metric 50 2>/dev/null
    if [ -s $GW_FILE ]; then
        BB_GW=$(head -1 $GW_FILE)
        ip route replace default via $BB_GW dev $W2_IF table $T2 2>/dev/null
        ip route show default | grep -q "via $BB_GW dev $W2_IF" || \
            ip route add default via $BB_GW dev $W2_IF metric 200 2>/dev/null
    fi
    # v2.3: eth0 NAT/FORWARD 看门狗(真补上——v1.7提交曾虚报覆盖, 手工规则重启即蒸发,
    #       eth0裸源出公网=黑洞; 本块与路由看门狗同周期自愈)
    iptables -t nat -C POSTROUTING -s $LAN_NET -o $W2_IF -j MASQUERADE 2>/dev/null || \
        iptables -t nat -A POSTROUTING -s $LAN_NET -o $W2_IF -j MASQUERADE
    iptables -C FORWARD -i br-lan -o $W2_IF -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i br-lan -o $W2_IF -j ACCEPT
    iptables -C FORWARD -i $W2_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
        iptables -I FORWARD -i $W2_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
    # v2.0: v6 T200 家宽路由学习(从 main 的 RA 默认路由取 gw, 每周期刷新)
    V6GW=$(ip -6 route show default 2>/dev/null | grep "dev $W2_IF" | grep -oE "via [a-f0-9:]+ " | awk '{print $2}' | head -1)
    [ -n "$V6GW" ] && ip -6 route replace default via $V6GW dev $W2_IF table $T2 2>/dev/null
}

ensure_rules() {  # v2.5: fwmark策略规则存在性看门狗 — 只补活侧缺失, 不动存量
    # 病例(2026-10-05): 高位v6规则在运行中被外力蒸发(boot期home瞬断恢复后消失),
    # 无看门狗=静默丢一半路由规则; 现与路由/NAT看门狗同周期自愈
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
    # 入向LAN护盾(v6 版也纳入看门狗; v4版在 ensure_lease)
    ip -6 rule show | grep -q "to fd42:9ac1:7e50::/64 lookup main" || \
        ip -6 rule add to fd42:9ac1:7e50::/64 lookup main priority 50
}

# ---------- 探活 (mobilenetwork 原版配方) ----------
probe() {  # $1=iface $2=dst
    ping -4 -I $1 -c1 -W3 -s1 "$2" 2>/dev/null | grep -q ttl
}
w1_alive() { probe $W1_IF 223.5.5.5 || probe $W1_IF 120.53.53.53; }
w2_alive() {
    # v2.13: 通用探活 — conf 的 UPLINK_PROBE_GW 优先(与认证程序解耦, 可插拔),
    # 旧字段 UPLINK_GW 兼容回退; 家宽形态探 BB_GW/公网DNS
    BB_GW=$(head -1 $GW_FILE 2>/dev/null)
    if [ -r /data/gw/uplink.conf ] && grep -q '^FORM=static' /data/gw/uplink.conf; then
        BB_GW=$(grep -m1 '^UPLINK_PROBE_GW=' /data/gw/uplink.conf | cut -d= -f2)
        [ -z "$BB_GW" ] && BB_GW=$(grep -m1 '^UPLINK_GW=' /data/gw/uplink.conf | cut -d= -f2)
        [ -z "$BB_GW" ] && return 1
        probe $W2_IF "$BB_GW" && return 0
        return 1
    fi
    [ -z "$BB_GW" ] && return 1
    probe $W2_IF "$BB_GW" || probe $W2_IF 223.5.5.5
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

# ---------- 主循环 ----------
log "===== wan_agg v2.12 start ====="
# v1.8: MAC 钉死表重放(内核模块状态不跨重启, 游戏PC等需开机重新钉)
while read -r MAC OP; do
    case "$MAC" in \#*|"") continue;; esac
    LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib LD_PRELOAD=/data/gw/fhstub.so         /data/gw/multiwan_ctl mac "$MAC" "$OP" >>$LOG 2>&1
    log "pin: $MAC op=$OP rc=$?"
done < /data/gw/agg_pins.conf
# 引擎探测: vendor ioctl (multiwan_ctl+fhstub; proc 写已证伪为只读) 失败则 iptables
kernel_apply 1 1 && ENGINE=vendor || ENGINE=iptables
echo "$ENGINE" > /tmp/wan_engine
# v2.15: 聚合总开关 (agg.conf ENABLE=0|1, GUI agg_mode 端点热切)
AGG_ON=1
grep -q '^ENABLE=0' /data/gw/agg.conf 2>/dev/null && AGG_ON=0
dp_setup
S1=1; S2=1; D1=0; D2=0; U1=0; U2=0
if [ "$AGG_ON" = 1 ]; then
    [ "$ENGINE" = iptables ] && fw_setup 60
    fw6_rules; fw6_setup 1   # v2.4: v6 低8位自建分流(模块v6哈希常数缺陷的对策)
else
    agg_bypass
    echo "off" > $MODE_FILE
fi
log "init: engine=$ENGINE agg_on=$AGG_ON weights=$W1_PCT/$W2_PCT s1=$S1 s2=$S2"

while :; do
    # 5G 承载漂移检测: 活跃 ccmni 变了就刷新 表100/main/NAT/FORWARD (幂等)
    CW=$(ip -o addr show 2>/dev/null | grep ccmni | grep 'inet ' | awk '{print $2}' | head -1)
    if [ -n "$CW" ] && [ "$CW" != "$W1_IF" ]; then
        log "5g iface moved: $W1_IF -> $CW"
        W1_IF=$CW
        ip route replace default dev $W1_IF table $T1 2>/dev/null
        # v1.4: main 主默认也钉到活跃 ccmni(netagent 漂移后可能指着死口)
        ip route replace default dev $W1_IF 2>/dev/null
        ip route replace default dev $W1_IF metric 50 2>/dev/null
        iptables -t nat -C POSTROUTING -s $LAN_NET -o $W1_IF -j MASQUERADE 2>/dev/null || \
            iptables -t nat -A POSTROUTING -s $LAN_NET -o $W1_IF -j MASQUERADE
        iptables -C FORWARD -i br-lan -o $W1_IF -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -i br-lan -o $W1_IF -j ACCEPT
        iptables -C FORWARD -i $W1_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
            iptables -I FORWARD -i $W1_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
        D1=99; U1=0   # 迫使下一轮重新评估 5G 探活
        ip -6 route replace default dev $W1_IF table $T1 2>/dev/null
    fi
    # v2.15: 总开关热切 (agg.conf ENABLE) — 0=旁路 1=参战
    NEW_EN=$(grep -m1 '^ENABLE=' /data/gw/agg.conf 2>/dev/null | cut -d= -f2)
    case "$NEW_EN" in 0|1) ;; *) NEW_EN=1 ;; esac
    if [ "$NEW_EN" != "$AGG_ON" ]; then
        AGG_ON=$NEW_EN
        if [ "$AGG_ON" = 0 ]; then
            agg_bypass
            echo "off" > $MODE_FILE
            log "agg: OFF -> bypass (单路 main 表; NAT/看门狗保留)"
        else
            dp_setup; fw6_rules
            FORCE=1   # 状态机按当前有效态整体重装分流
            log "agg: ON -> re-engage"
        fi
    fi
    # v2.9: 权重在线热更 — GUI(api.sh agg_weights)写 /data/gw/agg.conf,
    # 本守护每周期重读, 值变即下发 ioctl + 记日志(状态迁移不再用旧权重打回)
    if [ -r /data/gw/agg.conf ] && [ "$AGG_ON" = 1 ]; then
        OW1=$W1_PCT
        . /data/gw/agg.conf
        case "$W1_PCT" in
            ''|*[!0-9]*) W1_PCT=$OW1 ;;
        esac
        if [ "$W1_PCT" -ge 0 ] && [ "$W1_PCT" -le 100 ]; then :; else W1_PCT=$OW1; fi
        if [ "$W1_PCT" != "$OW1" ]; then
            W2_PCT=$((100 - W1_PCT))
            log "weights hot-reload: $OW1/$((100-OW1)) -> $W1_PCT/$W2_PCT"
            # v2.12: 100/0 触发主备语义切换, 交给状态机用有效态整体迁移
            OP_MODE=$PMODE; PMODE=$(pmode_of "$W1_PCT")
            if [ "$PMODE" != "$OP_MODE" ]; then
                log "mode: pmode $OP_MODE -> $PMODE (0=双活 1=5G主备 2=家宽主备)"
                FORCE=1
            else
                kernel_apply $S1 $S2 2>>$LOG
            fi
        fi
    fi
    ensure_lease
    [ "$AGG_ON" = 1 ] && ensure_rules
    # v2.17: 钉死IP漂移检测 — pin MAC 的邻居IP变了(或新上线)则重建分流链
    if [ "$AGG_ON" = 1 ] && [ "$PMODE" = 0 ] && [ "$ENGINE" = iptables ]; then
        while read -r PIN_MAC PIN_OP; do
            case "$PIN_MAC" in "#"*|"") continue ;; esac
            [ "$PIN_OP" = 1 ] || [ "$PIN_OP" = 2 ] || continue
            NOW_IP=$(pin_ip "$PIN_MAC")
            OLD_IP=$(cat /tmp/pin_${PIN_MAC//:/}.ip 2>/dev/null)
            if [ "$NOW_IP" != "$OLD_IP" ]; then
                log "pin: $PIN_MAC ip $OLD_IP -> ${NOW_IP:-未解析}, 重建分流链"
                FORCE=1
            fi
        done < /data/gw/agg_pins.conf
    fi
    if w1_alive; then U1=$((U1+1)); D1=0; else D1=$((D1+1)); U1=0; fi
    if w2_alive; then U2=$((U2+1)); D2=0; else D2=$((D2+1)); U2=0; fi
    NS1=$S1; NS2=$S2
    # v2.0: 确定性信号瞬时降级 — 无载波/无IP是"确定"而非"疑似"(重租约窗口被hash到
    #       家宽的新流全灭=恢复期粗糙窗口的根因), 跳过3连击立即全量切5G
    W2_READY=0
    [ "$(cat /sys/class/net/$W2_IF/carrier 2>/dev/null)" = "1" ] && \
      [ -n "$(ip -4 addr show $W2_IF 2>/dev/null | grep inet)" ] && W2_READY=1
    if [ $S2 -eq 1 ] && [ $W2_READY -eq 0 ]; then NS2=0; D2=99; fi
    # 3 连续判死/判活 (原厂 brokenHeartCount 同款节奏, 5s 周期 -> ~15s 收敛)
    [ $S1 -eq 1 ] && [ $D1 -ge 3 ] && NS1=0
    [ $S1 -eq 0 ] && [ $U1 -ge 3 ] && NS1=1
    [ $S2 -eq 1 ] && [ $D2 -ge 3 ] && NS2=0
    [ $S2 -eq 0 ] && [ $U2 -ge 3 ] && NS2=1
    # v2.12: 主备模式注入有效态 — 待命侧恒为逻辑down(NS 仅用于真实生死判定),
    # 主力死(E主力=0)时待命侧 NS 值透传 -> 全量接班; 主力恢复 -> 待命侧归零回切
    E1=$NS1; E2=$NS2
    if [ "$PMODE" = 1 ] && [ $NS1 -eq 1 ]; then E2=0
    elif [ "$PMODE" = 2 ] && [ $NS2 -eq 1 ]; then E1=0
    fi
    if [ "$AGG_ON" = 1 ] && { [ "$E1$E2" != "$S1$S2" ] || [ "${FORCE:-0}" = 1 ]; }; then
        FORCE=0
        log "state: 5g $S1->$E1 (d1=$D1) home $S2->$E2 (d2=$D2) pmode=$PMODE"
        kernel_apply $E1 $E2 2>>$LOG   # vendor 引擎下即生效; iptables 引擎下无害空写
        if [ "$ENGINE" = iptables ]; then
            if [ $E1 -eq 1 ] && [ $E2 -eq 1 ]; then fw_setup $W2_PCT
            elif [ $E2 -eq 0 ]; then fw_setup 0
            else fw_setup 100; fi
            # v2.5: conntrack二进制损坏(relocation: nfct_nlmsg_build_filter not found)
            #       conntrack -D 在v3从未生效, 移除死调用 — 断而必破由下方fwmark摘除承担
        fi
        # v2.4: v6 链按新态重建(低8位体系; 双路/单路形态)
        if   [ $E1 -eq 1 ] && [ $E2 -eq 1 ]; then fw6_setup 1
        elif [ $E2 -eq 0 ]; then fw6_setup 0
        else fw6_setup_alive2; fi
        # 粘性流兜底: 死侧 fwmark 规则摘除 -> 老流回落 main; 复活再装回
        # v2.5: 低8位v6规则(0x65/0x66)同摘 — 死侧低8位粘性/钉死流回落模块高位规则
        #       (模块v6按status翻转已实证: wan2_status=0→WAN1), 不再压向死T200黑洞
        if [ $E2 -eq 0 ]; then
            ip rule del fwmark $W2_MARK/$W_MASK table $T2 2>/dev/null
            ip -6 rule del fwmark $W2_MARK/$W_MASK table $T2 2>/dev/null
            ip -6 rule del fwmark $M6_LOW2/0xff table $T2 2>/dev/null
        else
            ip rule add fwmark $W2_MARK/$W_MASK table $T2 priority 102 2>/dev/null
            ip -6 rule add fwmark $W2_MARK/$W_MASK table $T2 priority 102 2>/dev/null
            ip -6 rule del fwmark $M6_LOW2/0xff table $T2 2>/dev/null
            ip -6 rule add fwmark $M6_LOW2/0xff table $T2 priority 91 2>/dev/null
        fi
        if [ $E1 -eq 0 ]; then
            ip rule del fwmark $W1_MARK/$W_MASK table $T1 2>/dev/null
            ip -6 rule del fwmark $W1_MARK/$W_MASK table $T1 2>/dev/null
            ip -6 rule del fwmark $M6_LOW1/0xff table $T1 2>/dev/null
            BB_GW=$(head -1 $GW_FILE 2>/dev/null)
            [ -n "$BB_GW" ] && ip route replace default via $BB_GW dev $W2_IF 2>/dev/null
        else
            ip rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
            ip -6 rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
            ip -6 rule del fwmark $M6_LOW1/0xff table $T1 2>/dev/null
            ip -6 rule add fwmark $M6_LOW1/0xff table $T1 priority 90 2>/dev/null
            ip route replace default dev $W1_IF 2>/dev/null   # main 表复位 5G
        fi
        S1=$E1; S2=$E2
        echo "agg:$S1:$S2" > $MODE_FILE
    fi
    sleep 5
done
