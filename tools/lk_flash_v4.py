#!/usr/bin/env python3
"""lk_flash_v4.py -- final flasher built on B3-proven facts:
curl works / '&' works (post /dev/null) / never hold serial with long
foreground commands. Device self-drives via deploy2.sh; PC only kicks it,
polls /tmp/deploy.log, then watches the reboot and v4 LAN arrival."""
import hashlib, re, serial, subprocess, sys, threading, time, urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
DEPOT = "http://127.0.0.1:8931"
D2 = r"D:\Repo\lg6151m-project\lg6151m\_drill_backup\deploy2.sh"
PC_IP = "169.254.162.221"
LOG = open("lk_flash_v4.log", "wb")

def log(m):
    print(m, flush=True)
    LOG.write((str(m) + "\n").encode()); LOG.flush()

s = serial.Serial(PORT, 921600, timeout=0.02)
s.reset_input_buffer()
recv = bytearray()
stop = [False]

def reader():
    raw = open("lk_flash_v4_serial.raw", "wb")
    while not stop[0]:
        try:
            d = s.read(65536)
            if d:
                recv.extend(d)
                LOG.write(d); LOG.flush()
                raw.write(d); raw.flush()
        except Exception:
            break
    raw.close()

def paced(cmd, wait=8.0):
    for ch in "  " + cmd:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    t0 = time.time(); n0 = len(recv)
    while time.time() - t0 < wait:
        time.sleep(0.05)
        if b"~ #" in bytes(recv[n0:])[-400:]:
            break
    return bytes(recv[n0:]).decode("utf-8", "replace")

def ping(ip):
    try:
        r = subprocess.run(["ping", "-n", "1", "-w", "1000", ip],
                           capture_output=True, text=True, timeout=5)
        return "TTL=" in r.stdout
    except Exception:
        return False

def md5f(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()

# ---- preflight: depot serves the exact deploy2.sh ----
want = md5f(D2)
try:
    got = urllib.request.urlopen(DEPOT + "/deploy2.sh", timeout=5).read()
    assert hashlib.md5(got).hexdigest() == want
    log("preflight: depot serves deploy2.sh md5=%s OK" % want)
except Exception as e:
    log("PREFLIGHT FAILED: %r" % e); sys.exit(1)

threading.Thread(target=reader, daemon=True).start()

ready = False
for i in range(12):
    n0 = len(recv)
    s.write(b"\r"); s.flush(); time.sleep(1.5)
    if b"~ #" in bytes(recv[n0:]):
        ready = True; break
log("attached=%s" % ready)
if not ready:
    log("CONSOLE DEAF -- needs power cycle + re-trap. ABORT (nothing written).")
    stop[0] = True; s.close(); sys.exit(2)

# ---- kick: env + fetch + verify + launch ----
paced("export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib", 4)
r = paced("curl -s --connect-timeout 8 -o /tmp/d2.sh http://%s:8931/deploy2.sh; md5sum /tmp/d2.sh" % PC_IP, 10)
log("fetch d2.sh: %s" % " ".join(r.split()[:4]))
if want not in r:
    log("D2 MD5 MISMATCH -- NOT launching. ABORT.")
    stop[0] = True; s.close(); sys.exit(3)
r = paced("(sh /tmp/d2.sh > /tmp/d2.console 2>&1 &)", 5)
log("launched: %r" % r[-60:])

# ---- poll deploy.log ----
ok = False; failed = False
for i in range(36):
    time.sleep(7)
    r = paced("tail -n 3 /tmp/deploy.log", 6)
    tail = " | ".join(l.strip() for l in r.splitlines() if l.strip() and "tail" not in l[:6])
    log("[%02d] %s" % (i, tail[:220]))
    if "ALL OK" in r: ok = True; break
    if "GATE" in r: failed = True; break
    if not tail and i > 4:  # console went quiet AND no log lines
        log("note: empty tail (console may be busy); continuing")

if failed:
    log("DEPLOY GATED -- see /tmp/deploy.log on device. bootctrl untouched; B still active.")
    stop[0] = True; s.close(); sys.exit(4)
if not ok:
    log("TIMEOUT waiting for ALL OK. Device state unknown -- NOT safe to power cycle blindly.")
    stop[0] = True; s.close(); sys.exit(5)
log("*** deploy reported ALL OK -- waiting for sysrq-b reboot ***")

# ---- watch ping death + capture boot ----
t0 = time.time(); died = False
while time.time() - t0 < 150:
    if not ping("169.254.77.1"):
        died = True; break
    time.sleep(3)
log("raw-shell IP dead=%s after %.0fs" % (died, time.time() - t0))

log("capturing boot output 90s (serial) ...")
time.sleep(90)
boot = bytes(recv).decode("utf-8", "replace")[-20000:]
for marker in ["OpenWrt", "v3:", "S98zz_data_hook", "toor", "procd", "Boot OK", "mtk"]:
    n = boot.count(marker)
    if n: log("boot-marker %r x%d" % (marker, n))

# ---- wait for v4 LAN ----
t0 = time.time(); up = False
while time.time() - t0 < 150:
    if ping("192.168.9.1"): up = True; break
    time.sleep(4)
log("192.168.9.1 up=%s after %.0fs" % (up, time.time() - t0))
try:
    r = subprocess.run(["powershell", "-NoProfile", "-Command",
        "(Get-NetIPAddress -InterfaceAlias '以太网' -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress"],
        capture_output=True, text=True, timeout=15)
    log("PC wired NIC now: %s" % r.stdout.strip())
except Exception as e:
    log("nic check err %r" % e)

log("*** lk_flash_v4 DONE (ok=%s, v4lan=%s) ***" % (ok, up))
stop[0] = True
s.close()
