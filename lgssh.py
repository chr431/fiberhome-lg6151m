#!/usr/bin/env python3
"""Reusable SSH helper for the rooted LG6151M.
Usage:
  python lgssh.py "command"          run a command, print output
  python lgssh.py -s remote local    sftp get
"""
import os
import sys

import paramiko

# 凭证从环境变量读取(LG_HOST/LG_TOOR_USER/LG_TOOR_PASS), 缺省回退 device_local.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    import device_local as _D
except ImportError:
    _D = None
HOST = os.environ.get("LG_HOST") or getattr(_D, "HOST", "192.168.8.1")
USER = os.environ.get("LG_TOOR_USER") or getattr(_D, "TOOR_USER", "toor")
PW = os.environ.get("LG_TOOR_PASS") or getattr(_D, "TOOR_PASS", "")


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=22, username=USER, password=PW, timeout=10,
              allow_agent=False, look_for_keys=False)
    return c


def run(c, cmd, timeout=60):
    _, out, err = c.exec_command(cmd, timeout=timeout)
    o = out.read().decode("utf-8", "replace")
    e = err.read().decode("utf-8", "replace")
    return o + (("\n[stderr] " + e) if e.strip() else "")


def main():
    c = connect()
    try:
        if len(sys.argv) >= 3 and sys.argv[1] == "-s":
            sftp = c.open_sftp()
            sftp.get(sys.argv[2], sys.argv[3])
            print(f"got {sys.argv[2]} -> {sys.argv[3]}")
        else:
            print(run(c, sys.argv[1] if len(sys.argv) > 1 else "id"))
    finally:
        c.close()


if __name__ == "__main__":
    main()
