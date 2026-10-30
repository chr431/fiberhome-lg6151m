#!/bin/sh
# build_nerepair.sh v1.0 -- nerepair 构建 (zig cc aarch64-linux-musl 全静态)
# v1.0 (2026-10-31 资产归位轮): 源码自 tools/oneoff/sigsegv/ 迁入 gw/src/ 并入
#   注册表(此前生产二进制的源码滞留 oneoff = 部署不可重现点)。vaguard 与
#   v3httpd/mipc_cellular 同款链接(FIX.md: 静态二进制一律带闸门)。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
GUARD=${GUARD:-$D/../_local/build/vaguard.o}
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/nerepair.c" "$GUARD" -o "$D/gw/bin/nerepair"
echo "built: $(ls -la "$D/gw/bin/nerepair" | awk '{print $5}') bytes"
