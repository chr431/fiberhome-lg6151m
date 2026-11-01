#!/bin/sh
# core_meta.sh v1.13 -- core_pattern metadata wrapper (stability P1-2/P1-5).
# v1.13 (2026-11-01 A1 far-infra 轮): ne_events 行尾追加 **far=/pc= 两列** ——
#   致死率对齐(fault addr 是否压到活指针)此前无法执行: 行内没有 FAR/PC, 而
#   arm64 用户态 fault 行是 pr_info 级, console/syslog 都收不到。来源 = core
#   note 头(NT_SIGINFO si_addr + NT_PRSTATUS pc, 偏移已在真实设备 .hdr 上验
#   证, 与 oneoff/sigsegv/core_scan.py 一致)。
#   流序(旧流程零破坏): 先把 core 前 8KB 截到 /tmp(tmpfs, 不受 /data 满盘影
#   响; note 段实测在 456..2284), /data/gw/bin/coreaddr 解析出 far/pc 再写台
#   账行; 助手缺失/解析失败一律回退 far=- pc=-(旧消费方按列尾忽略)。
#   字节流保全: shell 自身持有 fd0, 早期截取不会令内核写侧 EPIPE; 台账/配额
#   完成后用 `cat 快照 -` 重建完整字节流喂 tee/aee(与 v1.12 直读 stdin 字节
#   一致, 同 64MB 截断语义)。残险(已接受并记录): tmpfs 8KB 写中途失败会丢
#   头部字节, aee 该次收到短 core —— /tmp 848MB 余量下实际不可达。
#   列数契约随之 8/9 -> 8/9/10/11; incident_ledger v1.6+/retention_audit v1.4+
#   同批放行 10/11 列。
# v1.12 (2026-11-01 R2-D NE 台账数据质量轮): **写入侧列数自检** —— 历史上有 243 行
#   碎片(argv 内含换行的 awk/sed 脚本直落 TSV) 把 8 列契约打破, 消费方(incident_ledger)
#   只能靠"非数字开头"猜。本版把契约做成写入侧的硬不变量: 构造行后数一遍列数,
#   不是 8/9 就把 args 降级为 MALFORMED(nf=N) 再写, 保证任何上游脏变量都写不出坏行。
#   同时 COMM/EXE/SIG 也过 flat()(换行/制表压平), 不再只依赖 ARGS/PARGS 已清洗。
# v1.10 (2026-10-31 质量轮): ne_events.tsv 加 4000 行上限(tail+原子 mv, 与
#   netcfg_repairs.tsv 同款) — 兄弟台账全有界, 唯独 NE 台账无界, 风暴下 /data
#   无限膨胀且采样器游标扫描成本随之增长。avail_sampler 的行数游标对轮转收缩
#   已有 head 近似分支(new_lines else 臂), 收缩安全。
#   同轮: stackdump 自 v1.10 起为 deploy manifest 正式件(源码 gw/src/stackdump.c,
#   此前靠手工推送 = 部署不可重现点)。
# v1.7 (2026-10-30 自然 NE 分类): 每次崩溃额外落一份 fault-time 栈窗口
#   (.stack = 16 pages = 64 KiB, 由 /data/gw/bin/stackdump 读 /proc/<pid>/mem)。
#   目的: 自然 NE 也能按“fault addr 是否对齐栈上记录”分类，不再只有 canary 有栈。
#   部署前: bump VERSIONS.tsv core_meta 版本; push stackdump 后 chmod 755。
# v1.6 (2026-10-29 取证配额): 每次崩溃都另存一份 4KB 的 note 头(.hdr = ELF 头 + PT_NOTE,
#   含全部寄存器与 siginfo: PC/SP/LR/故障地址)。完整 core 只留最新 6 份(几十 MB 级),
#   但**每一次**崩溃都能定位 —— 实测 19:03-23:48 有 35 起 NE, 完整 core 只留得下 3 份。
# v1.5 (2026-10-29 真 core 轮): 把内核递来的 core **同时**落一份原始副本到
#   /data/gw/logs/cores/raw/(tee 分叉, aee 照旧收到完整流) —— 崩溃归因需要 PC/寄存器/
#   栈, 而 aee 的 dump 是加密的。超过 64MB 截断: PT_NOTE(寄存器)在文件头, 截断仍可读。
#   只留最新 3 份(原始 core 几十 MB, /data 余量 1.7G)。
# v1.4 (2026-10-28 时钟轮): unsync 判据改为 /tmp/ntp_synced 缺失(权威) + 原年份
#   阈值兜底。原判据 epoch<2025-01-01 在构建日 2026-09-09 下永远不成立, 开机窗
#   口的 NE 行因此全部没有标记(实测 9 行 17889xxxxxx 无 unsync)。
# v1.3 (SIGSEGV §8.13): 旧内核修复栈退役 —— 删除 v1.1 加的 NE 探针(崩溃时向旧栈
#   /proc 节点写 deep 的那一行)。本脚本此后只做元数据落盘, 不再触碰任何模块。
# v1.2 (SIGSEGV Phase 0): ne_events.tsv 行尾增 origin 列
#   (our-tree/vendor-tree/unknown) —— 台账"归零"时区分"修好了"与"看不见了";
#   判定只看祖先链 comm/cmdline(静态农场 exe 全同, 不可判), 见 _origin()。
# v1.1: Census hygiene: argv newlines/tabs are squashed (multi-line args broke
#   TSV rows) and pre-NTP-sync epochs get an unsync=1 marker column.
#
# aee owns /proc/sys/kernel/core_pattern as
#     |/sbin/aee_core_forwarder /tmp %p %s %u %g
# and its dumps are encrypted: no process name, no registers, no map.  The
# 2026-10-19 crashes (logc twice, awk/ip/sh/grep/netstat) therefore had no
# attributable evidence (analysis §4).
#
# This wrapper keeps aee's behaviour intact -- after taking a snapshot it
# exec()s the very same forwarder with the same argv, and never touches stdin
# (the kernel streams the core there) -- but first records:
#   * pid/comm/signal/uid/gid, exe, cwd, parent, argv
#   * /proc/<pid>/status (Vm/task/threads/stack) and maps (capped)
#   * PATH only from environ (no other env vars: credentials must not land)
#   * the persistent dmesg mirror tail + aee db_history tail
# One file per crash in /data/gw/logs/cores/meta/, one TSV census line in
# /data/gw/logs/ne_events.tsv. 读取方 = avail_sampler.sh:74/92(行数游标)与
# :107-124(整行子串归属), 都不按列取值; incident_ledger.sh h_ne 按字段数形态
# 放行(6/7=旧格式, 8/9=v1.2..v1.12, 10/11=v1.13+ 带 far/pc) —— 故新列只许追加
# 在行尾。
#
# Safety: <=120 files kept; every command is absolute; failure to record must
# never prevent aee from getting the core (so no `set -e`, all errors ignored).

