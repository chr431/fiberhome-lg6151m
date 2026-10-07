#!/usr/bin/env python3
"""rescue_shadow v1.0 -- shadow.override 未 bind 时的网络救援(P3 配套)

场景: rc.extend v2.1 钩子未生效(如 busybox grep -E 对钩子正则的行为差异),
开机后 /etc/shadow 回落镜像内建口令(轮换前的旧口令), 新口令进不去。
设备其余功能(路由/GUI/WiFi)不受影响, 只是 root SSH 认旧口令。

本工具:
  1. getpass 询问当前生效口令(即上一次轮换前的旧口令, 不进 argv/日志)。
  2. 上传只读诊断探针(经同一会话 cat, 无转义层):
     - 两个 override 文件的 md5/行数/有效 toor 行数
     - 部署版 rc.extend v2.1 钩子块的 sh -x 逐步执行(定位失败点)
     - busybox grep -E 对钩子正则的行为单测
  3. 修复: .bak 有效则恢复主文件并重新 bind, 校验生效 shadow 的 toor 哈希前缀。
  4. 全部输出回传 —— 把输出发给维护者即可定位根因。
"""
import getpass
import hashlib
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.abspath(os.environ.get("LG_SECRETS_DIR") or os.path.join(
    os.path.dirname(HERE), "..", "_local", "secrets")))
try:
    import device_local as D
except ImportError:
    D = None
import paramiko  # noqa: E402
import lgssh     # noqa: E402

PROBE = r'''#!/bin/sh
echo "== 文件状态 =="
for f in /data/gw/shadow.override /data/gw/shadow.override.bak; do
    if [ -f "$f" ]; then
        printf '%s: md5=%s lines=%s toor_valid=%s\n' "$f" \
            "$(md5sum "$f" | cut -c1-8)" "$(wc -l < "$f")" \
            "$(grep -cE '^toor:[*!'']' "$f" 2>/dev/null || echo 0)"
        grep -E '^toor:' "$f" | cut -c1-16
    else
        echo "$f: 不存在"
    fi
done
echo "== bind 状态 =="
grep ' /etc/shadow ' /proc/mounts || echo "(未 bind)"
echo "== grep 行为单测(钩子同款正则) =="
printf 'toor:$6$abcdefgh$ijkl\n' > /tmp/gt.txt
grep -qE '^toor:(\$[16]\$|!)' /tmp/gt.txt && echo "PATTERN-MATCH" || echo "PATTERN-NOMATCH"
rm -f /tmp/gt.txt
echo "== 部署版钩子块 sh -x 跟踪 =="
sed -n '/^if ! grep -q/,/^fi$/p' /data/rc.extend.sh > /tmp/hook.sh   # 唯一锚点(v2.1 现场复盘: 原精确模式少一字匹配0行)
wc -l /tmp/hook.sh
sh -x /tmp/hook.sh 2>&1
echo "== hook-rc=$? =="
echo "== 修复 =="
SO=/data/gw/shadow.override; SB=/data/gw/shadow.override.bak
if [ -f "$SB" ] && grep -qE '^toor:\$' "$SB" 2>/dev/null; then
    cp -f "$SB" "$SO" && echo "restore: 主文件已从 .bak 恢复"
fi
if ! grep -q ' /etc/shadow ' /proc/mounts; then
    chmod 600 "$SO"
    mount --bind "$SO" /etc/shadow && echo "bind: OK" || echo "bind: FAILED"
fi
echo "== 终态 =="
grep ' /etc/shadow ' /proc/mounts || echo "(仍未 bind)"
awk -F: '$1=="toor"{print "生效 shadow toor 哈希前缀:", substr($2,1,4)}' /etc/shadow
ls -la /data/gw/shadow.override*
'''

FIXTURE_OK = "bind: OK"


def main():
    host = os.environ.get("LG_HOST") or getattr(D, "HOST", "192.168.9.1")
    user = os.environ.get("LG_TOOR_USER") or getattr(D, "TOOR_USER", "toor")
    pw = getpass.getpass("当前生效的 toor 口令(轮换前的旧口令): ")
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(lgssh.PinPolicy() if lgssh.PIN else paramiko.AutoAddPolicy())
    c.connect(host, port=22, username=user, password=pw, timeout=10,
              allow_agent=False, look_for_keys=False)
    print("已连接(旧口令有效) — 运行诊断+修复探针")
    si, so, se = c.exec_command("cat > /tmp/probe_shadow.sh", timeout=15)
    si.write(PROBE); si.flush(); si.channel.shutdown_write()
    so.channel.recv_exit_status()
    out = lgssh.run(c, "sh /tmp/probe_shadow.sh; rm -f /tmp/probe_shadow.sh /tmp/hook.sh", timeout=60)
    print(out)
    c.close()
    if FIXTURE_OK in out:
        print("\n修复完成 — 新口令(轮换后的那个)现在应该可以登录; 请把上面完整输出发给维护者定位钩子根因。")
    else:
        print("\n探针未能完成 bind — 请把上面完整输出发给维护者。")


if __name__ == "__main__":
    main()
