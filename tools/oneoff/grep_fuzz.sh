#!/bin/sh
# grep_fuzz.sh -- differential grep fuzz: p6s vs stock on random/edge inputs (U-P)
N=${1:-30}
P=/bin/busybox
S=/data/stealth/stock/busybox
D=/tmp/gfuzz
mkdir -p "$D" 2>/dev/null
i=0; psig=0; ssig=0; ponly=0
while [ "$i" -lt "$N" ]; do
  dd if=/dev/urandom of="$D/f" bs=1024 count=8 2>/dev/null
  printf 'PSE_OQ_STA3: 1\n' >> "$D/f"
  "$P" grep PSE_OQ_STA3 "$D/f" >/dev/null 2>&1; rp=$?
  "$S" grep PSE_OQ_STA3 "$D/f" >/dev/null 2>&1; rs=$?
  [ "$rp" -ge 128 ] && psig=$((psig+1))
  [ "$rs" -ge 128 ] && ssig=$((ssig+1))
  [ "$rp" -ge 128 ] && [ "$rs" -lt 128 ] && ponly=$((ponly+1))
  i=$((i+1))
done
echo "FUZZ_RANDOM N=$N P_sig=$psig S_sig=$ssig P_only=$ponly"
# long-line / no-newline / high-byte crafted cases
j=0; cp2=0; cs2=0; cponly=0
while [ "$j" -lt 10 ]; do
  { yes 'A' | head -c 65535; printf '\nPSE_OQ_STA3: 2\n'; } > "$D/c1" 2>/dev/null
  { printf '\377\376PSE_OQ_STA3: 3'; } > "$D/c2" 2>/dev/null
  { printf 'PSE_OQ_STA3: 4'; } > "$D/c3" 2>/dev/null
  for f in "$D/c1" "$D/c2" "$D/c3"; do
    "$P" grep PSE_OQ_STA3 "$f" >/dev/null 2>&1; rp=$?
    "$S" grep PSE_OQ_STA3 "$f" >/dev/null 2>&1; rs=$?
    [ "$rp" -ge 128 ] && cp2=$((cp2+1))
    [ "$rs" -ge 128 ] && cs2=$((cs2+1))
    [ "$rp" -ge 128 ] && [ "$rs" -lt 128 ] && cponly=$((cponly+1))
  done
  j=$((j+1))
done
echo "FUZZ_CRAFT P_sig=$cp2 S_sig=$cs2 P_only=$cponly"
