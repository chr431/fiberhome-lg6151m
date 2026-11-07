#!/usr/bin/env python3
"""varpro_split32.py -- U-W: split 32B STP q-pair stores into 2x16B STR via per-site trampolines.

Purpose: remove the remaining 32B SIMD store transactions (the writer's transaction-shape
fingerprint) from a static aarch64 binary (bb_p11 family), WITHOUT changing semantics.

Target sites: `stp qA,qB,[xN{, #imm}]` (SIMD&FP pair store, unsigned-offset form only)
with N != 31 (sp-based sites are left alone; they belong to the FP-save-area class).

Encoding pitfall (learned the hard way): the naive mask 0xFF800000 == 0xAD000000 matches BOTH
`stp q,q` (0xAD0xxxxx, bit22=0) AND `ldp q,q` (0xAD4xxxxx, bit22=1). Patching an LDP as if it
were an STP replaces a va_list LOAD with a garbage STORE and crashes the program. The correct
mask is 0xFFC00000 == 0xAD000000 (bit22 included).

Mechanism: each site is replaced 1:1 with `b trampoline_i`; the trampoline (12B, placed in a
new appended RX region) executes
    str qA,[xN,#imm] ; str qB,[xN,#imm+16] ; b site+4
`b` clobbers nothing (x30 preserved), so leaf and non-leaf functions are both safe.

Layout: the ELF PT[0] (RX, off=0, va=0x400000) filesz/memsz is extended over the zero gap
(.eh_frame end .. RW segment start) and the file is padded with a new RX page range for the
trampoline block. No section headers are moved.

Usage: python varpro_split32.py INPUT OUTPUT
Prints a summary; verify by running the applet --help battery and the functional battery.
"""
import struct
import sys

STP_MASK = 0xFFC00000
STP_OPC = 0xAD000000
# TXT file offset -> section scan; works for statically linked bushbox layout:
# PT[0]: off 0, va 0x400000, exec sections .text/.fini inside.
SEG_VA = 0x400000


