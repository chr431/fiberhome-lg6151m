#!/bin/sh
# build_procmatch.sh v1.0 -- static aarch64 pidof/pgrep replacement.
# Same toolchain family as logc/logcut (zig cc, musl, static).  The tool scans
# /proc and formats with bounded manual output: no printf family, no locale.
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
Z=${ZIG:-$D/../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}
"$Z" cc -target aarch64-linux-musl -O2 -Wall -Wextra -static -s \
    -fstack-protector-all "$D/gw/src/procmatch.c" -o "$D/gw/bin/procmatch"
python - "$D/gw/bin/procmatch" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"\x7fELF", "not an ELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("built: %s (%d bytes, static)" % (sys.argv[1], len(b)))
EOF
