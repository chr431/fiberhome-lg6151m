#!/usr/bin/env python3
"""Catch the LK console: barrage 0x03 (Ctrl-C) from power-on; on 'PINTEST'
detection stop the barrage and interact. Per RE: shell_entry @0x5054 does ONE
non-blocking dgetc poll; byte 0x03 within 500ms window -> console_thread."""
import serial
import sys
import threading
import time

PORT = sys.argv[1] if len(sys.argv) > 1 else "COM6"
TIMEOUT = int(sys.argv[2]) if len(sys.argv) > 2 else 600

s = serial.Serial(PORT, 921600, timeout=0.02)
s.reset_input_buffer()

stop = False


def barrage():
    while not stop:
        try:
            s.write(b"\x03")
            s.flush()
        except Exception:
            pass
        time.sleep(0.015)


t = threading.Thread(target=barrage, daemon=True)
t.start()
print(f"CTRL-C TRAP ARMED on {PORT}, {TIMEOUT}s window. Power-cycle the CPE now.", flush=True)

buf = b""
t0 = time.time()
hit = False
while time.time() - t0 < TIMEOUT:
    d = s.read(8192)
    if d:
        buf += d
        if b"PINTEST" in d or b"PINTEST" in buf[-2000:]:
            hit = True
            break
        if b"entering main console loop" in buf:
            hit = True
            break

stop = True
time.sleep(0.3)
s.reset_input_buffer()

if not hit:
    s.close()
    open("lk_trap_fail.log", "wb").write(buf)
    print(f"NO PINTEST in {TIMEOUT}s. {len(buf)} bytes -> lk_trap_fail.log")
    sys.exit(1)

print("*** PINTEST CAUGHT! console should be live ***", flush=True)
time.sleep(0.5)
s.reset_input_buffer()
s.write(b"\r\n")
s.flush()
time.sleep(1)
s.write(b"help\r")
s.flush()
time.sleep(2)
out = b""
t1 = time.time()
while time.time() - t1 < 4:
    d = s.read(8192)
    if d:
        out += d
print(out.decode("utf-8", "replace")[:3000])
open("lk_console_session.log", "ab").write(b"\n=== session " + str(time.time()).encode() + b" ===\n" + out)
# keep port open for interactive follow-ups? script exits; rerun with commands.
s.close()
print("--- capture saved to lk_console_session.log ---")
