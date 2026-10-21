#!/bin/sh
cd /data/p0
rm -f dump.*
i=0
while [ $i -lt 3 ]; do
	./probe4 a1 200000000 >/dev/null 2>&1
	i=$((i+1))
done
echo DONE > /data/p0/p4.done
