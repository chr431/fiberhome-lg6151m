#!/usr/bin/env python3
"""LG6151M: encrypted login + read-only node queries (FiberHome fh_api scheme).
Crypto per xxtg666/FiberHome-LG6851F-SMS-Forward, adapted:
 - LG6151M is_encrypt returns {"data": b64} without "enable"; blob = 256B RSA + ~5B junk suffix.
 - RSA keypair reused from LG6851F firmware (verified by valid PKCS#1 v1.5 padding).
Login uses the owner's credentials; all node queries are reads. No writes.
"""
import base64
import json
import os
import random
import re
import subprocess
import sys
import tempfile
import urllib.request
import urllib.error
import http.cookiejar

BASE = "http://192.168.8.1"
USER = "admin"
import os
PASS = os.environ.get("LG_WEB_PASS", "<admin-password>")
IV_HEX = "6f707172737475767778797a7b7c7d7e"

_src = open(r"D:\Repo\lg6151m\ref\sms.sh", encoding="utf-8").read()
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
    """is_encrypt data = 6 random junk chars (before OR after) + b64(RSA 256B block).
    The real base64 is the 344-char substring ending at the '==' padding."""
    eq = data_b64.find("==")
    s = data_b64[max(0, eq - 342):eq + 2] if eq != -1 else data_b64[-344:]
    blob = base64.b64decode(s)
    if len(blob) != 256:
        raise RuntimeError(f"unexpected block len {len(blob)}")
    p = subprocess.run(["openssl", "pkeyutl", "-decrypt", "-inkey", _pem_file,
                        "-pkeyopt", "rsa_padding_mode:pkcs1"],
                       input=blob, capture_output=True)
    if p.returncode != 0 or len(p.stdout) < 5:
        raise RuntimeError("rsa token decrypt failed: rc=%d out=%s err=%s" % (
            p.returncode, p.stdout.hex(),
            p.stderr.decode("utf-8", "replace")[:120]))
    return p.stdout


def derive_key_hex(sid: str, token: bytes) -> str:
    """Port of the Lua derive_key_hex; Lua 1-based indexes converted."""
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
    st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt")
    token = rsa_token(json.loads(body)["data"])
    st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
    sid = json.loads(body)["sessionid"]
    return token, sid, derive_key_hex(sid, token)


def main():
    print("== 1-2) token + sessionid + key ==")
    token, sid, key_hex = get_token_sid_key()
    print(f"token: {token.hex()} ({len(token)}B)  sid={sid}\nkey={key_hex}")

    print("== 3) login ==")
    for attempt in (1, 2):
        plain = json.dumps({"dataObj": {"username": USER, "password": PASS},
                            "ajaxmethod": "DO_WEB_LOGIN", "sessionid": sid}, separators=(",", ":"))
        st, resp = http("POST", f"/fh_api/sign/DO_WEB_LOGIN?_={random.random()}",
                        encrypt_wire(plain, key_hex).encode())
        dec = decrypt_wire(resp, key_hex)
        print(f"attempt {attempt}: HTTP {st} -> {dec[:400]}")
        if '"result":9' in dec.replace(" ", "") or '"result":"9"' in dec:
            if attempt == 1:
                print("-- refresh token/sid and retry once --")
                token, sid, key_hex = get_token_sid_key()
                continue
            print("!! login failed twice (result=9) — stop")
            return 1
        print("LOGIN OK, cookies:", [(c.name, c.value[:12]) for c in jar])
        break

    print("== 4) fresh session + node reads ==")
    st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
    sid = json.loads(body)["sessionid"]
    key_hex = derive_key_hex(sid, token)

    nodes = [
        "InternetGatewayDevice.DeviceInfo.SoftwareVersion",
        "InternetGatewayDevice.DeviceInfo.ModelName",
        "InternetGatewayDevice.DeviceInfo.HardwareVersion",
        "InternetGatewayDevice.DeviceInfo.SerialNumber",
        "InternetGatewayDevice.X_FH_WebUserInfo.2.WebSuperPassword",
    ]
    for endpoint in ("/fh_api/tmp/FHAPIS", "/fh_api/tmp/FHNCAPIS"):
        print(f"-- endpoint {endpoint}")
        got = 0
        for node in nodes:
            payload = json.dumps({"dataObj": {node: ""}, "ajaxmethod": "get_value_by_xmlnode",
                                  "sessionid": sid}, separators=(",", ":"))
            st, resp = http("POST", f"{endpoint}?_={random.random()}",
                            encrypt_wire(payload, key_hex).encode())
            dec = decrypt_wire(resp, key_hex)
            print(f"  {node}: HTTP {st} :: {dec[:250]}")
            if st == 200 and dec.strip().startswith("{") and "error" not in dec[:60].lower():
                got += 1
        if got:
            break
    return 0


if __name__ == "__main__":
    sys.exit(main())
