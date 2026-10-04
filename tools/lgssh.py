#!/usr/bin/env python3
"""SSH helper for the rooted LG6151M (works on stock via rearm.py or on our
custom slot-A firmware where toor is baked in).

Usage:
  python lgssh.py "command"          run a command as uid=0
"""
import os
import sys

import paramiko

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import device_local as D

HOST = getattr(D, "HOST", "192.168.8.1")


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, port=22, username=D.TOOR_USER, password=D.TOOR_PASS, timeout=10,
              allow_agent=False, look_for_keys=False)
    return c


def run(c, cmd, timeout=60):
    _, out, err = c.exec_command(cmd, timeout=timeout)
    o = out.read().decode("utf-8", "replace")
    e = err.read().decode("utf-8", "replace")
    return o + (("\n[stderr] " + e) if e.strip() else "")


if __name__ == "__main__":
    c = connect()
    try:
        print(run(c, sys.argv[1] if len(sys.argv) > 1 else "id"))
    finally:
        c.close()
