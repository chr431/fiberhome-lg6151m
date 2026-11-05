#!/usr/bin/env python3
"""mode0_repair_triage.py -- host-side advisory triage for DEREF path-2 (mode 0) repairs.

WHY: the shipped mode-0 gate (find_record_near_stack, mode=0) does NOT call shape_ok().
     A host regression (nerepair_mode0_test.c) measures a 100% accept rate on constructed
     zero-padded small-value windows that shape_ok rejects.  While the device runs ARMED,
     this script flags DEREF (DREPAIR) lines whose logged record does not survive a shape
     re-check, so a human can review them before they are counted as real repairs.

Scope: read-only over a nerepair.log copy / live cat.  It does NOT touch the device.

Rule (both orientations, because the scan can land one 32 B window early):
  orientation A (which=q0): the logged window is [q0, 0, q2, 0]; shape_ok must accept it
      with f = addr.
  orientation B (which=q2): the matched word is q2, so the true record -- if any -- sits one
      window later.  The logged window's own w0 is q0; accept only if q0 looks like a record
      A word (0 < q0 < 2^24) AND q2 looks like a {len,ip} composite (high 32 bits != 0 and
      low 32 bits in [0x400,0x20000]).
Anything else is printed as REVIEW.
"""
import re, sys

TAGMASK = 0x00FFFFFFFFFFFFFF
LEN_MIN, LEN_MAX = 0x400, 0x20000


def shape_ok(w, fault):
    f = fault & TAGMASK
    w0 = w[0] & TAGMASK
    w1, w2, w3 = w[1], w[2], w[3]
    small0 = 0 < f < (1 << 24)
    small2 = 0 < w2 < (1 << 24)
    big0 = (f >> 32) != 0 and (f & 0xFFFFFFFF) != 0
    big2 = (w2 >> 32) != 0 and (w2 & 0xFFFFFFFF) != 0
    if w1 != 0 or w3 != 0:
        return 0
    if w0 != f and w0 != ((f + 8) & TAGMASK):
        return 0
    if small0 and big2:
        return LEN_MIN <= (w2 & 0xFFFFFFFF) <= LEN_MAX
    if big0 and small2:
        return LEN_MIN <= (w0 & 0xFFFFFFFF) <= LEN_MAX
    return 0


KV = re.compile(r"(pc|addr|q0|q2|which)=([0-9a-fx]+|q\d)")


def parse(line):
    d = {}
    for k, v in KV.findall(line):
        if k == "which":
            d["which"] = int(v[1:])
        else:
            d[k] = int(v, 16)
    return d


def main():
    if len(sys.argv) < 2:
        print("usage: mode0_repair_triage.py <nerepair.log>"); return 2
    n = rev = ok = 0
    for line in open(sys.argv[1], "r", errors="replace"):
        if "\tDREPAIR\t" not in line and "\tXREPAIR\t" not in line:
            continue
        n += 1
        d = parse(line.split("\t")[-1])
        if "addr" not in d or "q0" not in d or "q2" not in d:
            rev += 1; print("REVIEW (unparsable) %s" % line.rstrip()[:160]); continue
        w = [d["q0"], 0, d["q2"], 0]
        verdict = "REVIEW"
        if d.get("which", 0) == 0:
            verdict = "ok" if shape_ok(w, d["addr"]) else "REVIEW"
        else:
            a_like = 0 < d["q0"] < (1 << 24)
            comp = (d["q2"] >> 32) != 0 and LEN_MIN <= (d["q2"] & 0xFFFFFFFF) <= LEN_MAX
            verdict = "ok" if (a_like and comp) else "REVIEW"
        if verdict == "ok":
            ok += 1
        else:
            rev += 1
            print("REVIEW pc=0x%x addr=0x%x q0=0x%x q2=0x%x which=q%d"
                  % (d.get("pc", 0), d["addr"], d["q0"], d["q2"], d.get("which", -1)))
    print("---")
    print("deref repairs: %d ; shape-consistent: %d ; REVIEW: %d" % (n, ok, rev))
    print("advisory only: orientation-B 'ok' cannot be proven from the log alone (the window"
          " before the hit is not logged); a REVIEW line is a candidate false positive, not a"
          " verdict.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
