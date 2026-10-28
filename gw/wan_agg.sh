#!/bin/sh
# wan_agg.sh v3.6 — 双上行聚合主管: 探活 + 故障转移 FSM + 未打标主路策略 + CLI
# v3.2 (2026-10-17 日志加密轮): 每 ~30s TICK 汇总(存活/计数/authd/承载口/候选),
#   探活逐目标结果、硬截止触发、ccmni 清单变化、authd/W2_READY 边沿、主路写失败
#   全部留痕; 本文件日志自轮转(400 行) — 24h 分析不再依赖偶然的状态迁移行。
# v3.0 (2026-10-17 架构轮, 大杂烩拆分):
#   引擎落地层(dp_setup/fw*/kernel_apply/ensure_rules/agg_bypass/pin_*)与
#   agg.conf/钉死表管理迁入 wan_agg_lib.sh(被 source; 单进程 = 单写方纪律不变);
#   eth0 租约/NAT/路由看门狗(原 ensure_lease)迁出为独立守护 wan_eth.sh(rc19 先于
#   本守护拉起, watchdog 自愈) — udhcpc 最坏 9s+ 原内联在探活环循里, 租约期间整个
#   FSM 停摆(侵蚀 25s 硬截止预算), 独立后互不阻塞。
#   蜂窝探活路由(metric 250)+metric-50 遗留清理上收到 main_primary_apply() 头部:
#   原散在 ensure_lease(每周期), 上提后**双死态(prim 空)也维持探活可达** —— 否则
#   路由被外力冲刷后无法探活 = 无法恢复的死锁。BB_GW 改由本函数自读(原在
#   ensure_lease 设置, wan_eth 拆出后本进程无人再设)。
#   死代码清除: pmode_of(v2.12 legacy, v2.18 起 pmode_of_mode 取代后零调用方)。
#   MODE 白名单/W1_PCT 钳位校验原三处重复, 收敛为 lib 的 agg_conf_load()。
# v2.34: 钉死表缺省播种(逻辑在 lib.agg_conf_seed; 活文件设备侧自管不入库, 缺失时
#   从随版本部署的 agg_pins.default 缺省才写地播种, 已有钉死永不覆盖)。
# v2.32 (2026-10-16 00:06 宵断实弹): 判活目标多样化 —— 原目标(223.5.5.5/120.53.53.53)
#   被上行接入网夜间切断的白名单放行, 探测恒过而客户端全死 → 永不转移。现取三个不同
#   运营商/ASN 且不在白名单内的目标(任一通过即活) + ICMP 全灭时 TCP 握手兜底;
#   并发布 /tmp/wan_alive 作为数据面判活的唯一权威, led_mgr/api 消费之。
# v2.31 (2026-10-15 用户裁定): 未打标主路(v4 与 v6)不再写死优先级 —— 统一由
#   "模式+权重+真实存活"推导(prim_want), 并由 main_primary_apply() 作为 main 表
#   的**唯一写方**每周期复位(level-driven; 边沿触发会被外力冲刷后滞留)。
#   语义: 只一侧活→该侧; 双活→eth_prio/eth_only→家宽, cell_prio/cell_only→蜂窝,
#   weight→权重大的一侧(平局取家宽); 都不活→不猜保持现状。
# v2.30 (2026-10-15 A1): 蜂窝侧 main 表默认路由收敛为"纯探活"用途 —— metric
#   50→250(劣于家宽备用 200), 家宽主力期不再往 main 写 metric 0/50; 补齐家宽
#   主默认的存在性看门狗(原先只在状态迁移时装一次 = 长期漏洞)。
# v2.29: 移除 ETH_CURFEW 先验时段(用户裁定: 判定不做先验) — 静默型切断由 authd v2.3
#   静默看门狗(>40s 无 EAP 帧判死)承接
# v2.28(2026-10-12 实弹): w2_data_alive 去网关短路(宽限期网关仍答 ICMP 的盲区)
# v2.27(2026-10-11 实弹: 上游 EAP 重启窗口漏拦截页给手机): 探测 -W1 + 首败同轮复核
#   — 死亡确认 25s 级→<=8s
# v2.26(2026-10-09 21:30 实弹: 以太断链数分钟不转移): up 不再是充分的活证据,
#   必须叠加数据面 ICMP 实证(w2_data_alive)。根因在 authd: succ 一旦置位永不复位,
#   收到任何 EAPOL 帧即 state_write("up") → 以太恒判活 → 待命侧永无接班机会。
#   down 仍保留协议级零延迟快路径。
# v2.24: authd 会话信号(/tmp/authd_state) — down 即时判死, up 仅作免长探测加速项。
# v2.21: 安全启动 — W2_OK=0(eth 从未验证成功) => 硬截止立即判死 => 5G 起步。
# v2.20: 硬截止判死(活侧 >25s 无成功探活即判死, 跳过3连击) — 计数制可被迟滞/饥饿
#   模式饿死; 时间截止不可, 故障转移上界 = 60s + 一个环循周期。
# v2.23: 恢复迟滞 U>=6 — 掐灭抖动源(状态抖动→规则重建churn→8s 黑洞)。
# v1.3: 5G 承载通道动态跟踪 — FH 拨号可能落在 ccmni1 或 ccmni2(实测冷启动落
#       ccmni1, 硬编码 ccmni2 → 表100指向死口, 40%流量黑洞)。
# 引擎/规则/ioccc 历史与 RE 证据见 wan_agg_lib.sh 头注。
# 实测基线 2026-10-04: 5G 258Mbps / 家宽 375Mbps (8并发 TUNA) -> 40/60
. /data/gw/wan_agg_lib.sh
# v3.5 (batch3): wan_agg had no self-lock (rc19 starts it with nohup and the
# watchdog only pre-writes the lock when IT spawns).  A manual restart could
# therefore run two supervisors writing the same rules.  The shared lock is
# taken after the CLI dispatch below.
if [ -r /data/gw/svc_lib.sh ]; then . /data/gw/svc_lib.sh; fi
W1_IF=ccmni2; W2_IF=eth0
GW_FILE=/tmp/wan.gw
MODE_FILE=/tmp/wan_mode
W1_PCT=40; W2_PCT=60
PMODE=0
MODE=weight
# v3.2: 本文件日志轮转(日志加密轮) — 400 行保留 200; log_keeper 侧再做增量持久化
MAXL=400
log_rot() { [ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt $MAXL ] && \
    { tail -n $((MAXL/2)) $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }; }

