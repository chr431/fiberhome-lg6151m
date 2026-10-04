#!/usr/bin/env python3
"""Final bootctrl fix from the init=/bin/sh console (serial COM)."""
import serial
import sys
import time

s = serial.Serial(sys.argv[1] if len(sys.argv) > 1 else "COM6", 921600, timeout=0.15)
LOG = open("lk_final_recovery.log", "ab")


def log(m):
    print(m, flush=True)
    LOG.write((str(m) + "\n").encode())
    LOG.flush()


def drain(sec):
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


def cmd(c, wait=3.0):
    s.reset_input_buffer()
    s.write((c + "\r").encode())
    s.flush()
    time.sleep(0.15)  # let the line land before more noise
    return drain(wait)


CMDS = [
    "mount -t devtmpfs devtmpfs /dev",
    "mount -t proc proc /proc",
    "ls /dev/mmcblk0p1",
    # bootctrl rollback: A(pri=14,try=0,succ=1,up=0) B(pri=15,try=0,succ=1,up=2)
    "printf '\\016\\000\\001\\000\\000\\017\\000\\001\\002\\000' | dd of=/dev/mmcblk0p1 bs=1 seek=2060",
    "hexdump -C -n 16 -s 2060 /dev/mmcblk0p1",
    "sync",
]

for c in CMDS:
    r = cmd(c, 4.0)
    # strip noisy kernel lines for display
    clean = [l for l in r.split("\r\n") if not l.strip().startswith("[") and l.strip()]
    log(f"$ {c}")
    for l in clean[:6]:
        log(f"  {l}")
    time.sleep(0.5)

log("=== VERIFY & REBOOT? check hexdump above shows: 0e 00 01 00 00 0f 00 01 02 00 ===")
s.close()
