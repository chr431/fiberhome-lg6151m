#!/bin/sh
cd /data/p0
rm -f ab.log
for k in 1 2 3; do
	./pfguard 200000000 >> /data/p0/ab.log 2>&1; echo "hardened rc=$?" >> /data/p0/ab.log
	./pfctl 200000000 >> /data/p0/ab.log 2>&1; echo "control  rc=$?" >> /data/p0/ab.log
done
echo DONE >> /data/p0/ab.log
