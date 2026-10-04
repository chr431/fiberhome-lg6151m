#!/usr/bin/env python3
"""Serial login with retries + full diagnostics on the wedged v3."""
import sys, time
sys.path.insert(0, r"D:\Repo\lg6151m")
import serial
import device_local as D

s = serial.Serial("COM6", 921600, bytesize=8, parity="N", stopbits=1, timeout=0.2)
buf = b""

def pump(sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        d = s.read(4096)
        if d:
            buf += d
            sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()

def expect(marker, sec):
    global buf
    end = time.time() + sec
    while time.time() < end:
        d = s.read(4096)
        if d:
            buf += d
            sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()
            if marker.encode() in buf:
                return True
    return False

def paced(text, delay=0.15):
    for ch in text:
        s.write(ch.encode()); s.flush(); time.sleep(delay)
    s.write(b"\n"); s.flush()

# --- login retry loop (slow typing; wedge eats fast input)
ok = False
for attempt in range(4):
    s.write(b"\n"); s.flush()
    if not expect("login:", 8):
        continue
    time.sleep(0.5)
    paced(D.TOOR_USER, 0.15)
    if not expect("assword", 10):
        continue
    time.sleep(0.5)
    paced(D.TOOR_PASS, 0.15)
    if expect("#", 12):
        ok = True
        print(f"\n=== LOGIN OK (attempt {attempt+1})")
        break
    print(f"\n--- attempt {attempt+1} failed, retrying")
    pump(3)

if not ok:
    print("=== ALL LOGIN ATTEMPTS FAILED")
    sys.exit(2)

# --- diagnostic battery (paced; each with generous read)
for cmd in [
    "cat /proc/uptime",
    "ps w | awk '$4==\"D\"'",
    "ip -4 addr show | grep inet",
    "lsmod | grep -cE 'hw_nat|fhdrv'",
    "cat /proc/hnat/hnat_setting 2>/dev/null | grep 15101500",
    "cat /sys/class/net/eth0/statistics/rx_packets",
    "echo RC19LOG; cat /tmp/rc19.log 2>/dev/null | tail -5",
    "echo t > /proc/sysrq-trigger",
]:
    print(f"\n### CMD: {cmd}")
    paced(cmd, 0.02)
    pump(12)

pump(20)
open("f20_diag.log", "ab").write(buf)
print("\n=== done, saved f20_diag.log")
s.close()
