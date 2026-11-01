#!/bin/sh
# incident_ledger.sh v1.3 -- 统一事故台账（M1 / R1.1–R1.6 + R2-D + R4-C）
#   v1.3 (2026-11-01 R4-C 轮): ① **svc_outages.tsv 真格式并入**（12 列）+ **多探针去重**
#     （同一次中断 dns/tcp80 各成段 → 按时间窗合并成一条台账行，否则 SEV 统计被放大数倍）；
#     ② 尊重 excluded/excl_reason（演练/维护/计划重启/上游断网：仍入账但标 excluded）；
#     ③ evidence 证据链透传；④ 修 IFS 空字段塌陷（连续 TAB 让 read 变量左移）；
#     ⑤ R1.2 映射修正：cfg_heal:* 的 netcfg_repair 落 SEV2；
#     ⑥ 新增 --selftest-svcout（4 段 → 3 行、合并时长、excluded 透传、时长→SEV 重算）。
#   v1.1 (2026-11-01 R2-D): ① NE 消费改按**字段数形态**分类（碎片/旧格式/当前格式），
#     碎片只计数不入账且 status 暴露形态分布；② 新增输入源 10 = aee db_history
#     （KE 权威台账 —— 内核致命错误后设备直接复位，syslog/dmesg 常无文本痕迹，
#     2026-11-01 02:55 那次非计划重启就是 KE，旧版只记了 reboot_unplanned 没记 KE）；
#     ③ 新增 --selftest-ne（7 形态断言）。
#
# 目的：把散落在十余个文件里的事故证据，收敛成**统一、分级、可证明留存**的
#   事故台账 /data/gw/logs/incidents.tsv。本脚本只做「归一到行」，不发明判据：
#   每个来源都是既有台账/日志（watchdog 迁移行、ne_events、reboots、boot 台账、
#   netcfg 修复、可用性边缘/迁移、syslog 的 KE/OOM 行），见下方「输入源」。
#
# 设计要点（与 RELIABILITY_SPEC §M1 逐条对应）
#   R1.1 统一台账：8 列，前 7 列即合同字段，第 8 列 seq 是**单调序号**（行身份）。
#        列序固定：ts / severity / category / component / duration / evidence_ref
#                  / detail / seq
#   R1.2 分级单点：sev_of() 是唯一实现，映射表驱动，--classify / --selftest 可单测。
#   R1.3 分级留存：SEV3 TTL 7d / SEV2 TTL 30d / SEV1 **永不自动删除**；本脚本
#        只按策略裁剪(prune)，每次裁剪在 seal 里留痕(op=prune + 逐级计数)。
#   R1.4 留存可证明：每次追加/裁剪写 incidents.seal 一行，记
#        (rows, bytes, md5, first_seq, last_seq, 逐级条数, 最老 SEV1 行 md5)。
#        retention_audit.sh 重算并比对 —— 删行/改行/轮转掉都会 FAIL。
#   R1.5 崩溃前证据：boot 类别行记「上一次死亡原因」判定（计划/非计划/掉电/KE），
#        证据链落在 detail 里（reboots.log / boot_attempts / pstore / ne_events）。
#   R1.6 磁盘守卫：/data 低水位按 SEV3 → SEV2 顺序降级裁剪，SEV1 永不删；
#        每次动作记一条 disk_guard 自保事件。
#
# 时间纪律（项目铁律：设备无 RTC）
#   开机时钟=固件构建日，ntp_keeper 首次对时成功才写 /tmp/ntp_synced。
#   pre-sync 期间**不写任何带日期的行**（沿用 avail_sampler v1.9 判据）：
#   新行先进 .inc_pending 缓冲，首次对时后以 ts=<flush 时刻> + detail 里
#   pre_sync=1 src_ts=<原始 epoch> 补记 —— 不丢、不伪造日期。
#   ne_events.tsv 里既有 pre-sync 脏行（unsync=1 / epoch 太小）同样按 pre_sync 处理。
#
# 驱动方式：**无新守护**。log_keeper.sh v2.12 的 5min 块 fork 本脚本一次；
#   单实例锁(svc_lock)防止手工审计与 tick 并发双写。
#
# 用法：
#   sh incident_ledger.sh                     # 常规 tick（log_keeper 调用）
#   sh incident_ledger.sh --status            # 打印状态（含各源游标）
#   sh incident_ledger.sh --classify CAT COMP DUR [DETAIL]   # 打印分级（单测/演练用）
#   sh incident_ledger.sh --selftest          # 分级器表驱动单测（设备侧可跑）
#   sh incident_ledger.sh --flush-pending     # 强制补记 pre-sync 缓冲
#   sh incident_ledger.sh --prune             # 手工按留存策略裁剪（SEV1 永不删）
#
# 环境覆盖（仅供 selftest/本地演练；设备侧不设即用默认路径）
#   IL_DIR / IL_LEDGER / IL_SEAL / IL_DRYRUN / IL_NOW / IL_DATA_KB
#
# 纪律：busybox awk 只许标量（运行期数组在 1.36.1 上约 1% SIGSEGV，见
#   docs/SIGSEGV_ANALYSIS.md §11）；不使用花括号变量展开（ash 解析器分歧点，
#   见 AGENTS.md 陷阱表）；所有数值变量 case 守卫。

PATH=/data/gw/sbin:/data/gw/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
if [ -z "$TZ" ] && [ -r /etc/TZ ]; then TZ=$(cat /etc/TZ 2>/dev/null); export TZ; fi

DIR=$IL_DIR;       [ -n "$DIR" ] || DIR=/data/gw/logs
LEDGER=$IL_LEDGER; [ -n "$LEDGER" ] || LEDGER=$DIR/incidents.tsv
SEAL=$IL_SEAL;     [ -n "$SEAL" ] || SEAL=$DIR/incidents.seal
CURD=$DIR/.inc
OPENF=$DIR/.inc_open
PENDF=$DIR/.inc_pending
STATEF=$DIR/.inc_state
CNTF=$DIR/.inc_counters
STATUSF=$DIR/incident_ledger.status
DRILLF=$DIR/drills.tsv
BOOTATT=$IL_BOOTATT; [ -n "$BOOTATT" ] || BOOTATT=/data/gw/boot_attempts.tsv
LOGF=/tmp/incident_ledger.log
HB=/tmp/incident_ledger.hb
DRYRUN=$IL_DRYRUN; [ -n "$DRYRUN" ] || DRYRUN=0
LOGCUT=/data/gw/bin/logcut
BB=/data/gw/bin/busybox
[ -x "$LOGCUT" ] || LOGCUT=""
[ -x "$BB" ] || BB=""

# ---- 留存/守卫策略（合同下限 7d/1d，本项目取更严；SEV1 永不自动删） ----
TTL_SEV1=0
TTL_SEV2=30
TTL_SEV3=7
LOW_KB_T1=307200
LOW_KB_T2=204800
LOW_KB_T3=102400
MAX_ROWS=400
BACKFILL_N=150
[ -n "$IL_BACKFILL_N" ] && BACKFILL_N=$IL_BACKFILL_N
RESYNC_N=200

[ -r /data/gw/defaults.conf ] && . /data/gw/defaults.conf 2>/dev/null
[ -r /data/gw/settings.conf ] && . /data/gw/settings.conf 2>/dev/null
[ -n "$INC_TTL_SEV2" ] && TTL_SEV2=$INC_TTL_SEV2
[ -n "$INC_TTL_SEV3" ] && TTL_SEV3=$INC_TTL_SEV3
[ -n "$INC_MAX_ROWS" ] && MAX_ROWS=$INC_MAX_ROWS

UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)
case "$UP" in ''|*[!0-9]*) UP=0 ;; esac
NOW=$IL_NOW
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

il() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOGF" 2>/dev/null; }
num0() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
# 计数（handler 跑在管道子壳里，计数必须落文件）
cnt_get() { _v=$(sed -n "s/^$1=//p" "$CNTF" 2>/dev/null | tail -1); num0 "$_v"; }
cnt_set() {
    grep -v "^$1=" "$CNTF" 2>/dev/null > "$CNTF.tmp"
    printf '%s=%s
' "$1" "$2" >> "$CNTF.tmp"
    mv "$CNTF.tmp" "$CNTF"
}
cnt_add() {
    _cv=$(cnt_get "$1"); _nv=$(( _cv + $2 ))
    grep -v "^$1=" "$CNTF" 2>/dev/null > "$CNTF.tmp"
    printf '%s=%s\n' "$1" "$_nv" >> "$CNTF.tmp"
    mv "$CNTF.tmp" "$CNTF"
}

# =====================================================================
# R1.2 分级器 —— 全项目唯一实现（映射表驱动）
#   $1=category $2=component $3=duration(秒或-) $4=detail
# 合同：SEV1=KE/panic/NE/启动失败/服务中断>20s；SEV2=守护重启/中断 5-20s/
#       网络修复风暴；SEV3=degraded 迁移/一般事件
# 本项目补充映射（只会更严，不会更松）：
#   oom（内核 OOM 杀进程）=SEV1；ledger_gap（证据链断口）=SEV2；
#   非计划重启=SEV2；disk_guard tier>=2 =SEV2；clock/单次修复=SEV3
# =====================================================================
sev_of() {
    _c=$1; _dur=$3; _det=$4
    case "$_c" in
    ke_panic|oom|ne|boot_fail)  echo SEV1; return 0 ;;
    ledger_gap)                 echo SEV2; return 0 ;;
    svc_outage)
        # 2s 边缘侦测器的真实时长 —— 与 M3/R3.1 的口径同源，阈值照合同字面用
        case "$_dur" in
        ''|-) echo SEV3; return 0 ;;
        *[!0-9]*) echo SEV3; return 0 ;;
        *)  if [ "$_dur" -gt 20 ]; then echo SEV1
            elif [ "$_dur" -ge 5 ]; then echo SEV2
            else echo SEV3; fi
            return 0 ;;
        esac ;;
    svc_fail)
        # watchdog FAIL/OK 的时长分辨率只有 30s（监督周期）。合同 R1.2 的 20s 阈值
        # 建立在 M3 的 ≤1s 采样上，直接套到 30s 分辨率会把"单次探针抖动"判成 SEV1
        # （实弹：dp5g 一次丢包 = 一个 30-40s 的 FAIL 窗 = SEV1，SEV1 会瞬间被噪声
        # 淹没，而 SEV1 是要保留 90 天的最高档）。故按监督分辨率放大阈值：
        #   ≤60s（1-2 个监督周期，自愈型抖动）→ SEV3
        #   61-300s（真实降级，跨多个周期）→ SEV2
        #   >300s（长时间降级/需人工介入）→ SEV1
        # 真正的"服务中断 >20s"仍由 svc_outage(2s 边缘) 按合同字面判 SEV1。
        case "$_dur" in
        ''|-) echo SEV3; return 0 ;;
        *[!0-9]*) echo SEV3; return 0 ;;
        *)  if [ "$_dur" -gt 300 ]; then echo SEV1
            elif [ "$_dur" -gt 60 ]; then echo SEV2
            else echo SEV3; fi
            return 0 ;;
        esac ;;
    svc_restart|reboot_unplanned|netcfg_storm) echo SEV2; return 0 ;;
    netcfg_repair)
        # R1.2 映射修正（R4-C 轮，cfg-heal 提了两轮）：cfg_heal:* 是"配置被外力蒸发后
        # 自愈"，背后是真实的 NAT/路由/防火墙降级面（客户端可能已受影响），落 SEV2；
        # 其余单次修复（route/table 补装）仍按一般事件 SEV3。
        case "$_det" in
        *cfg_heal*) echo SEV2; return 0 ;;
        *) echo SEV3; return 0 ;;
        esac ;;
    degraded)
        case "$_det" in
        *level=down*) echo SEV2; return 0 ;;
        *) echo SEV3; return 0 ;;
        esac ;;
    disk_guard)
        case "$_det" in
        *tier=2*|*tier=3*) echo SEV2; return 0 ;;
        *) echo SEV3; return 0 ;;
        esac ;;
    *) echo SEV3; return 0 ;;
    esac
}

