#!/usr/bin/env python3
"""d10_analyze.py -- pre-registered D10 analysis (see 05_LOG/2026-11-01-11 §4/§8).

Timeline: device /proc/uptime is master (realtime steps under NTP).
  process_start_mono = anchor.uptime - anchor.ev/1e6   (per anchor, cross-checked)
  pc->mono map from anchor pairs (pc_mid = (pc_before+pc_after)/2, uptime).
Arm windows from inject_*.json (pc start/end), trimmed 3 s each side.
"""
import glob
import json
import os
import re
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, "run")

M242 = {200, 208, 228, 242}
M1242 = {1200, 1208, 1228, 1242}
PEER_A = "192.168.9.222"
PEER_B = "192.168.9.223"
LOCAL = "192.168.9.1"
PCPRI = "192.168.9.120"

HIT_RE = re.compile(
    r"^EV (\d+) HIT_(APPEAR|CHANGE|REWRITE) .*?"
    r"w=([0-9a-f]+),([0-9a-f]+),([0-9a-f]+),([0-9a-f]+) len=(\d+) ip=(\S+) inj=(\d)")

def parse_hits(path):
    out = []
    with open(path, errors="replace") as f:
        for line in f:
            if " HIT_" not in line or " w=" not in line:
                continue
            m = re.match(r"EV (\d+) HIT_(\w+) .*?w=([0-9a-f]+),([0-9a-f]+),([0-9a-f]+),([0-9a-f]+) len=(\d+) ip=(\S+) inj=(\d)", line)
            if not m:
                continue
            ev, kind = int(m.group(1)), m.group(2)
            w2 = int(m.group(6), 16)
            ln = int(m.group(7))
            ip_pr = m.group(8)
            inj = int(m.group(9))
            # decode ip from w2 as well (authoritative): bytes = LE of high32
            ip_u32 = w2 >> 32
            ln_w2 = w2 & 0xFFFFFFFF
            ip_str = ".".join(str((ip_u32 >> (8 * i)) & 0xFF) for i in range(4))
            out.append({"ev_us": ev, "kind": kind, "len": ln, "len_w2": ln_w2,
                        "ip": ip_str, "ip_printed": ip_pr, "inj": inj, "raw": line.strip()})
    return out


def load_anchors():
    anc = []
    for p in sorted(glob.glob(os.path.join(RUN, "anchor_*.json"))):
        with open(p) as f:
            a = json.load(f)
        tag = a["tag"]
        try:
            a["uptime_f"] = float(a.get("up", "nan"))
            a["ev_f"] = float(a.get("ev", "nan"))
            a["pc_mid"] = (a["pc_before"] + a["pc_after"]) / 2.0
        except (ValueError, KeyError):
            print("bad anchor", tag, a.get("up"), a.get("ev"))
            continue
        anc.append(a)
    return anc


