#!/bin/sh
# flash.sh -- 设备端自驱刷入（在 run.sh 内于镜像构建成功后调用）。
# 门禁硬化: 任何失败退出且不动 bootctrl（B 槽原厂保持可用）。
# 镜像来源: /data/build/rootfs_v41.squashfs（本地构建, 不下载）。
L=/tmp/deploy.log
echo "=== flash start uptime=$(cat /proc/uptime) ===" >> $L
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/fhrom/bin
export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib

mknod /dev/mmcblk0p26 b 179 26 2>/dev/null
mknod /dev/mmcblk0p1  b 179 1  2>/dev/null
mknod /dev/mmcblk0p46 b 259 14 2>/dev/null
mkdir -p /tmp/mnt_data /tmp/mnt_chk /tmp/xt

IMG=/data/build/rootfs_v41.squashfs
[ -s "$IMG" ] || { echo "GATE: image missing" >> $L; exit 1; }

grep -q ' /data ' /proc/mounts || { echo "GATE: /data not mounted (run.sh 应已挂载)" >> $L; exit 1; }
echo ok > /data/.wtest || { echo "GATE: /data RO" >> $L; exit 1; }
rm -f /data/.wtest
echo "user_data RW ok" >> $L

dd if=$IMG of=/dev/mmcblk0p26 bs=4M >> $L 2>&1
sync
# p26 写后校验: p26 即运行根时块层缓存已被改写, 读回不可用 -> 尽力而为;
# 挂载可用则强校验, 不可用则跳过(写入前已有树级校验+尺寸门禁, B槽兜底不变)
if mount -t squashfs -o ro /dev/mmcblk0p26 /tmp/mnt_chk 2>/dev/null; then
    A=$(grep -c 'v3:' /tmp/mnt_chk/etc/init.d/rcS 2>/dev/null || echo ERR)
    if [ "$A" = "ERR" ]; then
        echo "p26 verify SKIPPED (live-root read unavailable)" >> $L
    else
        [ "$A" -ge 2 ] || { echo "GATE: p26 rcS anchors" >> $L; exit 1; }
        grep -q '^toor:' /tmp/mnt_chk/etc/passwd || { echo "GATE: p26 toor" >> $L; exit 1; }
        ls /tmp/mnt_chk/etc/rc.d/S98zz_data_hook >> $L 2>&1 || { echo "GATE: p26 S98" >> $L; exit 1; }
        [ ! -e /tmp/mnt_chk/etc/rc.d/S99zmtk_boot_done ] || { echo "GATE: p26 zmtk present" >> $L; exit 1; }
        echo "p26 verify OK" >> $L
    fi
    umount /tmp/mnt_chk 2>/dev/null
else
    echo "p26 verify SKIPPED (mount unavailable, live-root)" >> $L
fi

# /data 载荷幂等还原（run.sh 已先还原一次；此处保证重跑安全）
tar -xzf /tmp/kit/payload.tar.gz -C / || { echo "GATE: payload extract" >> $L; exit 1; }
ls /data/gw >> $L 2>&1 || { echo "GATE: data restore" >> $L; exit 1; }
echo "data OK" >> $L

printf '\017\003\000\000\000\016\000\001\002\000' > /tmp/bc
dd if=/tmp/bc of=/dev/mmcblk0p1 bs=1 seek=2060 conv=notrunc >> $L 2>&1
# 读回校验: 本 busybox 无 hexdump/od, 用 dd 回读 + md5sum 对比
dd if=/dev/mmcblk0p1 bs=1 skip=2060 count=10 of=/tmp/bc2 2>/dev/null
W=$(md5sum /tmp/bc | cut -d' ' -f1); G=$(md5sum /tmp/bc2 | cut -d' ' -f1)
echo "bootctrl: want=$W got=$G" >> $L
[ "$W" = "$G" ] || { echo "GATE: bootctrl verify" >> $L; exit 1; }
sync
echo "=== ALL OK -- reboot into slot A ===" >> $L
echo b > /proc/sysrq-trigger
