#!/usr/bin/env python3
"""incident_audit.py v1.0 -- PC 侧独立留存审计（M1 / R1.4）

为什么需要它：设备侧的 retention_audit.sh 是**自证**（同一台机器既写账又审计）。
本工具把 incidents.tsv / incidents.seal 的**原始字节**取回 PC，在本地独立重算
md5、行数、seq 连续性、各 tier 最老龄，再与设备侧审计结论交叉核对；报告落到
_local/evidence/ 形成**设备外**的第二份见证（设备被人为改写时本报告仍留有旧事实）。

审计项（与设备侧 retention_audit.sh 同一套判据，独立实现）：
  1) 完整性：本地 md5/行数/字节 == seal 末行；seq 单调序号 1..N 无缺口，
     缺口必须等于 seal 里逐次 prune 的累计删除数；SEV1 从未被裁剪（rm1==0）
  2) 留存龄：各 tier rows/bytes/oldest_age_days 对合同阈值（SEV1 7d, SEV2/SEV3 1d）
  3) 交叉核对：设备侧 retention_audit.sh --json 的 overall 必须与本地重算一致
  4) 证据：报告写入 _local/evidence/M1-retention-audit-<UTC>.md

用法：
  python tools/incident_audit.py              # 审计设备并写报告（exit 1 = FAIL）
  python tools/incident_audit.py --no-report  # 只打印
  python tools/incident_audit.py --selftest   # 本地合成用例（不连设备）

退出码：0 = 完整性通过且无 FAIL（允许"历史不够长"的 GROWING/SHORT）；
        1 = 完整性失败；2 = 取数失败。
"""
import hashlib
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
EVID = os.path.abspath(os.path.join(REPO, "..", "_local", "evidence"))

CONTRACT = {"SEV1": 7, "SEV2": 1, "SEV3": 1}
TARGET = {"SEV1": 90, "SEV2": 30, "SEV3": 7}

DEV_LEDGER = "/data/gw/logs/incidents.tsv"
DEV_SEAL = "/data/gw/logs/incidents.seal"
DEV_STATUS = "/data/gw/incident_ledger.status"

COLS = ("ts", "sev", "cat", "comp", "dur", "ref", "detail", "seq")
TAB = "	"
NL = chr(10)


def rowline(r):
    return TAB.join(str(r[k]) for k in COLS)


def parse_rows(text):
    """TSV -> list of dict；坏行（列数不足/非数字 ts）单独计数。"""
    rows, bad = [], 0
    for line in text.split(NL):
        if not line:
            continue
        f = line.split(TAB)
        if len(f) != 8:
            bad += 1
            continue
        ts, sev, cat, comp, dur, ref, detail, seq = f
        if not ts.isdigit() or not seq.isdigit():
            bad += 1
            continue
        rows.append({"ts": int(ts), "sev": sev, "cat": cat, "comp": comp,
                     "dur": dur, "ref": ref, "detail": detail, "seq": int(seq)})
    return rows, bad


def parse_seal(text):
    out = {"lines": 0, "last": {}, "rm1": 0, "rm2": 0, "rm3": 0, "attest": {}}
    for line in text.split(NL):
        if not line.strip():
            continue
        out["lines"] += 1
        kv = {}
        for tok in line.split(" "):
            if "=" in tok:
                k, _, v = tok.partition("=")
                kv[k] = v
        for k in ("rm1", "rm2", "rm3"):
            try:
                out[k] += int(kv.get(k, "0"))
            except ValueError:
                pass
        md5 = kv.get("oldest_sev1_md5", "-")
        if md5 != "-" and md5 not in out["attest"]:
            out["attest"][md5] = (kv.get("ts", "-"), out["lines"])
        out["last"] = kv
    return out


