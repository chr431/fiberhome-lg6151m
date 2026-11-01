#!/bin/bash
# build_kernel.sh -- stage 2: build initramfs payload, wire it into .config,
# then make Image + dtbs with the Ubuntu aarch64 cross toolchain.
set -eu
LK="$HOME/lab-kernel"
TREE="$LK/linux-6.18.44"
INITRD="$LK/initramfs"
MUSLCC="$LK/musl-cross/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc"
BB=/mnt/d/Repo/lg6151m-project/_local/build/busybox.clean
VSURV_SRC=/mnt/d/Repo/lg6151m-project/lg6151m-public/tools/oneoff/sigsegv/vsurv4.c

echo "== 1. initramfs skeleton =="
rm -rf "$INITRD"
mkdir -p "$INITRD"/{bin,sbin,usr/bin,usr/sbin,proc,sys,dev,tmp,data/repro,root,mnt,etc}

echo "== 2. busybox (static aarch64, prebuilt by this project) =="
file "$BB"
cp "$BB" "$INITRD/bin/busybox"
chmod 755 "$INITRD/bin/busybox"
for a in sh mount umount cat echo ls ps kill sleep mkdir mknod uname cut awk grep \
         wc zcat date free dd head tail cp mv rm ln read cmp hexdump less sync \
         sysrq sed insmod rmmod lsmod ifconfig ip route ping vi false true \
         pidof basename dirname test [ ; do
    ln -sf busybox "$INITRD/bin/$a"
done
ln -sf ../bin/busybox "$INITRD/sbin/poweroff"
ln -sf ../bin/busybox "$INITRD/sbin/reboot"

echo "== 3. vsurv4 canary (static musl) =="
"$MUSLCC" -static -O2 -o "$INITRD/vsurv4" "$VSURV_SRC"
file "$INITRD/vsurv4"

echo "== 4. /init =="
cp "$LK/scripts/lab_init.sh" "$INITRD/init"
chmod 755 "$INITRD/init"

echo "== 5. wire INITRAMFS_SOURCE =="
cd "$TREE"
scripts/config --set-str INITRAMFS_SOURCE "$INITRD"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null
grep "^CONFIG_INITRAMFS_SOURCE" .config

echo "== 6. build Image + dtbs =="
mkdir -p "$LK/out"
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs 2>&1 | tee "$LK/out/kernel_build.log" | tail -30
# also keep vmlinux for gdb/kgdb symbol work
ls -la "$TREE/arch/arm64/boot/Image" "$TREE/arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb" "$TREE/vmlinux"
cp "$TREE/arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb" "$LK/out/"
echo BUILD_DONE
