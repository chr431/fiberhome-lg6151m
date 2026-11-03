#!/usr/bin/env python3
"""T1 ring-target analysis: parse on-device /proc/tuphook samples + patrace stack PAs.

Usage: python -I t1_ring_analyze.py <samples.log> <stackpa_start.txt> [stackpa_end.txt]
Prints a report to stdout; writes nothing.
"""
import re
import sys
from collections import Counter

LINEAR_BASE = 0xFFFFFF8000000000
LINEAR_END = 0xFFFFFFC000000000
USER_MAX = 1 << 39


def va_class(va):
    if va == 0:
        return "null"
    if va < USER_MAX:
        return "user"
    if LINEAR_BASE <= va < LINEAR_END:
        return "linear"
    if va >= LINEAR_END:
        return "vmalloc"
    return "gap"


def parse_pa_file(path):
    pas = set()
    for ln in open(path, errors="replace"):
        m = re.search(r"pid=(\d+) va=(0x[0-9a-f]+) pa=(0x[0-9a-f]+) err=(-?\d+)", ln)
        if not m:
            continue
        pa, err = int(m.group(3), 16), int(m.group(4))
        if err == 0 and pa:
            pas.add(pa & ~0xFFF)
    return pas


def family(q0, q1, q2, q3):
    if q1 == 0 and q3 == 0 and q0 != 0:
        ln = q2 & 0xFFFFFFFF
        ip = (q2 >> 32) & 0xFFFFFFFF
        first = (ip >> 24) & 0xFF
        if 0x40 <= ln <= 0x4000 and first not in (0, 127) and not (224 <= first <= 255):
            return "A0B2"
        if 0x1000 <= q2 <= 0x100000:
            return "B0A2"
    return None


FRE = re.compile(
    r"\s+F#(\d+) (tx|rx) lr=([0-9a-f]+) p=([0-9a-f]+) d=([0-9a-f]+) "
    r"br=([0-9a-f]+) rp=([0-9a-f]+) re=([0-9a-f]+) b8=([0-9a-f]+) "
    r"bc=([0-9a-f]+) f=([0-9a-f]+) "
    r"q=([0-9a-f]+),([0-9a-f]+),([0-9a-f]+),([0-9a-f]+) "
    r"t=(\d+) st=([0-9a-f]+) s=([0-9a-f]+),([0-9a-f]+),([0-9a-f]+)"
)
TRE = re.compile(
    r"\s+#(\d+) (tx|rx) skb=([0-9a-f]+) ctx=([0-9a-f]+) band=([0-9a-f]+) "
    r"x3=([0-9a-f]+) len=(\d+) ip=(\d+)\.(\d+)\.(\d+)\.(\d+) "
    r"st=([0-9a-f]+) ts=(\d+) proto=([0-9a-f]+)"
)
SRE = re.compile(r"===SAMPLE (\d+) ts=(\d+) up=([0-9.]+) h5=(\d+)")


