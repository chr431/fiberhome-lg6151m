#!/bin/sh
# lab_natctl.sh -- negative control: dump the stack of N HEALTHY long-running shells.
# Same dump format as core_meta's .stack (stackdump: 56B header + 64KB), so the same
# stride-8 record-shape scan can be applied and must yield 0 false positives.
OUT=/data/repro/natctl
mkdir -p $OUT
n=0
for d in /proc/[0-9]*; do
  p=$(basename $d)
  [ -r $d/exe ] || continue
  exe=$(readlink $d/exe 2>/dev/null)
  case "$exe" in */busybox*) ;; *) continue;; esac
  a0=$(tr '\0' ' ' < $d/cmdline 2>/dev/null | cut -d' ' -f1)
  case "$a0" in sh|ash|/bin/sh) ;; *) continue;; esac
  [ "$n" -ge 12 ] && break
  /data/gw/bin/stackdump "$p" "$OUT/$p.stack" 65536 2>/dev/null && n=$((n+1))
done
echo "dumped=$n"
ls -l $OUT | tail -14
