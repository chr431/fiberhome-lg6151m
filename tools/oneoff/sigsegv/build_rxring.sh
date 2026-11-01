#!/bin/sh
set -e
cd "$(dirname "$0")/../../.."
K=../_local/legacy/linux-5.15.134
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
OUT=${OUT:-../_local/work/crash-root/rxring.ko}
"$Z" cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"rxring"' -DKBUILD_BASENAME='"rxring"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -mgeneral-regs-only -mcmodel=small -O2 -fno-asynchronous-unwind-tables \
    -c tools/oneoff/sigsegv/rxring.c -o "$OUT"
echo "built: $OUT ($(stat -c%s "$OUT") bytes)"