# =====================================================================
# 行生成（batch 缓冲；key 去重；seq 在 append 时统一分配）
#   batch 行：key <TAB> ts <TAB> sev <TAB> cat <TAB> comp <TAB> dur <TAB> evref <TAB> detail
#   key = cat:evref；evref 含源内行序号 → 同一来源行只产出一条事件
# =====================================================================
BATCH=/tmp/il_batch.$$
: > "$BATCH" 2>/dev/null
IL_SRC=-
IL_SRC_SEQ=0
IL_BACKFILL=0
IL_PRESYNC_MODE=0
# 注意：必须在当前 shell 里自增（用 $(src_ref) 会进子壳，计数永远停在 1）
mkref() {
    IL_SRC_SEQ=$(( IL_SRC_SEQ + 1 ))
    _ref="$IL_SRC:$IL_SRC_SEQ"
}
san() { printf '%s' "$1" | tr '\t\n\r' '   ' | head -c 300; }
san_comp() {
    _s=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9_.' '_' | head -c 40)
    [ -n "$_s" ] || _s=-
    printf '%s' "$_s"
}
# ---- 演练标记（Lead v1.2 跨流契约）---------------------------------
#   /data/gw/logs/drills.tsv 列: start_epoch  end_epoch  kind  target  owner  note
#   写入方=soak-qa（其他流演练须先报 Lead）。end_epoch=0 表示窗口未闭合
#   （视为仍在进行）。窗口内的台账行**仍要落账**（可溯源性不豁免），
#   但 detail 前置 [drill] 并带 drill=1/drill_kind/drill_owner，
#   供验收统计单列排除（可审计，不是黑箱）。
IL_DRILLS=""
# 只装载"近 2 天内仍有效"的窗口（演练窗口天然短命），并对总量封顶 —— 否则每次
# emit 都要遍历全部历史窗口，回填期会把 5min tick 拖成分钟级。
# 统一窗口判据（Lead 2026-11-01 v2，全项目一致）：
#   NF>=5 && $1 纯数字 && $2 纯数字；空行 / CR 残片 / 碎片行一律跳过，**绝不当窗口**。
#   实弹：drills.tsv 被写坏后第 1 行是 CR 残片，旧的 NF>=4 + $2+0==0 会把它当成
#   "未闭合窗口 0..∞"，于是每一行都被判成演练内（集合比目标大）。
load_drills() {
    IL_DRILLS=$(awk -F'\t' -v n="$NOW" '
        NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            s=$1+0; e=$2+0; if (e==0) e=9999999999
            if (e < n-172800) next
            printf "%s:%s:%s:%s ", s, e, $3, $5
        }' "$DRILLF" 2>/dev/null)
    _cnt=$(printf '%s' "$IL_DRILLS" | wc -w); _cnt=$(num0 "$_cnt")
    if [ "$_cnt" -gt 60 ]; then
        IL_DRILLS=$(printf '%s' "$IL_DRILLS" | tr ' ' '\n' | tail -n 60 | tr '\n' ' ')
    fi
}
drill_tag() { # $1=ts $2=detail -> detail（可能被标记）
    _dt=$1; _dd=$2
    [ -n "$IL_DRILLS" ] || { echo "$_dd"; return 0; }
    # 无 fork 的窗口判定：IFS 切分 + set --（每行每窗口 4 次 cut 会拖死回填）
    _dt_save=$_dt
    _oldifs=$IFS
    for _w in $IL_DRILLS; do
        IFS=':'
        set -- $_w
        IFS=$_oldifs
        _ws=$1; _we=$2; _wk=$3; _wo=$4
        case "$_ws$_we" in ''|*[!0-9]*) continue ;; esac
        if [ "$_dt_save" -ge "$_ws" ] && [ "$_dt_save" -le "$_we" ]; then
            echo "[drill] drill=1 drill_kind=$_wk drill_owner=$_wo $_dd"
            return 0
        fi
    done
    echo "$_dd"
}

emit() { # $1=cat $2=comp $3=dur $4=evref $5=detail [$6=ts]
    _ec=$1; _ep=$2; _ed=$3; _er=$4; _ex=$5; _ets=$6
    [ -n "$_ets" ] || _ets=$NOW
    [ -n "$_ep" ] || _ep=-
    [ -n "$_ed" ] || _ed=-
    [ -n "$_er" ] || _er=-
    _ev=$(sev_of "$_ec" "$_ep" "$_ed" "$_ex")
    # 历史回填标记：行来自源台账的历史段（非本次实时观测），诚实标注
    [ "$IL_BACKFILL" = 1 ] && _ex="backfill=1 $_ex"
    # 时钟可疑判据（项目铁律：设备无 RTC，开机时钟 = 固件构建日）：
    # ts 落在构建日 +2 天内 = 写于 NTP 首同步之前，日期不可信。
    # 实弹 2026-11-01：ne_events 有 10 行 mdscan/pfcanary 带构建日 ts(2026-09-09)，
    # 回填后把「最老 SEV1」顶成 52.6 天 —— 假留存证据，必须挡在入账前。
    if [ -n "$IL_BUILD_EPOCH" ]; then
        case "$_ets" in
        ''|*[!0-9]*) ;;
        *) if [ "$_ets" -le $(( IL_BUILD_EPOCH + 172800 )) ]; then
               _ex="pre_sync=1 src_ts=$_ets $_ex"
               _ets=$NOW
           fi ;;
        esac
    fi
    _ex=$(drill_tag "$_ets" "$_ex")
    printf '%s:%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$_ec" "$_er" "$_ets" "$_ev" "$_ec" "$_ep" "$_ed" "$_er" \
        "$(san "$_ex")" >> "$BATCH"
}

# =====================================================================
# 时间：watchdog/syslog 行只有 "MM-DD HH:MM:SS"（无年无 epoch）。
# 用同一行流里 TICK/HEALTH 的 epoch= 做锚，按秒差插值 —— 不解析日期、
# 不受时区/年份影响（跨日由 +/-3600s 回绕判据兜住）。
# =====================================================================
IL_BASE_EPOCH=""
IL_BASE_SECS=0
hms_secs() {
    _h=$(printf '%s' "$1" | cut -d: -f1)
    _m=$(printf '%s' "$1" | cut -d: -f2)
    _s=$(printf '%s' "$1" | cut -d: -f3)
    case "$_h$_m$_s" in ''|*[!0-9]*) return 1 ;; esac
    _sl=$(printf '%s' "$_s" | wc -c)
    [ "$_sl" -eq 2 ] || return 1
    # 去前导 0：POSIX 算术把 08/09 当八进制 -> "value too great for base"（实弹，
    # 2026-11-01 演练：23:08/23:09 的 watchdog 行整批时间戳退化为入账时刻）。
    while :; do case "$_h" in 0?*) _h=${_h#0} ;; *) break ;; esac; done
    while :; do case "$_m" in 0?*) _m=${_m#0} ;; *) break ;; esac; done
    while :; do case "$_s" in 0?*) _s=${_s#0} ;; *) break ;; esac; done
    [ -n "$_h" ] || _h=0
    [ -n "$_m" ] || _m=0
    [ -n "$_s" ] || _s=0
    echo $(( _h * 3600 + _m * 60 + _s ))
}
line_epoch() {
    _l=$1
    case "$_l" in
    [0-9][0-9]-[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9]\ *) ;;
    *) return 1 ;;
    esac
    _st=$(printf '%s' "$_l" | cut -d' ' -f2)
    _sec=$(hms_secs "$_st") || return 1
    if [ -n "$IL_BASE_EPOCH" ]; then
        _d=$(( _sec - IL_BASE_SECS ))
        [ "$_d" -lt -3600 ] && _d=$(( _d + 86400 ))
        [ "$_d" -gt 3600 ] && _d=$(( _d - 86400 ))
        echo $(( IL_BASE_EPOCH + _d ))
        return 0
    fi
    _md=$(printf '%s' "$_l" | cut -d' ' -f1)
    _e=$(date -d "$(date +%Y)-$_md $_st" +%s 2>/dev/null) || return 1
    case "$_e" in ''|*[!0-9]*) return 1 ;; esac
    echo "$_e"
    return 0
}

# =====================================================================
# 开链状态（FAIL 开链、OK 配对得真实时长）—— 落文件，跨 tick 有效
# =====================================================================
open_set() {
    grep -v "^$1	" "$OPENF" 2>/dev/null > "$OPENF.tmp"
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$OPENF.tmp"
    mv "$OPENF.tmp" "$OPENF"
}
open_peek() { grep "^$1	" "$OPENF" 2>/dev/null | head -1; }
open_del() { grep -v "^$1	" "$OPENF" 2>/dev/null > "$OPENF.tmp"; mv "$OPENF.tmp" "$OPENF"; }

# =====================================================================
# 输入源 1: watchdog 迁移流（持久镜像 tmp/watchdog.log）
#   FAIL <label>            → 失败开链（等 OK 配对出时长，避免半截行）
#   FAIL detail <key> ...   → 同秒键名注记（component 换成真键）
#   OK   <label> (recovered) → 配对落行 category=svc_fail duration=真实秒
#   EVT restart <svc>       → 守护重启 SEV2
#   EVT clock jump / netlock / recover hostapd → 时钟跳变 / 锁泄漏 / 守卫恢复
#   WARN aee NE +N          → 不落行（NE 口径唯一来源 = ne_events.tsv）
# =====================================================================
h_wdlog() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        mkref
        case "$L" in
        *"epoch="*)
            _e=$(printf '%s' "$L" | sed -n 's/.*epoch=\([0-9][0-9]*\).*/\1/p' | head -1)
            case "$_e" in
            ''|*[!0-9]*) ;;
            *) _st=$(printf '%s' "$L" | cut -d' ' -f2)
               _sec=$(hms_secs "$_st") && { IL_BASE_EPOCH=$_e; IL_BASE_SECS=$_sec; } ;;
            esac ;;
        esac
        _ep=$(line_epoch "$L") || _ep=$NOW
        case "$L" in
        *" FAIL detail "*)
            _k=$(printf '%s' "$L" | sed -n 's/.*FAIL detail \([A-Za-z0-9_]*\).*/\1/p')
            _last=$(tail -n 1 "$OPENF" 2>/dev/null)
            if [ -n "$_last" ] && [ -n "$_k" ]; then
                _ll=$(printf '%s' "$_last" | cut -f1)
                _lt=$(printf '%s' "$_last" | cut -f2)
                case "$_lt" in ''|*[!0-9]*) _lt=0 ;; esac
                _dd=$(( _ep - _lt )); [ "$_dd" -lt 0 ] && _dd=$(( -_dd ))
                [ "$_dd" -le 2 ] && open_set "$_ll" "$_lt" "$(san_comp "$_k")"
            fi ;;
        *" FAIL  "*)
            _lab=$(printf '%s' "$L" | sed -n 's/.* FAIL  //p')
            open_set "$(san_comp "$_lab")" "$_ep" "-" ;;
        *" OK    "*)
            _lab=$(printf '%s' "$L" | sed -n 's/.* OK    //p' | sed 's/ (recovered)$//')
            _ck=$(san_comp "$_lab")
            _o=$(open_peek "$_ck")
            if [ -n "$_o" ]; then
                _ot=$(printf '%s' "$_o" | cut -f2)
                _ok=$(printf '%s' "$_o" | cut -f3)
                case "$_ot" in ''|*[!0-9]*) _ot=$_ep ;; esac
                _dur=$(( _ep - _ot )); [ "$_dur" -lt 0 ] && _dur=0
                [ "$_ok" = "-" ] && _ok=$_ck
                emit svc_fail "$_ok" "$_dur" "$_ref" "label=$_ck degraded_s=$_dur recovered_at=$_ep" "$_ot"
                open_del "$_ck"
            fi ;;
        *"EVT restart "*)
            _svc=$(printf '%s' "$L" | sed -n 's/.*EVT restart \([A-Za-z0-9_.]*\).*/\1/p')
            [ -n "$_svc" ] || _svc=unknown
            emit svc_restart "$(san_comp "$_svc")" - "$_ref" "evt=restart raw=$(san "$L")" "$_ep" ;;
        *"EVT clock jump"*)
            emit clock - - "$_ref" "$(san "$L")" "$_ep" ;;
        *"EVT netlock broken"*)
            emit svc_restart netcfg_lock - "$_ref" "$(san "$L")" "$_ep" ;;
        *"EVT recover hostapd"*)
            emit svc_restart hostapd - "$_ref" "$(san "$L")" "$_ep" ;;
        esac
    done
}

