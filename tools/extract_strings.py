#!/usr/bin/env python3
"""Extract the hex-escaped string table from the obfuscated web UI bundle
(polyfill.min.js). Reveals endpoints/method names the minified UI uses.
Usage: python extract_strings.py [polyfill.min.js] > strings.txt"""
import re
import sys

src = open(sys.argv[1] if len(sys.argv) > 1 else "polyfill.min.js",
           encoding="utf-8", errors="replace").read()
strings = set()
for m in re.finditer(r"'((?:\\x[0-9a-fA-F]{2}|\\.|[^'\\])+?)'", src):
    s = m.group(1)
    if "\\x" in s:
        try:
            dec = bytes(int(c, 16) for c in re.findall(r"\\x([0-9a-fA-F]{2})", s)).decode("latin1")
            if all(32 <= ord(c) < 127 for c in dec):
                strings.add(dec)
        except Exception:
            pass
print("\n".join(sorted(strings)))
