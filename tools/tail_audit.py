#!/usr/bin/env python3
"""tail_audit.py -- report ELF objects that occupy the last 64 bytes of a 4 KiB page.

The external writer lands 8/16 B at page offset 0xfc0 (docs/SIGSEGV_ANALYSIS.md 11.2).
Any object whose bytes intersect [0xfc0, 0x1000) of its page can be corrupted by it.
Objects placed with __attribute__((aligned(4096))) and smaller than 4032 bytes are
immune (see gw/src/tailsafe.h).

usage: tail_audit.py <elf> [--top N]
"""
import struct
import sys

TAIL_START = 0xFC0
PAGE = 0x1000


def parse(path):
    d = open(path, 'rb').read()
    if d[:4] != b'\x7fELF' or d[4] != 2 or d[5] != 1:
        raise SystemExit('not a little-endian ELF64: ' + path)
    e_shoff = struct.unpack_from('<Q', d, 0x28)[0]
    e_shentsize = struct.unpack_from('<H', d, 0x3a)[0]
    e_shnum = struct.unpack_from('<H', d, 0x3c)[0]
    e_shstrndx = struct.unpack_from('<H', d, 0x3e)[0]

    def sh(i):
        o = e_shoff + i * e_shentsize
        name, typ, flags, addr, off, size, link, info, align, entsize = \
            struct.unpack_from('<IIQQQQIIQQ', d, o)
        return dict(name=name, typ=typ, addr=addr, off=off, size=size,
                    link=link, entsize=entsize)

    shstr = sh(e_shstrndx)
    names = d[shstr['off']:shstr['off'] + shstr['size']]

    def sname(off):
        return names[off:names.index(b'\0', off)].decode('utf-8', 'replace')

    secs = [sh(i) for i in range(e_shnum)]
    out = []
    for sec in secs:
        if sname(sec['name']) != '.symtab':
            continue
        strtab = secs[sec['link']]
        strs = d[strtab['off']:strtab['off'] + strtab['size']]
        n = sec['size'] // 24
        for i in range(n):
            nameoff, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', d, sec['off'] + i * 24)
            typ = info & 0xf
            if typ != 1 or size == 0 or shndx == 0:      # STT_OBJECT, defined, sized
                continue
            if shndx >= 0xff00:                          # ABS/COMMON
                continue
            nm = strs[nameoff:strs.index(b'\0', nameoff)].decode('utf-8', 'replace')
            out.append((nm, value, size))
    return out


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    top = 20
    if '--top' in sys.argv:
        top = int(sys.argv[sys.argv.index('--top') + 1])
    objs = parse(path)
    hit = []
    for nm, va, size in objs:
        off = va & (PAGE - 1)
        end = off + size
        if end > TAIL_START:                # intersects the tail window
            hit.append((nm, va, size, off, min(end, PAGE) - max(off, TAIL_START)))
    total = sum(h[2] for h in hit)
    print('%s: %d objects, %d intersect page tail (%.1f%% of object bytes)'
          % (path, len(objs), len(hit), 100.0 * total / max(1, sum(o[2] for o in objs))))
    hit.sort(key=lambda x: -x[2])
    for nm, va, size, off, overlap in hit[:top]:
        print('  %-40s va=0x%08x size=%-6d pageoff=0x%03x overlap=%d'
              % (nm[:40], va, size, off, overlap))


if __name__ == '__main__':
    main()
