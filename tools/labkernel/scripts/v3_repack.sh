#!/bin/bash
# v3_repack.sh -- lab kernel V3.1 "refined + asset" build (pure offline).
# V3.1 = V3 + three /init corrections (kernel, scanary, config unchanged):
#   FIX-1 TRY_A write target is p1 offset 2061 (the A/B control block lives
#         in the misc partition, which starts at sector 64).  V3 wrote the
#         RAW device offset 2061 -- that byte belongs to a GPT entry, so a
#         v3 boot silently destroyed the GPT entries CRC.  NEVER write raw
#         /dev/mmcblk0 offset 2061; the preflight below enforces this.
#   FIX-2 window-end full scanary log to console (bytes/lines/md5 + full
#         cat) -- second channel beside the post-window interactive shell.
#   FIX-3 alive_check reads /proc/<pid>/stat comm (cmdline carries NULs, a
#         whole-line read never equals argv[0] -> false "0 alive").
# On top of the V2 tree state (which already carries the F1 nodes and F2/F3
# helpers) V3 adds, and V3.1 keeps:
#   A  reliability: MTK_LVTS_THERMAL + thermal-guard in /init,
#      watchdog feeder (MEDIATEK_WATCHDOG already built in),
#      TRY_A auto-clear (p1 misc block offset 2061), boot card.
#   B  V5 reserves: mt76/mt7996e + cfg80211/mac80211 as MODULES (stripped,
#      staged in initramfs /modules, never loaded), /bin/romount, /bin/kjump.
# Discipline: the 26 observation config symbols stay frozen; config changes
# vs v2 must be additions only (verified).
set -eu
LK="$HOME/lab-kernel"
TREE="$LK/linux-6.18.44"
INITRD="$LK/initramfs"
WIN=/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel
SCRIPTS_WIN="$WIN/scripts"
CFG_V2="$WIN/artifacts/config-lab2-6.18.44"
QEMU=$(command -v qemu-aarch64-static)
STRIP=aarch64-linux-gnu-strip

echo "== 0. preflight =="
for f in "$SCRIPTS_WIN/lab_init_v3.sh" "$SCRIPTS_WIN/romount.sh" "$SCRIPTS_WIN/kjump.sh"; do
    if grep -q $'\r' "$f"; then echo "CRLF found in $f -- aborting"; exit 1; fi
done
for pair in "scanary:17376b743d1df55240b77f8f0be0fdae" \
            "vsurv4:b4f32f329c6bcaaa4231e6f7d52c2915" \
            "bin/busybox:baf625fa8babda6d11027bfe175e0132"; do
    f=${pair%%:*}; want=${pair##*:}
    got=$(md5sum "$INITRD/$f" | cut -d" " -f1)
    [ "$got" = "$want" ] || { echo "INTEGRITY FAIL: $f md5 $got != $want"; exit 1; }
done
[ -c "$INITRD/dev/console" ] || { echo "dev/console node missing from v2 state"; exit 1; }

# ---- TRY_A write-target guard (regression for the v3 GPT-corruption defect) ----
# Authority: D28 report (docs/SIGSEGV/05_LOG/2026-11-03-12-d28-labv3-revalidation.md
# section 9b/11) -- p1@2060..2069 = 0f 00 01 00 00 0e 00 01 (A/B control block);
# raw /dev/mmcblk0@2061 is a GPT partition-entry byte (misc partition begins at
# sector 64).  Writing the raw offset destroys the GPT entries CRC.
INIT_SRC="$SCRIPTS_WIN/lab_init_v3.sh"
if ! grep -q 'P1=/dev/mmcblk0p1' "$INIT_SRC"; then
    echo "TRYA_GUARD FAIL: init does not target /dev/mmcblk0p1 -- abort"; exit 1
fi
if ! grep -q 'skip=2060 count=10' "$INIT_SRC"; then
    echo "TRYA_GUARD FAIL: init lacks the p1[2060..2069] before/after hexdump -- abort"; exit 1
fi
if grep -Eq 'of=/dev/mmcblk0([^0-9p]|$)' "$INIT_SRC"; then
    echo "TRYA_GUARD FAIL: raw /dev/mmcblk0 write found -- GPT entries corruption risk, abort"; exit 1
fi
if grep -Eq '(seek|skip)=2061' "$INIT_SRC"; then
    while IFS= read -r ln; do
        case "$ln" in
            *seek=2061*|*skip=2061*)
                case "$ln" in
                    *'$P1'*|*mmcblk0p1*) : ;;
                    *) echo "TRYA_GUARD FAIL: offset 2061 access without the p1 device: $ln"; exit 1 ;;
                esac ;;
        esac
    done < "$INIT_SRC"
