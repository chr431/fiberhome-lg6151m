#!/usr/bin/env python3
"""Pull a file from the device via SSH exec streaming (no SFTP support in this dropbear).
Usage: python pull_file.py <remote_path> <local_path>
"""
import sys
import lgssh


def pull(c, remote, local):
    _, out, err = c.exec_command("cat " + remote)
    total = 0
    with open(local, "wb") as f:
        while True:
            chunk = out.channel.recv(1024 * 512)
            if not chunk:
                break
            f.write(chunk)
            total += len(chunk)
    e = err.read()
    if e:
        print("stderr:", e.decode()[:200])
    return total


if __name__ == "__main__":
    c = lgssh.connect()
    try:
        n = pull(c, sys.argv[1], sys.argv[2])
        print(f"pulled {n} bytes -> {sys.argv[2]}")
    finally:
        c.close()