# =====================================================================
# 输入源 2: ne_events.tsv（core_meta 链 = NE 权威台账）
#   列: ts pid comm sig=N exe=.. args=.. [unsync=1] origin=.. stack=..
#   脏行两类必须挡住（否则污染时间轴/造垃圾行）：
#     a) 物理行不以 "<数字><TAB>" 开头 —— argv 内换行造成的断行残片（实测 243 行）
#     b) ts 过小 / unsync=1 —— pre-sync 脏时钟
#   组件归属沿用 AVAILABILITY_DESIGN §2 三规则（args 含守护脚本 → 归属）
# =====================================================================
# v1.1 (R2-D 数据质量轮): 按**字段数形态**分类，不再只看"首列是不是数字"。
#   实测分布(2026-11-01, 1611 行): 1 列 230 / 2 列 13 / 6 列 285 / 7 列 1058 /
#   8 列 21 / 9 列 4。其中：
#     1~2 列 = argv 含换行的 awk/sed 脚本被 echo 直落造成的**碎片**(243 行, 历史遗留,
#              core_meta v1.12 起写入侧列数自检, 不会再产生) -> 只计数, 不进台账
#     6 列   = core_meta v1.2 之前的旧格式(无 origin/stack)          -> 合法历史行
#     7 列   = v1.2~v1.6 格式(有 origin, 无 stack)                    -> 合法历史行
#     8 列   = 当前格式
#     9 列   = 当前格式 + unsync=1 标记
#   首列必须是 epoch；不是的一律按碎片计（哪怕它恰好有 6 列）。
h_ne() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        _nf=$(printf '%s' "$L" | awk -F'\t' '{print NF}')
        _nf=$(num0 "$_nf")
        _ts=$(printf '%s' "$L" | cut -f1)
        case "$_ts" in
        ''|*[!0-9]*)
            # 首列不是 epoch -> 绝不是台账行（碎片/半写）
            cnt_add malformed_ne 1
            cnt_add bad_ne_nf$_nf 1
            continue ;;
        esac
        case "$_nf" in
        6|7|8|9) cnt_add good_ne_nf$_nf 1 ;;
        *)
            # 首列是 epoch 但列数离谱（缺列/被截断/多列）—— 同样不入账，单独计数
            cnt_add malformed_ne 1
            cnt_add bad_ne_nf$_nf 1
            continue ;;
        esac
        mkref
        _comm=$(printf '%s' "$L" | cut -f3); [ -n "$_comm" ] || _comm='?'
        _sig=$(printf '%s' "$L" | cut -f4)
        _org=$(printf '%s' "$L" | sed -n 's/.*origin=\([a-z-]*\).*/\1/p' | head -1)
        [ -n "$_org" ] || _org=unknown
        _comp=-
        case "$L" in
        *"/data/gw/led_mgr.sh"*)         _comp=led_mgr ;;
        *"/data/gw/fan_mgr.sh"*)         _comp=fan_mgr ;;
        *"/data/gw/ntp_keeper.sh"*)      _comp=ntp_keeper ;;
        *"/data/gw/dial_keeper.sh"*)     _comp=dial_keeper ;;
        *"/data/gw/wan_eth.sh"*)         _comp=wan_eth ;;
        *"/data/gw/wan_agg.sh"*)         _comp=wan_agg ;;
        *"/data/gw/log_keeper.sh"*)      _comp=log_keeper ;;
        *"/data/gw/healthdog.sh"*)       _comp=healthdog ;;
        *"/data/gw/watchdog.sh"*)        _comp=watchdog ;;
        *"/data/gw/reboot_sched.sh"*)    _comp=reboot_sched ;;
        *"/data/gw/usb_mgr.sh"*)         _comp=usb_mgr ;;
        *"/data/gw/traffic_logger.sh"*)  _comp=traffic_logger ;;
        *"/data/gw/wifi_guard.sh"*)      _comp=wifi_guard ;;
        *"/data/gw/incident_ledger.sh"*) _comp=incident_ledger ;;
        *hostapd*)                       _comp=hostapd ;;
        *dnsmasq*)                       _comp=dnsmasq ;;
        *)                               _comp=$(san_comp "$_comm") ;;
        esac
        _pre=""
        case "$L" in *unsync=1*) _pre=1 ;; esac
        [ "$_ts" -lt 1735689600 ] && _pre=1
        _det="comm=$_comm sig=$(san "$_sig") origin=$_org"
        _ts_use=$_ts
        if [ -n "$_pre" ]; then
            # pre-sync 脏时钟：ts 用入账时刻（诚实），原值留 src_ts
            _det="$_det pre_sync=1 src_ts=$_ts"
            _ts_use=$NOW
        fi
        emit ne "$_comp" - "$_ref" "$_det" "$_ts_use"
    done
}

# =====================================================================
# 输入源 3: reboots.log（计划重启；reboot_sched 先落盘再重启）
# 输入源 4: boot_attempts.tsv（rc.extend 每次开机一行 result=healthy/...）
#   R1.5：判定「上一次死亡原因」= 计划 / 非计划（boot 失败另记 SEV1）
# =====================================================================
IL_PLANNED=""
load_planned() {
    IL_PLANNED=$(tail -n 20 "$DIR/reboots.log" 2>/dev/null | while IFS= read -r L; do
        case "$L" in *REBOOT*) ;; *) continue ;; esac
        # 行首是 "YYYY-MM-DD HH:MM:SS"（含时刻！只取日期会落到午夜，
        # ±900s 匹配必然失败 -> 计划重启被误判成非计划重启）
        _dt=$(printf '%s' "$L" | cut -c1-19)
        _e=$(date -d "$_dt" +%s 2>/dev/null)
        case "$_e" in ''|*[!0-9]*) continue ;; esac
        echo "$_e"
    done | tr '\n' ' ')
}
planned_near() {
    # 计划窗 ±300s（5min）。原来是 ±900s，太宽 —— 2026-11-01 04:13 的 state-truth 维护重启
    # 被 04:00:25 的定时重启"吸"成了 death_reason=planned（实弹）。定时重启 late=0min、
    # boot_attempts 在触发后 ~30s 落行，±300s 足够覆盖正常抖动。
    _p=$1
    for _x in $IL_PLANNED; do
        _d=$(( _p - _x )); [ "$_d" -lt 0 ] && _d=$(( -_d ))
        [ "$_d" -le 300 ] && return 0
    done
    return 1
}
h_reboot() {
    while IFS= read -r L; do
        case "$L" in *REBOOT*) ;; *) continue ;; esac
        mkref
        _dt=$(printf '%s' "$L" | cut -c1-19)
        _e=$(date -d "$_dt" +%s 2>/dev/null)
        case "$_e" in ''|*[!0-9]*) _e=$NOW ;; esac
        _up=$(printf '%s' "$L" | sed -n 's/.*uptime=\([0-9]*\)s.*/\1/p' | head -1)
        _up=$(num0 "$_up")
        emit reboot_planned - "$_up" "$_ref" "scheduled target=$(printf '%s' "$L" | sed -n 's/.*target=\([0-9:]*\).*/\1/p' | head -1) uptime_s=$_up raw=$(san "$L")" "$_e"
    done
}
h_bootatt() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        case "$L" in *btime=*) ;; *) continue ;; esac
        mkref
        _e=$(printf '%s' "$L" | sed -n 's/.*epoch=\([0-9]*\).*/\1/p' | head -1)
        _e=$(num0 "$_e")
        _res=$(printf '%s' "$L" | sed -n 's/.*result=\([a-z]*\).*/\1/p' | head -1)
        _bid=$(printf '%s' "$L" | sed -n 's/.*boot_id=\([0-9a-f-]*\).*/\1/p' | head -1)
        [ -n "$_res" ] || _res=unknown
        if planned_near "$_e"; then _why=planned; else _why=unplanned; fi
        if [ "$_res" != healthy ]; then
            emit boot_fail - - "$_ref" "result=$_res death_reason=$_why boot_id=$(san "$_bid") raw=$(san "$L")" "$_e"
        elif [ "$_why" = unplanned ]; then
            # 一次开机只落一行：非计划重启（boot 健康但 reboots.log 无匹配）= SEV2
            emit reboot_unplanned - - "$_ref" "boot_ok result=$_res death_reason=unplanned (no reboots.log match +/-300s) boot_id=$(san "$_bid") epoch=$_e" "$_e"
        else
            emit boot_ok - - "$_ref" "result=$_res death_reason=planned boot_id=$(san "$_bid")" "$_e"
        fi
    done
}

# =====================================================================
# 输入源 5: netcfg_repairs.tsv（REPAIR 台账；一轮内 >10 次 = 风暴 SEV2）
#   行: epoch reason rc=N verified=X [pre=1]
# =====================================================================
h_netcfg() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        # 实测格式是**空格分隔**: "<epoch> <reason 可含空格> rc=N verified=X [pre=1]"
        # （用 cut -f1 按 TAB 取会拿到整行 -> 非数字 -> 整源静默丢光，2026-11-01 实弹）
        _norm=$(printf '%s' "$L" | tr -s ' 	' ' ')
        _e=$(printf '%s' "$_norm" | cut -d' ' -f1)
        case "$_e" in ''|*[!0-9]*) continue ;; esac
        mkref
        _why=$(printf '%s' "$_norm" | cut -d' ' -f2-)
        _pre=""
        case "$L" in *pre=1*) _pre=1 ;; esac
        cnt_add repairs_seen 1
        _n=$(cnt_get repairs_seen)
        # 风暴判据只对**实时增量**有效：回填历史时同一轮会读到上百条历史修复，
        # 那不是风暴（实弹：首轮回填把 150 条历史 REPAIR 全判成 SEV2 风暴）。
        if [ "$IL_BACKFILL" != 1 ] && [ "$_n" -gt 10 ]; then
            emit netcfg_storm netcfg - "$_ref" "repairs_in_window=$_n reason=$(san "$_why") pre=$_pre" "$_e"
        else
            emit netcfg_repair netcfg - "$_ref" "reason=$(san "$_why") pre=$_pre raw=$(san "$L")" "$_e"
        fi
    done
}

