#!/bin/sh
# Build dpclamp.ko with zig cc (same chain as v3_fix.ko / dpquar.ko).
# dpclamp: drain the MD accumulated stale-page list out of circulation by
# sampling MOVABLE buddy pages and holding the injection-signed ones
# (docs/SIGSEGV_ANALYSIS.md section 8).
# 装载: rc.extend.sh v2.7 起开机自载(gw/rc.extend.sh); SIGSEGV Phase 1 起默认
#   不加载, 仅 FIXSTACK_ENABLE=1 时装载。
# 手动装载: insmod /data/gw/dpclamp.ko   (不带参数 = 模块默认值, 默认值即安全值)
# 历史事故参数, 勿照抄: period_s=8 batch=4096 是 2026-10-23 00:48 渐进冻结事故
#   (dpclamp v1.0)的运行组合——固定周期无退火地大批量分配 MOVABLE 页, 持续规整
#   压力约 25min 后渐进冻结 + RCU-stall panic。安全默认值见 gw/src/dpclamp.c。
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
