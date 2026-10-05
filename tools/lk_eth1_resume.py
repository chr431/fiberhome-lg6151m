#!/usr/bin/env python3
"""lk_eth1_resume.py -- resume the eth1 flash proof from the CURRENT state:
device sits in LK main console loop (trap caught; init=/bin/sh already
appended per probe; LK has chosen slot B for this boot -- stock fallback,
which re-creates the real-user starting point). Chain from here:
kcmdline verify -> heap exhaust -> raw shell(stock p39) -> setup -> eth1 ->
misc[2060] evidence capture -> curl deploy2 v1.2 over eth1 -> full gates ->
reboot into v4.1 -> wait LAN back."""
import hashlib, re, serial, subprocess, sys, threading, time, urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
D2 = r"D:\Repo\lg6151m-project\lg6151m\_drill_backup\deploy2.sh"
LOG = open("lk_eth1_resume.log", "wb")

def log(m):
    print(m, flush=True)
    LOG.write((str(m) + "\n").encode()); LOG.flush()

def pc_wired_ip():
    r = subprocess.run(["powershell", "-NoProfile", "-Command",
        "(Get-NetIPAddress -InterfaceAlias '以太网' -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress"],
        capture_output=True, text=True, timeout=15)
    ip = r.stdout.strip().splitlines()[0].strip() if r.stdout.strip() else ""
    return ip if re.match(r"^\d+\.\d+\.\d+\.\d+$", ip) else ""

def ping(ip):
    try:
        r = subprocess.run(["ping", "-n", "1", "-w", "1000", ip],
                           capture_output=True, text=True, timeout=5)
        return "TTL=" in r.stdout
    except Exception:
        return False

want = hashlib.md5(open(D2, "rb").read()).hexdigest()
try:
    got = urllib.request.urlopen("http://127.0.0.1:8931/deploy2.sh", timeout=5).read()
    assert hashlib.md5(got).hexdigest() == want
    log("preflight: depot deploy2.sh(v1.2) md5=%s OK" % want)
except Exception as e:
    log("PREFLIGHT FAILED: %r" % e); sys.exit(1)

PC_IP = pc_wired_ip()
DEV_IP = ".".join(PC_IP.split(".")[:3]) + ".77" if not PC_IP.startswith("169.254.") else "169.254.77.1"
MASK = "255.255.255.0" if not PC_IP.startswith("169.254.") else "255.255.0.0"
log("PC=%s -> device eth1=%s/%s" % (PC_IP, DEV_IP, MASK))

s = None
for i in range(6):
    try:
        s = serial.Serial(PORT, 921600, timeout=0.02)
        break
    except Exception as e:
        log("open retry %d: %r" % (i, e)); time.sleep(2)
if not s:
    log("FATAL: COM6 unopenable"); sys.exit(1)
s.reset_input_buffer()
recv = bytearray()
stop = [False]

def reader():
    while not stop[0]:
        try:
            d = s.read(65536)
            if d:
                recv.extend(d)
                LOG.write(d); LOG.flush()
        except Exception:
            break

def paced(cmd, wait=6.0):
    for ch in "  " + cmd:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    t0 = time.time(); n0 = len(recv)
    while time.time() - t0 < wait:
        time.sleep(0.05)
        if b"~ #" in bytes(recv[n0:])[-400:] or b"] " in bytes(recv[n0:])[-20:]:
            break
    return bytes(recv[n0:]).decode("utf-8", "replace")

def lkcmd(c, wait):
    n0 = len(recv)
    for ch in c:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    time.sleep(wait)
    return bytes(recv[n0:]).decode("utf-8", "replace")

def sh(name, cmd, w=6.0):
    r = paced(cmd, w)
    log("=== %s ===\n%s" % (name, r.strip()))
    return r

threading.Thread(target=reader, daemon=True).start()

# ---- confirm LK console + init=/bin/sh armed ----
r = lkcmd("kcmdline print", 3.0)
if "init=/bin/sh" not in r:
    log("init=/bin/sh missing -- appending")
    lkcmd("kcmdline append init=/bin/sh", 2.5)
    r = lkcmd("kcmdline print", 3.0)
    if "init=/bin/sh" not in r:
        log("FATAL: cannot arm init=/bin/sh: %r" % r[-200:]); sys.exit(2)
slot_b = "bootslot=b" in r
log("*** LK console confirmed, init=/bin/sh armed, LK-chosen-slot-B=%s ***" % slot_b)

