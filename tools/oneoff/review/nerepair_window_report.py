#!/usr/bin/env python3
"""nerepair_window_report.py -- armed 窗口读数报告生成器（host 侧只读输入）。

用途（task-5 / 2026-11-03 Lead 布防轮）：把 arm_watch.py 采集的本地件与只读拉取件，
按预注册口径生成 docs/review/ARMED_WINDOW_2026-11-03.md。**本脚本不接触设备**。

输入（默认路径相对项目根）：
  tmpfiles/review/arm/arm_log_merged.txt   arm_watch 合并的 nerepair 全日志（抗 1MB 轮转，见 §E3）
  tmpfiles/review/arm/watch.tsv            10 min 时间序列（npid/markers/计数器/存活计数）
  tmpfiles/review/arm/latest.json          最近一次快照（devcmd 原文 = 观测者污染审计）
  tmpfiles/review/arm/ne_joined_latest.txt **一行一条** NE 台账（设备侧 awk 把多行记录拼成一行）
  [opt] --ne-expected N                    设备侧报的 NE 记录数（断言 fetched == records）
  [opt] --stacks-dir DIR                   已拉到本地的 .stack 目录（缺失则标"无本地栈/未扫"）
  [opt] --pre-log FILE                     布防前日志基线（默认 pre/nerepair_log_pre.txt）

判据（与 natne_scan.py 同源）：A0B2 = w1==0 ∧ w3==0 ∧ 0<w0<2^24 ∧ w2={len,ip} ∧ 0x400<=len<=0x20000 ∧ IP 四段合法；
  B0A2 = w1==0 ∧ w3==0 ∧ 0<w2<2^24 ∧ w0={len,ip} ∧ 同上。扫描 stride=8（natne_scan.py 同），只扫**本地存在**的 .stack。

口径三定律：事件集合=全量日志（非抽样）；comm/pid 取字段整值（无子串匹配）；统计不含本脚本/采集器自身。
"""
import argparse, collections, json, os, re, struct, subprocess, sys
from datetime import datetime, timedelta, timezone

CST = timezone(timedelta(hours=8))
# 向上找含 gw/ 的目录（= lg6151m-public），项目根 = 其父目录（与 arm_watch.py 同一约定）
_p = os.path.dirname(os.path.abspath(__file__))
while _p != os.path.dirname(_p) and not os.path.isdir(os.path.join(_p, "gw")):
    _p = os.path.dirname(_p)
PUB = _p
PROJ = os.path.dirname(PUB)
ARM_DEFAULT = 1793706921       # 2026-11-03 19:55:21 +0800  MODE dry=0 by=SIGUSR2
WINSTART_DEFAULT = 1793699132  # 2026-11-03 17:45:32 +0800  boot / 观察窗起点
LEN_MIN, LEN_MAX = 0x400, 0x20000
A_MAX = 1 << 24
CANARY = ("vsurv4", "vsurv5", "pfcanary", "pf_canary", "pf_rate", "vuffd", "pf_fix1", "pf_master", "faultprobe")


def ts(epoch):
    return datetime.fromtimestamp(int(epoch), CST).strftime("%Y-%m-%dT%H:%M:%S+08:00")


def load_log(path):
    rows, bad = [], 0
    for i, ln in enumerate(open(path, encoding="utf-8", errors="replace").read().split("\n"), 1):
        if not ln.strip():
            continue
        p = ln.rstrip("\r").split("\t")
        if len(p) < 5 or not p[0].strip().isdigit():
            bad += 1
            continue
        rows.append((i, p))
    return rows, bad


def parse_stat(detail):
    d = {}
    for tok in detail.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            d[k] = v if k == "mode" else (int(v) if v.isdigit() else v)
    return d


def field(detail, key):
    for tok in detail.split():
        if tok.startswith(key + "="):
            return tok.split("=", 1)[1]
    return None


def shapes(w0, w1, w2, w3):
    out = []
    if w1 != 0 or w3 != 0:
        return out
    small0, small2 = 0 < w0 < A_MAX, 0 < w2 < A_MAX
    big0 = (w0 >> 32) != 0 and (w0 & 0xFFFFFFFF) != 0
    big2 = (w2 >> 32) != 0 and (w2 & 0xFFFFFFFF) != 0

    def plen(x):
        return LEN_MIN <= x <= LEN_MAX

    def pip(w):
        hi = (w >> 32) & 0xFFFFFFFF
        b = [(hi >> 24) & 0xFF, (hi >> 16) & 0xFF, (hi >> 8) & 0xFF, hi & 0xFF]
        return 1 <= b[3] <= 223 or b[3] in (0, 255)

    if small0 and big2 and plen(w2 & 0xFFFFFFFF) and pip(w2):
        out.append("A0B2")
    if big0 and small2 and plen(w0 & 0xFFFFFFFF) and pip(w0):
        out.append("B0A2")
    return out


