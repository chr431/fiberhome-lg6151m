#!/bin/sh
# build_mode0_test.sh -- regenerate mode0_under_test.inc from the LIVE gw/src/nerepair.c, build, run.
# [WRITE-SCOPE] lg6151m-public/tools/oneoff/sigsegv (tools/oneoff is registration-exempt by design)
#
# The criteria are never copied from another revision: every run re-extracts them from the
# current gw/src/nerepair.c, prints that file's md5, and asserts the extracted block is the
# MODE-AWARE revision (the v2.0 block had no 'mode' parameter).
#
# ONE documented mechanical normalization is applied to the extracted text:
#     s/unsigned long/uint64_t/g   and   s/UL/ULL/g
# Reason: this host is LLP64 -- sizeof(unsigned long) == 4 -- while the aarch64 target is
# LP64.  Without the normalization, shape_ok's (f >> 32) and (w2 >> 32) tests shift a 32-bit
# value by 32 and silently evaluate to 0, i.e. the harness would measure a criterion the
# device does not run.  The normalization touches type widths and integer suffix letters
# only; no operator, constant value, branch or order is changed.  It is proven by controls
# printed at the end of the run (shape_ok 150/150 real records, shape_ok 0/100 on {V,0,0,0}).
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)                    # lg6151m-public
PROJ=$(cd "$ROOT/.." && pwd)                          # project root (holds _local/)
SRC="$ROOT/gw/src/nerepair.c"
RAW="$HERE/mode0_under_test.raw.inc"
INC="$HERE/mode0_under_test.inc"
ZIG="$PROJ/_local/toolchains/zig-windows-x86_64-0.13.0/zig.exe"
CORPUS="$1"
[ -n "$CORPUS" ] || CORPUS="$PROJ/_local/evidence/crash-root/h4_rec150.txt"

echo "source : $SRC"
echo "md5    : $(md5sum "$SRC" | cut -d' ' -f1)"
: > "$RAW"
sed -n '/^#define NR_TAGMASK/,/^#define NR_LEN_MAX/p'                              "$SRC" >> "$RAW"
sed -n '/^static int shape_ok/,/^}$/p'                                             "$SRC" >> "$RAW"
sed -n '/^#define DEREF_SCAN_BYTES/,/^\/\* returns 1 if this fault was handled/p' "$SRC" >> "$RAW"
sed -e 's/unsigned long/uint64_t/g' -e 's/UL/ULL/g' "$RAW" > "$INC"
echo "raw    : $RAW ($(wc -l < "$RAW") lines)"
echo "inc    : $INC ($(wc -l < "$INC") lines, normalized to uint64_t)"
echo "crit   : $(grep -n 'find_record_near_stack(pid_t' "$INC" | head -1)"
NMODE=$(grep -c 'int mode)' "$INC")
echo "assert : $NMODE mode-aware definition(s); sizeof(unsigned long) on this host is checked in-program"
if [ "$NMODE" -lt 1 ]; then
    echo "FATAL: extracted block is NOT the mode-aware revision -- refusing to run"
    exit 1
fi
echo "normalized lines that differ (first 6):"
diff "$RAW" "$INC" | grep '^>' | head -6
[ -x "$ZIG" ] || { echo "FATAL: zig not found at $ZIG"; exit 1; }
"$ZIG" cc -O2 -o "$HERE/nerepair_mode0_test.exe" "$HERE/nerepair_mode0_test.c" -lm
"$HERE/nerepair_mode0_test.exe" "$CORPUS"
