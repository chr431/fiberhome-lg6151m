#!/usr/bin/env python3
"""leak_check.py -- 敏感词零命中门禁（本仓库 = 公开固件仓）。

任何专有/私有标识不得出现在本仓库。默认扫描工作树；--history 追加全部
git 提交对象（内容与提交信息）。命中 = exit 1。

用法:
  python tools/leak_check.py              # 工作树
  python tools/leak_check.py --history    # 工作树 + 全部历史
建议接入 pre-push 钩子:  git push 前自动跑 --history。
"""
import io
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

# v1.2(P2/PC-M4): 模式分两层 —
#   PAT_GENERIC: 仓纪律词(本仓设计上必须零命中的中性标识), 留在源内
#   个人 PII 模式(姓名/号码/IMEI/MAC/IP): 外置 _local/secrets/leak_patterns.py
#   (仓外, LG_SECRETS_DIR 可覆盖; 预期内容 PATTERNS=[...])。
#   动机: 拼接构造只骗得过它自己的 grep, 骗不过人 — 源码里两段字面量并排
#   即可拼回完整 MAC/姓名片段, 等于把要防的 PII 发布在公开仓里。
PAT_GENERIC = ["sc" + "ut", "cam" + "pus", "校" + "园", "dr" + "com"]
SECRETS_DIR = os.path.abspath(os.environ.get("LG_SECRETS_DIR")
                              or os.path.join(REPO, "..", "_local", "secrets"))
PERSONAL = []
_pfile = os.path.join(SECRETS_DIR, "leak_patterns.py")
if os.path.isfile(_pfile):
    _ns = {}
    exec(io.open(_pfile, encoding="utf-8").read(), _ns)
    PERSONAL = _ns.get("PATTERNS", [])
    if not PERSONAL:
        print("WARN: %s 存在但 PATTERNS 为空" % _pfile)
else:
    print("WARN: 个人PII模式未配置(%s) — 仅扫描仓纪律词" % _pfile)
SCAN_PAT = re.compile("|".join(PAT_GENERIC + PERSONAL), re.I)


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
    revs = sh_out(["git", "rev-list", "--all"]).split()
    # v2.2: 提交信息全量扫描(正文 %B) — 原仅扫标题 %s, 消息体泄露可漏检(2026-10-08 实证)
    for h in revs:
        scan_text("COMMIT-MSG " + h[:12],
                  sh_out(["git", "log", "-1", "--format=%B", h]), hits)
    if revs:
        # v2.1: 修 v2.0 重构遗留 — PAT_PARTS 未定义(NameError), --history 实际从未跑通过
        out = sh_out(["git", "grep", "-l", "-i", "-E",
                      "|".join(PAT_GENERIC + PERSONAL)] + revs)
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
