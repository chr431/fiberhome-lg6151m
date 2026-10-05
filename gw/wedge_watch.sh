#!/bin/sh
while :; do
  B=$(python -c "
import socket
s=socket.socket(); s.settimeout(4)
try:
    s.connect(('192.168.8.1',22)); print('SSH-'+s.recv(16).decode('utf-8','replace')[:12])
except Exception: print('DOWN')
s.close()" 2>/dev/null)
  echo "$(date +%H:%M:%S) ${B:0:20}" >> wedge_watch.log
  case "$B" in SSH-SSH*) echo "$(date +%H:%M:%S) RECOVERED" >> wedge_watch.log; break;; esac
  sleep 60
done
