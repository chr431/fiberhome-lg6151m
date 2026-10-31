#!/bin/sh
# cfg_heal.sh v1.1 -- 配置漂移自愈器 (docs/SELF_HEALING_AUDIT.md §4 G2 闭环; R4.1/R3)
#
# == 为什么需要它(缺口, 注入实测 C01/C02/C03/L01) ==
# 本项目自愈体系很完整 —— 守护死了会被拉起 —— 但**配置类的东西被外力删掉后没有任何
# 重建路径**: 删一条 NAT MASQUERADE 客户端就永久断网; 删 mangle WANAGG 的 MARK 分流
# 静默失效(所有新流回落 main 表); 删 br-lan 成员口 LAN 端口直接失联。watchdog 对这类
# 漂移只 set_state FAIL + 记日志, 不重建 -> 只能人工重启, 直接判死「30 天无人干预」。
#
# == 本脚本的职责边界(铁律: 不搞第二套配置逻辑) ==
# 只做两件事: **发现漂移** + **调度既有施加器重建**。规则文本一律不在本文件出现。
#   * 聚合/NAT/FORWARD 面 -> sh /data/gw/wan_agg.sh --reapply
#       由 wan_agg 用它自己的状态(FSM 变量/agg.conf)重装, 本脚本只提供触发。
#   * 端口映射/WAN 纵深封禁面 -> sh /data/gw/fw_apply.sh apply (既有幂等 CLI)
#   * br-lan 成员口 -> brctl addif (rc19/wifi_up/watchdog/usb_mgr 共用的原语)
#   * 期望值常量一律 source wan_agg_lib.sh / svc_lib.sh, 不抄写。
#
# == 时间预算(硬约束: 宿主 fast_watch 用 timeout -s KILL 3 同步调用 --tick) ==
#   --tick 只做**廉价检测**: 一拍 6 个外部命令(实测 23ms/fork @load12 -> 约 250-350ms),
#   正常态直接退出(<0.4s, 3s 预算的 1/8)。**修复永不在 --tick 内同步执行**:
#   跨拍 2-of-2 确认后把修复交给**后台单实例 worker**(--repair), --tick 立即返回。
#   这样即使施加器要 8s, 也不会被宿主的 3s 硬超时打断(打断=半装状态, 比不修更糟)。
#   修复上界: 5s(首拍) + 5s(确认) + 施加器(<2s) = 约 12s, 远在 60s 契约内。
#
# == 锁论证(AGENTS 陷阱表「netcfg 写锁被长持 -> 全写方超时」) ==
# 本脚本**从不获取 netcfg 写锁**:
#   1) wan_agg --reapply / fw_apply apply 是**独立进程**, 各自按既有纪律持锁,
#      临界区 <1s 且不在锁内 spawn 长驻子进程(目录租约结构上不可被继承, netlock v1.5);
#   2) brctl addif 在仓库内历来不加锁(rc19/wifi_up/watchdog/usb_mgr 同款);
#   3) 修复前先读 netcfg_busy, 有人在写就跳过本轮(下一拍重试), 不与施加器抢;
#   4) 施加器子进程有硬超时(mto; 设备无 timeout 命令), 卡死即 kill -9;
#      即便它滞留在锁内, netlock 的 60s TTL + pid 死亡立即回收是第二道兜底。
# 结论: 结构上不可能重现"锁被长持 -> 全写方超时"。实测见 docs/CFG_HEAL.md §4。
#
# == 不误伤(第一原则; 误判把正常配置反复重建 = 比原问题更大的不稳定) ==
#   1) 期望值只来自权威发布方, 不来自本脚本判断:
#        聚合态 = /tmp/wan_mode(wan_agg 每环循发布) + /tmp/wan_engine(引擎类型);
#        新鲜度 = svc_lib.wa_age() —— wan_agg 心跳 >30s 就不信它的状态, 交给 watchdog。
#        反例演练 D7: 把 /tmp/wan_mode 置陈旧 -> 本脚本**必须不动手**。
#   2) **跨拍 2-of-2**: 第 N 拍只记"疑似"(写 pending + 落一条 suspect 台账), 第 N+1 拍
#      仍然缺才动手; 两拍间隔 >=4s。正常态首拍即通过(零额外开销); 漂移态 +5s。
#      这同时免疫 wan_agg 迁移窗口(fw_setup 的 -D/-F/-X/-N 序列, 亚秒级)。
#   3) **只增不删**: 只补缺失, 永不删除任何人的规则(删是施加器的事)。
#   4) 节流: 同类 60s 冷却 + 每类 3 次/1h 预算; 超预算只告警不重建(宁可红不抖)。
#   5) 开机 240s 内不动作(rc19/rc_netfh 自己会装; 抢跑=双写)。
#   6) 不越界: ra0/rai0 在 wifi_up 运行中或 hostapd 恢复后 120s 内不判(与 wifi_guard
#      同款让步); rndis0 一律不判 —— usb_mgr 独占, 它按 USB_ENABLED 主动增删。
#
# == 挂载(不新增长驻守护) ==
#   fast_watch.sh v1.5 每 5 拍(5s): "$BB" timeout -s KILL 3 sh "$D/cfg_heal.sh" --tick
#   (state-truth 已合入; watchdog 不再加调用点 —— 避免双调用点)
#
# == 台账 ==
#   /data/gw/logs/cfg_heal.tsv : ts kind item action result dur_ms  (**正常态 0 行**)
#   /tmp/cfg_heal.beat         : uptime 心跳(证明 tick 在跑, 不污染台账)
#   /tmp/cfg_heal.cnt          : passes/detects/repairs 计数(30min 不误伤证明用)
#   修复同时调 netcfg_repair "cfg_heal:<kind>" -> netcfg_repairs.tsv, 由 incident_ledger
#   既有输入源 5 消费入 incidents(单次=netcfg_repair, 窗口内 >10 次=netcfg_storm)。
#
# usage: cfg_heal.sh [--tick|--once|--check|--status|--json|--selftest|--help]
#   --tick     宿主节拍用(廉价/非阻塞/跨拍确认); 唯一被 fast_watch 调用的入口
#   --once     同步跑完整一轮(手工/演练; 进程内 2s 复核, 修复在本进程内完成)
#   --check    只检测不修; 有漂移 exit 1; 输出 "DRIFT kind item detail"
#   --repair   内部用: 后台修复 worker(单实例), 参数为待修漂移串
#   --status   人读快照   --json 机器可读   --selftest 纯逻辑自检
GWDATA=/data/gw
LOG=/tmp/cfg_heal.log
LED=/data/gw/logs/cfg_heal.tsv
LASTF=/tmp/cfg_heal.last
CNTF=/tmp/cfg_heal.cnt
RLF=/tmp/cfg_heal.rl
STAMP=/tmp/cfg_heal.stamp
BEAT=/tmp/cfg_heal.beat
PENDF=/tmp/cfg_heal.pending
RPID=/tmp/cfg_heal.repair.pid
RLSPAM=/tmp/cfg_heal.rlspam
SUSF=/tmp/cfg_heal.suspect.stamp
OBSF=/tmp/cfg_heal.obs.stamp
CFG_HEAL_IVL=4
CFG_HEAL_CONFIRM=4
CFG_HEAL_BOOT=240
CFG_HEAL_CD=60
CFG_HEAL_BUDGET=3
CFG_HEAL_APTO=8
CFG_HEAL_WANFRESH=30
MAXL=400

