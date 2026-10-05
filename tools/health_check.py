#!/usr/bin/env python3
"""health_check.py -- v4.1 全系统体检 (SSH via lgssh/device_local).
覆盖: 身份/槽位/bootctrl/服务/WiFi/5G/外网/资源/温度/存储/数据载荷/日志错误."""
import sys, os, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lgssh  # uses env or device_local

CHECKS = [
    ("identity",   "uname -r; uptime; cat /proc/cmdline | tr ' ' '\\n' | grep -E 'root=|bootslot|init='"),
    ("release",    "cat /etc/release | head -2; grep -c 'v3:' /etc/init.d/rcS"),
    ("bootctrl",   "hexdump -C -s 2060 -n 16 /dev/mmcblk0p1 | head -2"),
    ("services",   "netstat -tln 2>/dev/null | tail -n +3"),
    ("procs",      "ps w | grep -E 'dropbear|httpd|dnsmasq|hostapd|access|extend|healthdog' | grep -v grep"),
    ("wifi",       "iwinfo ra0 info 2>&1 | head -6; echo ---; iwinfo rai0 info 2>&1 | head -6"),
    ("wifi_assoc", "iwinfo ra0 assoclist 2>&1 | head -4; iwinfo rai0 assoclist 2>&1 | head -4"),
    ("ssid",       "grep -E '^ssid' /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf 2>&1"),
    ("wan5g",      "ifconfig ccmni2 2>&1 | head -2; cat /proc/net/dev | grep ccmni"),
    ("internet",   "ping -c 3 -W 3 223.5.5.5 2>&1 | tail -2; ping -c 3 -W 3 www.baidu.com 2>&1 | tail -2"),
    ("resources",  "free | head -3; cat /proc/loadavg; df -h | grep -vE 'tmpfs|overlayfs:/rom' | head -6"),
    ("thermal",    "for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/temp 2>/dev/null); [ -n \"$t\" ] && echo \"$z: $t\"; done | head -8"),
    ("storage",    "mount | grep -E 'mmcblk0p(26|39|46)|squashfs' | head -4"),
    ("data",       "ls /data | head -10; ls /data/gw | wc -l; md5sum /data/rc.extend.sh 2>/dev/null"),
    ("markers",    "ls /tmp/rcS.done /tmp/boot.done 2>&1; cat /tmp/deploy.log 2>/dev/null | tail -3"),
    ("logerrs",    "dmesg 2>/dev/null | grep -iE 'error|fail|oops|panic' | grep -viE 'WiFi@ERROR.CFG|pAd not start|i2c.*timeout|error station' | tail -8"),
    ("ntp",        "date; grep . /etc/TZ 2>/dev/null"),
    ("fw_ver",     "cat /data/gw/VERSIONS 2>/dev/null | head -5; ls /data/gw/MODE.fh 2>&1"),
]

def main():
    c = lgssh.connect()
    print("== v4.1 health check via %s ==" % lgssh.HOST)
    for name, cmd in CHECKS:
        try:
            out = lgssh.run(c, cmd)
        except Exception as e:
            out = "!! %r" % e
        print("\n=== %s ===" % name)
        print(out.rstrip() if out.strip() else "(empty)")
    c.close()
    print("\n== health check done ==")

if __name__ == "__main__":
    main()
