#!/usr/bin/env python3
"""identify2.py -- final residue checks (READ-ONLY): user_data contents,
p26 partition purity (mount + release + v4 markers), /proc/net snapshots."""
import serial, sys, threading, time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
LOG = open("identify2.log", "wb")
s = serial.Serial(PORT, 921600, timeout=0.02)
s.reset_input_buffer()
recv = bytearray()
stop = [False]

def log(m):
    print(m, flush=True)
    LOG.write((str(m) + "\n").encode()); LOG.flush()

def reader():
    while not stop[0]:
        try:
            d = s.read(65536)
            if d:
                recv.extend(d)
                LOG.write(d); LOG.flush()
        except Exception:
            break

def paced(cmd, wait=7.0):
    for ch in "  " + cmd:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    t0 = time.time(); n0 = len(recv)
    while time.time() - t0 < wait:
        time.sleep(0.05)
        if b"~ #" in bytes(recv[n0:])[-400:]:
            break
    return bytes(recv[n0:]).decode("utf-8", "replace")

threading.Thread(target=reader, daemon=True).start()

ready = False
for i in range(12):
    n0 = len(recv)
    s.write(b"\r"); s.flush(); time.sleep(1.5)
    if b"~ #" in bytes(recv[n0:]):
        ready = True; break
log("attached=%s" % ready)
if not ready:
    log("CONSOLE DEAF: %r" % bytes(recv)[-300:])
    stop[0] = True; s.close(); sys.exit(1)

CMDS = [
    ("uptime",   "cat /proc/uptime; cat /proc/version", 6),
    ("ud_top",   "ls -la /tmp/mnt_data", 8),
    ("ud_all",   "ls -laR /tmp/mnt_data 2>&1 | head -70", 12),
    ("p26magic", "hexdump -C -n 16 /tmp/d26", 5),
    ("p26mnt",   "mount -t squashfs /tmp/d26 /tmp/mnt_chk", 6),
    ("p26rel",   "cat /tmp/mnt_chk/etc/release", 6),
    ("p26v4",    "grep -c v3: /tmp/mnt_chk/etc/init.d/rcS; grep -c ^toor: /tmp/mnt_chk/etc/passwd; ls /tmp/mnt_chk/etc/rc.d/S98zz_data_hook", 8),
    ("p26umnt",  "umount /tmp/mnt_chk", 5),
    ("netarp",   "cat /proc/net/arp", 6),
    ("nettcp",   "head -6 /proc/net/tcp /proc/net/udp 2>&1", 6),
    ("dev_route","cat /proc/net/route", 6),
]
for name, cmd, w in CMDS:
    r = paced(cmd, w)
    log("=== %s ===\n%s" % (name, r.strip()))
    time.sleep(0.3)

log("IDENTIFY2 DONE")
stop[0] = True
s.close()
