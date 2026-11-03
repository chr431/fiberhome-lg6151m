#!/bin/sh
# build.sh -- offline build of auditpoke + vmpoke (A2 audit-watch toolbox).
#
# Targets:
#   all (default)  auditpoke + vmpoke, static aarch64-linux-musl (device,
#                  kernel 5.15.134) + host selftest (layout assertions of
#                  the rule serializer, compiled and run locally)
#   x86_64         static x86_64-linux-musl variants for a WSL protocol
#                  smoke:  ./build.sh x86_64   -> auditpoke-x86_64 etc.
#   selftest       host selftest only
#
# Toolchain: zig cc 0.13.0 from _local/toolchains (same family as
# tools/build_procmatch.sh).  All audit/netlink/ptrace constants come from
# audit_const.h, hand-transcribed from the device kernel tree
# _local/legacy/linux-5.15.134 -- no host kernel headers are consulted.
set -e
cd "$(dirname "$0")"
Z=${ZIG:-../../../../../_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe}

check_static() {
    python - "$1" <<'EOF'
import sys
b = open(sys.argv[1], "rb").read()
assert b[:4] == b"\x7fELF", "not an ELF"
assert b.find(b"ld-musl") < 0, "not statically linked"
print("built: %s (%d bytes, static)" % (sys.argv[1], len(b)))
EOF
}

build_pair() {
    target=$1; def=$2; suffix=$3
    "$Z" cc -target "$target" -O2 -Wall -Wextra -static -s \
        -fstack-protector-all -D"$def" auditpoke.c -o "auditpoke$suffix"
    "$Z" cc -target "$target" -O2 -Wall -Wextra -static -s \
        -fstack-protector-all -D"$def" vmpoke.c -o "vmpoke$suffix"
    check_static "auditpoke$suffix"
    check_static "vmpoke$suffix"
}

build_selftest() {
    "$Z" cc -target native -O1 -g -Wall -DAUDITPOKE_ARCH_AARCH64 \
        -DAUDITPOKE_HOST_SELFTEST auditpoke.c -o auditpoke_selftest_host
    ./auditpoke_selftest_host selftest
}

case "${1:-all}" in
x86_64)
    build_pair x86_64-linux-musl AUDITPOKE_ARCH_X86_64 -x86_64
    ;;
all)
    build_pair aarch64-linux-musl AUDITPOKE_ARCH_AARCH64 ""
    build_selftest
    ;;
selftest)
    build_selftest
    ;;
*)
    echo "usage: build.sh [all|x86_64|selftest]" >&2
    exit 1
    ;;
esac
