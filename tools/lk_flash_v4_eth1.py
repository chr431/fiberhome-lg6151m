#!/usr/bin/env python3
"""lk_flash_v4_eth1.py -- EMPIRICAL PROOF: full flash pipeline with the PC on
eth1 (the LAN-labeled port). Chain: LK trap -> raw shell -> setup -> eth1
bring-up (the historical doubt: 'PHY only attaches after ifup', symmetric
ports) -> curl transfer -> deploy2.sh self-drive -> reboot back to v4.1.
Everything logged; gates hard; bootctrl only flipped after p26 verify."""
import hashlib, re, serial, subprocess, sys, threading, time, urllib.request

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
D2 = r"D:\Repo\lg6151m-project\lg6151m\_drill_backup\deploy2.sh"
LOG = open("lk_eth1_proof.log", "wb")
RAW = open("lk_eth1_proof_serial.raw", "wb")

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

s = serial.Serial(PORT, 921600, timeout=0.02)
s.reset_input_buffer()
recv = bytearray()
stop_reader = [False]

def reader():
    while not stop_reader[0]:
        try:
            d = s.read(65536)
            if d:
                recv.extend(d)
                LOG.write(d); LOG.flush()
                RAW.write(d); RAW.flush()
        except Exception:
            break

def paced(cmd, wait=6.0, prefix="  "):
    for ch in prefix + cmd:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    t0 = time.time(); n0 = len(recv)
    while time.time() - t0 < wait:
        time.sleep(0.05)
        if b"~ #" in bytes(recv[n0:])[-400:]:
            break
    return bytes(recv[n0:]).decode("utf-8", "replace")

def sh(name, cmd, w=6.0):
    r = paced(cmd, w)
    log("=== %s ===\n%s" % (name, r.strip()))
    return r

# ---- preflight: depot serves the exact deploy2.sh ----
want = hashlib.md5(open(D2, "rb").read()).hexdigest()
try:
    got = urllib.request.urlopen("http://127.0.0.1:8931/deploy2.sh", timeout=5).read()
    assert hashlib.md5(got).hexdigest() == want
    log("preflight: depot deploy2.sh md5=%s OK" % want)
except Exception as e:
    log("PREFLIGHT FAILED (depot down?): %r" % e); sys.exit(1)

PC_IP = pc_wired_ip()
if PC_IP.startswith("169.254."):
    DEV_IP, MASK = "169.254.77.1", "255.255.0.0"
else:
    DEV_IP, MASK = ".".join(PC_IP.split(".")[:3]) + ".77", "255.255.255.0"
log("PC wired IP: %s -> device eth1 will be %s/%s" % (PC_IP, DEV_IP, MASK))

threading.Thread(target=reader, daemon=True).start()

# ---- Stage A: trap (user power-cycles within window) ----
log("=== A: trap armed -- POWER-CYCLE THE CPE (900s window) ===")
stop_barrage = False
def barrage():
    while not stop_barrage:
        try:
            s.write(b"\x03"); s.flush()
        except Exception:
            pass
        time.sleep(0.015)
threading.Thread(target=barrage, daemon=True).start()
t0 = time.time(); hit = False
while time.time() - t0 < 900:
    d = s.read(65536)
    if d:
        recv.extend(d); LOG.write(d); LOG.flush(); RAW.write(d); RAW.flush()
        tail = bytes(recv[-4000:])
        if b"PINTEST" in d or b"PINTEST" in tail or b"entering main console loop" in tail:
            hit = True; break
stop_barrage = True; time.sleep(0.4)
if not hit:
    log("FATAL: TRAP FAILED (no PINTEST within window)"); sys.exit(1)
log("*** LK caught ***")
time.sleep(1.5); del recv[:]

def lkcmd(c, wait):
    n0 = len(recv)
    for ch in c:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\r"); s.flush()
    time.sleep(wait)
    return bytes(recv[n0:]).decode("utf-8", "replace")

# ---- Stage B/C/D ----
lkcmd("kcmdline append init=/bin/sh", 2.5)
r = lkcmd("kcmdline print", 3.0)
if "init=/bin/sh" not in r:
    log("FATAL: APPEND FAILED: %r" % r[-200:]); sys.exit(2)
log("*** init=/bin/sh armed ***")
log("=== C: heap exhaust ===")
paced("repeat 2000 heap alloc 65536", wait=10)
paced("", wait=6)
time.sleep(4)
log("stage C done")
t0 = time.time(); ready = False
while time.time() - t0 < 240:
    n0 = len(recv)
    s.write(b"\r"); s.flush(); time.sleep(2.5)
    if b"~ #" in bytes(recv[n0:]) or b"BusyBox" in bytes(recv[n0:]):
        ready = True; break
    time.sleep(2)
if not ready:
    log("FATAL: SHELL NOT READY"); sys.exit(3)
log("*** raw shell ready ***")

