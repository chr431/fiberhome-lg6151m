#!/usr/bin/env python3
"""serial_server.py -- persistent serial console daemon for the LG6151M CPE.

Design (2026-10-02): serial is the PRIMARY channel (PC networking must stay
untouched -- the ZCode session dies if wired+wireless both drop).
  - login ONCE at startup; watcher thread owns all (re)logins; reboot-safe
  - command interface: loopback TCP 127.0.0.1:7717 only (zero network exposure)
  - marker-token protocol isolates command output from console printk noise
  - every byte archived to tmpfiles/serial_ring.log (post-mortem channel)
  - all threads exception-guarded; run under run_serial_server.sh supervisor
    for auto-restart

Protocol: client sends "RUN <timeout_s> <command>"; server replies with the
captured output, a final "__RC <n>" line (exit code), then "__END".
Also: PING -> PONG; STATE -> logged_in=<bool>; QUIT -> BYE then clean exit
(serial handle released -- always stop the server this way, never kill -9).

Usage:
  python tools/serial_server.py            # daemon (background)
  python tools/serial_cmd.py "uptime"      # client
"""
import socket, sys, os, time, threading, re, traceback

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import serial
import device_local as D

COM = "COM6"
BAUD = 921600
PORT = 7717
BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RING = os.path.join(BASE, "tmpfiles", "serial_ring.log")


class Console:
    def __init__(self):
        self.s = serial.Serial(COM, BAUD, bytesize=8, parity="N", stopbits=1, timeout=0.2)
        self.buf = b""
        self.ring = open(RING, "ab")
        self.logged_in = False
        self.lock = threading.Lock()

    def pump(self, sec):
        end = time.time() + sec
        while time.time() < end:
            d = self.s.read(4096)
            if d:
                self.ring.write(d)
                self.ring.flush()
                # NUL floods (seen on stock-v2 console) corrupt line assembly;
                # keep raw bytes in the ring for forensics but drop them from
                # the working buffer.
                d = d.replace(b"\x00", b"")
                if d:
                    self.buf += d
                if len(self.buf) > 262144:
                    self.buf = self.buf[-131072:]

    def sendline(self, text, pace=0.01):
        for ch in text:
            self.s.write(ch.encode())
            self.s.flush()
            time.sleep(pace)
        self.s.write(b"\n")
        self.s.flush()

    def expect(self, pattern, timeout):
        rx = re.compile(pattern.encode())
        t0 = time.time()
        while time.time() - t0 < timeout:
            self.pump(0.2)
            if rx.search(self.buf):
                self.buf = b""
                return True
        return False

    def ensure_login(self):
        with self.lock:
            if self.logged_in:
                return True
            try:
                self.s.reset_input_buffer()
            except Exception:
                pass
            self.buf = b""
            for _ in range(5):
                self.sendline("")
                self.pump(1.5)
                stripped = self.buf.rstrip()
                if ((b"root@" in self.buf and b"~#" in self.buf)
                        or stripped.endswith(b"~ #") or stripped.endswith(b"#")):
                    self.logged_in = True
                    self.ring.write(b"\n=== RESUMED SHELL ===\n")
                    self.buf = b""
                    return True
                if b"login:" in self.buf:
                    time.sleep(1.5)
                    self.buf = b""
                    self.sendline(D.TOOR_USER, 0.15)
                    if self.expect(r"assword", 10):
                        time.sleep(1.5)
                        self.sendline(D.TOOR_PASS, 0.15)
                        if self.expect(r"root@.*~#", 12):
                            self.logged_in = True
                            self.ring.write(b"\n=== LOGGED IN ===\n")
                            return True
                self.buf = b""
                time.sleep(2)
            return False

    def run(self, cmd, timeout=30):
        """Run one command; NEVER blocks on login (watcher owns that)."""
        if not self.logged_in:
            return "!! NOT LOGGED IN YET -- retry in a few seconds"
        if not self.lock.acquire(timeout=2):
            return "!! CONSOLE BUSY -- retry"
        try:
            token = "__X%dX" % int(time.time() * 1000 % 1000000)
            rx_tok = re.compile((token + r"_(\d+)").encode())
            out = b""
            # echo-verified resend (stock-v2 console thieves eat chars):
            # retype cmd+marker until the command echo arrives intact, max 3.
            cmd_head = cmd[:24].encode()
            for attempt in range(3):
                self.buf = b""
                self.sendline(cmd, 0.01)
                time.sleep(0.2)
                self.sendline("echo %s_$?" % token, 0.01)
                t0 = time.time()
                while time.time() - t0 < timeout:
                    self.pump(0.3)
                    out += self.buf
                    self.buf = b""
                    m = rx_tok.search(out)
                    if m:
                        rc = m.group(1).decode()
                        idx = out.find(m.group(0))
                        body = out[:idx].decode("utf-8", "replace")
                        lines = [l for l in body.splitlines()
                                 if l.strip() and token not in l]
                        return "\n".join(lines) + "\n__RC " + rc
                    if cmd_head in out:
                        # echo landed; keep waiting for the marker only
                        pass
                out = b""   # full timeout without marker -> resend
            return out.decode("utf-8", "replace")[-4000:] + "\n!! TIMEOUT (3 resend attempts)"
        finally:
            self.lock.release()


