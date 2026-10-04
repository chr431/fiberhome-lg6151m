#!/bin/sh
# v3 firmware build (run ON DEVICE via lgssh: sh /data/build/build_v3.sh)
# Base: v2 tree. Changes per docs/V3_RESCUE_DESIGN.md + all post-mortems:
#   1. rcS: comment out `sysmgr &` (FH daemon army)
#   2. rcS: comment out the blocking mipc_wan_cli AT line (L122)
#   3. rcS: touch /tmp/rcS.done at end (babysitter observation point)
#   4. login.sh: remove uart_conf gate — getty on ttyS0 ALWAYS (serial lock removed)
#   5. zz_data_hook renamed S98 (runs BEFORE S99zmtk's rcS hang point)
#   6. preinit: launch boot babysitter (from /data/rescue if present, fallback baked-in)
#   7. babysitter + boot.done marker hook baked in
#   8. zmtk ab_image_sync stays commented (never clone slots)
# Flash target: slot A. Slot B (v2) untouched as permanent fallback.
set -e
B=/data/build
R=$B/rootfs_v3

echo "=== 1. copy v2 tree"
rm -rf $R
cp -a $B/rootfs $R

echo "=== 2. rcS surgical edits"
sed -i 's/^sysmgr &/#v3: sysmgr \&/' $R/etc/init.d/rcS
sed -i 's/^mipc_wan_cli/#v3: mipc_wan_cli/' $R/etc/init.d/rcS
printf '\n#v3: rcS complete marker\n[ -e /tmp ] && touch /tmp/rcS.done\n' >> $R/etc/init.d/rcS
grep -c 'v3:' $R/etc/init.d/rcS

echo "=== 3. login.sh: unconditional getty on ttyS0"
cat > $R/usr/libexec/login.sh <<'EOS'
#!/bin/sh
/sbin/getty -L ttyS0 921600 vt100
EOS
chmod +x $R/usr/libexec/login.sh

echo "=== 4. hook rename S99zz -> S98zz (before S99zmtk rcS call)"
rm -f $R/etc/rc.d/S99zz_data_hook
ln -s ../init.d/zz_data_hook $R/etc/rc.d/S98zz_data_hook
ls -la $R/etc/rc.d/S98zz_data_hook

echo "=== 5. babysitter baked-in + boot.done marker"
mkdir -p $R/sbin $R/data/rescue 2>/dev/null || true
# babysitter itself comes from /data/rescue/babysit.sh (persisted, editable);
# bake a minimal fallback copy:
cp /data/rescue/babysit.sh $R/sbin/babysit.sh 2>/dev/null || echo "WARN: /data/rescue/babysit.sh missing - push it first"
chmod +x $R/sbin/babysit.sh 2>/dev/null || true
# boot.done marker: append to zz hook
printf '\n#v3: boot completed marker for babysitter\ntouch /tmp/boot.done\n' >> $R/etc/init.d/zz_data_hook

echo "=== 6. preinit: launch babysitter (first controllable point, before procd)"
grep -q babysit $R/etc/preinit || sed -i '1a\
#v3: boot babysitter (rescue core — see docs/V3_RESCUE_DESIGN.md)\
if [ -x /data/rescue/babysit.sh ]; then /data/rescue/babysit.sh >/dev/console 2>&1 &\
elif [ -x /sbin/babysit.sh ]; then /sbin/babysit.sh >/dev/console 2>&1 & fi' $R/etc/preinit
grep -A3 babysit $R/etc/preinit | head -5

echo "=== 7. repack"
cd $B
LD_LIBRARY_PATH=/tmp/st/usr/lib /tmp/st/usr/sbin/mksquashfs rootfs_v3 rootfs_v3.squashfs \
    -comp xz -b 262144 -no-xattrs -noappend -all-root > /tmp/mksq3.log 2>&1 || { tail -5 /tmp/mksq3.log; exit 1; }
SZ=$(wc -c < rootfs_v3.squashfs); echo "image: $SZ bytes"

echo "=== 8. verify image"
mkdir -p /mnt/v3chk
mount -t squashfs -o loop,ro rootfs_v3.squashfs /mnt/v3chk
for f in "grep -c 'v3:' /mnt/v3chk/etc/init.d/rcS" "ls /mnt/v3chk/etc/rc.d/S98zz_data_hook" "grep -c babysit /mnt/v3chk/etc/preinit" "grep -c getty /mnt/v3chk/usr/libexec/login.sh"; do
    eval $f || { echo "VERIFY FAIL: $f"; umount /mnt/v3chk; exit 1; }
done
umount /mnt/v3chk
echo "image verified"

echo "=== 9. flash slot A (boot_a from boot_b, image to p26, tail zero)"
SZS=$(((SZ + 511) / 512))
dd if=/dev/mmcblk0p38 of=/dev/mmcblk0p25 bs=4M
dd if=$B/rootfs_v3.squashfs of=/dev/mmcblk0p26 bs=4M
dd if=/dev/zero of=/dev/mmcblk0p26 bs=512 seek=$SZS count=4096 2>/dev/null || true
sync
mount -t squashfs -o loop,ro /dev/mmcblk0p26 /mnt/v3chk && grep -c 'v3:' /mnt/v3chk/etc/init.d/rcS && umount /mnt/v3chk
echo "partition verified"

echo "=== 10. bootctrl -> slot A (try=3): 0f 03 00 00 00 0e 00 01 02 00"
printf '\x0f\x03\x00\x00\x00\x0e\x00\x01\x02\x00' > /tmp/bc_v3.bin
dd if=/tmp/bc_v3.bin of=/dev/mmcblk0p1 bs=1 seek=2060 count=10
sync
echo "=== v3 READY. bootctrl flip done — reboot when prepared."
echo "=== babysitter guarantees: T1=180s kill hung rcS, T2=360s flip back to B."
echo "=== manual rollback anytime: misc[2060]=0e 00 01 00 00 0f 00 01 02 00"
