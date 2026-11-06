#!/usr/bin/env python3
"""varpro_rebase_vr.py -- P13: rebase the FP half of every musl/AAPCS va_list
build by +16 bytes (vr_top += 16, vr_offs -= 16).

Semantics: va_arg reads at vr_top + vr_offs, and increments vr_offs by 16.
Adding 16 to vr_top and subtracting 16 from vr_offs preserves every effective
argument address, so the va_list still works; only the two words stored in the
va_list differ from the ABI-canonical (-0x80 / top-of-FP-save-area) values.
Purpose: test whether the external 32B writer's live-content validation keys
on the canonical va_list words (if so, rebased va_lists are not attacked).

Site pattern (the compiler's va_start expansion):
    add  xM, sp, #K          ; vr_top
    str  xM, [sp, #O]        ; va_list word2
    mov  wN, #-0x38          ; gr_offs
    str  wN, [sp, #O+8]
    mov  wN, #-0x80          ; vr_offs
    str  wN, [sp, #O+12]     ; va_list word4
Patch: K += 16 (ADD imm12), movn imm16 += 0x10 (so -0x80 -> -0x90).

Only the unambiguous 4-instruction core is matched; anything else is left
untouched.  Both instruction encodings are verified, never guessed.
"""
import sys, struct
from capstone import *
from capstone.arm64 import *

ADD_X_SP = 0x91000000
ADD_MASK = 0xFFC00000
STR_W    = 0xB9000000
STR_X    = 0xF9000000
STR_MASK = 0xFFC00000
MOVN_W   = 0x12800000
MOVN_MASK= 0xFF800000

def load_elf(path):
    d = bytearray(open(path,'rb').read())
    assert d[:4] == b'\x7fELF' and d[4] == 2, 'ELF64 only'
    e_shoff = struct.unpack_from('<Q', d, 0x28)[0]
    e_shes  = struct.unpack_from('<H', d, 0x3a)[0]
    e_shnum = struct.unpack_from('<H', d, 0x3c)[0]
    e_shstr = struct.unpack_from('<H', d, 0x3e)[0]
    shstr   = struct.unpack_from('<Q', d, e_shoff + e_shstr*e_shes + 0x18)[0]
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i*e_shes
        nm, typ, flags, addr, off, size = struct.unpack_from('<IIQQQQ', d, o)
        name = bytes(d[shstr+nm:d.index(b'\0', shstr+nm)]).decode()
        if flags & 4 and size:
            secs.append((name, addr, off, size))
    return d, secs

