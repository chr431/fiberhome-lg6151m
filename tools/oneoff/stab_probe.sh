#!/bin/sh
# bb_probe2.sh -- busybox/libc patch stability A/B (U-P)
# usage: bb_probe2.sh <N> <P-binary> [S-binary]
N=${1:-30}
P=${2:-/data/stealth/stab/P6/busybox}
S=${3:-/data/stealth/stock/busybox}
M=/tmp/zz_missing_u
ulimit -c 0 2>/dev/null
echo "START $(date +%s) N=$N P=$(md5sum "$P" | cut -c1-8) S=$(md5sum "$S" | cut -c1-8)"

# ---------- functional equality (one shot per command) ----------
run_func() {
  bin=$1; tag=$2
  case $tag in
    sh1)   "$bin" sh -c 'printf "%s|%d|%.3f|%x\n" abc 42 3.14159 255; echo $((6*7)); for i in 1 2 3; do echo $i; done; echo done' ;;
    awk1)  "$bin" awk 'BEGIN{for(i=0;i<100;i++)s+=i; printf "%d %.3f\n", s, 3.14159}' ;;
    sed1)  "$bin" sed -n '1,3p' /etc/passwd ;;
    grep1) "$bin" grep -c root /etc/passwd ;;
    sort1) "$bin" sort /etc/passwd ;;
    cut1)  "$bin" cut -d: -f1 /etc/passwd ;;
    md51)  "$bin" md5sum /etc/passwd ;;
    seq1)  "$bin" seq 1 10 ;;
    expr1) "$bin" expr 3 + 4 ;;
    tar1)  "$bin" tar -cf /tmp/bbp2.tar /etc/passwd && "$bin" tar -tf /tmp/bbp2.tar ;;
    wc1)   "$bin" wc -l /etc/passwd ;;
    ls1)   "$bin" ls -l /data/stealth/T0 ;;
    printf2) "$bin" printf '%d %s %f\n' 7 xyz 2.5 ;;
  esac
}
echo "--- functional"
for tg in sh1 awk1 sed1 grep1 sort1 cut1 md51 seq1 expr1 tar1 wc1 ls1 printf2; do
  run_func "$P" "$tg" > /tmp/fp.out 2>/tmp/fp.err; prc=$?
  run_func "$S" "$tg" > /tmp/fs.out 2>/tmp/fs.err; src=$?
  if [ "$prc" != "$src" ] || ! cmp -s /tmp/fp.out /tmp/fs.out || ! cmp -s /tmp/fp.err /tmp/fs.err; then
    echo "FUNC_DIFF $tg prc=$prc src=$src out=$(cmp -s /tmp/fp.out /tmp/fs.out && echo same || echo diff) err=$(cmp -s /tmp/fp.err /tmp/fs.err && echo same || echo diff)"
  fi
done
L=$("$P" --list 2>/dev/null | md5sum | cut -c1-8); LS=$("$S" --list 2>/dev/null | md5sum | cut -c1-8)
[ "$L" = "$LS" ] || echo "APPLET_LIST_DIFF P=$L S=$LS"

# ---------- error-path / stress A/B ----------
do_one() {
  bin=$1; tag=$2
  case $tag in
    lsmiss)  "$bin" ls -l "$M" >/dev/null 2>/dev/null ;;
    catmiss) "$bin" cat "$M" >/dev/null 2>/dev/null ;;
    tarmiss) "$bin" tar -cf /tmp/zz.t "$M" >/dev/null 2>/dev/null ;;
    lsproc)  "$bin" ls -l /proc/1/exe /proc/999998/exe /proc/999999/exe >/dev/null 2>/dev/null ;;
    grepfile) "$bin" grep -q T0 /data/stealth/T0 >/dev/null 2>/dev/null ;;
    printfx) "$bin" sh -c 'printf "%s %d\n" a 1' >/dev/null 2>/dev/null ;;
    exiterr) "$bin" sh -c 'exit 3' >/dev/null 2>/dev/null ;;
    true)    "$bin" true ;;
  esac
}
run_pair() {
  tg=$1; i=0; pok=0; perr=0; psig=0; sok=0; serr=0; ssig=0
  while [ "$i" -lt "$N" ]; do
    do_one "$P" "$tg"; rc=$?
    if [ "$rc" -ge 128 ]; then psig=$((psig+1)); elif [ "$rc" -eq 0 ]; then pok=$((pok+1)); else perr=$((perr+1)); fi
    do_one "$S" "$tg"; rc=$?
    if [ "$rc" -ge 128 ]; then ssig=$((ssig+1)); elif [ "$rc" -eq 0 ]; then sok=$((sok+1)); else serr=$((serr+1)); fi
    i=$((i+1))
  done
  echo "PAIR case=$tg N=$N P[ok=$pok err=$perr sig=$psig] S[ok=$sok err=$serr sig=$ssig]"
}
echo "--- stress"
for tg in lsmiss catmiss tarmiss lsproc grepfile printfx exiterr true; do
  run_pair "$tg"
done
echo "END $(date +%s)"
