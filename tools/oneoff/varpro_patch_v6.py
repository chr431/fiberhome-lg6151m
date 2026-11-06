#!/usr/bin/env python3
"""varpro_patch_v6.py -- strict variadic-prologue FP-save neutralizer (U-P).

v6 fixes the v5 false positive that broke busybox bb_perror_msg:
v5 treated ANY cluster of >=2 stp q,[sp] as a vararg save block, so it
NOPed the three 32-byte va_list copies in the printf helper (0x408c68..70).
v6 only patches q stores that are (a) in a real function prologue, (b) in a
function carrying the musl va_list vr_offs=-0x80 signature, (c) BEFORE the
first call of that function, and (d) NOT copies (same q register loaded from
any base in the preceding 24 instructions).

Shapes: str qN,[sp,#imm] runs and stp qA,qB,[sp,#imm] pairs; pre-indexed stp
writeback is replaced by sub sp,sp,#N to preserve the frame.
"""
import sys, struct
import capstone

NOP = 0xD503201F
ALLOW_RELOAD = False
ONLY = None

def load_elf(path):
    d = bytearray(open(path, 'rb').read())
    assert d[:4] == b'\x7fELF' and d[4] == 2
    e_phoff = struct.unpack_from('<Q', d, 0x20)[0]
    e_phentsize = struct.unpack_from('<H', d, 0x36)[0]
    e_phnum = struct.unpack_from('<H', d, 0x38)[0]
    segs = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, p_flags = struct.unpack_from('<II', d, off)
        p_off, p_va, _, p_sz = struct.unpack_from('<QQQQ', d, off + 8)
        if p_type == 1 and (p_flags & 1):
            segs.append((p_off, p_va, p_sz))
    return d, segs

def va2off(segs, va):
    for foff, vaddr, sz in segs:
        if vaddr <= va < vaddr + sz:
            return foff + (va - vaddr)
    return None

def qregs_of(ins):
    """return (list of q-reg numbers, is_stp, writeback) for q store to [sp], else None"""
    if ins.mnemonic == 'str' and '[sp' in ins.op_str:
        left = ins.op_str.split('[')[0].strip().rstrip(',')
        if left.startswith('q') and left[1:].isdigit():
            return [int(left[1:])], False, False
        return None
    if ins.mnemonic == 'stp' and '[sp' in ins.op_str and ins.op_str.startswith('q'):
        left = ins.op_str.split('[')[0].strip().rstrip(',')
        parts = [p.strip() for p in left.split(',')]
        if len(parts) == 2 and all(p.startswith('q') and p[1:].isdigit() for p in parts):
            wb = ins.op_str.rstrip().endswith('!')
            return [int(parts[0][1:]), int(parts[1][1:])], True, wb
    return None

def store_off(ins):
    """destination offset for [sp,#imm] forms; None if not parseable"""
    try:
        s = ins.op_str.split('[sp', 1)[1]
        s = s.split(']', 1)[0]
        s = s.replace('!', '').replace(' ', '').strip()
        if s.startswith(',#'):
            v = s[2:].strip()
            neg = v.startswith('-')
            v = v.lstrip('+-')
            return -int(v, 0) if neg else int(v, 0)
        return 0  # [sp] no offset
    except Exception:
        return None

def vr_offs_sig(insns, k):
    for j in range(max(0, k - 24), min(len(insns), k + 8)):
        ins = insns[j]
        if ins.mnemonic in ('mov', 'movz', 'movn') and '-0x80' in ins.op_str and ins.op_str.startswith('w'):
            return True
    return False

def is_boundary(ins):
    if ins is None:
        return True
    if ins.mnemonic == 'ret':
        return True
    if ins.mnemonic in ('b', 'br', 'brk'):
        return True
    if ins.mnemonic == 'nop':
        return True
    return False

def find_prologue(insns, k):
    """nearest stack-prologue marker before k, no bl/ret between, within 96 insns.
    Returns index of prologue marker or None."""
    lo = max(0, k - 96)
    p = k - 1
    while p >= lo:
        ins = insns[p]
        if ins.mnemonic in ('ret', 'br'):
            return None
        if ins.mnemonic == 'bl':
            return None
        strong = False
        if ins.mnemonic == 'stp' and 'x29' in ins.op_str and 'x30' in ins.op_str and '[sp' in ins.op_str:
            strong = True
        if ins.mnemonic == 'sub' and ins.op_str.replace(' ', '').startswith('sp,sp,#'):
            # accept if previous insn is a boundary, or within 4 after a strong stp x29,x30
            prev = insns[p - 1] if p > 0 else None
            if is_boundary(prev):
                strong = True
            else:
                for q in range(max(0, p - 4), p):
                    iq = insns[q]
                    if iq.mnemonic == 'stp' and 'x29' in iq.op_str and 'x30' in iq.op_str and '[sp' in iq.op_str:
                        strong = True
                        break
        if ins.mnemonic == 'stp' and ('x19' in ins.op_str or 'x20' in ins.op_str) and '[sp' in ins.op_str and ins.op_str.rstrip().endswith('!') and '-0x' in ins.op_str:
            strong = True
        if strong:
            return p
        p -= 1
    return None

