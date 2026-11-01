#!/usr/bin/env python3
"""d10_drive2.py -- D10 pass 2 (power extension, declared deviation).

Pass 1 (single scanary, 180 s arms) hit a cold writer state (~0.2 records/min).
Pass 2: 3 concurrent scanary instances (independent stacks -> 3x target
surface) + 300 s arms, same injection definition, same anchors. Slotwatch
keeps running throughout. Content endpoint (len/ip per record) is unaffected
by scanary restarts; rate comparability stays within-pass only.
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
    'echo EV=$(tail -1 /data/repro/d10_s2_a.log | sed "s/^EV \\([0-9]*\\).*/\\1/"); '
    'echo EVB=$(tail -1 /data/repro/d10_s2_b.log | sed "s/^EV \\([0-9]*\\).*/\\1/"); '
    'echo EVC=$(tail -1 /data/repro/d10_s2_c.log | sed "s/^EV \\([0-9]*\\).*/\\1/"); '
    'echo ETH1=$(grep eth1 /proc/net/dev)'
)

SCANARY = ("/data/repro/scanary --log /data/repro/d10_s2_%s.log --duration 2200 "
           "--probe-sec 120 --period-us 5000 --stride 16 --writeback safe "
           "--victim main --hold-us 10000 --depth-list 0")

ARMS = [
    ("A1b", "192.168.9.222", 200, 300),
    ("B1b", "192.168.9.223", 1200, 300),
    ("A2b", "192.168.9.223", 200, 300),
    ("C1b", "192.168.9.222", 1200, 300),
]
GAP = 60
SETTLE = 180
TAIL_QUIET = 180


def ssh(cmd):
    return subprocess.run([sys.executable, LGSSH, cmd],
                          capture_output=True, text=True, cwd=PUB)


def ssh_anchor(tag):
    pc0 = time.time()
    r = ssh(ANCHOR_CMD)
    pc1 = time.time()
    rec = {"tag": tag, "pc_before": pc0, "pc_after": pc1, "raw": r.stdout.strip()}
    for line in r.stdout.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            rec[k.lower()] = v.strip()
    with open(os.path.join(RUN, "anchor_%s.json" % tag), "w") as f:
        json.dump(rec, f, indent=1)
    return rec


def run_arm(tag, src, plen, seconds):
    r = subprocess.run(
        [sys.executable, INJECT, "--src", src, "--plen", str(plen),
         "--pps", "1000", "--seconds", str(seconds), "--tag", tag],
        capture_output=True, text=True, cwd=HERE)
    print(r.stdout.strip())
    if r.returncode != 0:
        print("INJECTOR FAILED", r.stderr[-400:], file=sys.stderr)


def main():
    os.makedirs(RUN, exist_ok=True)
    r = ssh('for i in a b c; do ( %s >/dev/null 2>&1 & ); sleep 8; done; pidof scanary'
            % SCANARY.replace("%s", "$i"))
    print("scanary instances:", r.stdout.strip())
    time.sleep(SETTLE)
    a = ssh_anchor("B0b_end")
    print("B0b_end:", a.get("up"), a.get("ev"), a.get("evb"), a.get("evc"))
    for tag, src, plen, secs in ARMS:
        run_arm(tag, src, plen, secs)
        a = ssh_anchor(tag + "_end")
        print(tag, "end:", a.get("up"), a.get("ev"))
        time.sleep(GAP)
    t0 = time.time()
    while time.time() - t0 < TAIL_QUIET:
        time.sleep(5)
    a = ssh_anchor("B0bp_end")
    print("B0bp_end:", a.get("up"), a.get("ev"))
    print("DRIVER2_DONE")


if __name__ == "__main__":
    main()
