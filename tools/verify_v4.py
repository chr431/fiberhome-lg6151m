#!/usr/bin/env python3
"""verify_v4.py -- login to v4.1 console (toor) and run the full
post-flash verification battery (read-only)."""
import serial, sys, threading, time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
PASS = sys.argv[2] if len(sys.argv) > 2 else ""
LOG = open("verify_v4.log", "wb")
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

def wait_for(pats, timeout=15.0, from_idx=None):
    t0 = time.time(); i0 = from_idx if from_idx is not None else len(recv)
    while time.time() - t0 < timeout:
        tail = bytes(recv[i0:])[-600:]
        for p in pats:
            if p in tail:
                return p
        time.sleep(0.1)
    return None

def send_line(line, sec_per=0.006):
    for ch in line:
        s.write(ch.encode()); s.flush(); time.sleep(sec_per)
    s.write(b"\r"); s.flush()

def run(name, cmd, w=8.0):
    n0 = len(recv)
    send_line("  " + cmd)
    t0 = time.time()
    while time.time() - t0 < w:
        time.sleep(0.1)
        tail = bytes(recv[n0:])[-200:]
        if tail.rstrip().endswith(b"#") or tail.rstrip().endswith(b"$"):
            break
    r = bytes(recv[n0:]).decode("utf-8", "replace")
    log("=== %s ===\n%s" % (name, r.strip()))
    time.sleep(0.3)
    return r

threading.Thread(target=reader, daemon=True).start()

# --- get to a login prompt (console may sit at shell/password/prompt junk) ---
send_line("")                      # wake
hit = wait_for([b"login:", b"assword:", b"#"], 8)
for attempt in range(3):
    if hit == b"login:":
        break
    if hit == b"assword:":         # stale password prompt from earlier junk
        send_line(PASS)
        hit = wait_for([b"login:", b"#"], 6)
    elif hit == b"#":              # already in a shell
        break
    else:
        send_line("")
        hit = wait_for([b"login:", b"assword:", b"#"], 8)
log("console state: %r" % hit)

if hit != b"#":
    send_line("toor")
    hit2 = wait_for([b"assword:"], 6)
    log("username sent, got %r" % hit2)
    send_line(PASS)
    hit3 = wait_for([b"#", b"ncorrect", b"login:"], 8)
    log("after password: %r" % hit3)
    if hit3 != b"#":
        log("LOGIN FAILED -- stopping (no further commands).")
        stop[0] = True; s.close(); sys.exit(2)

CMDS = [
    ("identity", "id; uptime; cat /proc/cmdline", 8),
    ("release",  "cat /etc/release; grep -c 'v3:' /etc/init.d/rcS", 7),
    ("hooks",    "ls /etc/rc.d/S98zz_data_hook /etc/rc.d/S99zmtk_boot_done 2>&1; ls /tmp/rcS.done /tmp/boot.done 2>&1", 7),
    ("data",     "ls /data 2>&1 | head -12", 7),
    ("net",      "ifconfig -a 2>&1 | grep -A1 -E '^(br-lan|eth[0-9]|lan|wan)' | head -20", 9),
    ("procs",    "ps w 2>&1 | grep -E 'dropbear|access|extend|dnsmasq|hostapd' | grep -v grep | head -8", 8),
    ("lan_ip",   "uci get network.lan.ipaddr 2>&1; ip -4 addr 2>&1 | grep inet | head -6", 8),
]
for name, cmd, w in CMDS:
    run(name, cmd, w)

log("VERIFY-V4 DONE")
stop[0] = True
s.close()