# core_pattern helpers run with a minimal kernel-provided environment: set PATH.
PATH=/data/gw/sbin:/data/gw/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
[ -z "${TZ:-}" ] && [ -r /etc/TZ ] && TZ=$(cat /etc/TZ 2>/dev/null) && export TZ
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=
DIR=/data/gw/logs/cores/meta
TSV=/data/gw/logs/ne_events.tsv
STACKDUMP=/data/gw/bin/stackdump
COREADDR=/data/gw/bin/coreaddr
PID=${1:-0}
SIG=${2:-0}
UID_=${3:-0}
GID=${4:-0}
case "$PID" in ''|*[!0-9]*) exit 0 ;; esac
[ "$PID" -gt 0 ] || exit 0

uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null; }
rlink() { if [ -n "$BB" ]; then "$BB" readlink "$1" 2>/dev/null; else readlink "$1" 2>/dev/null; fi; }
catf() { if [ -n "$BB" ]; then "$BB" cat "$1" 2>/dev/null; else cat "$1" 2>/dev/null; fi; }

mkdir -p "$DIR" 2>/dev/null
_bt=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
_ts=$(date +%s)
F=$DIR/${_bt}-${PID}-${_ts}.txt
STACK=$DIR/${_bt}-${PID}-${_ts}.stack
COMM=$(catf /proc/$PID/comm)
EXE=$(rlink /proc/$PID/exe)
PPID_=$(awk '{print $4}' /proc/$PID/stat 2>/dev/null)
PCOMM=$(catf /proc/$PPID_/comm)
# v1.11 (巡检轮): ARGS/PARGS 换行/制表压平 — awk 脚本类 argv 自带字面换行,
#   直落 TSV 即破行(今晨 6 行碎片混入台账; v1.1 声称的清洗在后续改动中丢失)。
PARGS=$(tr '\0' ' ' 2>/dev/null < /proc/$PPID_/cmdline | tr '\n\r\t' '   ' | head -c 300)
ARGS=$(tr '\0' ' ' 2>/dev/null < /proc/$PID/cmdline | tr '\n\r\t' '   ' | head -c 600)

