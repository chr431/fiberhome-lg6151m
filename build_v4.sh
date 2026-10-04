#!/bin/sh
# build_v4.sh -- v3 rebase onto RP0103 (2026-10-04)
# Base: slot B rootfs (pristine RP0103, loop-mounted from /dev/mmcblk0p39)
# Applies the COMPLETE verified v3 customization inventory:
#   A. toor account (passwd+shadow)          [base-tree custom, beyond build_v3]
#   B. dropbear uci config                    [base-tree custom]
#   C. rc.local: dropbear + iptables allow    [base-tree custom]
#   D. rcS surgical edits (sysmgr/mipc_wan_cli off, rcS.done marker)
#   E. login.sh unconditional getty ttyS0
#   F. zz_data_hook (from /data/build/rootfs) as S98
#   G. babysitter baked-in + preinit hook + boot.done marker
# Flash: boot_a <- boot_b (RP0103 kernel), rootfs_a <- v4 image, tail zeroed.
# Rollback: slot B = pristine RP0103 stock; lk_flip2 verified working on new LK.
set -e
B=/data/build
R=$B/rootfs_v4
SQ=/tmp/st/squashfs-tools-mksquashfs_4.6.1-1_aarch64_generic/ex/usr/sbin/mksquashfs
LIBS=/tmp/st/liblzma_5.4.6-1_aarch64_generic/ex/usr/lib:/tmp/st/libzstd_1.5.2-2_aarch64_generic/ex/usr/lib

echo "== 1. copy RP0103 tree from slot B"
mkdir -p /mnt/rp103
grep -q ' /mnt/rp103 ' /proc/mounts || mount -t squashfs -o loop,ro /dev/mmcblk0p39 /mnt/rp103
rm -rf $R
cp -a /mnt/rp103 $R
echo "tree: $(find $R -type f | wc -l) files"

echo "== 2. toor account"
grep -q '^toor:' $R/etc/passwd || echo 'toor:x:0:0:root:/root:/bin/ash' >> $R/etc/passwd
grep -q '^toor:' $R/etc/shadow || echo 'toor:$1$fhlg6151$ATwrqyUmHdLBTfkKhBmjA/:19953:0:99999:7:::' >> $R/etc/shadow
grep -c '^toor:' $R/etc/passwd $R/etc/shadow

echo "== 3. dropbear config + rc.local"
if [ ! -f $R/etc/config/dropbear ]; then
cat > $R/etc/config/dropbear <<'EOC'
config dropbear
	option PasswordAuth 'on'
	option RootPasswordAuth 'on'
	option Port         '22'
	option RootLogin    '0'
	option MaxAuthTries '4'
EOC
fi
grep -q dropbear $R/etc/rc.local || sed -i 's|^exit 0|/usr/sbin/dropbear -p 22 >/dev/null 2>\&1 \&\niptables -I INPUT 1 -p tcp -s 192.168.8.0/24 --dport 22 -j ACCEPT\nexit 0|' $R/etc/rc.local
tail -4 $R/etc/rc.local

echo "== 4. rcS surgical edits"
sed -i 's/^sysmgr \&/#v3: sysmgr \&/' $R/etc/init.d/rcS
sed -i 's/^mipc_wan_cli/#v3: mipc_wan_cli/' $R/etc/init.d/rcS
printf '\n#v3: rcS complete marker\n[ -e /tmp ] && touch /tmp/rcS.done\n' >> $R/etc/init.d/rcS
grep -c 'v3:' $R/etc/init.d/rcS

echo "== 5. login.sh getty"
cat > $R/usr/libexec/login.sh <<'EOS'
#!/bin/sh
/sbin/getty -L ttyS0 921600 vt100
EOS
chmod +x $R/usr/libexec/login.sh