# ---- 库(先 source 再定义自己的 log/LOG: wan_agg_lib 会覆盖这两个符号) ----
NETLOCK_OK=1
if [ -r $GWDATA/netlock.sh ]; then . $GWDATA/netlock.sh; else
    NETLOCK_OK=0; netcfg_busy() { return 1; }; netcfg_repair() { :; }
fi
SVCLIB_OK=1
if [ -r $GWDATA/svc_lib.sh ]; then . $GWDATA/svc_lib.sh; else SVCLIB_OK=0; fi
LIB_OK=1
if [ -r $GWDATA/wan_agg_lib.sh ]; then . $GWDATA/wan_agg_lib.sh; else LIB_OK=0; fi
# wan_agg_lib 定义了 log()/LOG -> 此处重新归属到本脚本
LOG=/tmp/cfg_heal.log
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> $LOG; }
log_rot() {
    [ -s $LOG ] && [ "$(wc -l < $LOG 2>/dev/null || echo 0)" -gt $MAXL ] && \
        { tail -n $((MAXL/2)) $LOG > $LOG.tmp && mv $LOG.tmp $LOG; }
}
IPB=$IP
[ -n "$IPB" ] || IPB=ip
UP_NOW=$(cut -d. -f1 /proc/uptime)
SELF=$0
case "$SELF" in /*) ;; *) SELF=/data/gw/cfg_heal.sh ;; esac
up_ms() {
    _c=$(cut -d' ' -f1 /proc/uptime | cut -d. -f2 | cut -c1-2)
    _c=$(printf '%s' "$_c" | sed 's/^0*//')
    [ -n "$_c" ] || _c=0
    echo $((_c * 10))
}

# /tmp 跨重启可能留残值(rc.extend v3.5 实证: /tmp 非 tmpfs, ntp_synced/wan_alive 等会跨 boot
#   残留)。本脚本把 uptime 存进 /tmp 做节流/预算/跨拍确认 —— 重启后这些值**大于**当前 uptime,
#   若不清理会导致: tick 永久节流 / 同类永久冷却 / 预算永久耗尽 = 自愈器"开机即瘫"。
#   统一入口: 任何读出的 uptime 若 >= 当前值, 一律当 0(无效)。
san_up() {
    case "$1" in ''|*[!0-9]*) echo 0; return ;; esac
    if [ "$1" -lt "$UP_NOW" ]; then echo "$1"; else echo 0; fi
}

# ---------------- 纯逻辑(可自检; 全部只读) ----------------
# /tmp/wan_mode 内容 -> "S1 S2"; 空=旁路/未知
agg_ss() {
    case "$1" in
        agg:[01]:[01])
            printf '%s %s\n' "$(printf '%s' "$1" | cut -d: -f2)" \
                             "$(printf '%s' "$1" | cut -d: -f3)" ;;
        *) : ;;
    esac
}
# $1=ip rule 全文 $2=mark $3=mask $4=table -> 0=在
rule_present() {
    case "$1" in *"fwmark $2/$3 lookup $4"*) return 0 ;; esac
    return 1
}
# $1=iptables -t nat -S 全文 $2=出接口 $3=LAN 网段 -> 0=在
nat_present() {
    case "$1" in *"-A POSTROUTING -s $3 -o $2 -j MASQUERADE"*) return 0 ;; esac
    return 1
}
# $1=iptables -S 全文 $2=入接口 $3=出接口 -> 0=转发放行在
fwd_ok() {
    case "$1" in
        *"-A FORWARD -i $2 -o $3 -m state --state RELATED,ESTABLISHED -j ACCEPT"*) return 0 ;;
        *"-A FORWARD -i $2 -o $3 -j ACCEPT"*) return 0 ;;
    esac
    return 1
}
# $1=iptables -t mangle -S **WANAGG**(链内) $2=iptables -t mangle -S(整表, 仅用于查跳转)
#   0=分流链结构完整(链/跳转/打标/存标四件)
#   两次实弹教训:
#   1) watchdog 的 "grep -q MARK" 会把只剩 CONNMARK --save-mark 的残链判成绿 -> 本判据要求四件齐全;
#   2) 本脚本 v1.0 曾用**整表**文本查打标, 而本机 mangle 表里有厂商 QoS 链(qos_Default*)
#      满载 --set-xmark -> 删掉 WANAGG 的打标后仍判绿(演练 D2 实弹 00:51 抓出)。
#      v1.1 起打标/存标/链存在性一律只看 **WANAGG 链内**文本, 跳转才看整表。
split_ok() {
    case "$1" in *"-N WANAGG"*) ;; *) return 1 ;; esac
    case "$1" in
        *"--set-xmark"*) ;;
        *"--set-mark"*) ;;
        *) return 1 ;;
    esac
    case "$1" in *"CONNMARK --save-mark"*) ;; *) return 1 ;; esac
    case "$2" in *"-A PREROUTING -i br-lan -j WANAGG"*) return 0 ;; esac
    return 1
}
# $1=已用次数 $2=窗口起点 $3=now -> 0=预算内
budget_ok() {
    case "$1$2" in ''|*[!0-9]*) return 0 ;; esac
    [ $(( $3 - $2 )) -ge 3600 ] && return 0
    [ "$1" -lt "$CFG_HEAL_BUDGET" ]
}
# $1=集合串 $2=子集串 -> 0 表示 $2 的每一项都在 $1 里
is_subset() {
    for _x in $2; do
        case " $1 " in *" $_x "*) ;; *) return 1 ;; esac
    done
    return 0
}

