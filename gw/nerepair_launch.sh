#!/bin/sh
# nerepair_launch.sh v1.1 -- single-instance launcher for the nerepair supervisor.
# Used as the watchdog SVC_TABLE restart recipe.  The pid survives exec, so the
# lock stays valid for the C supervisor.
# v1.1 (2026-10-31 质量轮): 锁改用 svc_lib 的 svc_lock(settle+回读护栏)。
#   原 v1.0 是手写 check-then-write: 开机 rc.extend 拉起与看门狗重启同刻并发
#   时, 两个 launcher 都能通过旧 pid 检查、各自写锁再各自 exec = 双 supervisor
#   实例(审计 nerepair_launch TOCTOU)。svc_lib 不可读时回退 v1.0 单检查语义。
. /data/gw/svc_lib.sh 2>/dev/null
if [ -n "$(command -v svc_lock 2>/dev/null)" ]; then
    svc_lock nerepair /data/gw/bin/nerepair && exec /data/gw/bin/nerepair
    exit 0
fi
_old=$(cat /tmp/nerepair.lock 2>/dev/null)
if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null && grep -qa '/data/gw/bin/nerepair' /proc/$_old/cmdline 2>/dev/null; then
    exit 0
fi
echo $$ > /tmp/nerepair.lock
exec /data/gw/bin/nerepair
