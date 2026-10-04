#!/usr/bin/env python3
"""Flight-20 serial intercept: capture boot from t0, login during the healthy
window (~40s), then fire sysrq-t (full task dump) into the wedge (~150s).
The sysrq echo is a shell builtin + syscall: survives fork-death (proven in
the nomaster incident). Everything lands on the serial capture.
"""
import sys, time
sys.path.insert(0, r"D:\Repo\lg6151m")
import serial
import device_local as D

BAUD = 921600
s = serial.Serial("COM6", BAUD, bytesize=8, parity="N", stopbits=1, timeout=0.2)

buf = b""
t0 = time.time()

def pump(sec):
    global buf
    global buf
    end = time.time() + sec
    while time.time() < end:
        d = s.read(4096)
        if d:
            buf += d
            sys.stdout.write(d.decode("utf-8", "replace"))
            sys.stdout.flush()

def expect(marker, sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        d = s.read(4096)
        if d:
            buf += d
            sys.stdout.write(d.decode("utf-8", "replace"))
            sys.stdout.flush()
            if marker.encode() in buf:
                return True
    return False

def paced(text, delay):
    for ch in text:
        s.write(ch.encode()); s.flush(); time.sleep(delay)
    s.write(b"\n"); s.flush()

log = open("f20_serial_full.log", "ab")

# phase 1: watch boot until the wifi-init marker (~ when sweep reaches S98)
print("=== phase1: waiting for boot (wifi init marker)")
expect("wifi_rcS_init_end", 600) or print("!! marker timeout")
pump(3)

# phase 2: login now (pre-wedge window)
print("\n=== phase2: serial login")
s.write(b"\n"); s.flush()
if expect("login:", 6):
    paced(D.TOOR_USER, 0.1)
    expect("assword", 8)
    paced(D.TOOR_PASS, 0.1)
    ok = expect("#", 10)
    print("\nlogin:", "OK" if ok else "FAILED")
else:
    print("!! no login prompt pre-wedge")

# phase 3: wait for the wedge to form, then sysrq dump
print("\n=== phase3: waiting 60s for wedge, then sysrq-t")
time.sleep(60)
paced("echo SC_MARK_ALIVE; cat /proc/uptime", 0.01)
expect("SC_MARK_ALIVE", 15)
print("\n--- shell alive check done, firing sysrq-t")
paced("echo t > /proc/sysrq-trigger", 0.01)
pump(20)
paced("echo w > /proc/sysrq-trigger", 0.01)
pump(15)
log.write(buf); log.close()
print("\n=== capture saved to f20_serial_full.log")
s.close()