def loaded_recently(insns, k, regs, window=24):
    """True if any q reg in regs was loaded (ldr/ldp q) from any base in
    the preceding window instructions.  A store of just-loaded regs is a copy."""
    lo = max(0, k - window)
    for j in range(k - 1, lo - 1, -1):
        ins = insns[j]
        if ins.mnemonic == 'ldr' and ins.op_str.startswith('q'):
            left = ins.op_str.split('[')[0].strip().rstrip(',')
            if left.startswith('q') and left[1:].isdigit() and int(left[1:]) in regs:
                return True
        elif ins.mnemonic == 'ldp' and ins.op_str.startswith('q'):
            left = ins.op_str.split('[')[0].strip().rstrip(',')
            parts = [x.strip() for x in left.split(',')]
            for p in parts:
                if p.startswith('q') and p[1:].isdigit() and int(p[1:]) in regs:
                    return True
    return False

def load_off_sp(ins):
    """offset for ldr/ldp q,[sp,#imm]; None if not [sp]"""
    try:
        s = ins.op_str.split('[sp', 1)[1]
        s = s.split(']', 1)[0]
        s = s.replace('!', '').replace(' ', '').strip()
        if s.startswith(',#'):
            v = s[2:].strip()
            neg = v.startswith('-')
            v = v.lstrip('+-')
            return -int(v, 0) if neg else int(v, 0)
        return 0
    except Exception:
        return None

def save_area_reloaded(insns, start, offs):
    """True if any saved q reg is later reloaded from the SAME [sp] offsets.
    This is the printf-engine case: the function itself consumes its own FP
    varargs, so NOPing the saves would corrupt its output (v5's guard, but
    offset-aware so the interleaved va_list copy load [sp,#0x30] is ignored)."""
    lo, hi = min(offs), max(offs)
    end = min(len(insns), start + 1500)
    for j in range(start, end):
        ins = insns[j]
        if ins.mnemonic == 'ret':
            break
        if ins.mnemonic in ('ldr', 'ldp') and ins.op_str.startswith('q') and '[sp' in ins.op_str:
            off = load_off_sp(ins)
            if off is not None and lo <= off <= hi:
                return True
    return False


def patch(path, out):
    d, segs = load_elf(path)
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    md.skipdata = True
    total = 0
    patches, skipped = [], []
    for foff, vaddr, sz in segs:
        insns = list(md.disasm(d[foff:foff + sz], vaddr))
        n = len(insns)
        used = set()
        # map: prologue index -> list of (idx, ins, regs, stp, wb, off)
        groups = {}
        for k, ins in enumerate(insns):
            if ins.address in used:
                continue
            info = qregs_of(ins)
            if info is None:
                continue
            regs, stp, wb = info
            if any(r > 7 for r in regs):
                continue
            p = find_prologue(insns, k)
            if p is None:
                skipped.append((ins.address, 'no-prologue'))
                continue
            if not vr_offs_sig(insns, k):
                skipped.append((ins.address, 'no-vr-offs'))
                continue
            # no call between prologue and this store (varargs are saved at entry)
            if any(insns[j].mnemonic == 'bl' for j in range(p, k)):
                skipped.append((ins.address, 'call-before-save'))
                continue
            if loaded_recently(insns, k, regs):
                skipped.append((ins.address, 'copy-of-loaded-q'))
                continue
            off = store_off(ins)
            if off is None:
                skipped.append((ins.address, 'imm-parse'))
                continue
            groups.setdefault(p, []).append((k, ins, regs, stp, wb, off))
        for p, items in sorted(groups.items()):
            # dedupe regs; require >=4 distinct q regs and strictly ascending offsets
            seen = set()
            uniq = []
            for it in items:
                if any(r in seen for r in it[2]):
                    continue
                seen.update(it[2])
                uniq.append(it)
            uniq.sort(key=lambda x: (x[5], x[0]))
            distinct = sorted(seen)
            if len(distinct) < 4:
                continue
            offs = [it[5] for it in uniq]
            if any(offs[i] >= offs[i + 1] for i in range(len(offs) - 1)):
                # allow non-monotonic stp pairs only if different shape; skip strictly
                continue
            if not ALLOW_RELOAD and save_area_reloaded(insns, uniq[0][0], offs):
                skipped.append((insns[uniq[0][0]].address, 'save-area-reload'))
                continue
            for (k, ins, regs, stp, wb, off) in uniq:
                if ins.address in used:
                    continue
                if ONLY is not None and ins.address not in ONLY:
                    continue
                o = va2off(segs, ins.address)
                if o is None or ins.size != 4:
                    continue
                if stp and wb:
                    num = ins.op_str.split('#')[-1].rstrip('!').replace('-', '')
                    try:
                        N = int(num, 0)
                    except Exception:
                        continue
                    if N > 4095:
                        continue
                    struct.pack_into('<I', d, o, 0xD10003FF | ((N & 0xfff) << 10))
                    patches.append((ins.address, 'stp ' + ins.op_str, 'sub sp,sp,#0x%x' % N))
                else:
                    struct.pack_into('<I', d, o, NOP)
                    patches.append((ins.address, '%s %s' % (ins.mnemonic, ins.op_str), 'nop'))
                used.add(ins.address)
                total += 1
    print('patched sites: %d' % total)
    for a, old, new in patches:
        print('  0x%-6x %-42s -> %s' % (a, old, new))
    if skipped:
        print('skipped: %d' % len(skipped))
        for a, w in skipped[:30]:
            print('  0x%x %s' % (a, w))
    open(out, 'wb').write(d)
    print('written:', out)

if __name__ == '__main__':
    ALLOW_RELOAD = '--allow-reload' in sys.argv
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if '--only' in sys.argv:
        i = sys.argv.index('--only')
        ONLY = set(int(x, 16) for x in open(sys.argv[i + 1]).read().split())
        args = [a for a in args if a != sys.argv[i + 1]]
    patch(args[0], args[1] if len(args) > 1 else args[0] + '.patched')
