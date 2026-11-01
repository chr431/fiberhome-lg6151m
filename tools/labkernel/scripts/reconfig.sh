#!/bin/bash
# reconfig.sh -- iterate config only (tree already prepared).
set -eu
LK="$HOME/lab-kernel"
REPO="$LK/openwrt-mt6990-lg6851f"
TREE="$LK/linux-6.18.44"
cd "$TREE"

cat "$REPO/target/linux/generic/config-6.18" > .config
cat "$REPO/target/linux/mediatek/mt6990/config-6.18" >> .config

K=scripts/config
$K --enable FTRACE
$K --enable TRACING
$K --enable KPROBES
$K --enable KPROBE_EVENTS
$K --enable UPROBES
$K --enable UPROBE_EVENTS
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
$K --enable VT
$K --enable KGDB_SERIAL_CONSOLE
$K --enable KGDB_KDB
$K --enable KALLSYMS
$K --enable KALLSYMS_ALL
$K --enable PAGE_OWNER
$K --enable DEBUG_FS
$K --enable IKCONFIG
$K --enable IKCONFIG_PROC
$K --enable GDB_SCRIPTS
$K --enable PROC_KCORE
$K --enable DEVMEM
$K --disable STRICT_DEVMEM
$K --disable IO_STRICT_DEVMEM
$K --disable PANIC_ON_OOPS
$K --set-val PANIC_TIMEOUT 10
$K --enable BLK_DEV_INITRD
$K --enable RD_GZIP
$K --enable INITRAMFS_COMPRESSION_GZIP
$K --set-str INITRAMFS_SOURCE ""

make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null >/dev/null

miss=0
for s in CONFIG_KPROBES CONFIG_KPROBE_EVENTS CONFIG_DYNAMIC_FTRACE \
         CONFIG_FUNCTION_TRACER CONFIG_PERF_EVENTS CONFIG_HAVE_HW_BREAKPOINT \
         CONFIG_USERFAULTFD CONFIG_PROC_PAGE_MONITOR CONFIG_KEXEC \
         CONFIG_KEXEC_FILE CONFIG_KGDB CONFIG_KGDB_SERIAL_CONSOLE \
         CONFIG_KALLSYMS_ALL CONFIG_UPROBE_EVENTS CONFIG_PAGE_OWNER \
         CONFIG_DEBUG_FS CONFIG_BLK_DEV_INITRD CONFIG_SERIAL_8250_MT6577 \
         CONFIG_MMC_MTK CONFIG_SMP CONFIG_IKCONFIG_PROC \
         CONFIG_FTRACE CONFIG_TRACING CONFIG_FUNCTION_GRAPH_TRACER \
         CONFIG_KGDB_KDB CONFIG_PANIC_TIMEOUT; do
    if grep -q "^$s=y" .config || grep -q "^$s=10$" .config; then
        echo "OK   $s"
    else
        echo "MISS $s = $(grep "^$s" .config | head -1)"
        miss=$((miss+1))
    fi
done
echo "missing=$miss"
echo RECONFIG_DONE
