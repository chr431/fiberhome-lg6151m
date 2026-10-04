#!/usr/bin/env python3
"""Serial re-login: extract sysrq-t dump from dmesg + udhcpc kernel stack."""
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

ok = False
for attempt in range(4):
    s.write(b"\n"); s.flush()
    if not expect("login:", 8): continue
    time.sleep(0.5)
    paced(D.TOOR_USER, 0.15)
    if not expect("assword", 10): continue
    time.sleep(0.5)
    paced(D.TOOR_PASS, 0.15)
    if expect("#", 12):
        ok = True; print(f"\n=== LOGIN OK (attempt {attempt+1})"); break
    print(f"\n--- attempt {attempt+1} failed"); pump(3)
if not ok:
    print("=== LOGIN FAILED"); sys.exit(2)

# silence console noise first, then pull data
paced("echo 0 > /proc/sysrq-trigger", 0.02); pump(4)
for cmd in [
    "U=$(pidof udhcpc | awk '{print $1}'); echo UDPID=$U; cat /proc/$U/wchan; echo; cat /proc/$U/syscall 2>/dev/null",
    "cat /proc/$U/stack 2>/dev/null | head -15",
    "dmesg | grep -A6 'udhcpc' | tail -30",
    "dmesg | grep -B1 -A8 'task:' | tail -60",
    "ps w | head -3; ps w | grep -E 'wan_poli|rc19|procd|rcS' | grep -v grep",
    "cat /tmp/wp2.out /tmp/wan_policy2.log 2>/dev/null | tail -5",
]:
    print(f"\n### CMD: {cmd}")
    paced(cmd, 0.02)
    pump(15)

pump(5)
open("f20_diag2.log", "ab").write(buf)
print("\n=== saved f20_diag2.log")
s.close()
