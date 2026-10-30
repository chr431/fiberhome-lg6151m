#!/usr/bin/env python3
"""core_scan.py -- classify the fault-time va_list record in full ELF cores.

Companion to va_scan.py.  Reads NT_PRSTATUS (fault-time registers) and
NT_SIGINFO (fault address), then the 32 bytes at x2.  Also scans the captured
stack for {small,0,big,0} candidates, which is useful for natural cores where
the faulting pointer is not a va_list.

Usage:
    python core_scan.py --cores 'tmpfiles/an2/*.core' 'tmpfiles/round_logc/*.core'
    python core_scan.py --strict-an2
"""
import argparse
import collections
import csv
import glob
import json
import os
import struct
import sys

from elftools.elf.elffile import ELFFile

MASK56 = 0x00FFFFFFFFFFFFFF
REGNAMES = ["x%d" % i for i in range(31)] + ["sp", "pc", "pstate"]


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


class Core:
    def __init__(self, path):
        self.path = path
        self.f = open(path, "rb")
        self.e = ELFFile(self.f)
        self.notes = []
        self._parse_notes()

    def _parse_notes(self):
        for seg in self.e.iter_segments():
            if seg["p_type"] != "PT_NOTE":
                continue
            self.f.seek(seg["p_offset"])
            raw = self.f.read(seg["p_filesz"])
            p = 0
            while p + 12 <= len(raw):
                nsz, dsz, ntype = struct.unpack_from("<III", raw, p)
                name = raw[p + 12:p + 12 + nsz].rstrip(b"\0")
                dstart = p + 12 + ((nsz + 3) & ~3)
                desc = raw[dstart:dstart + dsz]
                self.notes.append((name.decode(errors="replace"), ntype, desc))
                p = dstart + ((dsz + 3) & ~3)

    def prstatus(self):
        for ns, t, d in self.notes:
            if t == 1 and ns == "CORE":
                pid, = struct.unpack_from("<i", d, 32)
                regs = {}
                for i, nm in enumerate(REGNAMES):
                    regs[nm], = struct.unpack_from("<Q", d, 112 + i * 8)
                return dict(pid=pid, regs=regs)
        return None

    def siginfo(self):
        for ns, t, d in self.notes:
            if t == 0x53494749 and ns == "CORE":
                signo, errno_, code = struct.unpack_from("<iii", d, 0)
                addr, = struct.unpack_from("<Q", d, 16)
                return dict(signo=signo, code=code, errno=errno_, addr=addr)
        return None

    def loads(self):
        out = []
        for seg in self.e.iter_segments():
            if seg["p_type"] == "PT_LOAD" and seg["p_filesz"]:
                out.append((seg["p_vaddr"], seg["p_offset"], seg["p_filesz"]))
        return out

    def read(self, va, n):
        for vaddr, off, filesz in self.loads():
            if vaddr <= va < vaddr + filesz:
                d = min(n, vaddr + filesz - va)
                self.f.seek(off + (va - vaddr))
                return self.f.read(d)
        return None

    def stack_candidates(self, limit=8):
        """Scan PT_LOAD segments for {small,0,big,0} candidates."""
        out = []
        for vaddr, off, filesz in self.loads():
            self.f.seek(off)
            data = self.f.read(filesz)
            for o in range(0, len(data) - 32 + 1, 8):
                w = struct.unpack_from("<QQQQ", data, o)
                if w[1] or w[3] or w[0] == 0 or w[0] >= (1 << 24):
                    continue
                hi = w[2] >> 32
                lo = w[2] & 0xFFFFFFFF
                if hi == 0 or not (0x100 <= lo <= 0x10000):
                    continue
                out.append((vaddr + o, w))
                if len(out) >= limit:
                    return out
        return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cores", nargs="*", default=[
        "tmpfiles/an2/*.core", "tmpfiles/round_logc/*.core"])
    ap.add_argument("--out", default="")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--strict-an2", action="store_true")
    args = ap.parse_args()

    paths = []
    for pat in args.cores:
        paths.extend(sorted(glob.glob(pat)))
    rows = []
    for path in paths:
        try:
            c = Core(path)
            pr = c.prstatus()
            si = c.siginfo()
        except Exception as e:
            rows.append(dict(file=os.path.basename(path), error=str(e)))
            continue
        if not pr or not si:
            rows.append(dict(file=os.path.basename(path), error="no prstatus/siginfo"))
            continue
        r = pr["regs"]
        x2, x8 = r["x2"], r["x8"]
        w = c.read(x2, 32) if x2 < (1 << 48) else None
        lw = c.read(x2 - 0x240, 32) if x2 >= 0x240 and x2 < (1 << 48) else None
        ww = struct.unpack("<QQQQ", w) if w and len(w) == 32 else None
        ll = struct.unpack("<QQQQ", lw) if lw and len(lw) == 32 else None
        cand = c.stack_candidates()
        delta_ok = None
        if ww:
            delta_ok = int((untag(ww[0] - 8) == untag(si["addr"])) or (ww[0] - 8 == si["addr"]))
        rows.append(dict(
            file=os.path.basename(path), pid=pr["pid"], pc=r["pc"], sp=r["sp"],
            addr=si["addr"], x2=x2, x8=x8,
            shape=shape(ww) if ww else "n/a",
            lower_shape=shape(ll) if ll else "n/a",
            delta_ok=delta_ok,
            w0=ww[0] if ww else None, w1=ww[1] if ww else None,
            w2=ww[2] if ww else None, w3=ww[3] if ww else None,
            cand=len(cand),
            cand0=("%#x" % cand[0][0]) if cand else "",
        ))

    if args.out:
        with open(args.out, "w", newline="") as fh:
            wr = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else [])
            wr.writeheader()
            wr.writerows(rows)

    summary = dict(
        n=len(rows),
        shape=dict(collections.Counter(r.get("shape", "error") for r in rows)),
        errors=[r for r in rows if "error" in r],
    )
    if args.json:
        print(json.dumps(summary, indent=1, ensure_ascii=False))
    else:
        print("%-22s %-6s %-10s %-10s %-10s %-8s %-8s %s" %
              ("file", "pid", "pc", "addr", "x2", "shape", "lower", "delta/cand"))
        for r in rows:
            if "error" in r:
                print("%-22s ERROR %s" % (r["file"], r["error"]))
                continue
            print("%-22s %-6d %#-10x %#-10x %#-10x %-8s %-8s %s/%d" % (
                r["file"], r["pid"], r["pc"], r["addr"], r["x2"],
                r["shape"], r["lower_shape"], r["delta_ok"], r["cand"]))
        print("shape:", summary["shape"])

    if args.strict_an2:
        exp = {"c27830.core": "A0B2", "c27834.core": "B0A2", "c27836.core": "A0B2",
               "c9409.core": "A0B2", "r11228.core": "A0B2", "r3850.core": "A0B2"}
        got = {r["file"]: r.get("shape") for r in rows if "file" in r}
        ok = all(got.get(k) == v for k, v in exp.items())
        print("STRICT-AN2:", "PASS" if ok else "FAIL", exp, got)
        return 0 if ok else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
