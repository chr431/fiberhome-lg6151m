#!/bin/sh
# retention_audit.sh v1.4 -- 事故台账留存审计（M1 / R1.3 R1.4 R1.5 R1.6 + R2-D + A1）
# v1.4 (2026-11-01 A1 far-infra 轮): NE_QUALITY/NE_RUN_COUNTERS 形态分布放行
#   10/11 列(core_meta v1.13 起行尾 far=/pc=; 不放行会把新行计入 other 误报
#   CHECK)。(头注此前停在 v1.1 而登记列已 1.3, 本轮追平。)
# v1.1 (2026-11-01 R2-D 数据质量轮): 新增 NE_QUALITY(ne_events 形态分布: 6/7/8/9 列
#   合法格式 vs 1/2 列碎片) 与 AEE_KE(aee db_history 的 KE/NE 计数) 两行 —— 台账
#   数据源的健康度必须在审计里可见, 不能只藏在 incident_ledger.status 里。
#
# 一句话：让「最老一条 SEV1 是 N 天前的、仍在盘上、没被轮转吃掉」变成**一条命令
#   能反复验证的事实**，而不是承诺。
#
# 审计三件事（缺一不可）：
#   ① 完整性：台账 md5/行数/字节 与 seal 末行一致；seq 单调序号 1..N 无缺口，
#      缺口必须与 seal 里逐次 prune 的计数对账（丢行=FAIL，绝不静默通过）。
#   ② 留存龄：各 tier 的 rows/bytes/oldest_ts/oldest_age_days 对合同阈值判
#      PASS / GROWING / FAIL / NODATA（三态区分"还没到龄"与"被裁掉了"）。
#   ③ 可溯源性：演练窗口单列（Lead v1.2 契约）、pre-sync 行单列、回填行单列、
#      脏行计数、上一次死亡原因（R1.5）。
#
# 判定口径（诚实性优先）：
#   PASS    = 该级最老记录龄 >= 合同下限（SEV1 7d / SEV2 1d / SEV3 1d）
#   GROWING = 未到合同龄，但台账自身总龄也 < 合同龄 —— 历史还不够长，不是违规
#   FAIL    = 台账自身够老，而该级最老记录不够老 —— 只可能是被裁掉/被轮转吃掉
#   NODATA  = 该级没有任何行 —— 无法证明留存（不等于 PASS）
#   OVERALL = PROVEN（三级都有行且全部 PASS 且完整性通过）
#           / PARTIAL（无 FAIL 但有 NODATA/GROWING）
#           / FAIL（完整性失败或任一级 FAIL）
#
# 用法：
#   sh retention_audit.sh            # 人读报告 + 写 $DIR/retention_audit.txt + history 一行
#   sh retention_audit.sh --quiet    # 只写文件，stdout 一行摘要（供 log_keeper/API 用）
#   sh retention_audit.sh --json     # 单行机器可读 key=value
#   sh retention_audit.sh --selftest # 合成台账跑全部判据（含 4 个篡改用例必须 FAIL）
#
# 环境覆盖（selftest / PC 侧演练）：IL_DIR IL_LEDGER IL_SEAL IL_STATUS IL_CNT
#   IL_HB IL_NOW
#
# 纪律：busybox awk 只许标量；不使用花括号变量展开；所有数值 case 守卫。

PATH=/data/gw/sbin:/data/gw/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
if [ -z "$TZ" ] && [ -r /etc/TZ ]; then TZ=$(cat /etc/TZ 2>/dev/null); export TZ; fi

DIR=$IL_DIR;        [ -n "$DIR" ] || DIR=/data/gw/logs
LEDGER=$IL_LEDGER;  [ -n "$LEDGER" ] || LEDGER=$DIR/incidents.tsv
SEAL=$IL_SEAL;      [ -n "$SEAL" ] || SEAL=$DIR/incidents.seal
STATUSF=$IL_STATUS; [ -n "$STATUSF" ] || STATUSF=$DIR/incident_ledger.status
CNTF=$IL_CNT;       [ -n "$CNTF" ] || CNTF=$DIR/.inc_counters
DRILLF=$DIR/drills.tsv
NEV=$DIR/ne_events.tsv
HB=$IL_HB;          [ -n "$HB" ] || HB=/tmp/incident_ledger.hb
REPORT=$DIR/retention_audit.txt
HIST=$DIR/retention_audit_history.tsv

NOW=$IL_NOW
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
case "$NOW" in ''|*[!0-9]*) NOW=0 ;; esac

# ---- 一致性快照 ----------------------------------------------------------
# 台账正被 5min tick 追加：若一边 md5sum 一边 wc -l，中间插进一次 append 就会
# 报出"行数/字节不符"的**假 FAIL**（2026-11-01 04:10 实弹：PC 侧误报丢 20 行）。
# 做法：先把台账 cp 到 /tmp 快照，再用快照做全部计算；并用 seal 末行 md5 校验
# 快照一致性，不一致就重拍（最多 4 次）。
SRC=$LEDGER
SNAP=/tmp/ra_snap.$$
SNAP_TRY=0
SNAP_OK=no
if [ -s "$SRC" ]; then
    while [ "$SNAP_TRY" -lt 4 ]; do
        SNAP_TRY=$((SNAP_TRY + 1))
        cp "$SRC" "$SNAP" 2>/dev/null || break
        _sm=$(md5sum "$SNAP" 2>/dev/null | cut -d' ' -f1)
        _lm=$(tail -n 1 "$SEAL" 2>/dev/null | sed -n 's/.* md5=\([0-9a-f]*\).*/\1/p')
        if [ -n "$_sm" ] && [ "$_sm" = "$_lm" ]; then SNAP_OK=yes; break; fi
        sleep 2
    done
    LEDGER=$SNAP
fi