# ---------- v2.31: 未打标主路 = 聚合设定推导(不写死优先级) ----------
# 未打标流量 = 本机自身(netagent/DNS/NTP/测速…)+ 丢标记的转发流。统一为: 两侧地址
# 族都由"真实存活 + 模式/权重"推导同一主路, 且**每周期无条件复位**(边沿触发会被
# 外力冲刷后滞留, 与 led_mgr v2.0 同一课)。
prim_want() {   # $1=ns1(蜂窝真实存活 0/1) $2=ns2(家宽真实存活 0/1)
    case "$1$2" in
        10) echo w1 ;;
        01) echo w2 ;;
        00) echo "" ;;
        *)
            case "$MODE" in
                cell_prio|cell_only) echo w1 ;;
                eth_prio|eth_only)   echo w2 ;;
                weight) [ "$W1_PCT" -gt "$W2_PCT" ] && echo w1 || echo w2 ;;
                *) echo w2 ;;
            esac ;;
    esac
}

# main 表(未打标主路)的**唯一写方**。v4: 主路 metric 0(顺带挤掉对侧 metric-0);
# v6: 主路我方显式条目 metric V6_PRI_METRIC, 对侧我方条目删除、RA 默认留作兜底。
# v3.0: 头部先维持蜂窝探活可达(与主路无关也要保 —— 双死态探活是恢复的前提),
#   BB_GW 自读(原由 ensure_lease 设置, wan_eth 拆出后本函数是唯一读者)。
main_primary_apply() {   # $1=w1|w2 (空=状态未知, 仅维持探活路由)
    # v3.4 (batch3): serialize main-table writes with wan_eth/rc_netfh.
    # v3.6 (2026-10-29 断网): 锁被占**不得让 failover 停摆**。旧行为直接 return,
    #   实弹: radvd 泄漏持锁 2h -> 家宽断链时本函数每轮超时 -> 整机断网 9 分钟。
    #   新增单笔紧急切换: 仅当"目标主路 != 已生效主路"(确有待切换)时, 用一条原子
    #   ip route replace 完成 v4 切换(单条 netlink 写是原子的, 竞态最坏 last-wins,
    #   远好于死守已失效主路); 多步序列(规则/表/防火墙/v6 下一跳)仍只在锁内做。
    if ! netcfg_lock 3; then
        if [ -n "$1" ] && [ "$1" != "$P_LAST" ]; then
            if [ "$1" = w2 ]; then
                _ebg=$(head -1 $GW_FILE 2>/dev/null)
                [ -n "$_ebg" ] && ip route replace default via $_ebg dev $W2_IF 2>/dev/null && \
                    log "EVT main-primary emergency w2 (netlock busy; single-op dev=$W2_IF gw=$_ebg)"
            else
                ip route replace default dev $W1_IF 2>/dev/null && \
                    log "EVT main-primary emergency w1 (netlock busy; single-op dev=$W1_IF)"
                ip -6 route replace default dev $W1_IF metric $V6_PRI_METRIC 2>/dev/null
            fi
            P_LAST=$1
        else
            log "WARN netcfg lock timeout: main_primary_apply"
        fi
        return 0
    fi
    ip route show default | grep -q "dev $W1_IF metric $W1_PRB_METRIC" || \
        ip route add default dev $W1_IF metric $W1_PRB_METRIC 2>/dev/null
    ip route del default dev $W1_IF metric 50 2>/dev/null   # 清历史遗留(旧写方)
    _p=$1; [ -n "$_p" ] || { netcfg_unlock; return 0; }
    BB_GW=$(head -1 $GW_FILE 2>/dev/null)
    # --- v4 ---
    if [ "$_p" = w2 ]; then
        if [ -n "$BB_GW" ]; then
            ip route replace default via $BB_GW dev $W2_IF 2>/dev/null || \
                log "WARN main v4 w2 write failed (gw=$BB_GW dev=$W2_IF)"
            ip route show default | grep -q "via $BB_GW dev $W2_IF metric 200" || {
                ip route add default via $BB_GW dev $W2_IF metric 200 2>/dev/null || \
                    log "WARN main v4 w2 backup metric200 add failed (gw=$BB_GW)"; }
        fi
    else
        ip route replace default dev $W1_IF 2>/dev/null || \
            log "WARN main v4 w1 write failed (dev=$W1_IF)"
    fi
    # --- v6(与 v4 同一主路) ---
    # 家宽侧需 RA 学到的下一跳(via 链路本地地址); 蜂窝侧用**设备路由**
    #   (default dev ccmni2 —— 与 table 100 里已验证可用的同款形态), 不依赖
    #   模组是否重发 RA(实测 RIL 重启后主表 RA 默认路由可能长期不再出现)。
    _g2=$(ip -6 route show default 2>/dev/null | grep "dev $W2_IF" | grep -oE "via [0-9a-f:]+" | awk '{print $2}' | head -1)
    if [ "$_p" = w2 ]; then
        ip -6 route del default dev $W1_IF metric $V6_PRI_METRIC 2>/dev/null
        ip -6 route del default dev $W1_IF metric 0 2>/dev/null   # 清 rc_netfh 遗留
        [ -n "$_g2" ] && { ip -6 route replace default via $_g2 dev $W2_IF metric $V6_PRI_METRIC 2>/dev/null || \
            log "WARN main v6 w2 write failed (via=$_g2 dev=$W2_IF)"; }
        [ -z "$_g2" ] && [ "$_p" != "$P_LAST" ] && \
            log "WARN main v6 w2: no RA next-hop on $W2_IF (route left to RA default)"
    else
        ip -6 route del default dev $W2_IF metric $V6_PRI_METRIC 2>/dev/null
        ip -6 route replace default dev $W1_IF metric $V6_PRI_METRIC 2>/dev/null || \
            log "WARN main v6 w1 write failed (dev=$W1_IF)"
    fi
    [ "$_p" != "$P_LAST" ] && { log "main-primary: $_p (v4+v6 未打标主路; mode=$MODE w1=$W1_PCT% 存活=$NS1/$NS2)"; P_LAST=$_p; }
    netcfg_unlock
}
P_LAST=""

