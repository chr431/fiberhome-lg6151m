#!/bin/sh
# run.sh -- 设备端套件编排器（raw shell 内运行, 建议后台化）。
# 流程: /dev 修复 -> ipk 解包 -> 载荷还原 -> 镜像构建 -> 刷入(含门禁)。
# 用法: (sh /tmp/kit/run.sh '<TOOR_PASS>' >/tmp/kit.console 2>&1 &)
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/fhrom/bin
export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib

# ---- raw shell 环境修复(必须先于一切重定向/日志: 根fs只读) ----
grep -q ' /proc ' /proc/mounts || mount -t proc proc /proc
mount -t tmpfs tmpfs /dev
mknod /dev/null c 1 3
mknod /dev/urandom c 1 9
grep -q ' /tmp ' /proc/mounts || mount -t tmpfs tmpfs /tmp
grep -q ' /mnt ' /proc/mounts || mount -t tmpfs tmpfs /mnt
mknod /dev/mmcblk0p39 b 259 7 2>/dev/null   # 内核实测: B槽rootfs=259:7
mknod /dev/loop-control c 10 237 2>/dev/null
mknod /dev/loop0 b 7 0 2>/dev/null
mknod /dev/loop1 b 7 1 2>/dev/null
mknod /dev/mmcblk0p46 b 259 14 2>/dev/null
mknod /dev/mmcblk0p26 b 179 26 2>/dev/null
mknod /dev/mmcblk0p1  b 179 1  2>/dev/null
mkdir -p /data
grep -q ' /data ' /proc/mounts || mount -t ext4 /dev/mmcblk0p46 /data

L=/tmp/deploy.log
echo "=== run start uptime=$(cat /proc/uptime) ===" >> $L

TOOR_PASS="$1"
[ -n "$TOOR_PASS" ] || { echo "GATE: TOOR_PASS 未传" >> $L; exit 1; }
export TOOR_PASS
[ -d /data/gw ] || { :; }   # /data 挂载由下方 tar 校验兜底
echo "env: /dev/null=$(ls /dev/null) /tmp=$(mount | grep -c ' /tmp ') /data=$(mount | grep -c ' /data ')" >> $L

echo "== ipk 解包" >> $L
for p in /tmp/kit/ipk/*.ipk; do
  d=$(basename "$p" .ipk)
  mkdir -p /tmp/st/$d/ex
  tar -xzf "$p" -C /tmp/st/$d || { echo "GATE: ipk $d" >> $L; exit 1; }
  tar -xzf /tmp/st/$d/data.tar.gz -C /tmp/st/$d/ex || { echo "GATE: ipk data $d" >> $L; exit 1; }
done
[ -x /tmp/st/squashfs-tools-mksquashfs_4.6.1-1_aarch64_generic/ex/usr/sbin/mksquashfs ] || { echo "GATE: mksquashfs missing" >> $L; exit 1; }
echo "ipk OK" >> $L

echo "== 载荷还原" >> $L
tar -xzf /tmp/kit/payload.tar.gz -C / || { echo "GATE: payload" >> $L; exit 1; }
echo "payload OK" >> $L

echo "== 构建镜像" >> $L
sh /tmp/kit/build_image.sh >> $L 2>&1 || { echo "GATE: build_image rc=$?" >> $L; exit 1; }
echo "build OK" >> $L

echo "== 刷入" >> $L
sh /tmp/kit/flash.sh >> $L 2>&1
echo "flash.sh returned rc=$?" >> $L
