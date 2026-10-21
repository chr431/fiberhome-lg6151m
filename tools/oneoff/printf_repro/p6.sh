#!/bin/sh
cd /data/p0
rm -f layer.txt p6.log
for k in 1 2 3; do
	./pfchk3 100000000 1 >>/data/p0/p6.log 2>&1
	echo "c1 rc=$?" >> /data/p0/p6.log
done
./pfchk3 50000000 2 >>/data/p0/p6.log 2>&1; echo "c2 rc=$?" >> /data/p0/p6.log
./pfchk3 50000000 3 >>/data/p0/p6.log 2>&1; echo "c3 rc=$?" >> /data/p0/p6.log
echo DONE >> /data/p0/p6.log
