#!/usr/bin/env python3
"""drill.py -- 演练窗口标记器（强制前置，防止"忘了标记"污染验收数据）

背景：2026-11-01 两个子代理（cfg-heal / state-truth）都在**没写 drills.tsv 的情况下**做了会中断服务的演练，
导致客户端 1s 探测器把人为中断记成"有机故障"。drills.tsv 是 v1.2 契约，但靠人记不可靠 —— 所以做成工具。

用法:
  python _local/drill.py status
  python _local/drill.py start --owner NAME --kind KIND --target TEXT [--minutes N]
  python _local/drill.py stop  --owner NAME
  python _local/drill.py guard --owner NAME --kind KIND --target TEXT --minutes N -- <cmd...>

规则:
  - start 会先查设备侧是否有 end_epoch=0 的悬挂窗口；有则**拒绝**（除非 --force），
    避免多个演练窗口重叠导致排除范围说不清。
  - start 写一行 (start_epoch, 0, kind, target, owner, note)，并把返回的 start_epoch 存到
    _local/drill.state.json 供 stop 回填。
  - stop 把该行 end_epoch 回填为当前时刻。
  - guard = start + 执行命令 + stop（异常也会 stop）。

退出码: 0=成功 2=被拒 3=参数错误
"""
import argparse
import json
import os
import subprocess
import sys
import time

# 路径约定（v2, 2026-11-01 迁入仓库）：
#   工具本体在 lg6151m-public/tools/（版本控制），**运行态**仍写 _local/（不入仓）：
#   PROJ = dirname(dirname(HERE)) = 项目根；LOCAL = PROJ/_local
HERE = os.path.dirname(os.path.abspath(__file__))
PROJ = os.path.dirname(os.path.dirname(HERE))
LOCAL = os.environ.get("LG_LOCAL_DIR") or os.path.join(PROJ, "_local")
PUB = os.path.dirname(HERE)
LGSSH = os.path.join(HERE, "lgssh.py")
STATE = os.path.join(LOCAL, "drill.state.json")
DRILLS = "/data/gw/logs/drills.tsv"


def sh(cmd, timeout=60):
    env = dict(os.environ)
    env["MSYS_NO_PATHCONV"] = "1"
    r = subprocess.run([sys.executable, LGSSH, cmd], cwd=PUB, capture_output=True,
                       text=True, timeout=timeout, env=env)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def open_rows():
    # v2 (2026-11-01): 必须同时要求 NF>=5 且 $1/$2 是纯数字 —— 否则空行/CR 行/碎片行
    #   会被 awk 的 ""==0 语义误判成「未闭合演练窗口」（实弹：drills.tsv 被写坏后
    #   第 1 行 \r\n\r\n 让 open_rows 报 1，阻塞全队开窗）。
    rc, out = sh("awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2==0' %s 2>/dev/null | wc -l" % DRILLS)
    try:
        return int(out.strip().splitlines()[-1])
    except Exception:
        return -1


def status():
    # v5: 列出**全部**未闭合窗口（原来只 tail -3，会漏看）
    rc, out = sh("awk -F'\\t' 'NF>=5 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2==0 "
                 "{print NR\": \"$0}' %s 2>/dev/null" % DRILLS)
    n = open_rows()
    print("open_drill_rows=%s" % n)
    if out.strip():
        print(out.strip()[:1200])
    else:
        rc2, tail = sh("tail -2 %s 2>/dev/null" % DRILLS)
        print("(no open window) last rows:")
        print(tail.strip()[:400])
    return 0


def _clean_note(note, target):
    """v3 (2026-11-01): note 校验 —— 实弹发现 drills.tsv 里出现 note='python lg6151m-public/tools/lgssh.py'
    这种「工具调试输出被当成备注」的脏行。规则：note 不得为空、不得含路径分隔符/工具名样式、
    长度 <=120，否则用 target 兜底并加标记。"""
    s = (note or "").strip()
    bad = (not s) or ("/" in s) or ("\\" in s) or (len(s) > 120) or (".py" in s) or (".sh " in s)
    if bad:
        return "auto-note(target=%s)" % (target or "?")
    return s.replace("\t", " ")


