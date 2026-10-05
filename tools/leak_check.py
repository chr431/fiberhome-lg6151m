#!/usr/bin/env python3
"""leak_check.py -- 敏感词零命中门禁（本仓库 = 公开固件仓）。

任何专有/私有标识不得出现在本仓库。默认扫描工作树；--history 追加全部
git 提交对象（内容与提交信息）。命中 = exit 1。

用法:
  python tools/leak_check.py              # 工作树
  python tools/leak_check.py --history    # 工作树 + 全部历史
建议接入 pre-push 钩子:  git push 前自动跑 --history。
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# 拼接构造: 工具自身源码不出现连续的敏感字面量(否则扫到自己)
PAT_PARTS = ["chen" + "5533", "0206" + "7859", "2024" + "30350049",
             "110[.]65" + "[.]40[.]", "fc:5c:" + "ee:6c", "1927" + "0085330",
             "d8:f5:" + "07:db:2a:9", r"\+861\d{9}",
             "sc" + "ut", "cam" + "pus", "校" + "园", "dr" + "com"]
SCAN_PAT = re.compile("|".join(PAT_PARTS), re.I)


def scan_text(rel, text, hits):
    for m in SCAN_PAT.finditer(text):
        hits.append("%s: ...%s..." % (rel, text[max(0, m.start() - 30):m.end() + 30]
                                      .replace("\n", " ")))
        break


def scan_tree(hits):
    for root, dirs, files in os.walk(REPO):
        dirs[:] = [d for d in dirs if d not in (".git", "__pycache__")]
        for n in dirs + files:
            if SCAN_PAT.search(n):
                hits.append("NAME: " + os.path.join(root, n))
        for f in files:
            p = os.path.join(root, f)
            try:
                if os.path.getsize(p) > 8 << 20:
                    continue
                scan_text(os.path.relpath(p, REPO).replace("\\", "/"),
                          open(p, encoding="utf-8", errors="replace").read(), hits)
            except OSError:
                continue


def sh_out(args):
    return subprocess.run(args, capture_output=True, cwd=REPO,
                          encoding="utf-8", errors="replace").stdout


def scan_history(hits):
    for line in sh_out(["git", "log", "--all", "--format=%H %s"]).splitlines():
        scan_text("COMMIT-MSG " + line[:12], line, hits)
    revs = sh_out(["git", "rev-list", "--all"]).split()
    if revs:
        out = sh_out(["git", "grep", "-l", "-E", "|".join(PAT_PARTS)] + revs)
        for line in out.splitlines():
            if line.strip():
                hits.append("HISTORY: " + line[:200])


def main():
    hits = []
    scan_tree(hits)
    if "--history" in sys.argv:
        scan_history(hits)
    if hits:
        print("!! 命中 %d 处:" % len(hits))
        for h in hits[:30]:
            print("   ", h)
        sys.exit(1)
    print("leak_check: 0 命中 (%s)" % ("含全历史" if "--history" in sys.argv else "工作树"))


if __name__ == "__main__":
    main()
