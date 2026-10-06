#!/usr/bin/env python3
"""vercheck.py -- 版本注册表机制（唯一事实源 tools/VERSIONS.tsv）。

三条同步链，全部由本脚本机械保证，杜绝手工抄写漂移：
  1. 注册表 <-> deploy.py MANIFEST：kind=manifest 的行必须与 MANIFEST 一一对应
  2. 注册表 <-> 磁盘：每个 name 必须是仓库中存在的文件；src 行还要求
     源码与产物版本一致（healthdog.c 与 healthdog.ko 同版本号）
  3. 注册表 <-> docs/ARCHITECTURE.md：架构图内版本表由 `render` 生成、
     `check` 强制与注册表逐字节一致（VERCHECK 标记块内禁手改）
  4. image 行（v1.1）：不可入库的大产物（镜像/封包，gitignore 本地保留），
     target 列 = 32hex md5 指纹，`check` 强制磁盘文件 md5 与之一致——
     产物内容被机械钉死，换一个字节即 fail。
  5. 性质分区（v1.2）：位置必须匹配性质，杜绝设备载荷/永久工具/一次性混杂：
       gw/            设备载荷(manifest 件 + gw/bin + gw/src + gw/www)
       tools/         PC 永久工具(必须登记)
       tools/oneoff/  一次性/取证/历史归档(**禁止登记**)
       analysis/ *_analysis/ ref/  RE 数据与厂商转储(不登记)
       _drill_backup/ 刷机资产(image/tool 登记件)
       根级白名单      .gitignore .gitattributes LICENSE README.md
     双向强制: 登记行必须在正确区; 全部 git 跟踪文件必须可归类。

设备同步（第 4 链）由 deploy.py 完成：push 时把版本注入 #DEPLOY 戳，
snapshot 把注册表(含 md5)写到 /data/gw/VERSIONS，doctor 比对两侧。

Usage:
  python tools/vercheck.py check   # 本地一致性校验 (exit 1 = 有违规)
  python tools/vercheck.py render  # 重新生成 ARCHITECTURE.md 版本表
  python tools/vercheck.py device  # 对比设备 /data/gw/VERSIONS (需 SSH 环境)
"""
import hashlib
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
TSV = os.path.join(HERE, "VERSIONS.tsv")
ARCH = os.path.join(REPO, "docs", "ARCHITECTURE.md")
BEGIN = "<!--VERCHECK:BEGIN (generated from tools/VERSIONS.tsv; edit THERE, then `vercheck.py render`)-->"
END = "<!--VERCHECK:END-->"
VER_RE = re.compile(r"^\d+\.\d+$")
# deploy.py MANIFEST 行: ("local", "/device/path"),
MAN_RE = re.compile(r'^\s*\("([^"]+)",\s*"([^"]+)"\),?\s*(?:#.*)?$')


