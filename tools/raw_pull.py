#!/usr/bin/env python3
"""raw_pull.py -- binary-safe file pull from the device (dropbear has no SFTP;
lgssh's run() decodes text, so raw bytes need a direct channel read).
usage: python raw_pull.py <remote> <local>   (repeat args for pairs)"""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lgssh  # reuses PIN/auth/device_local

pairs = sys.argv[1:]
assert len(pairs) % 2 == 0, "even args: remote local ..."
c = lgssh.connect()
try:
    for i in range(0, len(pairs), 2):
        remote, local = pairs[i], pairs[i + 1]
        ch = c.get_transport().open_session()
        ch.exec_command("cat '%s'" % remote)
        buf = b""
        while True:
            d = ch.recv(65536)
            if not d:
                break
            buf += d
        rc = ch.recv_exit_status()
        with open(local, "wb") as f:
            f.write(buf)
        print("%-46s -> %s (%d bytes, rc=%d)" % (remote, local, len(buf), rc))
finally:
    c.close()
