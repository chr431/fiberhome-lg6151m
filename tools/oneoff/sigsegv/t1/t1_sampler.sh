#!/bin/sh
# T1: sample /proc/tuphook every 5 s for 380 ticks (~1900 s)
D=/data/repro/t1
LOG=$D/samples.log
rm -f $D/done
echo "# start ts=$(date +%s) up=$(cut -d' ' -f1 /proc/uptime) boot=$(cat /proc/sys/kernel/random/boot_id)" > $LOG
i=0
while [ "$i" -lt 380 ]; do
  ts=$(date +%s); up=$(cut -d' ' -f1 /proc/uptime)
  h5=$(ls /data/repro/h5_*.bin 2>/dev/null | wc -l)
  echo "===SAMPLE $i ts=$ts up=$up h5=$h5" >> $LOG
  cat /proc/tuphook >> $LOG
  echo "===TRYA $(hexdump -C -n 2 -s 2060 /dev/mmcblk0p1 | head -1)" >> $LOG
  i=$((i+1))
  sleep 5
done
echo DONE > $D/done
