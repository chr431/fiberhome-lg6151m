#!/usr/bin/env python3
"""warp_scan.py -- A5/S1: full static sweep of mtk_warp.ko for code that can
construct/write the 32B record  {u64 A; u64 0; u32 len; __be32 ip; u64 0}.

Patterns (each hit carries function/offset/evidence):
  PA  16B zero-slot pair writer   : stp Xt,xzr / stp xzr,Xt / str Xt + str xzr(+8)
  PB  32B zero region             : two stp xzr,xzr within 8 bytes (fill-target of a cb)
  PC  {u32 len;__be32 ip} packing : bfi/bfxil #32,#32 | lsl #32+orr | movk lsl#32
  PD  network byte swaps          : rev16/rev32/rev (weak marker)
  PE  IP-header-ish loads         : ldrh [x,#2] ldr [x,#12]/[x,#16] (weak, context)
  PF  DMA addr producers/consumers: callers of dma_map_* / dma_unmap_* + str of result
  PG  uaccess/copyout calls       : copy_to_user/nla_put/seq_* callers
Also dumps .rodata.str1.1 strings containing both a length and an address/ip
format token (S1.d: "who produces this data shape").

Usage: python -I warp_scan.py [ko_path] > warp_scan.out
"""
import sys, os, re, collections

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from common_ko import Ko, R_CALL26, R_JUMP26

KO = sys.argv[1] if len(sys.argv) > 1 else 'analysis/vendor/mods/5.15.134/mtk_warp.ko'
k = Ko(KO)

# ---------------------------------------------------------------- helpers
def reg_base(ops):
    m = re.match(r'\w+, \[(x\d+|sp)(?:, #(0x[0-9a-f]+|\d+))?\]', ops)
    if not m:
        return None
    return m.group(1), int(m.group(2).replace('0x', ''), 16) if m.group(2) else 0

PA, PB, PC, PD, PE, PF, PG = [], [], [], [], [], [], []
strzr_pairs = collections.Counter()   # per function count of xzr-slot stores
callers = collections.defaultdict(set)   # callee-pattern -> set of caller funcs

def note(L, fn, off, kind, ins, extra=''):
    L.append((fn, off, kind, '%-8s %s' % (ins.mnemonic, ins.op_str), extra))

# enumerate function ranges incl. gaps, then disassemble each
ranges = []
for f in k.funcs:
    ranges.append((f['val'], f['val'] + f['size'], f['name']))
cur = 0
gapno = 0
for (s, e, n) in ranges:
    if cur < s:
        gapno += 1
        ranges_insert = (cur, s, 'GAP%02d' % gapno)
        # keep ordering by collecting into separate list
    cur = e
# build ordered list with gaps
ordered = []
cur = 0
gapno = 0
for (s, e, n) in ranges:
    if cur < s:
        gapno += 1
        ordered.append((cur, s, 'GAP%02d' % gapno))
    ordered.append((s, e, n))
    cur = e
if cur < k.text['size']:
    gapno += 1
    ordered.append((cur, k.text['size'], 'GAP%02d' % gapno))

