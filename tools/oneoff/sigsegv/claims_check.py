#!/usr/bin/env python3
"""claims_check.py -- validate docs/SIGSEGV/01_CLAIMS.tsv.

Rules:
  - exactly 9 columns
  - unique C-xxx ids
  - grade in E0/E1/E2/E3/E4/X/?
  - status in active/open/retracted/superseded/blocked
  - supersedes points at an existing id (comma-separated)
  - date is YYYY-MM-DD
Exit 1 on any violation; print a summary.
"""
import csv
import re
import sys

PATH = "docs/SIGSEGV/01_CLAIMS.tsv"
GRADES = {"E0", "E1", "E2", "E3", "E4", "X", "?"}
STATUS = {"active", "open", "retracted", "superseded", "blocked"}
DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def main():
    rows = list(csv.reader(open(PATH, encoding="utf-8"), delimiter="\t"))
    if not rows:
        print("empty")
        return 1
    header = rows[0]
    if header != ["id", "family", "claim", "evidence", "grade", "date",
                  "status", "supersedes", "notes"]:
        print("bad header:", header)
        return 1
    ids = set()
    errors = []
    for r in rows[1:]:
        if len(r) != 9:
            errors.append("column count %d: %s" % (len(r), r[:1]))
            continue
        cid, family, claim, evidence, grade, date, status, sup, notes = r
        if cid in ids:
            errors.append("duplicate id: %s" % cid)
        ids.add(cid)
        if grade not in GRADES:
            errors.append("%s: bad grade %s" % (cid, grade))
        if status not in STATUS:
            errors.append("%s: bad status %s" % (cid, status))
        if not DATE.match(date):
            errors.append("%s: bad date %s" % (cid, date))
    for r in rows[1:]:
        if len(r) != 9:
            continue
        cid, sup = r[0], r[7]
        for ref in [x.strip() for x in sup.split(",") if x.strip()]:
            if ref not in ids:
                errors.append("%s: supersedes unknown %s" % (cid, ref))
    print("claims:", len(rows) - 1, "ids:", len(ids),
          "active:", sum(1 for r in rows[1:] if len(r) == 9 and r[6] == "active"),
          "retracted:", sum(1 for r in rows[1:] if len(r) == 9 and r[6] == "retracted"))
    if errors:
        print("ERRORS:")
        for e in errors:
            print("  ", e)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
