#!/bin/sh
# nerepair_launch.sh v1.0 -- single-instance launcher for the nerepair supervisor.
# Writes /tmp/nerepair.lock (pid) then execs nerepair; used as the watchdog
# SVC_TABLE restart recipe.  The pid survives exec, so the lock stays valid.
old=$(cat /tmp/nerepair.lock 2>/dev/null)
if [ -n "$old" ] && kill -0 "$old" 2>/dev/null && grep -qa '/data/gw/bin/nerepair' /proc/$old/cmdline 2>/dev/null; then
    exit 0
fi
echo $$ > /tmp/nerepair.lock
exec /data/gw/bin/nerepair