def main():
    if len(sys.argv) < 3:
        print('usage: varpro_rebase_vr.py in.elf out.elf [--dry]')
        return 2
    path, out = sys.argv[1], sys.argv[2]
    dry = '--dry' in sys.argv
    d, secs = load_elf(path)
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    sites = []
    for name, addr, off, size in secs:
        insns = list(md.disasm(d[off:off+size], addr))
        for i, ins in enumerate(insns):
            w = struct.unpack_from('<I', d, off + (ins.address - addr))[0]
            if (w & MOVN_MASK) != MOVN_W or ((w >> 21) & 3) != 0:
                continue
            imm16 = (w >> 5) & 0xFFFF
            if imm16 != 0x7F:               # -0x80
                continue
            rd = w & 0x1F
            # next <=5 insns: str w(rd), [sp, #off4]
            hit = None
            for j in range(i+1, min(i+6, len(insns))):
                w2 = struct.unpack_from('<I', d, off + (insns[j].address - addr))[0]
                if (w2 & STR_MASK) == STR_W:
                    rn = (w2 >> 5) & 0x1F; rt = w2 & 0x1F; imm12 = (w2 >> 10) & 0xFFF
                    if rn == 31 and rt == rd:
                        hit = (j, imm12 * 4, w2)   # 32-bit store scale
                        break
                if insns[j].mnemonic in ('mov','movn','movz','str','stp','ldr','ldp','add','sub','bl'):
                    break
            if hit is None:
                continue
            j, off4, w2 = hit
            # back <=10: str xM, [sp, #off4-12]; before it add xM, sp, #K
            found = None
            for k in range(i-1, max(i-11, -1), -1):
                w3 = struct.unpack_from('<I', d, off + (insns[k].address - addr))[0]
                if (w3 & STR_MASK) == STR_X:
                    rn = (w3 >> 5) & 0x1F; rt = w3 & 0x1F; imm12 = (w3 >> 10) & 0xFFF
                    if rn == 31 and imm12 * 8 == off4 - 12 and rt < 31:
                        for l in range(k-1, max(k-5, -1), -1):
                            w4 = struct.unpack_from('<I', d, off + (insns[l].address - addr))[0]
                            if (w4 & ADD_MASK) == ADD_X_SP:
                                rn2 = (w4 >> 5) & 0x1F; rd2 = w4 & 0x1F; imm12b = (w4 >> 10) & 0xFFF
                                if rn2 == 31 and rd2 == rt:
                                    found = (l, w4, imm12b, k)
                                    break
                        break
                if insns[k].mnemonic in ('ret','bl'):
                    break
            if found is None:
                continue
            l, w4, K, k = found
            if K + 16 > 0xFFF:
                continue
            sites.append((insns[l].address, insns[i].address, K, w4, w))
    # ---- clang idiom: packed offsets ----
    #   mov  xOFF, #-0x28|0x30|0x38    ; gr_offs (depends on named args)
    #   movk xOFF, #0xff80, lsl #32    ; vr_offs = -0x80 in high half
    #   add  xVR, xBASE, #0x80         ; vr_top = fp-save-area top
    #   stp/str xVR, ... [sp, ...]     ; word2 = vr_top, word3/4 = xOFF
    # Patch: add #0x80 -> #0x90, movk 0xff80 -> 0xff70.
    import re as _re
    cnt0 = len(sites)
    for name, addr, off, size in secs:
        insns = list(md.disasm(d[off:off+size], addr))
        n = len(insns)
        for i, ins in enumerate(insns):
            m = _re.match(r'x(\d+), #0xff80, lsl #32$', ins.op_str)
            if ins.mnemonic != 'movk' or not m:
                continue
            offreg = 'x' + m.group(1)
            ok_mov = False
            for k in range(i-1, max(i-7, -1), -1):
                kn = insns[k]
                if kn.mnemonic == 'mov' and _re.match(_re.escape(offreg) + r', #-0x[0-9a-f]+$', kn.op_str):
                    ok_mov = True
                    break
            if not ok_mov:
                continue
            # nearest add xVR, xBASE, #0x80 with xBASE == sp or a copy of sp
            cand = None
            for j in list(range(i+1, min(i+13, n))) + list(range(i-1, max(i-13, -1), -1)):
                jn = insns[j]
                mm = _re.match(r'(x\d+), (x\d+|sp), #(0x[0-9a-f]+|-?\d+)$', jn.op_str)
                if jn.mnemonic != 'add' or not mm:
                    continue
                if int(mm.group(3), 0) != 0x80:
                    continue
                vr, base = mm.group(1), mm.group(2)
                if base == 'sp':
                    cand = (j, vr, base)
                    break
                for l in range(j-1, max(j-7, -1), -1):
                    ln = insns[l]
                    if ln.mnemonic == 'mov' and ln.op_str == base + ', sp':
                        cand = (j, vr, base)
                        break
                if cand:
                    break
            if cand is None:
                continue
            j, vr, base = cand
            # require xVR to be stored to [sp] near the movk (word2 materialization)
            ok_store = False
            for k in range(i-3, min(i+10, n)):
                kn = insns[k]
                if kn.mnemonic in ('str','stp') and kn.op_str.startswith(vr + ',') and '[sp' in kn.op_str:
                    ok_store = True
                    break
            if not ok_store:
                continue
            w4 = struct.unpack_from('<I', d, off + (insns[j].address - addr))[0]
            w  = struct.unpack_from('<I', d, off + (insns[i].address - addr))[0]
            sites.append((insns[j].address, insns[i].address, 0x80, w4, w))
    print('clang-idiom sites: %d' % (len(sites) - cnt0))
    # apply
    for add_va, mov_va, K, w4, w in sites:
        w4n = w4 + (16 << 10)
        if (w & 0xFFE00000) == 0xF2C00000:     # clang: MOVK packs high half of -0x80
            wn = (w & ~(0xFFFF << 5)) | ((((w >> 5) & 0xFFFF) - 0x10) << 5)
        else:                                   # gcc: MOVN ~imm16
            wn = w + (0x10 << 5)
        o4 = None; o5 = None
        for name, addr, off, size in secs:
            if addr <= add_va < addr+size:
                o4 = off + (add_va - addr)
            if addr <= mov_va < addr+size:
                o5 = off + (mov_va - addr)
        if dry:
            print('  add@%08x K=0x%x mov@%08x' % (add_va, K, mov_va))
            continue
        struct.pack_into('<I', d, o4, w4n)
        struct.pack_into('<I', d, o5, wn)
    print('candidate sites: %d' % len(sites))
    for add_va, mov_va, K, w4, w in sites:
        print('  add@%08x K=0x%x -> 0x%x   mov@%08x -0x80 -> -0x90' % (add_va, K, K+16, mov_va))
    if not dry:
        open(out,'wb').write(d)
        print('written:', out)
    return 0

if __name__ == '__main__':
    sys.exit(main())
