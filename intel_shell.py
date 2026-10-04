#!/usr/bin/env python3
"""Telnet intel session: login admin, su root (attempt), run read-only commands."""
import socket
import time

HOST, PORT = "192.168.8.1", 23
USER = "admin"
PW = "hg2x0DB2A90"
SU_PW = "f1ber@dm!nDB2A90"

INTEL_CMDS = [
    "id",
    "cat /etc/openwrt_version /etc/os-release 2>&1 | head -8",
    "uname -a; cat /proc/version",
    "cat /proc/mtd",
    "cat /proc/cmdline",
    "busybox df -h 2>/dev/null || df -h",
    "cat /proc/mounts | head -20",
    "head -30 /proc/meminfo",
    "grep -c processor /proc/cpuinfo; grep -m1 model /proc/cpuinfo",
    "ls /data 2>&1 | head -15",
    "ls / 2>&1",
    "which opkg dropbear uhttpd lua 2>&1; opkg --version 2>&1",
    "ps w 2>&1 | head -25",
]


class Tel:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=6)

    def recv(self, wait=1.2, quiet=True):
        self.s.settimeout(wait)
        data = b""
        try:
            while True:
                chunk = self.s.recv(8192)
                if not chunk:
                    break
                data += chunk
        except socket.timeout:
            pass
        return data.decode("utf-8", "replace")

    def send(self, text):
        self.s.sendall(text.encode() + b"\n")


def strip_iac(t):
    out, i = [], 0
    while i < len(t):
        if t[i] == "\xff" and i + 2 < len(t):
            i += 3
        else:
            out.append(t[i])
            i += 1
    return "".join(out)


def main():
    t = Tel(HOST, PORT)
    print(strip_iac(t.recv(2.0)))
    t.send(USER)
    t.recv(0.8)
    t.send(PW)
    logged = t.recv(1.5)
    print("== admin shell ==", strip_iac(logged)[:200].replace("\r", ""))

    print("\n== try su - ==")
    t.send("su -")
    r = t.recv(1.5)
    print(strip_iac(r)[:150].replace("\r", ""))
    if "assword" in r or "密码" in r:
        t.send(SU_PW)
        r = t.recv(1.5)
        print("after su pw:", strip_iac(r)[:150].replace("\r", ""))

    t.send("id")
    r = t.recv(1.2)
    print("id now:", strip_iac(r)[:200].replace("\r", ""))

    for cmd in INTEL_CMDS:
        t.send(cmd)
        out = strip_iac(t.recv(1.8)).replace("\r", "")
        lines = [ln for ln in out.splitlines() if ln.strip()]
        print(f"\n$ {cmd}")
        for ln in lines[:14]:
            print("   " + ln)

    t.send("exit")
    time.sleep(0.3)
    t.send("exit")
    t.s.close()


if __name__ == "__main__":
    main()
