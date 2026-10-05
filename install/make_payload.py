#!/usr/bin/env python3
"""make_payload.py -- 从本仓 MANIFEST 生成 /data 载荷 payload.tar.gz。

tar 内路径 = 设备绝对路径去前导斜杠（data/gw/*、data/rc.extend.sh、
data/rescue/babysit.sh）。设备侧以 `tar -xzf payload.tar.gz -C /` 还原。
MANIFEST 直接解析 deploy.py 源码（不 import，避免 paramiko/凭证依赖）。
"""
import hashlib
import os
import re
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# 额外载荷件（MANIFEST 之外的引导/救援件）
EXTRA = [
    ("gw/v3_babysit_v2.sh", "/data/rescue/babysit.sh"),
]


def parse_manifest():
    src = open(os.path.join(REPO, "tools", "deploy.py"), encoding="utf-8").read()
    m = re.search(r"^MANIFEST = \[(.*?)^\]", src, re.S | re.M)
    if not m:
        sys.exit("!! 解析 deploy.py MANIFEST 失败")
    rows = re.findall(r'\("([^"]+)",\s*"([^"]+)"\)', m.group(1))
    return rows + EXTRA


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "payload.tar.gz")
    rows = parse_manifest()
    with tarfile.open(out, "w:gz") as tf:
        for local, remote in rows:
            lp = os.path.join(REPO, local)
            if not os.path.isfile(lp):
                sys.exit("!! 缺文件: %s" % local)
            tf.add(lp, arcname=remote.lstrip("/"))
    md5 = hashlib.md5(open(out, "rb").read()).hexdigest()
    print("payload: %s (%d entries, %d bytes, md5 %s)"
          % (out, len(rows), os.path.getsize(out), md5))


if __name__ == "__main__":
    main()
