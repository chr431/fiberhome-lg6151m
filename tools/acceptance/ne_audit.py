#!/usr/bin/env python3
"""ne_audit.py -- NE 台账(ne_events.tsv)消费侧数据质量审计 (R2-C 第 1 项)

职责边界: 本工具只做**消费侧**校验 —— 字段数一致性、脏行定位、历史/新增判别、
M1(incidents.tsv)覆盖度交叉核对。**写入方根因**由 obs-ledger 负责, 这里不碰。

已知 schema 演进(设备侧 core_meta.sh 各版本):
  6 列  epoch/pid/comm/sig/exe/args                (最早)
  7 列  + origin                                  (加来源判定)
  8 列  + stack                                   (加栈窗口, 当前形态)
  9 列  = args 里含字面 TAB 导致多裂一列          (历史脏行)
  <5 列 = args 含字面换行, 一行事件被写成多行     (历史脏行; core_meta v1.11 已压平)

用法:
  python tools/acceptance/ne_audit.py            # 读设备
  python tools/acceptance/ne_audit.py --json out.json
  python tools/acceptance/ne_audit.py --since EPOCH
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

NE = "/data/gw/logs/ne_events.tsv"
INC = "/data/gw/logs/incidents.tsv"

CMD = ("awk -F'\\t' '{print NR\"\\t\"NF\"\\t\"$0}' %s" % NE)


def fetch():
    from sshx import Dev
    with Dev() as d:
        _, ne = d.run("cat %s 2>/dev/null" % NE, timeout=120)
        _, inc = d.run("awk -F'\\t' '$3==\"ne\"{c++} END{print c+0}' %s 2>/dev/null" % INC, timeout=120)
        _, cnt = d.run("wc -l < %s 2>/dev/null" % NE, timeout=60)
    return ne, inc.strip(), cnt.strip()


def audit(ne_text, inc_ne, total_lines):
    rows = ne_text.splitlines()
    nf_hist = {}
    bad = []
    last_ctx = None
    for i, line in enumerate(rows, 1):
        f = line.split("\t")
        nf = len(f)
        nf_hist[nf] = nf_hist.get(nf, 0) + 1
        if nf >= 6 and f[0].isdigit():
            last_ctx = int(f[0])
        if nf < 5:
            bad.append(dict(line=i, nf=nf, ctx=last_ctx, text=line[:60]))
    # 9 列: args 内含字面 TAB, 属脏行但不是碎片
    tabbed = [i for i, line in enumerate(rows, 1) if len(line.split("\t")) == 9]
    frag_ctx = [b["ctx"] for b in bad if b["ctx"]]
    return dict(
        total_lines=int(total_lines) if total_lines.isdigit() else len(rows),
        nf_hist={str(k): v for k, v in sorted(nf_hist.items())},
        fragment_rows=len(bad),
        fragment_line_range=[bad[0]["line"], bad[-1]["line"]] if bad else None,
        fragment_first_ctx=min(frag_ctx) if frag_ctx else None,
        fragment_last_ctx=max(frag_ctx) if frag_ctx else None,
        tab_split_rows=len(tabbed),
        incidents_ne_rows=int(inc_ne) if inc_ne.isdigit() else None,
        samples=bad[:3] + bad[-2:] if len(bad) > 5 else bad,
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--json")
    a = ap.parse_args()
    ne, inc_ne, cnt = fetch()
    r = audit(ne, inc_ne, cnt)
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump(r, f, ensure_ascii=False, indent=1)
    print("NE 台账行数: %d" % r["total_lines"])
    print("字段数分布: %s" % r["nf_hist"])
    print("碎片行(NF<5): %d 条, 行号 %s" % (r["fragment_rows"], r["fragment_line_range"]))
    print("  上下文 epoch 范围: %s .. %s" % (r["fragment_first_ctx"], r["fragment_last_ctx"]))
    print("  判据: 6/7/8 列是 schema 演进(正常); <5 列是 args 含换行被拆行(历史脏行)")
    print("args 含 TAB 导致的 9 列行: %d 条" % r["tab_split_rows"])
    print("M1 覆盖: incidents.tsv 中 category=ne 的行数 = %s" % r["incidents_ne_rows"])
    if r["samples"]:
        print("样本:")
        for s in r["samples"]:
            _t = s["text"].encode("ascii", "replace").decode("ascii")
            print("  line %d (NF=%d, ctx=%s): %s" % (s["line"], s["nf"], s["ctx"], _t))
    return 0


if __name__ == "__main__":
    sys.exit(main())