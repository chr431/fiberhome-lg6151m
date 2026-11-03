#!/bin/sh
# lab_rec.sh -- extract header fields + the 32B record (at x2 = top-0x390) of the newest N h4 dumps.
#
# h4 layout: 120 B header + 8 x 4096 B, pages are top-relative, so the record is ALWAYS at
# dump offset 120 + 7*4096 + (4096 - 0x390) = 31976 (verified 6/6 on 2026-11-01).
# Header field offsets: pid=12 hit=16 fault=32 x2=56 top=96 ts=112 (from vsurv4.c struct h4_hdr)
# usage: lab_rec.sh <n>
OD=/data/gw/bin/busybox
N=$1
for f in $(ls -t /data/repro/h4_*.bin 2>/dev/null | head -n $N); do
  hdr=$($OD od -An -tx4 -j 12 -N 108 $f | tr -d '\n' | tr -s ' ')
  rec=$($OD od -An -tx1 -j 31976 -N 32 $f | tr -d ' \n')
  echo "$f|$hdr|$rec"
done
