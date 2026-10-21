#!/bin/sh
cd /data/p0
rm -f layer.txt pchk.log
i=0
while [ $i -lt 6 ]; do
	./pfchk 200000000 >> /data/p0/pchk.log 2>&1
	echo "run$i rc=$?" >> /data/p0/pchk.log
	i=$((i+1))
done
echo DONE >> /data/p0/pchk.log
