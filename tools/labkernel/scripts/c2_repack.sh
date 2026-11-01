#!/bin/bash
# c2_repack.sh -- C2 bench-session repack (pure offline, no device contact).
# Adds to the C1 lab-kernel initramfs:
#   /scanary            self-scanning canary v1.4 (static musl aarch64 build)
#   /bin/scanary_report busybox-awk on-device log summarizer
#   /init (C2)          banner bump + scanary window-1 auto-start
# Then rebuilds Image, repacks + re-signs boot.img via the C1 pipeline
# (assemble_boot.sh), re-runs the C1 self-check battery (c2_selfcheck.py),
# and exports artifacts + hashes to the Windows-side directory.
set -eu
LK="$HOME/lab-kernel"
TREE="$LK/linux-6.18.44"
INITRD="$LK/initramfs"
MUSLCC="$LK/musl-cross/aarch64-linux-musl-cross/bin/aarch64-linux-musl-gcc"
WIN=/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel
SCANARY_SRC=/mnt/d/Repo/lg6151m-project/tmpfiles/repro/scanary/scanary.c
QEMU=$(command -v qemu-aarch64-static)

echo "== 1. build scanary (static musl aarch64, same toolchain family as vsurv4) =="
mkdir -p "$LK/src"
cp -f "$SCANARY_SRC" "$LK/src/scanary.c"
"$MUSLCC" -static -O2 -pthread -s -o "$INITRD/scanary" "$LK/src/scanary.c"
chmod 755 "$INITRD/scanary"
file "$INITRD/scanary" || true
md5sum "$INITRD/scanary"

echo "== 2. qemu smoke test of the freshly built scanary (20 s self-terminating) =="
[ -n "$QEMU" ] || { echo "qemu-aarch64-static missing"; exit 1; }
rm -f /tmp/scanary_qemu.log
"$QEMU" "$INITRD/scanary" --log /tmp/scanary_qemu.log --duration 20 --probe-sec 5 --epoch-sec 5
grep -q "SELFTEST_PASS" /tmp/scanary_qemu.log || { echo "scanary qemu SELFTEST_PASS missing"; cat /tmp/scanary_qemu.log; exit 1; }
grep -q "SELFTEST_FAIL" /tmp/scanary_qemu.log && { echo "scanary qemu SELFTEST_FAIL present"; cat /tmp/scanary_qemu.log; exit 1; }
grep -q "EXIT reason=duration" /tmp/scanary_qemu.log || { echo "scanary qemu EXIT missing"; cat /tmp/scanary_qemu.log; exit 1; }
echo "qemu smoke test OK; log head:"
head -6 /tmp/scanary_qemu.log

echo "== 3. validate scanary_report under the actual initramfs busybox (qemu) =="
cp -f "$LK/scripts/scanary_report.sh" "$INITRD/bin/scanary_report"
chmod 755 "$INITRD/bin/scanary_report"
"$QEMU" "$INITRD/bin/busybox" sh "$INITRD/bin/scanary_report" /tmp/scanary_qemu.log \
    | tee "$LK/out/scanary_report_qemu_check.log"

echo "== 4. install C2 /init =="
cp -f "$LK/scripts/lab_init_c2.sh" "$INITRD/init"
chmod 755 "$INITRD/init"
ls -la "$INITRD" "$INITRD/bin" | head -40

echo "== 5. force initramfs regeneration + rebuild Image/dtbs =="
cd "$TREE"
# NOTE: usr/initramfs_data.S is a tracked kernel source (.incbin) -- never delete.
rm -f usr/initramfs_data.cpio usr/initramfs_data.cpio.gz usr/initramfs_data.o \
      usr/.initramfs_data* 2>/dev/null || true
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs \
     2>&1 | tee "$LK/out/kernel_build_c2.log" | tail -12
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb

echo "== 6. config drift check vs C1 export (must be identical) =="
if diff <(grep "^CONFIG_" "$TREE/.config") <(grep "^CONFIG_" "$WIN/artifacts/config-lab-6.18.44"); then
    echo "CONFIG_IDENTICAL_TO_C1"
else
    echo "CONFIG DRIFT vs C1 -- investigate"; exit 1
fi

echo "== 7. assemble + sign via C1 pipeline =="
bash "$LK/scripts/assemble_boot.sh"

echo "== 8. C2 self-check battery (C1 checks re-run) =="
python3 "$LK/scripts/c2_selfcheck.py"

echo "== 9. export artifacts + sums =="
cp -f "$INITRD/scanary" "$LK/out/scanary"
cp -f "$INITRD/scanary" "$LK/src/scanary.bin"
bash "$LK/scripts/export_artifacts.sh"
cp -f "$INITRD/scanary" "$WIN/artifacts/scanary"
cp -f "$LK/scripts/scanary_report.sh" "$WIN/artifacts/scanary_report.sh"
cp -f /tmp/scanary_qemu.log "$WIN/logs/scanary_qemu_smoketest.log" 2>/dev/null || true
cd "$WIN/artifacts"
sha256sum boot-lab-unsigned.img boot-lab-signed.img mt6990-fiberhome-lg6151m.dtb \
          Image.lab System.map.lab config-lab-6.18.44 vsurv4 scanary scanary_report.sh \
          vmlinux.zst | tee SHA256SUMS.txt
md5sum boot-lab-unsigned.img boot-lab-signed.img scanary | tee MD5SUMS.txt
echo C2_REPACK_DONE