fi
echo "TRYA_GUARD_OK (TRY_A target = p1@2061; raw-device 2061 forbidden)"

echo "== 1. install V3.1 /init + helpers =="
cp -f "$SCRIPTS_WIN/lab_init_v3.sh" "$INITRD/init";         chmod 755 "$INITRD/init"
cp -f "$SCRIPTS_WIN/romount.sh"     "$INITRD/bin/romount";  chmod 755 "$INITRD/bin/romount"
cp -f "$SCRIPTS_WIN/kjump.sh"       "$INITRD/bin/kjump";    chmod 755 "$INITRD/bin/kjump"
[ -n "$QEMU" ] || { echo "qemu-aarch64-static missing"; exit 1; }
"$QEMU" "$INITRD/bin/busybox" sh -n "$INITRD/init"
"$QEMU" "$INITRD/bin/busybox" sh -n "$INITRD/bin/romount"
"$QEMU" "$INITRD/bin/busybox" sh -n "$INITRD/bin/kjump"
"$QEMU" "$INITRD/bin/busybox" sh -n "$INITRD/bin/netup"
echo "sh -n syntax OK (init v3.1 + romount + kjump + netup)"
md5sum "$INITRD/init"

echo "== 2. config additions (additive only) =="
cd "$TREE"
cp -f .config "$LK/out/config-before-v3.selfcheck-copy" 2>/dev/null || true
K=scripts/config
$K --enable MTK_THERMAL
$K --enable MTK_LVTS_THERMAL
$K --enable MTK_LVTS_THERMAL_DEBUGFS
$K --module CFG80211
$K --module MAC80211
$K --enable WLAN_VENDOR_MEDIATEK   # vendor gate off in base config -> mt76 symbols invisible otherwise
$K --module MT76_CORE
$K --module MT76_CONNAC_LIB
$K --module MT7996E
$K --disable MT76_LEDS
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null >/dev/null

echo "== 3. config discipline gates =="
# 3a. 26 observation symbols unchanged vs v2
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
    a=$(grep "^$s=" .config | head -1)
    b=$(grep "^$s=" "$CFG_V2" | head -1)
    [ "$a" = "$b" ] && [ -n "$a" ] || { echo "OBS SYMBOL CHANGED: $s: '$b' -> '$a'"; missing=1; }
done
[ "$missing" = "0" ] && echo "OBS26_FROZEN_OK" || { echo "observation symbol drift -- abort"; exit 1; }
# 3b. no removals/changes vs v2 (additions only); print the delta
diff <(grep "^CONFIG_" "$CFG_V2" | sort) <(grep "^CONFIG_" .config | sort) \
    | tee "$LK/out/config_delta_v3_vs_v2.txt" || true
n_rem=$(diff <(grep "^CONFIG_" "$CFG_V2" | cut -d= -f1 | sort) \
              <(grep "^CONFIG_" .config | cut -d= -f1 | sort) | grep -c "^<" || true)
[ "$n_rem" = "0" ] || { echo "config symbols REMOVED vs v2 -- abort"; exit 1; }