# ---------- 探活 ----------
probe() {  # $1=iface $2=dst
    # v2.27: -W2→-W1 — 探测最坏耗时减半(w2_alive 3 目标×超时), 死亡确认窗口
    #   相应收窄; 双路 RTT 均 <<1s, 1s 超时余量充足。
    ping -4 -I $1 -c1 -W1 -s1 "$2" 2>/dev/null | grep -q ttl
}
# v2.32(2026-10-16 00:06 宵断实弹): 判活目标必须**多样且排除白名单内目标**。
#   原目标 223.5.5.5 / 120.53.53.53(运营商 DNS)恰好被上行接入网夜间切断的白名单放行 ——
#   探测恒过而客户端流量全死, 于是永不转移(用户手动改"仅蜂窝"才恢复)。实弹同时段:
#   223.5.5.5/120.53.53.53/网关 全通, 而 180.76.76.76/119.29.29.29/8.8.8.8 全 100%
#   丢包 —— 后者才是"能上网"的判据。取三个不同运营商/ASN 且不在白名单内的目标,
#   规则 = **任一通过即活**(单目标故障不致误判死)。
PROBE_V4="180.76.76.76 119.29.29.29 8.8.8.8"
# 兜底: 有的网络整段过滤 ICMP —— ICMP 全灭时再做一次 TCP 握手(按 IP, 不依赖 DNS),
#   任一 HTTP 响应码(含 4xx/5xx)都证明 TCP 通。只在疑似死亡时才付这次代价。
tcp_probe() {   # $1=iface
    # 单目标 + -m3: 死亡态下每环循最多多花 ~3s(环循 3s+3s), 不拖垮状态机节奏。
    _c=$(LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib /fhrom/bin/curl -s -m 3 -o /dev/null \
         -w '%{http_code}' --interface $1 http://180.76.76.76/ 2>/dev/null)
    [ -n "$_c" ] && [ "$_c" != "000" ]
}
data_alive() {   # $1=iface — 数据面实证: 多样 ICMP → TCP 兜底
    # v3.2: 逐目标结果写入 PRB_RES(日志用) — 24h 分析可区分"整段断"与"单目标
    #   被白名单放行/过滤"; 探测失败才付 TCP 兜底的代价, 结果一并留痕。
    _r=""
    for _t in $PROBE_V4; do
        if probe $1 $_t; then PRB_RES="${_r# } $_t:1"; return 0; fi
        _r="$_r $_t:0"
    done
    if tcp_probe $1; then PRB_RES="${_r# } tcp:1"; return 0; fi
    PRB_RES="${_r# } tcp:0"
    return 1
}
w1_alive() { data_alive $W1_IF; }
w2_data_alive() {  # 以太数据面实证 — 仅公网目标, 与认证程序解耦
    data_alive $W2_IF
}
w2_alive() {
    # v2.24: 协议级信号优先 — authd 会话状态文件(/tmp/authd_state: up|down+epoch,
    #   由 EAP-Success/重询问/Failure 实时刷新)。新鲜 down=死(00:06 型事件的服务器
    #   EAP-Failure 即刻可见, 检测延迟=0), 保留零延迟快路径。
    # v2.26(2026-10-09 21:30 实弹): 新鲜 up 不再单独构成"活"(authd 侧 succ 一旦
    #   置位即永不复位, 任何 EAPOL 帧都刷 up —— 认证帧在途而数据面已死时恒"活")。
    #   新语义: up 只作为"免长探测"的加速项, 必须叠加数据面 ICMP 实证才判活;
    #   down 仍是协议级零延迟判死。转移上界不变(硬截止 25s + 一个环循)。
    [ "$AUTHD_DOWN" = 1 ] && return 1
    [ "$AUTHD_UP" = 1 ] && w2_data_alive && return 0
    w2_data_alive
}

# ---------- CLI ----------
# v2.31: 干跑入口(自检/回归用, 不碰现场): 打印给定模式与存活态下的未打标主路。
#   usage: wan_agg.sh --dry-primary <mode> <ns1> <ns2> [w1_pct]
case "$1" in
--dry-primary)
    MODE=${2:-weight}; W1_PCT=${5:-30}; W2_PCT=$((100 - W1_PCT))
    _pw=$(prim_want "${3:-1}" "${4:-1}")
    printf 'mode=%s w1pct=%s alive=%s/%s primary=%s\n' "$MODE" "$W1_PCT" "${3:-1}" "${4:-1}" "${_pw:-none}"
    exit 0 ;;
