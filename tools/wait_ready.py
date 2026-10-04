#!/usr/bin/env python3
"""wait_ready.py -- 轮询等待器（取代一切长 sleep 的标准手段）。

设备完成即可返回，绝不干等；超时才失败。等待条件三选一（可组合）：

  python tools/wait_ready.py --tcp 192.168.9.1:22 --t 300
      轮询 TCP 端口通（SSH/dropbear 起来没有）
  python tools/wait_ready.py --ping 192.168.9.1 --t 120
      轮询 ICMP 可达
  python tools/wait_ready.py --mark SERIAL_LIVE --t 300 --echo "uptime"
      经 serial_server(:7717) 发探测命令，等 marker 回显出现
      （串口通道活着 == 控制台 shell 活着的充分证据）

  --i 2        轮询间隔秒数(默认 2, 上限 10 -- 禁止把间隔调成变相长 sleep)
  --t 300      总超时(到点 exit 1)

纪律(Docs/DISCIPLINE.md R4): PC 侧等待设备一律用本工具; 任何 tools/ 脚本
里出现 sleep > 10s 视为 bug。
"""
import socket
import subprocess
import sys
import time

PORT = 7717


def p_tcp(host_port, timeout=5):
    host, port = host_port.rsplit(":", 1)
    try:
        s = socket.create_connection((host, int(port)), timeout=timeout)
        s.close()
        return True
    except OSError:
        return False


def p_ping(ip):
    # -w 2000: 整体 2s 上限; 中文 Windows ping 输出 GBK, 用 bytes 判定不解码
    r = subprocess.run(["ping", "-n", "1", "-w", "2000", ip],
                       capture_output=True, timeout=6)
    return r.returncode == 0 and b"TTL=" in r.stdout.upper()


def p_serial_marker(echo_cmd, marker, tmo):
    """经 serial_server 发命令并等 marker 出现在输出里。"""
    try:
        s = socket.create_connection(("127.0.0.1", PORT), timeout=5)
    except OSError:
        return False
    try:
        s.settimeout(tmo)
        s.sendall(("RUN %d %s" % (tmo, echo_cmd)).encode() + b"\n")
        data = b""
        while b"__END" not in data:
            chunk = s.recv(4096)
            if not chunk:
                break
            data += chunk
        return marker.encode() in data
    except OSError:
        return False
    finally:
        s.close()


def main():
    args = sys.argv[1:]
    tmo, iv = 300, 2
    tcp = ping = mark = echo = None
    it = iter(range(len(args)))
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--t":
            tmo = int(args[i + 1]); i += 2
        elif a == "--i":
            iv = min(int(args[i + 1]), 10) or 2; i += 2
        elif a == "--tcp":
            tcp = args[i + 1]; i += 2
        elif a == "--ping":
            ping = args[i + 1]; i += 2
        elif a == "--mark":
            mark = args[i + 1]; i += 2
        elif a == "--echo":
            echo = args[i + 1]; i += 2
        else:
            sys.exit("未知参数: %s" % a)
    if not (tcp or ping or mark):
        sys.exit("至少给一个条件: --tcp / --ping / --mark")
    if mark and not echo:
        echo = "echo " + mark

    t0 = time.time()
    n = 0
    while time.time() - t0 < tmo:
        n += 1
        ok = True
        if tcp and not p_tcp(tcp):
            ok = False
        if ok and ping and not p_ping(ping):
            ok = False
        if ok and mark and not p_serial_marker(echo, mark, min(30, tmo)):
            ok = False
        if ok:
            print("READY after %.1fs (%d polls)" % (time.time() - t0, n))
            return 0
        time.sleep(iv)
    print("TIMEOUT after %.0fs (%d polls): tcp=%s ping=%s mark=%s"
          % (time.time() - t0, n, tcp, ping, mark))
    return 1


if __name__ == "__main__":
    sys.exit(main())
