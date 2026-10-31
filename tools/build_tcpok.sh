#!/bin/sh
# build_tcpok.sh v1.0 -- tcpok 构建 (zig cc aarch64-linux-musl 全静态)
# 判据审计轮: avail_watch 的 2s 节拍连接探测件(裸 TCP connect, 服务端零日志)。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/tcpok.c" -o "$D/gw/bin/tcpok"
echo "built: $(ls -la "$D/gw/bin/tcpok" | awk '{print $5}') bytes"
