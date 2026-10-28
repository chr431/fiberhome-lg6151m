#!/bin/sh
# Build mipc_cellular with zig cc (same chain family as v3httpd/wpapmk builds).
# v1.1: v0.12+ 已零 RIL 依赖 — 不再链接 libqlril(纯 musl 动态, NEEDED 为空)。
set -e
cd "$(dirname "$0")/.."
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
GUARD=${GUARD:-../_local/build/vaguard.o}
"$Z" cc -target aarch64-linux-musl \
    -Os -Wall \
    gw/src/mipc_cellular.c "$GUARD" \
    -o gw/bin/mipc_cellular
file gw/bin/mipc_cellular
echo "built: gw/bin/mipc_cellular ($(stat -c%s gw/bin/mipc_cellular) bytes)"