# =====================================================================
# 输入源 6: avail_edges.tsv（2s 边缘侦测器；唯一带秒级时长的来源）
#   行: epoch "YYYY-MM-DD HH:MM:SS" <id> edge_down|edge_up
#   down→up 配对得真实中断时长 → R1.2 的 5s/20s 分档就落在这里
# =====================================================================
IL_EDGE_OPEN=$DIR/.inc_edge_open
h_edges() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        # avail_edges.tsv 有**两代格式**（2026-11-01 实弹：M2 换 fast_watch 时
        # 契约从空格分隔改成管道分隔，消费方若只认一种会静默丢行）：
        #   旧: <epoch> <YYYY-MM-DD> <HH:MM:SS> <id> <edge_down|edge_up>
        #   新: <epoch>|<YYYY-MM-DDTHH:MM:SS>|<id>|<edge_down|edge_up>[|<kind>]
        # 判据 = 第 2 个字段里有没有 'T'（旧格式第 2 段是纯日期）。
        _norm=$(printf '%s' "$L" | tr -s ' 	|' ' ')
        _e=$(printf '%s' "$_norm" | cut -d' ' -f1)
        case "$_e" in ''|*[!0-9]*) continue ;; esac
        _f2=$(printf '%s' "$_norm" | cut -d' ' -f2)
        case "$_f2" in
        *T*)
            _id=$(printf '%s' "$_norm" | cut -d' ' -f3)
            _ev=$(printf '%s' "$_norm" | cut -d' ' -f4)
            _kind=$(printf '%s' "$_norm" | cut -d' ' -f5) ;;
        *)
            _id=$(printf '%s' "$_norm" | cut -d' ' -f4)
            _ev=$(printf '%s' "$_norm" | cut -d' ' -f5)
            _kind="" ;;
        esac
        [ -n "$_id" ] || continue
        _extra=""
        [ -n "$_kind" ] && _extra=" kind=$_kind"
        case "$_ev" in
        edge_down)
            grep -v "^$_id	" "$IL_EDGE_OPEN" 2>/dev/null > "$IL_EDGE_OPEN.tmp"
            printf '%s\t%s\n' "$_id" "$_e" >> "$IL_EDGE_OPEN.tmp"
            mv "$IL_EDGE_OPEN.tmp" "$IL_EDGE_OPEN" ;;
        edge_up)
            _o=$(grep "^$_id	" "$IL_EDGE_OPEN" 2>/dev/null | head -1 | cut -f2)
            case "$_o" in ''|*[!0-9]*) continue ;; esac
            mkref
            _dur=$(( _e - _o )); [ "$_dur" -lt 0 ] && _dur=0
            emit svc_outage "$(san_comp "$_id")" "$_dur" "$_ref" "probe=$_id path=edge down=$_o up=$_e$_extra" "$_e"
            grep -v "^$_id	" "$IL_EDGE_OPEN" 2>/dev/null > "$IL_EDGE_OPEN.tmp"
            mv "$IL_EDGE_OPEN.tmp" "$IL_EDGE_OPEN" ;;
        *)  continue ;;
        esac
    done
}

# =====================================================================
# 输入源 7: avail_transitions.tsv（10min 采样迁移流）
#   行: epoch comp from->to cause → ->down 记 SEV2；其余迁移 SEV3；->op 不入账
# =====================================================================
h_trans() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        _e=$(printf '%s' "$L" | cut -f1)
        case "$_e" in ''|*[!0-9]*) continue ;; esac
        _c=$(printf '%s' "$L" | cut -f2)
        _t=$(printf '%s' "$L" | cut -f3)
        _why=$(printf '%s' "$L" | cut -f4)
        case "$_t" in
        *"->op") continue ;;
        esac
        mkref
        case "$_t" in
        *"->down") emit degraded "$(san_comp "$_c")" - "$_ref" "trans=$_t cause=$(san "$_why") level=down" "$_e" ;;
        *)         emit degraded "$(san_comp "$_c")" - "$_ref" "trans=$_t cause=$(san "$_why")" "$_e" ;;
        esac
    done
}

# =====================================================================
# 输入源 8: svc_outages.tsv（M3/T3 交付后接入，R3.3 格式）
#   容错解析：能认 dur= 就用；认不出就整行入账（不丢证据、不猜字段）
# =====================================================================
# v1.3 (R4-C 轮): 真格式解析 + **多探针去重** + 尊重 excluded。
#   实测格式(svc_outage v1.0, 12 列 TAB):
#     start end dur path probe severity attrib excluded excl_reason evidence side flags
#   同一次中断在文件里会有多行(dns/tcp80 各自成段, 甚至一段拆多段) —— 必须按时间窗
#   合并成**一条台账行**, 否则 M1 的 SEV 统计会被同一故障放大数倍。
#   结算窗 SVCOUT_SETTLE: 只处理 end 已过 180s 的段 —— 保证同一次中断的各探针段
#   都已落盘、能在同一批里被合并(而不是被切成两条)。
SVCOUT_SETTLE=180
h_svcout() {
    _acc=/tmp/il_svcout.$$
    : > "$_acc"
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        case "$L" in \#*) continue ;; esac
        _s=$(printf '%s' "$L" | cut -f1); _e=$(printf '%s' "$L" | cut -f2)
        case "$_s$_e" in ''|*[!0-9]*) continue ;; esac
        [ "$_e" -le $(( NOW - SVCOUT_SETTLE )) ] || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$_s" "$_e" "$(printf '%s' "$L" | cut -f3)" "$(printf '%s' "$L" | cut -f4)" \
            "$(printf '%s' "$L" | cut -f5)" "$(printf '%s' "$L" | cut -f6)" \
            "$(printf '%s' "$L" | cut -f7)" "$(printf '%s' "$L" | cut -f8)" \
            "$(printf '%s' "$L" | cut -f9)" "$(printf '%s' "$L" | cut -f10)" >> "$_acc"
    done
    [ -s "$_acc" ] || { rm -f "$_acc"; return 0; }
    sort -n -k1,1 "$_acc" > "$_acc.s"
    awk -F'\t' -v OFS='\t' -v gap=5 '
        # 空字段必须写成 "-"：POSIX sh 的 IFS 是 TAB(空白类)，连续 TAB 会塌成一个，
        # 导致 read 的后续变量整体左移（实弹：空的 excl_reason 把 evidence 挤到了 excl_reason 位）。
        function nz(v) { return (v == "" ? "-" : v) }
        function out() { if (n > 0) printf "%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\n", cs, ce, ce-cs, nz(cpath), nz(cp), nz(csev), nz(catt), nz(cexc), csegs, nz(cxr), nz(cev) }
        {
            s = $1 + 0; e = $2 + 0
            if (n == 0) { cs = s; ce = e; cp = $5; cpath = $4; cexc = $8; catt = $7; csev = $6; csegs = 1; cxr = $9; cev = $10; n = 1; next }
            if (s <= ce + gap) {
                if (e > ce) ce = e
                if (index(cp, $5) == 0) cp = cp "+" $5
                if (index(cpath, $4) == 0) cpath = cpath "+" $4
                if ($8 != cexc) cexc = "mixed"
                if ($6 == "SEV1") csev = "SEV1"
                if (cxr == "" && $9 != "") cxr = $9
                if (cev == "" && $10 != "") cev = $10
                csegs++
                next
            }
            out()
            cs = s; ce = e; cp = $5; cpath = $4; cexc = $8; catt = $7; csev = $6; csegs = 1; cxr = $9; cev = $10
        }
        END { out() }' "$_acc.s" > "$_acc.m"
    # 跨批去重：与上一次已落账的区间重叠的，整段跳过（避免同一次中断被记两遍）
    _last=$(sed -n 's/^svcout_last=//p' "$STATEF" 2>/dev/null | head -1)
    _lstart=0; _lend=0
    case "$_last" in
    *:*) _lstart=$(printf '%s' "$_last" | cut -d: -f1); _lend=$(printf '%s' "$_last" | cut -d: -f2) ;;
    esac
    case "$_lstart$_lend" in ''|*[!0-9]*) _lstart=0; _lend=0 ;; esac
    _maxend=0
    while IFS='	' read -r _ms _me _mdur _mpath _mprobe _msev _matt _mexc _msegs _mxr _mev; do
        case "$_ms$_me" in ''|*[!0-9]*) continue ;; esac
        if [ "$_lend" -gt 0 ] && [ "$_ms" -ge "$_lstart" ] && [ "$_me" -le "$_lend" ]; then
            continue
        fi
        mkref
        _extra="probes=$_mprobe segments=$_msegs src_severity=$_msev"
        case "$_mexc" in
        1) _extra="$_extra excluded=1" ;;
        mixed) _extra="$_extra excluded=partial" ;;
        esac
        [ -n "$_matt" ] && [ "$_matt" != "-" ] && _extra="$_extra attrib=$_matt"
        [ -n "$_mxr" ] && [ "$_mxr" != "-" ] && _extra="$_extra excl_reason=$_mxr"
        [ -n "$_mev" ] && [ "$_mev" != "-" ] && _extra="$_extra evidence=$(san "$_mev")"
        emit svc_outage "$(san_comp "$_mpath")" "$_mdur" "$_ref" "$_extra" "$_ms"
        [ "$_me" -gt "$_maxend" ] && _maxend=$_me
    done < "$_acc.m"
    if [ "$_maxend" -gt 0 ] && [ "$DRYRUN" != 1 ]; then
        _firststart=$(head -1 "$_acc.m" 2>/dev/null | cut -f1)
        case "$_firststart" in ''|*[!0-9]*) _firststart=0 ;; esac
        grep -v '^svcout_last=' "$STATEF" 2>/dev/null > "$STATEF.tmp"
        printf 'svcout_last=%s:%s\n' "$_firststart" "$_maxend" >> "$STATEF.tmp" 2>/dev/null
        mv "$STATEF.tmp" "$STATEF" 2>/dev/null
    fi
    rm -f "$_acc" "$_acc.s" "$_acc.m"
}

# =====================================================================
# 输入源 10: /data/log/aee_exp/db_history（aee 自己的崩溃台账）
#   行: /data/log/aee_exp/db.fatal.NN.KE, Sat Oct 31 18:55:48 UTC 2026
#       /data/log/aee_exp/db.NN.NE,       Sun Nov  1 04:58:59 CST 2026
#   **KE 的权威来源**：内核致命错误后设备直接复位，syslog/dmesg 的持久镜像里
#   往往一个字都没有（2026-11-01 02:55 实弹：dmesg 里 0 条 panic 文本，只有 aee
#   的 db.fatal.07.KE 记着 18:55:48 UTC = 02:55:48 CST）。只靠 syslog 文本会漏 KE。
#   NE 行**只计数不落账**（NE 口径唯一来源仍是 ne_events.tsv，避免双计）。
# =====================================================================
AEEH=$IL_AEEH; [ -n "$AEEH" ] || AEEH=/data/log/aee_exp/db_history
aee_epoch() { # "... , Sat Oct 31 18:55:48 UTC 2026" -> 本地 epoch
    _d=$(printf '%s' "$1" | sed -n 's/^[^,]*,[ ]*//p')
    [ -n "$_d" ] || return 1
    _d=$(printf '%s' "$_d" | tr -s '  ' ' ')
    _mon=$(printf '%s' "$_d" | cut -d' ' -f2)
    _day=$(printf '%s' "$_d" | cut -d' ' -f3)
    _hms=$(printf '%s' "$_d" | cut -d' ' -f4)
    _tz=$(printf '%s' "$_d" | cut -d' ' -f5)
    _yr=$(printf '%s' "$_d" | cut -d' ' -f6)
    case "$_mon" in
    Jan) _m=01 ;; Feb) _m=02 ;; Mar) _m=03 ;; Apr) _m=04 ;;
    May) _m=05 ;; Jun) _m=06 ;; Jul) _m=07 ;; Aug) _m=08 ;;
    Sep) _m=09 ;; Oct) _m=10 ;; Nov) _m=11 ;; Dec) _m=12 ;;
    *) return 1 ;;
    esac
    case "$_day" in ''|*[!0-9]*) return 1 ;; esac
    _dl=$(printf '%s' "$_day" | wc -c)
    [ "$_dl" -eq 1 ] && _day=0$_day
    case "$_hms" in ''|*[!0-9:]*) return 1 ;; esac
    _e=$(date -d "$_yr-$_m-$_day $_hms" +%s 2>/dev/null) || return 1
    case "$_e" in ''|*[!0-9]*) return 1 ;; esac
    case "$_tz" in
    UTC|GMT) _e=$(( _e + 28800 )) ;;   # 设备本地 = CST(UTC+8)
    esac
    echo "$_e"
}
h_aee() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        case "$L" in
        *.KE,*) _kind=KE ;;
        *.NE,*) _kind=NE ;;
        *) continue ;;
        esac
        mkref
        _e=$(aee_epoch "$L") || _e=$NOW
        if [ "$_kind" = KE ]; then
            cnt_add aee_ke 1
            emit ke_panic - - "$_ref" "aee=$L source=aee_db_history" "$_e"
        else
            cnt_add aee_ne 1
        fi
    done
}

