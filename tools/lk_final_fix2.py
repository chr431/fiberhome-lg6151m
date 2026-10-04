#!/usr/bin/env python3
"""Char-paced final fix: type like a human to avoid tty input overrun."""
import serial
import sys
import time

s = serial.Serial(sys.argv[1] if len(sys.argv) > 1 else "COM6", 921600, timeout=0.15)
LOG = open("lk_final_recovery.log", "ab")
BS = chr(92)


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


def type_cmd(c, wait=2.2, char_delay=0.005):
    s.reset_input_buffer()
    for ch in c:
        s.write(ch.encode())
        s.flush()
        time.sleep(char_delay)
    s.write(b"\r")
    s.flush()
    time.sleep(0.3)
    return drain(wait)


# 0. sanity: recover prompt, check /mnt tmpfs still mounted
s.write(b"\x03")
s.flush()
drain(1)
r = type_cmd("mount | grep mnt", 2)
log(f"mnt mount: {r!r}")
if "tmpfs" not in r:
    type_cmd("mount -t tmpfs tmpfs /mnt", 2)
    r = type_cmd("ls /mnt", 1.5)
    log(f"mnt contents: {r!r}")

# 1. stage bytes (3 short appends, char-paced)
type_cmd("rm -f /mnt/bc", 1.2)
parts = [["016", "000", "001"], ["000", "000", "017"], ["000", "001", "002", "000"]]
for i, p in enumerate(parts):
    c = "echo -en '" + BS + (BS.join(p)) + ("' > /mnt/bc" if i == 0 else "' >> /mnt/bc")
    r = type_cmd(c, 2.0)
    log(f"stage{i}: {r[:70]!r}")

r = type_cmd("cd /mnt && hexdump -C bc", 2.5)
log(f"staged bytes: {r!r}")

# 2. write + verify
r = type_cmd("dd if=bc of=p1 bs=1 seek=2060", 3.5)
log(f"dd: {r[:130]!r}")
r = type_cmd("hexdump -C -n 10 -s 2060 p1", 3.5)
log(f"VERIFY: {r!r}")
ok = "0e 00 01 00 00 0f 00 01 02 00" in r.replace("  ", " ")
log(f"WRITE OK: {ok}")
if ok:
    type_cmd("sync", 2.0)
    log("*** reboot to slot B in 5s ***")
    time.sleep(5)
    for ch in "reboot -f":
        s.write(ch.encode())
        s.flush()
        time.sleep(0.01)
    s.write(b"\r")
    s.flush()
    drain(20)
else:
    log("verify FAILED — shell alive, NOT rebooting")
s.close()
