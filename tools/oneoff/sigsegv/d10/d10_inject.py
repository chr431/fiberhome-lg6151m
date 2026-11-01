#!/usr/bin/env python3
"""d10_inject.py -- D10 semantic experiment: single-flow UDP injector (PC side).

Pre-registered arms (docs/SIGSEGV/05_LOG/2026-11-01-11-d10-semantic.md):
  242B frame  -> payload 200
  1242B frame -> payload 1200
Sends to 192.168.9.1:47913 (closed UDP port) from a bound source IP at a fixed
pps, logs PC-side start/end anchors and achieved rate. One-off, not registered.

Usage:
  python d10_inject.py --src 192.168.9.222 --plen 200 --pps 1000 --seconds 180 \
      [--dst 192.168.9.1 --dport 47913] [--tag A1]
"""
import argparse
import json
import os
import socket
import sys
import time

LOGDIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--plen", type=int, required=True, help="UDP payload bytes")
    ap.add_argument("--pps", type=int, default=1000)
    ap.add_argument("--seconds", type=float, required=True)
    ap.add_argument("--dst", default="192.168.9.1")
    ap.add_argument("--dport", type=int, default=47913)
    ap.add_argument("--tag", default="arm")
    ns = ap.parse_args()

    os.makedirs(LOGDIR, exist_ok=True)

    # Windows timer resolution -> 1 ms so sleep pacing at 1 kHz is possible.
    try:
        import ctypes
        ctypes.windll.winmm.timeBeginPeriod(1)
    except Exception:
        pass

    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((ns.src, 0))
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 1 << 20)

    payload = bytearray(b"D10" + b"\x00" * (ns.plen - 4 if ns.plen > 4 else ns.plen))
    hdr = "D10:%s:%d:" % (ns.tag, ns.plen)
    hb = hdr.encode()[:16].ljust(16, b"\x00")
    payload[0:16] = hb

    interval = 1.0 / ns.pps
    t_start = time.time()
    mono0 = time.monotonic()
    sent = 0
    err = 0
    seq = 0
    deadline = mono0 + ns.seconds
    next_t = mono0
    while True:
        now = time.monotonic()
        if now >= deadline:
            break
        if now < next_t - 0.0015:
            time.sleep(max(0.0005, next_t - now - 0.0005))
            continue
        seq += 1
        payload[16:20] = seq.to_bytes(4, "big")
        try:
            s.sendto(bytes(payload), (ns.dst, ns.dport))
            sent += 1
        except OSError:
            err += 1
        next_t += interval
        if next_t < now - interval * 50:  # fell badly behind: resync
            next_t = now + interval

    t_end = time.time()
    dur = time.monotonic() - mono0
    rec = {
        "tag": ns.tag,
        "src": ns.src,
        "dst": ns.dst,
        "dport": ns.dport,
        "plen": ns.plen,
        "frame_eth": ns.plen + 42,
        "pps_target": ns.pps,
        "seconds_target": ns.seconds,
        "sent": sent,
        "send_errors": err,
        "dur_s": round(dur, 3),
        "pps_achieved": round(sent / dur, 1) if dur > 0 else 0,
        "pc_epoch_start": t_start,
        "pc_epoch_end": t_end,
    }
    out = os.path.join(LOGDIR, "inject_%s.json" % ns.tag)
    with open(out, "w") as f:
        json.dump(rec, f, indent=1)
    print(json.dumps(rec))
    s.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