# =====================================================================
# 输入源 9: syslog.log（KE/panic/OOM 的持久面；4MB 轮转到 .1）
# =====================================================================
syslog_epoch() { # "Sat Oct 31 18:44:31 2026 user.err : ..." -> epoch
    # busybox date -d 不认 "EEE MMM DD HH:MM:SS YYYY"（设备实测 invalid date），
    # 必须先把月名换成数字再交给 date -d。
    _mon=$(printf '%s' "$1" | cut -c5-7)
    _dd=$(printf '%s' "$1" | cut -c9-10)
    _hms=$(printf '%s' "$1" | cut -c12-19)
    _yr=$(printf '%s' "$1" | cut -c21-24)
    case "$_mon" in
    Jan) _m=01 ;; Feb) _m=02 ;; Mar) _m=03 ;; Apr) _m=04 ;;
    May) _m=05 ;; Jun) _m=06 ;; Jul) _m=07 ;; Aug) _m=08 ;;
    Sep) _m=09 ;; Oct) _m=10 ;; Nov) _m=11 ;; Dec) _m=12 ;;
    *) return 1 ;;
    esac
    case "$_dd$_yr" in ''|*[!0-9]*) return 1 ;; esac
    _e=$(date -d "$_yr-$_m-$_dd $_hms" +%s 2>/dev/null) || return 1
    case "$_e" in ''|*[!0-9]*) return 1 ;; esac
    echo "$_e"
}
# 内核构建时刻（uname -v 里的 "Wed Sep 9 01:42:03 2026"）—— 设备无 RTC，
# 开机时钟就是这个日期；任何落在这天附近的 ts 都写于 NTP 首同步之前。
build_epoch() {
    _v=$(uname -v 2>/dev/null)
    _mon=$(printf '%s' "$_v" | sed -n 's/.* \([A-Z][a-z][a-z]\) \([0-9][0-9]*\) \([0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*\) \([0-9][0-9][0-9][0-9]\).*/\1/p')
    _dd=$(printf '%s' "$_v" | sed -n 's/.* \([A-Z][a-z][a-z]\) \([0-9][0-9]*\) \([0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*\) \([0-9][0-9][0-9][0-9]\).*/\2/p')
    _hms=$(printf '%s' "$_v" | sed -n 's/.* \([A-Z][a-z][a-z]\) \([0-9][0-9]*\) \([0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*\) \([0-9][0-9][0-9][0-9]\).*/\3/p')
    _yr=$(printf '%s' "$_v" | sed -n 's/.* \([A-Z][a-z][a-z]\) \([0-9][0-9]*\) \([0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*\) \([0-9][0-9][0-9][0-9]\).*/\4/p')
    case "$_mon" in
    Jan) _m=01 ;; Feb) _m=02 ;; Mar) _m=03 ;; Apr) _m=04 ;;
    May) _m=05 ;; Jun) _m=06 ;; Jul) _m=07 ;; Aug) _m=08 ;;
    Sep) _m=09 ;; Oct) _m=10 ;; Nov) _m=11 ;; Dec) _m=12 ;;
    *) return 1 ;;
    esac
    case "$_dd" in ''|*[!0-9]*) return 1 ;; esac
    _dl=$(printf '%s' "$_dd" | wc -c)
    [ "$_dl" -eq 1 ] && _dd=0$_dd   # 只有 1 位数才补零（2 位数补零会变成 015）
    case "$_hms" in ''|*[!0-9:]*) return 1 ;; esac
    _e=$(date -d "$_yr-$_m-$_dd $_hms" +%s 2>/dev/null) || return 1
    case "$_e" in ''|*[!0-9]*) return 1 ;; esac
    echo "$_e"
}

h_syslog() {
    while IFS= read -r L; do
        [ -n "$L" ] || continue
        case "$L" in
        *"Kernel panic"*|*"Internal error"*|*"Unable to handle kernel"*|*"kernel BUG at"*|*"Oops"*)
            mkref
            _se=$(syslog_epoch "$L") || _se=$NOW
            emit ke_panic - - "$_ref" "$(san "$L")" "$_se" ;;
        *"Out of memory: Kill"*|*"Out of memory: Killed"*)
            mkref
            _se=$(syslog_epoch "$L") || _se=$NOW
            emit oom - - "$_ref" "$(san "$L")" "$_se" ;;
        esac
    done
}

# =====================================================================
# 游标：每源一文件（第 1 行=锚行，第 2 行=累计行序号）
# =====================================================================
cur_anchor() { sed -n 1p "$CURD/$1" 2>/dev/null; }
cur_seq() { _v=$(sed -n 2p "$CURD/$1" 2>/dev/null); num0 "$_v"; }
cur_set() {
    [ "$DRYRUN" = 1 ] && return 0
    printf '%s\n%s\n' "$2" "$3" > "$CURD/$1.tmp" 2>/dev/null && mv "$CURD/$1.tmp" "$CURD/$1"
}

# ingest <name> <file> <fallback|-> <handler>
ingest() {
    _nm=$1; _f=$2; _fb=$3; _h=$4
    [ -r "$_f" ] || return 0
    _anc=$(cur_anchor "$_nm")
    _sq=$(cur_seq "$_nm")
    IL_SRC=$_nm
    IL_SRC_SEQ=$_sq
    if [ -z "$_anc" ]; then
        _bfn=$BACKFILL_N
        # 首轮全量回填 ne_events（SEV1 历史直接决定"7 天前的事故在哪"能否回答）
        if [ "$_nm" = ne ] && [ -n "$IL_BACKFILL_N_NE" ]; then _bfn=$IL_BACKFILL_N_NE; fi
        _body=$(tail -n "$_bfn" "$_f" 2>/dev/null)
        _last=$(tail -n 1 "$_f" 2>/dev/null)
        [ -n "$_body" ] || return 0
        IL_BACKFILL=1
        printf '%s\n' "$_body" | $_h
        IL_BACKFILL=0
        if [ "$IL_PRESYNC_MODE" != 1 ]; then
            append_batch
            if [ "$IL_APPENDED" -gt 0 ]; then
                seal_write append "backfill src=$_nm"
            fi
        fi
        _n=$(printf '%s\n' "$_body" | wc -l); _n=$(num0 "$_n")
        cur_set "$_nm" "$_last" $(( _sq + _n ))
        cnt_add lines_read "$_n"
        il "backfill $_nm n=$_n (cap=$_bfn)"
        return 0
    fi
    _rc=1
    _body=""
    if [ -n "$LOGCUT" ]; then
        _body=$($LOGCUT --after-last "$_anc" "$_f" 2>/dev/null); _rc=$?
    else
        # 兜底：logcut 缺失时用 grep -nxF 定位最后一个精确锚行（慢但语义相同）
        _ln=$(grep -nxF -- "$_anc" "$_f" 2>/dev/null | tail -1 | cut -d: -f1)
        case "$_ln" in
        ''|*[!0-9]*) _rc=1 ;;
        *) _body=$(tail -n +$(( _ln + 1 )) "$_f" 2>/dev/null); _rc=0 ;;
        esac
    fi
    if [ "$_rc" -ne 0 ]; then
        _got=0
        if [ "$_fb" != "-" ] && [ -r "$_fb" ] && [ -n "$LOGCUT" ]; then
            _b2=$($LOGCUT --after-last "$_anc" "$_fb" 2>/dev/null) && _got=1
            if [ "$_got" = 1 ]; then
                _body=$_b2
                _tail=$(head -c 524288 "$_f" 2>/dev/null)
                if [ -n "$_tail" ]; then
                    _body="$_body
$_tail"
                fi
            fi
        fi
        if [ "$_got" = 0 ]; then
            # 锚行彻底丢失（轮转两代都找不到）：如实记断口，从当前末尾续读。
            # 不回读历史尾部 —— 回读只会产生与已有行重复的二次入账（R1.4 要求
            # 台账只能追加、不能凭空多行），丢失范围由本条 gap 行声明。
            _body=""
            cnt_add gaps 1
            emit ledger_gap "$_nm" - "cursor" "anchor lost (rotate/truncate); resume at tail src=$_nm"
        else
            il "rotation catch-up $_nm via $_fb"
        fi
    fi
    if [ -z "$_body" ]; then
        cur_set "$_nm" "$(tail -n 1 "$_f" 2>/dev/null)" "$_sq"
        return 0
    fi
    _take=$(printf '%s\n' "$_body" | head -n "$MAX_ROWS")
    _n=$(printf '%s\n' "$_take" | wc -l); _n=$(num0 "$_n")
    printf '%s\n' "$_take" | $_h
    # 耐久性：先把本轮的行落盘并写 seal，再推进游标 —— 否则 SSH 中途断开会让
    # "游标已前移但行未落盘"的窗口丢数据（首轮回填 1359 行尤其不可接受）。
    if [ "$IL_PRESYNC_MODE" != 1 ]; then
        append_batch
        if [ "$IL_APPENDED" -gt 0 ]; then
            seal_write append "src=$_nm"
        fi
    fi
    _last=$(printf '%s\n' "$_take" | tail -n 1)
    cur_set "$_nm" "$_last" $(( _sq + _n ))
    cnt_add lines_read "$_n"
}

# =====================================================================
# 追加：去重 → 分配 seq → 写台账
# =====================================================================
IL_APPENDED=0
next_seq() {
    _l=$(tail -n 1 "$LEDGER" 2>/dev/null)
    _s=$(printf '%s' "$_l" | cut -f8)
    case "$_s" in ''|*[!0-9]*) echo 1 ;; *) echo $(( _s + 1 )) ;; esac
}
append_batch() {
    IL_APPENDED=0
    [ -s "$BATCH" ] || return 0
    _existing=/tmp/il_keys.$$
    if [ -s "$LEDGER" ]; then
        tail -n 800 "$LEDGER" 2>/dev/null | awk -F'\t' '{ print $3 ":" $6 }' > "$_existing"
    else
        : > "$_existing"
    fi
    _bkeys=/tmp/il_bkeys.$$
    cut -f1 "$BATCH" > "$_bkeys"
    if [ -s "$_existing" ]; then
        grep -vxF -f "$_existing" "$_bkeys" > "$_bkeys.new" 2>/dev/null
    else
        cp "$_bkeys" "$_bkeys.new"
    fi
    _keep=/tmp/il_keep.$$
    : > "$_keep"
    if [ -s "$_bkeys.new" ]; then
        grep -F -f "$_bkeys.new" "$BATCH" > "$_keep" 2>/dev/null
    fi
    _n=$(wc -l < "$_keep" 2>/dev/null); _n=$(num0 "$_n")
    if [ "$_n" -eq 0 ]; then
        rm -f "$_existing" "$_bkeys" "$_bkeys.new" "$_keep"
        return 0
    fi
    _sq=$(next_seq)
    _rows=/tmp/il_rows.$$
    : > "$_rows"
    while IFS= read -r R; do
        _r=$(printf '%s' "$R" | cut -f2-)
        printf '%s\t%s\n' "$_r" "$_sq" >> "$_rows"
        _sq=$(( _sq + 1 ))
    done < "$_keep"
    if [ "$DRYRUN" = 1 ]; then
        echo "--- DRYRUN batch n=$_n ---"
        cat "$_rows"
    else
        cat "$_rows" >> "$LEDGER"
    fi
    IL_APPENDED=$_n
    rm -f "$_existing" "$_bkeys" "$_bkeys.new" "$_keep" "$_rows"
    : > "$BATCH"
}

