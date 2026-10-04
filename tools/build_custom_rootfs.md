# Custom rootfs build & slot-flash procedure (verified on RP0102)

Run these via `tools/lgssh.py` (root SSH). Everything happens ON THE DEVICE --
no cross-platform squashfs fidelity issues. Work dir: `/data/build`.

## 0. Toolchain (one-time)

The stock opkg distfeeds are 404 placeholders; fetch squashfs-tools from the
official 23.05 `aarch64_generic` feed on the PC and push it up:

```
PC:  curl -O https://downloads.openwrt.org/releases/23.05.0/packages/aarch64_generic/packages/{squashfs-tools-mksquashfs_4.6.1-1,squashfs-tools-unsquashfs_4.6.1-1,liblzma_5.4.6-1,libzstd_1.5.2-2}_aarch64_generic.ipk
PC:  python tools/file_transfer.py push <each>.ipk /tmp/<name>.ipk     (MSYS_NO_PATHCONV=1)
```

```
DEV: mkdir -p /tmp/st && cd /tmp/st
     for f in /tmp/*.ipk; do tar xzf $f -O ./data.tar.gz | tar xz -C /tmp/st; done
     export LD_LIBRARY_PATH=/tmp/st/usr/lib
     /tmp/st/usr/sbin/unsquashfs -version    # sanity
```

## 1. Unpack current rootfs (p39 = active slot b; use p26 when on slot a)

```
dd if=/dev/mmcblk0p39 of=/tmp/rootfs_cur.bin bs=4M
/tmp/st/usr/sbin/unsquashfs -d /data/build/rootfs /tmp/rootfs_cur.bin
```

## 2. Modify (v1 = persistent SSH root)

```
R=/data/build/rootfs
echo 'toor:x:0:0:root:/root:/bin/ash' >> $R/etc/passwd
echo 'toor:<1$MD5_HASH>:19953:0:99999:7:::' >> $R/etc/shadow
rm -f $R/etc/dropbear/*
dropbearkey -t ed25519 -f $R/etc/dropbear/dropbear_ed25519_host_key
dropbearkey -t rsa    -f $R/etc/dropbear/dropbear_rsa_host_key
chmod 755 $R/etc/dropbear; chmod 600 $R/etc/dropbear/*
# rc.local: add before 'exit 0'
#   /usr/sbin/dropbear -p 22 >/dev/null 2>&1 &
#   iptables -I INPUT 1 -p tcp -s 192.168.8.0/24 --dport 22 -j ACCEPT
# CRITICAL: keep the factory slot intact -- disable the post-upgrade clone:
sed -i 's/ab_image_sync/#&/' $R/etc/init.d/zmtk_boot_done
```

## 3. Repack + verify

```
cd /data/build
/tmp/st/usr/sbin/mksquashfs rootfs rootfs_v1.squashfs \
    -comp xz -b 262144 -no-xattrs -noappend -all-root
mkdir -p /mnt/v1test
mount -t squashfs -o loop rootfs_v1.squashfs /mnt/v1test   # must succeed
tail -1 /mnt/v1test/etc/shadow; umount /mnt/v1test
```

## 4. Flash the OTHER slot (from slot b -> slot a)

```
dd if=/dev/mmcblk0p38 of=/dev/mmcblk0p25 bs=4M          # boot_b -> boot_a (kernel match!)
dd if=rootfs_v1.squashfs of=/dev/mmcblk0p26 bs=4M
dd if=/dev/zero of=/dev/mmcblk0p26 bs=512 seek=<size_in_512b> count=<rest>
sync
mount -t squashfs -o loop,ro /dev/mmcblk0p26 /mnt/v1test  # verify actual partition
umount /mnt/v1test
```

## 5. Switch slot (bootctrl)

misc = /dev/mmcblk0p1, field base offset 2060, 10 bytes:
`A(pri,try,succ,up) gap B(pri,try,succ,up)`

- Boot custom slot A (from slot b): `0f 03 00 00 00 0e 00 01 02 00`
- Boot back to stock slot B:        `0e 00 00 00 00 0f 00 01 01 00`

```
printf '<bytes via a pushed 10-byte file>' -> dd if=/tmp/bc.bin of=/dev/mmcblk0p1 bs=1 seek=2060 count=10
```

NOTE: lk selects the slot purely by PRIORITY (the up=02 "upgrade pending"
flag is consumed by zmtk_boot_done in userspace, not by lk -- first attempt
with vendor-identical flags booted the old slot; priority swap works).

## 6. Reboot & verify

```
reboot
# after ~2min: ssh toor@192.168.8.1 (password = your TOOR_PASS)
cat /proc/cmdline    # root=/dev/mmcblk0p26 bootslot=a
dd if=/dev/mmcblk0p1 bs=1 skip=2048 count=32 | busybox hexdump -C
# A: 0f 00 01 00 (succ=01 by zmtk) ; stock slot B untouched
```

## v2 增量（已验证）：/data 持久钩子

v1 基础上新增开机钩子——此后配置迭代只改 /data，不再重刷固件：

- 新增 `/etc/init.d/zz_data_hook`（START=99）：后台执行 `/data/rc.extend.sh`（存在才执行）
- **关键**：必须在镜像里同时创建 `/etc/rc.d/S99zz_data_hook -> ../init.d/zz_data_hook` 符号链接，
  否则 OpenWrt init 根本不会调度它（第一次构建就漏了这步，靠开机日志定位）
- `/data/rc.extend.sh` 内容按站点自定义（例：`sh /data/gw/restore_wan.sh`）

## 经验教训（实战踩坑实录）

- OpenWrt init 靠 `/etc/rc.d/S*` 符号链接调度：新增 init.d 脚本必须同时放 rc.d 链接
- 改 eth1 MAC 前必须先 `ip link set eth1 nomaster`（还在桥里时 set MAC 返回 EBUSY 且**静默失败**）；改完要读回验证 + 重试
- MAC 改写后载波重协商需要 10-15 秒：依赖链路的服务（802.1X 客户端等）必须先等 `/sys/class/net/eth1/carrier = 1`
- 原厂 `DeviceInfo.X_UplinkCos` 节点切换（Web 后台"上网方式"）会触发守护进程重配端口/防火墙并**清空全部手工运行时配置**——自定义多 WAN 场景应把它钉死为 `nb5g`
- busybox `reboot` 偶发 I/O error；可靠硬复位：`sync` 后 `echo b > /proc/sysrq-trigger`
- SSH exec 里 `(...)&` 形式的后台任务会被信道关闭杀掉：用 `nohup` 包裹或同步执行
- 设备端 bash 的 `$(...)`/引号经过多层转发极易损坏：复杂命令一律推脚本文件上去执行