{
    echo "# core metadata (core_meta v1.13)"
    echo "epoch=$_ts date=$(date '+%Y-%m-%d %H:%M:%S') uptime=$(uptime_s) btime=$_bt"
    echo "pid=$PID comm=[$COMM] signal=$SIG uid=$UID_ gid=$GID_"
    echo "exe=[$EXE] ppid=$PPID_ pcomm=[$PCOMM]"
    echo "parent_args=[$PARGS]"
    echo "args=[$ARGS]"
    echo "stack=[$STACK]"
    echo "--- status (selected) ---"
    if [ -n "$BB" ]; then
        "$BB" grep -E '^(Name|State|Tgid|Pid|PPid|Uid|Gid|Threads|SigQ|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt|CapEff|voluntary|nonvoluntary):' /proc/$PID/status 2>/dev/null
    else
        grep -E '^(Name|State|Tgid|Pid|PPid|Uid|Gid|Threads|SigQ|SigPnd|ShdPnd|SigBlk|SigIgn|SigCgt|CapEff|voluntary|nonvoluntary):' /proc/$PID/status 2>/dev/null
    fi
    echo "cwd=[$(rlink /proc/$PID/cwd)]"
    echo "fds=$(ls /proc/$PID/fd 2>/dev/null | wc -l)"
    # PATH only: environ can carry credentials, never copy it wholesale
    echo "env_path=[$(tr '\0' '\n' < /proc/$PID/environ 2>/dev/null | grep '^PATH=' | head -1)]"
    echo "--- maps (first 80) ---"
    catf /proc/$PID/maps | head -n 80
    echo "--- maps tail (last 20) ---"
    catf /proc/$PID/maps | tail -n 20
    echo "--- dmesg mirror tail ---"
    tail -n 80 /data/gw/logs/dmesg.log 2>/dev/null
    echo "--- aee db_history tail ---"
    tail -n 5 /data/log/aee_exp/db_history 2>/dev/null
} > "$F" 2>/dev/null

# v1.7: fault-time stack window (process is stopped; /proc/<pid>/mem is valid)
# v1.8: keep stackdump stderr and rc in a .stackerr file so a missing .stack can
#       be diagnosed from the field (PID/permission/timing).
if [ -x "$STACKDUMP" ]; then
    "$STACKDUMP" "$PID" "$STACK" 16 >/dev/null 2>"$DIR/${_bt}-${PID}-${_ts}.stackerr"
    _src=$?
    [ "$_src" -ne 0 ] && STACK=""
else
    STACK=""
fi

# ---- v1.2: origin 归属 -----------------------------------------------------
# 静态农场下 exe 不可用于判定: 崩溃进程和它的祖先几乎都是同一个静态件
# (/data/gw/bin/busybox 或静态工具本体), exe 永远是那个二进制, 看不出崩在谁的
# 子树里。唯一可用信号是每一层的 comm 与 cmdline(脚本路径只出现在 cmdline)。
# 规则: 从崩溃进程自身(第 0 层)沿 /proc/<pid>/stat 的 ppid 向上最多 3 层,
#   任一层 comm/cmdline 命中自研件集合 → our-tree;
#   链走到 pid 1 (procd/init) 仍未命中     → vendor-tree;
#   链断(进程已被回收/ppid 读不成数字)或超 3 层 → unknown。
OURSET="rc19.sh rc.extend.sh v3_rc10.extend.sh boot_gate.sh log_keeper.sh \
watchdog.sh led_mgr.sh dial_keeper.sh wan_agg.sh healthdog.sh core_meta.sh \
avail_sampler.sh ntp_keeper.sh reboot_sched.sh traffic_logger.sh wifi_guard.sh \
fan_mgr.sh wan_eth.sh usb_mgr.sh v3httpd selftest"

