#!/usr/bin/env python3
"""varpro_patch.py v2 -- neutralize variadic-prologue FP saves in aarch64 ELF.

Two save-block shapes handled:
  A) 8x (or >=4) consecutive `str qN,[sp,#imm]` with ascending distinct qN
     (this device's musl shape; sink for va_start FP area)
  B) `stp qA,qB,[sp,#imm]` pairs (zig/other builds), incl pre-index writeback
     replaced by `sub sp,sp,#N` to preserve the frame.

Only save-block clusters are touched; scattered FP spills/reloads and
ldp+stp data copies are excluded.  Patched sites are NOPed.

usage: python varpro_patch.py <elf> [out]
"""
import sys, struct
import capstone

NOP = 0xD503201F

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

def qnum(ins):
    """q register number for str qN,[sp] or None"""
    l = ins.op_str.split('[')[0].strip().rstrip(',')
    if l.startswith('q') and l[1:].isdigit():
        return int(l[1:])
    return None

def is_str_qsp(ins):
    return ins.mnemonic == 'str' and '[sp' in ins.op_str and qnum(ins) is not None

def is_stp_qsp(ins):
    return ins.mnemonic == 'stp' and '[sp' in ins.op_str and ins.op_str.startswith('q')

def patch(path, out):
    d, segs = load_elf(path)
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_LITTLE_ENDIAN)
    md.skipdata = True
    total = 0
    patches, skipped = [], []
    for foff, vaddr, sz in segs:
        insns = list(md.disasm(d[foff:foff + sz], vaddr))
        idx = {i.address: k for k, i in enumerate(insns)}
        n = len(insns)
        used = set()
        # --- shape A: ascending str-q,[sp] save runs
        for k, ins in enumerate(insns):
            if ins.address in used or not is_str_qsp(ins):
                continue
            run = [(k, ins)]
            regs = [qnum(ins)]
            j = k + 1
            gap = 0
            while j < n and gap <= 1:
                nx = insns[j]
                if is_str_qsp(nx):
                    q = qnum(nx)
                    if q not in regs and q <= 7 and all(q > r for r in regs):
                        run.append((j, nx)); regs.append(q); gap = 0
                    else:
                        break
                else:
                    gap += 1
                j += 1
            if len(run) >= 4:
                # strict guards: (1) GP save-pair within preceding 16 instrs
                gp = 0
                for j in range(max(0, k - 16), k):
                    ij = insns[j]
                    if ij.mnemonic in ('stp', 'str') and '[sp' in ij.op_str and 'x' in ij.op_str.split('[')[0]:
                        gp += 1
                if gp == 0:
                    skipped.append((ins.address, 'no-gp-save'))
                    continue
                # (2) no q reload from [sp] in following 600 instrs (pure save)
                reload_found = False
                for j in range(k, min(n, k + 600)):
                    ij = insns[j]
                    if ij.mnemonic in ('ldp', 'ldr') and ij.op_str.startswith('q') and '[sp' in ij.op_str:
                        reload_found = True
                        break
                    if ij.mnemonic == 'ret' and j > k + 8:
                        break
                if reload_found:
                    skipped.append((ins.address, 'q-reload-after'))
                    continue
                for rk, rim in run:
                    off = va2off(segs, rim.address)
                    if off is None:
                        skipped.append((rim.address, 'no file off'))
                        continue
                    struct.pack_into('<I', d, off, NOP)
                    used.add(rim.address)
                    patches.append((rim.address, 'str ' + rim.op_str, 'nop'))
                    total += 1
        # --- shape B: stp q pairs (incl pre-index)
        k = 0
        while k < n:
            ins = insns[k]
            if ins.address in used or not is_stp_qsp(ins):
                k += 1
                continue
            cluster = [(k, ins)]
            j = k + 1
            gap = 0
            while j < n and gap <= 2:
                nx = insns[j]
                if is_stp_qsp(nx):
                    cluster.append((j, nx)); gap = 0
                elif is_str_qsp(nx):
                    cluster.append((j, nx)); gap = 0
                else:
                    gap += 1
                j += 1
            stps = [c for c in cluster if is_stp_qsp(c[1])]
            if len(stps) >= 2:
                prev = insns[k - 1] if k > 0 else None
                prev2 = insns[k - 2] if k > 1 else None
                if any(p is not None and p.mnemonic == 'ldp' and p.op_str.startswith('q') for p in (prev, prev2)):
                    skipped.append((ins.address, 'copy-pattern'))
                    k = cluster[-1][0] + 1
                    continue
                for ck, im in cluster:
                    off = va2off(segs, im.address)
                    if off is None or im.size != 4:
                        skipped.append((im.address, 'not patchable'))
                        continue
                    if im.mnemonic == 'str':
                        struct.pack_into('<I', d, off, NOP)
                        patches.append((im.address, 'str ' + im.op_str, 'nop')); total += 1
                        continue
                    if im.op_str.rstrip().endswith('!'):
                        num = im.op_str.split('#')[-1].rstrip('!').replace('-', '')
                        try:
                            N = int(num, 0)
                        except Exception:
                            skipped.append((im.address, 'imm parse')); continue
                        if N > 4095:
                            skipped.append((im.address, 'imm>4095')); continue
                        struct.pack_into('<I', d, off, 0xD10003FF | ((N & 0xfff) << 10))
                        patches.append((im.address, 'stp ' + im.op_str, 'sub sp,sp,#0x%x' % N)); total += 1
                    else:
                        struct.pack_into('<I', d, off, NOP)
                        patches.append((im.address, 'stp ' + im.op_str, 'nop')); total += 1
                k = cluster[-1][0] + 1
                continue
            k += 1
    print('patched sites: %d' % total)
    for a, old, new in patches:
        print('  0x%-6x %-38s -> %s' % (a, old, new))
    if skipped:
        print('skipped: %d' % len(skipped))
        for a, w in skipped[:20]:
            print('  0x%x %s' % (a, w))
    open(out, 'wb').write(d)
    print('written:', out)

if __name__ == '__main__':
    patch(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else sys.argv[1] + '.patched')