# 合同下限（RELIABILITY_SPEC R1.3：合同 7d/1d；本项目内部目标 90d/30d/7d）
C_SEV1=7;  C_SEV2=1;  C_SEV3=1
T_SEV1=90; T_SEV2=30; T_SEV3=7

num0() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
days() { # $1=秒差 -> 天.两位小数
    _s=$1
    case "$_s" in ''|*[!0-9-]*) echo 0.00; return 0 ;; esac
    [ "$_s" -lt 0 ] && _s=0
    _d=$(( _s / 86400 ))
    _r=$(( (_s % 86400) * 100 / 86400 ))
    case "$_r" in ''|*[!0-9]*) _r=0 ;; esac
    if [ "$_r" -lt 10 ]; then echo "$_d.0$_r"; else echo "$_d.$_r"; fi
}
# 判据：$1=age_seconds $2=contract_days $3=ledger_age_seconds
#   PASS    该级最老记录龄已达合同下限
#   GROWING 未达龄，但台账自身也还不到合同龄（历史不够长，不是违规）
#   SHORT   台账够老而该级没有更老的行（无事件/被策略裁剪；**不算违规**，
#           真正的"被吃掉"由 seq 缺口与 rm1 对账判 FAIL）
verdict_of() {
    _a=$1; _c=$2; _la=$3
    [ "$_a" -ge $(( _c * 86400 )) ] && { echo PASS; return 0; }
    [ "$_la" -lt $(( _c * 86400 )) ] && { echo GROWING; return 0; }
    echo SHORT
}

