#!/usr/bin/env python3
"""Read-only telnet probe for the CPE (own device).
Grabs the banner first; optionally tries a small candidate credential list.
No commands are executed beyond an `id` on success (read-only), then quits.
"""
import socket
import sys
import time

HOST = "192.168.8.1"
PORT = 23
MAC6 = "DB2A90"          # bridge MAC 02:03:7F:00:00:00
CANDIDATES = [
    ("admin", "hg2x0" + MAC6),          # LG6121F telnet rule (codming)
    ("root", "f1ber@dm!n" + MAC6),      # LG6121F su root rule
    ("admin", "Fh@" + MAC6),            # 恩山-tried rules (verify)
    ("admin", "F1ber$dm"),              # LG6121F superadmin pw
    ("admin", "f1ber@dm!n" + MAC6),
]


def recv_some(s, wait=1.5):
    s.settimeout(wait)
    data = b""
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
            if len(data) > 8192:
                break
    except socket.timeout:
        pass
    return data


def try_login(user, password):
    s = socket.create_connection((HOST, PORT), timeout=5)
    try:
        banner = recv_some(s, 2.0)
        # find prompt pattern
        text = banner.decode("utf-8", "replace")
        lowered = text.lower()
        if "login" in lowered or "account" in lowered or "user" in lowered:
            s.sendall(user.encode() + b"\n")
            time.sleep(0.6)
            r = recv_some(s, 1.2)
            if "pass" in r.decode("utf-8", "replace").lower() or "密码" in r.decode("utf-8", "replace"):
                s.sendall(password.encode() + b"\n")
                time.sleep(0.8)
                r2 = recv_some(s, 2.0)
                txt = r2.decode("utf-8", "replace")
                if "#" in txt or "$" in txt or ">" in txt or "busybox" in txt.lower() or "incorrect" not in txt.lower() and "fail" not in txt.lower() and txt.strip():
                    # verify with a read-only command
                    s.sendall(b"id; cat /etc/openwrt_version 2>/dev/null; cat /etc/version 2>/dev/null; uname -a\n")
                    time.sleep(1.0)
                    r3 = recv_some(s, 2.5)
                    return True, text + " || " + txt + " || " + r3.decode("utf-8", "replace")
                return False, text + " || " + txt
            return False, text + " || (no password prompt) " + r.decode("utf-8", "replace")
        return False, "banner without login prompt: " + repr(text[:200])
    finally:
        try:
            s.close()
        except Exception:
            pass


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "banner"
    if mode == "banner":
        s = socket.create_connection((HOST, PORT), timeout=5)
        try:
            print(repr(recv_some(s, 3.0)))
            s.sendall(b"\n")
            time.sleep(0.8)
            print("after-newline:", repr(recv_some(s, 2.0)))
        finally:
            s.close()
        return
    for user, pw in CANDIDATES:
        print(f"--- trying {user} / {pw[:4]}***")
        ok, log = try_login(user, pw)
        print(("SUCCESS " if ok else "fail    ") + log[:600].replace("\r", ""))
        if ok:
            break
        time.sleep(2)


if __name__ == "__main__":
    main()
