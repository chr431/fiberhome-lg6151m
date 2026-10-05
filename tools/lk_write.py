#!/usr/bin/env python3
"""lk_write.py -- LK raw-shell 文件写入器（固化版, 取代 lk_fix_access.py）。

lk_fix_access 的两个教训在此修复:
  1) 挂载: raw 世界 /dev 常缺失, 直接 mount /dev/mmcblk0p46 会 ENODEV。
     此处按实测有效路径: tmpfs 上 mknod b 259 14 (user_data=p46) 再挂 ext4,
     并 touch 验证可写。
  2) 写入: 盲写 b64 在串口噪声下会静默丢行。此处每行带确认标记
     `&& echo __WOK<n>`, 收不到标记最多重发 3 次; 最终 md5 一票否决。
     (标记确认证明命令被执行而非仅被回显; 若命令已执行但输出丢失,
      重发会双写 -> md5 兜底拦截, 此时人工介入, 绝不带伤 reboot。)

其他固化: /proc 先挂载再做 SysRq-0 静音(顺序反了=静音全灭, 实测教训);
不使用 /dev/null 与 /tmp 重定向(raw 世界根文件系统只读)。

Usage (Git Bash 下必须 MSYS_NO_PATHCONV=1):
  MSYS_NO_PATHCONV=1 python tools/lk_write.py COM6 v2_access.sh gw/v2_access.sh [--reboot]
  remote 一律写 /data 下的相对路径; 可一次传多对 local/remote。
  只读巡检(不写文件不重启, 用于读 /data/gw/*.log 等现场证据):
  MSYS_NO_PATHCONV=1 python tools/lk_write.py COM6 --cmdlist diag.lc
  diag.lc 每行一条 shell 命令(#开头为注释), 输出捕获到 lk_write.log。
"""
import base64
import re
import hashlib
import serial
import sys
import threading
import time

PORT = sys.argv[1]
REBOOT = "--reboot" in sys.argv
RESUME = "--resume" in sys.argv   # 裸壳会话已在(上次跑完留了控制台), 跳过陷阱直接续
CMDLIST = None
_args = sys.argv[2:]
if "--cmdlist" in _args:
    i = _args.index("--cmdlist")
    CMDLIST = _args[i + 1]
    del _args[i:i + 2]
_files = [a for a in _args if not a.startswith("--")]
PAIRS = [(_files[i], _files[i + 1]) for i in range(0, len(_files) - 1, 2)]
if len(_files) % 2:
    sys.exit("!! 落单参数: %s (local/remote 必须成对)" % _files[-1])
if not PAIRS and not CMDLIST:
    sys.exit(__doc__)
LOG = open("lk_write.log", "ab")
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


def paced(c, wait=2.0):
    """逐字符发送(6ms/字符, 实测安全速率), 返回应答。"""
    for ch in c:
        s.write(ch.encode()); s.flush(); time.sleep(0.006)
    s.write(b"\n"); s.flush()
    return drain(wait)


def raw(c, wait=2.0):
    s.reset_input_buffer()
    s.write((c + "\r").encode()); s.flush()
    return drain(wait)


def confirmed(cmd, marker_ok, wait=2.5, tries=3):
    """发 cmd 并要求 marker_ok(形如 __WOK5_0, 即 '标记_退出码') 出现在应答中。
    命令回显只含 '$?' 字面量, 伪造不出 '_0' 后缀 -- 回显欺骗免疫。"""
    for k in range(tries):
        r = paced(cmd, wait)
        if marker_ok in r:
            return True
        log("  retry %d/%d (marker %s missing)" % (k + 1, tries, marker_ok))
    return False


# ---------- Stage A: 0x03 陷阱 (--resume 时跳过: 会话已存活) ----------
stop = False
if RESUME:
    log("=== RESUME 模式: 跳过陷阱, 探测现存裸壳 ===")
    r = paced("", wait=2.5)
    if not (r.rstrip().endswith("#") or "# " in r[-40:]):
        log("RESUME 失败: 无存活 shell 提示符, got %r -- 需重新断电跑完整流程" % r[-80:])
        s.close()
        sys.exit(1)
    log("裸壳仍存活")
else:
    def barrage():
        while not stop:
            try:
                s.write(b"\x03"); s.flush()
            except Exception:
                pass
            time.sleep(0.015)


    log("=== Stage A: 陷阱已布 -- 给设备断电重启(600s 窗口) ===")
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

if not RESUME:
    # ---------- Stage B: init=/bin/sh + 解析器耗尽 ----------
    r = raw("kcmdline append init=/bin/sh", 2.5)
    r = raw("kcmdline print", 3.0)
    if "init=/bin/sh" not in r:
        log("APPEND FAILED: %r" % r[-120:]); s.close(); sys.exit(2)

    paced("repeat 2000 heap alloc 65536", wait=10)   # 解析器 malloc 失败 = 唯一退出路径
    paced("", wait=6)
    drain(4)
    log("console loop exited, kernel booting /bin/sh")

    t0 = time.time(); boot_txt = ""
    while time.time() - t0 < 100:
        d = s.read(65536)
        if d:
            LOG.write(d); LOG.flush()
            boot_txt += d.decode("utf-8", "replace")
            if "BusyBox" in boot_txt or "/ # " in boot_txt[-200:] or "~ #" in boot_txt[-200:]:
                break
    log("kernel shell up")
    time.sleep(2)

