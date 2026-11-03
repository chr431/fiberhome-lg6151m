#!/bin/sh
# build_slotguard.sh v1.0 -- slotguard 构建 (zig cc aarch64-linux-musl 全静态)
# 产物: gw/bin/slotguard (设备 /data/gw/bin/slotguard)
# 零仓外依赖: 只用 zig 与 gw/src/slotguard.c (与 build_nerepair.sh 同链)。
# host selftest 通道(不产出设备件):
#   zig cc -target x86_64-windows-gnu -O2 gw/src/slotguard.c -o slotguard_host.exe
#   ./slotguard_host.exe --selftest      # 必须 SELFTEST PASSED
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/gw/src/slotguard.c" -o "$D/gw/bin/slotguard"
echo "built: $(ls -la "$D/gw/bin/slotguard" | awk '{print $5}') bytes"
