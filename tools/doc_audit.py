#!/usr/bin/env python3
"""doc_audit.py -- 文档结论版本绑定与漂移审计 (L16, 2026-10-05).

背景: 160MHz 结论漂移数周 —— wifi_up.sh v1.10 已修复, 文档仍写"未解锁"。
根因: 结论没有版本锚点, 代码前进了没人知道哪些结论需要复审。
机制 (docs/CONCLUSIONS.tsv 为唯一事实源):

  1. 台账 <-> 文档内联标记 <!--CLM:id--> 双向一一对应
     (结论被删/改词不影响标记定位; 台账删行则标记成孤儿 -> 违规)
  2. 代码版本绑定: 每条结论声明 code_evidence "file>=ver";
     - 当前版本 < 声明 -> CODE-REGRESSED (证据已不成立)
     - 当前版本 != 验证 commit 时版本 -> 代码前进了:
         有 bound_tests 且测试仍在 selftest.py -> test-guarded (放行, 测试会抓回归)
         否则 -> STALE-CODE (需人工复审或 refresh)
  3. bound_tests 必须仍存在于 tools/selftest.py -> TEST-MISSING
  4. 能力否定类断言扫描 ("未解锁|不可用|不可能|不支持|未实现"):
     命中行无 CLM 标记 -> UNREGISTERED-CLAIM (正是 160MHz 漂移的句型)
  5. ARCHITECTURE.md 结论表生成块 (CLMAUDIT) 必须与 render 输出逐字节一致

Usage:
  python tools/doc_audit.py audit            # 审计 (exit 1 = 有违规; deploy push 前置)
  python tools/doc_audit.py render           # 重新生成 ARCHITECTURE.md 结论表
  python tools/doc_audit.py refresh <id>     # 复审后更新验证锚点(commit/date)
  python tools/doc_audit.py list             # 台账一览
"""
import datetime
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import vercheck  # noqa: E402  (registry single source)

TSV = os.path.join(REPO, "docs", "CONCLUSIONS.tsv")
ARCH = os.path.join(REPO, "docs", "ARCHITECTURE.md")
SELFTEST = os.path.join(REPO, "tools", "selftest.py")
SCANNED_DOCS = ("docs/FINDINGS.md", "docs/VENDOR_MAP.md", "docs/FEATURE_MATRIX.md")
BEGIN = "<!--CLMAUDIT:BEGIN (generated from docs/CONCLUSIONS.tsv; `doc_audit.py render`)-->"
END = "<!--CLMAUDIT:END-->"

CLM_RE = re.compile(r"<!--CLM:([A-Z0-9][A-Z0-9-]*)-->")
PHRASES = re.compile(r"未解锁|不可用|不可能|不支持|未实现")
COLS = ["id", "doc", "status", "code_evidence", "bound_tests",
        "verified_commit", "verified_date", "note"]


def load_ledger():
    """-> list[dict]; 台账格式错误立即失败 (fail closed)."""
    rows = []
    seen = set()
    for ln, line in enumerate(open(TSV, encoding="utf-8"), 1):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != len(COLS):
            sys.exit("!! CONCLUSIONS.tsv 第 %d 行应为 %d 列(tab): %r" % (ln, len(COLS), line))
        r = dict(zip(COLS, parts))
        if r["id"] in seen:
            sys.exit("!! 重复 id: %s" % r["id"])
        if r["status"] not in ("verified", "assumed", "historical"):
            sys.exit("!! %s: 非法 status %r" % (r["id"], r["status"]))
        if not re.match(r"^[0-9a-f]{7,40}$", r["verified_commit"]):
            sys.exit("!! %s: verified_commit 应为 git hash: %r" % (r["id"], r["verified_commit"]))
        seen.add(r["id"])
        rows.append(r)
    if not rows:
        sys.exit("!! 台账为空")
    return rows


def doc_markers(extra_docs=()):
    """-> {doc: [(lineno, id)]}; 扫描 docs/*.md + 台账引用的其他文档(如 install/README.md)."""
    out = {}
    rels = []
    ddir = os.path.join(REPO, "docs")
    for fn in sorted(os.listdir(ddir)):
        if fn.endswith(".md"):
            rels.append("docs/" + fn)
    for rel in extra_docs:            # v1.1: 台账 doc 字段可指向 docs/ 之外
        if rel not in rels:
            rels.append(rel)
    for rel in rels:
        path = os.path.join(REPO, rel)
        if not os.path.isfile(path):
            continue
        hits = []
        for i, line in enumerate(open(path, encoding="utf-8"), 1):
            for m in CLM_RE.finditer(line):
                hits.append((i, m.group(1)))
        if hits:
            out[rel] = hits
    return out


