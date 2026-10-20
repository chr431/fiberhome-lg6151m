#!/usr/bin/env python3
"""fuzz_logc.py -- on-device structural fuzzer for the logc frame parser (P1-2).

Why: logc v1.0/v1.1 crashed twice (SIGSEGV) while reading a live syslog ring.
The parser is length-checked by construction, so the crash needs a reproducer.
This tool builds mutated record streams (valid frames + truncations + bogus
lengths + type swaps + random garbage), feeds them to the *real device binary*
through `logc --stdin`, and reports any signal death.  A crash leaves
/tmp/logc.crash (signal/pid/frame offset/frame length/buffer fill) and the
offending corpus is saved locally for offline replay.

Usage:
  python tools/fuzz_logc.py                 # 6 x ~1.5MB corpora, seeds 1..6
  python tools/fuzz_logc.py --rounds 20 --seed 100
  python tools/fuzz_logc.py --from-ring     # seed with a real ring dump first
  python tools/fuzz_logc.py --keep          # keep device temp files
"""
import os
import random
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lgssh  # noqa: E402

DEV = "/data/gw/bin/logc"
TMP = "/tmp/logc_fuzz"


def mk_frame(t_ms, mid, prio, src, msg, rng=None):
    """Build one logd record: 5 named blobmsg attrs behind a length header."""
    def attr(typ, name, data):
        nb = name.encode()
        nl = len(nb)
        hlen = (2 + nl + 1 + 3) & ~3
        plen = hlen + len(data)
        pad = (plen + 4 + 3) & ~3
        hdr = struct.pack(">I", 0x80000000 | (typ << 24) | (plen + 4))
        body = struct.pack(">H", nl) + nb + b"\0"
        body += b"\0" * (hlen - 2 - nl)
        body += data
        body += b"\0" * (pad - 4 - plen)
        return hdr + body

    attrs = b""
    attrs += attr(4, "time", struct.pack(">Q", t_ms))
    m = msg.encode() if isinstance(msg, str) else msg
    attrs += attr(3, "msg", m + b"\0")
    attrs += attr(5, "id", struct.pack(">I", mid))
    attrs += attr(5, "priority", struct.pack(">I", prio))
    attrs += attr(5, "source", struct.pack(">I", src))
    return struct.pack(">I", len(attrs) + 4) + attrs


def corpus(seed, size):
    rng = random.Random(seed)
    out = bytearray()
    base = 1792400000000
    i = 0
    while len(out) < size:
        kind = rng.randrange(10)
        i += 1
        if kind < 4:
            msg = "rec-%d-%s" % (i, "x" * rng.randrange(0, 200))
            out += mk_frame(base + i * 1000, i, 0x1e, rng.randrange(3), msg)
        elif kind == 4:  # truncate a valid frame
            f = mk_frame(base + i * 1000, i, 0x1e, 0, "trunc-" + "y" * 50)
            cut = rng.randrange(1, len(f))
            out += f[:cut]
        elif kind == 5:  # bogus length header + garbage
            out += struct.pack(">I", rng.choice([0, 3, 4, 0x00ffffff, 0x7fffffff]))
            out += bytes(rng.randrange(256) for _ in range(rng.randrange(0, 80)))
        elif kind == 6:  # swap an attribute type inside an otherwise valid frame
            f = bytearray(mk_frame(base + i * 1000, i, 0x1e, 0, "typeswap-" + "z" * 30))
            if len(f) > 20:
                pos = rng.randrange(4, len(f) - 4)
                f[pos] = rng.randrange(256)
            out += bytes(f)
        elif kind == 7:  # oversized msg attribute
            out += mk_frame(base + i * 1000, i, 0x1e, 0, "huge-" + "q" * 9000)
        elif kind == 8:  # embedded NUL / invalid time
            out += mk_frame(rng.choice([0, 2**63, 2**64 - 1, base + i]),
                            i, rng.choice([0, 0x1e, 0xff]), 0, b"nul\0inside")
        else:  # pure noise
            out += bytes(rng.randrange(256) for _ in range(rng.randrange(4, 120)))
    return bytes(out)


def run_bytes(c, cmd, timeout=120):
    _, out, _ = c.exec_command(cmd, timeout=timeout)
    return out.read()


def put_bytes(c, path, data):
    sin, sout, serr = c.exec_command("cat > %s" % path, timeout=120)
    sin.write(data)
    sin.flush()
    sin.channel.shutdown_write()
    return sout.channel.recv_exit_status()


def main():
    args = sys.argv[1:]
    rounds = 6
    seed0 = 1
    from_ring = "--from-ring" in args
    keep = "--keep" in args
    for i, a in enumerate(args):
        if a == "--rounds":
            rounds = int(args[i + 1])
        if a == "--seed":
            seed0 = int(args[i + 1])

    c = lgssh.connect()
    try:
        run_bytes(c, "mkdir -p %s; rm -f %s/*" % (TMP, TMP))
        raw = b""
        if from_ring:
            run_bytes(c, "%s --dump-raw /tmp/logc_ring.raw -l 4000 >/dev/null 2>&1" % DEV)
            raw = run_bytes(c, "cat /tmp/logc_ring.raw 2>/dev/null")
            print("ring seed: %d bytes" % len(raw))

        bad = 0
        for r in range(rounds):
            data = corpus(seed0 + r, 1_500_000)
            if raw:
                data = raw + data
            rc = put_bytes(c, "%s/in.bin" % TMP, data)
            if rc != 0:
                print("round %d: upload failed rc=%d" % (r, rc))
                bad += 1
                continue
            out = run_bytes(
                c, "ulimit -c unlimited; %s --stdin --stats-file %s/in.stats "
                   "< %s/in.bin >/dev/null 2>%s/in.err; echo rc=$?; "
                   "tail -1 %s/in.err" % (DEV, TMP, TMP, TMP, TMP), timeout=180)
            txt = out.decode("utf-8", "replace").strip()
            line = "round %d seed=%d bytes=%d %s" % (r, seed0 + r, len(data), txt.replace("\n", " | "))
            if "rc=139" in txt or "rc=134" in txt or "rc=135" in txt or "rc=132" in txt:
                bad += 1
                crash = run_bytes(c, "cat /tmp/logc.crash 2>/dev/null").decode("utf-8", "replace").strip()
                local = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                                     "_local", "archive", "stability_2026-10-20",
                                     "logc_fuzz_%d_%d.bin" % (seed0 + r, int(time.time())))
                with open(local, "wb") as f:
                    f.write(data)
                print(line)
                print("  CRASH breadcrumb: %s" % (crash or "(none)"))
                print("  corpus saved: %s" % os.path.abspath(local))
            else:
                print(line)
        print("\nfuzz: %d round(s), %d crash(es)" % (rounds, bad))
        if not keep:
            run_bytes(c, "rm -f %s/*.bin %s/*.err" % (TMP, TMP))
        return 1 if bad else 0
    finally:
        c.close()


if __name__ == "__main__":
    sys.exit(main())
