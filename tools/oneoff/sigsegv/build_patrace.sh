#!/bin/sh
# build_patrace.sh -- build patrace.ko with zig cc (no kbuild), same flags as build_v3fix.sh.
set -e
cd "$(dirname "$0")/../../.."          # -> lg6151m-public
K=../_local/legacy/linux-5.15.134
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
OUT=${OUT:-../_local/work/crash-root/patrace.ko}
"$Z" cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"patrace"' -DKBUILD_BASENAME='"patrace"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -mgeneral-regs-only -mcmodel=small -O2 -fno-asynchronous-unwind-tables \
    -c tools/oneoff/sigsegv/patrace.c -o "$OUT"
echo "built: $OUT ($(stat -c%s "$OUT") bytes)"
