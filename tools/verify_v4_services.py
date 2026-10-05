#!/usr/bin/env python3
"""verify_v4_services.py -- quick service sweep on the v4.1 console."""
import serial, sys, threading, time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
PASS = sys.argv[2] if len(sys.argv) > 2 else ""
LOG = open("verify_v4_services.log", "wb")
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

def wait_for(pats, timeout=12.0):
    t0 = time.time(); i0 = len(recv)
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
        if bytes(recv[n0:])[-200:].rstrip().endswith(b"#"):
            break
    r = bytes(recv[n0:]).decode("utf-8", "replace")
    log("=== %s ===\n%s" % (name, r.strip()))
    time.sleep(0.3)

threading.Thread(target=reader, daemon=True).start()

send_line("")
hit = wait_for([b"login:", b"#"])
if hit != b"#":
    send_line("toor")
    wait_for([b"assword:"], 6)
    send_line(PASS)
    hit = wait_for([b"#"], 8)
    if hit != b"#":
        log("LOGIN FAILED")
        stop[0] = True; s.close(); sys.exit(2)

run("listeners", "netstat -tln 2>&1 | head -10", 8)
run("gui", "curl -s -m 5 -o /tmp/gui.html -w '%{http_code} %{size_download}' http://127.0.0.1:80/ ; echo; head -c 120 /tmp/gui.html", 10)
run("gw_dir", "ls /data/gw 2>&1 | head -8; ls /data/gw 2>&1 | wc -l", 8)
run("load", "cat /proc/loadavg; ps w | wc -l; cat /proc/uptime", 7)
run("wifi_state", "iwinfo ra0 info 2>&1 | head -4; iwinfo rai0 info 2>&1 | head -4", 9)
run("wan", "ifconfig ccmni2 2>&1 | head -3; ping -c 2 -W 3 223.5.5.5 2>&1 | tail -2", 12)

log("SERVICES DONE")
stop[0] = True
s.close()
