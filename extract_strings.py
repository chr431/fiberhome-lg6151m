#!/usr/bin/env python3
"""Extract hex-escaped string literals from the obfuscated web UI bundle."""
import re

src = open(r"D:\Repo\lg6151m\polyfill.min.js", encoding="utf-8", errors="replace").read()

pat = re.compile(r"'((?:\\x[0-9a-fA-F]{2}|\\.|[^'\\])+?)'")
strings = set()
for m in pat.finditer(src):
    s = m.group(1)
    if "\\x" in s:
        try:
            dec = bytes(int(c, 16) for c in re.findall(r"\\x([0-9a-fA-F]{2})", s)).decode("latin1")
            if all(32 <= ord(c) < 127 for c in dec):
                strings.add(dec)
        except Exception:
            pass

keys = ["sessionid", "superadmin", "xmlnode", "telnet", "adb", "version", "password",
        "login", "encrypt", "software", "device_info", "at_cmd", "at_command", "upgrade",
        "sim", "ajaxmethod", "fh_api", "fhncapis", "fhapis", "web_", "get_", "set_"]
interesting = sorted(s for s in strings if any(k in s.lower() for k in keys))
for s in interesting:
    print(repr(s))
print("---")
print("total decoded strings:", len(strings))
with open(r"D:\Repo\lg6151m\bundle_strings.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(sorted(strings)))
