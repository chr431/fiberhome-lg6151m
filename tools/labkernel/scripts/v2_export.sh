#!/bin/bash
# v2_export.sh -- step 9 of v2_repack.sh as a standalone file
# (wsl.exe inline commands lose shell variable assignments; C1 lesson).
set -eu
LK="$HOME/lab-kernel"
TREE="$LK/linux-6.18.44"
INITRD="$LK/initramfs"
WIN=/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel
cp -f "$LK/out/boot-lab2-unsigned.img" "$LK/out/boot-lab2-signed.img" "$WIN/artifacts/"
cp -f "$TREE/arch/arm64/boot/Image" "$WIN/artifacts/Image.lab2"
cp -f "$TREE/System.map" "$WIN/artifacts/System.map.lab2"
cp -f "$TREE/.config" "$WIN/artifacts/config-lab2-6.18.44"
cp -f "$TREE/arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb" "$LK/out/mt6990-fiberhome-lg6151m.dtb"
cp -f "$LK/out/mt6990-fiberhome-lg6151m.dtb" "$WIN/artifacts/mt6990-fiberhome-lg6151m.dtb"
cp -f "$INITRD/init" "$WIN/artifacts/lab_init_v2.sh"
cp -f "$INITRD/bin/netup" "$WIN/artifacts/netup"
zstd -T0 -12 -q -f -o "$WIN/artifacts/vmlinux.lab2.zst" "$TREE/vmlinux"
cp -f "$LK/out/kernel_build_v2.log" "$LK/out/sign_boot_v2.log" "$WIN/logs/" 2>/dev/null || true
cd "$WIN/artifacts"
sha256sum boot-lab2-unsigned.img boot-lab2-signed.img Image.lab2 System.map.lab2 \
          config-lab2-6.18.44 vmlinux.lab2.zst netup lab_init_v2.sh \
          boot-lab-unsigned.img boot-lab-signed.img Image.lab System.map.lab \
          config-lab-6.18.44 vmlinux.zst mt6990-fiberhome-lg6151m.dtb \
          mt6990-fiberhome-lg6151m.dts scanary scanary_report.sh vsurv4 | tee SHA256SUMS.txt
md5sum boot-lab2-unsigned.img boot-lab2-signed.img boot-lab-unsigned.img \
       boot-lab-signed.img scanary vsurv4 netup | tee MD5SUMS.txt
echo V2_EXPORT_DONE
