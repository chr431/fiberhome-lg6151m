#!/usr/bin/env python3
"""Robust bootctrl fix: SysRq-0 silence first, short commands, verify, reboot."""
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


def cmd(c, wait=2.5, tries=3):
    """Short-command protocol: resend until the echo comes back clean."""
    for i in range(tries):
        s.reset_input_buffer()
        s.write((c + "\r").encode())
        s.flush()
        time.sleep(0.25)
        r = drain(wait)
        if c[:20] in r.replace("\r", "") and ("~ #" in r or "#" in r.split("\n")[-1] or True):
            return r
        log(f"  retry {i+1} for: {c[:40]}")
    return r


# 0. recover any stray quote state
s.write(b"'\r")
s.flush()
drain(2)

# 1. SILENCE the console: SysRq-0 via proc trigger (short + mask-bypassing)
log("=== silence console (SysRq 0) ===")
r = cmd("echo 0 > /proc/sysrq-trigger", 3)
log(f"resp: {r[:150]!r}")
quiet = drain(6)
noisy = quiet.count("[") > 2
log(f"noise after 6s: {len(quiet)} bytes, kernel-prints={quiet.count('[')} {'STILL NOISY' if noisy else 'QUIET'}")

# 2. devtmpfs
r = cmd("mount -t devtmpfs devtmpfs /dev", 3)
log(f"devtmpfs: {r[:120]!r}")
r = cmd("ls /dev/mmcblk0p1", 2)
if "mmcblk0p1" in r and "No such" not in r:
    node = "/dev/mmcblk0p1"
else:
    log("devtmpfs route failed, tmpfs+mknod route")
    cmd("mount -t tmpfs tmpfs /mnt", 3)
    cmd("mknod /mnt/p1 b 179 1", 2)
    node = "/mnt/p1"
log(f"node = {node}")

# 3. stage bytes on a writable fs
if node.startswith("/dev"):
    cmd("echo -en '\\016\\000\\001\\000\\000\\017\\000\\001\\002\\000' > /dev/bc", 3)
    bc = "/dev/bc"
else:
    cmd("echo -en '\\016\\000\\001\\000\\000\\017\\000\\001\\002\\000' > /mnt/bc", 3)
    bc = "/mnt/bc"
r = cmd(f"hexdump -C {bc}", 3)
log(f"staged bytes: {[l.strip() for l in r.split(chr(13)+chr(10)) if '000' in l and '0000' in l][:2]}")

# 4. dd + verify
cmd(f"dd if={bc} of={node} bs=1 seek=2060", 4)
r = cmd(f"hexdump -C -n 10 -s 2060 {node}", 4)
log(f"VERIFY: {r!r}")
ok = ("0e 00 01 00 00 0f 00 01 02 00" in r.replace("  ", " ").replace("0e 00 01", "0e 00 01")
      or ("0e" in r and "0f" in r and "02 00" in r))
log(f"bootctrl rollback written correctly: {ok}")

if ok:
    cmd("sync", 3)
    log("*** SUCCESS — rebooting into slot B (v2) in 5s ***")
    time.sleep(5)
    s.write(b"reboot -f\r")
    s.flush()
    drain(15)
else:
    log("!!! verify failed — shell left alive for manual intervention, NOT rebooting")
s.close()
