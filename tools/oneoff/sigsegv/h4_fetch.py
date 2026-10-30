#!/usr/bin/env python3
"""h4_fetch.py -- batch-fetch /data/repro/h4_*.bin over ONE ssh connection.

dropbear overloads on rapid new connections; one connection + sequential cat
is reliable. Verifies size (32888) and retries.
"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.abspath(os.path.join(HERE, "..", "..")))
import lgssh  # noqa: E402

NAMES = "tmpfiles/an4/h4_names.txt"
OUT = "tmpfiles/an4"
SIZE = 32888

def main():
    names = [l.strip() for l in open(NAMES) if l.strip()]
    todo = []
    for p in names:
        b = os.path.basename(p)
        q = os.path.join(OUT, b)
        if os.path.exists(q) and os.path.getsize(q) == SIZE:
            continue
        todo.append((p, q))
    print("todo", len(todo), flush=True)
    if not todo:
        return
    c = lgssh.connect()
    ok = fail = 0
    try:
        for i, (remote, local) in enumerate(todo):
            data = b""
            for attempt in range(3):
                try:
                    _, out, err = c.exec_command("cat %s" % remote, timeout=60)
                    data = out.read()
                    if len(data) == SIZE:
                        break
                except Exception as e:
                    print("retry", remote, e, flush=True)
                time.sleep(1)
            if len(data) == SIZE:
                with open(local, "wb") as f:
                    f.write(data)
                ok += 1
            else:
                fail += 1
                print("FAIL", remote, len(data), flush=True)
            if (i + 1) % 10 == 0:
                print("progress", i + 1, "/", len(todo), "ok", ok, "fail", fail, flush=True)
    finally:
        c.close()
    print("done ok", ok, "fail", fail, flush=True)

if __name__ == "__main__":
    main()
