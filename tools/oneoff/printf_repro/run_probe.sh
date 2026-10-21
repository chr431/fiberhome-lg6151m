#!/bin/sh
# run_probe.sh -- drive p0probe modes, one process each, results to /data/p0.
B=/data/p0
: > $B/result.txt
echo "cores_before=$(ls /data/gw/logs/cores/meta 2>/dev/null | wc -l)" >> $B/result.txt
for m in r5 r1 r3 r3b r4 r2 r6 r7 r8 r9; do
	$B/probe $m 50000000 > $B/out.$m 2>&1
	rc=$?
	echo "$m rc=$rc" >> $B/result.txt
done
echo "cores_after=$(ls /data/gw/logs/cores/meta 2>/dev/null | wc -l)" >> $B/result.txt
echo DONE >> $B/result.txt
