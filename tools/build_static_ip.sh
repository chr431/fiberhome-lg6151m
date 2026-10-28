#!/bin/sh
# build_static_ip.sh v1.0 -- static aarch64 iproute2 6.3.0 (vendor version).
#
# Why not busybox's ip applet: its route output uses different spacing
# ("dev eth0  metric 200" with two spaces) and it has no "link add ... type
# bridge", so grep-based daemon checks and first-boot br-lan creation would
# drift.  iproute2 6.3.0 is exactly the vendor version (ip -V), rebuilt with
# zig cc against musl and linked statically.
#
# Build deps: zig 0.13, make, tar/xz, curl.  On Windows/MSYS2 the host make
# lives in /c/msys64/usr/bin; the script adds it when needed.
#
# Usage: sh tools/build_static_ip.sh
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-$D/../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
VER=6.3.0
URL=https://mirrors.edge.kernel.org/pub/linux/utils/net/iproute2/iproute2-$VER.tar.xz
SHA=dfb2a98db96e7a653cffc6693335a1a466e29a34b6ac528be48f35e1d2766732
WORK=${IPROUTE2_BUILD_DIR:-$D/../_local/build}
SRC=$WORK/iproute2-$VER
OUT=$D/gw/bin/ip
GUARD=${GUARD:-$D/../_local/build/vaguard.o}

if [ -n "${OS:-}" ] && [ "$OS" = "Windows_NT" ]; then
    PATH=/c/msys64/usr/bin:$PATH
    export PATH MSYS_NO_PATHCONV=1
fi
MAKE=${MAKE:-make}
command -v "$MAKE" >/dev/null 2>&1 || MAKE=/c/msys64/usr/bin/make

mkdir -p "$WORK"
if [ ! -d "$SRC" ]; then
    TMP=$WORK/dl
mkdir -p "$TMP"
    trap 'rm -rf "$TMP"' EXIT INT TERM
    curl -fsSL -o "$TMP/iproute2.tar.xz" "$URL"
    python - "$(cygpath -w "$TMP/iproute2.tar.xz" 2>/dev/null || echo "$TMP/iproute2.tar.xz")" "$SHA" <<'EOF'
import hashlib, sys
p, want = sys.argv[1], sys.argv[2]
got = hashlib.sha256(open(p, "rb").read()).hexdigest()
if got != want:
    sys.exit("sha256 mismatch: got %s want %s" % (got, want))
print("sha256 OK", got)
EOF
    tar xJf "$TMP/iproute2.tar.xz" -C "$WORK"
fi

CC=${CC:-"$Z cc -target aarch64-linux-musl"}   # env override: zig wrapper for Windows
AR="$Z ar"
CF='-O2 -include libgen.h -I../include -I../include/uapi -D_GNU_SOURCE -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -D_LARGEFILE64_SOURCE -DRESOLVE_HOSTNAMES -DCONFDIR=\"/etc/iproute2\" -DNETNS_RUN_DIR=\"/var/run/netns\" -DNETNS_ETC_DIR=\"/etc/netns\" -DHAVE_SETNS -DHAVE_HANDLE_AT'
ADDLIB='ax25_ntop.o rose_ntop.o mpls_ntop.o mpls_pton.o netrom_ntop.o'
LIBS='../lib/libutil.a ../lib/libnetlink.a'

# Windows zig needs a real AppData path even when make scrubs the environment.
# Use a repo-local path (no spaces) instead of the user profile: it only feeds
# zig's cache lookup.
HOSTVARS=
LA=; AP=; UP=; TW=
if [ -n "${OS:-}" ] && [ "$OS" = "Windows_NT" ]; then
    WORKW=$(cygpath -w "$WORK" 2>/dev/null || echo "$WORK")
    LA="$WORKW\\appdata"
    AP="$WORKW\\appdata"
    UP="$WORKW"
    TW="$WORKW\\tmp"
    mkdir -p "$WORK/appdata" "$WORK/tmp"
    HOSTVARS=1
fi

cd "$SRC"
if [ ! -f config.mk ]; then
    CC="$CC" AR="$AR" PKG_CONFIG=${PKG_CONFIG:-false} YACC=false ./configure
fi
rm -f lib/libutil.a lib/libnetlink.a

run_make() {
    if [ -n "$HOSTVARS" ]; then
        $MAKE "$@" "LOCALAPPDATA=$LA" "APPDATA=$AP" "USERPROFILE=$UP" \
            "TMP=$TW" "TEMP=$TW"
    else
        $MAKE "$@"
    fi
}

run_make -C lib -j4 libnetlink.a libutil.a \
    CC="$CC" AR="$AR" "CFLAGS=$CF" "ADDLIB=$ADDLIB"
run_make -C ip -j4 ip \
    CC="$CC" AR="$AR" "CFLAGS=$CF" "LDFLAGS=-static -s $GUARD" \
    "LIBNETLINK=$LIBS"

cp ip/ip "$OUT"
chmod 755 "$OUT"
python - "$OUT" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"\x7fELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("installed %s (%d bytes, static)" % (sys.argv[1], len(b)))
EOF
