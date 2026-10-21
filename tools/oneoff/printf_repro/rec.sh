#!/bin/sh
cd /data/p0
rm -f rec.log
./pfrec 300000000 > /data/p0/rec.log 2>&1
echo rc=$? >> /data/p0/rec.log
