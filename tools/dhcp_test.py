#!/usr/bin/env python3
import sys, time
sys.path.insert(0, r"D:\Repo\lg6151m")
import device_local as D
import paramiko
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.3.75', port=22, username=D.TOOR_USER, password=D.TOOR_PASS,
          timeout=12, allow_agent=False, look_for_keys=False)
def run(cmd, t=25):
    _, o, e = c.exec_command(cmd, timeout=t)
    return (o.read().decode('utf-8', 'replace') + e.read().decode('utf-8', 'replace')).strip()
# DHCP on the bridge (eth0's current L2 home)
print(run("dnsmasq -p 0 -i br-lan -I lo -F 192.168.8.100,192.168.8.200,255.255.255.0,12h "
          "--dhcp-option=3,192.168.8.1 --dhcp-option=6,192.168.8.1 "
          "-x /var/run/dnsmasd_br.pid 2>&1; echo DNSMASQ=$?; ps | grep -c dnsmasq"))
print(run("ip addr show br-lan | grep inet"))
c.close()
