#!/bin/sh
# Build dpquar.ko with zig cc (same chain as v3_fix.ko — see
# tools/build_v3fix.sh header for the one-time kernel-header prep).
# dpquar: quarantine dpmaif-released pages against the MD stale-buffer-list
# writes (docs/SIGSEGV_ANALYSIS.md §8). Not yet auto-loaded at boot; manual
# load: insmod /data/gw/dpquar.ko [qmask=0x30] [hold_s=86400] [cap=4096]
set -e
cd "$(dirname "$0")/.."
K=../_local/legacy/linux-5.15.134
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"dpquar"' -DKBUILD_BASENAME='"dpquar"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -fno-pic -mcmodel=small -mgeneral-regs-only -O2 -fno-asynchronous-unwind-tables \
    -c gw/src/dpquar.c -o gw/bin/dpquar.ko
echo "built: gw/bin/dpquar.ko ($(stat -c%s gw/bin/dpquar.ko) bytes)"
echo "deploy: python tools/deploy.py push   (manifest entry in place)"
echo "on-device: insmod /data/gw/dpquar.ko qmask=0x30 hold_s=86400 cap=4096 watch=1"
