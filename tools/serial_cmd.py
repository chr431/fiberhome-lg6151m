#!/usr/bin/env python3
"""serial_cmd.py -- thin client for serial_server.py (loopback :7717).

  python tools/serial_cmd.py "uptime"                          # one command
  python tools/serial_cmd.py --t 60 "sh /data/gw/dial_5g.sh"    # longer timeout
  python tools/serial_cmd.py --raw QUIT                        # PING/STATE/QUIT
"""
import socket, sys

PORT = 7717


def main():
    args = sys.argv[1:]
    timeout = 30
    if args and args[0] == "--t":
        timeout = int(args[1])
        args = args[2:]
    raw = False
    if args and args[0] == "--raw":
        raw = True
        args = args[1:]
    cmd = " ".join(args)
    if not cmd:
        sys.exit("usage: serial_cmd.py [--t N] <command> | --raw PING|STATE|QUIT")
    s = socket.create_connection(("127.0.0.1", PORT), timeout=8)
    s.settimeout(timeout + 30)
    if raw:
        # PING/STATE/QUIT replies have no __END marker; short drain instead
        s.settimeout(3)
        s.sendall(cmd.encode() + b"\n")
        data = b""
        while True:
            try:
                chunk = s.recv(4096)
            except socket.timeout:
                break
            if not chunk:
                break
            data += chunk
        text = data.decode("utf-8", "replace")
        for line in text.splitlines():
            if line.strip():
                print(line)
        s.close()
        return
    s.sendall(("RUN %d %s" % (timeout, cmd)).encode() + b"\n")
    data = b""
    while True:
        try:
            chunk = s.recv(4096)
        except socket.timeout:
            data += b"\n!! CLIENT TIMEOUT"
            break
        if not chunk:
            break
        data += chunk
        if b"__END" in data:
            break
    text = data.decode("utf-8", "replace")
    for line in text.splitlines():
        if line.strip() and line.strip() != "__END":
            print(line)
    s.close()


if __name__ == "__main__":
    main()