# ---------- Stage C: 环境(顺序敏感: proc 先挂, SysRq-0 才生效) ----------
# v1.2 教训: (a) 分区 minor 跨启动会漂移(259:14 本次失效) -> sysfs 动态探测;
#           (b) `&& echo MARKER` 会被命令回显欺骗(回显含 MARKER 字面量) ->
#               一律用 `echo MARKER_$?` 形式, 回显只含 "$?" 字面量骗不过。
paced("mount -t proc proc /proc", wait=4)
paced("echo 0 > /proc/sysrq-trigger", wait=3)
paced("echo 1 > /proc/sys/kernel/printk", wait=3)
paced("mount -t devtmpfs devtmpfs /dev; echo MDEV_$?", wait=4)
paced("mount -t sysfs sysfs /sys; echo SYSFS_$?", wait=4)

# /data = mmcblk0p46 (user_data)。挂载策略(v1.4, 全部实测教训):
#   PRE: 若前次会话已挂(真 /data 可见)直接复用 -- 再 mount tmpfs /mnt 会把它埋掉
#   路1: /proc/partitions 查 major:minor -> tmpfs mknod -> mount(最可靠, /proc 必在)
#   路2: minor 顺序扫描兜底
#   devtmpfs 不可用(内核未编译, MDEV_255 实测); sysfs block 类为空(cat 拿不到 dev)
data_ok = False
r = paced("[ -e /mnt/data/rc.extend.sh ]; echo PRE_$?", wait=3)
if "PRE_0" in r:
    data_ok = True
    log("/data 已挂载(复用现存会话挂载)")
if not data_ok:
    paced("umount /mnt/data; umount /mnt; mount -t tmpfs tmpfs /mnt; mkdir -p /mnt/data", wait=4)
    r = paced("set -- $(grep mmcblk0p46 /proc/partitions); mknod /mnt/d46 b $1 $2; mount -t ext4 /mnt/d46 /mnt/data; [ -e /mnt/data/rc.extend.sh ]; echo DM1_$?", wait=8)
    if "DM1_0" in r:
        data_ok = True
        log("/data via /proc/partitions 节点(259:14)")
if not data_ok:
    paced("umount /mnt/data", wait=2)
    r = paced("i=2; while [ $i -lt 18 ]; do rm -f /mnt/dx; mknod /mnt/dx b 259 $i; mount -t ext4 /mnt/dx /mnt/data && [ -e /mnt/data/rc.extend.sh ] && { echo DM3_HIT_$i; break; }; umount /mnt/data; i=$((i+1)); done", wait=15)
    if re.search(r"DM3_HIT_\d", r):   # 回显含 'DM3_HIT_$i' 字面量, 必须匹配数字
        data_ok = True
        log("/data via minor 扫描: %s" % [l for l in r.splitlines() if "DM3_HIT" in l][:1])
if not data_ok:
    log("/data MOUNT FAILED(三路全败): %r" % r[-200:])
    log("控制台保持打开供人工处置")
    # 不 exit: 仍执行 cmdlist(能取 /proc 证据), 但绝不写入/重启
    if PAIRS or REBOOT:
        log("!! 有写入/重启请求但 /data 未挂载 -- 拒绝执行")
        s.close()
        sys.exit(3)
else:
    r = paced("touch /mnt/data/.wtest && rm /mnt/data/.wtest; echo WT_$?", wait=3)
    if "WT_0" not in r:
        log("/data 只读? %r" % r[-120:])
        if PAIRS:
            s.close(); sys.exit(3)
    log("/data mounted + writable (内容校验通过)")

# ---------- Stage D: 逐行 b64 写入(标记确认) + md5 一票否决 ----------
ok_all = True
if CMDLIST:
    cmds = [ln.strip() for ln in open(CMDLIST, encoding="utf-8")
            if ln.strip() and not ln.lstrip().startswith("#")]
    log("--- cmdlist: %d 条命令 ---" % len(cmds))
    for k, c in enumerate(cmds):
        log(">>> [%d] %s" % (k + 1, c))
        paced(c, wait=4.0)
    log("--- cmdlist 完成, 控制台保持打开(无 --reboot 不重启) ---")
elif PAIRS:
  for local, rel in PAIRS:
      data = open(local, "rb").read()
      assert b"\r\n" not in data, "CRLF in %s (行尾纪律!)" % local
      lines = base64.encodebytes(data).decode().splitlines()
      tmp = "/mnt/w.b64"
      dst = "/mnt/data/" + rel.lstrip("/")
      paced("rm -f %s" % tmp, wait=2)
      bad = 0
      for i, l in enumerate(lines):
        mk = "__WOK%d_0" % i
        if not confirmed("echo %s >>%s; echo __WOK%d_$?" % (l, tmp, i), mk, wait=1.5):
            bad += 1
            log("  LINE %d 未确认(3次) -- 依赖 md5 兜底" % i)
        if i % 20 == 0:
            log("  %s: %d/%d" % (local, i + 1, len(lines)))
      r = paced("(openssl base64 -d <%s || base64 -d <%s) > %s; md5sum %s"
              % (tmp, tmp, dst, dst), wait=6)
      want = hashlib.md5(data).hexdigest()
      good = want in r
      log("%s -> /data/%s : %s%s" % (local, rel, "OK" if good else "MD5-MISMATCH",
                                   " (警告: %d 行未确认)" % bad if bad else ""))
      if not good:
        log("  got: %r" % r[-160:])
        ok_all = False
# ---------- Stage E: 收尾 ----------
if ok_all:
    paced("sync", wait=4)
    if REBOOT:
        log("*** ALL OK -- reboot -f (正常槽位启动) ***")
        paced("reboot -f", wait=5)
    else:
        log("*** ALL OK -- console left open (no --reboot) ***")
else:
    log("md5 兜底拦截: 有一文件校验失败, 不 reboot, 控制台保持打开供人工处置")
s.close()
sys.exit(0 if ok_all else 4)