# ---- seal：每次变更留一行（R1.4 的证明载体） -------------------------
seal_write() { # $1=op $2=reason $3=rm1 $4=rm2 $5=rm3
    [ "$DRYRUN" = 1 ] && return 0
    _op=$1; _rsn=$2; _r1=$3; _r2=$4; _r3=$5
    [ -n "$_r1" ] || _r1=0
    [ -n "$_r2" ] || _r2=0
    [ -n "$_r3" ] || _r3=0
    _rows=$(wc -l < "$LEDGER" 2>/dev/null); _rows=$(num0 "$_rows")
    _bytes=$(wc -c < "$LEDGER" 2>/dev/null); _bytes=$(num0 "$_bytes")
    _md5=$(md5sum "$LEDGER" 2>/dev/null | cut -d' ' -f1); [ -n "$_md5" ] || _md5=-
    _fs=$(head -n 1 "$LEDGER" 2>/dev/null | cut -f8); case "$_fs" in ''|*[!0-9]*) _fs=- ;; esac
    _ls=$(tail -n 1 "$LEDGER" 2>/dev/null | cut -f8); case "$_ls" in ''|*[!0-9]*) _ls=- ;; esac
    _cnt=$(awk -F'\t' '$2=="SEV1"{a++} $2=="SEV2"{b++} $2=="SEV3"{c++} END{print a+0" "b+0" "c+0}' "$LEDGER" 2>/dev/null)
    _c1=$(printf '%s' "$_cnt" | cut -d' ' -f1); _c1=$(num0 "$_c1")
    _c2=$(printf '%s' "$_cnt" | cut -d' ' -f2); _c2=$(num0 "$_c2")
    _c3=$(printf '%s' "$_cnt" | cut -d' ' -f3); _c3=$(num0 "$_c3")
    _s1=$(awk -F'\t' '$2=="SEV1" { if (ln==0 || $1+0 < best+0) { best=$1+0; ln=NR } } END { if (ln==0) print "- -"; else print best" "ln }' "$LEDGER" 2>/dev/null)
    _s1ts=$(printf '%s' "$_s1" | cut -d' ' -f1)
    _s1ln=$(printf '%s' "$_s1" | cut -d' ' -f2)
    _s1md5=-
    case "$_s1ln" in
    ''|*[!0-9]*) ;;
    *) _s1md5=$(sed -n "$_s1ln"p "$LEDGER" 2>/dev/null | md5sum | cut -d' ' -f1)
       [ -n "$_s1md5" ] || _s1md5=- ;;
    esac
    # rm1/rm2/rm3 = 留存裁剪(prune/disk_guard)删除数 —— SEV1 必须恒 0（审计红线）；
    # rp1/rp2/rp3 = **修复性**删除数（去重/纠错重写，可为任意级别）—— 与裁剪分开记，
    #   否则一次合法的去重修复会被审计当成"SEV1 被裁剪"而误判 FAIL（2026-11-01 实弹）。
    _p1=$IL_RP1; [ -n "$_p1" ] || _p1=0
    _p2=$IL_RP2; [ -n "$_p2" ] || _p2=0
    _p3=$IL_RP3; [ -n "$_p3" ] || _p3=0
    printf 'op=%s ts=%s rows=%s bytes=%s md5=%s first_seq=%s last_seq=%s sev1=%s sev2=%s sev3=%s rm1=%s rm2=%s rm3=%s rp1=%s rp2=%s rp3=%s oldest_sev1_ts=%s oldest_sev1_md5=%s reason=%s\n' \
        "$_op" "$NOW" "$_rows" "$_bytes" "$_md5" "$_fs" "$_ls" "$_c1" "$_c2" "$_c3" \
        "$_r1" "$_r2" "$_r3" "$_p1" "$_p2" "$_p3" "$_s1ts" "$_s1md5" "$_rsn" >> "$SEAL"
    IL_RP1=0; IL_RP2=0; IL_RP3=0
}

# =====================================================================
# 回溯标注（--reannotate --since <epoch> [--apply]）
#   场景：drills.tsv 被重建/补写后，那些窗口内**已经 ingest** 的台账行当时没有
#   [drill] 标记（时序陷阱：补写不回溯）。本模式把当前 drills.tsv 的窗口重新套到
#   ts >= since 且尚未标记的行上：
#     · 默认 dry-run：只打印「应当被标但未标」的清单（行号/ts/category/窗口）
#     · --apply：就地重写这些行的 detail（加 [drill] drill=1 drill_kind/owner 前缀），
#       行数/seq 不变，并写一条 op=reannotate 的 seal 行（可审计、可复查）
#   纯 awk 无数组实现（busybox awk 运行期数组有 ~1% SIGSEGV，见 SIGSEGV_ANALYSIS §11）。
# =====================================================================
reannotate() { # $1=since $2=apply(1|0)
    _since=$(num0 "$1"); _apply=$2
    [ "$_since" -gt 0 ] || { echo "reannotate: need --since <epoch>"; return 2; }
    # 只装载 end >= since 的窗口（含 end=0 未闭合 → 视作到 now）
    _wl=$(awk -F'\t' -v n="$NOW" -v s="$_since" '
        NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ {
            e=$2+0; if (e==0) e=9999999999
            if (e < s) next
            printf "%s:%s:%s:%s ", $1+0, e, $3, $5
        }' "$DRILLF" 2>/dev/null)
    _nw=$(printf '%s' "$_wl" | wc -w); _nw=$(num0 "$_nw")
    echo "# reannotate since=$_since windows=$_nw apply=$_apply"
    _out=/tmp/il_reann.$$
    awk -F'\t' -v OFS='\t' -v s="$_since" -v wl="$_wl" -v ap="$_apply" '
        function winhit(ts,   rest, sp, w, c1, c2, c3, a, b, k, o, r1, r2) {
            rest = wl
            while (rest != "") {
                sp = index(rest, " "); if (sp == 0) sp = length(rest) + 1
                w = substr(rest, 1, sp - 1); rest = substr(rest, sp + 1)
                c1 = index(w, ":"); if (c1 == 0) continue
                a = substr(w, 1, c1 - 1); r1 = substr(w, c1 + 1)
                c2 = index(r1, ":"); if (c2 == 0) continue
                b = substr(r1, 1, c2 - 1); r2 = substr(r1, c2 + 1)
                c3 = index(r2, ":"); if (c3 == 0) continue
                k = substr(r2, 1, c3 - 1); o = substr(r2, c3 + 1)
                if (ts + 0 >= a + 0 && ts + 0 <= b + 0) { HK = k; HO = o; return 1 }
            }
            return 0
        }
        {
            ts = $1 + 0
            if (ts < s) { if (ap == 1) print; next }
            if (index($7, "drill=1") > 0) { if (ap == 1) print; next }
            HK = ""; HO = ""
            if (winhit(ts)) {
                if (ap == 1) { $7 = "[drill] drill=1 drill_kind=" HK " drill_owner=" HO " " $7; print }
                else { printf "%d\t%s\t%s\t%s\t%s\t%s\n", NR, $1, $3, $4, HK, HO }
            } else {
                if (ap == 1) print
            }
        }' "$LEDGER" > "$_out" 2>/dev/null
    if [ "$_apply" = 1 ]; then
        _n=$(wc -l < "$_out" 2>/dev/null); _n=$(num0 "$_n")
        _rows=$(wc -l < "$LEDGER" 2>/dev/null); _rows=$(num0 "$_rows")
        if [ "$_n" = "$_rows" ]; then
            mv "$_out" "$LEDGER"
            seal_write reannotate "since=$_since windows=$_nw" 0 0 0
            echo "# reannotate APPLIED rows=$_rows windows=$_nw (seal op=reannotate written)"
        else
            echo "# reannotate ABORT: line count mismatch in=$_rows out=$_n (no change)"
            rm -f "$_out"; return 1
        fi
    else
        cat "$_out"; rm -f "$_out"
    fi
    return 0
}

# =====================================================================
# 裁剪（R1.3 留存策略 / R1.6 磁盘守卫）—— SEV1 永不删
# =====================================================================
prune_tier() { # $1=SEVx $2=ttl_days → 打印删除行数
    [ "$1" = SEV1 ] && { echo 0; return 0; }
    _cut=$(( NOW - $2 * 86400 ))
    _hit=$(awk -F'\t' -v c="$_cut" -v s="$1" '$2==s && $1+0 < c+0' "$LEDGER" 2>/dev/null | wc -l)
    _hit=$(num0 "$_hit")
    [ "$_hit" -gt 0 ] || { echo 0; return 0; }
    [ "$DRYRUN" = 1 ] && { echo "$_hit"; return 0; }
    awk -F'\t' -v c="$_cut" -v s="$1" '!($2==s && $1+0 < c+0)' "$LEDGER" > "$LEDGER.tmp" 2>/dev/null \
        && mv "$LEDGER.tmp" "$LEDGER"
    echo "$_hit"
}
do_prune() { # $1=reason $2=tier [$3=category]
    _why=$1; _tier=$2; _cat=$3
    [ -n "$_cat" ] || _cat=disk_guard
    _r2=0; _r3=0
    case "$_tier" in
    1) _r3=$(prune_tier SEV3 "$TTL_SEV3") ;;
    2) _r3=$(prune_tier SEV3 "$TTL_SEV3")
       _r2=$(prune_tier SEV2 "$TTL_SEV2") ;;
    3) _r3=$(prune_tier SEV3 1)
       _r2=$(prune_tier SEV2 1) ;;
    esac
    _r2=$(num0 "$_r2"); _r3=$(num0 "$_r3")
    if [ $(( _r2 + _r3 )) -gt 0 ]; then
        seal_write prune "$_why" 0 "$_r2" "$_r3"
        emit "$_cat" - - "retention" "tier=$_tier reason=$_why pruned_sev2=$_r2 pruned_sev3=$_r3 pruned_sev1=0"
        il "prune tier=$_tier r2=$_r2 r3=$_r3"
    fi
}
data_free_kb() {
    # IL_DATA_KB 是**演练用**显式覆盖（优先级最高）：R1.6 的守卫触发路径必须能在
    # 不真填盘的前提下被验证（真填到 <100MB 会毁掉真证据，见 docs §10 演练记录）。
    if [ -n "$IL_DATA_KB" ]; then
        case "$IL_DATA_KB" in ''|*[!0-9]*) ;; *) echo "$IL_DATA_KB"; return 0 ;; esac
    fi
    _v=$(/data/gw/bin/busybox df -k /data 2>/dev/null | tail -1 | awk '{print $4}')
    case "$_v" in ''|*[!0-9]*) _v=999999999 ;; esac
    echo "$_v"
}
disk_guard() {
    _free=$(data_free_kb)
    IL_FREE=$_free
    [ "$_free" -ge "$LOW_KB_T1" ] && return 0
    _tier=1
    [ "$_free" -lt "$LOW_KB_T2" ] && _tier=2
    [ "$_free" -lt "$LOW_KB_T3" ] && _tier=3
    il "disk guard free_kb=$_free tier=$_tier"
    emit disk_guard - - "retention" "tier=$_tier free_kb=$_free low_t1=$LOW_KB_T1 low_t2=$LOW_KB_T2 low_t3=$LOW_KB_T3 action=prune"
    do_prune "disk_low tier=$_tier free_kb=$_free" "$_tier"
}

