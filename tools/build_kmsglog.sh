#!/bin/sh
# build_kmsglog.sh v1.0 -- kmsglog 构建 (zig cc aarch64-linux-musl 全静态)
# kmsglog: /dev/kmsg 持久镜像守护(写前水位守卫/8MBx2 轮转/游标不丢),
# rc.extend v3.8+ 开机自启; 同 stackdump/coreaddr 链, 零仓外依赖。
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/kmsglog.c" -o "$D/gw/bin/kmsglog"
echo "built: $(ls -la "$D/gw/bin/kmsglog" | awk '{print $5}') bytes"
