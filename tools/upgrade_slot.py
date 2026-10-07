#!/usr/bin/env python3
"""upgrade_slot v1.0 -- SSH 整槽升级器: 不经串口重刷 slot A rootfs (P3/第一档加固)

设计(与 LK 串口管线等价的安全网, 全程网络):
  1. 预检: vercheck 全绿 / 当前 bootslot=a / 设备侧镜像存在且 md5 双验 /
     /data 剩余空间 >= p26 分区大小(整槽备份前置条件)。
  2. 生成设备侧自驱脚本 do_upgrade.sh 并经 deploy.py put 送达(唯一投递通道):
       md5 门禁 → dd 备份旧 p26 → dd 写新镜像 → 挂载 p26 做 sanity 断言
       (toor 账户/rcS 存在/#v3: 自定义标记/procd) → 任一失败 = 从备份整槽还原
       并退出(不重启, 运行系统不受影响) → 全过 = 清 TRY_A → sync → 重启。
  3. PC 侧轮询升级日志(REBOOTING/FAIL/RESTORED), 再轮询 SSH 回连做终检。
失败语义: dd 后 sanity 挂 = 自动还原旧槽, 系统留在旧 A(页缓存)可继续用;
真正无解的残局(还原也失败/新镜像启动即挂)才会走 LK 回退 B → 串口, 此为已知边界。

用法:
  python tools/upgrade_slot.py --img /data/build/rootfs_v41.squashfs [--md5 <hex>] [--dry-run]
  (--md5 缺省时以设备侧实测值为基准打印确认; --dry-run 只做预检+送达, 不执行)
"""
import argparse
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import lgssh  # noqa: E402

PAYLOAD_REMOTE = "/data/upgrade/do_upgrade.sh"
LOG_REMOTE = "/data/upgrade/upgrade.log"

