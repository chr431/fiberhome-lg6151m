#!/bin/bash
# prep_tree.sh -- stage 1: extract pristine 6.18.44, apply the repo's mediatek
# patch set + files overlay, drop in the LG6151M lab DTS, prepare .config.
set -eu
LK="$HOME/lab-kernel"
REPO="$LK/openwrt-mt6990-lg6851f"
TREE="$LK/linux-6.18.44"
TARBALL="$LK/linux-6.18.44.tar.xz"
EXPECT_SHA="0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43"

cd "$LK"
echo "== 0. verify tarball =="
if echo "$EXPECT_SHA  $LK/linux-6.18.44.owrt.tar.xz" | sha256sum -c - 2>/dev/null; then
    TARBALL="$LK/linux-6.18.44.owrt.tar.xz"   # openwrt mirror = byte-identical to kernel.org
    echo "using openwrt-mirror tarball (sha256 pinned match)"
elif echo "$EXPECT_SHA  $LK/linux-6.18.44.tar.xz" | sha256sum -c - 2>/dev/null; then
    TARBALL="$LK/linux-6.18.44.tar.xz"
    echo "using kernel.org tarball (sha256 pinned match)"
else
    TARBALL="$LK/linux-6.18.44.gh.tar.gz"    # gregkh/linux tag v6.18.44 (same content, different container)
    [ -f "$TARBALL" ] || { echo "no kernel tarball available"; exit 1; }
    echo "WARNING: using github gregkh tag tarball; pinned sha256 not applicable to this container"
fi
echo "TARBALL=$TARBALL"

echo "== 1. extract =="
rm -rf "$TREE"
tar xf "$TARBALL" -C "$LK"
[ -f "$TREE/Makefile" ] || { echo "extract failed: $TREE/Makefile missing"; exit 1; }
grep -E "^VERSION|^PATCHLEVEL|^SUBLEVEL|^EXTRAVERSION" "$TREE/Makefile" | head -4

echo "== 2. overlay files (OpenWrt order: generic/files, target files, target files-6.18) =="
cp -a "$REPO"/target/linux/generic/files/. "$TREE"/
cp -a "$REPO"/target/linux/mediatek/files/. "$TREE"/
cp -a "$REPO"/target/linux/mediatek/files-6.18/. "$TREE"/

echo "== 3. apply patches (OpenWrt order: backport -> pending -> hack -> platform) =="
cd "$TREE"
fail=0; applied=0
: > "$LK/out/patch_failures.txt"
apply_dir() {
    local label="$1" dir="$2"
    [ -d "$dir" ] || return 0
    for p in $(LC_ALL=C ls "$dir"/*.patch 2>/dev/null | LC_ALL=C sort); do
        if out=$(patch -p1 --forward --no-backup-if-mismatch < "$p" 2>&1); then
            applied=$((applied+1))
        else
            fail=$((fail+1))
            echo "PATCH FAILED [$label]: $(basename "$p")" | tee -a "$LK/out/patch_failures.txt"
            echo "$out" | head -8 >> "$LK/out/patch_failures.txt"
        fi
    done
}
apply_dir backport  "$REPO/target/linux/generic/backport-6.18"
apply_dir pending   "$REPO/target/linux/generic/pending-6.18"
apply_dir hack      "$REPO/target/linux/generic/hack-6.18"
apply_dir platform  "$REPO/target/linux/mediatek/patches-6.18"
echo "patches applied=$applied failed=$fail (details: out/patch_failures.txt)"
find "$TREE" -name "*.rej" -delete
find "$TREE" -name "*.orig" -delete

echo "== 4. install LG6151M lab DTS =="
cp "$LK/out/mt6990-fiberhome-lg6151m.dts" "$TREE/arch/arm64/boot/dts/mediatek/"
MK="$TREE/arch/arm64/boot/dts/mediatek/Makefile"
grep -q "mt6990-fiberhome-lg6151m" "$MK" || \
  printf 'dtb-$(CONFIG_ARCH_MEDIATEK) += mt6990-fiberhome-lg6151m.dtb\n' >> "$MK"

echo "== 5. base config + instrumentation =="
# OpenWrt layering: generic/config-6.18 (base) + mt6990/config-6.18 (subtarget,
# appended = wins on duplicates) + our instrumentation enables.
cat "$REPO/target/linux/generic/config-6.18" > "$TREE/.config"
cat "$REPO/target/linux/mediatek/mt6990/config-6.18" >> "$TREE/.config"
cd "$TREE"
K=scripts/config
$K --enable KPROBES
$K --enable KPROBE_EVENTS
$K --enable FTRACE
$K --enable TRACING
$K --enable DYNAMIC_FTRACE
$K --enable FUNCTION_TRACER
$K --enable FUNCTION_GRAPH_TRACER
$K --enable FTRACE_SYSCALLS
$K --enable PERF_EVENTS
$K --enable HW_BREAKPOINT
$K --enable USERFAULTFD
$K --enable PROC_PAGE_MONITOR
$K --enable KEXEC
$K --enable KEXEC_FILE
$K --enable KGDB
$K --enable KGDB_SERIAL_CONSOLE
$K --enable KGDB_KDB
$K --enable KALLSYMS
$K --enable KALLSYMS_ALL
$K --enable UPROBE_EVENTS
$K --enable PAGE_OWNER
$K --enable DEBUG_FS
$K --enable IKCONFIG
$K --enable IKCONFIG_PROC
$K --enable GDB_SCRIPTS
$K --enable PROC_KCORE
$K --enable DEVMEM
$K --disable STRICT_DEVMEM
$K --disable PANIC_ON_OOPS
$K --set-val PANIC_TIMEOUT 10
$K --enable BLK_DEV_INITRD
$K --enable RD_GZIP
$K --enable INITRAMFS_COMPRESSION_GZIP
# keep initramfs source empty here; build stage fills it
$K --set-str INITRAMFS_SOURCE ""

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null

echo "== 6. verify required symbols =="
miss=0
for s in CONFIG_KPROBES CONFIG_KPROBE_EVENTS CONFIG_DYNAMIC_FTRACE \
         CONFIG_FUNCTION_TRACER CONFIG_PERF_EVENTS CONFIG_HW_BREAKPOINT \
         CONFIG_USERFAULTFD CONFIG_PROC_PAGE_MONITOR CONFIG_KEXEC \
         CONFIG_KEXEC_FILE CONFIG_KGDB CONFIG_KGDB_SERIAL_CONSOLE \
         CONFIG_KALLSYMS_ALL CONFIG_UPROBE_EVENTS CONFIG_PAGE_OWNER \
         CONFIG_DEBUG_FS CONFIG_BLK_DEV_INITRD CONFIG_SERIAL_8250_MT6577 \
         CONFIG_MMC_MTK CONFIG_SMP CONFIG_IKCONFIG_PROC; do
    if grep -q "^$s=y" .config; then
        echo "OK   $s"
    else
        echo "MISS $s"
        miss=$((miss+1))
    fi
done
echo "missing=$miss"
[ "$miss" -eq 0 ] || echo "WARNING: some symbols missing -- inspect before build"
echo PREP_DONE
