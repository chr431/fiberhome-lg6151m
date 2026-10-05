#!/usr/bin/env python3
"""make_kit.py -- 组装设备端安装套件 kit.tar.gz（不随仓库分发，构建产物）。

内容: run.sh / build_image.sh / flash.sh / payload.tar.gz / ipk/* / MANIFEST.md5
设备侧流程见 install/README.md。产物 md5 供 lk_flash.py 预检。
"""
import hashlib
import os
import subprocess
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def md5(p):
    return hashlib.md5(open(p, "rb").read()).hexdigest()


def main():
    payload = os.path.join(HERE, "payload.tar.gz")
    subprocess.run([sys.executable, os.path.join(HERE, "make_payload.py"), payload],
                   check=True)
    kit = os.path.join(HERE, "kit.tar.gz")
    members = ["run.sh", "build_image.sh", "flash.sh", "payload.tar.gz"]
    ipk_dir = os.path.join(HERE, "ipk")
    ipks = sorted(f for f in os.listdir(ipk_dir) if f.endswith(".ipk"))
    lines = []
    for name in members:
        lines.append("%s  %s" % (md5(os.path.join(HERE, name)), name))
    for f in ipks:
        lines.append("%s  ipk/%s" % (md5(os.path.join(ipk_dir, f)), f))
    manifest = "\n".join(lines) + "\n"
    open(os.path.join(HERE, "MANIFEST.md5"), "w", newline="\n").write(manifest)

    with tarfile.open(kit, "w:gz") as tf:
        for name in members:
            tf.add(os.path.join(HERE, name), arcname=name)
        for f in ipks:
            tf.add(os.path.join(ipk_dir, f), arcname="ipk/" + f)
        tf.add(os.path.join(HERE, "MANIFEST.md5"), arcname="MANIFEST.md5")
    print("kit: %s (%d bytes, md5 %s)" % (kit, os.path.getsize(kit), md5(kit)))
    print(manifest, end="")


if __name__ == "__main__":
    main()