_origin() { # $1=崩溃 pid; 输出 our-tree|vendor-tree|unknown
	_d=$1
	_lv=0
	while [ "$_lv" -le 3 ]; do
		case "$_d" in ''|*[!0-9]*) break ;; esac
		[ "$_d" -gt 0 ] || break
		_c=$(catf /proc/$_d/comm)
		_cl=$(tr '\0' ' ' 2>/dev/null < /proc/$_d/cmdline | head -c 300)
		for _p in $OURSET; do
			case "$_c" in *"$_p"*) echo our-tree; return 0 ;; esac
			case "$_cl" in *"$_p"*) echo our-tree; return 0 ;; esac
		done
		[ "$_d" = 1 ] && { echo vendor-tree; return 0; }
		_d=$(awk '{print $4}' /proc/$_d/stat 2>/dev/null)
		_lv=$((_lv + 1))
	done
	echo unknown
}

# one-line census; 列序固定(新列只许加在行尾):
#   ts / pid / comm / sig=N / exe=路径 / args=... / [unsync=1] / origin=归属 /
#   stack=... / far=0x.. / pc=0x..
# v1.1: unsync marker when the clock is obviously pre-NTP (epoch < 2025-01-01)
# so boot-window NE rows can be told apart instead of landing in 1970 buckets
_us=""
{ [ ! -s /tmp/ntp_synced ] || [ "${_ts:-0}" -lt 1735689600 ]; } 2>/dev/null && _us="unsync=1"
_or=$(_origin "$PID")
case "$_or" in our-tree|vendor-tree) ;; *) _or=unknown ;; esac

# ---- v1.13: FAR/PC 提取(note 头快照 -> coreaddr) -----------------------------
# mkdir 失败 = v1.12 的 exec-forwarder 路径, 此时不动 stdin(快照为空, far/pc
# 空列)。快照放 tmpfs: 写它不受 /data 水位影响; 8KB 覆盖 note 段有余。
_rawd=/data/gw/logs/cores/raw
_t=""
_fa="-"; _pp="-"
if mkdir -p "$_rawd" 2>/dev/null; then
    _t=/tmp/cmnote.$$
    head -c 8192 > "$_t" 2>/dev/null || true
    [ -s "$_t" ] || _t=""
fi
if [ -n "$_t" ] && [ -x "$COREADDR" ]; then
    _out=$("$COREADDR" "$_t" 2>/dev/null) || _out=""
    _fa=$(printf '%s\n' "$_out" | sed -n 's/^far=//p' | head -1)
    _pp=$(printf '%s\n' "$_out" | sed -n 's/^pc=//p' | head -1)
    case "$_fa" in 0x[0-9a-f]*) ;; *) _fa="-" ;; esac
    case "$_pp" in 0x[0-9a-f]*) ;; *) _pp="-" ;; esac
fi

# v1.12: 写入侧列数自检（v1.13 起 8/9 = 旧行, 10/11 = 带 far/pc）。任何字段混入
# TAB 或换行都会把行撑破 —— 历史实弹 243 行碎片就是这么来的。宁可降级 args 也
# 不写坏行。far/pc 由 coreaddr 产出(纯 0x 十六进制)不过 flat(), 但 case 卫生检
# 查在上面已把非 0x[0-9a-f]* 一律钉成 "-"。
flat() { printf '%s' "$1" | tr '\n\r\t' '   '; }
_c=$(flat "${COMM:-?}"); _s=$(flat "$SIG"); _x=$(flat "${EXE:-?}"); _a=$(flat "${ARGS:-?}"); _k=$(flat "${STACK:-}")
if [ -n "$_us" ]; then
    _line=$(printf '%s\t%s\t%s\tsig=%s\texe=%s\targs=%s\t%s\torigin=%s\tstack=%s\tfar=%s\tpc=%s' "$_ts" "$PID" "$_c" "$_s" "$_x" "$_a" "$_us" "$_or" "$_k" "$_fa" "$_pp")
