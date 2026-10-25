#!/bin/sh
# Build dpquar.ko with zig cc (same chain as v3_fix.ko — see
# tools/build_v3fix.sh header for the one-time kernel-header prep).
# dpquar: quarantine dpmaif-released pages against the MD stale-buffer-list
# writes (docs/SIGSEGV_ANALYSIS.md §8).
# 装载: rc.extend.sh v2.7 起开机自载; SIGSEGV Phase 1 起默认不加载, 仅
#   FIXSTACK_ENABLE=1 时装载。手动装载: insmod /data/gw/dpquar.ko
# 参数默认值即安全值(gw/src/dpquar.c:66-68): qmask=0x3f0 hold_s=86400
#   cap=16384 watch=1 —— 不带参数加载即可。
# 历史冻结参数, 勿照抄: qmask=0x3c(v1.1 默认)与 0x3fc(v1.2 默认)都把 RX 回收
#   站点 2/3 计入隔离——正常流量下每回收一页就被钉住, held ~600/min 爬到 cap,
#   抽干驱动 RX 工作集 = 2026-10-23 00:48 渐进冻结(见 gw/src/dpquar.c:60-65)。
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
echo "on-device: insmod /data/gw/dpquar.ko   (默认 qmask=0x3f0 hold_s=86400 cap=16384 watch=1, 不带参数即可)"
