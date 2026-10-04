#!/usr/bin/env python3
"""Rollback to v2 via staged-append method (battle-tested), uplink-side SSH."""
import paramiko
import sys
import time

sys.path.insert(0, "D:/Repo/lg6151m")
import device_local as D

BS = chr(92)
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(os.environ.get("LG_HOST", D.HOST), port=22, username=D.TOOR_USER, password=D.TOOR_PASS,
          timeout=10, allow_agent=False, look_for_keys=False)


def run(cmd, t=15):
    _, o, e = c.exec_command(cmd, timeout=t)
    return (o.read().decode() + e.read().decode())


parts = [["016", "000", "001"], ["000", "000", "017"], ["000", "001", "002", "000"]]
run("rm -f /tmp/bc.bin")
for i, p in enumerate(parts):
    octals = BS + BS.join(p)
    op = ">" if i == 0 else ">>"
    r = run(f"echo -en '{octals}' {op} /tmp/bc.bin")
    print(f"stage{i}: {r.strip()[:40]}")
print("verify staged:", run("hexdump -C /tmp/bc.bin").strip())
print("dd:", run("dd if=/tmp/bc.bin of=/dev/mmcblk0p1 bs=1 seek=2060").strip())
print("VERIFY misc:", run("dd if=/dev/mmcblk0p1 bs=1 skip=2060 count=10 2>/dev/null | hexdump -C | head -1").strip())
run("sync")
print("rebooting...")
run("reboot", t=3)
c.close()
