#!/bin/sh
# build_logc.sh v1.2 -- static aarch64 build of the defensive log collector.
# Same toolchain family as v3httpd/mipc_cellular (zig cc, musl, static).
# v1.2 (batch3): --asan builds a host-native ASAN/UBSAN binary for the
#   --fuzz harness.  The device binary stays the static zig build; the ASAN
#   binary is a development artifact (not deployed).
# v1.1 (P1-2): -fstack-protector-all + frame pointer; the parser handles
#   untrusted frames, so canaries are cheap insurance behind the length checks.
#
# Usage:
#   sh tools/build_logc.sh            # device binary -> gw/bin/logc
#   sh tools/build_logc.sh --asan     # host ASAN binary -> _local/build/logc-asan
#   _local/build/logc-asan --fuzz 2000
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
SRC="$D/gw/src/logc.c"

if [ "${1:-}" = "--asan" ]; then
    OUT_DIR="$D/../_local/build"
    mkdir -p "$OUT_DIR"
    OUT="$OUT_DIR/logc-asan"
    CC=${CC:-}
    case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*)
        # The MSYS gcc has no Linux libc headers (endian.h etc.); ASAN must be
        # built on a Linux host or with an explicit cross compiler.
        [ -n "$CC" ] || { echo "build_logc: --asan on Windows needs CC=<linux cc>; run on Linux for the normal path" >&2; exit 1; } ;;
    esac
    if [ -z "$CC" ]; then
        for c in cc gcc clang aarch64-linux-musl-gcc; do
            command -v "$c" >/dev/null 2>&1 && { CC=$c; break; }
        done
    fi
    if [ -z "$CC" ]; then
        echo "build_logc: --asan needs a host C compiler (cc/gcc/clang)." >&2
        echo "  On the Linux side: CC=cc sh tools/build_logc.sh --asan" >&2
        exit 1
    fi
    "$CC" -O1 -g -fno-omit-frame-pointer -fstack-protector-all \
        -fsanitize=address,undefined "$SRC" -o "$OUT"
    echo "built: $OUT (ASAN/UBSAN; run: $OUT --fuzz 2000)"
    exit 0
fi

Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -Wall -Wextra -static -s \
    -fstack-protector-all -fno-omit-frame-pointer \
    "$SRC" -o "$D/gw/bin/logc"
python - "$D/gw/bin/logc" <<'EOF'
import sys
p = sys.argv[1]
b = open(p, "rb").read()
assert b[:4] == b"\x7fELF", "not an ELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("built: %s (%d bytes, static)" % (p, len(b)))
EOF