con = Console()


def log(msg):
    sys.stderr.write("serial_server: %s\n" % msg)
    sys.stderr.flush()


def watcher():
    while True:
        try:
            if con.logged_in:
                if con.lock.acquire(timeout=5):
                    con.lock.release()
                con.pump(0.2)
                if b"login:" in con.buf[-512:]:
                    con.buf = b""
                    con.logged_in = False
                    log("shell lost, relogging in")
                time.sleep(3)
                continue
            ok = con.ensure_login()
            log("login attempt -> %s" % ok)
        except Exception:
            log("watcher exc: %s" % traceback.format_exc()[-300:])
        time.sleep(3)


def client_loop(conn):
    try:
        f = conn.makefile("rwb", buffering=0)
        while True:
            line = f.readline()
            if not line:
                break
            parts = line.decode(errors="replace").strip().split(" ", 2)
            if parts and parts[0] == "RUN":
                timeout = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 30
                cmd = parts[2] if len(parts) > 2 else ""
                res = con.run(cmd, timeout)
                f.write(res.encode() + b"\n__END\n")
            elif parts and parts[0] == "PING":
                f.write(b"PONG\n")
            elif parts and parts[0] == "STATE":
                f.write(("logged_in=%s\n" % con.logged_in).encode())
            elif parts and parts[0] == "QUIT":
                # Graceful shutdown: close COM handle properly so the CH340
                # driver never leaks the port (Stop-Process -Force wedges it
                # into GEN_FAILURE, fixable only by PnP disable/enable).
                f.write(b"BYE\n")
                log("QUIT received -- closing %s and exiting" % COM)
                time.sleep(0.5)   # let BYE drain before the hard exit
                if con.lock.acquire(timeout=3):
                    con.lock.release()
                try:
                    con.s.close()
                except Exception:
                    pass
                try:
                    con.ring.write(b"\n=== SERVER QUIT ===\n")
                    con.ring.flush()
                    con.ring.close()
                except Exception:
                    pass
                os._exit(0)
    except Exception:
        log("client exc: %s" % traceback.format_exc()[-300:])
    finally:
        try:
            conn.close()
        except Exception:
            pass


def main():
    threading.Thread(target=watcher, daemon=True).start()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", PORT))
    srv.listen(4)
    log("listening on 127.0.0.1:%d (%s)" % (PORT, COM))
    threading.Thread(target=con.ensure_login, daemon=True).start()
    while True:
        try:
            conn, _ = srv.accept()
            threading.Thread(target=client_loop, args=(conn,), daemon=True).start()
        except Exception:
            log("accept exc: %s" % traceback.format_exc()[-300:])
            time.sleep(1)


if __name__ == "__main__":
    main()