else
    _line=$(printf '%s\t%s\t%s\tsig=%s\texe=%s\targs=%s\torigin=%s\tstack=%s\tfar=%s\tpc=%s' "$_ts" "$PID" "$_c" "$_s" "$_x" "$_a" "$_or" "$_k" "$_fa" "$_pp")
fi
_nf=$(printf '%s' "$_line" | awk -F'\t' '{print NF}')
case "$_nf" in
8|9) ;;   # 兼容: far/pc 为空写入路径理论上不产生(恒有占位), 保守放行
10|11) ;;
*)  _line=$(printf '%s\t%s\t%s\tsig=%s\texe=%s\targs=MALFORMED(nf=%s)\torigin=%s\tstack=%s\tfar=%s\tpc=%s' "$_ts" "$PID" "$_c" "$_s" "$_x" "$_nf" "$_or" "$_k" "$_fa" "$_pp") ;;
esac
[ -s "$F" ] && printf '%s\n' "$_line" >> "$TSV" 2>/dev/null

# v1.10: census cap -- keep the newest 4000 rows (atomic tail+mv).  Readers
# (avail_sampler line cursors) already tolerate rotation shrinkage.
_n=$(wc -l < "$TSV" 2>/dev/null)
case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
[ "$_n" -gt 4000 ] && tail -n 4000 "$TSV" > "$TSV.tmp.$$" 2>/dev/null && mv -f "$TSV.tmp.$$" "$TSV"

# quota: keep the 300 newest metadata files
_n=$(ls "$DIR" 2>/dev/null | wc -l)
if [ "${_n:-0}" -gt 300 ]; then
    ls -t "$DIR" 2>/dev/null | tail -n +301 | while read -r _f; do rm -f "$DIR/$_f"; done
fi

# v1.7: stack window quota (64 KiB each; keep 200 newest)
_n=$(ls "$DIR"/*.stack 2>/dev/null | wc -l)
if [ "${_n:-0}" -gt 200 ]; then
    ls -t "$DIR"/*.stack 2>/dev/null | tail -n +201 | while read -r _f; do rm -f "$DIR/$_f"; done
fi

# --- hand the core to aee exactly as before ---------------------------------
# v1.13: 已截取 note 快照(_t)时用 `cat 快照 -` 重建完整字节流 —— tee/aee 收到
# 的字节与 v1.12 直读 stdin 完全一致(含同样的 64MB 截断语义)。快照为空
# (mkdir 失败)时走 exec, stdin 原封未动 = v1.12 行为。
if [ -x /sbin/aee_core_forwarder ]; then
    if [ -d "$_rawd" ]; then
        _raw="$_rawd/${_bt}-${PID}-${_ts}.core"
        if [ -n "$_t" ]; then
            cat "$_t" - | head -c 67108864 | tee "$_raw" | /sbin/aee_core_forwarder /tmp "$PID" "$SIG" "$UID_" "$GID"
        else
            head -c 67108864 | tee "$_raw" | /sbin/aee_core_forwarder /tmp "$PID" "$SIG" "$UID_" "$GID"
        fi
        _crc=$?
        rm -f "$_t" 2>/dev/null
        # v1.6: 先留 note 头(4KB), 再按配额裁完整 core
        head -c 4096 "$_raw" > "${_raw%.core}.hdr" 2>/dev/null
        ls -t "$_rawd"/*.core 2>/dev/null | tail -n +7 | while read -r _f; do rm -f "$_rawd/$_f"; done
        ls -t "$_rawd"/*.hdr 2>/dev/null | tail -n +201 | while read -r _f; do rm -f "$_rawd/$_f"; done
        exit $_crc
    fi
    exec /sbin/aee_core_forwarder /tmp "$PID" "$SIG" "$UID_" "$GID"
fi
[ -n "$_t" ] && rm -f "$_t" 2>/dev/null
exit 0
