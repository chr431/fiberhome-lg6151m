#!/bin/sh
# build_logc.sh v1.0 -- static aarch64 build of the defensive log collector.
# Same toolchain family as v3httpd/mipc_cellular (zig cc, musl, static).
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -Wall -Wextra -static -s \
    "$D/gw/src/logc.c" -o "$D/gw/bin/logc"
python - "$D/gw/bin/logc" <<'EOF'
import sys
p = sys.argv[1]
b = open(p, "rb").read()
assert b[:4] == b"\x7fELF", "not an ELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("built: %s (%d bytes, static)" % (p, len(b)))
EOF
