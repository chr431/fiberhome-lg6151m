#!/usr/bin/env python3
"""wifi_fill_scan.py -- A5/S1b: find the wifi-side callback that fills the 32B
tuple struct consumed by mtk_warp's wifi_tx/rx_tuple_add (zeroed 32B, callback
fills {ptr@0; ?@8; u32@+8/+0xc/+0x10...}).

Hunt signature: a function that BOTH
  - loads a length-like field (ldrh [x,#2] tot_len / ldr w,[x,#off-len-ish])
  - loads an IPv4 saddr/daddr (ldr w,[x,#12] / [x,#16] on IP hdr)
  - stores two adjacent u32 into the destination struct (str wA,[x1,#n] then
    str wB,[x1,#n+4]) -- the {u32 len;__be32 ip} memory image needs NO byte
    swap, matching the 0 rev* instructions found in mtk_warp.
Usage: python -I wifi_fill_scan.py [ko] > out
"""
import sys, os, re

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common_ko import Ko

KO = sys.argv[1] if len(sys.argv) > 1 else 'analysis/vendor/mods/5.15.134/mt_wifi.ko'
k = Ko(KO)
print('scanning %s: %d funcs' % (KO, len(k.funcs)))

def parse_st(ops):
    m = re.match(r'(w\d+), \[(x\d+|sp)(?:, #(0x[0-9a-f]+|\d+))?\]', ops)
    if not m:
        return None
    return m.group(1), m.group(2), int(m.group(3).replace('0x', ''), 16) if m.group(3) else 0

hits = []
for f in k.funcs:
    if f['size'] == 0 or f['size'] > 0x400:
        continue
    ins = k.dis(f['val'], f['size'])
    if not ins:
        continue
    iploads = []   # loads from [x?,#12]/[#16] as w-reg (saddr/daddr)
    lenloads = []  # ldrh [x?,#2] (tot_len) or ldrh [x?,#0x3e] skb->len? keep generic: any ldrh
    stores = []    # str wA,[xB,#n]
    for x in ins:
        m, o = x.mnemonic, x.op_str
        if m in ('ldr', 'ldur') and o.startswith('w'):
            p = parse_st(o)
            if p and p[2] in (12, 16):
                iploads.append((x.address, o))
        if m in ('ldrh', 'ldurh'):
            p = parse_st(o)
            if p and p[2] == 2:
                lenloads.append((x.address, o))
        if m == 'str' and o.startswith('w'):
            p = parse_st(o)
            if p:
                stores.append((x.address, p))
    if not iploads:
        continue
    # adjacent u32 pair stores
    pair = None
    for i in range(len(stores) - 1):
        (a1, (r1, b1, n1)) = stores[i]
        (a2, (r2, b2, n2)) = stores[i + 1]
        if b1 == b2 and n2 == n1 + 4 and a2 - a1 <= 0x10:
            pair = (a1, b1, n1)
            break
    score = len(iploads) + (2 if lenloads else 0) + (3 if pair else 0) + (2 if pair and pair[2] in (0xc, 0x10) else 0)
    hits.append((score, f['name'], f['val'], f['size'], pair,
                 [o for _, o in iploads[:3]], [o for _, o in lenloads[:2]]))

hits.sort(reverse=True)
print('functions w/ saddr/daddr-style loads: %d; top 40 by score:' % len(hits))
for score, name, val, size, pair, ips, lens in hits[:40]:
    print('  %2d %-44s @0x%05x sz=0x-4x pair=%s ipl=%s len=%s' %
          (score, name[:44], val, pair, ips, lens))
