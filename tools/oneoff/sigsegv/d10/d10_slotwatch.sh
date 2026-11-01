#!/bin/sh
# d10_slotwatch.sh -- read-only watcher of known 32B-record slots (D10 extension).
# Every N seconds reads 32 bytes at start_stack - OFF for target pids and logs
# hex + uptime. Offsets: dnsmasq 0x1b40/0x12b0 (historical static/7-variant
# slots), nerepair 0x3b0/0x12d0 (active slots). Pure /proc reads; writes only
# its own log under /data/repro/.
LOG=/data/repro/d10_slotwatch.log
INT=5
: >> "$LOG"
while :; do
  UP=$(cut -d' ' -f1 /proc/uptime)
  for NAME in dnsmasq nerepair; do
    for P in $(pidof $NAME 2>/dev/null); do
      S=$(awk '{print $28}' /proc/$P/stat 2>/dev/null)
      [ -n "$S" ] || continue
      for OFF in 6980 4796 944 4816; do
        HEX=$(dd if=/proc/$P/mem bs=1 skip=$((S-OFF)) count=32 2>/dev/null | busybox hexdump -ve '32/1 "%02x"' 2>/dev/null)
        [ -n "$HEX" ] && echo "UP=$UP P=$P N=$NAME OFF=$OFF H=$HEX" >> "$LOG"
      done
    done
  done
  sleep $INT
done
