#!/usr/bin/env python3
"""Offline test: can the LG6851F firmware RSA key decrypt LG6151M's is_encrypt blob?"""
import base64
import json
import re
import subprocess
import tempfile
import os
import sys

sys.path.insert(0, r"D:\Repo\lg6151m")
from login_and_read import http

src = open(r"D:\Repo\lg6151m\ref\sms.sh", encoding="utf-8").read()
pem = re.search(r"-----BEGIN RSA PRIVATE KEY-----.*?-----END RSA PRIVATE KEY-----", src, re.S).group(0)
fd, pemfile = tempfile.mkstemp(suffix=".pem")
with os.fdopen(fd, "w") as f:
    f.write(pem + "\n")
print("PEM extracted:", len(pem), "chars ->", pemfile)
print("openssl pkey check:")
subprocess.run(["openssl", "pkey", "-in", pemfile, "-noout", "-text"], capture_output=False)

st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt")
blob = base64.b64decode(json.loads(body)["data"])
print(f"\nblob: {len(blob)} bytes, head hex: {blob[:8].hex()}")


def try_rsa(data, tag):
    p = subprocess.run(["openssl", "pkeyutl", "-decrypt", "-inkey", pemfile,
                        "-pkeyopt", "rsa_padding_mode:pkcs1"],
                       input=data, capture_output=True)
    if p.returncode == 0:
        print(f"[{tag}] OK -> {p.stdout!r}")
        return p.stdout
    print(f"[{tag}] fail: {p.stderr.decode('utf-8','replace').strip().splitlines()[-1]}")
    return None


try_rsa(blob, "full")
if len(blob) > 256:
    try_rsa(blob[-256:], "last256")
    try_rsa(blob[:256], "first256")
    try_rsa(blob[5:], "strip5")