PAYLOAD = r'''#!/bin/sh
# do_upgrade.sh v1.0 -- slot A 原位重镜像(自驱; SSH 会在 REBOOTING 处断开)
IMG="__IMG__"
MD5="__MD5__"
P26=/dev/mmcblk0p26
MISC=/dev/mmcblk0p1
BK=/data/upgrade/old_p26.bak
[ -f "$IMG" ] || { echo "FAIL image-missing"; exit 1; }
echo "STEP md5-gate"
GOT=$(md5sum "$IMG" 2>/dev/null | cut -d' ' -f1)
[ "$GOT" = "$MD5" ] || { echo "FAIL md5 got=$GOT want=$MD5"; exit 1; }
echo "STEP size-and-space"
SECT=$(cat /sys/block/mmcblk0/mmcblk0p26/size 2>/dev/null || awk '$4=="mmcblk0p26"{print $3}' /proc/partitions)
[ -n "$SECT" ] || { echo "FAIL no-p26-size"; exit 1; }
NEEDKB=$(( SECT / 2 ))
AVAILKB=$(df -k /data | awk 'NR==2{print $4}')
[ "$AVAILKB" -ge "$NEEDKB" ] || { echo "FAIL space avail=${AVAILKB}KB need=${NEEDKB}KB"; exit 1; }
echo "STEP backup-old-p26 ${NEEDKB}KB"
dd if=$P26 of=$BK bs=1M 2>/dev/null || { echo "FAIL backup-dd"; exit 1; }
sync
echo "STEP write-new-image"
dd if="$IMG" of=$P26 bs=1M 2>/dev/null || { echo "FAIL write-dd"; dd if=$BK of=$P26 bs=1M 2>/dev/null; echo "RESTORED-after-write-fail"; exit 1; }
sync
echo "STEP sanity"
mkdir -p /mnt/upv
if ! mount -t squashfs -o ro $P26 /mnt/upv 2>/dev/null; then
    echo "FAIL sanity-mount -> restore"
    dd if=$BK of=$P26 bs=1M 2>/dev/null; sync
    mount -t squashfs -o ro $P26 /mnt/upv 2>/dev/null && echo "RESTORED-verified" || echo "RESTORED-unverified"
    umount /mnt/upv 2>/dev/null
    exit 1
fi
ok=1
grep -q '^toor:' /mnt/upv/etc/passwd || { echo "FAIL no-toor-passwd"; ok=0; }
grep -q '^toor:' /mnt/upv/etc/shadow  || { echo "FAIL no-toor-shadow"; ok=0; }
[ -f /mnt/upv/etc/init.d/rcS ]         || { echo "FAIL no-rcS"; ok=0; }
grep -q '#v3:' /mnt/upv/etc/init.d/rcS || { echo "FAIL no-v3-marker"; ok=0; }
[ -f /mnt/upv/sbin/procd ]             || { echo "FAIL no-procd"; ok=0; }
if [ "$ok" != 1 ]; then
    echo "STEP sanity-failed -> restore"
    umount /mnt/upv 2>/dev/null
    dd if=$BK of=$P26 bs=1M 2>/dev/null; sync
    mkdir -p /mnt/upv2
    mount -t squashfs -o ro $P26 /mnt/upv2 2>/dev/null && grep -q '#v3:' /mnt/upv2/etc/init.d/rcS \
        && echo "RESTORED-verified" || echo "RESTORED-unverified"
    umount /mnt/upv2 2>/dev/null
    exit 1
fi
umount /mnt/upv 2>/dev/null
echo "STEP clear-try-a"
dd if=/dev/zero of=$MISC bs=1 seek=2061 count=1 conv=notrunc 2>/dev/null
sync
echo "REBOOTING"
reboot
'''


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--img", required=True, help="设备侧镜像绝对路径")
    ap.add_argument("--md5", help="预期 md5(缺省用设备侧实测值)")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    # 1) 仓门禁
    r = subprocess.run([sys.executable, os.path.join(HERE, "vercheck.py"), "check"],
                       capture_output=True, text=True)
    if "verdict: OK" not in r.stdout:
        print(r.stdout.strip()[-400:])
        sys.exit("FAIL: vercheck 未全绿, 拒绝升级")
    print("preflight: vercheck OK")

    c = lgssh.connect()
    run = lgssh.run
    # 2) 设备态断言
    slot = run(c, "cat /proc/cmdline | tr ' ' '\n' | grep '^bootslot='").strip()
    if slot != "bootslot=a":
        sys.exit(f"FAIL: 当前非 A 槽运行 ({slot}) — 本工具仅支持 A 槽原位升级")
    print("preflight: bootslot=a OK")
    dev_md5 = run(c, "md5sum %s 2>/dev/null | cut -d' ' -f1" % a.img).strip()
    if not dev_md5:
        sys.exit("FAIL: 设备侧镜像不存在或不可读: %s" % a.img)
    if a.md5 and a.md5 != dev_md5:
        sys.exit("FAIL: 镜像 md5 不符 (设备=%s 预期=%s)" % (dev_md5, a.md5))
    print("preflight: image md5 = %s %s" % (dev_md5, "(校验通过)" if a.md5 else "(未指定预期, 以此为基准)"))

    # 3) 生成并发送 payload(经 deploy put, 唯一投递通道)
    payload = PAYLOAD.replace("__IMG__", a.img).replace("__MD5", "__MD5__").replace("__MD5__", dev_md5)
    run(c, "mkdir -p /data/upgrade")
    import tempfile
    with tempfile.NamedTemporaryFile("w", suffix=".do_upgrade.sh", delete=False,
                                     encoding="utf-8", newline="\n") as tf:
        tf.write(payload)
        local = tf.name
    env = dict(os.environ)
    r = subprocess.run([sys.executable, os.path.join(HERE, "deploy.py"), "put",
                        local, PAYLOAD_REMOTE, "--mode", "755"],
                       env=env, capture_output=True, text=True)
    out = (r.stdout + r.stderr).strip()
    print(out.splitlines()[-1] if out else "put: (no output)")
    if r.returncode != 0 or "OK" not in out:
        sys.exit("FAIL: payload 送达未确认")
    os.unlink(local)
    if a.dry_run:
        print("dry-run: 预检+送达完成, 未执行。设备侧执行方式:")
        print("  nohup sh %s > %s 2>&1 &" % (PAYLOAD_REMOTE, LOG_REMOTE))
        c.close()
        return

    # 4) 点火 + 轮询日志
    print(run(c, "rm -f %s; nohup sh %s > %s 2>&1 & echo LAUNCHED" % (LOG_REMOTE, PAYLOAD_REMOTE, LOG_REMOTE)).strip())
    verdict = "TIMEOUT"
    for _ in range(180):   # 最多 15 分钟
        time.sleep(5)
        try:
            tail = run(c, "tail -3 %s 2>/dev/null" % LOG_REMOTE).strip()
        except Exception:
            tail = ""
        if "REBOOTING" in tail:
            verdict = "REBOOTING"; break
        if "RESTORED" in tail or "FAIL" in tail:
            verdict = tail.splitlines()[-1]; break
        print("  ...", tail.splitlines()[-1] if tail else "(等待)")
        if "LAUNCHED" not in tail and not tail:
            pass
    c.close()
    if verdict != "REBOOTING":
        sys.exit("升级中止: %s (旧槽保持/已还原, 设备未重启)" % verdict)
    print("新镜像已写入并通过 sanity, 设备重启中 (SSH 将断开 ~2-3 分钟)")

    # 5) 回连终检
    for i in range(40):
        time.sleep(10)
        try:
            c = lgssh.connect()
            print("设备回连 (%ds): %s" % ((i + 1) * 10, run(c, "id").strip()))
            print("bootslot: %s" % run(c, "cat /proc/cmdline | tr ' ' '\\n' | grep '^bootslot='").strip())
            print("shadow bind: %s" % run(c, "grep -c ' /etc/shadow ' /proc/mounts").strip())
            c.close()
            print("终检建议: python tools/selftest.py")
            return
        except Exception:
            print("  ...等待回连 (%ds)" % ((i + 1) * 10))
    sys.exit("FAIL: 设备未在 ~7 分钟内回连 — 可能需人工介入(此时才是串口场景)")


if __name__ == "__main__":
    main()
