#!/usr/bin/env python3
"""Simple HTTP PUT/POST receiver used while pulling device backups
(alternative to the nginx /www/html/static bind-mount channel).
Usage: python recv_server.py [port]   (saves into ./received)"""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "received")
os.makedirs(ROOT, exist_ok=True)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_PUT(self):
        name = self.path.lstrip("/").replace("..", "_").replace("/", "_") or "unnamed"
        length = int(self.headers.get("Content-Length", 0))
        tmp = os.path.join(ROOT, name + ".part")
        with open(tmp, "wb") as f:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(1 << 20, remaining))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        os.replace(tmp, os.path.join(ROOT, name))
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()
        sys.stderr.write(f"[recv] {name}: {length} bytes\n")

    do_POST = do_PUT


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    print(f"receiver on 0.0.0.0:{port} -> {os.path.abspath(ROOT)}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