def load_elf(path):
    d = bytearray(open(path, 'rb').read())
    if d[:4] != b'\x7fELF':
        raise SystemExit('not ELF')
    e_phoff = struct.unpack_from('<Q', d, 0x20)[0]
    e_phentsize = struct.unpack_from('<H', d, 0x36)[0]
    e_phnum = struct.unpack_from('<H', d, 0x38)[0]
    e_shoff = struct.unpack_from('<Q', d, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', d, 0x3a)[0]
    e_shnum = struct.unpack_from('<H', d, 0x3c)[0]
    e_shstrndx = struct.unpack_from('<H', d, 0x3e)[0]
    secs = []
    for i in range(e_shnum):
        o = e_shoff + i * e_shentsize
        name, typ, flags = struct.unpack_from('<IIQ', d, o)
        addr, off, size = struct.unpack_from('<QQQ', d, o + 16)
        secs.append(dict(name_off=name, typ=typ, flags=flags, addr=addr, off=off, size=size))
    stro = secs[e_shstrndx]['off']
    for s in secs:
        e = d.index(b'\x00', stro + s['name_off'])
        s['name'] = d[stro + s['name_off']:e].decode()
    phdrs = []
    for i in range(e_phnum):
        o = e_phoff + i * e_phentsize
        typ, flags = struct.unpack_from('<II', d, o)
        off, va, pa, fsz, msz, algn = struct.unpack_from('<QQQQQQ', d, o + 8)
        phdrs.append(dict(idx=i, typ=typ, flags=flags, off=off, va=va, fsz=fsz, msz=msz, algn=algn))
    return d, secs, phdrs, e_phoff


def enc_str_q(rt, rn, byteoff):
    assert 0 <= byteoff < 65536 and byteoff % 16 == 0
    return 0x3D800000 | ((byteoff // 16) << 10) | (rn << 5) | rt


def enc_stur_q(rt, rn, imm9):
    assert -256 <= imm9 <= 255 and imm9 % 16 == 0
    return 0x3C800000 | ((imm9 & 0x1FF) << 12) | (rn << 5) | rt


def enc_b(src_va, dst_va):
    off = dst_va - src_va
    assert off % 4 == 0 and -0x8000000 <= off <= 0x7FFFFFF, hex(off)
    return 0x14000000 | ((off >> 2) & 0x3FFFFFF)


def decode_stp(w):
    rt = w & 31
    rt2 = (w >> 10) & 31
    rn = (w >> 5) & 31
    imm7 = (w >> 15) & 0x7F
    if imm7 >= 64:
        imm7 -= 128
    return rt, rt2, rn, imm7 * 16


def main():
    src, dst = sys.argv[1], sys.argv[2]
    d, secs, phdrs, e_phoff = load_elf(src)
    execs = [s for s in secs if s['flags'] & 4 and s['typ'] != 8]
    # candidate STP sites (true STP only: bit22 == 0)
    sites = []
    for s in execs:
        for i in range(s['size'] // 4):
            w = struct.unpack_from('<I', d, s['off'] + i * 4)[0]
            if (w & STP_MASK) != STP_OPC:
                continue
            rt, rt2, rn, imm = decode_stp(w)
            if rn == 31:
                continue  # sp-based FP-save sites: excluded by design
            va = s['addr'] + i * 4
            sites.append(dict(va=va, off=s['off'] + i * 4, rt=rt, rt2=rt2, rn=rn, imm=imm, w=w))
    # sanity: bit22==0 excludes LDP
    ldp_like = sum(1 for s in sites if (s['w'] >> 22) & 1)
    assert ldp_like == 0, 'LDP leaked into STP set'
    if not sites:
        raise SystemExit('no STP sites found')

    pt0 = phdrs[0]
    assert pt0['off'] == 0 and pt0['va'] == SEG_VA and pt0['typ'] == 1

    # Trampoline block: place it in the file gap right after the last PT_LOAD filesz,
    # page-aligned, and extend PT[0] (RX) to cover it. This keeps PT[0]'s VA range below
    # the next segment's VA (no overlapping PT_LOAD vaddr ranges).
    seg_file_end = max(p['off'] + p['fsz'] for p in phdrs if p['typ'] == 1)
    block_off = (seg_file_end + 0x1000 - 1) & ~0xFFF
    block_len = (len(sites) * 12 + 0x1000 - 1) & ~0xFFF
    new_end = block_off + block_len
    tramp_base_va = SEG_VA + block_off

    # Verify no PT_LOAD VA overlap with the extended PT[0].
    for p in phdrs:
        if p is pt0 or p['typ'] != 1 or p['msz'] == 0:
            continue
        if p['va'] < SEG_VA + new_end and p['va'] + p['msz'] > SEG_VA:
            raise SystemExit(f"PT[0] extension would overlap PT_LOAD va=0x{p['va']:x}; "
                             f"layout not supported")

    struct.pack_into('<QQ', d, e_phoff + 32, new_end, new_end)

    while len(d) < new_end:
        d.append(0)

    for k, s in enumerate(sites):
        toff = block_off + k * 12
        tva = tramp_base_va + k * 12
        if s['imm'] >= 0:
            body = [enc_str_q(s['rt'], s['rn'], s['imm']),
                    enc_str_q(s['rt2'], s['rn'], s['imm'] + 16)]
        else:
            body = [enc_stur_q(s['rt'], s['rn'], s['imm']),
                    enc_stur_q(s['rt2'], s['rn'], s['imm'] + 16)]
        body.append(enc_b(tva + 8, s['va'] + 4))  # branch back to site+4
        for j in range(3):
            struct.pack_into('<I', d, toff + j * 4, body[j])
        struct.pack_into('<I', d, s['off'], enc_b(s['va'], tva))

    open(dst, 'wb').write(bytes(d))
    print(f'sites={len(sites)} tramp_block=0x{block_off:x}+0x{block_len:x} '
          f'(va 0x{tramp_base_va:x}) new_end=0x{new_end:x}')


if __name__ == '__main__':
    main()