# ---------------- 台账 ----------------
cnt_bump() { # $1=passes|detects|repairs
    _p=0; _d=0; _r=0
    [ -r $CNTF ] && read _p _d _r < $CNTF
    case "$_p" in ''|*[!0-9]*) _p=0 ;; esac
    case "$_d" in ''|*[!0-9]*) _d=0 ;; esac
    case "$_r" in ''|*[!0-9]*) _r=0 ;; esac
    case "$1" in
        passes)  _p=$((_p + 1)) ;;
        detects) _d=$((_d + 1)) ;;
        repairs) _r=$((_r + 1)) ;;
    esac
    printf '%s %s %s\n' "$_p" "$_d" "$_r" > $CNTF
}
ledger() { # $1=kind $2=item $3=action $4=result $5=dur_ms
    _ts=$(date +%s); _pre=""
    { [ ! -s /tmp/ntp_synced ] || [ "$_ts" -lt 1735689600 ]; } 2>/dev/null && _pre=" pre=1"
    _dm=$5
    case "$_dm" in ''|*[!0-9]*) _dm=0 ;; esac
    _f=$LED
    [ -d /data/gw/logs ] || _f=/tmp/cfg_heal.tsv
    printf '%s\t%s\t%s\t%s\t%s\t%s%s\n' "$_ts" "$1" "$2" "$3" "$4" "$_dm" "$_pre" >> "$_f" 2>/dev/null
    _n=$(wc -l < "$_f" 2>/dev/null || echo 0)
    if [ "$_n" -gt 4000 ]; then
        tail -n 2000 "$_f" > "$_f.tmp" 2>/dev/null && mv "$_f.tmp" "$_f"
    fi
}
# 并入 incidents: 走既有 netcfg_repairs.tsv 契约(incident_ledger 输入源 5)
nl_ledger() { # $1=kind $2=rc $3=verified
    [ "$NETLOCK_OK" = 1 ] || return 0
    netcfg_repair "cfg_heal:$1" "$2" "$3"
}

# ---------------- 施加器(全部是既有件; 本文件不含任何规则文本) ----------------
# 硬超时封装(设备无 timeout 命令; 同 ccmni_up.sh mto 配方)
mto() { # $1=秒 $2..=命令
    _to=$1; shift
    "$@" >/tmp/cfg_heal.out.$$ 2>&1 &
    _p=$!
    _i=0
    while [ "$_i" -lt "$_to" ] && kill -0 $_p 2>/dev/null; do sleep 1; _i=$((_i+1)); done
    if kill -0 $_p 2>/dev/null; then
        kill -9 $_p 2>/dev/null
        rm -f /tmp/cfg_heal.out.$$
        log "WARN applier timeout $_to s: $*"
        return 124
    fi
    wait $_p; _rc=$?
    cat /tmp/cfg_heal.out.$$ 2>/dev/null
    rm -f /tmp/cfg_heal.out.$$
    return $_rc
}
wan_reapply_ok() { # wan_agg.sh 是否提供 --reapply(探针; 没打补丁就降级为 escalate)
    [ -r $GWDATA/wan_agg.sh ] || return 1
    grep -q -- '--reapply)' $GWDATA/wan_agg.sh 2>/dev/null
}

# ---------------- 快照(每拍 6 个外部命令, 之后全 shell 匹配, 不逐条 -C) ----------------
snap() {
    IPR=$($IPB rule show 2>/dev/null)
    NAT_S=$(iptables -t nat -S 2>/dev/null)
    FLT_S=$(iptables -S 2>/dev/null)
    MGL_S=$(iptables -t mangle -S 2>/dev/null)
    MGLW_S=$(iptables -t mangle -S WANAGG 2>/dev/null)
    BR_S=$(brctl show br-lan 2>/dev/null)
    ADR_S=$($IPB -o -4 addr show 2>/dev/null)
    WAN_MODE=$(cat /tmp/wan_mode 2>/dev/null)
    WAN_ENG=$(cat /tmp/wan_engine 2>/dev/null)
    BR_MEM=$(printf '%s\n' "$BR_S" | awk 'NR>1 && NF {printf "%s ", $NF}')
    CCMNI=$(printf '%s\n' "$ADR_S" | awk '/ccmni/ && / inet / {print $2}' | sort -u | tr '\n' ' ')
    case "$BR_MEM" in ''|' ') BR_MEM="" ;; esac
}
br_has() { case " $BR_MEM " in *" $1 "*) return 0 ;; esac; return 1; }