echo "== 6. zz_data_hook -> S98"
cp /data/build/rootfs/etc/init.d/zz_data_hook $R/etc/init.d/zz_data_hook
chmod +x $R/etc/init.d/zz_data_hook
rm -f $R/etc/rc.d/S99zz_data_hook $R/etc/rc.d/S98zz_data_hook
ln -s ../init.d/zz_data_hook $R/etc/rc.d/S98zz_data_hook
ls -la $R/etc/rc.d/S98zz_data_hook

echo "== 7. babysitter + preinit"
mkdir -p $R/sbin
cp /data/rescue/babysit.sh $R/sbin/babysit.sh
chmod +x $R/sbin/babysit.sh
grep -q 'boot.done' $R/etc/init.d/zz_data_hook || printf '\n#v3: boot completed marker for babysitter\ntouch /tmp/boot.done\n' >> $R/etc/init.d/zz_data_hook
grep -q babysit $R/etc/preinit || sed -i '1a\
#v3: boot babysitter (rescue core)\
if [ -x /data/rescue/babysit.sh ]; then /data/rescue/babysit.sh >/dev/console 2>\&1 \&\
elif [ -x /sbin/babysit.sh ]; then /sbin/babysit.sh >/dev/console 2>\&1 \& fi' $R/etc/preinit
grep -A2 babysit $R/etc/preinit | head -3

echo "== 8. tree verify"
[ "$(grep -c 'v3:' $R/etc/init.d/rcS)" -ge 2 ] || { echo "FAIL: rcS anchors"; exit 1; }
[ -L $R/etc/rc.d/S98zz_data_hook ] || { echo "FAIL: S98 hook"; exit 1; }
grep -q babysit $R/etc/preinit || { echo "FAIL: preinit"; exit 1; }
grep -q '^toor:' $R/etc/passwd || { echo "FAIL: toor"; exit 1; }
grep -q dropbear $R/etc/rc.local || { echo "FAIL: rc.local"; exit 1; }
echo "tree OK"

echo "== 9. mksquashfs"
cd $B
LD_LIBRARY_PATH=$LIBS $SQ rootfs_v4 rootfs_v4.squashfs -comp xz -b 262144 -no-xattrs -noappend -all-root > /tmp/mksq4.log 2>&1 || { tail -5 /tmp/mksq4.log; exit 1; }
SZ=$(wc -c < rootfs_v4.squashfs); echo "image: $SZ bytes"

echo "== 10. image verify (loop mount)"
mkdir -p /mnt/v4chk
mount -t squashfs -o loop,ro rootfs_v4.squashfs /mnt/v4chk
grep -c 'v3:' /mnt/v4chk/etc/init.d/rcS
grep -c '^toor:' /mnt/v4chk/etc/passwd
grep -c babysit /mnt/v4chk/etc/preinit
ls /mnt/v4chk/etc/rc.d/S98zz_data_hook
grep /mnt/v4chk/etc/release 2>/dev/null || cat /mnt/v4chk/etc/release
umount /mnt/v4chk
echo "image verified"

echo "== 11. flash slot A (boot_a <- RP0103 kernel from boot_b)"
dd if=/dev/mmcblk0p38 of=/dev/mmcblk0p25 bs=4M
dd if=$B/rootfs_v4.squashfs of=/dev/mmcblk0p26 bs=4M
SZS=$(((SZ + 511) / 512))
dd if=/dev/zero of=/dev/mmcblk0p26 bs=512 seek=$SZS count=4096 2>/dev/null || true
sync

echo "== 12. partition verify"
mount -t squashfs -o loop,ro /dev/mmcblk0p26 /mnt/v4chk
grep -c 'v3:' /mnt/v4chk/etc/init.d/rcS && cat /mnt/v4chk/etc/release
umount /mnt/v4chk

echo "== 13. bootctrl (keep current A-active)"
hexdump -C -n 10 -s 2060 /dev/mmcblk0p1
echo "== v4 READY on slot A. Reboot when prepared."
echo "== babysitter: T1=180s kill hung rcS, T2=360s flip to B(stock RP0103)."