def main():
    samples_path = sys.argv[1]
    canary_pas = set()
    for p in sys.argv[2:]:
        canary_pas |= parse_pa_file(p)
    print("canary stack page PAs (%d): %s" % (
        len(canary_pas), " ".join("%09x" % x for x in sorted(canary_pas))))

    frecs, trecs, samples = {}, {}, []
    last_cpu = -1
    for ln in open(samples_path, errors="replace"):
        ln = ln.rstrip("\n")
        m = SRE.match(ln)
        if m:
            samples.append({"i": int(m.group(1)), "ts": int(m.group(2)),
                            "up": float(m.group(3)), "h5": int(m.group(4))})
            continue
        m = re.match(r"fcpu(\d+):", ln) or re.match(r"cpu(\d+):", ln)
        if m:
            last_cpu = int(m.group(1))
            continue
        m = FRE.match(ln)
        if m:
            seq = int(m.group(1))
            frecs[(last_cpu, seq)] = {
                "seq": seq, "cpu": last_cpu, "dir": m.group(2),
                "lr": int(m.group(3), 16), "p": int(m.group(4), 16),
                "d": int(m.group(5), 16), "br": int(m.group(6), 16),
                "rp": int(m.group(7), 16), "re": int(m.group(8), 16),
                "b8": int(m.group(9), 16), "bc": int(m.group(10), 16),
                "f": int(m.group(11), 16),
                "q0": int(m.group(12), 16), "q1": int(m.group(13), 16),
                "q2": int(m.group(14), 16), "q3": int(m.group(15), 16),
                "t": int(m.group(16)), "st": int(m.group(17), 16),
                "s0": int(m.group(18), 16), "s1": int(m.group(19), 16),
                "s2": int(m.group(20), 16),
            }
            continue
        m = TRE.match(ln)
        if m:
            seq = int(m.group(1))
            trecs[(last_cpu, seq)] = {
                "seq": seq, "cpu": last_cpu, "dir": m.group(2),
                "len": int(m.group(7)),
                "ip": ".".join(m.group(i) for i in (8, 9, 10, 11)),
                "st": int(m.group(12), 16), "t": int(m.group(13)),
            }

    if samples:
        span = samples[-1]["ts"] - samples[0]["ts"]
        print("samples: %d  span: %d..%d (%ds)  h5: %d..%d" % (
            len(samples), samples[0]["ts"], samples[-1]["ts"], span,
            samples[0]["h5"], samples[-1]["h5"]))
    print("fill unique records: %d   tuple unique records: %d" % (len(frecs), len(trecs)))
    if frecs:
        ts = [r["t"] for r in frecs.values()]
        print("fill record ts range: %d..%d" % (min(ts), max(ts)))

    print("\n== fill per cpu / dir ==")
    c = Counter((r["cpu"], r["dir"]) for r in frecs.values())
    for k in sorted(c):
        print("  cpu%d %s: %d" % (k[0], k[1], c[k]))

    print("\n== fill address classes ==")
    for field in ("d", "rp", "br"):
        cc = Counter(va_class(r[field]) for r in frecs.values())
        print("  %s: %s" % (field, dict(cc)))

    print("\n== fill meta bits (st) top ==")
    for k, v in Counter(r["st"] for r in frecs.values()).most_common(12):
        print("  st=%08x n=%d" % (k, v))

    print("\n== ring_ptr (rp) ==")
    rps = [r["rp"] for r in frecs.values()]
    if rps:
        print("  unique rp: %d  min=%016x max=%016x" % (len(set(rps)), min(rps), max(rps)))
        lin = [r for r in frecs.values() if va_class(r["rp"]) == "linear"]
        pas = sorted({(r["rp"] - LINEAR_BASE) & ~0xFFF for r in lin})
        print("  linear rp: %d  unique PA pages: %d" % (len(lin), len(pas)))
        if pas:
            print("  PA pages: %d; first=%s last=%s" % (
                len(pas), ["%09x" % x for x in pas[:8]], ["%09x" % x for x in pas[-4:]]))

    print("\n== HITS ==")
    hits = []
    for r in frecs.values():
        for field in ("rp", "d"):
            v = r[field]
            cl = va_class(v)
            if cl == "user":
                hits.append((field, "user", v, r))
            elif cl == "linear" and ((v - LINEAR_BASE) & ~0xFFF) in canary_pas:
                hits.append((field, "linear-canary", v, r))
    print("  total hits: %d" % len(hits))
    for h in hits[:30]:
        r = h[3]
        print("  HIT %s %s v=%016x seq=%d cpu=%d ts=%d st=%08x" % (
            h[0], h[1], h[2], r["seq"], r["cpu"], r["t"], r["st"]))

    print("\n== fill q content family ==")
    fam = Counter(family(r["q0"], r["q1"], r["q2"], r["q3"]) for r in frecs.values())
    print("  %s" % dict(fam))
    nz = [r for r in frecs.values() if (r["q0"] | r["q1"] | r["q2"] | r["q3"])]
    print("  nonzero q records: %d" % len(nz))
    for r in nz[:8]:
        print("    seq=%d cpu=%d rp=%016x q=%016x,%016x,%016x,%016x st=%08x" % (
            r["seq"], r["cpu"], r["rp"], r["q0"], r["q1"], r["q2"], r["q3"], r["st"]))

    print("\n== lr ==")
    for k, v in Counter(r["lr"] for r in frecs.values()).most_common(8):
        print("  lr=%016x n=%d" % (k, v))

    print("\n== tuple records (cross-check) ==")
    if trecs:
        print("  unique: %d  dirs: %s" % (
            len(trecs), dict(Counter(r["dir"] for r in trecs.values()))))
        print("  len top: %s" % Counter(r["len"] for r in trecs.values()).most_common(8))
        print("  ip top: %s" % Counter(r["ip"] for r in trecs.values()).most_common(8))


if __name__ == "__main__":
    main()
