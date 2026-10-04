#!/usr/bin/env python3
"""serial_put.py v1.0 -- push ANY file (incl. binaries) to the CPE via the
serial console daemon (deploy.py push --serial is .sh-manifest-only).

  python tools/serial_put.py <local_file> <remote_path>
b64 line-by-line via serial_cmd, on-device decode, md5 gate, whole-file
retry x2 (2026-10-03 lesson: serial noise corrupts blind writes).
"""
import base64
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def scmd(cmd, t=30):
    r = subprocess.run([sys.executable, os.path.join(HERE, "serial_cmd.py"),
                        "--t", str(t), cmd], capture_output=True, text=True,
                       timeout=t + 40)
    return r.stdout


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    local, remote = sys.argv[1], sys.argv[2]
    data = open(local, "rb").read()
    want = hashlib.md5(data).hexdigest()
    b64 = base64.encodebytes(data).decode().splitlines()
    for attempt in range(1, 4):
        print("attempt %d: %d b64 lines" % (attempt, len(b64)))
        scmd("rm -f /tmp/sp.b64")
        for i, chunk in enumerate(b64):
            out = scmd("echo %s >>/tmp/sp.b64" % chunk, 25)
            if i % 25 == 0:
                print("  %d/%d" % (i + 1, len(b64)))
        out = scmd("(openssl base64 -d </tmp/sp.b64 || base64 -d </tmp/sp.b64) > %s 2>/tmp/sp.err; md5sum %s"
                   % (remote, remote), 30)
        if want in out:
            print("OK %s -> %s (md5 %s)" % (local, remote, want))
            scmd("chmod +x %s 2>/dev/null" % remote)
            return 0
        print("MISMATCH; tail: %r" % out[-120:])
    sys.exit(5)


if __name__ == "__main__":
    sys.exit(main())
