#!/usr/bin/env python3
"""common_ko.py -- ET_REL aarch64 kernel-module loader for offline disassembly scans.

Handles what kd.py (vmlinux, ET_EXEC) cannot: mtk_warp.ko & friends are ET_REL,
so every bl/b/adrp target is a relocation, not an immediate. This module resolves
.rela.<sec> entries to symbol names and annotates capstone output with them.

Usage as a library:
    from common_ko import Ko
    k = Ko('analysis/vendor/mods/5.15.134/mtk_warp.ko')
    k.dump('wifi_tx_tuple_add')          # annotated disassembly
    k.callsites('dma_map_page_attrs')    # all bl sites to a symbol
"""
import struct
import bisect
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

R_ADR_GOT_PAGE      = 311
R_ADR_PREL_PG_HI21  = 275
R_ADR_PREL_LO12     = 277
R_ADD_ABS_LO12_NC   = 277  # alias
R_LDST_ABS_LO12     = 278
R_JUMP26            = 282
R_CALL26            = 283

REL_NAMES = {275: 'adrp', 277: 'add/ld', 278: 'ldst', 282: 'b', 283: 'bl'}


class Ko:
    def __init__(self, path):
        self.path = path
        d = self.data = open(path, 'rb').read()
        assert d[:4] == b'\x7fELF' and d[4] == 2 and d[5] == 1, 'need ELF64 LE'
        assert struct.unpack_from('<H', d, 0x10)[0] == 1, 'need ET_REL'
        assert struct.unpack_from('<H', d, 0x12)[0] == 183, 'need EM_AARCH64'
        e_shoff, = struct.unpack_from('<Q', d, 0x28)
        entsz, num, strndx = struct.unpack_from('<HHH', d, 0x3a)
        secs = []
        for i in range(num):
            o = e_shoff + i * entsz
            name, typ, flags, addr, off, size, link, info, align, es = \
                struct.unpack_from('<IIQQQQIIQQ', d, o)
            secs.append(dict(i=i, name_off=name, type=typ, flags=flags,
                             off=off, size=size, link=link, info=info))
        sh = secs[strndx]
        base = sh['off']
        for s in secs:
            e = d.index(b'\0', base + s['name_off'])
            s['name'] = d[base + s['name_off']:e].decode('latin1')
        self.secs = secs
        self.text = next(s for s in secs if s['name'] == '.text')
        self.texidx = self.text['i']

        self.syms = []
        for s in secs:
            if s['type'] == 2:  # SYMTAB
                st = secs[s['link']]
                for i in range(s['size'] // 24):
                    o = s['off'] + i * 24
                    nm, info, other, shndx, val, sz = struct.unpack_from('<IBBHQQ', d, o)
                    # NB: do NOT skip nm==0 -- relocation symbol indices refer to
                    # the full table including the null entry.
                    if nm == 0:
                        self.syms.append(dict(name='', info=0, shndx=0, val=0, size=0))
                        continue
                    e = d.index(b'\0', st['off'] + nm)
                    self.syms.append(dict(name=d[st['off'] + nm:e].decode('latin1'),
                                          info=info, shndx=shndx, val=val, size=sz))
        self.funcs = sorted([s for s in self.syms
                             if (s['info'] & 0xf) == 2 and s['shndx'] == self.texidx and s['size'] > 0],
                            key=lambda s: s['val'])
        self._fvals = [f['val'] for f in self.funcs]

        # relocations against .text: section-relative offset -> (reltype, symname, addend)
        self.relocs = {}
        for s in secs:
            if s['type'] == 4 and s['info'] == self.texidx:  # RELA targeting .text
                for i in range(s['size'] // 24):
                    o = s['off'] + i * 24
                    off, info, add = struct.unpack_from('<QQq', d, o)
                    symi, rt = info >> 32, info & 0xffffffff
                    nm = self.syms[symi]['name'] if symi < len(self.syms) else '?'
                    self.relocs[off] = (rt, nm, add)
        self.md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)

    def fn_at(self, off):
        i = bisect.bisect_right(self._fvals, off) - 1
        if i < 0:
            return None
        f = self.funcs[i]
        return f if f['val'] <= off < f['val'] + f['size'] else None

    def fn_or_gap(self, off):
        f = self.fn_at(off)
        if f:
            return f['name'], f['val']
        i = bisect.bisect_right(self._fvals, off) - 1
        prev = self.funcs[i]['name'] if i >= 0 else 'start'
        return 'GAP.after.%s' % prev, (self.funcs[i]['val'] + self.funcs[i]['size'] if i >= 0 else 0)

    def dis(self, off, n):
        code = self.data[self.text['off'] + off:self.text['off'] + off + n]
        return list(self.md.disasm(code, off))

    def ann(self, ins):
        """relocation annotation for one instruction"""
        r = self.relocs.get(ins.address)
        if not r:
            return ''
        rt, nm, add = r
        if rt in (R_CALL26, R_JUMP26):
            s = nm
            if add:
                s += '%+#x' % add
            return '   ; ' + s
        if rt == R_ADR_PREL_PG_HI21:
            return '   ; %s%+#x (page)' % (nm, add)
        if rt in (277, 278):
            return '   ; %s%+#x' % (nm, add)
        return '   ; rel%d %s%+#x' % (rt, nm, add)

    def dump(self, name, n=None):
        f = next((f for f in self.funcs if f['name'] == name), None)
        if not f:
            print('no func', name)
            return
        print('==== %s @.text+0x%x size=0x%x ====' % (f['name'], f['val'], f['size']))
        for ins in self.dis(f['val'], n or f['size']):
            print('  0x%05x: %-8s %-36s%s' % (ins.address, ins.mnemonic, ins.op_str, self.ann(ins)))

    def callsites(self, target_sub):
        """all instruction offsets whose relocated bl/b target contains target_sub"""
        out = []
        for off, (rt, nm, add) in sorted(self.relocs.items()):
            if rt in (R_CALL26, R_JUMP26) and target_sub in nm:
                out.append((off, nm))
        return out


if __name__ == '__main__':
    import sys
    k = Ko(sys.argv[1] if len(sys.argv) > 1 else 'analysis/vendor/mods/5.15.134/mtk_warp.ko')
    print('funcs:', len(k.funcs), 'text size:', hex(k.text['size']), 'relocs:', len(k.relocs))
    if len(sys.argv) > 2:
        k.dump(sys.argv[2])
