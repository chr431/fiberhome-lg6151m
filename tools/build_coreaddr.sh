#!/bin/sh
# build_coreaddr.sh v1.0 -- coreaddr 构建 (zig cc aarch64-linux-musl 全静态)
# coreaddr: ELF core note-head 解析(FAR/PC), core_meta.sh v1.13+ 的运行时依赖
# (同 stackdump 链: 单一 zig cc, 零仓外依赖)。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/coreaddr.c" -o "$D/gw/bin/coreaddr"
echo "built: $(ls -la "$D/gw/bin/coreaddr" | awk '{print $5}') bytes"
