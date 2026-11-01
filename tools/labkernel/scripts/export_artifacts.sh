#!/bin/bash
# export_artifacts.sh -- copy final artifacts + logs to the Windows-side
# lab-kernel dir, with hashes and compressed debug payload.
set -eu
LK="$HOME/lab-kernel"
WIN=/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel
OUT="$LK/out"
TREE="$LK/linux-6.18.44"

mkdir -p "$WIN/artifacts" "$WIN/logs"

echo "== compress vmlinux for kgdb/gdb symbol work =="
if [ ! -f "$OUT/vmlinux.zst" ]; then
    zstd -T0 -12 -q -o "$OUT/vmlinux.zst" "$TREE/vmlinux"
fi

echo "== copy artifacts =="
cp -f "$OUT/boot-lab-unsigned.img" "$WIN/artifacts/"
cp -f "$OUT/boot-lab-signed.img" "$WIN/artifacts/"
cp -f "$OUT/mt6990-fiberhome-lg6151m.dtb" "$WIN/artifacts/"
cp -f "$OUT/mt6990-fiberhome-lg6151m.dts" "$WIN/artifacts/" 2>/dev/null || cp -f "$LK/out/mt6990-fiberhome-lg6151m.dts" "$WIN/artifacts/" 2>/dev/null || true
cp -f "$TREE/arch/arm64/boot/Image" "$WIN/artifacts/Image.lab"
cp -f "$TREE/System.map" "$WIN/artifacts/System.map.lab"
cp -f "$TREE/.config" "$WIN/artifacts/config-lab-6.18.44"
cp -f "$OUT/vsurv4" "$WIN/artifacts/"
cp -f "$OUT/vmlinux.zst" "$WIN/artifacts/"

echo "== copy logs =="
cp -f "$OUT/prep_tree.log" "$WIN/logs/" 2>/dev/null || true
cp -f "$OUT/kernel_build.log" "$WIN/logs/kernel_build1_failed_leds.log" 2>/dev/null || true
cp -f "$OUT/kernel_build2.log" "$WIN/logs/" 2>/dev/null || true
cp -f "$OUT/sign_boot.log" "$WIN/logs/" 2>/dev/null || true
cp -f "$OUT/patch_failures.txt" "$WIN/logs/" 2>/dev/null || true
cp -f "$OUT/dl_kernel.log" "$WIN/logs/" 2>/dev/null || true
cp -f "$OUT/reconfig_missing0.log" "$WIN/logs/" 2>/dev/null || true

echo "== hashes =="
cd "$WIN/artifacts"
sha256sum boot-lab-unsigned.img boot-lab-signed.img mt6990-fiberhome-lg6151m.dtb Image.lab System.map.lab config-lab-6.18.44 vsurv4 vmlinux.zst | tee SHA256SUMS.txt
md5sum boot-lab-unsigned.img boot-lab-signed.img | tee MD5SUMS.txt
ls -la
echo EXPORT_DONE