echo "== 4. rebuild Image/dtbs FIRST (new config pulls KEYS/CRYPTO_RSA into =y; modpost needs the fresh Module.symvers) =="
rm -f usr/initramfs_data.cpio usr/initramfs_data.cpio.gz usr/initramfs_data.o \
      usr/.initramfs_data* 2>/dev/null || true
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs \
     2>&1 | tee "$LK/out/kernel_build_v3.log" | tail -6
ls -la arch/arm64/boot/Image

echo "== 5. build modules (wifi reserve) =="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" modules \
     2>&1 | tee "$LK/out/modules_build_v3.log" | tail -4
mkdir -p "$INITRD/modules"
for ko in net/wireless/cfg80211.ko net/mac80211/mac80211.ko \
          drivers/net/wireless/mediatek/mt76/mt76.ko \
          drivers/net/wireless/mediatek/mt76/mt76-connac-lib.ko \
          drivers/net/wireless/mediatek/mt76/mt7996/mt7996e.ko; do
    [ -f "$TREE/$ko" ] || { echo "module missing after build: $ko"; exit 1; }
    "$STRIP" --strip-debug "$TREE/$ko"
    cp -f "$TREE/$ko" "$INITRD/modules/"
done
ls -la "$INITRD/modules/"

echo "== 5b. re-link Image with modules inside the initramfs =="
rm -f usr/initramfs_data.cpio usr/initramfs_data.cpio.gz usr/initramfs_data.o \
      usr/.initramfs_data* 2>/dev/null || true
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$(nproc)" Image dtbs \
     2>&1 | tee -a "$LK/out/kernel_build_v3.log" | tail -6
ls -la arch/arm64/boot/Image arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb

echo "== 6. assemble + sign (boot-lab31-*) =="
bash "$LK/scripts/v3_assemble_boot.sh"

echo "== 7. V3.1 self-check battery =="
python3 "$LK/scripts/v3_selfcheck.py"

echo "== 8. export v3.1 artifacts to the Windows side =="
cp -f "$LK/out/boot-lab31-unsigned.img" "$LK/out/boot-lab31-signed.img" "$WIN/artifacts/"
cp -f "$TREE/arch/arm64/boot/Image" "$WIN/artifacts/Image.lab31"
cp -f "$TREE/System.map" "$WIN/artifacts/System.map.lab31"
cp -f "$TREE/.config" "$WIN/artifacts/config-lab3-6.18.44"
cp -f "$LK/out/mt6990-fiberhome-lg6151m.dtb" "$WIN/artifacts/" 2>/dev/null \
    || cp -f "$TREE/arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb" "$WIN/artifacts/"
cp -f "$INITRD/init" "$WIN/artifacts/lab_init_v31.sh"
cp -f "$INITRD/bin/netup" "$WIN/artifacts/netup"
cp -f "$INITRD/bin/romount" "$WIN/artifacts/romount"
cp -f "$INITRD/bin/kjump" "$WIN/artifacts/kjump"
mkdir -p "$WIN/artifacts/modules"
cp -f "$INITRD/modules/"*.ko "$WIN/artifacts/modules/"
zstd -T0 -12 -q -f -o "$WIN/artifacts/vmlinux.lab31.zst" "$TREE/vmlinux"
for lg in kernel_build_v3 modules_build_v3 sign_boot_v31 config_delta_v3_vs_v2; do
    cp -f "$LK/out/$lg.txt" "$LK/out/$lg.log" "$WIN/logs/" 2>/dev/null || true
done
cd "$WIN/artifacts"
sha256sum boot-lab31-unsigned.img boot-lab31-signed.img Image.lab31 System.map.lab31 \
          config-lab3-6.18.44 vmlinux.lab31.zst lab_init_v31.sh netup romount kjump \
          modules/*.ko | tee -a SHA256SUMS.txt
md5sum boot-lab31-unsigned.img boot-lab31-signed.img modules/*.ko | tee -a MD5SUMS.txt
echo V31_REPACK_DONE
