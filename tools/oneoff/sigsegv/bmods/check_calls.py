#!/usr/bin/env python3
"""check_calls.py -- static call-graph self-check for the bmods .ko files.

Host has no aarch64-capable objdump (msys BFD is pe-x86-64 only; the musl
cross objdump is a Linux binary), so this script provides the equivalent
evidence directly from the ELF relocatable:

  1. SHT_SYMTAB -> function symbols (offset+size) in executable sections
  2. SHT_RELA   -> all R_AARCH64_CALL26/JUMP26 edges (external kernel calls)
  3. bl decoder -> all intra-section calls (module-internal edges)
  4. closure    -> external calls reachable from given root functions

Usage: python check_calls.py <file.ko> [root_func ...]
Without roots, prints the full per-function edge table (audit view).
"""
import struct
import sys

SHT_SYMTAB = 2
SHT_RELA = 4
REL_CALL26 = 283   # R_AARCH64_CALL26
REL_JUMP26 = 282   # R_AARCH64_JUMP26


def parse(path):
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        sys.exit("not a little-endian ELF64: %s" % path)
    e_shoff, = struct.unpack_from("<Q", data, 0x28)
    e_shentsize, e_shnum, e_shstrndx = struct.unpack_from("<HHH", data, 0x3A)
    sh = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        (name, stype, flags, addr, offset, size,
         link, info, align, entsize) = struct.unpack_from("<IIQQQQIIQQ", data, off)
        sh.append(dict(name=name, type=stype, flags=flags, addr=addr,
                       offset=offset, size=size, link=link, info=info,
                       entsize=entsize))
    shstr = sh[e_shstrndx]

    def secname(s):
        o = shstr["offset"] + s["name"]
        return data[o:data.index(b"\0", o)].decode()

    for s in sh:
        s["sname"] = secname(s)

    symtab = next(s for s in sh if s["type"] == SHT_SYMTAB)
    strtab = sh[symtab["link"]]
    syms = []
    for i in range(symtab["size"] // 24):
        off = symtab["offset"] + i * 24
        nm, info, other, shndx, val, size = struct.unpack_from("<IBBHQQ", data, off)
        o = strtab["offset"] + nm
        name = data[o:data.index(b"\0", o)].decode()
        syms.append(dict(name=name, info=info, shndx=shndx, val=val, size=size))
    return data, sh, syms


def check(path, roots):
    data, sh, syms = parse(path)

    funcs = []      # (secname, start, end, name)
    for s in syms:
        if s["info"] & 0xF != 2:            # STT_FUNC
            continue
        sec = sh[s["shndx"]]
        if not (sec["flags"] & 0x4):        # SHF_EXECINSTR
            continue
        funcs.append((sec["sname"], s["val"], s["val"] + s["size"], s["name"]))
    funcs.sort(key=lambda t: (t[0], t[1]))

    def owner(secname, off):
        for sn, a, b, nm in funcs:
            if sn == secname and a <= off < b:
                return nm
        return "<%s+0x%x?>" % (secname, off)

    # external call/jump edges + reloc presence map
    ext_edges = {}   # func -> set(kernel symbol)
    int_edges = {}   # func -> set(internal func or <unresolved>)  (filled below)
    reloc_at = {}    # (secname, offset) -> True for CALL/JUMP26
    for s in sh:
        if s["type"] != SHT_RELA:
            continue
        secname = sh[s["info"]]["sname"]      # sh_info = target section
        for i in range(s["size"] // 24):
            r_off, r_info, r_add = struct.unpack_from("<QQq", data, s["offset"] + i * 24)
            rtype = r_info & 0xFFFFFFFF
            if rtype not in (REL_CALL26, REL_JUMP26):
                continue
            sym = syms[r_info >> 32]
            fn = owner(secname, r_off)
            reloc_at[(secname, r_off)] = True
            if sym["info"] & 0xF == 3:        # STT_SECTION: internal, addend
                tgt = owner(sh[sym["shndx"]]["sname"], r_add)
                int_edges.setdefault(fn, set()).add(tgt)
            else:
                ext_edges.setdefault(fn, set()).add(sym["name"])

    # decode BL in every executable section: internal edges + sanity check
    for s in sh:
        if not (s["flags"] & 0x4):
            continue
        code = data[s["offset"]:s["offset"] + s["size"]]
        for o in range(0, len(code) - 3, 4):
            insn, = struct.unpack_from("<I", code, o)
            if (insn >> 26) != 0b100101:     # BL
                continue
            imm = insn & 0x3FFFFFF
            if imm & 0x2000000:
                imm -= 0x4000000
            tgt = o + imm * 4
            fn = owner(s["sname"], o)
            if reloc_at.get((s["sname"], o)):
                continue                       # external, recorded above
            hit = None
            for f_ in funcs:
                if f_[0] == s["sname"] and f_[1] <= tgt < f_[2]:
                    hit = f_[3]
                    break
            int_edges.setdefault(fn, set()).add(
                hit if hit else "<unresolved:%s+0x%x>" % (s["sname"], tgt))

    if not roots:
        names = sorted(set(list(ext_edges) + list(int_edges)))
        print("== %s: per-function edges ==" % path)
        for n in names:
            for x in sorted(ext_edges.get(n, ())):
                print("  %-24s -> EXT %-32s (kernel)" % (n, x))
            for x in sorted(int_edges.get(n, ())):
                print("  %-24s -> INT %s" % (n, x))
        return

    seen, stack, ext_hit = set(), list(roots), set()
    while stack:
        f = stack.pop()
        if f in seen:
            continue
        seen.add(f)
        for x in ext_edges.get(f, ()):
            ext_hit.add((f, x))
        for x in int_edges.get(f, ()):
            if x not in seen and not x.startswith("<unresolved"):
                stack.append(x)
    print("== %s: closure from %s ==" % (path, ",".join(roots)))
    print("  internal functions reached: %s" % " ".join(sorted(seen)))
    for f, x in sorted(ext_hit, key=lambda t: (t[1], t[0])):
        print("  EXT CALL %-32s (from %s)" % (x, f))
    if not ext_hit:
        print("  (no external calls reachable)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    check(sys.argv[1], sys.argv[2:])
