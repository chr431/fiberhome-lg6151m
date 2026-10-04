#!/usr/bin/env python3
"""Serial login + command runner for LG6151M v3 (FH busybox login on ttyS0).

Usage: python serial_session.py <com> <cmdfile>
Strict prompt-sync: waits for the exact marker before each send.
Pacing 100ms/char for login strings, 10ms for commands (tty overrun limit).
"""
import sys, time
sys.path.insert(0, r"D:\Repo\lg6151m")
import serial
import device_local as D

BAUD = 921600

class Console:
    def __init__(self, com):
        self.s = serial.Serial(com, BAUD, bytesize=8, parity="N", stopbits=1, timeout=0.2)
    def paced(self, text, delay):
        for ch in text:
            self.s.write(ch.encode()); self.s.flush(); time.sleep(delay)
    def sendline(self, text, delay=0.1):
        self.paced(text, delay)
        self.s.write(b"\n"); self.s.flush()
    def expect(self, marker, timeout):
        t0 = time.time(); buf = b""
        while time.time() - t0 < timeout:
            d = self.s.read(4096)
            if d:
                buf += d
                sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()
                if marker.encode() in buf:
                    return True
        return False
    def close(self):
        self.s.close()

def main():
    com, cmdfile = sys.argv[1], sys.argv[2]
    c = Console(com)
    c.s.reset_input_buffer()
    c.sendline("")          # wake getty
    if not c.expect("login:", 8):
        print("\n!! no login prompt"); c.close(); sys.exit(2)
    time.sleep(1.0)
    print("\n=== username ===")
    c.sendline(D.TOOR_USER, 0.1)
    if not c.expect("assword", 10):
        print("\n!! no password prompt"); c.close(); sys.exit(3)
    time.sleep(1.0)
    print("\n=== password ===")
    c.sendline(D.TOOR_PASS, 0.1)
    got = c.expect(["#", "$"][0], 12)
    if not got:
        print("\n!! no shell prompt — login failed?"); c.close(); sys.exit(4)
    time.sleep(1.0)
    # quiet the console noise if possible (loglevel) then run commands
    for line in open(cmdfile, encoding="utf-8"):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        print(f"\n=== cmd: {line}")
        c.sendline(line, 0.01)
        c.expect("#", 20)
        time.sleep(0.3)
    c.close()

if __name__ == "__main__":
    main()
