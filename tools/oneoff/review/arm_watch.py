#!/usr/bin/env python3
"""arm_watch.py -- 只读观测采集器（nerepair armed 窗口）

用途（2026-11-03 Lead 布防轮）：每 interval 秒做一次**纯读**设备快照，落本地时间序列 + 合并日志，
并做 R-11 关注的"被修复进程存活追踪"与告警。**绝不写设备**。

设备侧命令只用 cat/ls/pidof/wc/tail/echo；每次快照的命令原文写进样本行（观测者污染审计）。
输出目录默认 ../tmpfiles/review/arm/
"""
import argparse, json, os, re, subprocess, sys, time
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
# 向上找到含 gw/ 的仓库（= lg6151m-public），项目根 = 其父目录
_p = HERE
while _p != os.path.dirname(_p) and not os.path.isdir(os.path.join(_p, "gw")):
    _p = os.path.dirname(_p)
PUB = _p
PROJ = os.path.dirname(PUB)
OUT = os.path.join(PROJ, "tmpfiles", "review", "arm")
CST = timezone(timedelta(hours=8))

def now():
    return datetime.now(CST).strftime("%Y-%m-%dT%H:%M:%S+08:00")

def sh(argv, timeout=120):
    env = dict(os.environ, MSYS_NO_PATHCONV="1", PYTHONIOENCODING="utf-8")
    p = subprocess.run(argv, cwd=PUB, capture_output=True, env=env, timeout=timeout, shell=False)
    return p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace")

def lgssh(devcmd, timeout=120):
    # argv 直调（Windows 下 shell=True 会落到 cmd.exe，单引号不成立）
    return sh([sys.executable, "tools/lgssh.py", devcmd], timeout)

STAT_RE = re.compile(r"STAT\tmode=(\w+) attached=(\d+) segv=(\d+) repaired=(\d+) passed=(\d+) suppressed=(\d+) abuse=(\d+) loop=(\d+) would=(\d+) near=(\d+) nearinsn=(\d+) rep2=(\d+) would2=(\d+) dfhit=(\d+)")

def parse_stat(line):
    m = STAT_RE.search(line)
    if not m:
        return None
    keys = ["mode","attached","segv","repaired","passed","suppressed","abuse","loop","would","near","nearinsn","rep2","would2","dfhit"]
    d = {}
    for k, v in zip(keys, m.groups()):
        d[k] = v if k == "mode" else int(v)
    return d