# ---------------- 检测 ----------------
detect() {
    DET=""; OBS=""
    SS=$(agg_ss "$WAN_MODE")
    S1=$(printf '%s' "$SS" | cut -d' ' -f1)
    S2=$(printf '%s' "$SS" | cut -d' ' -f2)
    AGG_ON=0
    [ -n "$SS" ] && AGG_ON=1
    WFRESH=1
    if [ "$SVCLIB_OK" = 1 ]; then
        _wa=$(wa_age 2>/dev/null)
        case "$_wa" in ''|*[!0-9]*) _wa=999999 ;; esac
        [ "$_wa" -le "$CFG_HEAL_WANFRESH" ] || WFRESH=0
    else
        WFRESH=0
    fi

    # --- 1) NAT/FORWARD: 每个带 v4 的 ccmni + eth0 ---
    #     不依赖 wan_agg 新鲜度: NAT 是 per-if 的, 与分流状态无关。
    if [ "$LIB_OK" = 1 ]; then
        for _if in $CCMNI; do
            nat_present "$NAT_S" "$_if" "$LAN_NET" || DET="$DET nat:$_if"
            fwd_ok "$FLT_S" br-lan "$_if" || DET="$DET fwd:$_if"
            fwd_ok "$FLT_S" "$_if" br-lan || DET="$DET fwd:$_if"
        done
        if [ -d /sys/class/net/eth0 ]; then
            nat_present "$NAT_S" eth0 "$LAN_NET" || DET="$DET nat:eth0"
            fwd_ok "$FLT_S" br-lan eth0 || DET="$DET fwd:eth0"
            fwd_ok "$FLT_S" eth0 br-lan || DET="$DET fwd:eth0"
        fi
    fi

    # --- 2) 聚合分流面(mangle WANAGG + fwmark 策略规则) ---
    #     三重闸门: 聚合开 + iptables 引擎 + wan_agg 状态新鲜。
    #     vendor 引擎下 mangle 链**本来就不装**(wan_agg 只在 ENGINE=iptables 调 fw_setup),
    #     旁路模式(ENABLE=0)下链**应该被拆**, wan_agg 状态陈旧时**不许猜** ——
    #     三种情况都不得判漂移(误判=双引擎对打/在死状态上乱装)。
    if [ "$AGG_ON" = 1 ] && [ "$WAN_ENG" = iptables ] && [ "$WFRESH" = 1 ] && [ "$LIB_OK" = 1 ]; then
        split_ok "$MGLW_S" "$MGL_S" || DET="$DET split:wanagg"
        [ "$S1" = 1 ] && { rule_present "$IPR" "$W1_MARK" "$W_MASK" "$T1" || DET="$DET mark:w1"; }
        [ "$S2" = 1 ] && { rule_present "$IPR" "$W2_MARK" "$W_MASK" "$T2" || DET="$DET mark:w2"; }
    fi

    # --- 3) br-lan 成员口(只补 eth1/ra0/rai0; rndis0 归 usb_mgr, eth0 是 WAN) ---
    if [ -n "$BR_MEM" ]; then
        [ -d /sys/class/net/eth1 ] && { br_has eth1 || DET="$DET br:eth1"; }
        if ! pgrep -f 'wifi_up[.]sh' >/dev/null 2>&1; then
            _hr=0
            if grep -q 'recover hostapd' /tmp/watchdog.log 2>/dev/null; then
                _ml=$(stat -c %Y /tmp/watchdog.log 2>/dev/null || echo 0)
                [ $(( $(date +%s) - _ml )) -lt 120 ] && _hr=1
            fi
            if [ "$_hr" = 0 ]; then
                for _w in ra0 rai0; do
                    [ -d /sys/class/net/$_w ] && { br_has $_w || DET="$DET br:$_w"; }
                done
            fi
        fi
    fi

    # --- 4) 防火墙纵深面(fw_apply 的 WAN 守卫链/跳转) ---
    if [ -d /sys/class/net/eth0 ]; then
        case "$NAT_S" in *"-N V3FWD"*) ;; *) DET="$DET fw:v3fwd" ;; esac
        case "$FLT_S" in *"-A FORWARD -i eth0 -j V4WANGUARDF"*) ;; *) DET="$DET fw:wanguardf-eth0" ;; esac
        case "$FLT_S" in *"-A FORWARD -i ccmni+ -j V4WANGUARDF"*) ;; *) DET="$DET fw:wanguardf-ccmni" ;; esac
        case "$FLT_S" in *"-A INPUT -i eth0 -j V3WANGUARD"*) ;; *) DET="$DET fw:wanguard-eth0" ;; esac
        case "$FLT_S" in *"-A INPUT -i ccmni+ -j V3WANGUARD"*) ;; *) DET="$DET fw:wanguard-ccmni" ;; esac
    fi

    # --- 5) 只观测不修(dnsmasq 关键运行配置) ---
    #     重启 dnsmasq 属 watchdog 的职责, 本脚本不越界; 但漂移必须可见。
    # 归一: DET/OBS 由 "DET=\"$DET x\"" 累加而成, 首个元素带前导空格。而 pending 用
    #   "read _pu _pd" 读回(IFS 会把连续空白折叠), 带前导空格的 DET 与读回的 _pd 永不相等
    #   -> 跨拍确认永远不成立(2026-11-01 02:04 演练 D7 实弹抓出: 60s 内只反复记 SUSPECT)。
    #   这里统一去掉前导空格, 让"写入/读回"两种表示一致。
    [ -n "$DET" ] && DET=$(printf '%s' "$DET" | sed 's/^ *//')
    [ -n "$OBS" ] && OBS=$(printf '%s' "$OBS" | sed 's/^ *//')

    _dp=$(pidof dnsmasq 2>/dev/null | cut -d' ' -f1)
    if [ -n "$_dp" ] && [ -r /proc/$_dp/cmdline ]; then
        _cl=$(tr '\0' ' ' < /proc/$_dp/cmdline 2>/dev/null)
        case "$_cl" in *"-i br-lan"*) ;; *) OBS="$OBS dnsmasq:iface" ;; esac
    fi
}

