#!/usr/bin/env python3
"""ud1_analyze.py -- U-D1/E2 offline analysis of a scanary v1.22 victim log.

Answers:
  1. real (inj=0) vs injected hit counts and rate;
  2. per-VA and per-poff histograms;
  3. same-VA rewrite evidence (>=2 real appearances / changes at the same VA);
  4. whole-page CTX structure around the top VAs (regs spill? log text? packet data?).
Usage: python -I ud1_analyze.py <victim.log>
"""
import re
import sys
import collections
import struct

HIT_RE = re.compile(r'^EV (\d+) HIT_APPEAR (.*)$')
CHG_RE = re.compile(r'^EV (\d+) (HIT_CHANGE|HIT_REWRITE) (.*)$')
GONE_RE = re.compile(r'^EV (\d+) HIT_GONE va=(0x[0-9a-f]+)')
CTX_RE = re.compile(r'^EV (\d+) CTX .*?va=(0x[0-9a-f]+) .*?win=([0-9a-f]+)-([0-9a-f]+) bytes=(\d+) hex=([0-9a-f]+)')
EXIT_RE = re.compile(r'^EV (\d+) EXIT reason=(\w+) passes=(\d+) appear=(\d+)')

def kv(s):
    return dict(re.findall(r'([A-Za-z_][A-Za-z0-9_]*)=([^\s]+)', s))

def main(path):
    hits, chgs, gones, ctxs = [], [], [], {}
    exit_line = None
    for line in open(path, 'r', errors='replace'):
        m = HIT_RE.match(line)
        if m:
            d = kv(m.group(2))
            d['ev'] = int(m.group(1)); d['va'] = int(d['va'], 16)
            d['poff'] = int(d['poff'], 16); d['topva'] = int(d['topva'], 16)
            d['w'] = [int(x, 16) for x in d['w'].split(',')]
            d['inj'] = int(d['inj']); d['len'] = int(d['len']); d['ip'] = d['ip']
            hits.append(d); continue
        m = CHG_RE.match(line)
        if m:
            d = kv(m.group(3)); d['ev'] = int(m.group(1)); d['kind'] = m.group(2)
            d['va'] = int(d['va'], 16)
            d['w'] = [int(x, 16) for x in d['w'].split(',')]
            chgs.append(d); continue
        m = GONE_RE.match(line)
        if m:
            gones.append((int(m.group(1)), int(m.group(2), 16))); continue
        m = CTX_RE.match(line)
        if m:
            ev = int(m.group(1)); va = int(m.group(2), 16)
            lo = int(m.group(3), 16); hi = int(m.group(4), 16)
            hx = m.group(6)
            try:
                raw = bytes.fromhex(hx)
            except ValueError:
                continue
            # key by the nearest hit at the same EV/va
            ctxs.setdefault((ev, va), (lo, hi, raw)); continue
        m = EXIT_RE.match(line)
        if m:
            exit_line = m.group(0)

    real = [h for h in hits if h['inj'] == 0]
    inj = [h for h in hits if h['inj'] != 0]
    print("== U-D1/E2 report: %s" % path)
    if exit_line:
        print("EXIT:", exit_line)
    print("hits total=%d real=%d injected=%d changes=%d gones=%d ctx=%d" %
          (len(hits), len(real), len(inj), len(chgs), len(gones), len(ctxs)))
    if not real:
        print("NO REAL HITS")
        return

    span = max(h['ev'] for h in real) - min(h['ev'] for h in real)
    rate = len(real) / (span / 60e6) if span else 0.0
    print("real window=%.1fs rate=%.1f/min" % (span / 1e6, rate))

    byva = collections.Counter(h['va'] for h in real)
    print("\n-- per-VA (top 15) --")
    for va, n in byva.most_common(15):
        evs = [h['ev'] for h in real if h['va'] == va]
        ws = collections.Counter((h['w'][2] & 0xffffffff, h['ip']) for h in real if h['va'] == va)
        print("va=0x%x n=%d first=%.3fs last=%.3fs distinct_len/ip=%d %s" %
              (va, n, min(evs) / 1e6, max(evs) / 1e6, len(ws),
               list(ws.items())[:4]))
    print("distinct VAs=%d" % len(byva))

    poff = collections.Counter(h['poff'] for h in real)
    print("\n-- per-poff (top 15) --")
    print(poff.most_common(15))
    topva = collections.Counter(h['topva'] for h in real)
    print("per-topva:", topva.most_common(10))

    print("\n-- same-VA rewrites (>=2 real) --")
    for va, n in byva.most_common(8):
        if n < 2:
            continue
        seq = [h for h in real if h['va'] == va]
        print("va=0x%x n=%d" % (va, n))
        for h in seq[:10]:
            print("   ev=%.3fs w=%x,%x,%x,%x len=%d ip=%s" %
                  (h['ev'] / 1e6, *h['w'], h['len'], h['ip']))
        if len(seq) > 10:
            print("   ... %d more" % (len(seq) - 10))

    # CTX structure for the most frequent VA
    print("\n-- CTX structure for top VAs --")
    for va, n in byva.most_common(3):
        cand = [(ev, v) for (ev, v) in ctxs if abs(v - va) <= 16]
        if not cand:
            print("va=0x%x: no CTX" % va); continue
        ev, v = sorted(cand)[0]
        lo, hi, raw = ctxs[(ev, v)]
        off = va - lo
        print("va=0x%x ctx_ev=%.3fs win=0x%x-0x%x bytes=%d off=%d" %
              (va, ev / 1e6, lo, hi, len(raw), off))
        if 0 <= off <= len(raw) - 32:
            rec = raw[off:off + 32]
            words = struct.unpack('<4Q', rec)
            print("   record w=%s" % ",".join("%x" % w for w in words))
            for delta in (-64, -32, 32, 64):
                a = off + delta
                if 0 <= a <= len(raw) - 32:
                    w4 = struct.unpack('<4Q', raw[a:a + 32])
                    print("   @%+4d: %s" % (delta, " ".join("%016x" % w for w in w4)))
            # printable ASCII runs in the window
            runs, cur = [], b""
            for b in raw:
                if 32 <= b < 127:
                    cur += bytes([b])
                else:
                    if len(cur) >= 6:
                        runs.append(cur.decode('ascii'))
                    cur = b""
            if len(cur) >= 6:
                runs.append(cur.decode('ascii'))
            print("   ascii_runs=%d %s" % (len(runs), runs[:6]))

if __name__ == '__main__':
    main(sys.argv[1])
