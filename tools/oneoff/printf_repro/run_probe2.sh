#!/bin/sh
# run_probe2.sh -- P0 forensics: repeat a mode, one crash per process.
B=/data/p0
M=${1:-a1}
K=${2:-6}
N=${3:-200000000}
: > $B/result2.txt
for m in a2 a3 a4 a5 a6 a7 a8; do
	$B/probe2 $m 50000000 > $B/o.$m 2>&1
	echo "$m rc=$? k=$(cat $B/o.$m)" >> $B/result2.txt
done
i=0
while [ $i -lt $K ]; do
	$B/probe2 $M $N > $B/o.$M.$i 2>&1
	echo "$M#$i rc=$? $(cat $B/o.$M.$i)" >> $B/result2.txt
	i=$((i+1))
done
echo DONE >> $B/result2.txt