def main():
    logpath = sys.argv[1] if len(sys.argv) > 1 else None
    anchors = load_anchors()
    if not anchors:
        print("no anchors"); return 1
    # process_start_mono from each anchor
    starts = [a["uptime_f"] - a["ev_f"] / 1e6 for a in anchors]
    spread = max(starts) - min(starts)
    pstart = sum(starts) / len(starts)
    print("scanary process_start_mono estimates:",
          [round(s, 3) for s in starts], "spread=%.3f s" % spread)

    # pc -> mono linear map (use all anchors, least squares y = k*x + b via first/last)
    a0, a1 = anchors[0], anchors[-1]
    k = (a1["uptime_f"] - a0["uptime_f"]) / (a1["pc_mid"] - a0["pc_mid"])
    b = a0["uptime_f"] - k * a0["pc_mid"]
    print("pc->mono map: k=%.6f b=%.3f" % (k, b))
    for a in anchors:
        pred = k * a["pc_mid"] + b
        print("  anchor %-8s mono=%s pred=%.3f resid=%+.3f pc_mid=%.1f" %
              (a["tag"], a.get("up"), pred, pred - a["uptime_f"], a["pc_mid"]))

    # arms
    arms = []
    for p in sorted(glob.glob(os.path.join(RUN, "inject_*.json"))):
        with open(p) as f:
            r = json.load(f)
        if r["tag"] == "SANE":
            continue
        s = k * r["pc_epoch_start"] + b + 3.0
        e = k * r["pc_epoch_end"] + b - 3.0
        arms.append({"tag": r["tag"], "src": r["src"], "plen": r["plen"],
                     "ms": M1242 if r["plen"] == 1200 else M242,
                     "other_m": M242 if r["plen"] == 1200 else M1242,
                     "mono_s": s, "mono_e": e, "sent": r["sent"],
                     "pps": r["pps_achieved"]})
    arms.sort(key=lambda x: x["mono_s"])

    if logpath is None:
        print("\n(arm windows in device-uptime seconds; scanary start = %.3f)" % pstart)
        for a in arms:
            print("  %-3s src=%s plen=%d sent=%d pps=%.0f window=[%.3f, %.3f] uptime-rel=[%.1f, %.1f]" %
                  (a["tag"], a["src"], a["plen"], a["sent"], a["pps"],
                   a["mono_s"], a["mono_e"], a["mono_s"] - pstart, a["mono_e"] - pstart))
        return 0

    hits = parse_hits(logpath)
    print("\ntotal parsed HIT lines: %d (inj=0: %d)" % (len(hits), sum(1 for h in hits if not h["inj"])))

    def classify(h):
        mono = pstart + h["ev_us"] / 1e6
        for a in arms:
            if a["mono_s"] <= mono <= a["mono_e"]:
                return a["tag"], mono
        return None, mono

    report = {}
    for h in hits:
        if h["inj"]:
            continue
        if h["len"] != h["len_w2"]:
            print("WARN len mismatch parsed=%d w2=%d" % (h["len"], h["len_w2"]))
        arm, mono = classify(h)
        key = arm if arm else "OUT"
        r = report.setdefault(key, {"n": 0, "len": Counter(), "ip": Counter(),
                                    "m_own": 0, "m_other": 0, "exact_own": 0,
                                    "peer_ip": 0, "local_ip": 0, "kinds": Counter(),
                                    "mono": []})
        r["n"] += 1
        r["kinds"][h["kind"]] += 1
        r["len"][h["len"]] += 1
        r["ip"][h["ip"]] += 1
        r["mono"].append(mono)
        if arm:
            armdef = [a for a in arms if a["tag"] == arm][0]
            if h["len"] in armdef["ms"]:
                r["m_own"] += 1
            if h["len"] in armdef["other_m"]:
                r["m_other"] += 1
            if h["len"] in (242, 1242):
                r["exact_own"] += 1
        if h["ip"] in (PEER_A, PEER_B):
            r["peer_ip"] += 1
        if h["ip"] == LOCAL:
            r["local_ip"] += 1

    print("\n=== per-window report (inj=0) ===")
    order = [a["tag"] for a in arms] + ["OUT"]
    for key in order:
        if key not in report:
            continue
        r = report[key]
        monos = r["mono"]
        print("\n[%s] n=%d (%s) span=[%.1f..%.1f] uptime-rel" %
              (key, r["n"], dict(r["kinds"]),
               min(monos) - pstart if monos else -1, max(monos) - pstart if monos else -1))
        print("  len top10:", r["len"].most_common(10))
        print("  len>1536: %d/%d" % (sum(c for l, c in r["len"].items() if l > 1536), r["n"]))
        if key in [a["tag"] for a in arms]:
            print("  M(own-arm) hits: %d   M(other-arm) hits: %d   exact 242/1242: %d" %
                  (r["m_own"], r["m_other"], r["exact_own"]))
        print("  ip==.222/.223 (peer): %d  ip==192.168.9.1 (local): %d" % (r["peer_ip"], r["local_ip"]))
        print("  ip top8:", r["ip"].most_common(8))

    # headline counts
    tot_inj = sum(report[a["tag"]]["n"] for a in arms if a["tag"] in report)
    m_own_all = sum(report[a["tag"]]["m_own"] for a in arms if a["tag"] in report)
    ex_all = sum(report[a["tag"]]["exact_own"] for a in arms if a["tag"] in report)
    peer_all = sum(report[a["tag"]]["peer_ip"] for a in arms if a["tag"] in report)
    print("\n=== headline (all 4 injection windows) ===")
    print("inj-window records N=%d ; len in M(own arm)=%d ; exact 242/1242=%d ; ip==peer(.222/.223)=%d"
          % (tot_inj, m_own_all, ex_all, peer_all))
    if tot_inj:
        print("LOD (rule of three, if 0): per-record P < %.4f" % (3.0 / tot_inj))
    return 0


if __name__ == "__main__":
    sys.exit(main())
