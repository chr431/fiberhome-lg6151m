#!/usr/bin/env python3
"""lk_flip_to_a.py -- one-shot: LK trap -> init=/bin/sh -> bootctrl -> slot A.

Pipeline (all stages field-proven 2026-10-01, recombined 2026-10-02):
  A. 0x03 barrage trap -> LK PINTEST console (power-cycle the CPE)
  B. kcmdline append init=/bin/sh (raw kernel shell: no FH userspace, no
     console input-thieves, no service NUL-flood)
  C. heap-hammer until LK exits its main console loop (only exit path)
  D. kernel boots /bin/sh -> mount devtmpfs -> dd A-priority bootctrl bytes
     (misc p1 @2060) -> verify -> reboot -> v3 (slot A)
Run with COM6 free (stop serial_server + supervisor first).
"""
import serial, sys, threading, time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
LOG = open("lk_flip_session.log", "ab")
s = serial.Serial(PORT, 921600, timeout=0.02)
s.reset_input_buffer()


def log(m):
    print(m, flush=True)
    LOG.write((str(m) + "\n").encode()); LOG.flush()


def drain(sec=0.5):
    out = b""
    t0 = time.time()
    while time.time() - t0 < sec:
        d = s.read(65536)
        if d:
            out += d
    if out:
        LOG.write(out); LOG.flush()
    return out.decode("utf-8", "replace")


def cmd(c, wait=1.5):
    s.reset_input_buffer()
    s.write((c + "\r").encode()); s.flush()
    time.sleep(0.15)
    return drain(wait)


# ---- Stage A: trap ----
stop = False
def barrage():
    while not stop:
        try:
            s.write(b"\x03"); s.flush()
        except Exception:
            pass
        time.sleep(0.015)

log("=== A: trap armed -- POWER-CYCLE THE CPE NOW (600s window) ===")
threading.Thread(target=barrage, daemon=True).start()
buf = b""; t0 = time.time(); hit = False
while time.time() - t0 < 600:
    d = s.read(65536)
    if d:
        buf += d; LOG.write(d); LOG.flush()
        if b"PINTEST" in d or b"PINTEST" in buf[-4000:] or b"entering main console loop" in buf:
            hit = True; break
stop = True; time.sleep(0.4)
if not hit:
    log("TRAP FAILED (600s)"); s.close(); sys.exit(1)
log("*** LK console caught ***")

# ---- Stage B: kcmdline append ----
drain(1.0)
r = cmd("kcmdline append init=/bin/sh", 2.0)
log("append: %r" % r[-120:])
r = cmd("kcmdline print", 2.5)
if "init=/bin/sh" not in r:
    log("ABORT: kcmdline append failed: %r" % r[-200:]); s.close(); sys.exit(2)
log("*** init=/bin/sh armed ***")

# ---- Stage C: heap-hammer to exit console loop ----
log("=== C: heap hammer (exit LK loop) ===")
exited = False; batch = 0; t0 = time.time()
while not exited and time.time() - t0 < 300:
    for i in range(300):
        s.write(("y%d%s" % (batch, "y" * 110)).encode()); s.write(b"\r")
        s.flush(); time.sleep(0.003)
    batch += 1
    d = drain(1.0)
    if "exiting main console loop" in d or "not enough memory" in d:
        exited = True
    if batch % 5 == 0:
        log("  batch %d exited=%s" % (batch, exited))
if not exited:
    log("HAMMER FAILED"); s.close(); sys.exit(3)
log("*** LK exiting -- boot proceeds ***")

# ---- Stage D: kernel raw shell -> bootctrl ----
log("=== D: waiting for kernel /bin/sh (up to 120s) ===")
t0 = time.time(); ready = False
while time.time() - t0 < 120:
    d = s.read(65536)
    if d:
        LOG.write(d); LOG.flush()
        tail = d.decode("utf-8", "replace")
        if "/ # " in tail or tail.rstrip().endswith("#") or "BusyBox" in tail:
            ready = True; break
if not ready:
    log("no shell prompt seen; probing anyway")
time.sleep(3)

def kcmd(c, wait=4.0, tries=3):
    for i in range(tries):
        s.reset_input_buffer()
        s.write((c + "\n").encode()); s.flush()
        r = drain(wait)
        if c[:15] in r.replace("\r", ""):
            return r
        log("  retry %d: %s" % (i + 1, c[:40]))
    return r

log("silence console")
kcmd("echo 0 > /proc/sysrq-trigger", 3)
log("mount devtmpfs")
kcmd("mount -t devtmpfs devtmpfs /dev", 4)
r = kcmd("ls /dev/mmcblk0p1", 3)
if "mmcblk0p1" not in r or "No such" in r:
    kcmd("mount -t tmpfs tmpfs /mnt", 3)
    kcmd("mknod /mnt/p1 b 179 1", 2)
    node = "/mnt/p1"; pre = "/mnt/"
else:
    node = "/dev/mmcblk0p1"; pre = "/dev/"
log("node=%s" % node)
kcmd("echo -en '\\016\\003\\000\\000\\000\\016\\000\\001\\002\\000' > %sbc" % pre, 3)
r = kcmd("hexdump -C %sbc | head -2" % pre, 3)
log("staged: %r" % r[:200])
kcmd("dd if=%sbc of=%s bs=1 seek=2060 count=10" % (pre, node), 5)
r = kcmd("hexdump -C -n 10 -s 2060 %s" % node, 5)
log("VERIFY: %r" % r[:300])
ok = ("0f 03 00 00 00" in r.replace("  ", " ")) or ("0f" in r and "02 00" in r)
log("bootctrl=A written: %s" % ok)
if ok:
    kcmd("sync", 3)
    log("*** SUCCESS -- rebooting into slot A (v3) ***")
    kcmd("reboot -f", 4)
else:
    log("VERIFY FAILED -- NOT rebooting; shell left on console for manual fix")
s.close()