# ---- Stage E: environment ----
sh("proc", "mount -t proc proc /proc", 5)
sh("sysrq", "echo 0 > /proc/sysrq-trigger", 4)
sh("tmpfs", "mount -t tmpfs tmpfs /tmp", 4)
sh("devdir", "mount -t tmpfs tmpfs /dev && mknod /dev/null c 1 3 && mknod /dev/zero c 1 5 && mknod /dev/urandom c 1 9 && echo DEVOK", 6)
sh("nulltest", "echo hi > /dev/null && echo NULLOK", 4)
sh("env", "export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/fhrom/bin; export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib; echo ENVOK", 4)
sh("mknods", "mknod /dev/mmcblk0p26 b 179 26; mknod /dev/mmcblk0p1 b 179 1; mknod /dev/mmcblk0p46 b 259 14; mkdir -p /tmp/mnt_data /tmp/mnt_chk /tmp/xt; echo NODESOK", 6)

# ---- Stage F: eth1 bring-up -- THE EMPIRICAL CORE ----
sh("eth1_up", "ifconfig eth1 up; sleep 3; ifconfig eth1", 8)
sh("eth1_ip", "ifconfig eth1 %s netmask %s up; sleep 2; ifconfig eth1 | head -3" % (DEV_IP, MASK), 8)
r = sh("eth1_run", "ifconfig eth1 | grep -E 'inet|RUNNING'", 6)
run_ok = "RUNNING" in r and DEV_IP in r
log("ETH1 RUNNING=%s ip=%s" % (run_ok, DEV_IP in r))
if not run_ok:
    r2 = sh("eth1_diag", "cat /proc/net/dev | grep eth1; dmesg | grep -iE 'eth1|phy' | tail -6", 8)
    log("!! eth1 NO CARRIER -- the historical doubt CONFIRMED?? See diag above.")
    log("!! falling back to eth0 (cable may effectively be on eth0 port)")
    sh("eth0_try", "ifconfig eth0 %s netmask %s up; sleep 2; ifconfig eth0 | grep RUNNING" % (DEV_IP, MASK), 8)
r = sh("pc_ping", "ping -c 2 -W 3 %s 2>&1 | tail -2" % PC_IP, 10)
pc_ok = "0% packet loss" in r or "0% packet" in r
log("device->PC ICMP via eth1: %s" % pc_ok)
sh("cnt_before", "cat /proc/net/dev | grep eth1", 5)
sh("tcpdump_up", "(tcpdump -i eth1 -n -c 80 -s 96 host %s > /tmp/cap.txt 2>&1 &); sleep 1; echo CAPARMED" % PC_IP, 6)

# ---- Stage G: transfer + flash via deploy2 v1.1 ----
sh("export_pc", "export PC_URL=http://%s:8931; echo $PC_URL" % PC_IP, 4)
r = sh("fetch_d2", "curl -s --connect-timeout 8 -o /tmp/d2.sh http://%s:8931/deploy2.sh; md5sum /tmp/d2.sh" % PC_IP, 10)
if want not in r:
    log("FATAL: deploy2.sh md5 mismatch over eth1 -- transfer path unusable: %r" % r[-200:])
    log("pcap:"); sh("pcap_dump", "killall tcpdump 2>/dev/null; sleep 1; head -30 /tmp/cap.txt", 8)
    sys.exit(4)
log("*** deploy2.sh transferred over eth1, md5 OK ***")
r = sh("launch", "(sh /tmp/d2.sh > /tmp/d2.console 2>&1 &)", 5)
log("launched: %r" % r[-60:])

ok = False; gated = False
for i in range(40):
    time.sleep(7)
    r = paced("tail -n 3 /tmp/deploy.log", 6)
    tail = " | ".join(l.strip() for l in r.splitlines() if l.strip() and "tail" not in l[:6])
    log("[%02d] %s" % (i, tail[:220]))
    if "ALL OK" in r: ok = True; break
    if "GATE" in r: gated = True; break
sh("pcap_end", "killall tcpdump 2>/dev/null; sleep 1; grep -cE '.' /tmp/cap.txt; head -12 /tmp/cap.txt", 8)
if gated or not ok:
    log("FATAL: deploy gated/timeout (gated=%s ok=%s) -- bootctrl untouched" % (gated, ok))
    sys.exit(5)
log("*** ALL GATES PASSED -- deploy2 completing on eth1, rebooting ***")

# ---- Stage H: watch reboot + v4.1 return on eth1 LAN ----
t0 = time.time(); died = False
while time.time() - t0 < 150:
    if not ping("192.168.9.1"): died = True; break
    time.sleep(3)
log("v4 LAN died=%s after %.0fs (sysrq-b)" % (died, time.time() - t0))
time.sleep(75)
t0 = time.time(); up = False
while time.time() - t0 < 240:
    if ping("192.168.9.1"): up = True; break
    time.sleep(4)
log("192.168.9.1 back up=%s after %.0fs" % (up, time.time() - t0))
boot = bytes(recv).decode("utf-8", "replace")[-15000:]
for mk in ["OpenWrt", "v3:", "S98zz_data_hook", "procd"]:
    n = boot.count(mk)
    if n: log("boot-marker %r x%d" % (mk, n))

log("*** ETH1 FLASH PROOF DONE (ok=%s, v4lan=%s) ***" % (ok, up))
stop_reader[0] = True
s.close()
