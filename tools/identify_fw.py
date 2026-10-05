#!/usr/bin/env python3
"""identify_fw.py -- READ-ONLY forensic interrogation of current device state.
No state change on the device: only cat/ls/df/grep/dd-read/hexdump-read.
Every command is sent with a leading-space guard (first-char eating seen in
kick/flash_v3 logs) and waits for a fresh '~ #' prompt."""
import serial, sys, threading, time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
LOG = open("identify_fw.log", "wb")
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
    # leading spaces survive first-char eating; harmless to sh
    c = "  " + cmd
    for ch in c:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    t0 = time.time(); n0 = len(recv)
    while time.time() - t0 < wait:
        time.sleep(0.05)
        if b"~ #" in bytes(recv[n0:])[-400:]:
            break
    return bytes(recv[n0:]).decode("utf-8", "replace")

threading.Thread(target=reader, daemon=True).start()

# --- attach ---
ready = False
for i in range(12):
    n0 = len(recv)
    s.write(b"\r"); s.flush(); time.sleep(1.5)
    if b"~ #" in bytes(recv[n0:]):
        ready = True; break
log("attached=%s" % ready)
if not ready:
    log("CONSOLE DEAF -- no prompt after 12 CRs; raw dump of anything heard:")
    log(repr(bytes(recv)[-500:]))
    stop[0] = True; s.close(); sys.exit(1)

# stale-drain: whatever the tty had pending executes here (evidence!)
time.sleep(0.5)
n0 = len(recv)
s.write(b"\r"); s.flush(); time.sleep(2.0)
log("DRAIN: %r" % bytes(recv[n0:]))

CMDS = [
    ("pid1",      "  strings /proc/1/cmdline; id", 6),
    ("release",   "  cat /etc/release", 6),
    ("cmdline",   "  cat /proc/cmdline", 6),
    ("v4marks",   "  grep -c v3: /etc/init.d/rcS; grep -c ^toor: /etc/passwd; ls /etc/rc.d/S98zz_data_hook", 8),
    ("df",        "  df", 8),
    ("tmp",       "  ls -l /tmp", 10),
    ("deploylog", "  cat /tmp/deploy.log", 8),
    ("mounts",    "  cat /proc/mounts", 8),
    ("bootctrl",  "  hexdump -C -s 2060 -n 16 /tmp/d1", 6),
    ("free",      "  free", 6),
]
for name, cmd, w in CMDS:
    r = paced(cmd, w)
    log("=== %s ===\n%s" % (name, r.strip()))
    time.sleep(0.3)

log("IDENTIFY DONE")
stop[0] = True
s.close()
