#!/usr/bin/env python3
"""Final: stage bootctrl bytes with zero-escaping-ambiguity, dd, verify, reboot."""
import serial
import sys
import time

s = serial.Serial(sys.argv[1] if len(sys.argv) > 1 else "COM6", 921600, timeout=0.15)
LOG = open("lk_final_recovery.log", "ab")
BS = chr(92)  # backslash, built explicitly


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


def cmd(c, wait=2.2):
    s.reset_input_buffer()
    s.write((c + "\r").encode())
    s.flush()
    time.sleep(0.3)
    return drain(wait)


# three short appends; bytes: 0e 00 01 | 00 00 0f | 00 01 02 00
parts = [
    ["016", "000", "001"],
    ["000", "000", "017"],
    ["000", "001", "002", "000"],
]
cmd("rm -f /mnt/bc", 1.5)
for i, p in enumerate(parts):
    octals = BS + (BS.join(p))
    c = "echo -en '" + octals + ("' > " if i == 0 else "' >> ") + "/mnt/bc"
    log(f"cmd{i}: {c}")
    r = cmd(c, 2.0)
    log(f"  resp: {r[:80]!r}")

r = cmd("hexdump -C /mnt/bc", 2.5)
log(f"staged: {r!r}")

r = cmd("cd /mnt", 1.2)
r = cmd("dd if=bc of=p1 bs=1 seek=2060", 3.5)
log(f"dd: {r[:150]!r}")

r = cmd("hexdump -C -n 10 -s 2060 p1", 3.5)
log(f"VERIFY: {r!r}")
ok = "0e 00 01 00 00 0f 00 01 02 00" in r.replace("  ", " ") or \
     ("0e" in r and "0f" in r and "02 00" in r and "0f 00 01" in r)
log(f"WRITE OK: {ok}")
if ok:
    cmd("sync", 2.5)
    log("*** rebooting into slot B in 5s ***")
    time.sleep(5)
    s.write(b"reboot -f\r")
    s.flush()
    drain(20)
else:
    log("verify FAILED — not rebooting; shell alive")
s.close()