def audit_text(ledger_text, seal_text, now=None):
    """纯函数：给定台账/seal 文本，返回审计结果 dict（可单测）。"""
    now = now or int(time.time())
    rows, bad = parse_rows(ledger_text)
    seal = parse_seal(seal_text)
    res = {"ok": True, "errors": [], "warnings": [], "rows": len(rows), "bad_rows": bad,
           "bytes": len(ledger_text.encode()), "tiers": {}, "seal": seal}
    md5 = hashlib.md5(ledger_text.encode()).hexdigest()
    res["md5"] = md5
    last = seal["last"]
    res["seal_rows"] = last.get("rows", "-")
    res["seal_bytes"] = last.get("bytes", "-")
    res["seal_md5"] = last.get("md5", "-")
    if not seal["lines"]:
        res["errors"].append("seal 为空：无法证明台账未被改写")
    else:
        if last.get("md5") != md5:
            res["errors"].append("md5 不符：台账内容与 seal 末行不一致（被改过/未记账的追加）")
        if str(last.get("rows", "")) != str(len(rows)):
            res["errors"].append("行数不符：文件 %d 行 vs seal %s" % (len(rows), last.get("rows")))
        if str(last.get("bytes", "")) != str(res["bytes"]):
            res["errors"].append("字节数不符：文件 %d vs seal %s" % (res["bytes"], last.get("bytes")))
    seqs = [r["seq"] for r in rows]
    first = seqs[0] if seqs else 0
    mx = max(seqs) if seqs else 0
    interior_gap = 0
    prev = None
    for s in seqs:
        if prev is not None and s != prev + 1:
            interior_gap += s - prev - 1
        prev = s
    gone = (first - 1) + interior_gap
    rec = seal["rm1"] + seal["rm2"] + seal["rm3"]
    res.update({"first_seq": first, "last_seq": mx, "gaps": interior_gap,
                "gone": gone, "recorded_removed": rec})
    if gone != rec:
        res["errors"].append(
            "seq 缺口未记账：丢失 %d 行，seal 只记录了 %d 行删除（丢行=篡改/被轮转吃掉）"
            % (gone, rec))
    if seal["rm1"] != 0:
        res["errors"].append("SEV1 被裁剪过 %d 行（R1.6：SEV1 永不自动删除）" % seal["rm1"])
    oldest_any = min((r["ts"] for r in rows), default=0)
    ledger_age = max(0, now - oldest_any)
    # pre_sync 行（写于 NTP 首同步前 / 时钟=固件构建日）日期不可信：
    # 单列统计，**不参与"最老龄"**，否则留存证据会被假日期顶高（2026-11-01 实弹：
    # 10 行 mdscan/pfcanary 带构建日 ts，把最老 SEV1 顶成 52.6 天）。
    presync_rows = [r for r in rows if "pre_sync=1" in r["detail"]]
    res["presync_n"] = len(presync_rows)
    for sev in ("SEV1", "SEV2", "SEV3"):
        sub = [r for r in rows if r["sev"] == sev and "pre_sync=1" not in r["detail"]]
        if not sub:
            res["tiers"][sev] = {"rows": 0, "bytes": 0, "oldest_ts": 0,
                                 "age_days": 0.0, "verdict": "NODATA",
                                 "contract_met": False,
                                 "target_days": TARGET[sev],
                                 "contract_days": CONTRACT[sev]}
            continue
        o = min(r["ts"] for r in sub)
        age = max(0, now - o)
        if age >= CONTRACT[sev] * 86400:
            v = "PASS"
        elif ledger_age < CONTRACT[sev] * 86400:
            v = "GROWING"
        else:
            v = "SHORT"
        res["tiers"][sev] = {
            "rows": len(sub),
            "bytes": sum(len(rowline(r).encode()) + 1 for r in sub),
            "oldest_ts": o, "age_days": round(age / 86400.0, 2),
            "verdict": v, "contract_met": age >= CONTRACT[sev] * 86400,
            "target_days": TARGET[sev], "contract_days": CONTRACT[sev],
        }
    s1 = [r for r in rows if r["sev"] == "SEV1"]
    res["oldest_sev1_attest"] = "-"
    if s1:
        o = min(s1, key=lambda r: r["ts"])
        m = hashlib.md5(rowline(o).encode()).hexdigest()
        res["oldest_sev1_md5"] = m
        a = seal["attest"].get(m)
        res["oldest_sev1_attest"] = ("ts=%s seal_line=%s" % a) if a else "未在 seal 中见证"
        if not a:
            if seal["attest"]:
                # seal 里记过别的见证却唯独没有这一行 = 该行是 seal 之后被塞进来的
                res["errors"].append("最老 SEV1 行未在 seal 里被见证过（该行是 seal 之后被塞进来的？）")
            else:
                res["warnings"].append("seal 未记录最老 SEV1 见证（旧格式/首次写账前）")
    res["drill_rows"] = sum(1 for r in rows if "drill=1" in r["detail"])
    res["presync_rows"] = sum(1 for r in rows if "pre_sync=1" in r["detail"])
    res["backfill_rows"] = sum(1 for r in rows if "backfill=1" in r["detail"])
    res["ok"] = not res["errors"]
    return res


def verdict_overall(res):
    if not res["ok"]:
        return "FAIL"
    vs = [t["verdict"] for t in res["tiers"].values()]
    if all(v == "PASS" for v in vs):
        return "PROVEN"
    return "PARTIAL"


