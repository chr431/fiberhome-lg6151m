#!/bin/sh
# slotguard_launch.sh v1.0 -- single-instance launcher for the slot sanitizer.
# Used as the watchdog SVC_TABLE restart recipe.  The pid survives exec, so the
# lock written by svc_lock stays valid for the C process.
#
# Fail-closed on a missing binary: the deploy order is binary first, then this
# recipe and the SVC_TABLE row (docs/SIGSEGV/SLOTGUARD_DESIGN.md §7).  Exiting 0
# without exec would make the supervisor report a healthy service that does not
# exist, so a missing binary is a hard error (exit 1) and the reason lands in
# whatever out-file the supervisor redirects.
. /data/gw/svc_lib.sh 2>/dev/null
if [ ! -x /data/gw/bin/slotguard ]; then
    echo "slotguard_launch: /data/gw/bin/slotguard missing or not executable -- refusing" >&2
    exit 1
fi
if [ -n "$(command -v svc_lock 2>/dev/null)" ]; then
    svc_lock slotguard /data/gw/bin/slotguard && exec /data/gw/bin/slotguard
    exit 0
fi
_old=$(cat /tmp/slotguard.lock 2>/dev/null)
if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null && grep -qa '/data/gw/bin/slotguard' /proc/$_old/cmdline 2>/dev/null; then
    exit 0
fi
echo $$ > /tmp/slotguard.lock
exec /data/gw/bin/slotguard
