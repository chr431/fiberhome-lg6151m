#!/bin/sh
# Build healthdog.ko with zig cc (same chain as v3_fix.ko — see
# tools/build_v3fix.sh header for the one-time kernel-header prep).
set -e
cd "$(dirname "$0")/.."
K=linux-5.15.134
Z=./zig-windows-x86_64-0.13.0/zig.exe
$Z cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"healthdog"' -DKBUILD_BASENAME='"healthdog"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -fno-pic -mcmodel=small \
    -mgeneral-regs-only -O2 -fno-asynchronous-unwind-tables \
    -c healthdog.c -o healthdog.ko
python tools/ko_check.py healthdog.ko | grep -E "text|modinfo: vermagic|modinfo: name"
echo "built: healthdog.ko ($(stat -c%s healthdog.ko) bytes)"
