#!/bin/sh
# Build mipc_cellular with zig cc (same chain family as v3httpd/wpapmk builds).
# Links against the RP103 tree's libqlril.so at build time; runtime resolves
# /usr/lib/libqlril.so + its deps on device (musl dynamic).
set -e
cd "$(dirname "$0")/.."
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
QLDIR=/tmp/mipc_build_lib
QLSRC=/d/Repo/lg6151m-project/_local/legacy/received_raw_captures/rp103_rootfs/usr/lib/libqlril.so
[ -f "$QLSRC" ] || { echo "!! libqlril.so not found at $QLSRC"; exit 1; }
mkdir -p "$QLDIR" && cp "$QLSRC" "$QLDIR/libqlril.so"
"$Z" cc -target aarch64-linux-musl \
    -Os -Wall \
    gw/src/mipc_cellular.c \
    -L"$QLDIR" -lqlril \
    -o gw/bin/mipc_cellular
file gw/bin/mipc_cellular
echo "built: gw/bin/mipc_cellular ($(stat -c%s gw/bin/mipc_cellular) bytes)"
