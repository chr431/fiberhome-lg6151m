#!/bin/sh
# Build v3_fix.ko (TTL masquerade + RX unhook) with zig cc — no kbuild needed.
# v1.1 (2026-10-18): 路径修正到当前布局(内核树=_local/legacy, 源码=gw/src,
#   产物=gw/bin) + 记录 2026-10-18 事故: 旧产物 ELF 节表整体错位 1 字节(某处
#   被插入 1B), 内核报 "Invalid ELF section hdr(type 768)" 拒载 — **每次开机
#   都在静默失败**, 由 24h 日志轮抓获。重建即修复; selftest t_v3fix_loaded 护栏。
# One-time prep (内核树在 _local/legacy/linux-5.15.134, 多数已就绪):
#   1. include/uapi/asm 与 include/generated/uapi/asm: 原 NTFS junction 指向
#      旧绝对路径(D:\Repo\lg6151m\...)已失效 — 用 cp -r asm-generic 就地复制
#      (junction 换机器必坏, 不再使用)。
#   2. python tools/gen_kernel_inc.py <ksrc>   (analysis/kernel_ev 缺失时仅末步
#      失败, 其余生成物已在树内)
#   3. awk -f $K/arch/arm64/tools/gen-cpucaps.awk $K/arch/arm64/tools/cpucaps \
#        > $K/arch/arm64/include/generated/asm/cpucaps.h
#   4. echo '#include <asm-generic/delay.h>' > $K/include/generated/asm/delay.h
# Verification: vermagic 必须等于 stock ebtables.ko 的
#   "5.15.134 SMP mod_unload aarch64"; 加载实测见 selftest t_v3fix_loaded。
set -e
cd "$(dirname "$0")/.."
K=../_local/legacy/linux-5.15.134
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-freestanding \
    -DMODULE -DKBUILD_MODNAME='"v3_fix"' -DKBUILD_BASENAME='"v3_fix"' -D__KERNEL__ \
    -nostdinc \
    -I$K/arch/arm64/include -I$K/arch/arm64/include/generated \
    -I$K/include -I$K/include/generated \
    -I$K/arch/arm64/include/uapi -I$K/arch/arm64/include/generated/uapi \
    -I$K/include/uapi -I$K/include/generated/uapi \
    -include $K/include/linux/kconfig.h \
    -ffreestanding -fno-stack-protector -fno-pie -mgeneral-regs-only -mcmodel=small -O2 -fno-asynchronous-unwind-tables \
    -c gw/src/v3_fix.c -o gw/bin/v3_fix.ko
echo "built: gw/bin/v3_fix.ko ($(stat -c%s gw/bin/v3_fix.ko) bytes)"
echo "deploy: deploy.py push gw/bin/v3_fix.ko"
echo "on-device: insmod /data/gw/v3_fix.ko wan_if= ttl_mode=1 unhook=1"
