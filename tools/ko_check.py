#!/usr/bin/env python3
"""Sanity-check a kernel .ko: modinfo strings, allocated-section reloc types."""
import struct, sys

f = sys.argv[1] if len(sys.argv) > 1 else 'v3_fix.ko'
d = open(f, 'rb').read()
e_shoff, = struct.unpack_from('<Q', d, 0x28)
entsz, shnum, shstrndx = struct.unpack_from('<HHH', d, 0x3a)
hdrs = []
for i in range(shnum):
    hdrs.append(struct.unpack_from('<IIQQQQIIQQ', d, e_shoff + i * entsz))
so = hdrs[shstrndx][4]

def sname(h):
    e = d.index(b'\x00', so + h[0])
    return d[so + h[0]:e].decode()

names = {i: sname(h) for i, h in enumerate(hdrs)}
NAMES = {282: 'ADR_GOT_PAGE?', 283: 'ADR_PREL_PG_HI21', 275: 'LDST*', 277: 'ADR_PREL_LO21',
         285: 'ADR_PG_HI21_NC?', 286: 'ADD_ABS_LO12_NC', 257: 'ABS64', 261: 'PREL32',
         311: 'GOT_PAGE(bad)', 312: 'GOT12(bad)', 1024: 'JUMP26', 1025: 'CALL26'}

for i, h in enumerate(hdrs):
    if h[1] != 4:  # SHT_RELA only
        continue
    ti = h[7]
    if not (0 <= ti < shnum):
        continue
    if not (hdrs[ti][2] & 0x2):  # SHF_ALLOC only
        continue
    cnt = {}
    for o in range(h[4], h[4] + h[5], 24):
        t = struct.unpack_from('<QQ', d, o)[1] & 0xffffffff
        cnt[t] = cnt.get(t, 0) + 1
    pretty = {NAMES.get(k, str(k)): v for k, v in cnt.items()}
    print(f'{names[ti]}: {pretty}')

for i, h in enumerate(hdrs):
    if names[i] == '.modinfo':
        for s in d[h[4]:h[4] + h[5]].split(b'\x00'):
            if s:
                print('  modinfo:', s.decode())
