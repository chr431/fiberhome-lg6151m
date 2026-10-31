#!/usr/bin/env python3
"""boot_audit.py -- 重启归因审计 (R4.3 "重启原因" / R4.1 覆盖审计的证据源)

回答甲方那句最硬的话之前必须先回答: "这台设备到底重启了多少次, 每次是为什么?"
判据全部来自设备侧可复核证据, 不猜:

  * pstore/console-ramoops.*  —— ramoops 在**每次启动时**保存上一 boot 的 console;
    文件名带的是**本次** boot_id (精确对应), mtime = 本次启动时刻。
    → 这是最权威的"启动次数 + 死亡原因"台账。
  * /data/gw/logs/reboots.log —— reboot_sched 的触发行(计划重启)。±600s 内匹配到的
    启动判 scheduled。
  * /data/gw/healthdog.armlog  —— 每次 arm 成功(即该 boot 达到 stable-healthy)的 btime;
    与 pstore 启动数之差 = "没活到 stable 的启动数"。

分类(spec 0 诚实性: 判不出就写 unknown, 不猜):
  scheduled      计划重启(reboots.log 命中)
  crash          内核 panic / Oops / Internal error(ramoops 尾行)
  sysrq          人工 sysrq-b(SMP: stopping secondary CPUs)
  clean          人工/脚本 reboot(procd/reboot: Restarting system)
  unknown        无匹配证据(掉电、硬件看门狗、或 ramoops 未落盘)

用法:
  python tools/acceptance/boot_audit.py                 # 人读摘要 + 表
  python tools/acceptance/boot_audit.py --json out.json
  python tools/acceptance/boot_audit.py --tsv out.tsv
  python tools/acceptance/boot_audit.py --offline pstore_census.txt reboots.log armlog.txt
"""
import argparse
import datetime
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

CENSUS_CMD = r"""BB=/data/gw/bin/busybox
for f in /data/gw/logs/pstore/console-ramoops*; do
  e=$($BB stat -c %Y "$f" 2>/dev/null)
  m=$(grep -aoE 'Kernel panic[^]]*|Unable to handle kernel[^]]*|Internal error[^]]*|Restarting system|procd: reboot[^]]*|SMP: stopping secondary CPUs' "$f" 2>/dev/null | tail -1 | tr -d '\000' | cut -c1-60)
  l=$(tail -1 "$f" 2>/dev/null | tr -d '\000' | cut -c1-70)
  echo "$e|$m|$l"
done | sort -n"""

def classify(marker, last, boot_epoch, sched_epochs):
    """返回 (category, reason)."""
    for s in sched_epochs:
        if 0 <= boot_epoch - s <= 600:
            return "scheduled", "reboots.log(+%ds)" % (boot_epoch - s)
    m = marker or ""
    if "Kernel panic" in m:
        return "crash", m[:50]
    if "Unable to handle kernel" in m or "Internal error" in m:
        return "crash", m[:50]
    if "Restarting system" in m or "procd: reboot" in m:
        return "clean", "procd/reboot"
    if "SMP: stopping secondary CPUs" in (last or "") or "sysrq" in (last or ""):
        return "sysrq", "sysrq-b"
    return "unknown", (last or "")[:50]

def parse_reboots(text):
    out = []
    for line in text.splitlines():
        line = line.strip()
        if "REBOOT" not in line:
            continue
        # 2026-10-31 04:00:16 REBOOT target=04:00 ...
        try:
            ts = line.split(" REBOOT")[0]
            dt = datetime.datetime.strptime(ts, "%Y-%m-%d %H:%M:%S")
        except ValueError:
            continue
        out.append(int(dt.replace(tzinfo=datetime.timezone(
            datetime.timedelta(hours=8))).timestamp()))
    return out

def parse_armlog(text):
    bt = []
    for line in text.splitlines():
        for tok in line.split():
            if tok.startswith("btime="):
                try:
                    bt.append(int(tok[6:]))
                except ValueError:
                    pass
    return bt