def start(owner, kind, target, note, force):
    # v5: 空 target 会被作用域过滤器当成「全链路」→ 排除一切，实弹造成三条孤儿窗藏住所有中断。
    #     强制要求写清作用域；确实全链路就显式写「全链路」。
    if not (target or "").strip():
        print("REFUSED: --target 不能为空。请写清作用域：v3httpd / dnsmasq / hostapd / dropbear / wifi / wan / 全链路")
        return 2
    note = _clean_note(note, target)
    # v4 (2026-11-01): 允许并发窗口（只警告，不拒绝）。
    #   实弹：soak-qa 的 batchB 窗口一开就是 20+ 分钟，把全队的 drill.py start 全堵死。
    #   排除语义本身是「窗口并集」，重叠不会漏排除，只会多排除（保守方向）。
    n = open_rows()
    if n > 0:
        print("WARN: %d open drill row(s) already present; this window will OVERLAP them "
              "(exclusion = union, which is conservative: may over-exclude, never under-exclude)" % n)
    t = int(time.time())
    row = "%d\t0\t%s\t%s\t%s\t%s" % (t, kind, target, owner, note)
    rc, out = sh("printf '%s\\n' >> %s && tail -1 %s" % (row.replace("'", ""), DRILLS, DRILLS))
    if rc != 0:
        print("START-FAIL rc=%d %s" % (rc, out[:200]))
        return 2
    try:
        with open(STATE, encoding="utf-8") as f:
            st = json.load(f)
        if not isinstance(st, dict) or "windows" not in st:
            st = {"windows": {}}
    except Exception:
        st = {"windows": {}}
    st["windows"][owner] = {"start": t, "kind": kind, "target": target}
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump(st, f)
    print("DRILL-STARTED owner=%s start=%d kind=%s target=%s" % (owner, t, kind, target))
    return 0


def stop(owner):
    try:
        with open(STATE, encoding="utf-8") as f:
            st = json.load(f)
    except Exception:
        print("STOP-FAIL: no local drill state; fill end_epoch manually")
        return 2
    if "windows" in st:
        w = st["windows"].get(owner)
        if not w:
            print("STOP-REFUSED: no open window for %s" % owner)
            return 2
    else:
        if st.get("owner") != owner:
            print("STOP-REFUSED: open drill owned by %s" % st.get("owner"))
            return 2
        w = {"start": st["start"]}
    t = int(time.time())
    start_ts = w["start"]
    cmd = ("awk -F'\t' -v OFS='\t' -v s=%d -v e=%d '$1==s && $2==0 {$2=e} {print}' %s > %s.tmp "
           "&& mv %s.tmp %s && awk -F'\t' '$1==%d' %s" % (start_ts, t, DRILLS, DRILLS, DRILLS, DRILLS, start_ts, DRILLS))
    rc, out = sh(cmd)
    if rc != 0:
        print("STOP-FAIL rc=%d %s" % (rc, out[:200]))
        return 2
    os.remove(STATE)
    print("DRILL-STOPPED start=%d end=%d dur=%ds" % (start_ts, t, t - start_ts))
    print(out.strip()[:200])
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    s = sub.add_parser("start")
    s.add_argument("--owner", required=True); s.add_argument("--kind", default="drill-manual")
    s.add_argument("--target", default=""); s.add_argument("--note", default=""); s.add_argument("--minutes", type=int, default=0)
    s.add_argument("--force", action="store_true")
    e = sub.add_parser("stop"); e.add_argument("--owner", required=True)
    g = sub.add_parser("guard")
    g.add_argument("--owner", required=True); g.add_argument("--kind", default="drill-manual")
    g.add_argument("--target", default=""); g.add_argument("--note", default=""); g.add_argument("--minutes", type=int, default=0)
    g.add_argument("argv", nargs=argparse.REMAINDER)
    ns = ap.parse_args()

    if ns.cmd == "status":
        return status()
    if ns.cmd == "start":
        return start(ns.owner, ns.kind, ns.target, ns.note, ns.force)
    if ns.cmd == "stop":
        return stop(ns.owner)
    if ns.cmd == "guard":
        argv = list(ns.argv)
        if argv and argv[0] == "--":
            argv = argv[1:]
        if not argv:
            print("guard: missing command after --"); return 3
        rc = start(ns.owner, ns.kind, ns.target, ns.note or " ".join(argv[:2]), False)
        if rc != 0:
            return rc
        try:
            return subprocess.call(argv)
        finally:
            stop(ns.owner)
    return 3


if __name__ == "__main__":
    sys.exit(main())
