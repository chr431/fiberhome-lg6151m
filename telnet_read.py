#!/usr/bin/env python3
"""Read files from the CPE telnet sandbox via the allowed `strings` command."""
import socket
import sys
import time

HOST, PORT = "192.168.8.1", 23
USER, PW = "admin", "hg2x0DB2A90"


class Sess:
    def __init__(self):
        self.s = socket.create_connection((HOST, PORT), timeout=6)
        self.recv(2.0)
        self.send(USER)
        self.recv(0.6)
        self.send(PW)
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
        # strip first echo line and final prompt
        lines = out.splitlines()
        if lines and lines[0].strip() == cmd:
            lines = lines[1:]
        while lines and lines[-1].strip().endswith(":/$"):
            lines = lines[:-1]
        return "\n".join(lines).strip()


def main():
    s = Sess()
    try:
        for cmd in sys.argv[1:]:
            print(f"$ {cmd}")
            print(s.run(cmd, w=2.5))
            print()
    finally:
        s.send("exit")
        time.sleep(0.2)
        s.s.close()


if __name__ == "__main__":
    main()
