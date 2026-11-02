#!/bin/sh
# build_bmods.sh -- build the three B0-B2 read-only .ko with zig cc (no kbuild).
# Pipeline copied verbatim from build_patrace.sh (proven on-device via
# patrace/v3_steth/v3_fix/healthdog): plain -c compile against
# _local/legacy/linux-5.15.134 (modules_prepare'd, .config == device IKCONFIG),
# hand-rolled __this_module + vermagic, MODVERSIONS=n means no CRC table.
set -e
cd "$(dirname "$0")/../../../.."       # -> lg6151m-public (bmods is one level under sigsegv)
K=../_local/legacy/linux-5.15.134
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
OUTDIR=${OUTDIR:-tools/oneoff/sigsegv/bmods/out}
mkdir -p "$OUTDIR"

# tuphook needs the inline-asm trampoline (mrs tpidr_el1 / tlbi / dc / ic are
# armv8.0; paciasp is emitted as a raw .inst word) -- build_bmods keeps the
# proven flag set and only names the modules
MODS="dieblx romap ioprobe tuphook rxcount wdkill wdone"

for m in $MODS; do
    "$Z" cc -target aarch64-freestanding \
        -DMODULE -DKBUILD_MODNAME="\"$m\"" -DKBUILD_BASENAME="\"$m\"" -D__KERNEL__ \
        -nostdinc \
        -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
        -I$K/include -I$K/include/generated \
        -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
        -I$K/include/uapi -I$K/include/generated/uapi \
        -include $K/include/linux/kconfig.h \
        -ffreestanding -fno-stack-protector -fno-pie -mgeneral-regs-only -mcmodel=small -O2 -fno-asynchronous-unwind-tables \
        -Wall -Wno-unused-function \
        -c tools/oneoff/sigsegv/bmods/$m.c -o "$OUTDIR/$m.ko"
    echo "built: $OUTDIR/$m.ko ($(stat -c%s "$OUTDIR/$m.ko") bytes)"
done

# modinfo equivalent (no host modinfo): dump .modinfo strings (NUL-separated)
for m in $MODS; do
    echo "== $m =="
    tr '\0' '\n' < "$OUTDIR/$m.ko" | grep -a -E '^(vermagic|name)=' || true
done