def selftest_tests():
    """-> set(selftest 中注册的测试名)."""
    text = open(SELFTEST, encoding="utf-8").read()
    return set(re.findall(r'@test\("([^"]+)"\)', text))


def git_ver_at(commit, name):
    """注册表中某文件在指定 commit 时的版本; 查不到 -> None."""
    try:
        t = subprocess.run(["git", "show", "%s:tools/VERSIONS.tsv" % commit],
                           capture_output=True, text=True, cwd=REPO, timeout=15).stdout
    except Exception:
        return None
    for line in t.splitlines():
        parts = line.split("\t")
        if parts and parts[0] == name:
            return parts[1]
    return None


def head_short():
    return subprocess.run(["git", "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True, cwd=REPO).stdout.strip()


def audit(verbose=True):
    errs, infos = [], []
    rows = load_ledger()
    marks = doc_markers(extra_docs={r['doc'] for r in rows})
    tests = selftest_tests()
    reg = {r[0]: r[1] for r in vercheck.load_registry()}

    # 1) 台账 -> 标记 (每行结论在其 doc 中恰好出现一次)
    by_doc = {}
    for r in rows:
        by_doc.setdefault(r["doc"], set()).add(r["id"])
        if not os.path.isfile(os.path.join(REPO, r["doc"])):
            errs.append("%s: 文档不存在 %s" % (r["id"], r["doc"]))
            continue
        ids = [i for _, i in marks.get(r["doc"], []) if i == r["id"]]
        if len(ids) == 0:
            errs.append("%s: 文档 %s 缺 <!--CLM:%s--> 标记" % (r["id"], r["doc"], r["id"]))
        elif len(ids) > 1:
            errs.append("%s: 标记出现 %d 次 (应 1)" % (r["id"], len(ids)))

    # 2) 标记 -> 台账 (孤儿标记)
    led_ids = {r["id"] for r in rows}
    for doc, hits in sorted(marks.items()):
        for _, cid in hits:
            if cid not in led_ids:
                errs.append("孤儿标记 %s @ %s (台账无此行)" % (cid, doc))

    # 3) 代码版本绑定 + 测试存在性
    for r in rows:
        if r["status"] == "historical":
            continue  # 存档结论不再绑代码
        ev = [e.strip() for e in r["code_evidence"].split(",") if e.strip() and e.strip() != "-"]
        bt = [t.strip() for t in r["bound_tests"].split(",") if t.strip() and t.strip() != "-"]
        for t in bt:
            if t not in tests:
                errs.append("%s: TEST-MISSING selftest 无测试 %r" % (r["id"], t))
        for e in ev:
            m = re.match(r"^(.+?)>=(\d+\.\d+)$", e)
            if not m:
                errs.append("%s: 证据格式非法 %r (应为 file>=N.N)" % (r["id"], e))
                continue
            f, want = m.group(1), m.group(2)
            cur = reg.get(f)
            if cur is None:
                errs.append("%s: %s 不在版本注册表" % (r["id"], f))
                continue
            if tuple(map(int, cur.split("."))) < tuple(map(int, want.split("."))):
                errs.append("%s: CODE-REGRESSED %s 当前 v%s < 证据要求 v%s"
                            % (r["id"], f, cur, want))
                continue
            at = git_ver_at(r["verified_commit"], f)
            if at is not None and at != cur:
                guarded = bool(bt) and all(t in tests for t in bt)
                if guarded:
                    infos.append("%s: 代码已前进 %s v%s->v%s, 测试护栏在 (%s)"
                                 % (r["id"], f, at, cur, bt[0]))
                else:
                    errs.append("%s: STALE-CODE %s 验证时 v%s, 现 v%s, 无测试护栏 -- 复审后 refresh"
                                % (r["id"], f, at, cur))

    # 4) 未登记的能力否定类断言
    #    多行结论: 标记在结论首行, 续行(非新块起点)归属上方最近的标记
    BLOCK_START = re.compile(r"^\s*(?:[-*+]\s|\d+\.\s|#|\||>)")
    for doc in SCANNED_DOCS:
        p = os.path.join(REPO, doc)
        if not os.path.isfile(p):
            continue
        lines = open(p, encoding="utf-8").readlines()
        for i, line in enumerate(lines):
            if not PHRASES.search(line) or CLM_RE.search(line):
                continue
            covered = False
            for back in range(i - 1, max(i - 6, -1), -1):
                if CLM_RE.search(lines[back]):
                    covered = True  # 期间无新块起点则归属该标记
                    break
                if BLOCK_START.match(lines[back]):
                    break
            if not covered:
                errs.append("UNREGISTERED-CLAIM %s:%d %s"
                            % (doc, i + 1, line.strip()[:60]))

    # 5) ARCHITECTURE.md 生成块一致性
    if os.path.isfile(ARCH):
        text = open(ARCH, encoding="utf-8").read()
        if BEGIN in text and END in text:
            i, j = text.index(BEGIN), text.index(END)
            if text[i + len(BEGIN):j].strip("\n") != render_block(rows).strip("\n"):
                errs.append("ARCHITECTURE.md 结论表过期: 运行 `doc_audit.py render`")
        # 无块不算错 (render 后才强制), 但 deploy 链会先 render
    if verbose:
        for s in infos:
            print("  info: %s" % s)
        for e in errs:
            print("DOCAUDIT-FAIL: %s" % e)
        print("verdict: %s (%d 条结论, %d 提示, %d 违规)"
              % ("OK" if not errs else "FAIL", len(rows), len(infos), len(errs)))
    return not errs


def render_block(rows):
    st = {"verified": "✅实证", "assumed": "⚠️推断", "historical": "📜存档"}
    lines = ["| 结论 | 状态 | 代码证据 | 测试护栏 | 验证锚点 | 说明 |",
             "|---|---|---|---|---|---|"]
    for r in rows:
        ev = r["code_evidence"] if r["code_evidence"] != "-" else "—"
        bt = r["bound_tests"] if r["bound_tests"] != "-" else "—"
        lines.append("| `%s`@%s | %s | `%s` | %s | %s@%s | %s |" % (
            r["id"], r["doc"].replace("docs/", ""), st[r["status"]],
            ev, bt if bt != "—" else "—",
            r["verified_commit"][:7], r["verified_date"], r["note"]))
    return "\n".join(lines)


def render():
    rows = load_ledger()
    text = open(ARCH, encoding="utf-8").read()
    block = "\n%s\n\n%s\n\n%s\n" % (BEGIN, render_block(rows), END)
    if BEGIN in text and END in text:
        i, j = text.index(BEGIN), text.index(END) + len(END)
        text = text[:i] + block.strip("\n") + text[j:]
    else:
        text = text.rstrip("\n") + "\n\n## 结论台账 (审计生成, 勿手改)\n\n" + block
    open(ARCH, "w", encoding="utf-8", newline="").write(text)
    print("rendered %d 条结论 -> docs/ARCHITECTURE.md" % len(rows))


def refresh(cid):
    rows = load_ledger()
    hit = [r for r in rows if r["id"] == cid]
    if not hit:
        sys.exit("!! 无此 id: %s (list 查看)" % cid)
    today = datetime.date.today().isoformat()
    head = head_short()
    lines_out = []
    for line in open(TSV, encoding="utf-8"):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == len(COLS) and parts[0] == cid:
            parts[5], parts[6] = head, today
            lines_out.append("\t".join(parts))
        else:
            lines_out.append(line.rstrip("\n"))
    open(TSV, "w", encoding="utf-8", newline="").write("\n".join(lines_out) + "\n")
    print("%s -> verified @%s %s (记得 render)" % (cid, head, today))


def main():
    args = sys.argv[1:]
    if not args or args[0] == "audit":
        sys.exit(0 if audit() else 1)
    if args[0] == "render":
        render()
        return 0
    if args[0] == "refresh" and len(args) > 1:
        refresh(args[1])
        return 0
    if args[0] == "list":
        for r in load_ledger():
            print("  %-22s %-8s %-28s %s" % (r["id"], r["status"],
                                             r["code_evidence"], r["note"][:40]))
        return 0
    print(__doc__)
    return 1


if __name__ == "__main__":
    sys.exit(main())
