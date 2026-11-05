#!/usr/bin/env python3
"""ud1_pull.py -- binary-safe device pull (no pty, no text decode).

Usage: python -I ud1_pull.py <remote_path> <local_path>
Reuses tools/lgssh.py's credential chain and connect(); reads stdout as bytes.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, TOOLS)
import lgssh  # noqa: E402

def main():
    if len(sys.argv) != 3:
        print("usage: ud1_pull.py <remote> <local>")
        return 2
    remote, local = sys.argv[1], sys.argv[2]
    c = lgssh.connect()
    try:
        _, out, err = c.exec_command("cat '%s'" % remote, timeout=300)
        data = out.read()
        e = err.read()
        if e:
            sys.stderr.write(e.decode("utf-8", "replace"))
    finally:
        c.close()
    with open(local, "wb") as f:
        f.write(data)
    print("pulled %s -> %s (%d bytes)" % (remote, local, len(data)))
    return 0

if __name__ == "__main__":
    sys.exit(main())
