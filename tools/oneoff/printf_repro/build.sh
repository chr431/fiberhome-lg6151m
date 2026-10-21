#!/bin/sh
# build.sh -- build the printf reproducer family for aarch64 (static).
# Usage: sh tools/oneoff/printf_repro/build.sh [outdir]
set -e
D=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$D/out}
Z=${ZIG:-$D/../../../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
mkdir -p "$OUT"
for f in pfcanary v_big v_intd v_fixed; do
	"$Z" cc -target aarch64-linux-musl -O2 -static -s "$D/$f.c" -o "$OUT/$f"
	echo "built $OUT/$f"
done
