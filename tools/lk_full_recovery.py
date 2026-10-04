#!/usr/bin/env python3
"""One-shot LK recovery: trap console -> append init=/bin/sh -> heap-exhaust
exit -> kernel boots /bin/sh on console -> fix bootctrl -> reboot to v2."""
import serial
import sys
import threading
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
s = serial.Serial(PORT, 921600, timeout=0.02)
s.reset_input_buffer()
LOG = open("lk_recovery_session.log", "ab")


def log(msg):
    print(msg, flush=True)
    LOG.write((msg + "\n").encode())
    LOG.flush()


def drain(sec=0.5):
    out = b""
    t0 = time.time()
    while time.time() - t0 < sec:
        d = s.read(65536)
        if d:
            out += d
    if out:
        LOG.write(out)
        LOG.flush()
    return out.decode("utf-8", "replace")


def cmd(c, wait=1.2):
    s.reset_input_buffer()
    s.write((c + "\r").encode())
    s.flush()
    return drain(wait)


# ---------- Stage A: trap ----------
stop = False


def barrage():
    while not stop:
        try:
            s.write(b"\x03")
            s.flush()
        except Exception:
            pass
        time.sleep(0.015)


log("=== Stage A: 0x03 trap, waiting for PINTEST (power-cycle the CPE) ===")
t = threading.Thread(target=barrage, daemon=True)
t.start()
buf = b""
t0 = time.time()
hit = False
while time.time() - t0 < 600:
    d = s.read(65536)
    if d:
        buf += d
        LOG.write(d)
        if b"PINTEST" in d or b"PINTEST" in buf[-4000:] or b"entering main console loop" in buf:
            hit = True
            break
stop = True
time.sleep(0.4)
if not hit:
    log(f"TRAP FAILED after 600s ({len(buf)} bytes)")
    s.close()
    sys.exit(1)
log("*** PINTEST caught ***")
drain(1.5)

# ---------- Stage B: arm init=/bin/sh ----------
log("=== Stage B: kcmdline append ===")
cmd("", 0.5)
r = cmd("kcmdline append init=/bin/sh", 1.5)
log(f"append resp: {r[-120:]!r}")
r = cmd("kcmdline print", 2)
ok = "init=/bin/sh" in r
log(f"verify init=/bin/sh in cmdline: {ok}")
if not ok:
    log("ABORT: append failed")
    s.close()
    sys.exit(2)

# ---------- Stage C: usage survey (for the record / possible write primitives) ----------
log("=== Stage C: usage survey ===")
for c in ["heap", "pmm", "vmm", "vm", "page_alloc", "test"]:
    r = cmd(c, 1.0)
    log(f"[{c}] {r[:200]!r}")

# ---------- Stage D: heap growth probe ----------
log("=== Stage D: heap probe ===")
base = cmd("heap", 1.5)
log(f"heap baseline: {base[:300]!r}")
for i in range(200):
    s.write((f"z{i}z" + "z" * 110).encode())
    s.write(b"\r")
    s.flush()
    time.sleep(0.004)
drain(2.0)
h1 = cmd("heap", 1.5)
log(f"heap after 200 lines: {h1[:300]!r}")
r = cmd("repeat 200 echo q", 2.0)
h2 = cmd("heap", 1.5)
log(f"heap after repeat 200 echo: {h2[:300]!r}")

# decide growth
grew = (h1 != base) or (h2 != base)
log(f"heap growth detected: {grew}")

# ---------- Stage E: hammer to exhaustion ----------
log("=== Stage E: hammering (watch for 'exiting main console loop') ===")
exited = False
batch = 0
t0 = time.time()
while not exited and time.time() - t0 < 300:
    for i in range(300):
        s.write(("y" + str(batch) + "y" + "y" * 110).encode())
        s.write(b"\r")
        s.flush()
        time.sleep(0.003)
    batch += 1
    d = drain(1.0)
    if "exiting main console loop" in d or "not enough memory" in d:
        exited = True
    if batch % 5 == 0:
        log(f"  batch {batch}, {len(d)} resp bytes, exited={exited}")

if not exited:
    log("HAMMER FAILED to exit console in 300s — dumping and stopping")
    s.close()
    sys.exit(3)
log("*** CONSOLE EXITED — boot should proceed ***")

# ---------- Stage F: watch kernel boot -> /bin/sh ----------
log("=== Stage F: waiting for kernel + sh ===")
boot = drain(45)
log(f"boot tail: {boot[-600:]!r}")
s.write(b"\r")
drain(1.0)
pr = drain(2.0)
log(f"prompt probe: {pr[:200]!r}")
if "#" not in pr and "/ #" not in pr:
    # try again after more boot time
    time.sleep(10)
    s.write(b"\r")
    pr = drain(2.0)
    log(f"prompt probe2: {pr[:200]!r}")

# ---------- Stage G: fix bootctrl + reboot ----------
log("=== Stage G: dd bootctrl rollback ===")
cmds = [
    "ls /dev/mmcblk0p1",
    "printf '\\016\\000\\001\\000\\000\\017\\000\\001\\002\\000' | dd of=/dev/mmcblk0p1 bs=1 seek=2060",
    "hexdump -C -n 10 -s 2060 /dev/mmcblk0p1",
    "sync",
    "reboot -f",
]
for c in cmds:
    r = cmd(c, 3.0)
    log(f"$ {c}\n{r[:300]}")
log("=== done — device should reboot to slot B (v2) ===")
drain(20)
s.close()