# ---------------- 节流 ----------------
rl_get() { # $1=kind -> "up count win"
    [ -r $RLF ] || { echo "0 0 0"; return; }
    _l=$(grep -m1 "^$1 " $RLF 2>/dev/null)
    if [ -n "$_l" ]; then printf '%s\n' "$_l" | cut -d' ' -f2- ; else echo "0 0 0"; fi
}
rl_put() { # $1=kind $2=up $3=count $4=win
    if [ -r $RLF ]; then grep -v "^$1 " $RLF > $RLF.tmp 2>/dev/null; else : > $RLF.tmp; fi
    echo "$1 $2 $3 $4" >> $RLF.tmp
    mv $RLF.tmp $RLF 2>/dev/null
}
# 0=允许修复; 1=冷却中; 2=预算耗尽
rl_check() { # $1=kind
    _r=$(rl_get "$1")
    _lu=$(san_up "$(printf '%s' "$_r" | cut -d' ' -f1)")
    _ct=$(printf '%s' "$_r" | cut -d' ' -f2)
    _wn=$(san_up "$(printf '%s' "$_r" | cut -d' ' -f3)")
    case "$_ct" in ''|*[!0-9]*) _ct=0 ;; esac
    if [ "$_lu" -gt 0 ] && [ $(( UP_NOW - _lu )) -lt "$CFG_HEAL_CD" ]; then return 1; fi
    budget_ok "$_ct" "$_wn" "$UP_NOW" || return 2
    return 0
}
rl_record() { # $1=kind
    _r=$(rl_get "$1")
    _lu=$(san_up "$(printf '%s' "$_r" | cut -d' ' -f1)")
    _ct=$(printf '%s' "$_r" | cut -d' ' -f2)
    _wn=$(san_up "$(printf '%s' "$_r" | cut -d' ' -f3)")
    case "$_ct" in ''|*[!0-9]*) _ct=0 ;; esac
    [ $(( UP_NOW - _wn )) -ge 3600 ] && { _ct=0; _wn=$UP_NOW; }
    [ "$_wn" = 0 ] && _wn=$UP_NOW
    rl_put "$1" "$UP_NOW" $((_ct + 1)) "$_wn"
}

# 漂移串 -> 涉及哪几类施加器(agg|fw|br)
kinds_of() {
    _k=""
    for _d in $1; do
        case "$_d" in
            nat:*|fwd:*|split:*|mark:*)
                case " $_k " in *" agg "*) ;; *) _k="$_k agg" ;; esac ;;
            fw:*)
                case " $_k " in *" fw "*) ;; *) _k="$_k fw" ;; esac ;;
            br:*)
                case " $_k " in *" br "*) ;; *) _k="$_k br" ;; esac ;;
        esac
    done
    printf '%s' "$_k"
}
# 至少一类还在预算内/不在冷却 -> 0(值得 spawn worker)
rl_any_allowed() {
    for _k in $(kinds_of "$1"); do
        rl_check "$_k"
        [ "$?" = 0 ] && return 0
    done
    return 1
}

# ---------------- 修复 ----------------
do_repair() { # $1=已确认的漂移串
    _need_wan=0; _need_fw=0; _brs=""
    for _d in $1; do
        case "$_d" in
            nat:*|fwd:*|split:*|mark:*) _need_wan=1 ;;
            fw:*)  _need_fw=1 ;;
            br:*)  _brs="$_brs $(printf '%s' "$_d" | cut -d: -f2)" ;;
        esac
    done

    # (a) 聚合/NAT/FORWARD 面 -> wan_agg --reapply
    if [ "$_need_wan" = 1 ]; then
        _t0=$(up_ms)
        if ! wan_reapply_ok; then
            _dur=$(( $(up_ms) - _t0 ))
            ledger agg wan_agg escalate no_applier "$_dur"
            nl_ledger agg 1 '?'
            log "FAIL drift agg/nat: wan_agg.sh has no --reapply - escalate only"
            _esc="$_esc agg"
        else
            rl_check agg; _rc_ok=$?
            if [ "$_rc_ok" = 1 ]; then
                ledger agg wan_agg skip cooldown "$(( $(up_ms) - _t0 ))"
            elif [ "$_rc_ok" = 2 ]; then
                ledger agg wan_agg escalate budget "$(( $(up_ms) - _t0 ))"
                nl_ledger agg 1 '?'
                log "WARN agg repair budget exhausted (3/h) - alert only"
                _esc="$_esc agg"
            else
                rl_record agg
                mto "$CFG_HEAL_APTO" sh $GWDATA/wan_agg.sh --reapply >/dev/null 2>&1
                _arc=$?
                _dur=$(( $(up_ms) - _t0 ))
                snap; detect
                _left=""
                for _d in $DET; do
                    case "$_d" in nat:*|fwd:*|split:*|mark:*) _left="$_left $_d" ;; esac
                done
                if [ -z "$_left" ]; then
                    ledger agg wan_agg repair ok "$_dur"
                    nl_ledger agg "$_arc" ok
                    cnt_bump repairs
                    log "REPAIR agg/nat via wan_agg --reapply rc=$_arc dur=$_dur ms"
                else
                    ledger agg wan_agg repair fail "$_dur"
                    nl_ledger agg "$_arc" fail
                    log "FAIL agg/nat repair rc=$_arc dur=$_dur ms still=[$_left]"
                    _esc="$_esc agg"
                fi
            fi
        fi
    fi

    # (b) 防火墙纵深面 -> fw_apply.sh apply (既有幂等 CLI, 自带锁)
    if [ "$_need_fw" = 1 ]; then
        _t0=$(up_ms)
        rl_check fw; _rc_ok=$?
        if [ "$_rc_ok" = 1 ]; then
            ledger fw fw_apply skip cooldown "$(( $(up_ms) - _t0 ))"
        elif [ "$_rc_ok" = 2 ]; then
            ledger fw fw_apply escalate budget "$(( $(up_ms) - _t0 ))"
            nl_ledger fw 1 '?'
            log "WARN fw repair budget exhausted - alert only"
            _esc="$_esc fw"
        else
            rl_record fw
            mto "$CFG_HEAL_APTO" sh $GWDATA/fw_apply.sh apply >/dev/null 2>&1
            _arc=$?
            _dur=$(( $(up_ms) - _t0 ))
            snap; detect
            _left=""
            for _d in $DET; do case "$_d" in fw:*) _left="$_left $_d" ;; esac; done
            if [ -z "$_left" ]; then
                ledger fw fw_apply repair ok "$_dur"
                nl_ledger fw "$_arc" ok
                cnt_bump repairs
                log "REPAIR fw guard via fw_apply.sh apply rc=$_arc dur=$_dur ms"
            else
                ledger fw fw_apply repair fail "$_dur"
                nl_ledger fw "$_arc" fail
                log "FAIL fw repair rc=$_arc dur=$_dur ms still=[$_left]"
                _esc="$_esc fw"
            fi
        fi
    fi

    # (c) br-lan 成员口 -> brctl addif (仓库共用原语, 历来不加 netcfg 锁)
    if [ -n "$_brs" ]; then
        _t0=$(up_ms)
        rl_check br; _rc_ok=$?
        if [ "$_rc_ok" = 1 ]; then
            ledger br bridge skip cooldown "$(( $(up_ms) - _t0 ))"
        elif [ "$_rc_ok" = 2 ]; then
            ledger br bridge escalate budget "$(( $(up_ms) - _t0 ))"
            nl_ledger br 1 '?'
            log "WARN br repair budget exhausted - alert only"
            _esc="$_esc br"
        else
            rl_record br
            _brl=""
            for _b in $_brs; do
                case "$_b" in eth1|ra0|rai0) ;; *) continue ;; esac
                brctl addif br-lan "$_b" 2>/dev/null
                _brl="$_brl $_b"
            done
            _dur=$(( $(up_ms) - _t0 ))
            snap
            _left=""
            for _b in $_brl; do br_has "$_b" || _left="$_left $_b"; done
            if [ -z "$_left" ]; then
                ledger br bridge repair ok "$_dur"
                nl_ledger br 0 ok
                cnt_bump repairs
                log "REPAIR br-lan members:$_brl dur=$_dur ms"
            else
                ledger br bridge repair fail "$_dur"
                nl_ledger br 1 fail
                log "FAIL br-lan repair still missing:[$_left]"
                _esc="$_esc br"
            fi
        fi
    fi
}

