#!/bin/bash
# v2_repack.sh -- lab kernel V2 repack (pure offline, no device contact).
# Fixes over the C2/v1 session kernel (both seen live 2026-11-01/02):
#   F1  initramfs cpio now ships /dev/console (c 5:1 mode 0600) and
#       /dev/null (c 1:3 mode 0666) as static nodes in the source dir ->
#       gen_initramfs.sh emits `nod` entries.  v1: no console node, kernel
#       could not open the initial console for rdinit PID1 -> ash exited
#       instantly -> panic "Attempted to kill init"
#       (phase-AB/c2-serial/console-s4-20261102-0046.log:4055).
#   F2  /init v2: same pre-registered scanary window-1 invocation (binary
#       unchanged), then interactive shell on console (setsid+cttyhack,
#       respawn loop), heartbeat kept (10s in-window, 60s hb-slow after).
#   F3  /bin/netup zero-conf 169.254/16 helper on eth* ports.
# Kernel .config: ZERO drift vs the C1/C2 export (verified below); the 26
# observation symbols are frozen.  scanary/vsurv4/busybox binaries are
# asserted byte-identical (md5) to the ones that ran on-device tonight.
set -eu
LK="$HOME/lab-kernel"
TREE="$LK/linux-6.18.44"
INITRD="$LK/initramfs"
WIN=/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel
SCRIPTS_WIN="$WIN/scripts"
QEMU=$(command -v qemu-aarch64-static)

echo "== 0. preflight: CRLF gate + canary integrity vs the on-device v1 =="
for f in "$SCRIPTS_WIN/lab_init_v2.sh" "$SCRIPTS_WIN/netup.sh"; do
    if grep -q $'\r' "$f"; then echo "CRLF found in $f -- aborting"; exit 1; fi
done
md5sum "$INITRD/scanary" "$INITRD/vsurv4" "$INITRD/bin/busybox"
for pair in "scanary:17376b743d1df55240b77f8f0be0fdae" \
            "vsurv4:b4f32f329c6bcaaa4231e6f7d52c2915" \
            "bin/busybox:baf625fa8babda6d11027bfe175e0132"; do
    f=${pair%%:*}; want=${pair##*:}
    got=$(md5sum "$INITRD/$f" | cut -d" " -f1)
    [ "$got" = "$want" ] || { echo "INTEGRITY FAIL: $f md5 $got != $want"; exit 1; }
done
echo "canary/busybox integrity OK (same binaries that ran the C2 session)"

echo "== 1. F1: static device nodes in the initramfs source dir =="
mkdir -p "$INITRD/dev"
rm -f "$INITRD/dev/console" "$INITRD/dev/null"
mknod -m 600 "$INITRD/dev/console" c 5 1
mknod -m 666 "$INITRD/dev/null" c 1 3
ls -la "$INITRD/dev"

echo "== 2. F3: netup + F2: cttyhack/setsid applet symlinks =="
cp -f "$SCRIPTS_WIN/netup.sh" "$INITRD/bin/netup"
chmod 755 "$INITRD/bin/netup"
ln -sf busybox "$INITRD/bin/setsid"
ln -sf busybox "$INITRD/bin/cttyhack"
ls -la "$INITRD/bin/netup" "$INITRD/bin/setsid" "$INITRD/bin/cttyhack" "$INITRD/bin/sh"

echo "== 3. F2: install V2 /init + syntax check under the real initramfs busybox =="
cp -f "$SCRIPTS_WIN/lab_init_v2.sh" "$INITRD/init"
chmod 755 "$INITRD/init"
[ -n "$QEMU" ] || { echo "qemu-aarch64-static missing"; exit 1; }
"$QEMU" "$INITRD/bin/busybox" sh -n "$INITRD/init"
"$QEMU" "$INITRD/bin/busybox" sh -n "$INITRD/bin/netup"
echo "sh -n syntax OK for init v2 + netup"
md5sum "$INITRD/init"

echo "== 4. force initramfs regeneration + rebuild Image/dtbs =="
cd "$TREE"
# NOTE: usr/initramfs_data.S is a tracked kernel source (.incbin) -- never delete.
rm -f usr/initramfs_data.cpio usr/initramfs_data.cpio.gz usr/initramfs_data.o \
      usr/.initramfs_data* 2>/dev/null || true
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs \
     2>&1 | tee "$LK/out/kernel_build_v2.log" | tail -12
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb

echo "== 5. config drift check vs C1/C2 export (must be identical) =="
if diff <(grep "^CONFIG_" "$TREE/.config") <(grep "^CONFIG_" "$WIN/artifacts/config-lab-6.18.44") >/dev/null; then
    echo "CONFIG_IDENTICAL_TO_C1"
else
    echo "CONFIG DRIFT vs C1 -- investigate"; exit 1
fi

echo "== 6. 26/26 observation symbols (canonical C1 reconfig list) =="
missing=0
for s in CONFIG_KPROBES CONFIG_KPROBE_EVENTS CONFIG_DYNAMIC_FTRACE \
         CONFIG_FUNCTION_TRACER CONFIG_PERF_EVENTS CONFIG_HAVE_HW_BREAKPOINT \
         CONFIG_USERFAULTFD CONFIG_PROC_PAGE_MONITOR CONFIG_KEXEC \
         CONFIG_KEXEC_FILE CONFIG_KGDB CONFIG_KGDB_SERIAL_CONSOLE \
         CONFIG_KALLSYMS_ALL CONFIG_UPROBE_EVENTS CONFIG_PAGE_OWNER \
         CONFIG_DEBUG_FS CONFIG_BLK_DEV_INITRD CONFIG_SERIAL_8250_MT6577 \
         CONFIG_MMC_MTK CONFIG_SMP CONFIG_IKCONFIG_PROC \
         CONFIG_FTRACE CONFIG_TRACING CONFIG_FUNCTION_GRAPH_TRACER \
         CONFIG_KGDB_KDB CONFIG_PANIC_TIMEOUT; do
    grep -q "^$s=y" "$TREE/.config" || grep -q "^$s=10$" "$TREE/.config" \
        || { echo "MISSING SYMBOL: $s"; missing=1; }
done
[ "$missing" = "0" ] && echo "OBSERVATION_SYMBOLS_26_OF_26_OK" || { echo "symbol check failed"; exit 1; }

echo "== 7. assemble + sign (boot-lab2-*) =="
bash "$LK/scripts/v2_assemble_boot.sh"

echo "== 8. V2 self-check battery (inherited 29 + F1/F2/F3 17) =="
python3 "$LK/scripts/v2_selfcheck.py"

echo "== 9. export v2 artifacts to the Windows side =="
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
echo V2_REPACK_DONE
