#!/bin/bash
# v3_export.sh -- step 8 of v3_repack.sh as a standalone file.
set -eu
LK="$HOME/lab-kernel"
TREE="$LK/linux-6.18.44"
INITRD="$LK/initramfs"
WIN=/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel
cp -f "$LK/out/boot-lab3-unsigned.img" "$LK/out/boot-lab3-signed.img" "$WIN/artifacts/"
cp -f "$TREE/arch/arm64/boot/Image" "$WIN/artifacts/Image.lab3"
cp -f "$TREE/System.map" "$WIN/artifacts/System.map.lab3"
cp -f "$TREE/.config" "$WIN/artifacts/config-lab3-6.18.44"
cp -f "$LK/out/mt6990-fiberhome-lg6151m.dtb" "$WIN/artifacts/" 2>/dev/null \
    || cp -f "$TREE/arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb" "$WIN/artifacts/"
cp -f "$INITRD/init" "$WIN/artifacts/lab_init_v3.sh"
cp -f "$INITRD/bin/netup" "$WIN/artifacts/netup"
cp -f "$INITRD/bin/romount" "$WIN/artifacts/romount"
cp -f "$INITRD/bin/kjump" "$WIN/artifacts/kjump"
mkdir -p "$WIN/artifacts/modules"
cp -f "$INITRD/modules/"*.ko "$WIN/artifacts/modules/"
zstd -T0 -12 -q -f -o "$WIN/artifacts/vmlinux.lab3.zst" "$TREE/vmlinux"
for lg in kernel_build_v3 modules_build_v3 sign_boot_v3; do
    cp -f "$LK/out/$lg.log" "$WIN/logs/" 2>/dev/null || true
done
cp -f "$LK/out/config_delta_v3_vs_v2.txt" "$WIN/logs/" 2>/dev/null || true
cd "$WIN/artifacts"
# regenerate complete SUMS covering v1+v2+v3 sets
sha256sum boot-lab-unsigned.img boot-lab-signed.img boot-lab2-unsigned.img \
          boot-lab2-signed.img boot-lab3-unsigned.img boot-lab3-signed.img \
          Image.lab Image.lab2 Image.lab3 System.map.lab System.map.lab2 \
          System.map.lab3 config-lab-6.18.44 config-lab2-6.18.44 \
          config-lab3-6.18.44 vmlinux.zst vmlinux.lab2.zst vmlinux.lab3.zst \
          mt6990-fiberhome-lg6151m.dtb mt6990-fiberhome-lg6151m.dts \
          scanary scanary_report.sh vsurv4 netup lab_init_v2.sh lab_init_v3.sh \
          romount kjump modules/*.ko | tee SHA256SUMS.txt
md5sum boot-lab-unsigned.img boot-lab2-unsigned.img boot-lab3-unsigned.img \
       boot-lab-signed.img boot-lab2-signed.img boot-lab3-signed.img \
       scanary vsurv4 netup modules/*.ko | tee MD5SUMS.txt
echo V3_EXPORT_DONE