for (s, e, fname) in ordered:
    ins = k.dis(s, e - s)
    for i, x in enumerate(ins):
        m, o = x.mnemonic, x.op_str
        # ---- PE/PG/PG2: call classification via relocs
        if m in ('bl', 'b') and x.address in k.relocs:
            rt, nm, add = k.relocs[x.address]
            if rt in (R_CALL26, R_JUMP26):
                low = nm.lower()
                for pat in ('dma_map', 'dma_unmap', 'copy_to_user', 'copy_from_user',
                            'nla_put', 'seq_printf', 'seq_read', 'proc_', 'skb_'):
                    if pat in low:
                        callers[pat].add('%s+0x%x' % (fname, x.address))
                if 'tuple' in low:
                    callers['tuple'].add('%s+0x%x->%s' % (fname, x.address, nm))
        # ---- PA: stp with xzr as one of the pair
        if m == 'stp' and 'xzr' in o:
            note(PA, fname, x.address, 'PA-stp', x, '')
            strzr_pairs[fname] += 1
        # ---- PA2: str Xt,[b,#i] followed (<=3) by str xzr,[b,#i+8], same base
        elif m == 'str' and reg_base(o) and o.split(',')[0].strip().startswith('x') \
                and 'xzr' not in o:
            b1, i1 = reg_base(o)
            for j in range(i + 1, min(i + 4, len(ins))):
                y = ins[j]
                if y.mnemonic != 'str' or 'xzr' not in y.op_str:
                    continue
                b2, i2 = reg_base(y.op_str) or (None, None)
                if b2 == b1 and i2 == i1 + 8:
                    note(PA, fname, x.address, 'PA-strpair', x,
                         'then %s @+0x%x' % (y.op_str, y.address))
                    strzr_pairs[fname] += 1
                break
        # ---- PB: 32B zero region
        if m == 'stp' and o.startswith('xzr, xzr'):
            for j in range(i + 1, min(i + 5, len(ins))):
                if ins[j].mnemonic == 'stp' and ins[j].op_str.startswith('xzr, xzr'):
                    note(PB, fname, x.address, 'PB-32B', x,
                         'then @+0x%x %s %s' % (ins[j].address, ins[j].mnemonic, ins[j].op_str))
                    break
        # ---- PC: q2 packing
        if m in ('bfi', 'bfxil') and '#32' in o and '#32' in o.replace('0x32', ''):
            note(PC, fname, x.address, 'PC-bfi32', x, '')
        if m == 'lsl' and o.endswith('#32') and o.startswith('x'):
            for j in range(i + 1, min(i + 4, len(ins))):
                if ins[j].mnemonic == 'orr' and o.split(',')[0].split()[1][:3] in ins[j].op_str:
                    note(PC, fname, x.address, 'PC-lsl-orr', x,
                         'then orr %s' % ins[j].op_str)
                    break
        if m == 'orr' and 'lsl #32' in o:
            note(PC, fname, x.address, 'PC-orr32', x, '')
        if m == 'movk' and 'lsl #32' in o:
            note(PC, fname, x.address, 'PC-movk32', x, '')
        # ---- PD: byte swaps
        if m in ('rev16', 'rev32', 'rev'):
            note(PD, fname, x.address, 'PD-rev', x, '')
        # ---- PE: IP header offsets
        if m in ('ldrh', 'ldur') and reg_base(o):
            b, i2 = reg_base(o)
            if i2 == 2:
                note(PE, fname, x.address, 'PE-len2', x, '')
        if m in ('ldr', 'ldur') and reg_base(o):
            b, i2 = reg_base(o)
            if i2 in (12, 16) and o.startswith('w'):
                note(PE, fname, x.address, 'PE-addr%d' % i2, x, '')

# ---- PF: dma map callers, then store of result
for pat in sorted(callers):
    print('== callers of *%s*: %d' % (pat, len(callers[pat])))
    for c in sorted(callers[pat]):
        print('   ', c)
print()

def dump(name, L):
    print('==== %s (%d) ====' % (name, len(L)))
    for fn, off, kind, txt, extra in L:
        print('  %-34s 0x%05x %-10s %-34s %s' % (fn[:34], off, kind, txt[:34], extra))
    print()

dump('PA 16B zero-slot writers', PA)
dump('PB 32B zeroed regions', PB)
dump('PC {u32,u32}->x64 pack sites', PC)
dump('PD byte-swaps', PD)
dump('PE IP-hdr-offset loads', PE)
print('== per-function PA hit counts ==')
for fn, c in strzr_pairs.most_common(40):
    print('  %-40s %d' % (fn[:40], c))

# ---- S1.d: strings mentioning len+addr/ip shapes
ro = next(s for s in k.secs if s['name'] == '.rodata.str1.1')
blob = k.data[ro['off']:ro['off'] + ro['size']]
print('\n== format strings with len AND (addr|ip|sip|dip) tokens ==')
for m2 in re.finditer(rb'[\x20-\x7e]{4,}', blob):
    t = m2.group().decode('latin1')
    if re.search(r'%\d*[dux].*len|len.*%\d*[dux]', t, re.I) and re.search(r'(addr|sip|dip|\bip\b)', t, re.I):
        print('   ', t[:160])
print('\n== strings containing NO_INFO_WB / info / pkt len ==')
for m2 in re.finditer(rb'[\x20-\x7e]{4,}', blob):
    t = m2.group().decode('latin1')
    if re.search(r'(NO_INFO_WB|info_wb|flow_info|pkt.*len|len.*pkt)', t, re.I):
        print('   ', t[:160])
