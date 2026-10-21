#!/bin/sh
cd /data/p0
rm -f dump.*
for m in b2 b1 b1 b1 b2 b1; do
	./probe5 $m 50000000 >/dev/null 2>&1
	echo "$m rc=$?" >> /data/p0/p5.log
done
echo DONE >> /data/p0/p5.log