# =====================================================================
# ① 完整性
# =====================================================================
IL_ROWS=0; IL_BYTES=0; IL_MD5="-"; IL_SEAL_N=0
IL_SROWS="-"; IL_SBYTES="-"; IL_SMD5="-"; IL_RM1=0; IL_RM2=0; IL_RM3=0
IL_FIRST=0; IL_LAST=0; IL_GAPS=0; IL_SEQN=0
IL_OK_ROWS=no; IL_OK_BYTES=no; IL_OK_MD5=no; IL_OK_SEQ=no; IL_OK_ACC=no; IL_OK_SEV1=no
IL_S1_ATTEST_TS="-"; IL_S1_ATTEST_LINE="-"
IL_OLDEST_ANY=0
integrity() {
    [ -s "$LEDGER" ] || return 0
    IL_ROWS=$(wc -l < "$LEDGER" 2>/dev/null); IL_ROWS=$(num0 "$IL_ROWS")
    IL_BYTES=$(wc -c < "$LEDGER" 2>/dev/null); IL_BYTES=$(num0 "$IL_BYTES")
    IL_MD5=$(md5sum "$LEDGER" 2>/dev/null | cut -d' ' -f1); [ -n "$IL_MD5" ] || IL_MD5=-
    # seal 末行
    _sl=$(tail -n 1 "$SEAL" 2>/dev/null)
    IL_SEAL_N=$(wc -l < "$SEAL" 2>/dev/null); IL_SEAL_N=$(num0 "$IL_SEAL_N")
    if [ -n "$_sl" ]; then
        # **按字段名取第一个匹配**，不用贪婪 sed —— reason 里若出现 rows=/bytes= 字样
        # （例如 reason=mark_clock_skew blocks=1 rows=3），贪婪 sed 会抓到 reason 里的值
        # 而把 rows_ok 判成 no（2026-11-01 实弹）。
        _sf=$(printf '%s' "$_sl" | awk '{
            for (i = 1; i <= NF; i++) {
                p = index($i, "=")
                if (p == 0) continue
                k = substr($i, 1, p - 1)
                if (k == "rows" && r == "") r = substr($i, p + 1)
                if (k == "bytes" && b == "") b = substr($i, p + 1)
                if (k == "md5" && m == "") m = substr($i, p + 1)
            }
            print r" "b" "m
        }')
        IL_SROWS=$(printf '%s' "$_sf" | cut -d' ' -f1); IL_SROWS=$(num0 "$IL_SROWS")
        IL_SBYTES=$(printf '%s' "$_sf" | cut -d' ' -f2); IL_SBYTES=$(num0 "$IL_SBYTES")
        IL_SMD5=$(printf '%s' "$_sf" | cut -d' ' -f3); [ -n "$IL_SMD5" ] || IL_SMD5=-
        [ "$IL_ROWS" = "$IL_SROWS" ] && IL_OK_ROWS=yes
        [ "$IL_BYTES" = "$IL_SBYTES" ] && IL_OK_BYTES=yes
        [ "$IL_MD5" = "$IL_SMD5" ] && IL_OK_MD5=yes
    fi
    # 累计删除计数：rm*=留存裁剪（SEV1 必须恒 0）；rp*=修复性删除（去重/纠错重写，
    # 可为任意级别）。两者都造成 seq 缺口，但只有 rm* 违反"SEV1 永不裁剪"的红线。
    # 语义判定：只有 prune/disk_guard/retention 这三类 op 的 rm* 才算"留存裁剪"；
    # 其它 op（repair/reannotate）行上的 rm* 一律按**修复性删除**计 —— 这样历史里
    # 那次"去重修复却写了 rm1"的错记不会永久污染 SEV1 红线（向后兼容，不改历史）。
    _rms=$(awk '{
        op = ""
        if (match($0, /op=[a-z_]+/)) op = substr($0, RSTART+3, RLENGTH-3)
        prune = (op == "prune" || op == "disk_guard" || op == "retention")
        if (match($0, /rm1=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); if (prune) a+=s+0; else d+=s+0 }
        if (match($0, /rm2=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); if (prune) b+=s+0; else e+=s+0 }
        if (match($0, /rm3=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); if (prune) c+=s+0; else f+=s+0 }
        if (match($0, /rp1=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); d+=s+0 }
        if (match($0, /rp2=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); e+=s+0 }
        if (match($0, /rp3=[0-9]+/)) { s=substr($0, RSTART+4, RLENGTH-4); f+=s+0 }
        if (match($0, /last_seq=[0-9]+/)) { s=substr($0, RSTART+9, RLENGTH-9); if (s+0>mx) mx=s+0 }
        # reuse 是**累计标记**（取最大值而非求和）：同一条对账记录被重复写入时
        # 不能重复扣减（实弹：我跑了两遍 reconcile 脚本 → 求和 2 → 反而少算 1）。
        if (match($0, /reuse=[0-9]+/)) { s=substr($0, RSTART+6, RLENGTH-6); if (s+0>g) g=s+0 }
    } END { print a+0" "b+0" "c+0" "d+0" "e+0" "f+0" "mx+0" "g+0 }' "$SEAL" 2>/dev/null)
    IL_RM1=$(printf '%s' "$_rms" | cut -d' ' -f1); IL_RM1=$(num0 "$IL_RM1")
    IL_RM2=$(printf '%s' "$_rms" | cut -d' ' -f2); IL_RM2=$(num0 "$IL_RM2")
    IL_RM3=$(printf '%s' "$_rms" | cut -d' ' -f3); IL_RM3=$(num0 "$IL_RM3")
    IL_RP1=$(printf '%s' "$_rms" | cut -d' ' -f4); IL_RP1=$(num0 "$IL_RP1")
    IL_RP2=$(printf '%s' "$_rms" | cut -d' ' -f5); IL_RP2=$(num0 "$IL_RP2")
    IL_RP3=$(printf '%s' "$_rms" | cut -d' ' -f6); IL_RP3=$(num0 "$IL_RP3")
    IL_MAXSEQ=$(printf '%s' "$_rms" | cut -d' ' -f7); IL_MAXSEQ=$(num0 "$IL_MAXSEQ")
    # reuse = 历史上有几次删除落在"当时的末尾"、seq 随后被重用（删除不留缺口）。
    # 这是唯一会让"记录删除数 > 实际缺口数"的情形，必须显式声明（见 ledger 的 seq 高水位修复）。
    IL_REUSE=$(printf '%s' "$_rms" | cut -d' ' -f8); IL_REUSE=$(num0 "$IL_REUSE")
    # seq 连续性（标量 awk）
    _ss=$(awk -F'\t' '
        { s=$8+0; if (n==0) { first=s } else { if (s != prev+1) gap += s-prev-1 }
          prev=s; n++ ; if (s>mx) mx=s }
        END { printf "%d %d %d %d\n", first+0, mx+0, gap+0, n+0 }' "$LEDGER" 2>/dev/null)
    IL_FIRST=$(printf '%s' "$_ss" | cut -d' ' -f1); IL_FIRST=$(num0 "$IL_FIRST")
    IL_LAST=$(printf '%s' "$_ss" | cut -d' ' -f2); IL_LAST=$(num0 "$IL_LAST")
    IL_GAPS=$(printf '%s' "$_ss" | cut -d' ' -f3); IL_GAPS=$(num0 "$IL_GAPS")
    IL_SEQN=$(printf '%s' "$_ss" | cut -d' ' -f4); IL_SEQN=$(num0 "$IL_SEQN")
    # 缺口对账：first-1 + 内部缺口 + **尾部缺口** 必须等于 seal 记录的累计删除数。
    # 尾部缺口 = 曾经分配过的最大 seq - 当前最大 seq（删掉末尾行时内部缺口不会增长，
    # 2026-11-01 实弹：删 35 行尾部只多出 34 个内部缺口，对账差 1）。
    _tail=$(( IL_MAXSEQ - IL_LAST ))
    [ "$_tail" -lt 0 ] && _tail=0
    _gone=$(( IL_FIRST - 1 + IL_GAPS + _tail ))
    _rec=$(( IL_RM1 + IL_RM2 + IL_RM3 + IL_RP1 + IL_RP2 + IL_RP3 - IL_REUSE ))
    [ "$_gone" = "$_rec" ] && IL_OK_ACC=yes
    # 重复 seq 检测（真实损坏信号；正常应为 0）
    IL_DUP=$(awk -F'\t' '{print $8}' "$LEDGER" 2>/dev/null | sort -n | uniq -d | wc -l); IL_DUP=$(num0 "$IL_DUP")
    IL_GONE=$_gone; IL_REC=$_rec; IL_TAIL=$_tail
    [ "$IL_SEQN" = "$IL_ROWS" ] && [ "$IL_GAPS" = 0 ] && IL_OK_SEQ=yes
    [ "$IL_RM1" = 0 ] && IL_OK_SEV1=yes
    # 台账自身总龄（用最早一行的 ts）
    IL_OLDEST_ANY=$(awk -F'\t' 'BEGIN{mn=0} { if (mn==0 || $1+0 < mn) mn=$1+0 } END{print mn+0}' "$LEDGER" 2>/dev/null)
    IL_OLDEST_ANY=$(num0 "$IL_OLDEST_ANY")
}

# =====================================================================
# ② 每 tier 统计
# =====================================================================
# 输出 "<rows> <bytes> <oldest_ts>"
tier_stat() { # $1=SEVx —— pre_sync 行单列，不参与"最老龄"（日期不可信）
    awk -F'\t' -v s="$1" '
        $2==s {
            if (index($7, "pre_sync=1") > 0) next
            n++; b+=length($0)+1
            if (mn==0 || $1+0 < mn) mn=$1+0
        }
        END { printf "%d %d %d\n", n+0, b+0, mn+0 }' "$LEDGER" 2>/dev/null
}
presync_stat() { # 单独统计 pre_sync 行（ts 不可信，只能计入"已如实标注"）
    awk -F'\t' '
        index($7, "pre_sync=1") > 0 { n++; b+=length($0)+1 }
        END { printf "%d %d\n", n+0, b+0 }' "$LEDGER" 2>/dev/null
}
oldest_row_md5() { # $1=SEVx -> md5 of the oldest row of that tier
    _ln=$(awk -F'\t' -v s="$1" 'BEGIN{ln=0}
        $2==s { if (ln==0 || $1+0 < best+0) { best=$1+0; ln=NR } }
        END{print ln+0}' "$LEDGER" 2>/dev/null)
    _ln=$(num0 "$_ln")
    [ "$_ln" -gt 0 ] || { echo "-"; return 0; }
    md5sum "$LEDGER" 2>/dev/null >/dev/null
    sed -n "$_ln"p "$LEDGER" 2>/dev/null | md5sum | cut -d' ' -f1
}
# 最老 SEV1 行在 seal 里最早被记到的时间（= 连续性见证）
attest_sev1() { # $1=md5
    [ "$1" = "-" ] && return 0
    awk -v m="$1" '
        {
            if (match($0, /oldest_sev1_md5=[0-9a-f]+/)) {
                v = substr($0, RSTART+16, RLENGTH-16)
                if (v == m && first == 0) {
                    t = "-"
                    if (match($0, / ts=[0-9]+/)) t = substr($0, RSTART+4, RLENGTH-4)
                    first = 1; out = t; outn = NR
                }
            }
        }
        END { if (first == 0) print "- -"; else print out" "outn }' "$SEAL" 2>/dev/null
}

# =====================================================================
# ③ 可溯源性与质量指标
# =====================================================================
IL_PRESYNC=0; IL_BACKFILL=0; IL_DRILLROWS=0
quality() {
    [ -s "$LEDGER" ] || return 0
    IL_PRESYNC=$(grep -c 'pre_sync=1' "$LEDGER" 2>/dev/null); IL_PRESYNC=$(num0 "$IL_PRESYNC")
    IL_BACKFILL=$(grep -c 'backfill=1' "$LEDGER" 2>/dev/null); IL_BACKFILL=$(num0 "$IL_BACKFILL")
    IL_DRILLROWS=$(grep -c 'drill=1' "$LEDGER" 2>/dev/null); IL_DRILLROWS=$(num0 "$IL_DRILLROWS")
}
hb_age() {
    _v=$(cat "$HB" 2>/dev/null)
    case "$_v" in ''|*[!0-9]*) echo 999999; return 0 ;; esac
    _u=$(cut -d. -f1 /proc/uptime 2>/dev/null); _u=$(num0 "$_u")
    _a=$(( _u - _v ))
    [ "$_a" -lt 0 ] && _a=999999
    echo "$_a"
}

# =====================================================================
# 主报告
# =====================================================================
run_audit() {
    integrity
    quality
    _hb=$(hb_age)
    _ps=$(presync_stat)
    PS_N=$(printf '%s' "$_ps" | cut -d' ' -f1); PS_N=$(num0 "$PS_N")
    PS_B=$(printf '%s' "$_ps" | cut -d' ' -f2); PS_B=$(num0 "$PS_B")
    _s1=$(tier_stat SEV1); _s2=$(tier_stat SEV2); _s3=$(tier_stat SEV3)
    R1=$(printf '%s' "$_s1" | cut -d' ' -f1); R1=$(num0 "$R1")
    B1=$(printf '%s' "$_s1" | cut -d' ' -f2); B1=$(num0 "$B1")
    O1=$(printf '%s' "$_s1" | cut -d' ' -f3); O1=$(num0 "$O1")
    R2=$(printf '%s' "$_s2" | cut -d' ' -f1); R2=$(num0 "$R2")
    B2=$(printf '%s' "$_s2" | cut -d' ' -f2); B2=$(num0 "$B2")
    O2=$(printf '%s' "$_s2" | cut -d' ' -f3); O2=$(num0 "$O2")
    R3=$(printf '%s' "$_s3" | cut -d' ' -f1); R3=$(num0 "$R3")
    B3=$(printf '%s' "$_s3" | cut -d' ' -f2); B3=$(num0 "$B3")
    O3=$(printf '%s' "$_s3" | cut -d' ' -f3); O3=$(num0 "$O3")
    _la=$(( NOW - IL_OLDEST_ANY )); [ "$_la" -lt 0 ] && _la=0
    # 每级
    if [ "$R1" -gt 0 ]; then
        _a1=$(( NOW - O1 )); [ "$_a1" -lt 0 ] && _a1=0
        V1=$(verdict_of "$_a1" "$C_SEV1" "$_la")
    else
        _a1=0; V1=NODATA
    fi
    if [ "$R2" -gt 0 ]; then
        _a2=$(( NOW - O2 )); [ "$_a2" -lt 0 ] && _a2=0
        V2=$(verdict_of "$_a2" "$C_SEV2" "$_la")
    else
        _a2=0; V2=NODATA
    fi
    if [ "$R3" -gt 0 ]; then
        _a3=$(( NOW - O3 )); [ "$_a3" -lt 0 ] && _a3=0
        V3=$(verdict_of "$_a3" "$C_SEV3" "$_la")
    else
        _a3=0; V3=NODATA
    fi
    # 最老 SEV1 的连续性见证
    _m1=$(oldest_row_md5 SEV1)
    if [ "$_m1" != "-" ]; then
        _at=$(attest_sev1 "$_m1")
        IL_S1_ATTEST_TS=$(printf '%s' "$_at" | cut -d' ' -f1)
        IL_S1_ATTEST_LINE=$(printf '%s' "$_at" | cut -d' ' -f2)
    fi
    # 合同是否达成（甲方口径：SEV1 最老 >7d、SEV2/SEV3 >1d）
    M1=no; M2=no; M3=no
    [ "$R1" -gt 0 ] && [ "$_a1" -ge $(( C_SEV1 * 86400 )) ] && M1=yes
    [ "$R2" -gt 0 ] && [ "$_a2" -ge $(( C_SEV2 * 86400 )) ] && M2=yes
    [ "$R3" -gt 0 ] && [ "$_a3" -ge $(( C_SEV3 * 86400 )) ] && M3=yes
    # 总体：只有完整性被破坏才是 FAIL（丢行/改行/SEV1 被删）
    OVERALL=PROVEN
    case "$V1$V2$V3" in
    *PASS*) case "$V1$V2$V3" in *NODATA*|*GROWING*|*SHORT*) OVERALL=PARTIAL ;; esac ;;
    *) OVERALL=PARTIAL ;;
    esac
    [ "$IL_OK_ROWS" = yes ] || OVERALL=FAIL
    [ "$IL_OK_BYTES" = yes ] || OVERALL=FAIL
    [ "$IL_OK_MD5" = yes ] || OVERALL=FAIL
    [ "$IL_OK_ACC" = yes ] || OVERALL=FAIL
    [ "$IL_OK_SEV1" = yes ] || OVERALL=FAIL
    [ "$SNAP_OK" = yes ] || OVERALL=FAIL
    [ "$IL_DUP" = 0 ] || OVERALL=FAIL
    # 输出
    {
        echo "retention_audit v1.0  ts=$NOW  ($(date '+%F %T %Z'))"
        echo "ledger=$SRC rows=$IL_ROWS bytes=$IL_BYTES md5=$IL_MD5"
        echo "SNAPSHOT consistent=$SNAP_OK attempts=$SNAP_TRY note=台账读取期可能被 tick 追加, 一致性快照后计算"
        echo "seal=$SEAL lines=$IL_SEAL_N last_rows=$IL_SROWS last_bytes=$IL_SBYTES last_md5=$IL_SMD5"
        echo "INTEGRITY rows_match=$IL_OK_ROWS bytes_match=$IL_OK_BYTES md5_match=$IL_OK_MD5 seq_contiguous=$IL_OK_SEQ gaps=$IL_GAPS tail_gaps=$IL_TAIL gaps_accounted=$IL_OK_ACC gone=$IL_GONE accounted=$IL_REC reused_seqs=$IL_REUSE dup_seqs=$IL_DUP pruned_total=$(( IL_RM1 + IL_RM2 + IL_RM3 )) rm1=$IL_RM1 rm2=$IL_RM2 rm3=$IL_RM3 repaired_total=$(( IL_RP1 + IL_RP2 + IL_RP3 )) rp1=$IL_RP1 rp2=$IL_RP2 rp3=$IL_RP3 sev1_never_pruned=$IL_OK_SEV1"
        echo "TIER SEV1 rows=$R1 bytes=$B1 oldest_ts=$O1 oldest_age_days=$(days "$_a1") target_days=$T_SEV1 contract_days=$C_SEV1 verdict=$V1"
        echo "TIER SEV2 rows=$R2 bytes=$B2 oldest_ts=$O2 oldest_age_days=$(days "$_a2") target_days=$T_SEV2 contract_days=$C_SEV2 verdict=$V2"
        echo "TIER SEV3 rows=$R3 bytes=$B3 oldest_ts=$O3 oldest_age_days=$(days "$_a3") target_days=$T_SEV3 contract_days=$C_SEV3 verdict=$V3"
        echo "LEDGER_AGE days=$(days "$_la") oldest_ts=$IL_OLDEST_ANY first_seq=$IL_FIRST last_seq=$IL_LAST rows=$IL_ROWS"
        echo "CONTRACT sev1_met=$M1 sev1_oldest_age_days=$(days "$_a1") sev1_floor_days=$C_SEV1 sev2_met=$M2 sev2_oldest_age_days=$(days "$_a2") sev2_floor_days=$C_SEV2 sev3_met=$M3 sev3_oldest_age_days=$(days "$_a3") sev3_floor_days=$C_SEV3"
        echo "OLDEST_SEV1 attested_since_ts=$IL_S1_ATTEST_TS seal_line=$IL_S1_ATTEST_LINE row_md5=$_m1"
        echo "QUALITY presync_rows=$IL_PRESYNC backfill_rows=$IL_BACKFILL drill_tagged_rows=$IL_DRILLROWS ledger_hb_age_s=$_hb"
        echo "PRESYNC rows=$PS_N bytes=$PS_B counted_in_oldest=no note=写于NTP首同步前(或时钟=固件构建日), ts已按入账时刻计, 原值在src_ts"
        # R1.6/M1 新失效模式：时钟跳变污染时间轴。审计只看 md5/行数/seq 是看不见的，
        # 必须单列「有多少行时间戳不可信」。标注只加 detail，**不改 epoch**。
        _cs=$(awk -F'\t' '
            index($7, "clock_skew=1") > 0 {
                n++
                if (prev == 0) spans++
                else if ($8 + 0 != prev + 1) spans++
                prev = $8 + 0
            }
            END { printf "%d %d\n", n + 0, spans + 0 }' "$LEDGER" 2>/dev/null)
        CS_N=$(printf '%s' "$_cs" | cut -d' ' -f1); CS_N=$(num0 "$CS_N")
        CS_S=$(printf '%s' "$_cs" | cut -d' ' -f2); CS_S=$(num0 "$CS_S")
        echo "CLOCK_SKEW rows=$CS_N spans=$CS_S note=时间戳受时钟跳变污染(epoch 未改, 仅 detail 标注); 该区间不可用于跨源对齐, 只能用客户端锚点校正"
        # R4-C: 各 category 的行数分布（新 category 必须能在 tier 统计里被正确归类；
        # 这里给出 category × severity 的交叉表，便于核对"活着但不服务"这类新来源）
        if [ -s "$SRC" ]; then
            awk -F'\t' '
                { k = $3 "/" $2; n[k]++ }
                END { for (x in n) printf "%s=%d ", x, n[x]; print "" }
            ' "$SRC" 2>/dev/null | sed 's/^/CATEGORIES /'
        fi
        echo "SOURCE_HEALTH malformed_ne=$(sed -n 's/^malformed_ne=//p' "$STATUSF" 2>/dev/null) source_gaps=$(sed -n 's/^gaps=//p' "$STATUSF" 2>/dev/null) lines_read=$(sed -n 's/^lines_read=//p' "$STATUSF" 2>/dev/null) pending=$(sed -n 's/^pending=//p' "$STATUSF" 2>/dev/null) presync_now=$(sed -n 's/^presync=//p' "$STATUSF" 2>/dev/null) data_free_kb=$(sed -n 's/^data_free_kb=//p' "$STATUSF" 2>/dev/null)"
        # R2-D: NE 台账**文件级**形态分布（不是每轮计数器 —— 计数器在静默轮会归零，
        # 会让人误读成"文件里没有合法行"）。一次 awk 扫描源文件，给出：
        #   合法: 6/7 列=旧格式(core_meta v1.2 前/v1.2~v1.6), 8/9 列=v1.7..v1.12,
        #         10/11 列=v1.13+(行尾 far=/pc=, A1 far-infra)
        #   脏行: fragments=首列非数字(碎片), blank=空白行, other=首列是数字但列数离谱
        #   newest_fragment_line 与 total 的对比 = "历史遗留 vs 新产生"的判据
        if [ -r "$NEV" ]; then
            _nq=$(awk -F'\t' '
                /^[ \t]*$/ { blank++; next }
                $1 !~ /^[0-9]+$/ { frag++; if (NR > maxfrag) maxfrag = NR; next }
                NF==6 { v6++; next } NF==7 { v7++; next } NF==8 { v8++; next } NF==9 { v9++; next }
                NF==10 { v10++; next } NF==11 { v11++; next }
                { other++ }
                END { printf "%d %d %d %d %d %d %d %d %d %d\n", v6+0, v7+0, v8+0, v9+0, v10+0, v11+0, frag+0, blank+0, other+0, maxfrag+0 }
            ' "$NEV" 2>/dev/null)
            _v6=$(printf '%s' "$_nq" | cut -d' ' -f1); _v7=$(printf '%s' "$_nq" | cut -d' ' -f2)
            _v8=$(printf '%s' "$_nq" | cut -d' ' -f3); _v9=$(printf '%s' "$_nq" | cut -d' ' -f4)
            _v10=$(printf '%s' "$_nq" | cut -d' ' -f5); _v11=$(printf '%s' "$_nq" | cut -d' ' -f6)
            _fr=$(printf '%s' "$_nq" | cut -d' ' -f7); _bl=$(printf '%s' "$_nq" | cut -d' ' -f8)
            _ot=$(printf '%s' "$_nq" | cut -d' ' -f9); _mf=$(printf '%s' "$_nq" | cut -d' ' -f10)
            _tot=$(wc -l < "$NEV" 2>/dev/null); _tot=$(num0 "$_tot")
            _verd=OK
            [ "$_ot" != 0 ] && _verd=CHECK
            [ "$_fr" != 0 ] && _verd=FRAGMENTS_HISTORICAL
            # 新产生的判据：碎片出现在文件最后 50 行内
            if [ "$_fr" != 0 ] && [ "$_mf" -gt $(( _tot - 50 )) ]; then _verd=FRAGMENTS_RECENT; fi
            echo "NE_QUALITY file=$NEV total=$_tot valid_6col=$_v6 valid_7col=$_v7 valid_8col=$_v8 valid_9col=$_v9 valid_10col=$_v10 valid_11col=$_v11 fragments=$_fr blank=$_bl other=$_ot newest_fragment_line=$_mf verdict=$_verd"
        fi
        echo "NE_RUN_COUNTERS malformed_ne=$(sed -n 's/^malformed_ne=//p' "$STATUSF" 2>/dev/null) good_6=$(sed -n 's/^ne_good_nf6=//p' "$STATUSF" 2>/dev/null) good_7=$(sed -n 's/^ne_good_nf7=//p' "$STATUSF" 2>/dev/null) good_8=$(sed -n 's/^ne_good_nf8=//p' "$STATUSF" 2>/dev/null) good_9=$(sed -n 's/^ne_good_nf9=//p' "$STATUSF" 2>/dev/null) good_10=$(sed -n 's/^ne_good_nf10=//p' "$STATUSF" 2>/dev/null) good_11=$(sed -n 's/^ne_good_nf11=//p' "$STATUSF" 2>/dev/null) bad_1=$(sed -n 's/^ne_bad_nf1=//p' "$STATUSF" 2>/dev/null) bad_2=$(sed -n 's/^ne_bad_nf2=//p' "$STATUSF" 2>/dev/null) note=每轮增量计数(静默轮为 0 属正常)"
        echo "AEE_KE aee_ke_rows=$(sed -n 's/^aee_ke=//p' "$STATUSF" 2>/dev/null) aee_ne_rows=$(sed -n 's/^aee_ne=//p' "$STATUSF" 2>/dev/null) note=KE 权威来源; NE 只计数防双计"
        # 演练窗口（Lead v1.2：排除必须可审计，不能是黑箱）
        _dn=0
        if [ -s "$DRILLF" ]; then
            _dn=$(wc -l < "$DRILLF" 2>/dev/null); _dn=$(num0 "$_dn")
        fi
        _dn=$(awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/' "$DRILLF" 2>/dev/null | wc -l); _dn=$(num0 "$_dn")
        echo "DRILLS windows=$_dn rows_tagged=$IL_DRILLROWS"
        if [ "$_dn" -gt 0 ]; then
            # 统一窗口判据（Lead 2026-11-01 v2）：NF>=5 && start/end 都是纯数字；
            # 空行 / CR 残片 / 碎片行一律跳过 —— 否则会把写坏的文件读成"一堆未闭合窗口"。
            while IFS='	' read -r _ds _de _dk _dt _do _dn2; do
                case "$_ds" in ''|*[!0-9]*) continue ;; esac
                case "$_de" in ''|*[!0-9]*) continue ;; esac
                [ -n "$_dk" ] || continue
                _flag=""
                [ "$_de" = 0 ] && _flag="OPEN_WINDOW"
                echo "  drill $_ds..$_de kind=$_dk target=$_dt owner=$_do $_flag"
            done < "$DRILLF"
        fi
        # 上一次死亡原因（R1.5）
        echo "BOOT_EVIDENCE (last 5 boot rows; death_reason 判定)"
        grep -E 'death_reason=|boot_ok' "$LEDGER" 2>/dev/null | tail -5 | while IFS='	' read -r _bts _bsv _bcat _bcp _bdu _bev _bdt _bseq; do
            echo "  ts=$_bts sev=$_bsv cat=$_bcat $(printf '%s' "$_bdt" | head -c 160)"
        done
        echo "OVERALL $OVERALL"
    } > "$REPORT.tmp" 2>/dev/null && mv "$REPORT.tmp" "$REPORT" 2>/dev/null
    # history 一行（趋势/取证用；DIR 不可写时静默跳过，审计本身不因此失败）
    if [ -d "$DIR" ] && [ -w "$DIR" ]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$NOW" "$OVERALL" "$R1" "$(days "$_a1")" "$R2" "$(days "$_a2")" "$R3" "$(days "$_a3")" "$IL_ROWS" \
            >> "$HIST" 2>/dev/null
        _hn=$(wc -l < "$HIST" 2>/dev/null); _hn=$(num0 "$_hn")
        if [ "$_hn" -gt 4000 ]; then
            tail -n 2000 "$HIST" > "$HIST.tmp" 2>/dev/null && mv "$HIST.tmp" "$HIST"
        fi
    fi
}

