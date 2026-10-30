#!/usr/bin/env python3
"""Reusable SSH helper for the rooted LG6151M.
Usage:
  python lgssh.py "command"          run a command, print output
  python lgssh.py -s remote local    sftp get
v1.4 (2026-10-31 dropbear 排查轮): connect() 加指数退避重试(3 次, 1/2/4s)。
      实测定罪(设备侧 tcpdump): 20 路并发连接, 设备 SYN-ACK 20/20 且 banner
      与密钥交换数据全部送达, 全部 RST 均发自 PC 侧 —— 设备 dropbear 无辜,
      杀连接的是 PC 本机代理栈(Mihomo TUN 类, AGENTS 陷阱表同族)。重试把
      并发刺峰化为顺序重连, 对该故障形态免疫; 指纹不匹配仍立即中止(不重试)。
v1.3: 主机密钥指纹钉死(审计P0-5) — device_local.HOST_KEY_FP / env LG_HOST_KEY_FP
      (md5 hex, 冒号可选)。配置了指纹时每次连接先校验后认证, 不匹配即拒绝;
      未配置时保持旧 AutoAdd 行为(兼容)。
"""
import hashlib
import os
import sys
import time

import paramiko

# 凭证从环境变量读取(LG_HOST/LG_TOOR_USER/LG_TOOR_PASS), 缺省回退 _local/secrets/device_local.py
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.abspath(os.environ.get("LG_SECRETS_DIR") or os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "..", "_local", "secrets")))
try:
    import device_local as _D
except ImportError:
    _D = None
HOST = os.environ.get("LG_HOST") or getattr(_D, "HOST", "192.168.8.1")
USER = os.environ.get("LG_TOOR_USER") or getattr(_D, "TOOR_USER", "toor")
PW = os.environ.get("LG_TOOR_PASS") or getattr(_D, "TOOR_PASS", "")
PIN = (os.environ.get("LG_HOST_KEY_FP") or getattr(_D, "HOST_KEY_FP", "") or "").replace(":", "").lower()


class PinPolicy(paramiko.MissingHostKeyPolicy):
    """无状态指纹校验: 每次连接都走 missing_host_key → 先比指纹再放行认证。"""

    def missing_host_key(self, client, hostname, key):
        got = hashlib.md5(key.asbytes()).hexdigest()
        if PIN and got != PIN:
            raise paramiko.SSHException(
                "host key fingerprint mismatch: got %s expect %s" % (got, PIN))
        client.get_host_keys().add(hostname, key.get_name(), key)


def connect(retries=3):
    """Connect with exponential backoff.

    v1.4: PC 本机代理栈(Mihomo TUN 类)会在连接并发/密钥交换阶段单方面掐死
    连接(设备侧无辜, 见头注) — 立刻重连即可成功。指纹不匹配是安全告警,
    立即上抛, 不在重试之列。
    """
    last = None
    for i in range(retries):
        if i:
            time.sleep(1 << (i - 1))   # 1s, 2s
        c = paramiko.SSHClient()
        c.set_missing_host_key_policy(PinPolicy() if PIN else paramiko.AutoAddPolicy())
        try:
            c.connect(HOST, port=22, username=USER, password=PW, timeout=10,
                      allow_agent=False, look_for_keys=False, banner_timeout=20)
            return c
        except paramiko.SSHException as e:
            if "fingerprint mismatch" in str(e):
                raise
            last = e
            try:
                c.close()
            except Exception:
                pass
        except OSError as e:
            last = e
            try:
                c.close()
            except Exception:
                pass
    raise last


def run(c, cmd, timeout=60):
    _, out, err = c.exec_command(cmd, timeout=timeout)
    o = out.read().decode("utf-8", "replace")
    e = err.read().decode("utf-8", "replace")
    return o + (("\n[stderr] " + e) if e.strip() else "")


def main():
    c = connect()
    try:
        if len(sys.argv) >= 3 and sys.argv[1] == "-s":
            sftp = c.open_sftp()
            sftp.get(sys.argv[2], sys.argv[3])
            print(f"got {sys.argv[2]} -> {sys.argv[3]}")
        else:
            print(run(c, sys.argv[1] if len(sys.argv) > 1 else "id"))
    finally:
        c.close()


if __name__ == "__main__":
    main()
