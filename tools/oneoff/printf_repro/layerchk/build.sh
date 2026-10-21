#!/bin/sh
# build.sh -- build the P0 printf-chain instruments (P0, 2026-10-22).
# Needs: ZIG (zig 0.13 path) and the musl sources that ship with zig.
# Output: layerchk/out/{probe-probe5 are built by ../build.sh, here the chk ones}
set -e
D=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$D/../../../.." && pwd)              # repo root
Z=${ZIG:-$ROOT/../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
M=${MUSL:-$ROOT/../_local/toolchains/zig-windows-x86_64-0.13.0/lib/libc/musl}
OUT=$D/out
mkdir -p "$OUT"
cd "$D"
INC="-I$M/src/internal -I$M/src/include -I$M/include -I$M/arch/aarch64 -I$M/arch/generic -I$D"
CC="$Z cc -target aarch64-linux-musl -O2 -D_GNU_SOURCE $INC"

# --- hardened vfprintf (pop_arg guard) + its A/B test programs -------------
$CC -c h_vfprintf.c -o "$D/h_vfprintf.o"
$CC -static -s pfguard.c "$D/h_vfprintf.o" -o "$OUT/pfguard"   # guarded
$CC -static -s pfguard.c                   -o "$OUT/pfctl"     # control

# --- probes ---------------------------------------------------------------
$CC -c h2_vfprintf.c -o "$D/h2_vfprintf.o"
$CC -static -s pfrec.c "$D/h2_vfprintf.o" -o "$OUT/pfrec"      # ap vs &ap2
$CC -c h3_vfprintf.c -o "$D/h3_vfprintf.o"
$CC -static -s pfcp.c "$D/h3_vfprintf.o" -o "$OUT/pfcp"        # ordered checkpoints
$CC -static -s pfscope.c -o "$OUT/pfscope"                     # own varargs vs printf

# --- layered bisect (override snprintf/vsnprintf/vfprintf) ----------------
$CC -c p0chk.c -o "$D/p0chk.o"
$CC -c my_snprintf.c -o "$D/my_snprintf.o"
$CC -c my_vsnprintf.c -o "$D/my_vsnprintf.o"
$CC -c my_vfprintf.c -o "$D/my_vfprintf.o"
$CC -static -s pfchk.c my_snprintf.o my_vsnprintf.o my_vfprintf.o p0chk.o -o "$OUT/pfchk"
$CC -c my2_vsnprintf.c -o "$D/my2_vsnprintf.o"
$CC -c my2_vfprintf.c -o "$D/my2_vfprintf.o"
$CC -c chk2.c -o "$D/chk2.o"
$CC -static -s pfchk.c my2_vsnprintf.o my2_vfprintf.o chk2.o my_snprintf.o p0chk.o -o "$OUT/pfchk2"
$CC -c my3_vfprintf.c -o "$D/my3_vfprintf.o"
$CC -static -s pfchk3.c my3_vfprintf.o p0chk.o -o "$OUT/pfchk3"
echo "built: $(ls $OUT | tr '\n' ' ')"
