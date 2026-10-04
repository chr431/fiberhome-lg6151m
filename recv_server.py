#!/usr/bin/env python3
"""Simple PUT/POST receiver for device backups. Saves into backup/."""
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = r"D:\Repo\lg6151m\backup"
os.makedirs(ROOT, exist_ok=True)


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_PUT(self):
        name = self.path.lstrip("/").replace("..", "_").replace("/", "_") or "unnamed"
        path = os.path.join(ROOT, name)
        length = int(self.headers.get("Content-Length", 0))
        tmp = path + ".part"
        with open(tmp, "wb") as f:
            remaining = length
            while remaining > 0:
                chunk = self.rfile.read(min(1024 * 1024, remaining))
                if not chunk:
                    break
                f.write(chunk)
                remaining -= len(chunk)
        os.replace(tmp, path)
        self.send_response(201)
        self.send_header("Content-Length", "0")
        self.end_headers()
        sys.stderr.write(f"[recv] {name}: {length} bytes\n")
        sys.stderr.flush()

    do_POST = do_PUT

    def log_message(self, fmt, *args):
        sys.stderr.write("[http] " + fmt % args + "\n")


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8888
    print(f"receiver on 0.0.0.0:{port} -> {ROOT}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
