#!/usr/bin/env python3
"""ud1_pcap_match.py -- U-D1/E5: match scanary hits to eth0 packets in a pcap.

Usage: python -I ud1_pcap_match.py <victim.log> <capture.pcap> [window_ms]

For every real hit (EV, len, ip) the T0 epoch anchor in the victim log gives
hit_epoch = T0_epoch_us + EV.  The pcap is parsed (Ethernet/IPv4) and for each
hit we report packets with src or dst == hit ip within +/- window_ms, their
lengths and direction.  The record's len is expected to be an skb/GRO-GSO length,
so exact wire-length equality is NOT required; direction and flow are the claim.
"""
import re
import sys
import struct
import bisect

def parse_hits(path):
    t0 = None
    hits = []
    for line in open(path, 'r', errors='replace'):
        m = re.match(r'^EV (\d+) T0 epoch_us=(\d+) ', line)
        if m:
            t0 = int(m.group(2))
        m = re.match(r'^EV (\d+) HIT_APPEAR .*va=(0x[0-9a-f]+) .*len=(\d+) ip=([\d.]+) inj=(\d)', line)
        if m and m.group(5) == '0':
            hits.append(dict(ev=int(m.group(1)), va=m.group(2),
                             len=int(m.group(3)), ip=m.group(4)))
    if t0 is None:
        raise SystemExit('no T0 anchor in %s' % path)
    for h in hits:
        h['epoch'] = (t0 + h['ev']) / 1e6
    return hits

def parse_pcap(path):
    b = open(path, 'rb').read()
    if len(b) < 24:
        raise SystemExit('short pcap')
    magic = b[:4]
    if magic == b'\xd4\xc3\xb2\xa1':
        endian = '<'
    elif magic == b'\xa1\xb2\xc3\xd4':
        endian = '>'
    else:
        raise SystemExit('bad pcap magic %r' % magic)
    linktype = struct.unpack(endian + 'I', b[20:24])[0]
    pkts = []
    off = 24
    while off + 16 <= len(b):
        ts_sec, ts_usec, incl, orig = struct.unpack(endian + 'IIII', b[off:off + 16])
        off += 16
        if off + incl > len(b):
            break
        data = b[off:off + incl]
        off += incl
        if linktype != 1 or len(data) < 34:
            continue
        if data[12:14] != b'\x08\x00':
            continue
        ip = data[14:]
        vihl = ip[0]
        if (vihl >> 4) != 4:
            continue
        ihl = (vihl & 0xf) * 4
        total = struct.unpack('>H', ip[2:4])[0]
        proto = ip[9]
        sa = '.'.join(str(x) for x in ip[12:16])
        da = '.'.join(str(x) for x in ip[16:20])
        sport = dport = 0
        if proto == 6 and len(ip) >= ihl + 4:
            sport, dport = struct.unpack('>HH', ip[ihl:ihl + 4])
        pkts.append(dict(t=ts_sec + ts_usec / 1e6, total=total, sa=sa, da=da,
                         proto=proto, sport=sport, dport=dport))
    pkts.sort(key=lambda p: p['t'])
    return pkts

def main():
    vlog, pcap = sys.argv[1], sys.argv[2]
    win = (float(sys.argv[3]) / 1000.0) if len(sys.argv) > 3 else 0.05
    hits = parse_hits(vlog)
    pkts = parse_pcap(pcap)
    times = [p['t'] for p in pkts]
    print("hits=%d packets=%d window=%.0fms" % (len(hits), len(pkts), win * 1000))
    if not pkts:
        return
    print("pcap span=%.3fs" % (times[-1] - times[0]))
    matched = 0
    for h in hits:
        lo = bisect.bisect_left(times, h['epoch'] - win)
        hi = bisect.bisect_right(times, h['epoch'] + win)
        near = pkts[lo:hi]
        same = [p for p in near if h['ip'] in (p['sa'], p['da'])]
        if same:
            matched += 1
            dirs = []
            for p in same[:6]:
                d = 'TX' if p['sa'] == h['ip'] else 'RX'
                dirs.append('%s %s:%d>%s:%d len=%d dt=%+.3fms' %
                            (d, p['sa'], p['sport'], p['da'], p['dport'], p['total'],
                             (p['t'] - h['epoch']) * 1000))
            print("hit ev=%.3fs len=%d ip=%s pkts=%d | %s" %
                  (h['ev'] / 1e6, h['len'], h['ip'], len(same), ' ; '.join(dirs)))
        else:
            print("hit ev=%.3fs len=%d ip=%s NO_PKT_IN_WINDOW (near=%d)" %
                  (h['ev'] / 1e6, h['len'], h['ip'], len(near)))
    print("matched %d/%d hits with same-ip packet in +/-%.0fms" % (matched, len(hits), win * 1000))

if __name__ == '__main__':
    main()
