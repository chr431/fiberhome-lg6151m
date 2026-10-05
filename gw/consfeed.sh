#!/bin/sh
# consfeed -- v2 console feeder (deploy MANIFEST member; v2_access spawns it).
# login.sh holds the console fd but never reads (sleeps in a loop), so this
# interactive shell receives every typed keystroke. NO setsid (E3: absent in
# busybox; the old v1 file crashed here in an infinite loop).
while true; do
    sh -i </dev/console >/dev/console 2>&1
    sleep 5
done
