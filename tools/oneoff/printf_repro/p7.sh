#!/bin/sh
cd /data/p0
rm -f layer.txt p7.log
while [ ! -s /data/p0/layer.txt ]; do
	./pfchk3 100000000 1 >/dev/null 2>&1
	echo "run rc=$?" >> /data/p0/p7.log
done
echo DONE >> /data/p0/p7.log
