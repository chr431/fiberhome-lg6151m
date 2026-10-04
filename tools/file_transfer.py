#!/usr/bin/env python3
"""File transfer helpers for the rooted device (its dropbear has no SFTP).

  python file_transfer.py pull <remote> <local>   (SSH exec + raw channel recv)
  python file_transfer.py push <local> <remote>   (SSH exec + stdin -> cat)

NOTE for Git Bash users: prefix MSYS_NO_PATHCONV=1 so /tmp/... is not
rewritten to a Windows path.
"""
import hashlib
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lgssh


def pull(c, remote, local):
    _, out, err = c.exec_command("cat " + remote)
    h, total = hashlib.md5(), 0
    with open(local, "wb") as f:
        while True:
            chunk = out.channel.recv(512 * 1024)
            if not chunk:
                break
            f.write(chunk)
            h.update(chunk)
            total += len(chunk)
    e = err.read().decode()[:200]
    if e:
        print("stderr:", e)
    return total, h.hexdigest()


def push(c, local, remote):
    if remote.endswith((".sh", ".extend")) and b"
" in open(local, "rb").read(2048):
        print("REFUSED: %s has CRLF line endings (device sh breaks) - fix locally first" % local)
        sys.exit(1)
    _, out, err = c.exec_command("cat > " + remote)
    with open(local, "rb") as f:
        while True:
            chunk = f.read(512 * 1024)
            if not chunk:
                break
            out.channel.sendall(chunk)
    out.channel.shutdown_write()
    e = err.read().decode()[:200]
    if e:
        print("stderr:", e)


if __name__ == "__main__":
    c = lgssh.connect()
    try:
        if sys.argv[1] == "pull":
            n, md5 = pull(c, sys.argv[2], sys.argv[3])
            print(f"pulled {n} bytes (md5 {md5})")
        else:
            push(c, sys.argv[2], sys.argv[3])
            print("pushed", sys.argv[2], "->", sys.argv[3])
    finally:
        c.close()
