#!/usr/bin/env python3
import sys, time, hashlib
sys.path.insert(0, r"D:\Repo\lg6151m")
import serial
s = serial.Serial("COM6", 921600, bytesize=8, parity="N", stopbits=1, timeout=0.2)
def pump(sec):
    end = time.time() + sec
    out = b""
    while time.time() < end:
        d = s.read(4096)
        if d:
            out += d
            sys.stdout.write(d.decode("utf-8", "replace")); sys.stdout.flush()
    return out
def line(text, delay=0.004):
    for ch in text:
        s.write(ch.encode()); s.flush(); time.sleep(delay)
    s.write(b"\n"); s.flush()
b64 = open(sys.argv[1]).read().split()
remote = sys.argv[2]
md5 = hashlib.md5(open(sys.argv[3], "rb").read()).hexdigest()
b64md5 = hashlib.md5(open(sys.argv[1], "rb").read()).hexdigest()
s.write(b"\n"); s.flush(); pump(2)
for attempt in range(3):
    line("rm -f /tmp/push.b64"); pump(1)
    t0 = time.time()
    for i, chunk in enumerate(b64):
        line("echo -n %s >> /tmp/push.b64" % chunk, 0.004)
        if i % 100 == 0:
            pump(0.5)
            print("... %d/%d (%.0fs)" % (i+1, len(b64), time.time()-t0), flush=True)
    pump(4)
    line("md5sum /tmp/push.b64")
    out = pump(8).decode("utf-8", "replace")
    if b64md5 in out:
        print("b64 VERIFIED attempt", attempt+1)
        break
    print("b64 MISMATCH, retry")
line("openssl base64 -d < /tmp/push.b64 | gunzip > %s; chmod +x %s; md5sum %s" % (remote, remote, remote))
out = pump(10).decode("utf-8", "replace")
print("RESULT:", out[-200:])
print("EXPECT:", md5, "->", "MATCH" if md5 in out else "MISMATCH")
s.close()