# ---- heap exhaust -> boot continues ----
log("=== heap exhaust ===")
paced("repeat 2000 heap alloc 65536", wait=10)
paced("", wait=6)
time.sleep(4)
log("stage C done -- waiting for raw shell (stock p39)")
t0 = time.time(); ready = False
while time.time() - t0 < 200:
    n0 = len(recv)
    s.write(b"\r"); s.flush(); time.sleep(2.5)
    if b"~ #" in bytes(recv[n0:]) or b"BusyBox" in bytes(recv[n0:]):
        ready = True; break
    time.sleep(2)
if not ready:
    log("FATAL: SHELL NOT READY"); sys.exit(3)
log("*** raw shell ready (stock slot B) ***")

# ---- environment ----
sh("proc", "mount -t proc proc /proc", 5)
sh("sysrq", "echo 0 > /proc/sysrq-trigger", 4)
sh("tmpfs", "mount -t tmpfs tmpfs /tmp", 4)
sh("devdir", "mount -t tmpfs tmpfs /dev && mknod /dev/null c 1 3 && mknod /dev/zero c 1 5 && mknod /dev/urandom c 1 9 && echo DEVOK", 6)
sh("env", "export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/fhrom/bin; export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib; echo ENVOK", 4)
sh("mknods", "mknod /dev/mmcblk0p26 b 179 26; mknod /dev/mmcblk0p1 b 179 1; mknod /dev/mmcblk0p46 b 259 14; mkdir -p /tmp/mnt_data /tmp/mnt_chk /tmp/xt; echo NODESOK", 6)

# ---- EVIDENCE: misc[2060] as LK left it (fallback decision) ----
sh("misc_now", "hexdump -C -s 2060 -n 16 /dev/mmcblk0p1", 6)

# ---- eth1 empirical core ----
sh("eth1_up", "ifconfig eth1 up; sleep 3; ifconfig eth1", 8)
sh("eth1_ip", "ifconfig eth1 %s netmask %s up; sleep 2; ifconfig eth1 | grep -E 'inet|RUNNING'" % (DEV_IP, MASK), 8)
r = sh("pc_ping", "ping -c 2 -W 3 %s 2>&1 | tail -2" % PC_IP, 10)
pc_ok = "0% packet" in r
log("device->PC ICMP over eth1: %s" % pc_ok)
if not pc_ok:
    sh("diag", "cat /proc/net/dev | grep eth1; dmesg | grep -iE 'eth1|phy' | tail -5", 8)
    log("FATAL: eth1 unusable -- proof FAILED"); sys.exit(4)
sh("tcpdump_up", "(tcpdump -i eth1 -n -c 80 -s 96 host %s > /tmp/cap.txt 2>&1 &); echo CAPARMED" % PC_IP, 6)

# ---- transfer + full flash via deploy2 v1.2 ----
sh("export_pc", "export PC_URL=http://%s:8931" % PC_IP, 4)
r = sh("fetch_d2", "curl -s --connect-timeout 8 -o /tmp/d2.sh http://%s:8931/deploy2.sh; md5sum /tmp/d2.sh" % PC_IP, 10)
if want not in r:
    log("FATAL: deploy2 md5 mismatch over eth1"); sys.exit(5)
log("*** deploy2.sh(v1.2) transferred over eth1, md5 OK ***")
r = sh("launch", "(sh /tmp/d2.sh > /tmp/d2.console 2>&1 &)", 5)
log("launched")

ok = False
for i in range(30):
    time.sleep(7)
    r = paced("tail -n 3 /tmp/deploy.log", 6)
    tail = " | ".join(l.strip() for l in r.splitlines() if l.strip() and "tail" not in l[:6])
    log("[%02d] %s" % (i, tail[:230]))
    if "ALL OK" in r: ok = True; break
    if "GATE" in r: break
sh("pcap_end", "killall tcpdump 2>/dev/null; sleep 1; grep -cE '.' /tmp/cap.txt; grep -E 'S\\]|:8931' /tmp/cap.txt | head -8", 8)
sh("misc_after", "hexdump -C -s 2060 -n 16 /dev/mmcblk0p1", 6)
if not ok:
    log("FATAL: deploy gated/timeout"); sys.exit(6)
log("*** ALL GATES PASSED on eth1 -- rebooting into v4.1 ***")

t0 = time.time(); died = False
while time.time() - t0 < 120:
    if not ping("192.168.9.1"): died = True; break
    time.sleep(3)
log("old LAN died=%s (%.0fs)" % (died, time.time() - t0))
time.sleep(60)
t0 = time.time(); up = False
while time.time() - t0 < 180:
    if ping("192.168.9.1"): up = True; break
    time.sleep(4)
log("192.168.9.1 back=%s (%.0fs)" % (up, time.time() - t0))
log("*** ETH1 FLASH PROOF COMPLETE (ok=%s v4lan=%s) ***" % (ok, up))
stop[0] = True
s.close()
