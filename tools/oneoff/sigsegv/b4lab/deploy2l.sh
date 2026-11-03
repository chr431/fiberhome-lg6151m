#!/bin/sh
# deploy2l.sh -- B4L bench: flash a p26 image from the LK raw shell.
# Derived from deploy2r.sh (C2R Round A, md5 a88c2e9a...): same fetch/dd/
# readback gates; mount gate made optional (p26 is the RUNNING root under
# init=/bin/sh -> mount returns "Resource busy"; readback md5 is the
# authority) and per-image content anchors added.
# Serve the b4lab dir from the PC:  python -m http.server 8931 --bind 0.0.0.0
# Run on device raw shell:  sh deploy2l.sh b4lab | b4lab_nowarp | v41
L=/tmp/deploy2l.log
echo "=== deploy2l start arg=$1 uptime=$(cat /proc/uptime) ===" >> $L
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/fhrom/bin
export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib
PC=${PC_URL:-http://192.168.8.250:8931}
case "$1" in
  b4lab)        F=rootfs_b4lab.squashfs;        WANT=f671cd75a1322e8c61fd3ed59aab7e86; SZ=48914432 ;;
  b4lab_nowarp) F=rootfs_b4lab_nowarp.squashfs;  WANT=8688aa7a94b2f639d55d328d330602c1; SZ=48914432 ;;
  v41)          F=rootfs_v41.squashfs;          WANT=dec55b3722e95074722dc1761752f0ab; SZ=48910336 ;;
  *) echo "usage: sh deploy2l.sh b4lab|b4lab_nowarp|v41" > /dev/console; exit 2 ;;
esac
md5s() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
mknod /dev/mmcblk0p26 b 179 26 2>/dev/null
mknod /dev/mmcblk0p1 b 179 1 2>/dev/null
mkdir -p /tmp/mnt_chk
rm -f /tmp/v.sqfs
i=0
while [ $i -lt 3 ]; do
  curl -s --connect-timeout 10 --max-time 900 -o /tmp/v.sqfs $PC/$F
  G=$(md5s /tmp/v.sqfs)
  echo "fetch try=$i file=$F md5=$G" >> $L
  [ "$G" = "$WANT" ] && break
  rm -f /tmp/v.sqfs; i=$((i+1)); sleep 2
done
[ "$(md5s /tmp/v.sqfs)" = "$WANT" ] || { echo "GATE: image md5" >> $L; exit 1; }
dd if=/tmp/v.sqfs of=/dev/mmcblk0p26 bs=4M >> $L 2>&1
sync
# content gates when p26 is mountable (NOT the running root); skip on busy
if mount -t squashfs /dev/mmcblk0p26 /tmp/mnt_chk 2>>$L; then
  [ "$(grep -c 'v3:' /tmp/mnt_chk/etc/init.d/rcS)" -ge 2 ] || { echo "GATE: rcS anchors" >> $L; exit 1; }
  grep -q '^toor:' /tmp/mnt_chk/etc/passwd || { echo "GATE: toor" >> $L; exit 1; }
  ls /tmp/mnt_chk/etc/rc.d/S98zz_data_hook >> $L 2>&1 || { echo "GATE: S98" >> $L; exit 1; }
  [ ! -e /tmp/mnt_chk/etc/rc.d/S99zmtk_boot_done ] || { echo "GATE: zmtk present" >> $L; exit 1; }
  case "$1" in
    b4lab)
      grep -q 'armed v3.2' /tmp/mnt_chk/sbin/babysit.sh || { echo "GATE: babysit v3.2" >> $L; exit 1; }
      [ -f /tmp/mnt_chk/sbin/mod_mask.sh ] || { echo "GATE: mod_mask" >> $L; exit 1; }
      grep -q '^VARIANT=primary' /tmp/mnt_chk/etc/b4lab_id || { echo "GATE: b4lab_id primary" >> $L; exit 1; }
      [ -e /tmp/mnt_chk/etc/modules.d/60-warp ] || { echo "GATE: 60-warp missing" >> $L; exit 1; }
      ;;
    b4lab_nowarp)
      grep -q 'armed v3.2' /tmp/mnt_chk/sbin/babysit.sh || { echo "GATE: babysit v3.2" >> $L; exit 1; }
      [ -f /tmp/mnt_chk/sbin/mod_mask.sh ] || { echo "GATE: mod_mask" >> $L; exit 1; }
      grep -q '^VARIANT=nowarp' /tmp/mnt_chk/etc/b4lab_id || { echo "GATE: b4lab_id nowarp" >> $L; exit 1; }
      [ ! -e /tmp/mnt_chk/etc/modules.d/60-warp ] || { echo "GATE: 60-warp present" >> $L; exit 1; }
      ;;
    v41) : ;;
  esac
  umount /tmp/mnt_chk
else
  echo "mount busy (p26 is running root) -- readback md5 is the authority" >> $L
fi
R=$(dd if=/dev/mmcblk0p26 bs=$SZ count=1 2>>$L | md5s)
echo "readback=$R want=$WANT" >> $L
[ "$R" = "$WANT" ] || { echo "GATE: readback md5" >> $L; exit 1; }
H=$(hexdump -C -n 10 -s 2060 /dev/mmcblk0p1 2>>$L | head -1)
echo "misc: $H" >> $L
case "$H" in *"0f 00"*"0e"*) ;; *) echo "GATE: misc form" >> $L; exit 1 ;; esac
sync
echo "=== ALL_OK_P26_$1 ===" >> $L
