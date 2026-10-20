#!/bin/sh
# build_logc.sh v1.1 -- static aarch64 build of the defensive log collector.
# Same toolchain family as v3httpd/mipc_cellular (zig cc, musl, static).
# v1.1 (P1-2): -fstack-protector-all + frame pointer; the parser handles
#   untrusted frames, so canaries are cheap insurance behind the length checks.
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -Wall -Wextra -static -s \
    -fstack-protector-all -fno-omit-frame-pointer \
    "$D/gw/src/logc.c" -o "$D/gw/bin/logc"
python - "$D/gw/bin/logc" <<'EOF'
import sys
p = sys.argv[1]
b = open(p, "rb").read()
assert b[:4] == b"\x7fELF", "not an ELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("built: %s (%d bytes, static)" % (p, len(b)))
EOF
