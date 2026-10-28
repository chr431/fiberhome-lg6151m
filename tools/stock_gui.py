#!/usr/bin/env python3
"""stock_gui.py -- vendor-firmware web GUI client (reboot, reads).

Drives the vendor (slot B) web UI's encrypted fh_api protocol so the vendor
system can be managed when only its LAN GUI is reachable (root paths are
sealed on vendor firmware).  Scheme per the vendor web RE corpus:
  1 GET /fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt      -> RSA-256B token
  2 GET /fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid
  3 AES-128-CBC key derived from (sid, token); fixed IV
  4 POST /fh_api/sign/DO_WEB_LOGIN   {username, password}
  5 POST /fh_api/tmp/FHAPIS          ajaxmethod=do_cmd_web {key: REBOOT_WEB}
Note: a vendor-GUI reboot is a GRACEFUL reset -- the LK console thread does
NOT start on that path, so the 0x03 trap cannot catch it (see
docs/SIGSEGV_ANALYSIS.md S12).  Bootctrl flips still require a power cycle.

Credentials: WEB_USER/WEB_PASS in _local/secrets/device_local.py (imported,
never printed).  RSA private key: _local/secrets/stock_web_rsa.pem
(factory-wide key, provenance: public LG6851F research project).

usage:
  python tools/stock_gui.py reboot [base_ip]     # login + REBOOT_WEB
  python tools/stock_gui.py info  [base_ip]      # login + device info reads
"""
import base64
import http.cookiejar
import json
import os
import random
import re
import subprocess
import sys
import urllib.error
import urllib.request

IV_HEX = "6f707172737475767778797a7b7c7d7e"
PEM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                   "_local", "secrets", "stock_web_rsa.pem")

sys.path.insert(0, os.environ.get("LG_SECRETS_DIR") or os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "..", "_local", "secrets"))
try:
    import device_local as D
    USER = getattr(D, "WEB_USER", "admin")
    PASS = getattr(D, "WEB_PASS", "")
except ImportError:
    USER = os.environ.get("LG_WEB_USER", "admin")
    PASS = os.environ.get("LG_WEB_PASS", "")

jar = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
BASE = None


def log(m):
    print(m, flush=True)


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
        return None, "ERR: %s" % e


def aes(data, key_hex, decrypt):
    cmd = ["openssl", "enc"] + (["-d"] if decrypt else []) + \
          ["-aes-128-cbc", "-nosalt", "-K", key_hex, "-iv", IV_HEX]
    p = subprocess.run(cmd, input=data, capture_output=True)
    if p.returncode != 0:
        raise RuntimeError("openssl aes failed: " + p.stderr.decode("utf-8", "replace")[:200])
    return p.stdout


def rsa_token(data_b64):
    eq = data_b64.find("==")
    s = data_b64[max(0, eq - 342):eq + 2] if eq != -1 else data_b64[-344:]
    blob = base64.b64decode(s)
    if len(blob) != 256:
        raise RuntimeError("unexpected RSA block len %d" % len(blob))
    p = subprocess.run(["openssl", "pkeyutl", "-decrypt", "-inkey", PEM,
                        "-pkeyopt", "rsa_padding_mode:pkcs1"],
                       input=blob, capture_output=True)
    if p.returncode != 0 or len(p.stdout) < 5:
        raise RuntimeError("RSA token decrypt failed")
    return p.stdout


def derive_key_hex(sid, token):
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


def encrypt_wire(plain, key_hex):
    cipher_hex = aes(plain.encode(), key_hex, decrypt=False).hex()
    prefix = "".join(random.choice("0123456789abcdefghijklmnopqrstuvwxyz") for _ in range(6))
    return prefix + cipher_hex


def decrypt_wire(raw, key_hex):
    raw = raw.strip().strip('"')
    hexpart = raw[6:]
    if not hexpart or any(c not in "0123456789abcdefABCDEF" for c in hexpart):
        return raw
    try:
        return aes(bytes.fromhex(hexpart), key_hex, decrypt=True).decode("utf-8", "replace")
    except Exception:
        return raw


def api(method, dataobj, sid, key_hex, endpoint="/fh_api/tmp/FHAPIS"):
    payload = json.dumps({"dataObj": dataobj, "ajaxmethod": method,
                          "sessionid": sid}, separators=(",", ":"))
    st, resp = http("POST", "%s?_=%s" % (endpoint, random.random()),
                    encrypt_wire(payload, key_hex).encode())
    return st, decrypt_wire(resp, key_hex)


def handshake_and_login():
    st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt")
    token = rsa_token(json.loads(body)["data"])
    st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
    sid = json.loads(body)["sessionid"]
    key_hex = derive_key_hex(sid, token)
    for attempt in (1, 2):
        st, dec = api("DO_WEB_LOGIN", {"username": USER, "password": PASS},
                      sid, key_hex, endpoint="/fh_api/sign/DO_WEB_LOGIN")
        log("login attempt %d: HTTP %s -> %s" % (attempt, st, dec[:160]))
        if '"result":0' in dec.replace(" ", ""):
            st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
            sid = json.loads(body)["sessionid"]
            return token, sid, derive_key_hex(sid, token)
        st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt")
        token = rsa_token(json.loads(body)["data"])
        st, body = http("GET", "/fh_api/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
        sid = json.loads(body)["sessionid"]
    raise SystemExit("login failed (check WEB_USER/WEB_PASS in device_local)")


def main():
    global BASE
    if len(sys.argv) < 2 or sys.argv[1] not in ("reboot", "info"):
        print(__doc__)
        return 2
    BASE = "http://%s" % (sys.argv[2] if len(sys.argv) > 2 else "192.168.8.1")
    token, sid, key_hex = handshake_and_login()
    if sys.argv[1] == "reboot":
        st, dec = api("do_cmd_web", {"key": "RECORD_MESSAGE_WEB"}, sid, key_hex)
        log("record: HTTP %s :: %s" % (st, dec[:120]))
        st, dec = api("do_cmd_web", {"key": "REBOOT_WEB"}, sid, key_hex)
        log("REBOOT_WEB: HTTP %s :: %s" % (st, dec[:120]))
        return 0
    nodes = ["InternetGatewayDevice.DeviceInfo.SoftwareVersion",
             "InternetGatewayDevice.DeviceInfo.SerialNumber"]
    for node in nodes:
        st, dec = api("get_value_by_xmlnode", {node: ""}, sid, key_hex)
        log("%s: HTTP %s :: %s" % (node.split(".")[-1], st, dec[:200]))
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)
