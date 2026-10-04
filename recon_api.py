import os
#!/usr/bin/env python3
"""LG6151M read-only recon against the web API (user's own device).
Only GET/POST reads + one normal-user login with the owner's credentials.
No state changes, no writes, no firmware operations.
"""
import json
import subprocess
import sys
import urllib.request
import urllib.error

BASE = "http://192.168.8.1"
IV_OLD = "707172737475767778797a7b7c7d7e7f"  # bytes 0x70..0x7f (codming / LG6121F)
IV_NEW = "6f707172737475767778797a7b7c7d7e"   # 0x6f..0x7e (xxtg / LG6851F)


def http(method, path, data=None, timeout=6):
    req = urllib.request.Request(BASE + path, data=data, method=method)
    req.add_header("X-Requested-With", "XMLHttpRequest")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:
        return None, f"ERR: {e}"


def aes_op(plaintext_or_cipher, key_hex, iv_hex, decrypt=False):
    cmd = ["openssl", "enc"]
    if decrypt:
        cmd += ["-d"]
    cmd += ["-aes-128-cbc", "-nosalt", "-K", key_hex, "-iv", iv_hex]
    if isinstance(plaintext_or_cipher, str):
        payload = bytes.fromhex(plaintext_or_cipher) if decrypt else plaintext_or_cipher.encode()
    else:
        payload = plaintext_or_cipher
    p = subprocess.run(cmd, input=payload, capture_output=True)
    if p.returncode != 0:
        return None
    return p.stdout.hex() if not decrypt else p.stdout.decode("utf-8", "replace")


def show(tag, status, body, limit=400):
    body = body.strip()
    print(f"[{tag}] HTTP {status} len={len(body)} :: {body[:limit]}")
    return body


def main():
    print("== 1) API path probe: /api vs /fh_api ==")
    sid = None
    working_prefix = None
    for prefix in ("/api", "/fh_api"):
        st, body = http("GET", f"{prefix}/tmp/FHNCAPIS?ajaxmethod=get_refresh_sessionid")
        show(f"sessionid {prefix}", st, body)
        if st == 200 and "sessionid" in body:
            try:
                sid = json.loads(body)["sessionid"]
                working_prefix = prefix
            except Exception:
                pass
    print(f"--> working prefix: {working_prefix}, sid={sid}")

    print("\n== 2) is_encrypt probe ==")
    for prefix in {working_prefix, "/api", "/fh_api"}:
        st, body = http("GET", f"{prefix}/tmp/FHNCAPIS?ajaxmethod=is_encrypt")
        show(f"is_encrypt {prefix}", st, body, 200)

    print("\n== 3) unauth node read attempts (plaintext POST variants) ==")
    nodes = [
        "InternetGatewayDevice.DeviceInfo.SoftwareVersion",
        "InternetGatewayDevice.DeviceInfo.ModelName",
        "InternetGatewayDevice.DeviceInfo.SerialNumber",
    ]
    if sid:
        for i, node in enumerate(nodes[:1]):  # probe formats with the first node only
            variants = [
                ("dataObj-wrapped", json.dumps(
                    {"dataObj": {node: ""}, "ajaxmethod": "get_value_by_xmlnode", "sessionid": sid})),
                ("flat-node-dict", json.dumps(
                    {node: "", "ajaxmethod": "get_value_by_xmlnode", "sessionid": sid})),
                ("dataObj-string", json.dumps(
                    {"dataObj": node, "ajaxmethod": "get_value_by_xmlnode", "sessionid": sid})),
                ("query-param", None),  # GET with node param
            ]
            for name, payload in variants:
                if payload is None:
                    st, body = http("GET", f"{working_prefix}/tmp/FHNCAPIS?ajaxmethod=get_value_by_xmlnode&node={urllib.parse.quote(node)}")
                else:
                    st, body = http("POST", f"{working_prefix}/tmp/FHNCAPIS?ajaxmethod=get_value_by_xmlnode", payload.encode())
                show(f"get_value {name}", st, body)

    print("\n== 4) normal-user login (owner credentials, max 2 attempts) ==")
    if sid:
        key_hex = sid[:16].encode().hex()  # codming scheme: key = first 16 ASCII bytes of sid
        login_plain = json.dumps({"dataObj": {"username": "admin", "password": os.environ.get("LG_WEB_PASS", "<admin-password>")},
                                  "ajaxmethod": "DO_WEB_LOGIN", "sessionid": sid})
        for path in (f"{working_prefix}/sign/DO_WEB_LOGIN",):
            st, body = http("POST", path, login_plain.encode())
            body = show("login plaintext", st, body)
            if body and all(c in "0123456789abcdefABCDEF" for c in body.strip()) and len(body.strip()) > 32:
                for iv, tag in ((IV_OLD, "IV-old"), (IV_NEW, "IV-new")):
                    dec = aes_op(body.strip(), key_hex, iv, decrypt=True)
                    if dec:
                        print(f"    decrypted({tag}): {dec[:300]}")
            if st != 200 or "9" in body[:200]:
                # retry encrypted (codming scheme)
                enc = aes_op(login_plain, key_hex, IV_OLD)
                if enc:
                    st2, body2 = http("POST", path, enc.encode())
                    show("login encrypted(IV-old)", st2, body2)
                    if body2 and all(c in "0123456789abcdefABCDEF" for c in body2.strip()) and len(body2.strip()) > 32:
                        dec = aes_op(body2.strip(), key_hex, IV_OLD, decrypt=True)
                        if dec:
                            print(f"    decrypted: {dec[:300]}")

    print("\n== 5) misc version paths ==")
    for p in ("/version", "/version.txt", "/fw_version", "/api/tmp/FHNCAPIS?ajaxmethod=get_device_info"):
        st, body = http("GET", p)
        show(p, st, body, 200)


if __name__ == "__main__":
    import urllib.parse  # noqa: F401 (used above)
    main()
