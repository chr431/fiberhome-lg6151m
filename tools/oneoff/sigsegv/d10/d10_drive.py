#!/usr/bin/env python3
"""d10_drive.py -- runs the pre-registered D10 arm sequence (PC side).

Arms (05_LOG/2026-11-01-11-d10-semantic.md §4):
  B0 (already running, we only anchor) -> A1(242,.222) -> B1(1242,.223)
  -> A2(242,.223) -> C1(1242,.222) -> B0'  ; 60 s gaps.
Each boundary: one lgssh anchor capturing device realtime + /proc/uptime +
last scanary EV + eth1 counter + covariates; PC wall time recorded around
the call. Device realtime steps under NTP, so uptime is the master clock.
"""
import json
import os
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RUN = os.path.join(HERE, "run")
PUB = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
LGSSH = os.path.join(PUB, "tools", "lgssh.py")
INJECT = os.path.join(HERE, "d10_inject.py")

ANCHOR_CMD = (
    'echo RT=$(date +%s.%N); echo UP=$(cut -d" " -f1 /proc/uptime); '
    'echo EV=$(tail -1 /data/repro/d10_scanary.log | sed "s/^EV \\([0-9]*\\).*/\\1/"); '
    'echo ETH1=$(grep eth1 /proc/net/dev); '
    'echo CT=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null); '
    'echo MEM=$(grep MemAvailable /proc/meminfo | tr -dc 0-9)'
)

ARMS = [
    # tag, src, plen, seconds
    ("A1", "192.168.9.222", 200, 180),
    ("B1", "192.168.9.223", 1200, 180),
    ("A2", "192.168.9.223", 200, 180),
    ("C1", "192.168.9.222", 1200, 180),
]
GAP = 60
TAIL_QUIET = 120  # final no-injection window


def ssh_anchor(tag):
    pc0 = time.time()
    r = subprocess.run(
        [sys.executable, LGSSH, ANCHOR_CMD],
        capture_output=True, text=True, cwd=PUB,
    )
    pc1 = time.time()
    out = r.stdout.strip()
    rec = {"tag": tag, "pc_before": pc0, "pc_after": pc1, "raw": out}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            rec[k.lower()] = v.strip()
    with open(os.path.join(RUN, "anchor_%s.json" % tag), "w") as f:
        json.dump(rec, f, indent=1)
    return rec


def run_arm(tag, src, plen, seconds):
    pps = 1000
    r = subprocess.run(
        [sys.executable, INJECT, "--src", src, "--plen", str(plen),
         "--pps", str(pps), "--seconds", str(seconds), "--tag", tag],
        capture_output=True, text=True, cwd=HERE,
    )
    print(r.stdout.strip())
    if r.returncode != 0:
        print("INJECTOR FAILED", r.stderr[-400:], file=sys.stderr)


def main():
    os.makedirs(RUN, exist_ok=True)
    a = ssh_anchor("B0_end")
    print("B0_end anchor:", a.get("up"), a.get("ev"))
    for tag, src, plen, secs in ARMS:
        run_arm(tag, src, plen, secs)
        a = ssh_anchor(tag + "_end")
        print(tag, "end anchor:", a.get("up"), a.get("ev"))
        time.sleep(GAP)
    t0 = time.time()
    while time.time() - t0 < TAIL_QUIET:
        time.sleep(5)
    a = ssh_anchor("B0p_end")
    print("B0p_end anchor:", a.get("up"), a.get("ev"))
    print("DRIVER_DONE")


if __name__ == "__main__":
    main()
