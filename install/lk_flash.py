#!/usr/bin/env python3
"""lk_flash.py -- PC 侧刷机驱动（在 LK 陷阱已抓、raw shell 已就绪后运行）。

前提（install/README.md 有完整步骤）: 设备已通过 LK 串口链进入 raw shell
（`~ #` 提示符）。本脚本: 预检 depot 上的 kit.tar.gz -> 串口 kick 设备
curl 拉取 -> 后台自驱（载荷还原+构建镜像+刷入）-> 轮询 /tmp/deploy.log
-> 等待 sysrq-b 重启 -> 确认 v4 LAN 回来。

用法:
  python install/lk_flash.py [COM6] [--toor-pass PASS]
口令默认取 _local/secrets/device_local.py 的 TOOR_PASS(或 LG_TOOR_PASS)。
PC 侧先起 depot:  python -m http.server 8931   (在 install/ 目录)
"""
import hashlib
import os
import re
import subprocess
import sys
import threading
import time
import urllib.request

import serial

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

PORT = next((a for a in sys.argv[1:] if not a.startswith("-")), "COM6")
DEPOT = "http://127.0.0.1:8931"
KIT = os.path.join(HERE, "kit.tar.gz")
PC_IP = None  # 自动探测 PC 的 169.254 link-local 地址

LOG = open("lk_flash.log", "wb")


def log(m):
    print(m, flush=True)
    LOG.write((str(m) + "\n").encode())
    LOG.flush()


def md5f(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def detect_pc_ip():
    try:
        out = subprocess.run(["ipconfig"], capture_output=True, text=True,
                             timeout=10).stdout
        m = re.findall(r"IPv4[^:]*:\s*(169\.254\.\d+\.\d+)", out)
        if m:
            return m[0]
    except Exception:
        pass
    return None


def get_toor_pass():
    if "--toor-pass" in sys.argv:
        return sys.argv[sys.argv.index("--toor-pass") + 1]
    if os.environ.get("LG_TOOR_PASS"):
        return os.environ["LG_TOOR_PASS"]
    secrets = os.path.abspath(os.environ.get("LG_SECRETS_DIR")
                              or os.path.join(REPO, "..", "_local", "secrets"))
    sys.path.insert(0, secrets)
    try:
        import device_local as D
        return D.TOOR_PASS
    except Exception:
        sys.exit("!! 取不到 TOOR_PASS（--toor-pass / LG_TOOR_PASS / _local/secrets）")


def main():
    global PC_IP
    toor = get_toor_pass()
    if "'" in toor:
        sys.exit("!! 口令含单引号, 不支持")
    PC_IP = detect_pc_ip()
    if not PC_IP:
        sys.exit("!! 未探测到 PC 的 169.254.x.x 地址（有线口未就绪?）")
    log("PC link-local: %s   depot: %s" % (PC_IP, DEPOT))

    want = md5f(KIT)
    try:
        got = urllib.request.urlopen(DEPOT + "/kit.tar.gz", timeout=5).read()
        assert hashlib.md5(got).hexdigest() == want
        log("preflight: depot serves kit.tar.gz md5=%s OK" % want)
    except Exception as e:
        log("PREFLIGHT FAILED: %r" % e)
        sys.exit(1)

    s = serial.Serial(PORT, 921600, timeout=0.02)
    s.reset_input_buffer()
    recv = bytearray()
    stop = [False]

    def reader():
        raw = open("lk_flash_serial.raw", "wb")
        while not stop[0]:
            try:
                d = s.read(65536)
                if d:
                    recv.extend(d)
                    LOG.write(d)
                    LOG.flush()
                    raw.write(d)
                    raw.flush()
            except Exception:
                break
        raw.close()

    def paced(cmd, wait=8.0):
        for ch in "  " + cmd:
            s.write(ch.encode())
            s.flush()
            time.sleep(0.006)
        s.write(b"\r")
        s.flush()
        t0 = time.time()
        n0 = len(recv)
        while time.time() - t0 < wait:
            time.sleep(0.05)
            if b"~ #" in bytes(recv[n0:])[-400:]:
                break
        return bytes(recv[n0:]).decode("utf-8", "replace")

    def ping(ip):
        try:
            r = subprocess.run(["ping", "-n", "1", "-w", "1000", ip],
                               capture_output=True, text=True, timeout=5)
            return "TTL=" in r.stdout
        except Exception:
            return False

    threading.Thread(target=reader, daemon=True).start()

    ready = False
    for _ in range(12):
        n0 = len(recv)
        s.write(b"\r")
        s.flush()
        time.sleep(1.5)
        if b"~ #" in bytes(recv[n0:]):
            ready = True
            break
    log("attached=%s" % ready)
    if not ready:
        log("CONSOLE DEAF -- 需断电重上电并重抓 LK。中止(未写任何东西)。")
        stop[0] = True
        s.close()
        sys.exit(2)

    paced("export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib", 4)
    r = paced("curl -s --connect-timeout 8 --max-time 300 -o /tmp/kit.tgz "
              "http://%s:8931/kit.tar.gz; md5sum /tmp/kit.tgz" % PC_IP, 30)
    log("fetch kit: %s" % " ".join(r.split()[:4]))
    if want not in r:
        log("KIT MD5 MISMATCH -- 不启动。中止。")
        stop[0] = True
        s.close()
        sys.exit(3)
    paced("mkdir -p /tmp/kit && tar -xzf /tmp/kit.tgz -C /tmp/kit && "
          "md5sum -c /tmp/kit/MANIFEST.md5 2>&1 | tail -3", 20)
    r = paced("(sh /tmp/kit/run.sh '%s' >/tmp/kit.console 2>&1 &)" % toor, 5)
    log("launched: %r" % r[-60:])

    ok = False
    failed = False
    for i in range(60):
        time.sleep(7)
        r = paced("tail -n 3 /tmp/deploy.log", 6)
        tail = " | ".join(l.strip() for l in r.splitlines()
                          if l.strip() and "tail" not in l[:6])
        log("[%02d] %s" % (i, tail[:220]))
        if "ALL OK" in r:
            ok = True
            break
        if "GATE" in r:
            failed = True
            break

    if failed:
        log("DEPLOY GATED -- 见设备 /tmp/deploy.log。bootctrl 未动, B 槽仍可用。")
        stop[0] = True
        s.close()
        sys.exit(4)
    if not ok:
        log("TIMEOUT 等待 ALL OK。设备状态未知 -- 不要盲目断电。")
        stop[0] = True
        s.close()
        sys.exit(5)
    log("*** ALL OK -- 等待 sysrq-b 重启 ***")

    t0 = time.time()
    died = False
    while time.time() - t0 < 150:
        if not ping("169.254.77.1"):
            died = True
            break
        time.sleep(3)
    log("raw-shell IP dead=%s after %.0fs" % (died, time.time() - t0))

    log("capturing boot output 90s (serial) ...")
    time.sleep(90)
    boot = bytes(recv).decode("utf-8", "replace")[-20000:]
    for marker in ["OpenWrt", "v3:", "S98zz_data_hook", "toor", "procd", "mtk"]:
        n = boot.count(marker)
        if n:
            log("boot-marker %r x%d" % (marker, n))

    t0 = time.time()
    up = False
    while time.time() - t0 < 150:
        if ping("192.168.9.1"):
            up = True
            break
        time.sleep(4)
    log("192.168.9.1 up=%s after %.0fs" % (up, time.time() - t0))
    log("*** lk_flash DONE (ok=%s, lan=%s) ***" % (ok, up))
    stop[0] = True
    s.close()


if __name__ == "__main__":
    main()
