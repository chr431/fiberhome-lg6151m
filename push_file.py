#!/usr/bin/env python3
"""Push a local file to the device via SSH (stdin -> cat > remote).
Usage: python push_file.py <local> <remote>"""
import sys
import lgssh


def push(c, local, remote):
    _, out, err = c.exec_command("cat > " + remote)
    with open(local, "rb") as f:
        while True:
            chunk = f.read(512 * 1024)
            if not chunk:
                break
            out.channel.sendall(chunk)
    out.channel.shutdown_write()
    e = err.read().decode()[:200]
    o = out.read().decode()[:200]
    if e:
        print("stderr:", e)
    return o


if __name__ == "__main__":
    c = lgssh.connect()
    try:
        r = push(c, sys.argv[1], sys.argv[2])
        print("pushed", sys.argv[1], "->", sys.argv[2], r)
    finally:
        c.close()
