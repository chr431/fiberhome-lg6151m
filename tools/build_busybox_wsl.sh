#!/bin/sh
# build_busybox_wsl.sh v1.1 -- rebuild busybox 1.36.1 (aarch64, static, musl) with
# the va_list guard linked in.  Run inside WSL2/Ubuntu or any x86_64 Linux.
#
# Why a GNU musl cross toolchain and not zig: busybox's kbuild host tools,
# scripts/trylink (gcc-only linker flags), strip and the applet table each fight
# a clang/zig driver; the GNU toolchain is the supported path
# (docs/SIGSEGV_ANALYSIS.md section 20.1).
#
# Inputs (env):
#   TC_DIR      musl cross toolchain root      (default ~/aarch64-linux-musl-cross)
#   BB_SRC      existing busybox source tree   (default: download 1.36.1)
#   MUSL_SRC    musl source tree for the guard (default: download 1.2.5)
#   GUARD_SRC   va_list guard source           (default: repo tools/vaguard/vfprintf_guard.c)
#   OUT         output binary                  (default: <repo>/gw/bin/busybox)
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
TC=${TC_DIR:-$HOME/aarch64-linux-musl-cross}
BB=${BB_SRC:-}
MU=${MUSL_SRC:-}
GUARD=${GUARD_SRC:-$REPO/tools/vaguard/vfprintf_guard.c}
OUT=${OUT:-$REPO/gw/bin/busybox}
WORK=${WORK:-$HOME/bb-build}
MUSL_VER=${MUSL_VER:-1.2.5}

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need make; need gcc; need tar; need python3; need curl

mkdir -p "$WORK"

if [ ! -x "$TC/bin/aarch64-linux-musl-gcc" ]; then
    echo "== fetching musl cross toolchain (108 MB) into $TC"
    curl -L -o "$WORK/musl-cross.tgz" https://musl.cc/aarch64-linux-musl-cross.tgz
    mkdir -p "$(dirname "$TC")"
    tar xf "$WORK/musl-cross.tgz" -C "$(dirname "$TC")"
fi
export PATH="$TC/bin:$PATH"

if [ -z "$BB" ]; then
    BB=$WORK/busybox-1.36.1
    if [ ! -d "$BB" ]; then
        echo "== fetching busybox 1.36.1"
        curl -L -o "$WORK/bb.tar.bz2" https://busybox.net/downloads/busybox-1.36.1.tar.bz2
        tar xjf "$WORK/bb.tar.bz2" -C "$WORK"
    fi
fi

if [ -z "$MU" ]; then
    MU=$WORK/musl-$MUSL_VER
    if [ ! -d "$MU" ]; then
        echo "== fetching musl $MUSL_VER sources (for stdio_impl.h)"
        curl -L -o "$WORK/musl.tar.gz" https://musl.libc.org/releases/musl-$MUSL_VER.tar.gz
        tar xzf "$WORK/musl.tar.gz" -C "$WORK"
    fi
fi

echo "== building the va_list guard"
"$TC/bin/aarch64-linux-musl-gcc" -O2 -D_GNU_SOURCE \
    -I"$MU/src/internal" -I"$MU/src/include" -I"$TC/aarch64-linux-musl/include" \
    -I"$MU/arch/aarch64" -I"$MU/arch/generic" \
    -c "$GUARD" -o "$WORK/vaguard.o"
ls -la "$WORK/vaguard.o"

echo "== patching scripts/trylink (gcc-only flags + guard object)"
python3 - "$BB/scripts/trylink" "$WORK/vaguard.o" <<'PY'
import sys
path, guard = sys.argv[1], sys.argv[2]
BS = chr(92)
s = open(path, encoding="utf-8", errors="replace").read()
s = s.replace("-Wl,--warn-common -Wl,-Map,$EXE.map -Wl,--verbose", "")
old = "-o $EXE " + BS
new = "-o $EXE " + guard + " " + BS
n = s.count(old)
s = s.replace(old, new)
open(path, "w", encoding="utf-8").write(s)
print("link sites patched:", n, "guard:", guard in s)
PY

echo "== configuring and building"
cd "$BB"
make defconfig >/dev/null
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make -j"$(nproc)" CROSS_COMPILE=aarch64-linux-musl- SKIP_STRIP=y \
     LDFLAGS="-static -no-pie"

file busybox | cut -c1-90
strings busybox | grep -q vaguard.tsv || { echo "guard missing" >&2; exit 1; }
cp busybox "$OUT"
chmod 755 "$OUT"
echo "== installed $OUT ($(stat -c%s "$OUT") bytes)"