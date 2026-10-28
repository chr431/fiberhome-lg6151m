#!/bin/sh
# build_v3httpd.sh v1.0 -- v3httpd 构建 (zig cc aarch64-linux-musl 全静态)
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
GUARD=${GUARD:-$D/../_local/build/vaguard.o}
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/v3httpd.c" "$GUARD" -o "$D/gw/bin/v3httpd"
echo "built: $(ls -la "$D/gw/bin/v3httpd" | awk '{print $5}') bytes"