--set-primary)
    # 维护/验证入口: 立即把未打标主路(v4+v6)设为 w1|w2 并回显结果。守护在跑时
    #   下个环循会按模式复位 —— 手动覆盖是瞬态的(level-driven 的自然结果)。
    [ -n "$2" ] || { echo "usage: wan_agg.sh --set-primary w1|w2"; exit 2; }
    main_primary_apply "$2"
    echo "main-primary -> $2"
    ip route show default; ip -6 route show default
    exit 0 ;;
esac

# v3.5: one supervisor only (cmdline + zombie verification, shared primitive).
if command -v svc_lock >/dev/null 2>&1; then
    _rc=0; svc_lock wan_agg /data/gw/wan_agg.sh || _rc=$?
    if [ "$_rc" != 0 ]; then
        [ "$_rc" = 1 ] && echo "wan_agg: already running" >&2 || echo "wan_agg: lost lock race" >&2
        exit 0
    fi
fi

log "===== wan_agg v3.5 start (lib 拆分; eth0 归 wan_eth; 判活多样+wan_alive; fine-log) ====="
log "EVT env: w1=$W1_IF w2=$W2_IF probe=[$PROBE_V4] t1=$T1 t2=$T2 metric_prb=$W1_PRB_METRIC up=$(cut -d. -f1 /proc/uptime)s"
agg_conf_seed
pin_replay
# 引擎探测: vendor ioctl (multiwan_ctl+fhstub; proc 写已证伪为只读) 失败则 iptables
kernel_apply 1 1 && ENGINE=vendor || ENGINE=iptables
echo "$ENGINE" > /tmp/wan_engine
# v2.15: 聚合总开关 (agg.conf ENABLE=0|1, GUI agg_mode 端点热切)
AGG_ON=1
grep -q '^ENABLE=0' /data/gw/agg.conf 2>/dev/null && AGG_ON=0
agg_conf_load 30
dp_setup
S1=1; S2=1; D1=0; D2=0; U1=0; U2=0
# v2.21: 安全启动 — W2_OK=0(eth 从未验证成功) => 硬截止立即判死 => 5G 起步;
# eth 探活 3 连过后自动回切。杜绝"上行已死时重启/开机, 状态机先盲目把
# 流量灌进死 eth0"的黑洞窗口(2026-10-08 00:33 实弹 29s 黑洞)。
W1_OK=$(date +%s); W2_OK=0
if [ "$AGG_ON" = 1 ]; then
    [ "$ENGINE" = iptables ] && fw_setup 60
    fw6_rules; fw6_setup 1   # v2.4: v6 低8位自建分流