# =====================================================================
# 单测：合成台账上跑全部判据（含 4 个篡改用例必须 FAIL）
# =====================================================================
mkfix() { # $1=dir $2=rowsfile $3=rm1 $4=rm2 $5=rm3 $6=first_seq
    # 目录参数必须非空 —— 空值会把重定向写到当前目录并留下 0/2/3 之类垃圾文件
    # （2026-10-31 实弹：selftest 早期版本在 CWD 留下 0/2/3 三个垃圾文件）。
    _d=$1
    case "$_d" in ''|/) echo "mkfix: bad dir" >&2; return 1 ;; esac
    rm -rf "$_d"; mkdir -p "$_d" || return 1
    _i=$(( $6 - 1 ))
    : > "$_d/incidents.tsv"
    while IFS='	' read -r _t _s _c; do
        [ -n "$_t" ] || continue
        _i=$((_i + 1))
        printf '%s\t%s\t%s\tfixture\t-\tfixture\tfixture row\t%s\n' "$_t" "$_s" "$_c" "$_i" >> "$_d/incidents.tsv"
    done < "$2"
    # 注意：本函数中间变量一律 _mk_ 前缀 —— 早期版本用 _rows 覆盖了调用方
    # selftest 的夹具路径变量，后续重定向于是写到名为 0/2/3 的垃圾文件（实弹教训）。
    _mk_rows=$(wc -l < "$_d/incidents.tsv" 2>/dev/null); _mk_rows=$(num0 "$_mk_rows")
    _mk_bytes=$(wc -c < "$_d/incidents.tsv" 2>/dev/null); _mk_bytes=$(num0 "$_mk_bytes")
    _mk_md5=$(md5sum "$_d/incidents.tsv" 2>/dev/null | cut -d' ' -f1)
    _mk_ls=$(tail -n 1 "$_d/incidents.tsv" 2>/dev/null | cut -f8); _mk_ls=$(num0 "$_mk_ls")
    _mk_op=$7; [ -n "$_mk_op" ] || _mk_op=append
    printf 'op=%s ts=%s rows=%s bytes=%s md5=%s first_seq=%s last_seq=%s sev1=0 sev2=0 sev3=0 rm1=%s rm2=%s rm3=%s oldest_sev1_ts=- oldest_sev1_md5=- reason=fixture\n' \
        "$_mk_op" "$NOW" "$_mk_rows" "$_mk_bytes" "$_mk_md5" "$6" "$_mk_ls" "$3" "$4" "$5" > "$_d/incidents.seal"
}
selftest() {
    _td=/tmp/ra_selftest.$$
    _bad=0; _n=0
    _D40=$(( NOW - 40 * 86400 ))
    _D10=$(( NOW - 10 * 86400 ))
    _D3=$(( NOW - 3 * 86400 ))
    _D2=$(( NOW - 2 * 86400 ))
    _rowsf=$_td/rows.txt
    chk() { # $1=name $2=expect $3=dir
        _n=$((_n + 1))
        _o=$(IL_DIR=$3 IL_NOW=$NOW sh "$0" --json 2>/dev/null)
        _g=$(printf '%s' "$_o" | sed -n 's/.*overall=\([A-Z]*\).*/\1/p')
        if [ "$_g" = "$2" ]; then
            echo "  PASS $1 -> $_g"
        else
            echo "  FAIL $1 want=$2 got=$_g"
            _bad=$((_bad + 1))
        fi
    }
    mkdir -p "$_td"
    # 1) 健康台账：SEV1 40d / SEV2 10d / SEV3 3d
    printf '%s\tSEV1\tne\n%s\tSEV2\tsvc_restart\n%s\tSEV3\tnetcfg_repair\n' "$_D40" "$_D10" "$_D3" > "$_rowsf"
    mkfix "$_td/good" "$_rowsf" 0 0 0 1
    chk good PROVEN "$_td/good"
    # 2) seq 断口未记账（中间删行）→ 必须 FAIL
    mkfix "$_td/gap" "$_rowsf" 0 0 0 1
    sed '2d' "$_td/gap/incidents.tsv" > "$_td/gap/t" && mv "$_td/gap/t" "$_td/gap/incidents.tsv"
    chk seq_gap_unaccounted FAIL "$_td/gap"
    # 3) 追加行但不更新 seal（md5/rows 不符）→ 必须 FAIL
    mkfix "$_td/tail" "$_rowsf" 0 0 0 1
    printf '%s\tSEV3\tledger\tx\t-\tfixture\tunsealed\t99\n' "$NOW" >> "$_td/tail/incidents.tsv"
    chk unsealed_append FAIL "$_td/tail"
    # 4) 台账够老但 SEV1 只留了 2 天（=被裁掉）→ 必须 FAIL
    printf '%s\tSEV1\tne\n%s\tSEV2\tsvc_restart\n%s\tSEV3\tnetcfg_repair\n' "$_D2" "$_D10" "$_D3" > "$_rowsf"
    mkfix "$_td/young" "$_rowsf" 0 0 0 1
    chk sev1_too_young PARTIAL "$_td/young"
    # 5) 已记账的 prune（seq 从 3 起，rm3=2）→ 不算断口
    printf '%s\tSEV1\tne\n%s\tSEV2\tsvc_restart\n%s\tSEV3\tnetcfg_repair\n' "$_D40" "$_D10" "$_D3" > "$_rowsf"
    mkfix "$_td/pruned" "$_rowsf" 0 0 2 3
    chk recorded_prune PROVEN "$_td/pruned"
    # 6) 某级无行 → PARTIAL（NODATA 不等于 PASS）
    printf '%s\tSEV1\tne\n%s\tSEV3\tnetcfg_repair\n' "$_D40" "$_D3" > "$_rowsf"
    mkfix "$_td/nodata" "$_rowsf" 0 0 0 1
    chk tier_nodata PARTIAL "$_td/nodata"
    # 7) 台账自身只有 2 天（SEV1 合同 7d 未到）→ GROWING，不是 FAIL
    printf '%s\tSEV1\tne\n%s\tSEV2\tsvc_restart\n%s\tSEV3\tnetcfg_repair\n' "$_D2" "$(( NOW - 86400 ))" "$NOW" > "$_rowsf"
    mkfix "$_td/growing" "$_rowsf" 0 0 0 1
    chk growing PARTIAL "$_td/growing"
    # 7b) 尾部删除 + rp 记账（seq 1..7 存在, 曾分配 1..10 → 尾部缺口 3, rp3=3）→ 必须 PROVEN
    printf '%s\tSEV1\tne\n%s\tSEV2\tsvc_restart\n%s\tSEV3\tnetcfg_repair\n' "$_D40" "$_D10" "$_D3" > "$_rowsf"
    mkfix "$_td/tailrp" "$_rowsf" 0 0 0 1
    _tl=$(wc -l < "$_td/tailrp/incidents.tsv"); _tb=$(wc -c < "$_td/tailrp/incidents.tsv")
    _tm=$(md5sum "$_td/tailrp/incidents.tsv" | cut -d' ' -f1)
    # 模拟"曾分配 seq 到 10、现只剩 1..3"：尾部缺口 7 必须由 rp3=7 记账
    printf 'op=repair ts=%s rows=%s bytes=%s md5=%s first_seq=1 last_seq=10 sev1=1 sev2=1 sev3=1 rm1=0 rm2=0 rm3=0 rp1=0 rp2=0 rp3=7 oldest_sev1_ts=- oldest_sev1_md5=- reason=test_tail\n' "$NOW" "$_tl" "$_tb" "$_tm" >> "$_td/tailrp/incidents.seal"
    chk tail_removal_rp PROVEN "$_td/tailrp"
    # 8) SEV1 被 prune 过（prune 行 rm1>0）→ 完整性红线 FAIL
    printf '%s\tSEV2\tsvc_restart\n%s\tSEV3\tnetcfg_repair\n' "$_D10" "$_D3" > "$_rowsf"
    mkfix "$_td/sev1gone" "$_rowsf" 1 0 0 2 prune
    chk sev1_pruned_flag FAIL "$_td/sev1gone"
    rm -rf "$_td"
    echo "retention_audit selftest cases=$_n failures=$_bad"
    [ "$_bad" -eq 0 ] || return 1
    return 0
}
case "$1" in
--selftest) selftest; exit $? ;;
esac

run_audit
case "$1" in
--quiet)
    echo "retention_audit ts=$NOW overall=$OVERALL sev1_days=$(sed -n 's/^TIER SEV1 .*oldest_age_days=\([0-9.]*\).*/\1/p' "$REPORT" 2>/dev/null) report=$REPORT"
    ;;
--json)
    echo "ts=$NOW overall=$OVERALL rows=$IL_ROWS md5_ok=$IL_OK_MD5 rows_ok=$IL_OK_ROWS gaps=$IL_GAPS gaps_accounted=$IL_OK_ACC sev1_never_pruned=$IL_OK_SEV1 presync=$IL_PRESYNC clock_skew=$CS_N backfill=$IL_BACKFILL drill=$IL_DRILLROWS hb_age=$_hb snap_ok=$SNAP_OK snap_tries=$SNAP_TRY"
    ;;
*)
    cat "$REPORT" 2>/dev/null
    ;;
esac
[ "$OVERALL" = FAIL ] && exit 1
exit 0
