#!/bin/sh
cd /data/p0
rm -f cp.log
./pfcp 400000000 > /data/p0/cp.log 2>&1
echo rc=$? >> /data/p0/cp.log
