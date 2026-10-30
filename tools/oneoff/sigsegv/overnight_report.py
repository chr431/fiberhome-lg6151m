#!/usr/bin/env python3
"""overnight_report.py -- summarize the nerepair overnight run (pre-registered in
docs/SIGSEGV/OVERNIGHT.md).  Run on the PC: python tools/oneoff/sigsegv/overnight_report.py
"""
import os, sys, re

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..")))
import lgssh  # noqa: E402


def sh(cmd):
    c = lgssh.connect()
    try:
        _, out, err = c.exec_command(cmd, timeout=180)
        return out.read().decode("utf-8", "replace")
    finally:
        c.close()


def kv(text):
    d = {}
    for line in text.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def main():
    base = kv(sh("cat /data/gw/logs/overnight_baseline.txt"))
    ne0 = int(base.get("ne", "0") or 0)
    now = kv(sh(
        "echo epoch=$(date +%s); "
        "echo uptime=$(cut -d' ' -f1 /proc/uptime); "
        "echo load=$(cut -d' ' -f1 /proc/loadavg); "
        "echo ne=$(wc -l < /data/gw/logs/ne_events.tsv); "
        "echo vaguard=$(wc -l < /data/gw/logs/vaguard.tsv); "
        "echo reboots=$(wc -l < /data/gw/logs/reboots.log); "
        "echo h4=$(ls /data/repro/h4_* 2>/dev/null | wc -l); "
        "echo aee=$(ls -d /data/log/aee_exp/* 2>/dev/null | wc -l); "
        "echo stacks=$(ls /data/gw/logs/cores/meta/*.stack 2>/dev/null | wc -l); "
        "echo nerepair_pid=$(pgrep -f /data/gw/bin/nerepair | head -1); "
        "echo nerepair_hb=$(cat /tmp/nerepair.hb 2>/dev/null)"))
    ne = int(now.get("ne", "0") or 0)
    new_ne = sh("awk -v b=%d 'NR>b' /data/gw/logs/ne_events.tsv" % ne0) if ne > ne0 else ""
    log = sh("tail -n 4000 /data/gw/logs/nerepair.log 2>/dev/null")
    wd = sh("grep -a nerepair /tmp/watchdog.log 2>/dev/null | tail -20; echo '---'; grep -a nerepair /tmp/watchdog_state 2>/dev/null")

    events, comms, reasons = {}, {}, {}
    for line in log.splitlines():
        p = line.split("\t")
        if len(p) < 6:
            continue
        ev, comm, detail = p[4], p[3], p[5]
        events[ev] = events.get(ev, 0) + 1
        if ev in ("REPAIR", "SEGV", "PASS"):
            comms[(ev, comm)] = comms.get((ev, comm), 0) + 1
        if ev == "PASS":
            m = re.search(r"reason=([^ ]+)", detail)
            if m:
                reasons[m.group(1)] = reasons.get(m.group(1), 0) + 1

    ne_lines = [l for l in new_ne.splitlines() if l.strip()]
    sig11 = [l for l in ne_lines if "sig=11" in l]
    rep = events.get("REPAIR", 0)
    out = []
    out.append("# nerepair Overnight Report")
    out.append("")
    out.append("## 1. 基线 vs 现在")
    out.append("")
    out.append("| 指标 | 基线 | 现在 | 增量 |")
    out.append("|---|---|---|---|")
    for k in ("epoch", "uptime", "ne", "vaguard", "reboots", "h4", "aee", "stacks", "load", "nerepair_pid", "nerepair_hb"):
        b = base.get(k, "?")
        n = now.get(k, "?")
        try:
            d = int(n) - int(b)
        except Exception:
            d = ""
        out.append("| %s | %s | %s | %s |" % (k, b, n, d))
    out.append("")
    out.append("## 2. nerepair 事件（当前日志）")
    out.append("")
    out.append("- events: %s" % events)
    out.append("- REPAIR by comm: %s" % dict((k[1], v) for k, v in comms.items() if k[0] == "REPAIR"))
    out.append("- PASS reasons: %s" % reasons)
    out.append("")
    out.append("## 3. 新增 ne_events（基线之后）")
    out.append("")
    out.append("共 %d 条，其中 sig=11 %d 条：" % (len(ne_lines), len(sig11)))
    out.append("")
    for l in ne_lines[:40]:
        out.append("    " + l)
    out.append("")
    out.append("## 4. watchdog")
    out.append("")
    for l in wd.splitlines():
        out.append("    " + l)
    out.append("")
    out.append("## 5. 判据")
    out.append("")
    vg_b = int(base.get("vaguard", "0") or 0)
    vg_n = int(now.get("vaguard", "0") or 0)
    h4_b = int(base.get("h4", "0") or 0)
    h4_n = int(now.get("h4", "0") or 0)
    rb_b = int(base.get("reboots", "0") or 0)
    rb_n = int(now.get("reboots", "0") or 0)
    out.append("- vaguard 增量: %d (应为 0)" % (vg_n - vg_b))
    out.append("- h4 增量: %d (现象仍存在)" % (h4_n - h4_b))
    out.append("- reboots 增量: %d" % (rb_n - rb_b))
    out.append("- REPAIR: %d" % rep)
    out.append("- 新增 sig=11: %d" % len(sig11))
    if vg_n - vg_b != 0:
        out.append("- **警告：vaguard 仍在增长，闸门未关干净**")
    if rep > 0 and len(sig11) == 0:
        out.append("- **判据：有效（候选）**：有 REPAIR、无 sig=11 新增；确认 h4 增量>0 则现象仍在")
    elif rep > 0 and len(sig11) > 0:
        out.append("- **判据：部分**：有 REPAIR 但仍有 sig=11 死亡；对照上面的 PASS reason 与 ne 行")
    else:
        out.append("- **判据：无效/未观察到**：REPAIR=0；检查 nerepair 是否在跑、vaguard 是否真关")
    txt = "\n".join(out)
    print(txt)
    outpath = os.path.join(os.path.dirname(HERE), "..", "..", "..", "tmpfiles", "an4", "overnight_report.md")
    outpath = os.path.abspath(outpath)
    try:
        with open(outpath, "w", encoding="utf-8") as fh:
            fh.write(txt + "\n")
        print("\nwrote " + outpath)
    except Exception as e:
        print("write failed: %s" % e)


if __name__ == "__main__":
    main()
