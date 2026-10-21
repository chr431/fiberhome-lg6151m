#!/bin/sh
cd /data/p0
rm -f layer_n.txt layer_g.txt
for k in 1 2 3; do
	./pfchk3 100000000 1 >> /data/p0/n.log 2>&1; echo "normal rc=$?" >> /data/p0/n.log
	./pfchk3gpr 100000000 1 >> /data/p0/g.log 2>&1; echo "gpr rc=$?" >> /data/p0/g.log
done
echo DONE >> /data/p0/n.log
