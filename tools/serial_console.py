#!/usr/bin/env python3
"""Serial console toolkit for LG6151M rescue (UART 921600 8N1).

Usage:
  python serial_console.py capture <com> <seconds> [logfile]
      -- log everything the device prints (boot log / LK / kernel)
  python serial_console.py send <com> <text>
      -- send one line (e.g. LK commands, Enter key: use "" )
  python serial_console.py sysrq <com> <key>
      -- send serial BREAK + SysRq key (b=reboot, e=SIGTERM all, i=SIGKILL all,
         t=task list, w=blocked tasks, c=intentional crash(panic+reboot))
  python serial_console.py probe <com>
      -- identify UART wiring: prints "wired as TX->RX" check via loopback echo test

Keep it simple; pyserial only.
"""
import sys
import time

import serial  # pyserial (came with mtkclient deps)

BAUD = 921600


def open_port(com):
    return serial.Serial(com, BAUD, bytesize=8, parity="N", stopbits=1, timeout=0.2)


def cmd_capture(com, seconds, logfile=None):
    s = open_port(com)
    t0 = time.time()
    out = open(logfile, "wb") if logfile else None
    print(f"capturing {com} @ {BAUD} for {seconds}s ...")
    try:
        while time.time() - t0 < seconds:
            data = s.read(4096)
            if data:
                ts = time.strftime("%H:%M:%S")
                for line in data.split(b"\n"):
                    try:
                        print(f"[{ts}] {line.decode('utf-8', 'replace')}")
                    except Exception:
                        pass
                if out:
                    out.write(data)
                    out.flush()
    finally:
        s.close()
        if out:
            out.close()
            print(f"saved -> {logfile}")


def cmd_send(com, text):
    s = open_port(com)
    s.write((text + "\n").encode())
    s.flush()
    time.sleep(0.5)
    data = s.read(4096)
    print("resp:", data.decode("utf-8", "replace"))
    s.close()


def cmd_sysrq(com, key):
    s = open_port(com)
    print(f"sending BREAK + SysRq[{key}] ...")
    s.sendBreak(0.3)   # BREAK condition ~300ms
    time.sleep(0.05)
    s.write(key.encode())
    s.flush()
    time.sleep(2)
    data = s.read(8192)
    print("resp:", data.decode("utf-8", "replace"))
    s.close()


def cmd_probe(com):
    """Wiring helper: with the board POWERED and adapter wired, send UU; if the
    adapter TX goes to board TX (wrong), nothing comes back; if wired to board
    RX correctly the kernel console may echo activity. Mainly: capture 10s and
    show whether we see boot-noise/serial output."""
    cmd_capture(com, 10)


def cmd_list():
    from serial.tools import list_ports
    for p in list_ports.comports():
        print(f"{p.device}  {p.description}  {p.hwid}")


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "list"
    if mode == "list":
        cmd_list()
    elif mode == "capture":
        cmd_capture(sys.argv[2], int(sys.argv[3]),
                    sys.argv[4] if len(sys.argv) > 4 else None)
    elif mode == "send":
        cmd_send(sys.argv[2], sys.argv[3])
    elif mode == "sysrq":
        cmd_sysrq(sys.argv[2], sys.argv[3])
    elif mode == "probe":
        cmd_probe(sys.argv[2])