def iso(epoch):
    return datetime.datetime.fromtimestamp(
        epoch, datetime.timezone(datetime.timedelta(hours=8))
    ).strftime("%Y-%m-%d %H:%M:%S")

def build(census_text, reboots_text, armlog_text):
    sched = parse_reboots(reboots_text)
    rows = []
    for line in census_text.splitlines():
        parts = line.split("|")
        if len(parts) < 3:
            continue
        try:
            e = int(parts[0])
        except ValueError:
            continue
        cat, why = classify(parts[1], parts[2], e, sched)
        rows.append(dict(epoch=e, iso=iso(e), category=cat, reason=why,
                         marker=(parts[1] or "")[:60], last=(parts[2] or "")[:70]))
    rows.sort(key=lambda r: r["epoch"])
    counts = {}
    for r in rows:
        counts[r["category"]] = counts.get(r["category"], 0) + 1
    matched = set()
    for r in rows:
        for i, s in enumerate(sched):
            if 0 <= r["epoch"] - s <= 600:
                matched.add(i)
    unmatched_sched = [iso(s) for i, s in enumerate(sched) if i not in matched]
    armed = parse_armlog(armlog_text)
    uniq_armed = sorted(set(armed))
    return dict(rows=rows, counts=counts, total=len(rows),
                scheduled_triggers=len(sched),
                scheduled_matched=len(matched),
                scheduled_unmatched=unmatched_sched,
                armed_boots=len(uniq_armed),
                armed_min=iso(uniq_armed[0]) if uniq_armed else None,
                armed_max=iso(uniq_armed[-1]) if uniq_armed else None)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    ap.add_argument("--tsv")
    ap.add_argument("--offline", nargs=3, metavar=("CENSUS", "REBOOTS", "ARMLOG"))
    a = ap.parse_args()

    if a.offline:
        census = open(a.offline[0], encoding="utf-8", errors="replace").read()
        reb = open(a.offline[1], encoding="utf-8", errors="replace").read()
        arm = open(a.offline[2], encoding="utf-8", errors="replace").read()
    else:
        from sshx import Dev
        with Dev() as d:
            _, census = d.run(CENSUS_CMD, timeout=180)
            _, reb = d.run("cat /data/gw/logs/reboots.log 2>/dev/null", timeout=60)
            _, arm = d.run("cat /data/gw/healthdog.armlog 2>/dev/null", timeout=60)

    res = build(census, reb, arm)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(res, f, ensure_ascii=False, indent=1)
    if a.tsv:
        with open(a.tsv, "w", encoding="utf-8") as f:
            f.write("epoch\tiso\tcategory\treason\tmarker\tlast_line\n")
            for r in res["rows"]:
                f.write("%d\t%s\t%s\t%s\t%s\t%s\n" % (
                    r["epoch"], r["iso"], r["category"],
                    r["reason"].replace("\t", " "),
                    r["marker"].replace("\t", " "),
                    r["last"].replace("\t", " ")))

    print("启动总数(pstore 台账): %d" % res["total"])
    for k in ("scheduled", "clean", "sysrq", "crash", "unknown"):
        if k in res["counts"]:
            print("  %-10s %d" % (k, res["counts"][k]))
    print("reboots.log 计划触发: %d 条, 其中 %d 条能在 pstore 里匹配到启动"
          % (res["scheduled_triggers"], res["scheduled_matched"]))
    if res["scheduled_unmatched"]:
        print("  !! 有触发行但无 pstore 启动记录(台账覆盖缺口): %s"
              % ", ".join(res["scheduled_unmatched"]))
    print("healthdog.armlog 达 stable-healthy 的启动: %d (%s .. %s)"
          % (res["armed_boots"], res["armed_min"], res["armed_max"]))
    print("未达 stable-healthy 的启动(含人工快速重启): %d"
          % (res["total"] - res["armed_boots"]))
    print()
    print("%-20s %-10s %s" % ("启动时刻", "类别", "证据"))
    for r in res["rows"]:
        print("%-20s %-10s %s" % (r["iso"], r["category"], r["reason"][:56]))
    return 0

if __name__ == "__main__":
    sys.exit(main())
