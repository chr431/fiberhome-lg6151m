#!/usr/bin/env python3
"""va_scan.py -- classify the fault-time va_list record in 16KB stack dumps.

Why this exists
---------------
The old attrib.py checked a hard-coded slot 0x7ffffff780.  In the vsurv3
dumps the fault-time va_list is ucontext.regs[2] = 0x7ffffff9c0; 0x780 is a
deeper copy.  Checking the wrong slot split one record family into "71 known
/ 35 unknown".  This tool reads the fault-time x2 from the ucontext.

Dump format (vsurv3 dump_pages):
    0x00  u64 base
    0x08  u64 top
    0x10  stack pages (base .. top), 4 pages by default
Fault context:
    siginfo at some offset: signo=11, errno=0, code=1, pad, si_addr
    ucontext at siginfo+0x130:
        fault_address, regs[31], sp, pc, pstate
    fault-time x2 = ucontext.regs[2]

Usage:
    python va_scan.py --dump-dir tmpfiles/an4/h3b --log-dir tmpfiles/an4/v3l
    python va_scan.py --legacy          # reproduce the old 0x780 split
    python va_scan.py --strict          # exit 1 unless 71/32/3

No third-party dependencies.
"""
import argparse
import collections
import csv
import glob
import json
import os
import re
import struct
import sys

MASK56 = 0x00FFFFFFFFFFFFFF


def untag(v):
    return v & MASK56


def small(v):
    return 0 < v < (1 << 24)


def big(v):
    return (v >> 32) != 0 and (v & 0xFFFFFFFF) != 0


def shape(w):
    if small(w[0]) and w[1] == 0 and big(w[2]) and w[3] == 0:
        return "A0B2"
    if big(w[0]) and w[1] == 0 and small(w[2]) and w[3] == 0:
        return "B0A2"
    return "other"


def record_like(w):
    hi = w[2] >> 32
    lo = w[2] & 0xFFFFFFFF
    return (w[1] == 0 and w[3] == 0 and w[0] != 0
            and hi != 0 and 0x100 <= lo <= 0x10000)


def read_logs(log_dir):
    """Return {(pid, n): addr} from VSURV/HIT lines."""
    hits = {}
    for path in glob.glob(os.path.join(log_dir, "*.log")):
        pid = None
        with open(path, errors="replace") as fh:
            for line in fh:
                m = re.search(r"VSURV pid=(\d+)", line)
                if m:
                    pid = int(m.group(1))
                m = re.search(r"HIT n=(\d+) sig=(\d+) addr=(\S+)", line)
                if m and pid is not None:
                    hits[(pid, int(m.group(1)))] = int(m.group(3), 16)
    return hits


def find_siginfo(body, addr):
    """Find the fault siginfo; tolerate tagged/untagged si_addr."""
    pat = struct.pack("<iiii", 11, 0, 1, 0) + struct.pack("<Q", addr)
    off = body.find(pat)
    if off >= 0:
        return off
    for tag in range(256):
        pat = struct.pack("<iiii", 11, 0, 1, 0) + struct.pack("<Q", addr | (tag << 56))
        off = body.find(pat)
        if off >= 0:
            return off
    return -1


def parse_dump(path, addr):
    with open(path, "rb") as fh:
        d = fh.read()
    if len(d) < 16 + 32:
        return None, "short"
    base, top = struct.unpack_from("<QQ", d, 0)
    body = d[16:]
    si = find_siginfo(body, addr)
    if si < 0:
        return None, "no siginfo"
    uc = si + 0x130
    if uc + 34 * 8 > len(body):
        return None, "ucontext truncated"
    vals = struct.unpack_from("<34Q", body, uc)
    x2 = vals[3]
    x8 = vals[9]
    sp = vals[32]
    pc = vals[33]
    o = x2 - base
    if not (0 <= o <= len(body) - 32):
        return None, "x2 outside dump"
    w = struct.unpack_from("<QQQQ", body, o)
    lo = o - 0x240
    lw = struct.unpack_from("<QQQQ", body, lo) if lo >= 0 else None
    return dict(base=base, top=top, body=body, si=si, uc=uc, x2=x2, x8=x8,
                sp=sp, pc=pc, w=w, lw=lw, off=o), None