# ---------------- 观测类(只记不改) ----------------
emit_obs() { # 只观测项: 每 300s 最多记一行(否则 5s 一拍会把台账刷满)
    [ -n "$OBS" ] || return 0
    _now=$(date +%s); _ls=$(cat $OBSF 2>/dev/null)
    case "$_ls" in ''|*[!0-9]*) _ls=0 ;; esac
    [ $(( _now - _ls )) -lt 300 ] && return 0
    echo "$_now" > $OBSF
    for _o in $OBS; do
        _ok=$(printf '%s' "$_o" | cut -d: -f1)
        _oi=$(printf '%s' "$_o" | cut -d: -f2)
        ledger "$_ok" "$_oi" observe drift 0
        log "OBS drift $_o (observe-only; owner=watchdog)"
    done
}

# ---------------- --tick: 廉价/非阻塞/跨拍 2-of-2 ----------------
tick() {
    log_rot
    if [ "$UP_NOW" -lt "$CFG_HEAL_BOOT" ]; then
        printf '%s\n' "$(date +%s) skip boot up=$UP_NOW s" > $LASTF
        return 0
    fi
    if [ "$LIB_OK" != 1 ]; then
        printf '%s\n' "$(date +%s) skip nolib" > $LASTF
        return 0
    fi
    echo "$UP_NOW" > $BEAT
    cnt_bump passes
    snap; detect
    emit_obs

    if [ -z "$DET" ]; then
        [ -s $PENDF ] && { log "EVT drift cleared before confirm: [$(cat $PENDF)]"; rm -f $PENDF; }
        printf '%s\n' "$(date +%s) ok drift=0" > $LASTF
        return 0
    fi

    if worker_running; then
        printf '%s\n' "$(date +%s) drift=[$DET] worker=running" > $LASTF
        return 0
    fi

    _pu=0; _pd=""
    [ -s $PENDF ] && read _pu _pd < $PENDF
    _pu=$(san_up "$_pu")
    if [ "$_pu" -gt 0 ] && [ "$_pd" = "$DET" ] && [ $(( UP_NOW - _pu )) -ge "$CFG_HEAL_CONFIRM" ]; then
        rm -f $PENDF
        cnt_bump detects
        # 节流中(冷却/预算耗尽)不 spawn worker, 否则会每 5s 空转一次 -> 日志风暴
        if ! rl_any_allowed "$DET"; then
            _now=$(date +%s); _ls=$(cat $RLSPAM 2>/dev/null)
            case "$_ls" in ''|*[!0-9]*) _ls=0 ;; esac
            if [ $(( _now - _ls )) -ge 60 ]; then
                echo "$_now" > $RLSPAM
                ledger misc "$(printf '%s' "$DET" | tr ' ' ',')" escalate throttled 0
                log "THROTTLED drift [$DET] (cooldown/budget) - worker not spawned"
            fi
            printf '%s\n' "$(date +%s) throttled [$DET]" > $LASTF
            return 0
        fi
        log "DETECT confirmed drift [$DET] (suspect_age=$(( UP_NOW - _pu ))s) -> spawn repair worker"
        printf '%s\n' "$(date +%s) confirmed [$DET] worker=spawned" > $LASTF
        nohup sh "$SELF" --repair "$DET" >>/tmp/cfg_heal.worker.log 2>&1 &
        return 0
    fi

    echo "$UP_NOW $DET" > $PENDF
    _now=$(date +%s); _ls=$(cat $SUSF 2>/dev/null)
    case "$_ls" in ''|*[!0-9]*) _ls=0 ;; esac
    if [ $(( _now - _ls )) -ge 60 ]; then
        echo "$_now" > $SUSF
        ledger misc "$(printf '%s' "$DET" | tr ' ' ',')" observe suspect 0
        log "SUSPECT drift [$DET] (first seen, will re-check next tick)"
    fi
    printf '%s\n' "$(date +%s) suspect [$DET]" > $LASTF
    return 0
}

