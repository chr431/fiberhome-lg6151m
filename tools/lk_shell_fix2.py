#!/usr/bin/env python3
"""Repair the init-shell session: close stray quote, silence printk, redo fix."""
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
    time.sleep(0.2)
    return drain(wait)


def show(tag, r):
    clean = [l for l in r.replace("\r", "").split("\n")
             if l.strip() and not l.strip().startswith("[") and "SPM" not in l]
    log(f"$ {tag}")
    for l in clean[:8]:
        log(f"  {l.strip()[:110]}")


# 0. recover from the unterminated-quote state
drain(1)
s.write(b"'\r")
s.flush()
drain(2)

# 1. silence kernel console noise (needs /proc)
r = cmd("cat /proc/sys/kernel/printk", 2)
show("printk current", r)
r = cmd("echo 0 > /proc/sys/kernel/printk", 2)
show("silence printk", r)

# 2. verify/redo mounts
r = cmd("mount -t devtmpfs devtmpfs /dev", 3)
show("mount devtmpfs", r)
r = cmd("ls /dev/mmcblk0p1", 2)
show("node check", r)

# 3. if still missing, manual mknod on a tmpfs
r = cmd("ls /dev/mmcblk0p1", 2)
if "No such file" in r:
    cmd("mount -t tmpfs tmpfs /mnt", 3)
    cmd("mknod /mnt/p1 b 179 1", 2)
    node = "/mnt/p1"
else:
    node = "/dev/mmcblk0p1"

# 4. write rollback bootctrl
r = cmd("printf '\\016\\000\\001\\000\\000\\017\\000\\001\\002\\000' | dd of=" + node + " bs=1 seek=2060", 5)
show("dd write", r)

# 5. verify
r = cmd("hexdump -C -n 16 -s 2060 " + node, 5)
show("verify hexdump", r)
cmd("sync", 3)
log("=== if hexdump shows 0e 00 01 00 00 0f 00 01 02 00 -> ready to reboot ===")
s.close()