def legacy_slot(body, base):
    o = 0x7FFFFFF780 - base
    if 0 <= o <= len(body) - 32:
        return struct.unpack_from("<QQQQ", body, o)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dump-dir", default="tmpfiles/an4/h3b")
    ap.add_argument("--log-dir", default="tmpfiles/an4/v3l")
    ap.add_argument("--out", default="")
    ap.add_argument("--legacy", action="store_true",
                    help="classify the old hard-coded 0x780 slot instead of x2")
    ap.add_argument("--strict", action="store_true",
                    help="exit 1 unless x2 shapes are 71 A0B2 / 32 B0A2 / 3 other")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    hits = read_logs(args.log_dir)
    rows = []
    errors = []
    for path in sorted(glob.glob(os.path.join(args.dump_dir, "*.bin"))):
        m = re.match(r"h3_(\d+)_(\d+)\.bin$", os.path.basename(path))
        if not m:
            continue
        pid, n = int(m.group(1)), int(m.group(2))
        addr = hits.get((pid, n))
        if addr is None:
            errors.append((os.path.basename(path), "no log line"))
            continue
        rec, err = parse_dump(path, addr)
        if err:
            errors.append((os.path.basename(path), err))
            continue
        w, lw = rec["w"], rec["lw"]
        sh = shape(w)
        lsh = shape(lw) if lw else "none"
        delta_ok = (untag(w[0] - 8) == untag(addr)) or (w[0] - 8 == addr)
        legacy = legacy_slot(rec["body"], rec["base"])
        lshape = shape(legacy) if legacy else "none"
        rows.append(dict(
            file=os.path.basename(path), pid=pid, n=n, addr=addr,
            x2=rec["x2"], x8=rec["x8"], sp=rec["sp"], pc=rec["pc"],
            w0=w[0], w1=w[1], w2=w[2], w3=w[3], shape=sh,
            lower_shape=lsh, delta_ok=int(delta_ok),
            legacy_shape=lshape,
        ))

    if args.legacy:
        # emulate attrib.py: record-like at 0x780, then shape
        for r in rows:
            r["shape"] = r["legacy_shape"]
            r["lower_shape"] = "n/a"
            r["delta_ok"] = "n/a"

    if args.out:
        with open(args.out, "w", newline="") as fh:
            wr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else [])
            wr.writeheader()
            wr.writerows(rows)

    summary = dict(
        n=len(rows),
        errors=errors,
        shape=dict(collections.Counter(r["shape"] for r in rows)),
        lower_shape=dict(collections.Counter(r["lower_shape"] for r in rows)),
        delta_ok=sum(1 for r in rows if r["delta_ok"] == 1),
        x2=dict(collections.Counter(hex(r["x2"]) for r in rows)),
        legacy_shape=dict(collections.Counter(r["legacy_shape"] for r in rows)),
    )
    if args.json:
        print(json.dumps(summary, indent=1, ensure_ascii=False))
    else:
        print("dumps:", len(rows), "errors:", len(errors))
        for name, err in errors:
            print("  ERR", name, err)
        print("x2:", summary["x2"])
        print("fault shape:", summary["shape"])
        print("lower shape:", summary["lower_shape"])
        print("delta_ok:", summary["delta_ok"], "/", len(rows))
        print("legacy 0x780 shape:", summary["legacy_shape"])

    if args.strict:
        exp = {"A0B2": 71, "B0A2": 32, "other": 3}
        got = summary["shape"]
        ok = all(got.get(k, 0) == v for k, v in exp.items()) and len(rows) == 106
        print("STRICT:", "PASS" if ok else "FAIL", "expected", exp, "got", got)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
