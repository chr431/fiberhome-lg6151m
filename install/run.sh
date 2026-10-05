#!/bin/sh
# run.sh -- 设备端套件编排器（raw shell 内运行, 建议后台化）。
# 流程: /dev 修复 -> ipk 解包 -> 载荷还原 -> 镜像构建 -> 刷入(含门禁)。
# 用法: (sh /tmp/kit/run.sh '<TOOR_PASS>' >/tmp/kit.console 2>&1 &)
L=/tmp/deploy.log
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/fhrom/bin
export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib
echo "=== run start uptime=$(cat /proc/uptime) ===" >> $L

TOOR_PASS="$1"
[ -n "$TOOR_PASS" ] || { echo "GATE: TOOR_PASS 未传" >> $L; exit 1; }
export TOOR_PASS

# raw shell 环境修复（无 /dev/null 则一切后台重定向失败）
[ -e /dev/null ] || { mount -t tmpfs tmpfs /dev 2>/dev/null; mknod /dev/null c 1 3 2>/dev/null; }
[ -e /dev/urandom ] || mknod /dev/urandom c 1 9 2>/dev/null
grep -q ' /proc ' /proc/mounts || mount -t proc proc /proc 2>/dev/null
[ -e /dev/mmcblk0p39 ] || mknod /dev/mmcblk0p39 b 179 39 2>/dev/null

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