def fetch(c, path):
    _, out, _ = c.exec_command("cat %s 2>/dev/null" % path, timeout=60)
    return out.read()


def run_device(no_report=False):
    sys.path.insert(0, HERE)
    import lgssh
    c = lgssh.connect()
    try:
        ledger_b = fetch(c, DEV_LEDGER)
        seal_b = fetch(c, DEV_SEAL)
        status_b = fetch(c, DEV_STATUS)
        _, out, _ = c.exec_command("sh /data/gw/retention_audit.sh --json 2>/dev/null", timeout=180)
        dev_audit = out.read().decode("utf-8", "replace").strip()
        _, out2, _ = c.exec_command("date +%s; date '+%F %T %Z'", timeout=30)
        devtime = out2.read().decode("utf-8", "replace").strip().split(NL)
    finally:
        c.close()
    if not ledger_b and not seal_b:
        print("!! 设备上没有 incidents.tsv/incidents.seal —— 台账尚未部署")
        return 2
    now = int(devtime[0]) if devtime and devtime[0].strip().isdigit() else int(time.time())
    res = audit_text(ledger_b.decode("utf-8", "replace"),
                     seal_b.decode("utf-8", "replace"), now=now)
    res["dev_audit"] = dev_audit
    res["dev_time"] = devtime[1] if len(devtime) > 1 else "?"
    res["status"] = status_b.decode("utf-8", "replace")
    ov = verdict_overall(res)
    if dev_audit:
        d_ov = ""
        for tok in dev_audit.split():
            if tok.startswith("overall="):
                d_ov = tok.split("=", 1)[1]
        if d_ov and d_ov != ov:
            res["errors"].append("设备侧 overall=%s 与本地重算 %s 不一致" % (d_ov, ov))
            res["ok"] = False
            ov = "FAIL"
    print("incident_audit v1.0  设备时刻 %s" % res["dev_time"])
    print("ledger=%s rows=%d bytes=%d md5=%s" % (DEV_LEDGER, res["rows"], res["bytes"], res["md5"]))
    print("seal: lines=%d rows=%s bytes=%s md5=%s" % (
        res["seal"]["lines"], res["seal_rows"], res["seal_bytes"], res["seal_md5"]))
    print("seq: first=%d last=%d interior_gaps=%d gone=%d recorded_removed=%d"
          % (res["first_seq"], res["last_seq"], res["gaps"], res["gone"],
             res["recorded_removed"]))
    for sev in ("SEV1", "SEV2", "SEV3"):
        t = res["tiers"][sev]
        print("%s rows=%-5d bytes=%-7d oldest_age_days=%-8s contract=%dd target=%dd verdict=%s"
              % (sev, t["rows"], t["bytes"], t["age_days"], t["contract_days"],
                 t["target_days"], t["verdict"]))
    print("oldest_sev1_attest=%s" % res["oldest_sev1_attest"])
    print("quality: drill_rows=%d presync_rows=%d backfill_rows=%d presync_excluded_from_oldest=%d"
          % (res["drill_rows"], res["presync_rows"], res["backfill_rows"], res["presync_n"]))
    for w in res["warnings"]:
        print("  ~ %s" % w)
    for e in res["errors"]:
        print("  !! %s" % e)
    print("OVERALL %s" % ov)
    if not no_report:
        os.makedirs(EVID, exist_ok=True)
        stamp = time.strftime("%Y%m%d-%H%M%S", time.gmtime())
        path = os.path.join(EVID, "M1-retention-audit-%s.md" % stamp)
        lines = ["# M1 留存审计（PC 侧独立重算）", "",
                 "- 生成: %s (设备时刻 %s)" % (stamp, res["dev_time"]),
                 "- 取数: %s %s %s（原始字节，本地重算）" % (DEV_LEDGER, DEV_SEAL, DEV_STATUS),
                 "- OVERALL: **%s**" % ov, "",
                 "| tier | rows | bytes | oldest_age_days | contract | target | verdict |",
                 "|---|---|---|---|---|---|---|"]
        for sev in ("SEV1", "SEV2", "SEV3"):
            t = res["tiers"][sev]
            lines.append("| %s | %d | %d | %s | %dd | %dd | %s |"
                         % (sev, t["rows"], t["bytes"], t["age_days"],
                            t["contract_days"], t["target_days"], t["verdict"]))
        lines += ["",
                  "- seq: first=%d last=%d interior_gaps=%d gone=%d recorded_removed=%d"
                  % (res["first_seq"], res["last_seq"], res["gaps"], res["gone"],
                     res["recorded_removed"]),
                  "- ledger md5=%s（seal 末行 md5=%s）" % (res["md5"], res["seal_md5"]),
                  "- 最老 SEV1 见证: %s" % res["oldest_sev1_attest"],
                  "- 演练标记行=%d / pre-sync 行=%d / 回填行=%d"
                  % (res["drill_rows"], res["presync_rows"], res["backfill_rows"])]
        if res["errors"]:
            lines += ["", "## 失败项"] + ["- %s" % e for e in res["errors"]]
        lines += ["", "## 复核命令", "    cd lg6151m-public && python tools/incident_audit.py", ""]
        with open(path, "w", encoding="utf-8", newline=NL) as f:
            f.write(NL.join(lines))
        print("报告: %s" % path)
    return 0 if ov in ("PROVEN", "PARTIAL") else 1


