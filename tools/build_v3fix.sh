#!/bin/sh
# Build v3_fix.ko (TTL masquerade + RX unhook) with zig cc — no kbuild needed.
# One-time prep (already done in this repo):
#   1. linux-5.15.134/ extracted next to this script (tuna mirror tarball)
#   2. cmd /c mklink /J linux-5.15.134\include\uapi\asm linux-5.15.134\include\uapi\asm-generic
#   3. python tools/gen_kernel_inc.py linux-5.15.134
#   4. awk -f linux-5.15.134/arch/arm64/tools/gen-cpucaps.awk \
#        linux-5.15.134/arch/arm64/tools/cpucaps \
#        > linux-5.15.134/arch/arm64/include/generated/asm/cpucaps.h
#   5. echo '#include <asm-generic/delay.h>' \
#        > linux-5.15.134/arch/arm64/include/generated/asm/delay.h
#      (5.15.134 arm64 has no asm/delay.h in-tree; kernel build generates it)
# Verification: modinfo vermagic must equal the value in stock ebtables.ko:
#   "5.15.134 SMP mod_unload aarch64"
set -e
cd "$(dirname "$0")/.."
K=linux-5.15.134
Z=./zig-windows-x86_64-0.13.0/zig.exe
$Z cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"v3_fix"' -DKBUILD_BASENAME='"v3_fix"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -mgeneral-regs-only -mcmodel=small -O2 -fno-asynchronous-unwind-tables \
    -c v3_fix.c -o v3_fix.ko
echo "built: v3_fix.ko ($(stat -c%s v3_fix.ko) bytes)"
echo "deploy: file_transfer.py push v3_fix.ko /data/gw/v3_fix.ko"
echo "on-device: insmod /data/gw/v3_fix.ko wan_if=eth1 ttl_mode=1 unhook=1"