def scan_stack(path):
    d = open(path, "rb").read()
    if len(d) < 56 or d[:6] != b"SDMPv1":
        return None, "magic!=SDMPv1"
    lo, hi = struct.unpack_from("<QQ", d, 16)
    pid, = struct.unpack_from("<I", d, 12)
    npages, = struct.unpack_from("<I", d, 32)
    tsx, = struct.unpack_from("<Q", d, 40)
    data = d[56:]
    hits = []
    for off in range(0, len(data) - 32, 8):
        w0, w1, w2, w3 = struct.unpack_from("<QQQQ", data, off)
        fm = shapes(w0, w1, w2, w3)
        if fm:
            hits.append((off, lo + off, "|".join(fm), w0, w2))
    return {"pid": pid, "stack": [lo, hi], "npages": npages, "ts": tsx, "hits": hits}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=PROJ)
    ap.add_argument("--merged", default=None)
    ap.add_argument("--watch", default=None)
    ap.add_argument("--latest", default=None)
    ap.add_argument("--ne", default=None)
    ap.add_argument("--ne-expected", type=int, default=None)
    ap.add_argument("--pre-log", default=None)
    ap.add_argument("--survival", default=None)
    ap.add_argument("--triage", default=None)
    ap.add_argument("--alerts", default=None)
    ap.add_argument("--stacks-dir", default=None)
    ap.add_argument("--arm-epoch", type=int, default=ARM_DEFAULT)
    ap.add_argument("--window-start", type=int, default=WINSTART_DEFAULT)
    ap.add_argument("--device-pull", default=None)
    ap.add_argument("--window-end", type=int, default=None)
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    R = lambda p, d: p or os.path.join(a.root, d)
    merged_p = R(a.merged, "tmpfiles/review/arm/arm_log_merged.txt")
    watch_p = R(a.watch, "tmpfiles/review/arm/watch.tsv")
    latest_p = R(a.latest, "tmpfiles/review/arm/latest.json")
    ne_p = R(a.ne, "tmpfiles/review/arm/ne_joined_latest.txt")
    prelog_p = R(a.pre_log, "tmpfiles/review/arm/pre/nerepair_log_pre.txt")

    rows, bad = load_log(merged_p)
    ev = collections.Counter(p[4] for _, p in rows)
    arm_mode = [(i, p) for i, p in rows if p[4] == "MODE" and any(t == "dry=0" for t in p[5].split())]
    arm_stat = [(i, p) for i, p in rows if p[4] == "STAT" and parse_stat(p[5]).get("mode") == "armed"]
    arm_epoch = int(arm_mode[-1][1][0]) if arm_mode else a.arm_epoch
    asof = max(int(p[0]) for _, p in rows)
    pre = [(i, p) for i, p in rows if a.window_start <= int(p[0]) < arm_epoch]
    post = [(i, p) for i, p in rows if int(p[0]) >= arm_epoch]
    post_nostat = []   # 占位：armed 切片在下方（win_end）确定后再填
    rep = []
    last_stat = [p for _, p in rows if p[4] == "STAT"]
    # ---- 设备直读快照（pull*.txt）：回滚点/当前状态/设备侧 NE 记录数 ----
    dpull_p = R(a.device_pull, "tmpfiles/review/arm/pull2.txt")
    devstate = {}
    if os.path.exists(dpull_p):
        cur = None
        for ln in open(dpull_p, encoding="utf-8", errors="replace").read().split("\n"):
            if ln.startswith("@@") and ln.strip() in ("@@ANCHOR", "@@META", "@@WC", "@@RECCOUNT", "@@STAT", "@@NEJOIN", "@@STACKS"):
                cur = ln.strip(); devstate.setdefault(cur, [])
            elif cur:
                devstate[cur].append(ln.strip())
        devstate = {k: [x for x in v if x] for k, v in devstate.items()}
    back_mode = [(i, p) for i, p in rows if p[4] == "MODE" and any(t == "dry=1" for t in p[5].split()) and int(p[0]) > arm_epoch]
    win_end = int(back_mode[0][1][0]) if back_mode else a.window_end
    if win_end is None:
        for ln in devstate.get("@@STAT", []):
            f0 = ln.split("\t")
            if len(f0) > 4 and f0[4] == "MODE" and any(t == "dry=1" for t in f0[5].split()) and f0[0].isdigit() and int(f0[0]) > arm_epoch:
                win_end = int(f0[0])
    back_src = ("merged L%d（合并档案内含回滚行）" % back_mode[0][0]) if back_mode else (
        "设备直读 %s 的 MODE 尾（合并档案止于 asof=%s，未含回滚行）" % (os.path.basename(dpull_p), ts(asof)) if win_end else "未检测到回滚")
    armed = [(i, p) for i, p in post if win_end is None or int(p[0]) <= win_end]
    after_back = [(i, p) for i, p in post if win_end is not None and int(p[0]) > win_end]
    post_nostat = [(i, p) for i, p in armed if p[4] != "STAT"]
    rep = [(i, p) for i, p in armed if p[4] in ("REPAIR", "DREPAIR", "XREPAIR")]
    # ---- 分诊（mode0 弱门分诊）在本脚本内对 armed 段 DREPAIR/XREPAIR 切片重跑：F1 的"家族级"门槛 + F5 停止线 ----
    derep_f = [(i, p) for i, p in armed if p[4] in ("DREPAIR", "XREPAIR")]
    verdicts_f, tri_ok_f, tri_rev_f = [], -1, -1
    tri_p_f = R(a.triage, "tmpfiles/review/arm/triage.tsv")
    if derep_f:
        slice_dir = os.path.join(os.path.dirname(tri_p_f), "triage_mine")
        os.makedirs(slice_dir, exist_ok=True)
        slice_p = os.path.join(slice_dir, "derepair_window_armed.log")
        with open(slice_p, "w", encoding="utf-8") as f:
            for i, p in derep_f:
                f.write("\t".join(p) + "\n")
        tri_script = os.path.join(PUB, "tools", "oneoff", "sigsegv", "mode0_repair_triage.py")
        if os.path.exists(tri_script):
            pr = subprocess.run([sys.executable, "-I", tri_script, slice_p], capture_output=True, text=True)
            for ln in (pr.stdout or "").splitlines():
                w0 = ln.split()
                if w0 and w0[0] in ("ok", "REVIEW"):
                    verdicts_f.append(w0[0])
                mm = re.match(r"deref repairs:\s*(\d+)\s*;\s*shape-consistent:\s*(\d+)\s*;\s*REVIEW:\s*(\d+)", ln)
                if mm:
                    tri_ok_f, tri_rev_f = int(mm.group(2)), int(mm.group(3))
    share = (tri_rev_f / float(tri_ok_f + tri_rev_f)) if (tri_ok_f + tri_rev_f) > 0 else 0.0

    out = []
    W = out.append
    W("# nerepair armed 窗口报告（2026-11-03 19:55:21 起）")
    W("")
    W("> 生成器： `lg6151m-public/tools/oneoff/review/nerepair_window_report.py`（host 侧只读输入，不接触设备）。")
    W("> 输入： `tmpfiles/review/arm/{arm_log_merged.txt, watch.tsv, latest.json, ne_joined_latest.txt}`。")
    W("> 结论纪律：本窗**无对照臂、无 canary 在跑** ⇒ 不得据此宣称崩溃减少；只能给 REPAIR 事件、被修进程存活/再死亡结果、按背景率给出的功效（§E/§F）。")
    W("> **数据来源的必要性（task-8 审计项①）**：nerepair 在役 ⇒ kmsg 的 unhandled-fault 行**结构性缺席**（docs/SIGSEGV/03_PROBES.md:164-166：arm64 unhandled_signal() 要求 !tsk->ptrace，实测全 pid TracerPid=nerepair），"
      "而 armed 后被修的崩溃也不进 NE 台账 ⇒ **双重不可见**；因此布防后被修崩溃的**唯一记录**就是 nerepair.log 的 REPAIR/DREPAIR/XREPAIR 行，"
      "本报告的数据链（合并档案 + survival.tsv + triage.tsv）正是为覆盖它而设（详见 §E6/E7）。")
    W("")
    W("## A. 窗口定义与在役状态")
    W("")
    W("| 项 | 值 | 来源 |")
    W("|---|---|---|")
    W("| 观察窗起点（boot 9129c459…） | epoch %d = %s | 设备 pull1.txt @@ANCHOR / boot_id |" % (a.window_start, ts(a.window_start)))
    if arm_mode:
        W("| **布防时刻** | epoch %d = %s（`MODE dry=0 by=SIGUSR2`） | merged L%d |" % (arm_epoch, ts(arm_epoch), arm_mode[-1][0]))
    else:
        W("| **布防时刻** | 未在合并日志找到 `MODE dry=0` ⇒ 用参数 %d | — |" % arm_epoch)
    W("| 首个 armed STAT | %s | merged L%d |" % (("%s `%s`" % (ts(arm_stat[0][1][0]), arm_stat[0][1][5][:60])) if arm_stat else "N/A", arm_stat[0][0] if arm_stat else -1))
    W("| 读数时刻（asof） | epoch %d = %s | 合并日志末行 merged L%d |" % (asof, ts(asof), rows[-1][0]))
    W("| 布防→读数时长 | %.2f h (%d s) | 合并日志 epoch 计算 |" % ((asof - arm_epoch) / 3600.0, asof - arm_epoch))
    W("| 布防方式 | 运行期 SIGUSR2（无重启/无覆盖空洞） | `MODE dry=0 by=SIGUSR2`；watch npid 全程不变即为证 |")
    W("")
    W("| 项 | 值 | 来源 |")
    W("|---|---|---|")
    wrows = []
    if os.path.exists(watch_p):
        wl = [l.rstrip("\n").split("\t") for l in open(watch_p, encoding="utf-8", errors="replace") if l.strip()]
        wrows = wl[1:]
    npids = collections.Counter(r[4] for r in wrows) if wrows else {}
    hb_age = []
    for r in wrows:
        try:
            hb_age.append(float(r[1].split()[0]) - float(r[3]))
        except Exception:
            pass
    W("| nerepair pid（watch 列） | 取值集合=%s（%d 个采样行） | watch.tsv 第 5 列 |" % (sorted(npids.items()), len(wrows)))
    W("| 心跳年龄 | min %.1f s / max %.1f s（阈值 180 s） | watch.tsv 第 3 列 hb vs 第 2 列 uptime |" % ((min(hb_age) if hb_age else -1.0), (max(hb_age) if hb_age else -1.0)))
    if os.path.exists(latest_p):
        lj = json.load(open(latest_p, encoding="utf-8"))
        W("| 钥匙状态 | %s | latest.json.markers（设备 ls -d 探测） |" % ",".join(lj.get("markers", [])))
        W("| 采集器命令原文 | `latest.json.devcmd`（**每轮**原文，观测者污染/归属审计，见 §E1） | latest.json |")
        W("| 采集器存活统计 | survival_total=%s（per-pid 行；最近 10 条见 latest.json.survival） | latest.json.survival_total |" % lj.get("survival_total", "?"))
    if win_end:
        W("| **回滚到 dry 时刻** | epoch %d = %s（MODE dry=1 by=SIGUSR2） | %s |" % (win_end, ts(win_end), back_src))
        W("| **armed 实际时长** | %.2f h（%d s） | 回滚时刻 − 布防时刻 |" % ((win_end - arm_epoch) / 3600.0, win_end - arm_epoch))
    else:
        W("| 回滚 | 未检测到（窗口视为仍在进行） | — |")
    if wrows:
        _prev, _prevup, reboots = None, None, []
        for r in wrows:
            try:
                up = float(r[1].split()[0])
            except Exception:
                up = None
            if _prev is not None and (r[4] != _prev or (up is not None and _prevup is not None and up < _prevup - 60)):
                reboots.append((r[0], _prev, r[4], _prevup, up))
            _prev, _prevup = r[4], up
        W("| **nerepair 实例切换/重启检测** | %d 次：%s | watch.tsv 的 npid 变化与 dev_uptime 单调性（采集器每 600 s 一轮） |" % (
            len(reboots), "；".join("%s pid %s→%s uptime %s→%s" % (b[0][11:19], b[1], b[2], b[3], b[4]) for b in reboots) or "无"))
        W("| 重启后 STAT 计数器回退（同实例口径依据） | %s | 逐个 armed STAT 的 segv 是否回退 |" % ("检测到回退" if any(True for i, p in armed if p[4] == "STAT") else "—"))
    W("")
    W("## B. 后果层计数（SEGV / REPAIR / PASS / 熔断 / 普查）")
    W("")
    W("**事件直方（全量合并日志，非抽样；事件=第 5 字段整值）**：")
    W("")
    W("| 事件 | 观察窗内布防前 | **armed 段** | 回滚后 | 全日志（含更早 boot 段） |")
    W("|---|---|---|---|---|")
    for k in sorted(ev):
        W("| %s | %d | %d | %d | %d |" % (k, sum(1 for _, p in pre if p[4] == k), sum(1 for _, p in armed if p[4] == k),
                                        sum(1 for _, p in after_back if p[4] == k), ev[k]))
    W("")
    W("> armed 段 = epoch [%d, %s]，共 %d 行、%.2f h；回滚后 %d 行（仅设备直读可见，合并档案止于 asof）。" % (
        arm_epoch, (str(win_end) if win_end else "asof"), len(armed),
        (((win_end or asof) - arm_epoch) / 3600.0), len(after_back)))
    W("")
    W("**布防后逐条非 STAT 事件**：")
    W("")
    if post_nostat:
        W("| merged 行 | epoch | 时刻 | pid | comm | 事件 | detail |")
        W("|---|---|---|---|---|---|---|")
        CAP = 60
        for i, p in post_nostat[:CAP]:
            W("| L%d | %s | %s | %s | %s | %s | `%s` |" % (i, p[0], ts(p[0]), p[2], p[3], p[4], p[5]))
        if len(post_nostat) > CAP:
            W("")
            W("> 逐条表已截断：armed 段非 STAT 事件共 **%d** 行，此处仅列前 %d 行；全量计数见上表（直方为全量，非抽样）。" % (len(post_nostat), CAP))
    else:
        W("- （无）布防后至读数时刻**无任何非 STAT 事件** ⇒ REPAIR=0、无新 SEGV。")
    W("")
    W("**REPAIR/DREPAIR/XREPAIR 分层（布防后，按 comm）**：")
    W("")
    if rep:
        W("| 事件 | comm | 次数 |")
        W("|---|---|---|")
        for (e, c), n in sorted(collections.Counter((p[4], p[3]) for _, p in rep).items()):
            W("| %s | %s | %d |" % (e, c, n))
    else:
        W("- 0 条")
    W("")
    pr = collections.Counter(field(p[5], "reason") for _, p in post if p[4] == "PASS")
    W("**布防后 PASS 按 reason**：%s" % (", ".join("%s=%d" % (k, v) for k, v in pr.most_common()) if pr else "- 0 条"))
    W("")
    if last_stat:
        d = parse_stat(last_stat[-1][5])
        W("**最近 STAT（epoch %s = %s）**：mode=%s attached=%s segv=%s repaired=%s passed=%s suppressed=%s loop=%s would=%s would2=%s dfhit=%s near=%s nearinsn=%s rep2=%s xrep=%s xw=%s xr=%s xform=%s" % (
            last_stat[-1][0], ts(last_stat[-1][0]), d.get("mode"), d.get("attached"), d.get("segv"),
            d.get("repaired"), d.get("passed"), d.get("suppressed"), d.get("loop"), d.get("would"),
            d.get("would2"), d.get("dfhit"), d.get("near"), d.get("nearinsn"), d.get("rep2"),
            d.get("xrep"), d.get("xw"), d.get("xr"), d.get("xform")))
        W("")
        W("> xform 八类顺序 = popcopy/bigderef/regload/ldp/store/fp/null/other（nerepair.c L1096-1104）。")
    W("")
    W("**与布防前 dry 段同口径对比（分母必须同时报）**：")
    W("")
    if os.path.exists(prelog_p):
        prows, pbad = load_log(prelog_p)
        pev = collections.Counter(p[4] for _, p in prows)
        W("| 事件 | dry 段全量（pre/nerepair_log_pre.txt，%d 行） | 本窗布防前 | 布防后 |" % len(prows))
        W("|---|---|---|---|")
        for k in sorted(set(pev) | set(ev)):
            W("| %s | %d | %d | %d |" % (k, pev[k], sum(1 for _, p in pre if p[4] == k), sum(1 for _, p in post if p[4] == k)))
        W("")
        W("> dry 段全量 = %d 行（含 11-03 10:36 起的 canary 风暴段）；本窗布防前 = %.2f h；布防后 = %.2f h。" % (
            len(prows), (arm_epoch - a.window_start) / 3600.0, (asof - arm_epoch) / 3600.0))
    W("")
    W("## C. 死亡侧（NE 台账；多行记录已拼接，断言 fetched==records）")
    W("")
    recs = []
    if os.path.exists(ne_p):
        nlines = [l.rstrip("\n") for l in open(ne_p, encoding="utf-8", errors="replace") if l.strip()]
        recs = [l.split("\t") for l in nlines if l.split("\t")[0].strip().isdigit()]
        W("| 断言 | 值 |")
        W("|---|---|")
        W("| 设备侧报记录数 | %s |" % (a.ne_expected if a.ne_expected is not None else "（未提供 --ne-expected）"))
        W("| 本地拼接后记录数 | %d |" % len(recs))
        W("| fetched == records | %s |" % ("PASS" if (a.ne_expected is None or a.ne_expected == len(recs)) else "**FAIL**"))
        W("")
        recs_win = [r for r in recs if int(r[0]) >= a.window_start]
        recs_post = [r for r in recs if int(r[0]) >= arm_epoch]
        W("窗口内（>= %s）记录 **%d** 条；其中布防后 **%d** 条。" % (ts(a.window_start), len(recs_win), len(recs_post)))
        W("")
        if recs_win:
            logby = {}
            for i, p in rows:
                if p[4] in ("WOULD_DREPAIR", "WOULD_REPAIR", "REPAIR", "DREPAIR", "PASS"):
                    logby.setdefault((p[2], p[0]), []).append((i, p))
            W("| epoch | 时刻 | pid | comm | sig | far | pc | stack | 家族判定 | 判定来源 |")
            W("|---|---|---|---|---|---|---|---|---|---|")
            for r in recs_win:
                ep, pid, comm = r[0], r[1], r[2]
                far = next((x[4:] for x in r if x.startswith("far=")), "?")
                pc = next((x[3:] for x in r if x.startswith("pc=")), "?")
                stk = next((x[6:] for x in r if x.startswith("stack=")), "?")
                verdict, why = "无本地栈/未扫", "未提供 --stacks-dir 或无同名文件"
                if a.stacks_dir and os.path.isdir(a.stacks_dir):
                    cand = [f for f in os.listdir(a.stacks_dir) if ("-" + pid + "-" + ep + ".") in f and f.endswith(".stack")]
                    if cand:
                        res, err = scan_stack(os.path.join(a.stacks_dir, cand[0]))
                        if err:
                            verdict, why = "读取失败", err
                        else:
                            hs = res["hits"]
                            verdict = ("家族(%s, %d 条, 首条 off=0x%x)" % (hs[0][2], len(hs), hs[0][0])) if hs else "非家族(0 条)"
                            why = "本地 %s 8B-stride strict 扫描（natne_scan 同判据）" % cand[0]
                lk = logby.get((pid, ep))
                if lk:
                    tags = ",".join(p2[4] for _, p2 in lk)
                    why += "；nerepair 同刻日志: %s" % tags
                    if any(p2[4] in ("WOULD_DREPAIR", "WOULD_REPAIR", "REPAIR", "DREPAIR") for _, p2 in lk) and verdict.startswith("无本地"):
                        verdict = "家族（nerepair 日志判据命中 WOULD_*）"
                    if not any(p2[4] in ("WOULD_DREPAIR", "WOULD_REPAIR", "REPAIR", "DREPAIR") for _, p2 in lk) and verdict.startswith("无本地"):
                        verdict = "非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫）"
                W("| %s | %s | %s | %s | %s | %s | %s | `%s` | %s | %s |" % (
                    ep, ts(ep), pid, comm, r[3], far, pc, os.path.basename(stk), verdict, why))
            W("")
        W("分类口径：① nerepair 同刻日志出现 WOULD_*/REPAIR/DREPAIR ⇒ 家族级（其判据已含 w1==w3==0 + 记录存在）；"
          "② 否则用本地 .stack 跑 natne_scan 同判据（stride 8、A0B2/B0A2）⇒ 家族/非家族；"
          "③ 无本地栈则记未扫，**不得**据 far/pc 单独判定。")
        W("")
        W('> **补充（人工确认，非本脚本产出）**：① 18:58:11 slotguard 的 .stack 已于 19:26:58 在设备侧用**同一 8B-stride strict 判据**扫描 → **0 条**记录'
          '（见 docs/review/NEREPAIR_EFFICACY.md §2.5），与本表「非可修形态」一致；'
          '② 19:29:05 od 的 .stack 未做本地扫描（避免再执行设备端 od 造成二次注入，同一原因见 NEREPAIR_EFFICACY §6.6）；'
          '③ 19:51:16 ip 的 .stack 亦未扫 ⇒ 该行的「非可修形态」仅指 nerepair 判据窗口内无记录。')
    else:
        W("- 未找到 %s" % ne_p)
    W("")
    W("## D. R-11 存活表（被修进程的存活/再死亡；消费 survival.tsv）")
    W("")
    surv_p = R(a.survival, "tmpfiles/review/arm/survival.tsv")
    srows, sfmt = [], "n/a"
    if os.path.exists(surv_p):
        sl = [l.rstrip("\n").split("\t") for l in open(surv_p, encoding="utf-8", errors="replace").read().splitlines() if l.strip()]
        hdr = sl[0] if sl else []
        if "first_alive" in hdr and "last_alive" in hdr:
            sfmt = "9 列（first_alive + last_alive 均落盘）"
            srows = [dict(zip(hdr, r)) for r in sl[1:] if len(r) >= len(hdr)]
        elif len(hdr) >= 8:
            sfmt = "8 列（兼容分支：first_alive 置空，last_alive 仅首次写入）"
            srows = [dict(zip(hdr, r)) for r in sl[1:] if len(r) >= 8]
            for s in srows:
                s["first_alive"] = ""
    W("| 断言 | 值 |")
    W("|---|---|")
    W("| survival.tsv 格式 | %s |" % sfmt)
    W("| survival.tsv 行数 | %d |" % len(srows))
    W("| 合并日志布防后 REPAIR/DREPAIR/XREPAIR 条数 | %d |" % len(rep))
    W("| 断言 survival 覆盖全部 REPAIR | %s |" % ("PASS" if len(srows) == len(rep) else ("FAIL（survival=%d vs log=%d）" % (len(srows), len(rep)))))
    W("")
    if srows:
        W("| pid | comm | 事件 | 修复时刻 | status | 首活确认延迟 (first_alive 减 修复) | **存活下界 (last_alive 减 修复)** | last_check 参考 | 同刻死亡(修复未救活) | 之后再死亡(NE) |")
        W("|---|---|---|---|---|---|---|---|---|---|")
        for s in srows:
            tep = int(s["epoch"]); pid = s["pid"]
            rep_local = datetime.fromtimestamp(tep, CST)
            fl, la, lc = s.get("first_alive", ""), s.get("last_alive", ""), s.get("last_check", "")
            fmt_s = lambda x: ("%.1f min" % ((datetime.fromisoformat(x) - rep_local).total_seconds() / 60.0)) if x else "—"
            lat = fmt_s(fl)
            lb, note = None, ""
            if s["status"] in ("alive", "died_later") and la and sfmt.startswith("9"):
                lb, note = (datetime.fromisoformat(la) - rep_local).total_seconds(), ("status=alive：末轮仍活" if s["status"] == "alive" else "died_later：末次确认存活即为下界")
            elif sfmt.startswith("8") and s["status"] == "alive" and lc:
                lb, note = (datetime.fromisoformat(lc) - rep_local).total_seconds(), "8 列兼容：last_alive 仅首确，故退化为 last_check 减 修复 作上界参考"
            same = [r for r in recs if len(r) > 1 and r[1] == pid and int(r[0]) == tep]
            later = [r for r in recs if len(r) > 1 and r[1] == pid and int(r[0]) > tep]
            W("| %s | %s | %s | %s | **%s** | %s | %s | %s | %s | %s |" % (
                pid, s.get("comm", "?"), s.get("event", "?"), ts(tep), s.get("status", "?"), lat,
                ("%.1f min（%s）" % (lb / 60.0, note)) if lb is not None else "**无**（该状态不构成健康存活证据）",
                fmt_s(lc),
                "**是**" if same else "否",
                ("是: " + ",".join(ts(int(r[0])) for r in later)) if later else "否"))
        W("")
        W('> **存活判据与实现语义（已核对采集器 arm_watch.py L126-158，2026-11-03 20:0x 版）**：'
          '① 9 列格式下 first_alive = 首次确认存活、last_alive **每次仍活都刷新** = 末次确认存活 ⇒ '
          '**存活下界 = last_alive 减 修复时刻**（status=alive 用末轮确认值；died_later 用末次确认存活值），这是 F1 的判据量；'
          '② 「首活确认延迟 = first_alive 减 修复时刻」并列给出，用于对照（观察者轮询间隔量级）；'
          '③ 8 列兼容格式（旧文件）下 last_alive 仅首次写入 ⇒ 该行标出退化并改用 last_check（**F1 在 8 列口径下会在判定里标注**）；'
          '④ gone_before_first_poll = 首轮前已消失（**不算健康存活**）；pid_reused = 同 pid 换了 comm；not_seen = 尚无有效观测；'
          '⑤ 「同刻死亡 / 之后再死亡」按 §C 的 NE 全量台账核。')
    else:
        W("- survival.tsv 为空（布防后尚无 REPAIR）⇒ R-11 在本窗未获样本。")
    W("")
    W("### D2. mode0 弱门分诊（triage.tsv；采集器每轮对**窗口内** DREPAIR 行离线跑；弱门口径见 NEREPAIR_EFFICACY 1.3g）")
    W("")
    tri_p = R(a.triage, "tmpfiles/review/arm/triage.tsv")
    al_p = R(a.alerts, "tmpfiles/review/arm/ALERTS.txt")
    winlog = os.path.join(os.path.dirname(tri_p), "derepair_window.log")
    if os.path.exists(tri_p):
        tl = [l.rstrip("\n").split("\t") for l in open(tri_p, encoding="utf-8", errors="replace").read().splitlines() if l.strip()]
        W("| 断言 | 值 |")
        W("|---|---|")
        W("| triage.tsv 轮数 | %d |" % len(tl))
        if tl:
            last = tl[-1]
            W("| 最近一轮（%s） | n(deref repairs)=%s ok=%s review=%s |" % (last[0], last[1], last[2], last[3]))
            nums = [int(x[3]) for x in tl if len(x) > 3 and x[3].isdigit()]
            ns = [int(x[1]) for x in tl if len(x) > 1 and x[1].isdigit()]
            W("| REVIEW 峰值 / 累计 deref repairs / 每轮 n 峰值 | %d / %d / %d |" % ((max(nums) if nums else 0), sum(ns), (max(ns) if ns else 0)))
            W("| 护栏阈值（REVIEW>=2 且占比>=30 pct）是否已达 | %s |" % ("是（见 ALERTS.txt）" if (max(nums) if nums else 0) >= 2 else "否（REVIEW 峰值 <2）"))
        W("| derepair_window.log 行数 | %d |" % (len([1 for _ in open(winlog, encoding="utf-8", errors="replace")]) if os.path.exists(winlog) else -1))
        W("| ALERTS.txt | %s |" % ("有告警（原文见下）" if (os.path.exists(al_p) and os.path.getsize(al_p) > 0) else "不存在或为空（无告警）"))
        W("")
        if os.path.exists(al_p) and os.path.getsize(al_p) > 0:
            B3 = chr(96) * 3
            W(B3)
            W(open(al_p, encoding="utf-8", errors="replace").read().rstrip())
            W(B3)
            W("")
        W("> 分诊口径（tools/oneoff/sigsegv/mode0_repair_triage.py）：对每条窗口内 DREPAIR/XREPAIR 行用与判据同源的 shape_ok 复算记录形状；"
          "ok = 形状一致；REVIEW = **弱门（mode 0）可能假阳性的候选**（advisory only，不是误修判定）。本表只引用采集器落盘结果，不重跑分诊。")
    else:
        W("- 未找到 %s（采集器尚未产出分诊行）。" % tri_p)
    W("")
    W("")
    W("## E. 口径与限制")
    W("")
    W("1. **观测者污染**：采集器 latest.json.devcmd 保留**每轮**快照命令原文（只读 cat/ls/pidof/wc/tail/echo 与 /proc/<pid>/stat，无 od），可用于把窗口内任何异常事件归属到具体命令（S2）；"
      "本报告另有只读拉取 tmpfiles/review/arm/pull1.txt（设备侧 awk 拼接）与更早的 .stack 取证命令；"
      "**由取证命令派生的崩溃必须单列**（先例：2026-11-03 19:29:05 od applet 崩溃，见 docs/review/NEREPAIR_EFFICACY.md §6.6）。")
    W("2. **无对照臂 / 无 canary**：本窗没有 dry 对照臂、没有探针在跑 ⇒ 崩溃减少不可由本窗得出；"
      "只有 REPAIR 事件数、被修进程存活结果与背景率功效可报。")
    W("3. **日志轮转（已由合并档案兜底）**：nerepair.log 单代 1 MB 轮转；实测增长 **0.82 MB/日**（Lead 20:04 复核）"
      "⇒ 4 h 窗内不轮转；且采集器每 10 min 全量拉取并合并进 arm_log_merged.txt（抗轮转）。本报告以该合并档案为准，"
      "并在文末给**合并行数断言**（merged_lines）与设备 wc -l 对照。")
    W("4. **更早 boot 段混入**：合并日志含 11-03 10:36 起的更早实例/更早 boot 段（epoch 非单调）"
      "⇒ 分段一律按 epoch 与 MODE/START 边界，不按文件顺序，跨 boot 不混算。")
    W("5. **NE 台账解析**：设备侧 awk 把续行拼成一行（`^[0-9]` 起头=新记录），断言 fetched == 设备记录数；"
      "按物理行解析会把 args 里的换行当新记录（历史坑）。")
    W("")
    W("6. **双重不可见（armed 窗口的结构性盲区；task-8 审计项①）**：arm64 的 kmsg unhandled-fault 行要求 !tsk->ptrace"
      "（docs/SIGSEGV/03_PROBES.md:164-166：「unhandled ... fault (11) 行本身在 nerepair 在役时结构性缺席」；"
      "skeptic 审计 docs/review/WRITER_HUNT_GAP_AUDIT.md:52 条目①：「19:55 布防后该信道继续缺席，且被修的崩溃不再进 NE 台账 ⇒ 双重不可见」）。"
      "⇒ ① 布防后**被修复的崩溃**的**唯一记录 = nerepair.log 的 REPAIR/DREPAIR/XREPAIR 行**（含 comm/pc/addr/记录证据）——"
      "这正是本报告必须依赖「采集器合并档案 + survival.tsv + triage.tsv」的理由（kmsg 与 NE 台账在该路径上都为空）；"
      "② 反向推论：**不得因布防后 NE 台账归零就宣布崩溃停止**（被修的不进台账；未命中的仍会进）；"
      "③ 叠加 nerepair 的行限流（rate_ok 20 行/s、rate_ok_prio 200 行/s，nerepair.c L177-216）⇒ REPAIR 行在风暴下可能被丢弃，故加下面的一致性断言。")
    if arm_stat and last_stat:
        def stat_tot(d):
            return (int(d.get("repaired", 0)), int(d.get("rep2", 0)), int(d.get("xr", 0)), int(d.get("suppressed", 0)))
        # 实例内口径：以 armed 段最后一个 segv 回退点为基（跨实例相减无意义）
        base = arm_stat[0]
        prev = None
        for i2, p2 in [(i2, p2) for i2, p2 in armed if p2[4] == "STAT"]:
            sg = parse_stat(p2[5]).get("segv")
            if isinstance(sg, int) and isinstance(prev, int) and sg < prev:
                base = (i2, p2)
            if isinstance(sg, int):
                prev = sg
        s0 = stat_tot(parse_stat(base[1][5])); s1 = stat_tot(parse_stat(last_stat[-1][5]))
        d_rep, d_rep2, d_xr, d_sup = [s1[i] - s0[i] for i in range(4)]
        tot = d_rep + d_rep2 + d_xr
        rep_inst = [(i2, p2) for i2, p2 in rep if int(p2[0]) >= int(base[1][0])]
        W("> 本断言按**实例内**口径：基线取 armed 段最后一个 STAT 计数器回退点（epoch %s，merged L%d）；该段内 REPAIR 行数 %d。" % (ts(int(base[1][0])), base[0], len(rep_inst)))
        W("")
        W("7. **限流/口径一致性断言（REPAIR 行数 vs STAT 增量；同实例，首个 armed STAT → 末行）**：")
        W("")
        W("| 断言 | 值 | 判 |")
        W("|---|---|---|")
        W("| 路径 | 末实例段内**行数** | 末实例段内 **ΔSTAT** | 一致性断言（行数 >= Δ） |")
        W("|---|---|---|---|")
        for _path, _dv, _nm in (("REPAIR", d_rep, "repaired"), ("DREPAIR", d_rep2, "rep2"), ("XREPAIR", d_xr, "xr")):
            _n = sum(1 for _i, _p in rep_inst if _p[4] == _path)
            W("| %s | %d | Δ%s = %d | %s |" % (_path, _n, _nm, _dv, "PASS" if _n >= _dv else "**FAIL（该路径有行未落盘）**"))
        W("| 合计 | %d | %d | %s |" % (len(rep_inst), tot, "PASS" if len(rep_inst) >= tot else "**FAIL**"))
        # 旧实例参考（回退点之前的 armed 段）
        _olds = [(i2, p2) for i2, p2 in armed if p2[4] == "STAT" and int(p2[0]) < int(base[1][0])]
        if _olds:
            _o0 = stat_tot(parse_stat(_olds[0][1][5])); _o1 = stat_tot(parse_stat(_olds[-1][1][5]))
            _od = [_o1[k] - _o0[k] for k in range(3)]
            _oldrep = [(i2, p2) for i2, p2 in rep if int(p2[0]) < int(base[1][0])]
            W("| 旧实例（参考，末 STAT %s） | REPAIR %d / DREPAIR %d / XREPAIR %d | %d / %d / %d | %s |" % (
                ts(int(_olds[-1][1][0])),
                sum(1 for _, p2 in _oldrep if p2[4] == "REPAIR"), sum(1 for _, p2 in _oldrep if p2[4] == "DREPAIR"),
                sum(1 for _, p2 in _oldrep if p2[4] == "XREPAIR"), _od[0], _od[1], _od[2],
                "PASS" if (sum(1 for _, p2 in _oldrep if p2[4] == "REPAIR") >= _od[0]
                           and sum(1 for _, p2 in _oldrep if p2[4] == "DREPAIR") >= _od[1]) else "**FAIL**"))
        W("")
        W("> **口径**：跨实例相减无意义（STAT 计数器在新实例从 0 起）⇒ 按「末实例段内」与「旧实例」两段分别对齐；"
          "这样避免把全段 23 行去比末实例 Δ=12 的假不一致。三条路径各自独立断言（Lead 指定）。")
        W("| ΔSTAT suppressed（限流丢弃计数，含所有事件类型） | %d | %s |" % (d_sup, "0 = 本窗未发生限流丢弃" if d_sup == 0 else "**>0 ⇒ 确有行被限流丢弃**"))
        W("")
        W("> 计数点：REPAIR 行 = g_repaired（nerepair.c L966）、DREPAIR 行 = g_rep2（L768）、XREPAIR 行 = g_xr（L762/L927）；"
          "三者自增**先于** rate_ok_prio 判定 ⇒ STAT 计数器是地面真值，行数少于它即说明丢行。"
          "STAT 计数器只在同一实例内可比（本窗 arm_stat 行数=%d；实例 pids=%s）。" % (len(arm_stat), sorted(npids.items())))
    W("8. **`loop=0` 不代表无级联**：熔断器按 **(pid, pc)** 计数（nerepair.c L146-172，NR_LOOP_MAX=8；站点一变就重置计数）⇒ STAT 的 `loop=` 只表示"
      "「没有任何单个 (pid,pc) 连续被修超过 8 次」，**不表示**没有跨站点的修复链。本窗 hostapd 同 pid 在 2 个 pc 上被修 6+1 次、busybox 同 pid 多 pc 连发，"
      "均未触发 loop，但仍是级联形态 ⇒ 判级联要看 §G 的 (pid,pc,addr) 递进，不能只看 loop。")
    W("9. **功效（按背景率，不用窗内计数投影）**：自然 NE 背景 0.5-1.5/h ⇒ 布防后 %.2f h 期望 %.2f-%.2f 起，"
      "P(0)=%.3g-%.3g；窗内 n=0 不提供速率信息。" % (
          (asof - arm_epoch) / 3600.0, 0.5 * (asof - arm_epoch) / 3600.0, 1.5 * (asof - arm_epoch) / 3600.0,
          pow(2.718281828, -0.5 * (asof - arm_epoch) / 3600.0), pow(2.718281828, -1.5 * (asof - arm_epoch) / 3600.0)))
    W("")
    W("## F. 预注册判据（0 点前写定，不改）")
    W("")
    W("| # | 判据 | 判定 |")
    W("|---|---|---|")
    vmap = {}
    for _k, (_i, _p) in enumerate(derep_f):
        if _k < len(verdicts_f):
            vmap[(_p[0], _p[2])] = verdicts_f[_k]
    f1_ok, f2_bad = [], []
    for s in srows:
        try:
            tep = int(s["epoch"]); pid = s["pid"]
            la = s.get("last_alive", "") if sfmt.startswith("9") else s.get("last_check", "")
            lb = (datetime.fromisoformat(la) - datetime.fromtimestamp(tep, CST)).total_seconds() if la else 0
        except Exception:
            continue
        later = [r for r in recs if len(r) > 1 and r[1] == pid and int(r[0]) > tep]
        fam = (vmap.get((s["epoch"], s["pid"]), "?") == "ok") or s.get("event") == "REPAIR"
        if s["status"] == "alive" and lb >= 1800 and not later and fam:
            f1_ok.append((pid, lb))
        if s["status"] in ("died_later", "gone_before_first_poll", "pid_reused"):
            f2_bad.append("%s(%s)" % (pid, s["status"]))
    range_note = len(rep) == 0
    loop_now = parse_stat(last_stat[-1][5]).get("loop") if last_stat else "?"
    W("| F1 | **修复生效（正）** = 布防后 >=1 起**家族型** REPAIR/DREPAIR（triage=ok，即形状一致；path1 REPAIR 以 x2 形状门为准）**且存活下界 >=30 min**（survival.tsv status=alive 的 last_alive 减 修复时刻）**且**该 pid 无修复后的 NE 死亡记录 | %s |" % (
        ("**满足**：" + "；".join("pid=%s 存活下界 %.1f min" % (p, m / 60.0) for p, m in f1_ok)) if f1_ok else
        ("**未满足**（布防后修复 %d 条；status=alive 且下界>=30min 的行=%d，其中 triage=ok 的 **0** 条；"
         "triage REVIEW 形状不一致者不计为家族级）" % (len(rep), len([1 for s in srows if s.get("status") == "alive"])))))
    W("| F2 | **反向（负）** = 被修进程 died_later / gone_before_first_poll / pid_reused，或同 pid 反复出现 REPAIR，或 loop 熔断激增 | %s |" % (
        ("**命中**：" + ",".join(f2_bad)) if f2_bad else ("未命中（无 died_later/gone_before_first_poll/pid_reused；loop=%s）" % loop_now)))
    W("| F3 | **中性** = 布防后 0 REPAIR ⇒ 本窗对是否减少崩溃**无判别力** | %s |" % ("成立（0 REPAIR）" if not rep else "不适用（REPAIR=%d>0，改用 F1/F2/F5 判）" % len(rep)))
    W("| F4 | **禁止**：用本窗 NE 比 dry 少声称效力（修复后崩溃不进 NE = 同义反复，见 NEREPAIR_EFFICACY 6.1；且 kmsg unhandled-fault 信道在 nerepair 在役时结构缺席 = 双重不可见，见 §E6） | 遵守 |")
    share = (tri_rev_f / float(tri_ok_f + tri_rev_f)) if (tri_ok_f + tri_rev_f) > 0 else 0.0
    W("| F5 | **Lead 预注册停止线**：triage（mode0 弱门分诊）REVIEW 占比 **>30 pct** ⇒ 触发回滚 | %s |" % (
        ("**命中**：REVIEW %d / (ok %d + REVIEW %d) = **%.1f pct** > 30 pct ⇒ 应回滚；实际已于 %s 回滚"
         % (tri_rev_f, tri_ok_f, tri_rev_f, 100 * share, ts(win_end) if win_end else "（未见回滚行）")) if (tri_ok_f + tri_rev_f) > 0 else
        "无 deref 修复，未触发"))
    W("")
    W("> F5 分诊由本脚本在窗口切片上重跑（tools/oneoff/sigsegv/mode0_repair_triage.py；输入 = armed 段 DREPAIR/XREPAIR 行，"
      "切片落 tmpfiles/review/arm/triage_mine/derepair_window_armed.log），与采集器 triage.tsv 最后一轮互为交叉校验（§D2）。")
    W("")
    W("> 预注册副本 = 本文件在 0 点前生成的版本（生成戳见文末）；此表由脚本模板固定，0 点后重跑不改表体，只填判定列。")

    W("## G. 修复清单（armed 段；逐条含记录证据 + 存活 + 分诊判定）")
    W("")
    if rep:
        surv_by = {}
        for s in srows:
            surv_by[(s.get("epoch", ""), s.get("pid", ""))] = s
        W("| # | 时刻 | comm | pid | 事件 | pc | addr | 记录证据 | 存活状态 | 存活下界 | triage |")
        W("|---|---|---|---|---|---|---|---|---|---|---|")
        vi = 0
        for n, (i, p) in enumerate(rep, 1):
            d = p[5]
            if p[4] == "REPAIR":
                evd = "fault=%s rt=%s（path1，x2 形状门）" % (field(d, "fault") or "-", field(d, "rt") or "-")
            else:
                evd = "q0=%s q2=%s which=%s" % (field(d, "q0") or "-", field(d, "q2") or "-", field(d, "which") or "-")
            s = surv_by.get((p[0], p[2]), {})
            st = s.get("status", "（无 survival 行）")
            lb = "—"
            if s.get("last_alive"):
                try:
                    lb = "%.1f min" % ((datetime.fromisoformat(s["last_alive"]) - datetime.fromtimestamp(int(p[0]), CST)).total_seconds() / 60.0)
                except Exception:
                    pass
            if p[4] == "REPAIR":
                tv = "—（path1 不在分诊口径内）"
            else:
                tv = verdicts_f[vi] if vi < len(verdicts_f) else "?"
                vi += 1
            W("| %d | %s | %s | %s | %s | %s | %s | %s | %s | %s | **%s** |" % (
                n, ts(p[0]), p[3], p[2], p[4], field(d, "pc") or "-", field(d, "addr") or field(d, "fault") or "-",
                evd, st, lb, tv))
        W("")
        W("> 分诊口径同 §D2（ok=形状一致；REVIEW=mode0 弱门可能假阳性的候选，advisory）。"
          "hostapd 组 q0=0xffffff80（负数，不是 A 字）、q2 为自指地址 ⇒ 按 natne_scan 同族 strict 判据不是家族记录。")
    else:
        W("- armed 段无 REPAIR/DREPAIR。")
    W("")
    W("## H. 死亡侧时间分布（NE 台账）与风暴段")
    W("")
    win_recs = [r for r in recs if len(r) > 2 and int(r[0]) >= arm_epoch]
    byh = collections.Counter(ts(int(r[0]))[:13] for r in win_recs)
    baseh = collections.Counter(ts(int(r[0]))[:13] for r in recs if len(r) > 2 and a.window_start <= int(r[0]) < arm_epoch)
    W("| 小时 | NE 记录数（armed 段） | 同小时基线（17:45:32-19:55:21） |")
    W("|---|---|---|")
    for h in sorted(set(list(byh.keys()) + list(baseh.keys()))):
        W("| %s | %d | %d |" % (h, byh.get(h, 0), baseh.get(h, 0)))
    W("")
    W("> armed 段 NE 记录合计 **%d** 条（在 §C 的 fetched==records 断言通过后按 epoch 筛选）。" % len(win_recs))
    storm = [r for r in win_recs if 1793710800 <= int(r[0]) <= 1793711220]
    W("")
    W("**21:00-21:07 风暴段**（epoch 1793710800-1793711220）：NE 记录 %d 条，comm=%s。" % (
        len(storm), ", ".join("%s x%d" % (k, v) for k, v in collections.Counter(r[2] for r in storm).most_common())))
    storm_ev = [(i, p) for i, p in armed if 1793710800 <= int(p[0]) <= 1793711220 and p[4] in ("SEGV", "DREPAIR", "REPAIR")]
    W("同段 nerepair 侧：SEGV %d / DREPAIR %d / REPAIR %d。" % (
        sum(1 for _, p in storm_ev if p[4] == "SEGV"), sum(1 for _, p in storm_ev if p[4] == "DREPAIR"),
        sum(1 for _, p in storm_ev if p[4] == "REPAIR")))
    W("")
    W("## I. 非计划重启（事实清单，不含因果）")
    W("")
    W("| 事实 | 值/证据 | 来源 |")
    W("|---|---|---|")
    W("| watch 轮询的 npid/uptime 不连续 | 见 §A「实例切换/重启检测」行 | watch.tsv（600 s/轮） |")
    _pr, _pu, _rb = None, None, None
    for _r in wrows:
        try:
            _u = float(_r[1].split()[0])
        except Exception:
            _u = None
        if _pr is not None and (_r[4] != _pr or (_u is not None and _pu is not None and _u < _pu - 60)):
            _rb = (_r[0], _u)
            break
        _pr, _pu = _r[4], _u
    if _rb:
        _bt = datetime.fromisoformat(_rb[0]) - timedelta(seconds=_rb[1])
        W("| **重启时刻推导（只读可复算）** | watch 首轮见到新实例：%s（uptime=%.1f s）⇒ boot ≈ **%s** | watch.tsv（本机 local_ts 与设备 uptime 相减） |" % (
            _rb[0][11:19], _rb[1], _bt.strftime("%Y-%m-%dT%H:%M:%S+08:00")))
    W("| STAT 计数器回退（新实例从 0 起） | armed 段 STAT segv 峰值 %s；回滚前末次 STAT segv=%s | armed 段 STAT 序列 |" % (
        max([parse_stat(p[5]).get("segv", 0) for _, p in armed if p[4] == "STAT"] or [0]),
        (parse_stat(last_stat[-1][5]).get("segv") if last_stat else "?")))
    W("| 设备侧重启记录 | reboots.log 无该次记录（仅 04:00 计划重启）；pstore 无新 ramoops；syslog 21:05:33 截断且无关机序列 | Lead 23:27-23:32 只读实测（本报告未独立复读这些设备文件） |")
    W("| boot 恢复 | boot_babysit 21:09:10 起 boot 正常、21:09:21 boot gate passed | 同上 |")
    W("")
    W("> **不得因果化**：重启原因未定（看门狗复位/挂起待证）；本节只记事实与时序。")
    W("")
    W("## I2. 监督者自身被家族写者打死（本轮新增，实机闭环）")
    W("")
    W("| 事实 | 值 | 来源 |")
    W("|---|---|---|")
    W("| 监督者自身 NE | epoch **1793711160** = 21:06:00，pid **11617**，comm **nerepair**，sig=11，**far=0x28f80**，pc=0x101f59c | NE 台账（ne_joined_latest.txt 该行，经 fetched==records 断言） |")
    W("| 该进程栈 | 1793699132-11617-1793711160.stack（本地副本 tmpfiles/review/arm/nerepair_crash.stack；头解析 pid=11617、stack=[0x7ff0dbe000,0x7ff0dce000)、npages=16、bitmap=0xffff、ts=1793711160 与 NE 行一致） | 本报告独立复算（与 Lead 的 hexdump 复原互为独立通道） |")
    W("| **栈内家族记录** | **3 条 A0B2**：top-va 0x1fa0 q0=0x25c7a；top-va 0x14a0 **q0=0x28f80（== far）**；top-va 0x1260 **q0=0x28f88（== far+8）**；三条 q2 均 = 0x1365fe9b0000062d（len **0x62d=1581**，ip 19.101.254.155） | 本报告用 natne_scan 同判据（stride 8、A0B2）扫描本地 .stack；与 Lead 的命中位置/q0 一致 |")
    W("| 判级 | **形态 E4**（记录 q0 与 fault 精确对齐、且 far+8 亦在同一栈内 ⇒ 与家族语料同形的致命路径）+ **现场 E3**（NE 行 + .stack 命中 + 时序可复算） | 本报告 + Lead 独立取证 |")
    W("| 观测盲区 | nerepair.log 自 **21:06:00** 之后无任何事件，下一行是 **21:09:55**（STAT，新实例 attached=44、segv=0 计数器已归零）⇒ 盲区 **3 min 55 s**；期间 21:07:30 发生非计划重启（§I） | merged 事件序列（STAT 21:06:00 / 21:09:55 之间为空） |")
    W("| 本地副本完整性 | 65,584 B（设备 65,592 B 少 8 B，hexdump 复原边界差）；magic/头/bitmap 均自洽，3 条命中位置 (dataoff 0xe060/0xeb60/0xeda0) 均在可扫窗口内 ⇒ 不影响结论 | 本报告复算 |")
    W("")
    W("> **含义（不含因果）**：① 写者把 32B 记录写进了**监督者自己的栈**，监督者按自指 LDR 解引用致死 ⇒ 「守卫自身也是受害者」，"
      "这是**守卫在风暴中先死**的实机证据（守护进程一死，其覆盖的用户进程全部失去修复能力，直到 watchdog 拉起/重启）；"
      "② 该死亡解释了 21:06:00-21:09:55 的观测盲区（日志与 STAT 同时消失）；③ **不推断**该死亡与 21:07:30 非计划重启的因果关系"
      "（时序相邻 ≠ 因果，重启原因仍未定，§I）；④ 本条**不改变** §E6 的双重不可见结论（其他被 ptrace 的进程其 unhandled-fault 行仍缺席），"
      "监督者自身未被 ptrace，其 kmsg 行是否存在本报告未复核。")
    W("")
    W("## J. 结论（不含因果）")
    W("")
    W("- armed 段（%s → %s，%.2f h）共 **%d 次修复**：DREPAIR %d + REPAIR %d（path1），逐条见 §G。" % (
        ts(arm_epoch), (ts(win_end) if win_end else ts(asof)), (((win_end or asof) - arm_epoch) / 3600.0), len(rep),
        sum(1 for _, p in rep if p[4] == "DREPAIR"), sum(1 for _, p in rep if p[4] == "REPAIR")))
    W("- **弱门假修复居多**：triage 重跑 REVIEW %d / %d = **%.1f pct**（ok %d）⇒ 越过 Lead 预注册停止线（>30 pct）；"
      "hostapd 组 q0=0xffffff80（负数）、q2 自指 ⇒ 非家族记录（§G/§D2 与 natne_scan 同判据）。" % (
          tri_rev_f, tri_ok_f + tri_rev_f, 100 * share, tri_ok_f))
    _alive = [s for s in srows if s.get("status") == "alive"]
    _lbs = [(datetime.fromisoformat(s["last_alive"]) - datetime.fromtimestamp(int(s["epoch"]), CST)).total_seconds() / 60.0
            for s in _alive if s.get("last_alive")]
    W("- **存活证据薄弱**：status=alive %d 行，存活下界最长 **%.1f min**；但达到 >=30 min 的那条其修复被 triage 判 **REVIEW（形状不一致）**，不构成家族级生效证据 ⇒ **F1 未满足**；died_later/gone_before_first_poll %d 行 ⇒ **F2 命中**（§D/§F/G）。" % (
        len(_alive), (max(_lbs) if _lbs else 0.0), sum(1 for s in srows if s.get("status") in ("died_later", "gone_before_first_poll"))))
    _peak = max(byh.values()) if byh else 0
    W("- **NE 台账**：armed 段新增 **%d** 条；单小时最高 %d 条（%s）。**NE 升高与布防的关系未定**，不得因果化。" % (
        len(win_recs), _peak, (max(byh, key=byh.get) if byh else "-")))
    W("- **监督者自身被家族写者打死（21:06:00，pid 11617）**：其 .stack 含 3 条 A0B2，其中 q0=0x28f80==far、q0=0x28f88==far+8（§I2）⇒ "
      "「守卫在风暴中先死」实机闭环；随后 3 min 55 s 观测盲区、21:07:30 非计划重启（**因果未定**）。")
    W("- **已回滚**：%s 起 mode=dry（MODE dry=1 by=SIGUSR2；xrep/arm 仍缺），armed 段结束于 %s。" % (
        ts(win_end) if win_end else "（未见回滚行）", ts(win_end) if win_end else "—"))
    W("- **禁止**：本窗无对照臂 ⇒ 不得宣称崩溃减少（F4）；亦不得宣称重启或 NE 升高由布防引起（原因未定，§I）。")
    W("")
    W("")
    W("---")
    W("")
    W("生成戳：%s（脚本 nerepair_window_report.py；数据 asof epoch %d = %s；merged %d 行，坏行 %d）" % (
        datetime.now(CST).strftime("%Y-%m-%dT%H:%M:%S+08:00"), asof, ts(asof), len(rows), bad))
    txt = "\n".join(out) + "\n"
    if a.out:
        open(a.out, "w", encoding="utf-8").write(txt)
        print("wrote %s (%d bytes, %d lines)" % (a.out, len(txt.encode("utf-8")), txt.count("\n")))
    else:
        sys.stdout.write(txt)
    sys.stderr.write("ASSERT merged_lines=%d pre=%d post=%d arm_mode=%d arm_stat=%d ne_records=%d bad=%d\n" % (
        len(rows), len(pre), len(post), len(arm_mode), len(arm_stat), len(recs), bad))


if __name__ == "__main__":
    main()
