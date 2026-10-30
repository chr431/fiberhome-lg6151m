#!/bin/sh
# build_stackdump.sh v1.0 -- stackdump 构建 (zig cc aarch64-linux-musl 全静态)
# v1.0 (2026-10-31 资产归位轮): 源码自 tools/oneoff/sigsegv/ 迁入 gw/src/、二进制
#   入 gw/bin/ 并进 deploy manifest —— 此前 core_meta.sh v1.7+ 依赖
#   /data/gw/bin/stackdump 却靠手工推送(头注一句"push 后 chmod 755"), 部署
#   不可重现。vaguard 与 v3httpd 同款链接。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
GUARD=${GUARD:-$D/../_local/build/vaguard.o}
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/stackdump.c" "$GUARD" -o "$D/gw/bin/stackdump"
echo "built: $(ls -la "$D/gw/bin/stackdump" | awk '{print $5}') bytes"
