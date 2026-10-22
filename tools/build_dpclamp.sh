#!/bin/sh
# Build dpclamp.ko with zig cc (same chain as v3_fix.ko / dpquar.ko).
# dpclamp: drain the MD accumulated stale-page list out of circulation by
# sampling MOVABLE buddy pages and holding the injection-signed ones
# (docs/SIGSEGV_ANALYSIS.md section 8). Not auto-loaded at boot yet.
# on-device: insmod /data/gw/dpclamp.ko period_s=8 batch=4096
set -e
cd "$(dirname "$0")/.."
K=../_local/legacy/linux-5.15.134
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"dpclamp"' -DKBUILD_BASENAME='"dpclamp"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -fno-pic -mcmodel=small -mgeneral-regs-only -O2 -fno-asynchronous-unwind-tables \
    -c gw/src/dpclamp.c -o gw/bin/dpclamp.ko
echo "built: gw/bin/dpclamp.ko ($(stat -c%s gw/bin/dpclamp.ko) bytes)"