def selftest():
    now = 1800000000
    day = 86400
    bad = [0]

    def mk(rows):
        lines = []
        for i, (ts, sev, cat) in enumerate(rows, 1):
            lines.append(TAB.join([str(ts), sev, cat, "fixture", "-", "fixture", "row", str(i)]))
        text = NL.join(lines) + (NL if lines else "")
        seal = ("op=append ts=%d rows=%d bytes=%d md5=%s first_seq=1 last_seq=%d "
                "sev1=0 sev2=0 sev3=0 rm1=0 rm2=0 rm3=0 oldest_sev1_ts=- "
                "oldest_sev1_md5=- reason=fixture%s"
                % (now, len(lines), len(text.encode()),
                   hashlib.md5(text.encode()).hexdigest(), len(lines), NL))
        return text, seal

    def chk(name, want_ok, want_overall, ledger, seal):
        r = audit_text(ledger, seal, now=now)
        got = verdict_overall(r)
        if r["ok"] != want_ok or got != want_overall:
            print("  FAIL %s want ok=%s/%s got ok=%s/%s (%s)"
                  % (name, want_ok, want_overall, r["ok"], got, "; ".join(r["errors"])[:110]))
            bad[0] += 1
        else:
            print("  PASS %s -> ok=%s/%s" % (name, r["ok"], got))

    good = [(now - 40 * day, "SEV1", "ne"), (now - 10 * day, "SEV2", "svc_restart"),
            (now - 3 * day, "SEV3", "netcfg_repair")]
    t, s = mk(good)
    chk("good", True, "PROVEN", t, s)
    lines = t.rstrip(NL).split(NL)
    del lines[1]
    chk("seq_gap", False, "FAIL", NL.join(lines) + NL, s)
    chk("unsealed_append", False, "FAIL",
        t + TAB.join([str(now), "SEV3", "ledger", "x", "-", "f", "sneaky", "99"]) + NL, s)
    t2, s2 = mk([(now - 2 * day, "SEV1", "ne"), (now - 10 * day, "SEV2", "x"),
                 (now - 3 * day, "SEV3", "y")])
    r = audit_text(t2, s2, now=now)
    if r["tiers"]["SEV1"]["contract_met"] or r["tiers"]["SEV1"]["verdict"] != "SHORT":
        print("  FAIL sev1_too_young (verdict=%s)" % r["tiers"]["SEV1"]["verdict"])
        bad[0] += 1
    else:
        print("  PASS sev1_too_young -> SHORT/contract_met=no")
    lines = []
    for i, (ts, sev, cat) in enumerate(good, 3):
        lines.append(TAB.join([str(ts), sev, cat, "fixture", "-", "fixture", "row", str(i)]))
    t3 = NL.join(lines) + NL
    s3 = ("op=prune ts=%d rows=3 bytes=%d md5=%s first_seq=3 last_seq=5 sev1=1 sev2=1 "
          "sev3=1 rm1=0 rm2=0 rm3=2 oldest_sev1_ts=- oldest_sev1_md5=- reason=retention%s"
          % (now, len(t3.encode()), hashlib.md5(t3.encode()).hexdigest(), NL))
    chk("recorded_prune", True, "PROVEN", t3, s3)
    chk("sev1_pruned_flag", False, "FAIL", t3, s3.replace("rm1=0", "rm1=1"))
    t5, s5 = mk([(now - 40 * day, "SEV1", "ne"), (now - 3 * day, "SEV3", "y")])
    chk("tier_nodata", True, "PARTIAL", t5, s5)
    print("incident_audit selftest failures=%d" % bad[0])
    return 0 if bad[0] == 0 else 1


def main():
    args = sys.argv[1:]
    if "--selftest" in args:
        return selftest()
    return run_device(no_report=("--no-report" in args))


if __name__ == "__main__":
    sys.exit(main())
