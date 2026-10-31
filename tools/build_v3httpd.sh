#!/bin/sh
# build_v3httpd.sh v1.2 -- v3httpd 构建 (zig cc aarch64-linux-musl 全静态)
# v1.2 (2026-10-31 vaguard 退役轮): 摘除 vaguard.o 链接 —— 防务由 nerepair 单层
#   承担; 构建零仓外依赖(_local/build/*)。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/v3httpd.c" -o "$D/gw/bin/v3httpd"
echo "built: $(ls -la "$D/gw/bin/v3httpd" | awk '{print $5}') bytes"
