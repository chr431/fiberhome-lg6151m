#!/usr/bin/env python3
"""natural_scan.py -- classify records in natural-NE captures.

Two formats:

  h4  : vsurv4 output
        120-byte header + npages*4096 stack pages
        header: <8sIIII 10Q II Q  (magic, version, pid, hit, sig,
                addr, fault_address, pc, sp, x2, x8, x29, x30,
                pstate, stack_top, npages, pad, ts)

  sd  : stackdump output (core_meta v1.7)
        48-byte header + u64 present bitmap + pages*4096
        header: <8sIIQQIIQ  (magic, version, pid, start, end,
                pages, reserved, ts)
        The fault context (x2/addr/pc) comes from the sibling .hdr
        (the first 4KB of the core, parsed by core_scan.Core).

Usage:
    python natural_scan.py --format h4 /data/repro/h4_*.bin
    python natural_scan.py --format sd --meta-dir /data/gw/logs/cores/meta
"""
import argparse
import collections
import csv
import glob
import json
import os
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

H4_HDR = struct.Struct("<8sIIII10QIIQ")
SD_HDR = struct.Struct("<8sIIQQIIQ")


def parse_h4(path):
    with open(path, "rb") as fh:
        d = fh.read()
    if len(d) < H4_HDR.size:
        return None, "short"
    v = H4_HDR.unpack_from(d, 0)
    (magic, version, pid, hit, sig, addr, fault_address, pc, sp, x2, x8,
     x29, x30, pstate, stack_top, npages, pad, ts) = v
    if magic[:4] != b"H4v1":
        return None, "bad magic"
    page0 = stack_top - npages * 4096 if stack_top else 0
    off = x2 - page0 if page0 and page0 <= x2 < stack_top else None
    w = None
    if off is not None and H4_HDR.size + off + 32 <= len(d):
        w = struct.unpack_from("<QQQQ", d, H4_HDR.size + off)
    return dict(kind="h4", pid=pid, hit=hit, sig=sig, addr=addr,
                fault_address=fault_address, pc=pc, sp=sp, x2=x2, x8=x8,
                stack_top=stack_top, npages=npages, ts=ts, w=w), None


def parse_sd(stack_path, hdr_path=None):
    with open(stack_path, "rb") as fh:
        d = fh.read()
    if len(d) < SD_HDR.size + 8:
        return None, "short"
    magic, version, pid, start, end, pages, reserved, ts = SD_HDR.unpack_from(d, 0)
    if magic[:4] != b"SDMP":
        return None, "bad magic"
    present, = struct.unpack_from("<Q", d, SD_HDR.size)
    page0 = SD_HDR.size + 8
    x2 = addr = pc = sp = None
    if hdr_path and os.path.exists(hdr_path):
        try:
            from core_scan import Core
            c = Core(hdr_path)
            pr = c.prstatus()
            si = c.siginfo()
            if pr and si:
                x2 = pr["regs"]["x2"]
                pc = pr["regs"]["pc"]
                sp = pr["regs"]["sp"]
                addr = si["addr"]
        except Exception:
            pass
    w = None
    if x2 is not None and start <= x2 < end:
        o = page0 + (x2 - start)
        if o + 32 <= len(d):
            w = struct.unpack_from("<QQQQ", d, o)
    return dict(kind="sd", pid=pid, hit=None, sig=None, addr=addr,
                fault_address=None, pc=pc, sp=sp, x2=x2, x8=None,
                stack_top=end, npages=pages, ts=ts, present=present, w=w), None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--format", choices=["h4", "sd"], required=True)
    ap.add_argument("--meta-dir", default="")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--out", default="")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    rows = []
    if args.format == "h4":
        for path in args.files:
            rec, err = parse_h4(path)
            if err:
                rows.append(dict(file=os.path.basename(path), error=err))
                continue
            w = rec["w"]
            rows.append(dict(file=os.path.basename(path), pid=rec["pid"],
                             hit=rec["hit"], addr=rec["addr"], pc=rec["pc"],
                             sp=rec["sp"], x2=rec["x2"], shape=shape(w) if w else "n/a",
                             delta_ok=(int((untag(w[0] - 8) == untag(rec["addr"])) or
                                           (w[0] - 8 == rec["addr"])) if w else None),
                             w0=w[0] if w else None, w2=w[2] if w else None))
    else:
        for stack_path in args.files or sorted(glob.glob(os.path.join(args.meta_dir, "*.stack"))):
            base = stack_path[:-6] if stack_path.endswith(".stack") else stack_path
            hdr = base + ".hdr"
            rec, err = parse_sd(stack_path, hdr if os.path.exists(hdr) else None)
            if err:
                rows.append(dict(file=os.path.basename(stack_path), error=err))
                continue
            w = rec["w"]
            rows.append(dict(file=os.path.basename(stack_path), pid=rec["pid"],
                             addr=rec["addr"], pc=rec["pc"], sp=rec["sp"],
                             x2=rec["x2"], shape=shape(w) if w else "n/a",
                             delta_ok=(int((untag(w[0] - 8) == untag(rec["addr"])) or
                                           (w[0] - 8 == rec["addr"])) if (w and rec["addr"] is not None) else None),
                             w0=w[0] if w else None, w2=w[2] if w else None))

    if args.out:
        with open(args.out, "w", newline="") as fh:
            wr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else [])
            wr.writeheader()
            wr.writerows(rows)
    summary = dict(n=len(rows),
                   shape=dict(collections.Counter(r.get("shape", "error") for r in rows)),
                   errors=[r for r in rows if "error" in r])
    if args.json:
        print(json.dumps(summary, indent=1, ensure_ascii=False))
    else:
        for r in rows:
            print(r)
        print("shape:", summary["shape"])
    return 0


if __name__ == "__main__":
    sys.exit(main())