# =====================================================================
# pre-sync 缓冲（时间纪律）：缓冲 → 首次对时后补记
# =====================================================================
PRESYNC=0
[ -s /tmp/ntp_synced ] || PRESYNC=1
IL_PENDING=0
flush_pending() {
    [ -s "$PENDF" ] || return 0
    _n=$(wc -l < "$PENDF" 2>/dev/null); _n=$(num0 "$_n")
    [ "$_n" -gt 0 ] || return 0
    _out=/tmp/il_pend.$$
    : > "$_out"
    # 缓冲行 = key ts sev cat comp dur evref detail（8 段）。补记时必须**逐段重建**，
    # 早期版本把 f3- 整段拼上去又追加了一次 detail -> 落出 9~11 列的坏行，
    # 破坏 8 列 TSV 契约（2026-11-01 04:07 冷启动补记 14 行实弹）。
    while IFS= read -r R; do
        _k=$(printf '%s' "$R" | cut -f1)
        _ts=$(printf '%s' "$R" | cut -f2)
        _sev=$(printf '%s' "$R" | cut -f3)
        _cat=$(printf '%s' "$R" | cut -f4)
        _comp=$(printf '%s' "$R" | cut -f5)
        _dur=$(printf '%s' "$R" | cut -f6)
        _ref=$(printf '%s' "$R" | cut -f7)
        _det=$(printf '%s' "$R" | cut -f8-)
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\tpre_sync=1 src_ts=%s %s\n' \
            "$_k" "$NOW" "$_sev" "$_cat" "$_comp" "$_dur" "$_ref" "$_ts" "$_det" >> "$_out"
    done < "$PENDF"
    cat "$_out" >> "$BATCH"
    IL_PENDING=$_n
    rm -f "$_out"
    : > "$PENDF"
    il "pending flushed n=$_n"
}

# =====================================================================
# 状态文件（供 retention_audit 与 PC 侧审计读取）
# =====================================================================
write_status() {
    [ "$DRYRUN" = 1 ] && return 0
    _rows=$(wc -l < "$LEDGER" 2>/dev/null); _rows=$(num0 "$_rows")
    _bytes=$(wc -c < "$LEDGER" 2>/dev/null); _bytes=$(num0 "$_bytes")
    _open=$(wc -l < "$OPENF" 2>/dev/null | tr -d ' '); _open=$(num0 "$_open")
    {
        echo "# incident_ledger status (v1.0) -- machine readable key=value"
        echo "ts=$NOW"
        echo "uptime=$UP"
        echo "boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
        echo "presync=$PRESYNC"
        echo "build_epoch=$IL_BUILD_EPOCH"
        echo "rows=$_rows"
        echo "bytes=$_bytes"
        echo "appended=$IL_APPENDED"
        echo "lines_read=$(cnt_get lines_read)"
        echo "gaps=$(cnt_get gaps)"
        echo "malformed_ne=$(cnt_get malformed_ne)"
        echo "ne_good_nf6=$(cnt_get good_ne_nf6)"
        echo "ne_good_nf7=$(cnt_get good_ne_nf7)"
        echo "ne_good_nf8=$(cnt_get good_ne_nf8)"
        echo "ne_good_nf9=$(cnt_get good_ne_nf9)"
        echo "ne_bad_nf1=$(cnt_get bad_ne_nf1)"
        echo "ne_bad_nf2=$(cnt_get bad_ne_nf2)"
        echo "ne_bad_nf_other=$(cnt_get bad_ne_nf3)"
        echo "aee_ke=$(cnt_get aee_ke)"
        echo "aee_ne=$(cnt_get aee_ne)"
        echo "pending=$IL_PENDING"
        echo "open_episodes=$_open"
        echo "data_free_kb=$IL_FREE"
        echo "drill_windows=$(printf '%s' "$IL_DRILLS" | wc -w | tr -d ' ')"
        echo "drill_open=$(awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2+0==0' "$DRILLF" 2>/dev/null | wc -l | tr -d ' ')"
        echo "ttl_sev1=$TTL_SEV1"
        echo "ttl_sev2=$TTL_SEV2"
        echo "ttl_sev3=$TTL_SEV3"
        echo "sources=watchdog.log ne_events.tsv reboots.log boot_attempts.tsv netcfg_repairs.tsv avail_edges.tsv avail_transitions.tsv svc_outages.tsv syslog.log"
    } > "$STATUSF.tmp" 2>/dev/null && mv "$STATUSF.tmp" "$STATUSF"
}

# =====================================================================
# 单测（分级器表驱动）—— 设备侧可直接跑
# =====================================================================
selftest() {
    _bad=0; _n=0
    t() {
        _n=$((_n + 1))
        _got=$(sev_of "$2" "$3" "$4" "$5")
        if [ "$_got" != "$1" ]; then
            echo "FAIL case $_n cat=$2 dur=$4 want=$1 got=$_got"
            _bad=$((_bad + 1))
        fi
    }
    t SEV1 ke_panic - - "Kernel panic - not syncing"
    t SEV1 oom - - "Out of memory: Kill process 123"
    t SEV1 ne led_mgr - "comm=sh sig=sig=11"
    t SEV1 boot_fail - - "result=failed"
    t SEV1 svc_outage gui 21 "probe=gui"
    t SEV2 svc_outage gui 20 "probe=gui"
    t SEV2 svc_outage gui 5 "probe=gui"
    t SEV3 svc_outage gui 4 "probe=gui"
    t SEV3 svc_outage gui - "open"
    t SEV2 svc_restart led_mgr - "evt=restart"
    t SEV3 svc_fail led_mgr 30 "label=led_mgr"
    t SEV3 svc_fail led_mgr 60 "label=led_mgr"
    t SEV2 svc_fail led_mgr 61 "label=led_mgr"
    t SEV2 svc_fail led_mgr 300 "label=led_mgr"
    t SEV1 svc_fail led_mgr 301 "label=led_mgr"
    t SEV3 svc_fail led_mgr 2 "label=led_mgr"
    t SEV2 netcfg_storm netcfg - "repairs_in_window=11"
    t SEV3 netcfg_repair netcfg - "reason=route"
    t SEV2 netcfg_repair netcfg - "reason=cfg_heal:agg rc=0 verified=ok"
    t SEV3 netcfg_repair netcfg - "reason=table200 v6 default rc=0 verified=?"
    t SEV2 reboot_unplanned - - "no match"
    t SEV3 reboot_planned - 3600 "target=04:00"
    t SEV3 degraded lan.wifi2g - "trans=op->deg"
    t SEV2 degraded lan.wifi2g - "trans=op->down level=down"
    t SEV2 ledger_gap wdlog - "anchor lost"
    t SEV3 clock - - "EVT clock jump"
    t SEV3 disk_guard - - "tier=1 free_kb=290000"
    t SEV2 disk_guard - - "tier=2 free_kb=190000"
    t SEV3 unknowncat x - "whatever"
    echo "incident_ledger selftest cases=$_n failures=$_bad"
    [ "$_bad" -eq 0 ] || return 1
    selftest_ne || return 1
    selftest_drill || return 1
    selftest_svcout || return 1
    return 0
}

# svc_outages 并入单测（R4-C）：多探针同一次中断必须合并成一行；excluded 必须被尊重；
# 严重度必须按 R1.2 由**合并后的时长**重算（而不是照抄文件里的 severity 列）。
selftest_svcout() {
    _sv=/tmp/il_svcout_selftest.$$
    rm -rf "$_sv"; mkdir -p "$_sv"
    {
        printf '#svc_outage v1.0\tfields: start end dur path probe severity attrib excluded excl_reason evidence side flags\n'
        # 同一次中断：dns 83s + tcp80 90s（重叠）→ 必须合并成 1 行，dur=90
        printf '1793460000\t1793460083\t83\tgw\tdns\tSEV1\tdrill\t1\tdrill\tdrills:1-2\tdev\t\n'
        printf '1793460000\t1793460090\t90\tgw\ttcp80\tSEV1\tdrill\t1\tdrill\tdrills:1-2\tdev\t\n'
        # 独立短中断 4s → SEV3
        printf '1793460300\t1793460304\t4\tgw\tdns\tSEV3\t-\t0\t-\t-\tdev\t\n'
        # 独立长中断 30s，未排除 → SEV1
        printf '1793460500\t1793460530\t30\tgw\ttcp80\tSEV1\t-\t0\t-\t-\tdev\t\n'
    } > "$_sv/svc_outages.tsv"
    IL_DIR=$_sv IL_NOW=1793465000 IL_DATA_KB=999999999 IL_BACKFILL_N=50 sh "$0" >/dev/null 2>&1
    _n=$(grep -c '	svc_outage	' "$_sv/incidents.tsv" 2>/dev/null); _n=$(num0 "$_n")
    _merged=$(grep 'probes=dns+tcp80' "$_sv/incidents.tsv" 2>/dev/null | head -1)
    _mdur=$(printf '%s' "$_merged" | cut -f5)
    _msev=$(printf '%s' "$_merged" | cut -f2)
    _mexc=$(printf '%s' "$_merged" | sed -n 's/.*excluded=\([a-z0-9]*\).*/\1/p')
    _sev3=$(grep -c '	svc_outage	gw	4	' "$_sv/incidents.tsv" 2>/dev/null)
    _sev1=$(grep -c '	svc_outage	gw	30	' "$_sv/incidents.tsv" 2>/dev/null)
    _fail=0
    [ "$_n" = 3 ] || { echo "FAIL svcout: 入账行数=$_n 应为 3（2 段合并成 1 + 2 段独立）"; _fail=1; }
    [ -n "$_merged" ] || { echo "FAIL svcout: 未合并多探针（probes=dns+tcp80 未出现）"; _fail=1; }
    [ "$_mdur" = 90 ] || { echo "FAIL svcout: 合并时长=$_mdur 应为 90（取并集）"; _fail=1; }
    [ "$_msev" = SEV1 ] || { echo "FAIL svcout: 合并后严重度=$_msev 应为 SEV1（>20s）"; _fail=1; }
    [ "$_mexc" = 1 ] || { echo "FAIL svcout: excluded 未透传（=$_mexc 应为 1）"; _fail=1; }
    [ "$_sev3" = 1 ] || { echo "FAIL svcout: 4s 中断未落 SEV3"; _fail=1; }
    [ "$_sev1" = 1 ] || { echo "FAIL svcout: 30s 中断未落 SEV1"; _fail=1; }
    rm -rf "$_sv"
    if [ "$_fail" = 0 ]; then
        echo "incident_ledger selftest_svcout: 4 段→3 行(PASS) 合并 dur=90 SEV1 excluded=1; 4s→SEV3; 30s→SEV1"
        return 0
    fi
    return 1
}

