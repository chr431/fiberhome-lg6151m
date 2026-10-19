#!/usr/bin/env python3
"""oneoff: fetch an aee core from the CPE and decode the fault (arm64 ELF core).

Usage: python fetch_core.py <remote-path> <local-path> [--parse]

dropbear has no SFTP, so the file is streamed over `cat` on stdout.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import lgssh  # noqa: E402


def fetch(remote, local):
    c = lgssh.connect()
    try:
        _, out, err = c.exec_command("cat %s" % remote, timeout=120)
        data = out.read()
        e = err.read().decode("utf-8", "replace")
    finally:
        c.close()
    if e.strip():
        print("stderr:", e.strip()[:300])
    with open(local, "wb") as f:
        f.write(data)
    print("fetched %d bytes -> %s" % (len(data), local))
    return data


def parse(data):
    if data[:4] != b"\x7fELF" or data[4] != 2:
        print("not ELF64")
        return
    e_phoff, = struct.unpack_from("<Q", data, 0x20)
    e_phentsize, e_phnum = struct.unpack_from("<HH", data, 0x36)
    notes = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        p_type, = struct.unpack_from("<I", data, off)
        if p_type != 4:  # PT_NOTE
            continue
        p_offset, = struct.unpack_from("<Q", data, off + 8)
        p_filesz, = struct.unpack_from("<Q", data, off + 32)
        pos, end = p_offset, p_offset + p_filesz
        while pos + 12 <= end:
            namesz, descsz, ntype = struct.unpack_from("<III", data, pos)
            pos += 12
            name = data[pos:pos + namesz].rstrip(b"\0")
            pos += (namesz + 3) & ~3
            desc = data[pos:pos + descsz]
            pos += (descsz + 3) & ~3
            notes.append((ntype, name, desc))

    prstatus = sig = prpsinfo = None
    files = []
    for ntype, name, desc in notes:
        if ntype == 1:
            prstatus = desc
        elif ntype == 3:
            prpsinfo = desc
        elif ntype == 0x53494749:
            sig = desc
        elif ntype == 0x46494c45:
            cnt, pgsz = struct.unpack_from("<QQ", desc, 0)
            p = 16
            ents = []
            for _ in range(cnt):
                s, e, fo = struct.unpack_from("<QQQ", desc, p)
                ents.append((s, e, fo))
                p += 24
            names = desc[p:].split(b"\0")
            for i, (s, e, fo) in enumerate(ents):
                fn = names[i].decode("utf-8", "replace") if i < len(names) else "?"
                files.append((s, e, fn))

    print("notes:", [(hex(t), n.decode("latin1")) for t, n, _ in notes][:8])
    if prpsinfo:
        fname = prpsinfo[40:56].split(b"\0")[0].decode("latin1")
        print("pr_fname:", fname)
    if sig:
        si_signo, si_errno, si_code = struct.unpack_from("<iii", sig, 0)
        si_addr, = struct.unpack_from("<Q", sig, 16)
        print("siginfo: signo=%d errno=%d code=%d si_addr=0x%x" %
              (si_signo, si_errno, si_code, si_addr))
    if prstatus:
        signo, code, errno = struct.unpack_from("<iii", prstatus, 0)
        cur = struct.unpack_from("<h", prstatus, 12)[0]
        pid = struct.unpack_from("<i", prstatus, 32)[0]
        regs = struct.unpack_from("<34Q", prstatus, 112)
        sp, pc, pstate = regs[31], regs[32], regs[33]
        print("prstatus: cursig=%d pid=%d pc=0x%x sp=0x%x pstate=0x%x" %
              (cur, pid, pc, sp, pstate))
        print("  x0=0x%x x1=0x%x x29(fp)=0x%x x30(lr)=0x%x" %
              (regs[0], regs[1], regs[29], regs[30]))
        for s, e, fn in files:
            if s <= pc < e:
                print("  pc in %s [0x%x-0x%x) +0x%x" % (fn, s, e, pc - s))
                break
        else:
            print("  pc not in any NT_FILE mapping")
        for s, e, fn in files:
            if s <= sp < e:
                print("  sp in %s [0x%x-0x%x)" % (fn, s, e))
                break
        else:
            print("  sp not in any NT_FILE mapping (stack is anonymous)")
    print("mappings:")
    for s, e, fn in files[:20]:
        print("  0x%x-0x%x %s" % (s, e, fn))


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return
    data = fetch(sys.argv[1], sys.argv[2])
    if "--parse" in sys.argv:
        parse(data)


if __name__ == "__main__":
    main()
