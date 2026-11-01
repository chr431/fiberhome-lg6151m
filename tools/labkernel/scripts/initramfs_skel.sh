#!/bin/bash
# initramfs_skel.sh -- build the lab-kernel initramfs skeleton (runs inside
# the prepared WSL tree, see tools/labkernel/README.md).
# Layout + static busybox + applet symlinks + /dev console nodes (v2 fix F1)
# + v3 helper scripts. Payload binaries (busybox/vsurv4/scanary) are md5-
# pinned inputs -- see README.
# Usage: initramfs_skel.sh <initramfs-dir> <busybox.bin> <payload-dir>
#   payload-dir must contain vsurv4 and scanary (static aarch64, musl).
set -eu
INITRD="${1:?usage: initramfs_skel.sh <initramfs-dir> <busybox.bin> <payload-dir>}"
BB="${2:?busybox binary missing}"
PAYLOAD="${3:?payload dir missing (vsurv4 + scanary)}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "== 1. skeleton =="
mkdir -p "$INITRD"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,data/repro,root,mnt,etc,modules}

echo "== 2. busybox (static aarch64) + applets =="
cp "$BB" "$INITRD/bin/busybox"
chmod 755 "$INITRD/bin/busybox"
for a in sh mount umount cat echo ls ps kill sleep mkdir mknod uname cut awk grep \
         wc zcat date free dd head tail cp mv rm ln read cmp hexdump less sync \
         sysrq sed insmod rmmod lsmod ifconfig ip route ping vi false true \
         pidof basename dirname test [ setsid cttyhack blkid; do
    ln -sf busybox "$INITRD/bin/$a"
done
ln -sf ../bin/busybox "$INITRD/sbin/poweroff"
ln -sf ../bin/busybox "$INITRD/sbin/reboot"

echo "== 3. device nodes (v2 fix F1: kernel opens /dev/console for PID1) =="
mknod -m 600 "$INITRD/dev/console" c 5 1
mknod -m 666 "$INITRD/dev/null" c 1 3

echo "== 4. canary payloads (md5-pinned, see README) =="
cp -f "$PAYLOAD/vsurv4"  "$INITRD/vsurv4";  chmod 755 "$INITRD/vsurv4"
cp -f "$PAYLOAD/scanary" "$INITRD/scanary"; chmod 755 "$INITRD/scanary"

echo "== 5. /init + helpers (v3 current) =="
cp -f "$HERE/lab_init_v3.sh" "$INITRD/init";        chmod 755 "$INITRD/init"
cp -f "$HERE/netup.sh"       "$INITRD/bin/netup";   chmod 755 "$INITRD/bin/netup"
cp -f "$HERE/romount.sh"     "$INITRD/bin/romount"; chmod 755 "$INITRD/bin/romount"
cp -f "$HERE/kjump.sh"       "$INITRD/bin/kjump";   chmod 755 "$INITRD/bin/kjump"
cp -f "$HERE/scanary_report.sh" "$INITRD/bin/scanary_report"; chmod 755 "$INITRD/bin/scanary_report"
md5sum "$INITRD/init" "$INITRD/bin/"{netup,romount,kjump}
echo SKELETON_DONE