def read_procs(pids):
    """return {pid: (comm, state)} for live pids using ONE cat call"""
    pids = [p for p in pids if p and p.isdigit()][:40]
    if not pids:
        return {}, "cat", ""
    devcmd = "cat " + " ".join("/proc/%s/stat" % p for p in pids)
    rc, out, err = lgssh(devcmd, timeout=60)
    res = {}
    for ln in out.splitlines():
        m = re.match(r"^(\d+) \((.*)\) (\S)", ln)
        if m:
            res[m.group(1)] = (m.group(2), m.group(3))
    return res, devcmd, err

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=int, default=600)
    ap.add_argument("--until", default="2026-11-04T00:05:00+08:00")
    ap.add_argument("--max-iter", type=int, default=40)
    ns = ap.parse_args()
    os.makedirs(OUT, exist_ok=True)
    merged_path = os.path.join(OUT, "arm_log_merged.txt")
    seen_path = os.path.join(OUT, "arm_log_seen.txt")
    watch_path = os.path.join(OUT, "watch.tsv")
    alert_path = os.path.join(OUT, "ALERTS.txt")
    latest_path = os.path.join(OUT, "latest.json")
    seen = set(open(seen_path, encoding="utf-8", errors="replace").read().split("\n")) if os.path.exists(seen_path) else set()
    repairs = []   # dicts
    pid_first_alive, pid_last_alive, pid_dead = {}, {}, {}
    until = datetime.fromisoformat(ns.until)
    it = 0
    while it < ns.max_iter and datetime.now(CST) < until:
        it += 1
        stamp = now()
        # ---- one read-only snapshot ----
        pids = [r["pid"] for r in repairs][-40:]
        catprocs = "cat " + " ".join("/proc/%s/stat" % p for p in pids) if pids else "echo nopid"
        devcmd = ("echo @@META; cat /proc/uptime; echo; cat /proc/loadavg; echo; cat /tmp/nerepair.hb 2>/dev/null || echo nohb; echo; "
                  "pidof nerepair || echo nopid; echo; ls -d /data/gw/nerepair.dry 2>/dev/null || echo no_dry; "
                  "ls -d /data/gw/nerepair.xrep 2>/dev/null || echo no_xrep; "
                  "ls -d /data/gw/slotguard.arm 2>/dev/null || echo no_arm; "
                  "echo @@WC; wc -l /data/gw/logs/nerepair.log /data/gw/logs/ne_events.tsv; "
                  "echo @@STAT; tail -1 /data/gw/logs/nerepair.log; "
                  "echo @@LOG; cat /data/gw/logs/nerepair.log; "
                  "echo @@PROC; " + catprocs)
        rc, out, err = lgssh(devcmd, timeout=180)
        if rc != 0 or "@@LOG" not in out:
            with open(alert_path, "a", encoding="utf-8") as f:
                f.write("%s POLL_FAIL rc=%s err=%s\n" % (stamp, rc, err[:200]))
            time.sleep(min(60, ns.interval))
            continue
        sec = {}
        cur = None
        for ln in out.splitlines():
            if ln.startswith("@@") and ln.strip() in ("@@META", "@@WC", "@@STAT", "@@LOG", "@@PROC"):
                cur = ln.strip(); sec[cur] = []
            else:
                sec.setdefault(cur or "raw", []).append(ln)
        meta = [x.strip() for x in sec.get("@@META", []) if x.strip()]
        uptime = meta[0] if meta else ""
        load = meta[1] if len(meta) > 1 else ""
        hb = meta[2] if len(meta) > 2 else ""
        npid = meta[3] if len(meta) > 3 else ""
        markers = [x.strip() for x in meta[4:7]]
        wc = [x.split() for x in sec.get("@@WC", []) if x.split()]
        log_lines = int(wc[0][0]) if len(wc) > 0 and wc[0][0].isdigit() else -1
        ne_lines = int(wc[1][0]) if len(wc) > 1 and wc[1][0].isdigit() else -1
        stat = parse_stat("\n".join(sec.get("@@STAT", [])))
        new_lines = [x for x in sec.get("@@LOG", []) if x and x not in seen]
        if new_lines:
            with open(merged_path, "a", encoding="utf-8") as f:
                f.write("\n".join(new_lines) + "\n")
            with open(seen_path, "a", encoding="utf-8") as f:
                f.write("\n".join(new_lines) + "\n")
            seen.update(new_lines)
        for ln in new_lines:
            p = ln.split("\t")
            if len(p) >= 5 and p[4] in ("REPAIR", "DREPAIR", "XREPAIR"):
                repairs.append({"pid": p[2], "comm": p[3], "event": p[4], "detail": p[5] if len(p) > 5 else "", "epoch": p[0], "at": stamp})
        # ---- survival：per-pid 持久化（survival.tsv；R-11 观测） ----
        surv_path = os.path.join(OUT, "survival.tsv")
        live, catcmd, procerr = read_procs([r["pid"] for r in repairs][-40:])
        surv = {}
        COLS9 = ["epoch","pid","comm","event","first_check","first_alive","last_alive","last_check","status"]
        COLS8 = ["epoch","pid","comm","event","first_check","last_alive","last_check","status"]
        if os.path.exists(surv_path):
            for ln in open(surv_path, encoding="utf-8", errors="replace").read().splitlines()[1:]:
                p = ln.split("\t")
                if len(p) >= 9:
                    surv[(p[0], p[1])] = dict(zip(COLS9, p))
                elif len(p) >= 8:      # 兼容旧 8 列（首活当末活，已弃用）
                    d8 = dict(zip(COLS8, p)); d8["first_alive"] = d8.get("last_alive", "")
                    surv[(d8["epoch"], d8["pid"])] = d8
        for r in repairs:
            key = (r["epoch"], r["pid"])
            ent = surv.get(key) or {"epoch": r["epoch"], "pid": r["pid"], "comm": r["comm"], "event": r["event"],
                                    "first_check": stamp, "first_alive": "", "last_alive": "", "last_check": stamp, "status": "not_seen"}
            ent["last_check"] = stamp
            if r["pid"] in live and live[r["pid"]][0] == r["comm"]:
                if not ent.get("first_alive"):
                    ent["first_alive"] = stamp
                ent["last_alive"] = stamp          # 每次仍活都刷新 => 末次确认存活
                ent["status"] = "alive"
            elif r["pid"] in live:
                ent["status"] = "pid_reused"
            elif ent.get("last_alive"):
                ent["status"] = "died_later"
            else:
                ent["status"] = "gone_before_first_poll"
            surv[key] = ent
        with open(surv_path, "w", encoding="utf-8") as f:
            f.write("\t".join(COLS9) + "\n")
            for k in sorted(surv.keys(), key=lambda x: (int(x[0]), x[1])):
                v = surv[k]
                f.write("\t".join([v[c] for c in COLS9]) + "\n")
        alive_n = sum(1 for v in surv.values() if v["status"] == "alive")
        dead_n = sum(1 for v in surv.values() if v["status"] in ("died_later", "gone_before_first_poll"))
        surv_summary = list(surv.values())[-10:]
        row = [stamp, uptime, load, hb, npid, "|".join(markers[:3]), str(log_lines), str(ne_lines)] + \
              [str((stat or {}).get(k, -1)) for k in ("attached","segv","repaired","passed","suppressed","loop","would","would2","dfhit","near","nearinsn","rep2")] + \
              [str(len(repairs)), str(alive_n), str(dead_n), str(len(new_lines)), "|".join(x for x in [npid and ("pid=" + npid)] + [m for m in markers[:3]])]
        if not os.path.exists(watch_path):
            open(watch_path, "w", encoding="utf-8").write("local_ts\tdev_uptime\tload\thb\tnpid\tmarkers\tlog_lines\tne_lines\tattached\tsegv\trepaired\tpassed\tsuppressed\tloop\twould\twould2\tdfhit\tnear\tnearinsn\trep2\tn_repairs\talive\tdead\tnew_lines\tnote\n")
        with open(watch_path, "a", encoding="utf-8") as f:
            f.write("\t".join(row) + "\n")
        # ---- mode0 弱门分诊（窗口内 DREPAIR，host 侧离线；task-7 建议的 armed 窗口护栏） ----
        ARM_EPOCH = 1793706921
        win_path = os.path.join(OUT, "derepair_window.log")
        triage_script = os.path.join(PUB, "tools", "oneoff", "sigsegv", "mode0_repair_triage.py")
        tri = {"n": 0, "ok": 0, "review": 0}
        try:
            with open(merged_path, encoding="utf-8", errors="replace") as f, open(win_path, "w", encoding="utf-8") as g:
                for ln in f:
                    p0 = ln.split("\t")
                    if len(p0) >= 5 and p0[0].isdigit() and int(p0[0]) >= ARM_EPOCH and p0[4] in ("DREPAIR", "XREPAIR"):
                        g.write(ln)
            if os.path.exists(triage_script) and os.path.getsize(win_path) > 0:
                pr = subprocess.run([sys.executable, "-I", triage_script, win_path], capture_output=True, text=True, timeout=120)
                for ln in (pr.stdout or "").splitlines():
                    if ln.startswith("deref repairs:"):
                        nums = re.findall(r"\d+", ln)
                        if len(nums) >= 3:
                            tri = {"n": int(nums[0]), "ok": int(nums[1]), "review": int(nums[2])}
        except Exception:
            tri = {"n": -1, "ok": -1, "review": -1}
        with open(os.path.join(OUT, "triage.tsv"), "a", encoding="utf-8") as f:
            f.write("%s\t%d\t%d\t%d\n" % (stamp, tri["n"], tri["ok"], tri["review"]))

        # ---- alerts ----
        alerts = []
        log_pulled = len(sec.get("@@LOG", []))
        if log_lines > 0 and abs(log_pulled - log_lines) > 1:
            alerts.append("LOG_PULL_MISMATCH device_wc=%d pulled=%d" % (log_lines, log_pulled))
        if stat and stat.get("mode") != "armed":
            alerts.append("MODE_NOT_ARMED mode=%s" % stat.get("mode"))
        if hb.strip().isdigit() and uptime:
            try:
                age = float(uptime.split()[0]) - float(hb.strip())   # hb = uptime 秒(整数)
                if age > 180:
                    alerts.append("HB_STALE age=%.0fs" % age)
            except Exception:
                pass
        if stat and stat.get("loop", 0) > 20:
            alerts.append("REPAIR_LOOP=%s" % stat.get("loop"))
        if tri["n"] > 0 and tri["review"] >= 2 and tri["review"] / float(tri["n"]) >= 0.30:
            alerts.append("DREPAIR_REVIEW_RATIO %d/%d" % (tri["review"], tri["n"]))
        try:
            l1 = float(load.split()[0])
            if l1 > 40:
                alerts.append("LOAD1=%.1f" % l1)
        except Exception:
            pass
        if alerts:
            with open(alert_path, "a", encoding="utf-8") as f:
                f.write("%s %s\n" % (stamp, ";".join(alerts)))
        with open(latest_path, "w", encoding="utf-8") as f:
            json.dump({"stamp": stamp, "uptime": uptime, "load": load, "npid": npid, "markers": markers,
                       "log_lines": log_lines, "log_pulled": log_pulled, "ne_lines": ne_lines, "stat": stat,
                       "n_repairs": len(repairs), "alive": alive_n, "dead": dead_n,
                       "survival_total": len(surv), "survival": surv_summary,
                       "repairs_last": repairs[-5:], "alerts": alerts, "devcmd": devcmd[:1500]}, f, ensure_ascii=False, indent=1)
        print("%s poll#%d log=%s ne=%s stat=%s repairs=%d alive=%d dead=%d alerts=%s" %
              (stamp, it, log_lines, ne_lines, stat and stat.get("mode"), len(repairs), alive_n, dead_n, alerts), flush=True)
        time.sleep(ns.interval)
    print("DONE it=%d at %s" % (it, now()), flush=True)

if __name__ == "__main__":
    main()