def load_registry():
    """-> [(name, ver, kind, target, note)]；格式错误立即失败。"""
    rows = []
    for ln, line in enumerate(open(TSV, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 5:
            sys.exit("!! VERSIONS.tsv 第 %d 行应为 5 列(tab 分隔): %r" % (ln, line))
        name, ver, kind, target, note = parts
        if not VER_RE.match(ver):
            sys.exit("!! VERSIONS.tsv 第 %d 行版本号格式应为 N.N: %r" % (ln, ver))
        if kind not in ("manifest", "tool", "doc", "src", "image"):
            sys.exit("!! VERSIONS.tsv 第 %d 行 kind 非法: %r" % (ln, kind))
        if kind == "image" and not re.fullmatch(r"[0-9a-f]{32}", target):
            sys.exit("!! VERSIONS.tsv 第 %d 行 image 的 target 应为 32hex md5: %r" % (ln, target))
        rows.append((name, ver, kind, target, note))
    if not rows:
        sys.exit("!! VERSIONS.tsv 为空")
    names = [r[0] for r in rows]
    dup = {n for n in names if names.count(n) > 1}
    if dup:
        sys.exit("!! VERSIONS.tsv 重名: %s" % sorted(dup))
    return rows


def version_of(name):
    """注册表查询单文件版本; 未登记抛 KeyError(deploy 端 fail-closed)。"""
    for n, v, *_ in load_registry():
        if n == name:
            return v
    raise KeyError(name)


def load_manifest_from_source():
    """从 deploy.py 源码文本解析 MANIFEST（不 import，避免 paramiko/device_local 依赖）。"""
    m = re.search(r"^MANIFEST = \[(.*?)^\]", open(os.path.join(HERE, "deploy.py"), encoding="utf-8").read(), re.S | re.M)
    if not m:
        sys.exit("!! 无法在 deploy.py 中定位 MANIFEST")
    out = []
    for line in m.group(1).splitlines():
        hit = MAN_RE.match(line)
        if hit:
            out.append((hit.group(1), hit.group(2)))
    if not out:
        sys.exit("!! MANIFEST 解析结果为空")
    return out


def check(fail=True):
    errs = []
    reg = load_registry()
    by_name = {r[0]: r for r in reg}
    manifest = load_manifest_from_source()

    # 1) manifest <-> registry 双向覆盖
    mset = {n for n, _ in manifest}
    reg_manifest = {r[0] for r in reg if r[2] == "manifest"}
    for n in sorted(mset - reg_manifest):
        errs.append("MANIFEST 成员缺版本行: %s" % n)
    for n in sorted(reg_manifest - mset):
        errs.append("注册表 manifest 行不在 MANIFEST: %s" % n)

    # 2) target 与 MANIFEST 远端路径一致（防部署路径漂移）
    mdest = dict(manifest)
    for name, ver, kind, target, note in reg:
        if kind == "manifest" and mdest.get(name) != target:
            errs.append("%s: 注册表 target(%s) != MANIFEST(%s)" % (name, target, mdest.get(name)))

    # 3) 文件存在；src 行要求同名产物同版本；image 行 md5 必须与磁盘一致
    for name, ver, kind, target, note in reg:
        if not os.path.isfile(os.path.join(REPO, name)):
            errs.append("文件不存在: %s" % name)
        if kind == "src":
            prod = target
            prow = by_name.get(prod)
            if prow is None:
                errs.append("src %s 的产物 %s 不在注册表" % (name, prod))
            elif prow[1] != ver:
                errs.append("源码/产物版本脱钩: %s=%s vs %s=%s" % (name, ver, prod, prow[1]))
        if kind == "image":
            p = os.path.join(REPO, name)
            if os.path.isfile(p):
                got = hashlib.md5(open(p, "rb").read()).hexdigest()
                if got != target:
                    errs.append("image md5 不符: %s 磁盘=%s 注册=%s" % (name, got, target))

    # 4) .sh 文件禁 CRLF（行尾纪律的静态关卡）
    for name, ver, kind, target, note in reg:
        if name.endswith((".sh", ".py")):
            data = open(os.path.join(REPO, name), "rb").read()
            if b"\r\n" in data:
                errs.append("CRLF 行尾: %s" % name)

    # 5) ARCHITECTURE.md 生成块 == render 输出
    if os.path.isfile(ARCH):
        text = open(ARCH, encoding="utf-8").read()
        if BEGIN in text:
            i, j = text.index(BEGIN), text.index(END)
            if text[i + len(BEGIN):j].strip("\n") != render_block(reg).strip("\n"):
                errs.append("ARCHITECTURE.md 版本表过期: 运行 `vercheck.py render`")
        else:
            errs.append("ARCHITECTURE.md 缺 VERCHECK 标记块")
    else:
        errs.append("docs/ARCHITECTURE.md 不存在")

    # 6) 性质分区: 登记行位置 <-> kind (v1.2)
    ZONE = {"manifest": ("gw/",), "src": ("gw/src/",), "doc": ("docs/",),
            "tool": ("tools/", "_drill_backup/", "install/"),   # v1.3: 安装套件脚本纳入工具区(RP102兼容轮)
            "image": ("_drill_backup/",)}
    for name, ver, kind, target, note in reg:
        if kind == "doc" and name == "README.md":
            continue
        if not name.startswith(ZONE[kind]):
            errs.append("性质分区: %s (kind=%s) 必须在 %s 下" % (name, kind, " 或 ".join(ZONE[kind])))
        if name.startswith("tools/oneoff/"):
            errs.append("一次性归档禁止登记: %s" % name)

    # 7) 全跟踪文件必须可归类: 登记 / 豁免区 / 根级白名单
    #    *_analysis/ 为动态发现(analysis 同类 RE 数据区, 免在代码里写死具体名)
    ROOT_OK = {".gitignore", ".gitattributes", "LICENSE", "README.md", "tools/VERSIONS.tsv"}
    FREE_ZONES = ("tools/oneoff/", "analysis/", "ref/", "docs/", "install/")
    FREE_ZONES += tuple(d + "/" for d in os.listdir(REPO)
                        if d.endswith("_analysis") and os.path.isdir(os.path.join(REPO, d)))
    try:
        ls = subprocess.run(["git", "ls-files"], capture_output=True, text=True,
                            cwd=REPO).stdout.split("\n")
    except Exception:
        ls = []
    regnames = {r[0] for r in reg}
    for f in ls:
        f = f.replace("\\", "/").strip()
        if not f or f in regnames or f in ROOT_OK or f.startswith(FREE_ZONES):
            continue
        errs.append("未归类跟踪文件(登记/oneoff/analysis/白名单均无): %s" % f)

    for e in errs:
        print("VERCHECK-FAIL: %s" % e)
    if errs:
        print("verdict: %d 项违规" % len(errs))
        if fail:
            sys.exit(1)
    else:
        print("verdict: OK (%d 个登记文件, MANIFEST %d 项全覆盖)" % (len(reg), len(manifest)))
    return not errs


def render_block(reg):
    lines = ["| 文件 | 版本 | 类别 | 设备路径 | 用途 |",
             "|---|---|---|---|---|"]
    for name, ver, kind, target, note in sorted(reg, key=lambda r: (r[2], r[0])):
        lines.append("| `%s` | **v%s** | %s | `%s` | %s |" % (name, ver, kind, target, note))
    return "\n".join(lines)


def render():
    reg = load_registry()
    text = open(ARCH, encoding="utf-8").read()
    block = BEGIN + "\n" + render_block(reg) + "\n" + END
    if BEGIN not in text:
        sys.exit("!! ARCHITECTURE.md 缺 %s 标记" % BEGIN)
    i, j = text.index(BEGIN), text.index(END) + len(END)
    open(ARCH, "w", encoding="utf-8", newline="\n").write(text[:i] + block + text[j:])
    print("rendered %d 行版本表 -> docs/ARCHITECTURE.md" % (len(reg) + 2))


def device():
    """对比设备 /data/gw/VERSIONS 与本地注册表（走 deploy 的 SSH 通道）。"""
    sys.path.insert(0, HERE)
    import deploy  # 需要 paramiko + device_local.py
    reg = {r[0]: r for r in load_registry()}
    c, ip = deploy.connect()
    print("device via %s" % ip)
    out = deploy.ssh_cmd(c, "cat /data/gw/VERSIONS 2>/dev/null")
    c.close()
    if not out.strip():
        sys.exit("!! 设备无 /data/gw/VERSIONS -- 先跑 deploy.py snapshot")
    drift = 0
    for line in out.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        name, dver, dmd5 = parts[0], parts[1], parts[2]
        row = reg.get(name)
        if row is None:
            print("device-only: %s" % name)
            continue
        mark = "OK" if dver == row[1] else "STALE(device=%s local=v%s)" % (dver, row[1])
        if dver != row[1]:
            drift += 1
        print("%-22s %s" % (name, mark))
    sys.exit(1 if drift else 0)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    {"check": check, "render": render, "device": device}[cmd]()