else
    agg_bypass
    echo "off" > $MODE_FILE
fi
log "init: engine=$ENGINE agg_on=$AGG_ON weights=$W1_PCT/$W2_PCT s1=$S1 s2=$S2"

CYC=0; CAND_LAST=""; AS_LAST=""; W2R_LAST=""; P1R_LAST=""; P2R_LAST=""; CW_LAST=""
while :; do
    CYC=$((CYC+1)); T0=$(date +%s)
    [ $((CYC % 10)) -eq 0 ] && log_rot
    # 5G 承载漂移检测: 活跃 ccmni 变了就刷新 表100/main/NAT/FORWARD (幂等)
    # v3.1 (RIL 清零轮回归): 原判据取 `ip addr show | head -1` —— 字母序第一个。
    #   多 ccmni 并存(旧 PDN 未 deact 干净)时可能选中**僵尸口**(有 IP 无数据),
    #   而真正承载数据的是另一口(实弹: ccmni1 通/cmmni2,3 僵尸, 探活全灭 cell=0)。
    #   新判据: 候选按字母序, **能探活通过的那个才算活跃**; 当前口仍通则不变
    #   (避免每轮乒乓)。全部不通时保持现状, 由 FSM 判死转移。
    _cand=$(ip -o -4 addr show 2>/dev/null | grep ccmni | grep 'inet ' | awk '{print $2}')
    # v3.2: ccmni 清单/地址变化留痕 — 僵尸口增删是"多 PDN 并存"的第一手证据
    _inv=$(ip -o -4 addr show 2>/dev/null | grep ccmni | awk '{print $2":"$4}' | tr '\n' ',')
    if [ "$_inv" != "$CAND_LAST" ]; then
        log "EVT ccmni inventory: [${_inv%,}] (candidates=[$(echo $_cand | tr ' ' ',')])"
        CAND_LAST=$_inv
    fi
    CW=""
    for _c in $W1_IF $_cand; do
        [ -n "$_c" ] || continue
        for _t in $PROBE_V4; do        # 轻量单目标 ICMP(不做 TCP 兜底, 保环循节奏)
            probe "$_c" "$_t" && { CW=$_c; break 2; }
        done
    done
    if [ -z "$CW" ] && [ "$CW_LAST" != "none" ]; then
        log "WARN no probe-passing ccmni this cycle (candidates=[$(echo $_cand | tr ' ' ',')])"
        CW_LAST=none
    elif [ -n "$CW" ]; then CW_LAST=$CW; fi
    if [ -n "$CW" ] && [ "$CW" != "$W1_IF" ]; then
        # v3.4: all writes under the netcfg lock; on timeout keep the old iface
        # and retry next cycle (CW still differs from W1_IF).
        if netcfg_lock 5; then
            log "5g iface moved: $W1_IF -> $CW"
            W1_IF=$CW
            ip route replace default dev $W1_IF table $T1 2>/dev/null
            # v1.4: 探活路由随活跃 ccmni 重指(netagent 漂移后可能指着死口);
            #   main 主默认由 main_primary_apply() 每周期统一完成(它用更新后的
            #   $W1_IF), 本处不写 main, 避免第二写方 —— 只保证探活路由指向新口。
            ip route del default dev $W1_IF metric 50 2>/dev/null
            ip route replace default dev $W1_IF metric $W1_PRB_METRIC 2>/dev/null
            iptables -t nat -C POSTROUTING -s $LAN_NET -o $W1_IF -j MASQUERADE 2>/dev/null || \
                iptables -t nat -A POSTROUTING -s $LAN_NET -o $W1_IF -j MASQUERADE
            iptables -C FORWARD -i br-lan -o $W1_IF -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -i br-lan -o $W1_IF -j ACCEPT
            iptables -C FORWARD -i $W1_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -i $W1_IF -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
            D1=99; U1=0   # 迫使下一轮重新评估 5G 探活
            ip -6 route replace default dev $W1_IF table $T1 2>/dev/null
            netcfg_unlock
        else
            log "WARN netcfg lock timeout: 5g iface move (retry next cycle)"
        fi
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
    # v2.9: 权重/模式在线热更 — GUI(api.sh agg_weights/agg_mode)写 /data/gw/agg.conf,
    # 本守护每周期重读, 值变即记日志并重装(状态迁移不再用旧权重打回);
    # 校验/钳位归 lib.agg_conf_load(v3.0 收敛, 原三处重复)
    if [ -r /data/gw/agg.conf ] && [ "$AGG_ON" = 1 ]; then
        OW1=$W1_PCT; OMODE=$MODE
        agg_conf_load
        if [ "$MODE" != "$OMODE" ]; then          # v2.18: 模式热切
            log "mode hot-reload: $OMODE -> $MODE (pmode=$PMODE)"
            FORCE=1
        fi
        if [ "$W1_PCT" != "$OW1" ]; then
            log "weights hot-reload: $OW1/$((100-OW1)) -> $W1_PCT/$W2_PCT"
            # v2.18: pmode 由 MODE 驱动(模式热切已在上面处理); 权重只影响分流比例
            if [ "$MODE" = weight ]; then
                FORCE=1    # 重建 sport 分界
            else
                kernel_apply $S1 $S2 2>>$LOG
            fi
        fi
    fi
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
    # v2.24: 读取 authd 会话信号(每环循) — 新鲜度: up<=45s(重询问周期30s+余量),
    # down<=60s(authd 30s 重试循环持续刷新); 过期视为无信号
    AS=""; AST=0
    if [ -r /tmp/authd_state ]; then
        set -- $(cat /tmp/authd_state 2>/dev/null)
        case "$1" in up|down) AS=$1; AST=${2:-0} ;; esac
    fi
    ASAGE=$(( $(date +%s) - AST ))
    AUTHD_UP=0; AUTHD_DOWN=0
    [ "$AS" = up ] && [ $ASAGE -le 45 ] && AUTHD_UP=1
    [ "$AS" = down ] && [ $ASAGE -le 60 ] && AUTHD_DOWN=1
    # v3.2: 认证会话信号边沿留痕(up/down 切换是家宽判活的协议级证据)
    if [ "$AS" != "$AS_LAST" ]; then
        log "EVT authd signal ${AS_LAST:-none} -> ${AS:-none} (age=${ASAGE}s up=$AUTHD_UP down=$AUTHD_DOWN)"
        AS_LAST=$AS
    fi
    # 信号过期: 状态文件在但已不新鲜(认证程序可能卡死/未刷新)
    [ -n "$AS" ] && [ "$AUTHD_UP$AUTHD_DOWN" = "00" ] && [ $((CYC % 10)) -eq 0 ] && \
        log "WARN authd signal stale: state=$AS age=${ASAGE}s (>45/60s)"
    if w1_alive; then P1R=$PRB_RES; U1=$((U1+1)); D1=0; W1_OK=$(date +%s); else P1R=$PRB_RES; D1=$((D1+1)); U1=0; fi
    if w2_alive; then P2R=$PRB_RES; U2=$((U2+1)); D2=0; W2_OK=$(date +%s); else P2R=$PRB_RES; D2=$((D2+1)); U2=0; fi
    # v2.27: 首败同轮复核 — 家宽首败立即复探, 再败即确认(D2=3)。背景(2026-10-11
    #   实弹): 上游交换机 EAP 重启窗口内"载波在/数据死"最长 25s(硬截止)才转移,
    #   LAN 探测流量漏出 eth0 被上游拦截页 302 → 手机把 SSID 标"需要认证"转投
    #   移动网络。3 击×最坏 6s 探测≈20s+ 窗口; 复核后 2 击≈一个环循(≤8s)收敛,
    #   单包丢失在复探中自愈不误切。authd 会话重启(交换机 EAP restart)由此
    #   最快 ~5s 摘除 eth0 出口。
    if [ $S2 -eq 1 ] && [ $D2 -eq 1 ]; then
        if w2_alive; then P2R=$PRB_RES; U2=$((U2+1)); D2=0; W2_OK=$(date +%s); else P2R=$PRB_RES; D2=3; fi
    fi
    now=$(date +%s)
    NS1=$S1; NS2=$S2
    # v2.20: 硬截止判死 — 活侧距上次成功探活 >25s 即判死, 跳过3连击(计数制可被
    #   迟滞/饥饿模式饿死; 时间截止不可, 故障转移上界 = 60s + 一个环循周期)
    [ $S1 -eq 1 ] && [ $((now - W1_OK)) -gt 25 ] && {
        log "EVT hard-deadline w1: last success $((now - W1_OK))s ago (>25s) probe=[$P1R]"
        NS1=0; D1=99; }
    [ $S2 -eq 1 ] && [ $((now - W2_OK)) -gt 25 ] && {
        log "EVT hard-deadline w2: last success $((now - W2_OK))s ago (>25s) probe=[$P2R]"
        NS2=0; D2=99; }
    # v2.24: authd 明示 down => 协议级判死(跳过连击) — 服务器踢会话的 Failure
    # 信号零延迟, 故障转移上界压缩到一个环循周期(<=3s)
    [ "$AUTHD_DOWN" = 1 ] && [ $S2 -eq 1 ] && {
        log "EVT authd-down -> w2 immediate dead (age=${ASAGE}s)"
        NS2=0; D2=99; }
    # v2.0: 确定性信号瞬时降级 — 无载波/无IP是"确定"而非"疑似"(重租约窗口被hash到
    #       家宽的新流全灭=恢复期粗糙窗口的根因), 跳过3连击立即全量切5G
    W2_READY=0; W2_CAR=$(cat /sys/class/net/$W2_IF/carrier 2>/dev/null)
    W2_IP=$(ip -o -4 addr show $W2_IF 2>/dev/null | awk '{print $4}' | head -1)
    [ "$W2_CAR" = "1" ] && [ -n "$W2_IP" ] && W2_READY=1
    if [ "$W2_READY" != "$W2R_LAST" ]; then
        log "EVT w2 ready $W2R_LAST -> $W2_READY (carrier=${W2_CAR:-?} ip=${W2_IP:-none})"
        W2R_LAST=$W2_READY
    fi
    if [ $S2 -eq 1 ] && [ $W2_READY -eq 0 ]; then
        log "EVT w2 deterministic-dead: carrier=${W2_CAR:-?} ip=${W2_IP:-none}"
        NS2=0; D2=99
    fi
    # 3 连续判死/判活 (原厂 brokenHeartCount 同款节奏, 5s 周期 -> ~15s 收敛)
    [ $S1 -eq 1 ] && [ $D1 -ge 3 ] && NS1=0
    # v2.23: 恢复迟滞 U>=6 — 死亡快(25s 硬截止)恢复慢(持续通过), 掐灭抖动源
    [ $S1 -eq 0 ] && [ $U1 -ge 6 ] && NS1=1
    [ $S2 -eq 1 ] && [ $D2 -ge 3 ] && NS2=0
    [ $S2 -eq 0 ] && [ $U2 -ge 6 ] && NS2=1
    # v2.12: 主备模式注入有效态 — 待命侧恒为逻辑down(NS 仅用于真实生死判定),
    # 主力死(E主力=0)时待命侧 NS 值透传 -> 全量接班; 主力恢复 -> 待命侧归零回切
    E1=$NS1; E2=$NS2
    if [ "$PMODE" = 3 ]; then E1=0; E2=1          # v2.18 仅以太: 5G 逻辑死, 家宽恒活(无failover)
    elif [ "$PMODE" = 4 ]; then E1=1; E2=0        # v2.18 仅蜂窝: 家宽逻辑死, 5G 恒活(无failover)
    elif [ "$PMODE" = 1 ] && [ $NS1 -eq 1 ]; then E2=0
    elif [ "$PMODE" = 2 ] && [ $NS2 -eq 1 ]; then E1=0
    fi
    # v2.31: 未打标主路(v4+v6)每周期按"模式+权重+真实存活"复位 —— 唯一写方,
    #   与上面 E1/E2(标记/分流用)解耦: 标记面仍由模式决定经 fwmark 分流, 未打标
    #   面则统一走本函数推导的主路, 两侧地址族一致。
    main_primary_apply "$(prim_want "$NS1" "$NS2")"
    # v2.32: 发布判活结论 —— 本进程是**数据面判活的唯一权威**(每环循实测),
    #   led_mgr(WAN 灯)与 api.sh(状态页)消费本文件, 不再各自用一套判据
    #   (2026-10-16 宵断实弹: 三处共用错判据 → 灯/状态页/转移全部谎报)。
    #   消费方须校验 ts 新鲜度, 过期回退自身探测。
    echo "home=$NS2 cell=$NS1 ts=$(date +%s)" > /tmp/wan_alive
    # v3.2: 探活结果边沿 + 每 10 环循(~30s)汇总 — 24h 分析的主时间线
    if [ "$P1R" != "$P1R_LAST" ] || [ "$P2R" != "$P2R_LAST" ]; then
        log "EVT probe w1[$W1_IF]=[$P1R] alive=$NS1 | w2[$W2_IF]=[$P2R] alive=$NS2"
        P1R_LAST=$P1R; P2R_LAST=$P2R
    fi
    if [ $((CYC % 10)) -eq 0 ]; then
        log "TICK epoch=$now cyc=$CYC loop=$((now - T0))s s=$S1/$S2 ns=$NS1/$NS2 d=$D1/$D2 u=$U1/$U2 authd=${AS:-none}/${ASAGE}s w2rdy=$W2_READY car=${W2_CAR:-?} ip=${W2_IP:-none} cw=${CW:-none} prim=${P_LAST:-none} mode=$MODE w1=$W1_PCT agg=$AGG_ON eng=$ENGINE slp=$SLP"
        log "TICK probe w1=[$P1R] w2=[$P2R] cand=[$(echo $_cand | tr ' ' ',')]"
    fi
    if [ "$AGG_ON" = 1 ] && { [ "$E1$E2" != "$S1$S2" ] || [ "${FORCE:-0}" = 1 ]; }; then
        FORCE=0
        if netcfg_lock 5; then
        log "state: 5g $S1->$E1 (d1=$D1) home $S2->$E2 (d2=$D2) pmode=$PMODE probe1=[$P1R] probe2=[$P2R] authd=${AS:-none}/${ASAGE}s w2rdy=$W2_READY"
        kernel_apply $E1 $E2 2>>$LOG   # vendor 引擎下即生效; iptables 引擎下无害空写
        if [ "$ENGINE" = iptables ]; then
            if [ $E1 -eq 1 ] && [ $E2 -eq 1 ]; then fw_setup $W2_PCT
            elif [ $E2 -eq 0 ]; then fw_setup 0
            else fw_setup 100; fi
            # v2.5: conntrack二进制损坏(relocation) conntrack -D 从未生效, 已移除
            #       死调用 — 断而必破由下方fwmark摘除承担
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
            # v2.31: main 表主默认不在此写 —— 由 main_primary_apply() 每周期按
            # "模式+权重+真实存活"统一维护(唯一写方, level-driven)。
        else
            ip rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
            ip -6 rule add fwmark $W1_MARK/$W_MASK table $T1 priority 101 2>/dev/null
            ip -6 rule del fwmark $M6_LOW1/0xff table $T1 2>/dev/null
            ip -6 rule add fwmark $M6_LOW1/0xff table $T1 priority 90 2>/dev/null
        fi
        S1=$E1; S2=$E2
        echo "agg:$S1:$S2" > $MODE_FILE
        netcfg_unlock
        else
            log "WARN netcfg lock timeout: agg transition (retry next cycle)"
            FORCE=1
        fi
    fi
    # v2.22: 自适应节奏 — 任一侧有失败记录时加快环循(死亡确认提速)
    SLP=3   # v2.24: authd-up 免 ping 使健康环循变廉, 基础节奏 5s->3s
    [ $D1 -gt 0 ] || [ $D2 -gt 0 ] && SLP=2
    sleep $SLP
done