# ---------------- --once: 同步完整一轮(手工/演练) ----------------
once() {
    log_rot
    if [ "$UP_NOW" -lt "$CFG_HEAL_BOOT" ]; then
        printf '%s\n' "$(date +%s) skip boot up=$UP_NOW s" > $LASTF
        return 0
    fi
    if [ "$LIB_OK" != 1 ]; then
        printf '%s\n' "$(date +%s) skip nolib" > $LASTF
        return 0
    fi
    echo "$UP_NOW" > $BEAT
    cnt_bump passes
    snap; detect
    emit_obs
    if [ -z "$DET" ]; then
        rm -f $PENDF
        printf '%s\n' "$(date +%s) ok drift=0" > $LASTF
        return 0
    fi
    sleep 2
    _first=$DET
    snap; detect
    _D=""
    for _d in $_first; do
        case " $DET " in *" $_d "*) _D="$_D $_d" ;; esac
    done
    _D=$(printf '%s' "$_D" | sed 's/^ *//')
    if [ -z "$_D" ]; then
        rm -f $PENDF
        printf '%s\n' "$(date +%s) ok drift=transient first=[$_first]" > $LASTF
        log "EVT transient drift cleared on recheck: [$_first]"
        return 0
    fi
    cnt_bump detects
    rm -f $PENDF
    # 手工/演练路径是**一次性**的, 没有"下一拍重试", 因此对锁忙做 3 次有界重试
    # (--tick 路径相反: 立刻跳过, 由下一拍重试, 绝不等待)
    if [ "$NETLOCK_OK" = 1 ]; then
        _try=0
        while [ "$_try" -lt 3 ] && netcfg_busy; do sleep 1; _try=$((_try + 1)); done
        if netcfg_busy; then
            log "SKIP repair: netcfg write lock busy after $_try s (holder=$(netcfg_holders 2>/dev/null))"
            ledger misc netlock skip busy 0
            printf '%s\n' "$(date +%s) drift=[$_D] skip=netlock-busy" > $LASTF
            return 0
        fi
    fi
    log "DETECT drift [$_D] (sync --once)"
    do_repair "$_D"
    printf '%s\n' "$(date +%s) repaired [$_D] escalate=[$_esc]" > $LASTF
    return 0
}

# ---------------- 后台修复 worker(单实例; 不占宿主 3s 预算) ----------------
worker_running() {
    _p=$(cat $RPID 2>/dev/null)
    case "$_p" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$_p" 2>/dev/null || return 1
    tr '\0' ' ' < /proc/$_p/cmdline 2>/dev/null | grep -q 'cfg_heal' || return 1
    return 0
}
worker() { # $1=待修漂移串
    if worker_running; then log "worker: already running ($(cat $RPID 2>/dev/null)) - exit"; exit 0; fi
    echo $$ > $RPID
    trap 'rm -f $RPID' EXIT INT TERM
    UP_NOW=$(cut -d. -f1 /proc/uptime)
    _want=$1
    snap; detect
    _D=""
    for _d in $_want; do
        case " $DET " in *" $_d "*) _D="$_D $_d" ;; esac
    done
    _D=$(printf '%s' "$_D" | sed 's/^ *//')
    if [ -z "$_D" ]; then
        ledger misc "$(printf '%s' "$_want" | tr ' ' ',')" delegated already_ok 0
        log "worker: [$_want] already restored by someone else (delegated)"
        exit 0
    fi
    if [ "$NETLOCK_OK" = 1 ] && netcfg_busy; then
        log "worker: netcfg busy - skip this round (next tick retries)"
        ledger misc netlock skip busy 0
        exit 0
    fi
    log "worker: repairing [$_D]"
    do_repair "$_D"
    printf '%s\n' "$(date +%s) repaired [$_D] escalate=[$_esc]" > $LASTF
    exit 0
}

