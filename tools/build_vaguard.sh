#!/bin/sh
# build_vaguard.sh v1.0 -- compile gw/src/vfprintf_guard.c into a linkable object.
# The object must be linked BEFORE libc so its vfprintf/vsnprintf definitions win.
# Usage: sh tools/build_vaguard.sh [out.o]
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-$D/../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
M=${MUSL:-$D/../_local/toolchains/zig-windows-x86_64-0.13.0/lib/libc/musl}
# zig resolves its own cache from argv[0]; a path containing ".." breaks it
# on Windows (AppDataDirUnavailable), so canonicalise.
Z=$(cd "$(dirname "$Z")" && pwd)/$(basename "$Z")
M=$(cd "$M" && pwd)
OUT=${1:-$D/../_local/build/vaguard.o}
mkdir -p "$(dirname "$OUT")"
LAUNCH=""
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) [ -f "$D/tools/zigcc.py" ] && LAUNCH="python $D/tools/zigcc.py" ;;
esac
[ -n "$LAUNCH" ] || LAUNCH="$Z"
eval "$LAUNCH" cc -target aarch64-linux-musl -O2 -D_GNU_SOURCE \
    -I"$M/src/internal" -I"$M/src/include" -I"$M/include" \
    -I"$M/arch/aarch64" -I"$M/arch/generic" \
    -c "$D/tools/vaguard/vfprintf_guard.c" -o "$OUT"
echo "built $OUT"
