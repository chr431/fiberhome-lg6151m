#!/bin/sh
# fetch_static_busybox.sh v1.0 -- pin and fetch the static aarch64 busybox.
#
# The device's vendor busybox is 1.36.1 (dynamically linked against the vendor
# musl, the crash surface we are removing).  Alpine's busybox-static 1.36.1-r31
# is the same upstream version built with musl and linked statically; its
# applet set covers grep/awk/sed/sh/tail/sort/pgrep/ps/... used by the gw
# scripts.  The APK is pinned by SHA-256 so a mirror change cannot silently
# swap the binary.
#
# Usage: sh tools/fetch_static_busybox.sh
set -e
D=$(cd "$(dirname "$0")/.." && pwd)
OUT=$D/gw/bin/busybox
VER=1.36.1-r31
URL=https://dl-cdn.alpinelinux.org/alpine/v3.20/main/aarch64/busybox-static-$VER.apk
SHA=1d8e7a7fc2ed69bdb8eb7be9d962489c21a0f75b72d8a325437c8a09d4cfac70

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
echo "fetch $URL"
curl -fsSL -o "$TMP/bb.apk" "$URL"
python - "$TMP/bb.apk" "$SHA" <<'EOF'
import hashlib, sys
p, want = sys.argv[1], sys.argv[2]
got = hashlib.sha256(open(p, "rb").read()).hexdigest()
if got != want:
    sys.exit("sha256 mismatch: got %s want %s" % (got, want))
print("sha256 OK", got)
EOF
tar xzf "$TMP/bb.apk" -C "$TMP"
cp "$TMP/bin/busybox.static" "$OUT"
chmod 755 "$OUT"
python - "$OUT" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"\x7fELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("installed %s (%d bytes, static)" % (sys.argv[1], len(b)))
EOF
