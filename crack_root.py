#!/usr/bin/env python3
"""Offline crack of the LG6151M root /etc/shadow hash (SHA-512 crypt) with a
targeted FiberHome-flavoured candidate list."""
import itertools
from passlib.hash import sha512_crypt

HASH = "$6$uXvf3aBJEpS7sdq0$cBeFd5CPbb5fcokmaJOWCprk/Cr0ItcboF4gx9qogusQyqz7JyzJ/3MysiYkoVK8Q6/alWTrHFztm2zig.VTG1"
MAC6 = [m.upper() for m in [os.environ.get("LG_MAC6", "XXXXXX")] if m != "XXXXXX"] + [os.environ.get("LG_MAC6", "").lower()]
_m = os.environ.get("LG_MACFULL", "").replace(":", "")
MACFULL = list(filter(None, [os.environ.get("LG_MACFULL"), _m.lower(), _m.upper()]))

bases = [
    "F1ber@dm!n", "f1ber@dm!n", "F1ber$dm", "F1ber@dm", "f1ber$dm",
    "Fh@", "FH@", "fh@", "hg2x0", "HG2X0",
    "F1berh0me", "Fiberhome", "fiberhome", "FiberHome",
    "Fh@dm!n", "fh@dm!n", "F1berHome", "Fh$dm", "f1ber@dm",
    "dph94", os.environ.get("LG_WEB_PASS") or "admin", "root", "password", "Fh123456",
    "F1ber@dm!n2024", "F1ber@dm!n2025", "F1ber@dm!n2026",
]
macs = MAC6 + MACFULL

cands = set()
for b in bases:
    cands.add(b)
    for m in macs:
        cands.add(b + m)
        cands.add(b + m.lower())
        cands.add(b + "@" + m)

print(f"testing {len(cands)} candidates ...")
for i, c in enumerate(sorted(cands)):
    try:
        if sha512_crypt.verify(c, HASH):
            print("FOUND root password:", repr(c))
            break
    except Exception as e:
        print("err", c, e)
        break
else:
    print("not found in targeted list")
