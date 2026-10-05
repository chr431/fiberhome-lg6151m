#!/bin/sh
# build_image.sh -- 设备端: 从 B 槽原厂树构建自定义根文件系统镜像（不刷入）。
# 前提: /tmp/kit/payload.tar.gz 已还原到 /（提供 /data/build/rootfs/... 与
#       /data/rescue/babysit.sh）；ipk 已解包到 /tmp/st。
# 环境: TOOR_PASS 必须设置（root 后门口令, 构建时生成哈希, 不落明文）。
set -e
B=/data/build
R=$B/rootfs_v41
SQ=/tmp/st/squashfs-tools-mksquashfs_4.6.1-1_aarch64_generic/ex/usr/sbin/mksquashfs
LIBS=/tmp/st/liblzma_5.4.6-1_aarch64_generic/ex/usr/lib:/tmp/st/libzstd_1.5.2-2_aarch64_generic/ex/usr/lib

[ -n "$TOOR_PASS" ] || { echo "FAIL: TOOR_PASS 未设置"; exit 1; }
case "$TOOR_PASS" in *"'"*) echo "FAIL: 口令含单引号"; exit 1;; esac

echo "== 1. copy stock tree from slot B"
mkdir -p /mnt/rp103
grep -q ' /mnt/rp103 ' /proc/mounts || mount -t squashfs -o ro /dev/mmcblk0p39 /mnt/rp103
rm -rf $R
cp -a /mnt/rp103 $R
echo "tree: $(find $R -type f | wc -l) files"

echo "== 2. root account"
grep -q '^toor:' $R/etc/passwd || echo 'toor:x:0:0:root:/root:/bin/ash' >> $R/etc/passwd
grep -q '^toor:' $R/etc/shadow || echo "toor:$(openssl passwd -1 -salt fhlg6151 "$TOOR_PASS"):19953:0:99999:7:::" >> $R/etc/shadow
grep -c '^toor:' $R/etc/passwd $R/etc/shadow

echo "== 3. rc.local (SSH 由 /data/rc.extend.sh 的带密钥 dropbear 唯一提供, 不加固件侧实例)"
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

echo "== 6. S98 data hook"
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

echo "== 7b. neutralize S99zmtk_boot_done"
rm -f $R/etc/rc.d/S99zmtk_boot_done
ls $R/etc/rc.d/ | grep -c zmtk || true

echo "== 7c. vendor strip (外围裁剪: 只断启动路径, 不动二进制; 回滚=不裁剪重刷)"
# 高成本/零功能/已被自有实现取代的 vendor 守护
# P0: +S53lppe_service (低功耗定位守护, 无 GNSS 消费者; atci 对保留剥离 -- 由 rc_netfh 按受控环境拉起, L14)
STRIP_S="S53lppe_service S98mdlogger S96atci_service S96atcid S99log_controld S99ql_speed_monitor_mgr S99ql_entry_auto_qos S80wapp S80ucitrack S92baresip S85auto_adapt S98meta_tst S99slt2_test S55speech_daemon S56libmodem_afe_service S57audio-ctrl-service S60vnstat"
STRIP_K="K1mdlogger K01ql_speed_monitor_mgr K01ql_entry_auto_qos K90wapp K15auto_adapt K1slt2_test K50vnstat"
for S in $STRIP_S; do rm -f $R/etc/rc.d/$S; done
for K in $STRIP_K; do rm -f $R/etc/rc.d/$K; done
echo "stripped: $(echo $STRIP_S | wc -w) start + $(echo $STRIP_K | wc -w) stop links"

echo "== 8. tree verify"
[ "$(grep -c 'v3:' $R/etc/init.d/rcS)" -ge 2 ] || { echo "FAIL: rcS anchors"; exit 1; }
[ -L $R/etc/rc.d/S98zz_data_hook ] || { echo "FAIL: S98 hook"; exit 1; }
[ ! -e $R/etc/rc.d/S99zmtk_boot_done ] || { echo "FAIL: zmtk still linked"; exit 1; }
grep -q babysit $R/etc/preinit || { echo "FAIL: preinit"; exit 1; }
grep -q '^toor:' $R/etc/passwd || { echo "FAIL: toor"; exit 1; }
for S in S98zz_data_hook; do [ -e $R/etc/rc.d/$S ] || { echo "FAIL: $S"; exit 1; }; done
echo "tree OK"

echo "== 9. mksquashfs"
cd $B
LD_LIBRARY_PATH=$LIBS $SQ rootfs_v41 rootfs_v41.squashfs -comp xz -b 262144 -no-xattrs -noappend -all-root > /tmp/mksq41.log 2>&1 || { tail -5 /tmp/mksq41.log; exit 1; }
SZ=$(wc -c < rootfs_v41.squashfs); echo "image: $SZ bytes"

echo "== 10. image summary (挂载级验证由 flash.sh 的 p26 门禁完成)"
md5sum $B/rootfs_v41.squashfs
SZ=$(wc -c < $B/rootfs_v41.squashfs); echo "image bytes: $SZ"
[ "$SZ" -gt 20000000 ] || { echo "FAIL: image too small"; exit 1; }
echo "== image READY (not flashed)"
