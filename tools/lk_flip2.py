#!/usr/bin/env python3
"""lk_flip2.py -- one-shot LK bootctrl flip to slot A (v3).
Follows docs/RESCUE_RUNBOOK_V2.md exactly:
  kcmdline append init=/bin/sh
  repeat 2000 heap alloc 65536      (parser exit = its own malloc failure)
  <Enter>                           -> "exiting main console loop"
  kernel /bin/sh on console:
    echo 0 > /proc/sysrq-trigger    (silence loglevel=8 flood)
    char-paced >=5ms commands, short lines only
    devtmpfs -> stage A bytes -> dd @2060 -> verify -> reboot -f
"""
import serial, sys, threading, time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
LOG = open("lk_flip2_session.log", "ab")
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


def paced(c, sec_per=0.006, wait=2.0):
    for ch in c:
        s.write(ch.encode()); s.flush(); time.sleep(sec_per)
    s.write(b"\r"); s.flush()
    return drain(wait)


def raw(c, wait=2.0):
    s.reset_input_buffer()
    s.write((c + "\r").encode()); s.flush()
    return drain(wait)


# ---- Stage A: Ctrl-C trap ----
stop = False
def barrage():
    while not stop:
        try:
            s.write(b"\x03"); s.flush()
        except Exception:
            pass
        time.sleep(0.015)

log("=== A: trap armed -- POWER-CYCLE THE CPE (600s window) ===")
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
    log("TRAP FAILED"); s.close(); sys.exit(1)
log("*** LK caught ***")
drain(1.5)

# ---- Stage B: kcmdline ----
r = raw("kcmdline append init=/bin/sh", 2.5)
r = raw("kcmdline print", 3.0)
if "init=/bin/sh" not in r:
    log("APPEND FAILED: %r" % r[-200:]); s.close(); sys.exit(2)
log("*** init=/bin/sh armed ***")

# ---- Stage C: repeat-exhaust + Enter (runbook recipe) ----
log("=== C: repeat 2000 heap alloc 65536 ===")
paced("repeat 2000 heap alloc 65536", wait=10)
paced("", wait=6)          # the Enter that triggers parser malloc failure
d = drain(4)
if "exiting" not in d:
    # retry once with double dose
    log("no exit marker yet; second wave")
    paced("repeat 4000 heap alloc 65536", wait=10)
    paced("", wait=6)
    d = drain(4)
log("stage C tail: %r" % d[-120:])

# ---- Stage D: kernel /bin/sh -- v1.5 自动完成体(不再留手工尾巴) ----
# 病灶修复(2026-10-05 实战三连坑):
#   1) 提示符检测被 loglevel=8 刷屏淹没 -> 改为周期发\n探针+找响应中的提示符
#   2) 没挂 /proc 就写 /proc/sysrq-trigger -> 先 mount proc 再静音
#   3) 验证失败无重试/结尾 reboot -f -> 校验失败重写一次; 成功用 sysrq-b
log("=== D: waiting kernel /bin/sh (ping-probe) ===")
t0 = time.time(); ready = False
while time.time() - t0 < 240:
    s.reset_input_buffer()
    s.write(b"\r"); s.flush()
    r = drain(2.5)
    if "/ #" in r or r.rstrip().endswith("#") or "BusyBox" in r:
        ready = True; break
    time.sleep(4)
if not ready:
    log("SHELL NOT READY after 240s -- port left open"); sys.exit(3)
log("*** raw shell ready ***")

def sh(c, wait=3.0):
    return paced(c, wait=wait)

sh("mount -t proc proc /proc", 4)                     # 先 proc(R7: 不吞错误)
sh("echo 0 > /proc/sysrq-trigger", 3)                 # 静音刷屏
sh("mount -t devtmpfs devtmpfs /dev 2>/dev/null", 3)  # 本机未编译, 失败无害
r = sh("ls /dev/mmcblk0p1", 3)
if "mmcblk0p1" not in r or "No such" in r:
    sh("mount -t tmpfs tmpfs /mnt", 3)
    sh("mknod /mnt/p1 b 179 1", 2)
    node, pre = "/mnt/p1", "/mnt/"
else:
    node, pre = "/dev/mmcblk0p1", "/dev/"
log("node=%s" % node)
# slot bytes: A-priority (boot v3) or B-priority (boot stock v2)
OCT = ("\\017\\003\\000\\000\\000\\016\\000\\001\\002\\000" if len(sys.argv) < 3 or sys.argv[2] == "a"
       else "\\016\\000\\000\\000\\000\\017\\000\\001\\001\\000")
WANT = ("0f 03 00 00 00" if len(sys.argv) < 3 or sys.argv[2] == "a" else "0e 00 00 00 00")

ok = False
for attempt in (1, 2):
    sh("echo -en '%s' > %sbc" % (OCT, pre), 3)
    sh("dd if=%sbc of=%s bs=1 seek=2060 conv=notrunc" % (pre, node), 5)
    r = sh("hexdump -C -n 10 -s 2060 %s" % node, 4)
    log("VERIFY(attempt %d): %r" % (attempt, r[:200]))
    if WANT in r.replace("  ", " "):
        ok = True; break
    log("mismatch, rewriting")
if not ok:
    log("VERIFY FAILED x2 -- console left open for manual rescue"); sys.exit(4)
sh("sync", 3)
log("*** bootctrl written+verified -- rebooting (sysrq-b) ***")
sh("echo b > /proc/sysrq-trigger", 4)
drain(3)
log("*** SUCCESS: slot %s set, device rebooting ***" % (sys.argv[2] if len(sys.argv) > 2 else "a"))
s.close()
sys.exit(0)