# ---------------- 自检(纯逻辑, 不碰设备配置) ----------------
selftest() {
    _f=0
    _t() {
        if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3 (want=[$1] got=[$2])"; _f=$((_f+1)); fi
    }
    _t "0 1"   "$(agg_ss agg:0:1)"        "agg_ss valid"
    _t ""      "$(agg_ss off)"            "agg_ss bypass"
    _t ""      "$(agg_ss agg:1:x)"        "agg_ss invalid"
    _t ""      "$(agg_ss '')"             "agg_ss empty"
    _S='0:	from all lookup local
102:	from all fwmark 0x8000000/0xfc000000 lookup 200'
    rule_present "$_S" 0x8000000 0xfc000000 200; _t 0 $? "rule_present hit"
    rule_present "$_S" 0x4000000 0xfc000000 100; _t 1 $? "rule_present miss"
    _N='-P POSTROUTING ACCEPT
-A POSTROUTING -s 192.168.9.0/24 -o ccmni2 -j MASQUERADE'
    nat_present "$_N" ccmni2 192.168.9.0/24; _t 0 $? "nat_present hit"
    nat_present "$_N" eth0   192.168.9.0/24; _t 1 $? "nat_present miss"
    _F='-A FORWARD -i br-lan -o eth0 -j ACCEPT
-A FORWARD -i ccmni2 -o br-lan -m state --state RELATED,ESTABLISHED -j ACCEPT'
    fwd_ok "$_F" br-lan eth0;   _t 0 $? "fwd_ok direct"
    fwd_ok "$_F" ccmni2 br-lan; _t 0 $? "fwd_ok state"
    fwd_ok "$_F" eth0 br-lan;   _t 1 $? "fwd_ok miss"
    _M='-N WANAGG
-A WANAGG -j CONNMARK --save-mark --nfmask 0xfc000000
-A WANAGG -m conntrack --ctstate NEW -m mark --mark 0x0/0xfc000000 -j MARK --set-xmark 0x8000000/0xfc000000
-A PREROUTING -i br-lan -j WANAGG'
    split_ok "$_M" "$_M"; _t 0 $? "split_ok complete"
    split_ok '-N WANAGG
-A WANAGG -j CONNMARK --save-mark
-A PREROUTING -i br-lan -j WANAGG' '-N WANAGG
-A WANAGG -j CONNMARK --save-mark
-A PREROUTING -i br-lan -j WANAGG'; _t 1 $? "split_ok no-mark (watchdog grep -q MARK 会漏判)"
    split_ok '-N WANAGG
-A WANAGG -j MARK --set-xmark 0x8000000/0xfc000000
-A PREROUTING -i br-lan -j WANAGG' '-N WANAGG
-A WANAGG -j MARK --set-xmark 0x8000000/0xfc000000
-A PREROUTING -i br-lan -j WANAGG'; _t 1 $? "split_ok no-connmark"
    split_ok '-N WANAGG
-A WANAGG -j MARK --set-xmark 0x8000000/0xfc000000
-A WANAGG -j CONNMARK --save-mark' '-N WANAGG
-A WANAGG -j MARK --set-xmark 0x8000000/0xfc000000
-A WANAGG -j CONNMARK --save-mark'; _t 1 $? "split_ok no-jump"
    budget_ok 0 0 1000;      _t 0 $? "budget fresh"
    budget_ok 3 500 1000;    _t 1 $? "budget exhausted"
    budget_ok 3 0 4000;      _t 0 $? "budget window rolled"
    # 跨重启残值: 存下来的 uptime 若 >= 当前 uptime 必须判无效(否则开机即瘫)
    _t 0 "$(san_up "")"                         "san_up empty"
    _t 0 "$(san_up "abc")"                      "san_up nonnum"
    _t 0 "$(san_up $((UP_NOW + 5000)))"         "san_up from-future (stale across reboot)"
    _t $((UP_NOW - 100)) "$(san_up $((UP_NOW - 100)))" "san_up valid"
    is_subset "nat:eth0 br:eth1" "br:eth1";  _t 0 $? "is_subset yes"
    is_subset "nat:eth0" "br:eth1";          _t 1 $? "is_subset no"
    is_subset "nat:eth0 br:eth1" "";         _t 0 $? "is_subset empty"
    echo "---- selftest: failures=$_f"
    [ "$_f" = 0 ] && return 0 || return 1
}

status() {
    snap
    _wa='?'
    [ "$SVCLIB_OK" = 1 ] && _wa=$(wa_age)
    _bt='-'
    [ -r $BEAT ] && _bt=$(( $(cut -d. -f1 /proc/uptime) - $(cat $BEAT) ))
    printf 'wan_mode=[%s] engine=[%s] wan_age=%s s beat_age=%s s\n' "$WAN_MODE" "$WAN_ENG" "$_wa" "$_bt"
    printf 'ccmni_v4=[%s]\n' "$CCMNI"
    printf 'br-lan members=[%s]\n' "$BR_MEM"
    printf 'wan_agg --reapply: %s\n' "$(wan_reapply_ok && echo yes || echo NO)"
    printf 'pending=[%s] worker=%s\n' "$(cat $PENDF 2>/dev/null)" "$(worker_running && echo running || echo idle)"
    [ -r $CNTF ] && printf 'counters(passes detects repairs)=[%s]\n' "$(cat $CNTF)"
    [ -r $LASTF ] && printf 'last=[%s]\n' "$(cat $LASTF)"
    if [ -r $LED ]; then printf 'ledger rows=%s last3:\n%s\n' "$(wc -l < $LED)" "$(tail -n 3 $LED)"; fi
    detect
    printf 'detect_now=[%s] observe=[%s]\n' "$DET" "$OBS"
}

# ---------------- 入口 ----------------
MODE=$1
[ -n "$MODE" ] || MODE=--tick
case "$MODE" in
--selftest) selftest; exit $? ;;
--status)   status; exit 0 ;;
--json)
    snap; detect
    printf '{"ts":%s,"up":%s,"wan_mode":"%s","engine":"%s","drift":"%s","observe":"%s","worker":"%s"}\n' \
        "$(date +%s)" "$UP_NOW" "$WAN_MODE" "$WAN_ENG" \
        "$(printf '%s' "$DET" | tr ' ' ',')" "$(printf '%s' "$OBS" | tr ' ' ',')" \
        "$(worker_running && echo running || echo idle)"
    exit 0 ;;
--check)
    if [ "$UP_NOW" -lt "$CFG_HEAL_BOOT" ]; then echo "SKIP boot up=$UP_NOW"; exit 0; fi
    snap; detect
    if [ -z "$DET" ]; then echo "OK drift=0"; exit 0; fi
    for _d in $DET; do
        printf 'DRIFT %s %s %s\n' "$(printf '%s' "$_d" | cut -d: -f1)" \
            "$(printf '%s' "$_d" | cut -d: -f2)" missing
    done
    exit 1 ;;
--once)   once; exit 0 ;;
--repair) worker "$2"; exit 0 ;;
--tick)
    _last=$(san_up "$(cat $STAMP 2>/dev/null)")
    if [ $(( UP_NOW - _last )) -lt "$CFG_HEAL_IVL" ]; then exit 0; fi
    echo "$UP_NOW" > $STAMP
    tick; exit 0 ;;
--help|*)
    sed -n '2,50p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac
