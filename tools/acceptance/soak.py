#!/usr/bin/env python3
"""soak.py -- 30d soak 装置的 PC 侧一半: 拉取归档 / 趋势判定 / 漂移告警 / 日报

设备侧那一半是 gw/soak_checkpoint.sh (由 log_keeper 5min 块 fork 驱动)。
本工具做四件事:
  pull    把设备台账拉到 _local/evidence/soak/<UTC 时间戳>/ (不入公开仓)
  trend   从归档算趋势: /data 增长、NE 速率、fd/内存/僵尸、重启构成
  alert   漂移判定(退出码非 0 = 有告警), 供 cron/人工巡检
  daily   生成一份 <=40 行的人读日报(设备侧 + 归档)

诚实性: 缺失的列一律按"未知"处理并显式打印, 绝不把未知当 0。

用法:
  python tools/acceptance/soak.py pull
  python tools/acceptance/soak.py trend [--days 7]
  python tools/acceptance/soak.py alert
  python tools/acceptance/soak.py daily [--out file.md]
"""
import argparse
import datetime
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

PROJ = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
EVID = os.path.join(PROJ, "_local", "evidence", "soak")

FILES = [
    "/data/gw/logs/soak_daily.tsv",
    "/data/gw/logs/soak_boots.tsv",
    "/data/gw/logs/soak_alerts.tsv",
    "/data/gw/logs/fault_inject.tsv",
    "/data/gw/logs/drills.tsv",
    "/data/gw/logs/reboots.log",
]

# 漂移阈值(与设备侧 soak_checkpoint.sh 的判定对齐; 这里做跨天趋势判定)
DRIFT = dict(
    data_free_min_kb=102400,
    ne_per_day_max=50,
    boot_unplanned_max=1,
    mem_avail_min_kb=200000,
    zombies_max=20,
)

def _pull_one(dev, remote, localdir):
    name = os.path.basename(remote)
    _, out = dev.run("cat %s 2>/dev/null" % remote, timeout=120)
    if not out.strip():
        return name, 0, "absent"
    with open(os.path.join(localdir, name), "w", encoding="utf-8", newline="") as f:
        f.write(out if out.endswith("\n") else out + "\n")
    return name, len(out.splitlines()), "ok"

def cmd_pull(a):
    from sshx import Dev
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    d = os.path.join(EVID, stamp)
    os.makedirs(d, exist_ok=True)
    with Dev() as dev:
        for f in FILES:
            n, rows, st = _pull_one(dev, f, d)
            print("%-28s %-7s %d lines" % (n, st, rows))
    with open(os.path.join(EVID, "LATEST"), "w", encoding="utf-8") as f:
        f.write(stamp + "\n")
    print("archived ->", d)
    return 0

def _latest_dir():
    p = os.path.join(EVID, "LATEST")
    if os.path.isfile(p):
        s = open(p, encoding="utf-8").read().strip()
        d = os.path.join(EVID, s)
        if os.path.isdir(d):
            return d
    if not os.path.isdir(EVID):
        return None
    subs = sorted([x for x in os.listdir(EVID)
                   if os.path.isdir(os.path.join(EVID, x))])
    return os.path.join(EVID, subs[-1]) if subs else None

def load_tsv(path):
    if not os.path.isfile(path):
        return [], []
    rows = []
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = [l.rstrip("\n") for l in f if l.strip()]
    if not lines:
        return [], []
    lines[0] = lines[0].replace(chr(92) + "t", chr(9))  # 兼容 v1.0 注入器写的字面 backslash-t 表头
    hdr = lines[0].split("\t")
    for l in lines[1:]:
        p = l.split("\t")
        if len(p) < len(hdr):
            p += [""] * (len(hdr) - len(p))
        rows.append(dict(zip(hdr, p)))
    return hdr, rows

def _i(v, default=None):
    try:
        return int(v)
    except (TypeError, ValueError):
        return default

def cmd_trend(a):
    d = _latest_dir()
    if not d:
        print("no archive yet: run 'soak.py pull' first")
        return 2
    hdr, rows = load_tsv(os.path.join(d, "soak_daily.tsv"))
    if not rows:
        print("soak_daily.tsv empty/absent in", d)
        return 2
    rows = rows[-max(1, a.days):]
    print("archive: %s   days: %d" % (d, len(rows)))
    print("%-12s %10s %10s %8s %8s %8s %8s %6s %6s %8s" %
          ("day", "data_free", "logs_kb", "procs", "zomb", "fd", "memav", "ne24",
           "boots", "verdict"))
    for r in rows:
        print("%-12s %10s %10s %8s %8s %8s %8s %6s %6s %8s" % (
            r.get("day", "?"), r.get("data_free_kb", "?"), r.get("logs_kb", "?"),
            r.get("procs", "?"), r.get("zombies", "?"),
            r.get("fd_used", "?"), r.get("mem_avail_kb", "?"),
            r.get("ne_24h", "?"), r.get("boots_24h", "?"), r.get("verdict", "?")))
    ds = [(_i(r.get("epoch")), _i(r.get("data_used_kb")), _i(r.get("logs_kb")))
          for r in rows]
    ds = [x for x in ds if x[0] and x[1] is not None]
    if len(ds) >= 2:
        dt = (ds[-1][0] - ds[0][0]) / 86400.0
        if dt > 0:
            g_data = (ds[-1][1] - ds[0][1]) / dt
            g_logs = ((ds[-1][2] or 0) - (ds[0][2] or 0)) / dt
            print()
            print("斜率: /data %+.0f KB/day    logs %+.0f KB/day  (窗口 %.1f 天)"
                  % (g_data, g_logs, dt))
            free = _i(rows[-1].get("data_free_kb"))
            if free is not None and g_data > 0:
                print("按当前斜率, /data 剩余 %d KB 将在 %.0f 天后触底(<100MB)"
                      % (free, max(0, (free - 102400) / g_data)))
    return 0

def cmd_alert(a):
    d = _latest_dir()
    if not d:
        print("ALERT no-archive")
        return 2
    _, rows = load_tsv(os.path.join(d, "soak_daily.tsv"))
    if not rows:
        print("ALERT no-soak-daily")
        return 2
    last = rows[-1]
    bad = []
    free = _i(last.get("data_free_kb"))
    if free is not None and free < DRIFT["data_free_min_kb"]:
        bad.append("data_free=%dKB < %dKB" % (free, DRIFT["data_free_min_kb"]))
    ne = _i(last.get("ne_24h"))
    if ne is not None and ne > DRIFT["ne_per_day_max"]:
        bad.append("ne_24h=%d > %d" % (ne, DRIFT["ne_per_day_max"]))
    bup = _i(last.get("boots_unplanned_24h"))
    if bup is not None and bup > DRIFT["boot_unplanned_max"]:
        bad.append("boots_unplanned_24h=%d > %d" % (bup, DRIFT["boot_unplanned_max"]))
    ma = _i(last.get("mem_avail_kb"))
    if ma is not None and ma >= 0 and ma < DRIFT["mem_avail_min_kb"]:
        bad.append("mem_avail=%dKB < %dKB" % (ma, DRIFT["mem_avail_min_kb"]))
    zo = _i(last.get("zombies"))
    if zo is not None and zo > DRIFT["zombies_max"]:
        bad.append("zombies=%d > %d" % (zo, DRIFT["zombies_max"]))
    if last.get("scheduled_missed") == "1":
        bad.append("scheduled reboot missed today")
    if bad:
        for b in bad:
            print("ALERT", b)
        return 1
    print("OK no drift on", last.get("day"))
    return 0

def cmd_daily(a):
    d = _latest_dir()
    L = ["# soak 日报", ""]
    if not d:
        L.append("- 无归档(先跑 soak.py pull)")
    else:
        L.append("- 归档: " + d)
        _, daily = load_tsv(os.path.join(d, "soak_daily.tsv"))
        _, boots = load_tsv(os.path.join(d, "soak_boots.tsv"))
        _, inj = load_tsv(os.path.join(d, "fault_inject.tsv"))
        if daily:
            r = daily[-1]
            L.append("- 最新 checkpoint: day=%s up=%ss verdict=%s notes=%s" % (
                r.get("day"), r.get("up_s"), r.get("verdict"), r.get("notes")))
            L.append("- 资源: /data free %s KB (used %s%%)  logs %s KB  procs %s  zombies %s  fd %s/%s  memavail %s KB" % (
                r.get("data_free_kb"), r.get("data_used_pct"), r.get("logs_kb"),
                r.get("procs"), r.get("zombies"), r.get("fd_used"), r.get("fd_max"),
                r.get("mem_avail_kb")))
            L.append("- 重启: 24h 内 %s 次(计划 %s / 非计划 %s), 计划该来没来=%s" % (
                r.get("boots_24h"), r.get("boots_sched_24h"),
                r.get("boots_unplanned_24h"), r.get("scheduled_missed")))
            L.append("- 事故: NE 24h=%s(累计 %s)  repairs_24h=%s  incidents_24h=%s" % (
                r.get("ne_24h"), r.get("ne_total"), r.get("repairs_24h"),
                r.get("incidents_24h")))
            L.append("- 中断三档(<5s/5-20s/>20s): %s / %s / %s" % (
                r.get("svc_lt5_24h"), r.get("svc_5_20_24h"), r.get("svc_gt20_24h")))
        if boots:
            from collections import Counter
            c = Counter(b.get("cause", "?") for b in boots)
            L.append("- 开机台账: %d 条, 原因分布 %s" % (len(boots), dict(c)))
        if inj:
            from collections import Counter
            c = Counter(b.get("verdict", "?") for b in inj)
            L.append("- 注入台账: %d 条, 判定分布 %s" % (len(inj), dict(c)))
    txt = "\n".join(L) + "\n"
    if a.out:
        with open(a.out, "w", encoding="utf-8") as f:
            f.write(txt)
        print("written", a.out)
    else:
        sys.stdout.write(txt)
    return 0

def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("pull")
    t = sub.add_parser("trend"); t.add_argument("--days", type=int, default=30)
    sub.add_parser("alert")
    dd = sub.add_parser("daily"); dd.add_argument("--out")
    a = ap.parse_args()
    return {"pull": cmd_pull, "trend": cmd_trend,
            "alert": cmd_alert, "daily": cmd_daily}[a.cmd](a)

if __name__ == "__main__":
    sys.exit(main())