# drills.tsv 解析单测（Lead 2026-11-01 v2 要求）：空行/CR 残片/4 列碎片/非数字起点
# 一律**不得**被当成窗口；合法窗口（含 end=0 未闭合）必须被正确识别。
selftest_drill() {
    _sd=/tmp/il_drill_selftest.$$
    rm -rf "$_sd"; mkdir -p "$_sd"
    _save_drillf=$DRILLF
    DRILLF=$_sd/drills.tsv
    {
        printf '1793468500\t1793468700\tdrill-manual\tX\tme\tclosed\n'
        printf '1793469000\t0\tdrill-manual\tY\tme\topen\n'
        printf '\n'
        printf '\r\n'
        printf '1793468000\t1793468100\tfrag\tX\n'
        printf 'abc\t1793468100\tdrill-manual\tZ\tme\tbad\n'
    } > "$DRILLF"
    IL_DRILLS=""
    load_drills
    _nw=$(printf '%s' "$IL_DRILLS" | wc -w); _nw=$(num0 "$_nw")
    _t1=$(drill_tag 1793468600 "d")
    _t2=$(drill_tag 1793468050 "d")
    _t3=$(drill_tag 1793469500 "d")
    _t4=$(drill_tag 1793468800 "d")
    _op=$(awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2+0==0' "$DRILLF" | wc -l)
    _fail=0
    [ "$_nw" = 2 ] || { echo "FAIL drill_parse: windows=$_nw 应为 2（CR/空行/4列碎片/非数字起点都要跳过）"; _fail=1; }
    [ "$_op" = 1 ] || { echo "FAIL drill_parse: open=$_op 应为 1（只认合法的 end=0 行）"; _fail=1; }
    case "$_t1" in "[drill]"*) ;; *) echo "FAIL drill_parse: 闭合窗口内的行未被标记"; _fail=1 ;; esac
    case "$_t2" in "[drill]"*) echo "FAIL drill_parse: 4 列碎片行被当成窗口（应跳过）"; _fail=1 ;; esac
    case "$_t3" in "[drill]"*) ;; *) echo "FAIL drill_parse: 未闭合窗口(0)内的行未被标记"; _fail=1 ;; esac
    case "$_t4" in "[drill]"*) echo "FAIL drill_parse: 窗口外的行被误标"; _fail=1 ;; esac
    DRILLF=$_save_drillf
    rm -rf "$_sd"
    if [ "$_fail" = 0 ]; then
        echo "incident_ledger selftest_drill: 6 形态(PASS) windows=2 open=1 窗口内标记/碎片不误判"
        return 0
    fi
    return 1
}

# NE 台账形态单测（R2-D）：构造 1/2/6/7/8/9 列 + 首列非数字，断言
#   ① 碎片只计数不入账 ② 旧格式(6/7 列)照常入账 ③ 当前格式(8/9 列)入账 ④ 正常行不受影响
selftest_ne() {
    _d=/tmp/il_ne_selftest.$$
    rm -rf "$_d"; mkdir -p "$_d"
    {
        printf '%s\n' '        index($0, last) == 1 && length($0) == length(last) { n = 0 }'
        printf '%s\n' '    } 	origin=our-tree'
        printf '1792455416	20198	busybox	sig=11	exe=/x	args=busybox sh\n'
        printf '1792455500	20199	ip	sig=11	exe=/y	args=ip addr	origin=our-tree\n'
        printf '1792455600	20200	awk	sig=11	exe=/z	args=awk	origin=our-tree	stack=/s\n'
        printf '1792455700	20201	sh	sig=11	exe=/w	args=sh	unsync=1	origin=our-tree	stack=/s\n'
        printf 'notanumber	fake	sig=11	exe=x	args=y	origin=z\n'
    } > "$_d/ne_events.tsv"
    IL_DIR=$_d IL_NOW=1793464339 IL_DATA_KB=999999999 IL_BACKFILL_N=50 IL_BACKFILL_N_NE=50 sh "$0" >/dev/null 2>&1
    _rows=$(grep -c '	ne	' "$_d/incidents.tsv" 2>/dev/null); _rows=$(num0 "$_rows")
    _bad=$(sed -n 's/^malformed_ne=//p' "$_d/incident_ledger.status" 2>/dev/null); _bad=$(num0 "$_bad")
    _g6=$(sed -n 's/^ne_good_nf6=//p' "$_d/incident_ledger.status" 2>/dev/null); _g6=$(num0 "$_g6")
    _g7=$(sed -n 's/^ne_good_nf7=//p' "$_d/incident_ledger.status" 2>/dev/null); _g7=$(num0 "$_g7")
    _g8=$(sed -n 's/^ne_good_nf8=//p' "$_d/incident_ledger.status" 2>/dev/null); _g8=$(num0 "$_g8")
    _g9=$(sed -n 's/^ne_good_nf9=//p' "$_d/incident_ledger.status" 2>/dev/null); _g9=$(num0 "$_g9")
    _fail=0
    [ "$_rows" = 4 ] || { echo "FAIL ne_forms: 入账行数=$_rows 应为 4(6/7/8/9 列各一)"; _fail=1; }
    [ "$_bad" = 3 ] || { echo "FAIL ne_forms: malformed_ne=$_bad 应为 3(1列碎片+2列碎片+首列非数字)"; _fail=1; }
    [ "$_g6" = 1 ] && [ "$_g7" = 1 ] && [ "$_g8" = 1 ] && [ "$_g9" = 1 ] || {
        echo "FAIL ne_forms: 形态计数 g6=$_g6 g7=$_g7 g8=$_g8 g9=$_g9 应各为 1"; _fail=1; }
    rm -rf "$_d"
    if [ "$_fail" = 0 ]; then
        echo "incident_ledger selftest_ne: 7 形态(PASS) 入账=4 碎片计数=3 形态计数=1/1/1/1"
        return 0
    fi
    return 1
}

# =====================================================================
# 主流程
# =====================================================================
case "$1" in
--classify) sev_of "$2" "$3" "$4" "$5"; exit 0 ;;
--selftest) selftest; exit $? ;;
--status)
    [ -f "$STATUSF" ] && cat "$STATUSF"
    echo "--- cursors ---"
    for _c in wdlog ne reboot bootatt netcfg edges trans svcout syslog; do
        [ -f "$CURD/$_c" ] && echo "$_c seq=$(cur_seq "$_c")"
    done
    echo "--- open episodes ---"
    cat "$OPENF" 2>/dev/null
    echo "--- tail ledger ---"
    tail -n 5 "$LEDGER" 2>/dev/null
    exit 0 ;;
esac

mkdir -p "$CURD" 2>/dev/null
touch "$LEDGER" "$SEAL" "$OPENF" "$CNTF" 2>/dev/null

# 单实例锁（手工审计与 tick 并发时只让一个跑；svc_lib 缺失时退化为继续）
if [ -r /data/gw/svc_lib.sh ] && [ "$DRYRUN" != 1 ]; then
    . /data/gw/svc_lib.sh 2>/dev/null
    _rc=0
    svc_lock incident_ledger /data/gw/incident_ledger.sh || _rc=$?
    if [ "$_rc" != 0 ]; then
        il "skip another instance holds the lock rc=$_rc"
        exit 0
    fi
fi

BOOTID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
PREV_BOOT=$(sed -n 's/^boot_id=//p' "$STATEF" 2>/dev/null | head -1)
# 新 boot：未配对的开链全部按「重启时仍处降级」落行（否则证据丢在 /tmp）
if [ -n "$BOOTID" ] && [ "$BOOTID" != "$PREV_BOOT" ] && [ -s "$OPENF" ]; then
    IL_SRC=wdlog
    while IFS= read -r R; do
        [ -n "$R" ] || continue
        _lab=$(printf '%s' "$R" | cut -f1)
        _ot=$(printf '%s' "$R" | cut -f2)
        _ok=$(printf '%s' "$R" | cut -f3)
        [ "$_ok" = "-" ] && _ok=$_lab
        mkref
        emit svc_fail "$_ok" - "$_ref" "label=$_lab open=1 rebooted_while_degraded since=$_ot"
    done < "$OPENF"
    : > "$OPENF"
    il "new boot flushed open episodes"
fi
if [ -n "$BOOTID" ]; then
    grep -v '^boot_id=' "$STATEF" 2>/dev/null > "$STATEF.tmp"
    printf 'boot_id=%s\n' "$BOOTID" >> "$STATEF.tmp"
    mv "$STATEF.tmp" "$STATEF"
fi

load_planned
load_drills
[ -n "$IL_BUILD_EPOCH" ] || IL_BUILD_EPOCH=$(build_epoch 2>/dev/null)
case "$IL_BUILD_EPOCH" in ''|*[!0-9]*) IL_BUILD_EPOCH="" ;; esac
il "build_epoch=$IL_BUILD_EPOCH"

if [ "$1" = "--flush-pending" ]; then
    flush_pending
    append_batch
    [ "$IL_APPENDED" -gt 0 ] && seal_write append manual_flush
    write_status
    rm -f "$BATCH"
    exit 0
fi
if [ "$1" = "--reannotate" ]; then
    _since=""; _apply=0
    shift
    while [ $# -gt 0 ]; do
        case "$1" in
        --since) shift; _since=$1 ;;
        --apply) _apply=1 ;;
        esac
        shift
    done
    reannotate "$_since" "$_apply"
    rm -f "$BATCH"
    exit 0
fi
if [ "$1" = "--prune" ]; then
    do_prune manual 2
    append_batch
    [ "$IL_APPENDED" -gt 0 ] && seal_write append manual_prune
    write_status
    rm -f "$BATCH"
    exit 0
fi

if [ "$PRESYNC" = 1 ]; then
    il "pre-sync buffering only"
    IL_PRESYNC_MODE=1
    cnt_set repairs_seen 0
    ingest wdlog   "$DIR/tmp/watchdog.log"      "$DIR/tmp.prev/watchdog.log" h_wdlog
    ingest ne      "$DIR/ne_events.tsv"         -                            h_ne
    ingest reboot  "$DIR/reboots.log"           -                            h_reboot
    ingest bootatt "$BOOTATT"                   -                            h_bootatt
    ingest netcfg  "$DIR/netcfg_repairs.tsv"    -                            h_netcfg
    ingest edges   "$DIR/avail_edges.tsv"       -                            h_edges
    ingest trans   "$DIR/avail_transitions.tsv" -                            h_trans
    ingest svcout  "$DIR/svc_outages.tsv"       -                            h_svcout
    ingest syslog  "$DIR/syslog.log"            "$DIR/syslog.log.1"          h_syslog
    ingest aee     "$AEEH"                      -                            h_aee
    if [ -s "$BATCH" ]; then
        cat "$BATCH" >> "$PENDF" 2>/dev/null
        _pn=$(wc -l < "$BATCH" | tr -d ' ')
        IL_PENDING=$(num0 "$_pn")
        : > "$BATCH"
    fi
    echo "$UP" > "$HB" 2>/dev/null
    write_status
    il "tick pre-sync done buffered=$IL_PENDING"
    rm -f "$BATCH"
    exit 0
fi

cnt_set repairs_seen 0
flush_pending
ingest wdlog   "$DIR/tmp/watchdog.log"      "$DIR/tmp.prev/watchdog.log" h_wdlog
ingest ne      "$DIR/ne_events.tsv"         -                            h_ne
ingest reboot  "$DIR/reboots.log"           -                            h_reboot
ingest bootatt "$BOOTATT"                   -                            h_bootatt
ingest netcfg  "$DIR/netcfg_repairs.tsv"    -                            h_netcfg
ingest edges   "$DIR/avail_edges.tsv"       -                            h_edges
ingest trans   "$DIR/avail_transitions.tsv" -                            h_trans
ingest svcout  "$DIR/svc_outages.tsv"       -                            h_svcout
ingest syslog  "$DIR/syslog.log"            "$DIR/syslog.log.1"          h_syslog
ingest aee     "$AEEH"                      -                            h_aee

append_batch
[ "$IL_APPENDED" -gt 0 ] && seal_write append tick

# 留存策略（每日一次：按 TTL 裁过期 SEV3/SEV2；SEV1 永不裁）
_lastprune=$(sed -n 's/^last_prune=//p' "$STATEF" 2>/dev/null | head -1)
case "$_lastprune" in ''|*[!0-9]*) _lastprune=0 ;; esac
if [ $(( NOW - _lastprune )) -ge 86400 ]; then
    do_prune retention_daily 2 retention
    printf 'last_prune=%s\n' "$NOW" >> "$STATEF" 2>/dev/null
fi

disk_guard

append_batch
[ "$IL_APPENDED" -gt 0 ] && seal_write append guard

echo "$UP" > "$HB" 2>/dev/null
write_status
il "tick done appended=$IL_APPENDED lines=$(cnt_get lines_read) gaps=$(cnt_get gaps) malformed_ne=$(cnt_get malformed_ne) pending=$IL_PENDING"
rm -f "$BATCH"
exit 0
