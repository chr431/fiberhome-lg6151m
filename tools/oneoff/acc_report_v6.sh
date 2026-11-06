#!/bin/sh
# acc_report.sh v6 -- U-P 3-mount stealth acceptance (+ boot.log + origin breakdown)
NE=/data/gw/logs/ne_events.tsv
T0=$(cat /data/stealth/T0 2>/dev/null | cut -d' ' -f1)
echo "=== T5 STEALTH ACCEPTANCE v6 $(date) ==="
echo "uptime=$(cut -d' ' -f1 /proc/uptime)"
for m in " /lib/libc.so " " /bin/busybox " " /usr/sbin/wpad "; do
  echo "mount($m)=$(grep -c "$m" /proc/mounts)"
done
echo "mount( /usr/libexec/ip-full )=$(grep -c ' /usr/libexec/ip-full ' /proc/mounts) (expect 0)"
echo "disable=$([ -e /data/stealth/DISABLE ] && echo PRESENT || echo absent)"
md5sum /data/stealth/libc_p4.so /data/stealth/busybox_dyn_p6s /data/stealth/wpad_p5 2>/dev/null | cut -c1-8
echo "rc19_boot_logs=$(dmesg | grep -c 'RC19: stealth')"; dmesg | grep 'RC19: stealth' | tail -1
echo "boot_markers=$(wc -l < /data/stealth/boot.log 2>/dev/null)"
echo "--- boot.log tail"; tail -3 /data/stealth/boot.log 2>/dev/null
NOW=$(date +%s); T24=$((NOW-86400))
valid=$(grep -cE '^[0-9]+\t[0-9]+\t[^\t]+\tsig=' $NE)
cur=$(awk -v t=$T24 '$0 ~ /^[0-9]+\t/ && /sig=/ && $1>=t' $NE | wc -l)
echo "ledger valid=$valid last24h=$cur T0=$T0"
echo "--- deaths by exe (since T0)"
awk -v t=${T0:-0} '$0 ~ /^[0-9]+\t/ && /sig=/ && $1>=t' $NE | awk -F'\t' '{for(i=1;i<=NF;i++) if ($i ~ /^exe=/) {sub(/^exe=/,"",$i); print $i; break}}' | sort | uniq -c | sort -rn | head -10
echo "--- deaths by origin (since T0)"
awk -v t=${T0:-0} '$0 ~ /^[0-9]+	/ && /sig=/ && $1>=t' $NE | awk -F'	' '{for(i=1;i<=NF;i++) if ($i ~ /^origin=/) {sub(/^origin=/,"",$i); print $i; break}}' | sort | uniq -c | sort -rn
echo "--- recent 6 deaths (since T0)"
awk -v t=${T0:-0} '$0 ~ /^[0-9]+\t/ && /sig=/ && $1>=t' $NE | tail -6 | cut -c1-100
echo "--- services"
ps | grep -E 'hostapd|dnsmasq' | grep -v grep | wc -l
ip -4 addr show br-lan 2>/dev/null | grep -c inet
echo "--- known pre-existing families (not p6s): ip neigh (40 pre-T0), phy_info (2 pre-T0), gw static busybox"
echo "=== END ==="
