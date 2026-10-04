#!/usr/bin/env python3
import sys
sys.path.insert(0, r"D:\Repo\lg6151m")
import device_local as D
import paramiko
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.3.75', port=22, username=D.TOOR_USER, password=D.TOOR_PASS,
          timeout=12, allow_agent=False, look_for_keys=False)
cmd = ('cat /sys/class/net/eth0/statistics/rx_packets; '
       'ip -s link show eth0 | grep -A1 RX | tail -1; '
       'cat /proc/v3_probe | head -3')
_, o, e = c.exec_command(cmd, timeout=20)
print(o.read().decode('utf-8', 'replace'))
c.close()
