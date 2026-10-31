#!/bin/sh
# build_nerepair.sh v1.2 -- nerepair 构建 (zig cc aarch64-linux-musl 全静态)
# v1.0 (2026-10-31 资产归位轮): 源码自 tools/oneoff/sigsegv/ 迁入 gw/src/ 并入
#   注册表(此前生产二进制的源码滞留 oneoff = 部署不可重现点)。
# v1.2 (2026-10-31 vaguard 退役轮): 摘除 vaguard.o 链接 —— nerepair 是唯一
#   防线, 自身不得依赖被退役的闸门; 构建自此零仓外依赖(_local/build/*)。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/nerepair.c" -o "$D/gw/bin/nerepair"
echo "built: $(ls -la "$D/gw/bin/nerepair" | awk '{print $5}') bytes"
