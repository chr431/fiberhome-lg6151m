#!/bin/sh
# toolchain_init.sh v1.0 -- static userland bootstrap (SIGSEGV P2).
#
# Background: every crash in the 2026-10-19 SIGSEGV family came from a vendor
# binary dynamically linked against the vendor musl (grep/awk/sh/ip/...).
# This script materialises /data/gw/sbin as a symlink farm over the static
# busybox (gw/bin/busybox, Alpine 1.36.1-r31) and points "ip" at the static
# iproute2 6.3.0 build (gw/bin/ip) so the exact vendor CLI behaviour is kept.
# rc.extend.sh prepends /data/gw/sbin:/data/gw/bin to PATH, therefore every
# daemon launched after boot (and every child it spawns) executes the static
# tools instead of the vendor copies.
#
# Safety:
#   - farm is built in a temporary directory and swapped in with rename(2),
#     so a failed/partial bootstrap never leaves a half-populated PATH dir;
#   - if the static busybox is missing or does not execute, the farm is
#     removed and PATH resolution falls back to the vendor /bin,/usr/bin;
#   - idempotent; safe to run by hand after a deploy.
set -u

BB=/data/gw/bin/busybox
IP=/data/gw/bin/ip
DIR=/data/gw/sbin
TMP=$DIR.new
OLD=$DIR.old
LOG=/tmp/toolchain_init.log

say() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }

if [ ! -x "$BB" ]; then
	rm -rf "$TMP"
	[ -d "$DIR" ] && rm -rf "$DIR"
	say "static busybox missing at $BB -- farm removed (vendor fallback)"
	exit 1
fi
# smoke test: the binary must actually execute on this kernel
if ! "$BB" sh -c 'exit 0' >/dev/null 2>&1; then
	rm -rf "$TMP"
	say "static busybox at $BB does not execute -- farm left untouched"
	exit 1
fi

rm -rf "$TMP" "$OLD"
mkdir -p "$TMP" || exit 1
if ! "$BB" --install -s "$TMP" >/dev/null 2>&1; then
	rm -rf "$TMP"
	say "busybox --install failed -- farm left untouched"
	exit 1
fi

# "ip" must stay the real iproute2 binary: busybox ip renders route output
# with different spacing and does not implement "link add ... type bridge".
if [ -x "$IP" ] && "$IP" -V >/dev/null 2>&1; then
	ln -sf "$IP" "$TMP/ip"
else
	say "WARN static ip missing/not executable at $IP -- busybox ip applet used"
fi
ln -sf "$BB" "$TMP/sh"

# atomic-ish swap: old farm aside, new farm in place, old removed
[ -d "$DIR" ] && mv "$DIR" "$OLD"
mv "$TMP" "$DIR"
rm -rf "$OLD"

_n=$(ls "$DIR" | wc -l)
say "farm ready: $_n applets, busybox=$BB ip=$IP"
exit 0
