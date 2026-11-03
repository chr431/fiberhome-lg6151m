#!/usr/bin/env python3
"""vml_scan.py -- A5/S2: vmlinux.elf (.text) inline-uaccess sweep + rerun of the
"685 user-write call sites" caliber, with function clustering + network ranking.

Part 1  sttr/sttrb/sttrh + ldtr/ldtrb/ldtrh/ldtrsw census (inline __put_user/
        __get_user sites; with CONFIG_ARM64_PAN=y these are the ONLY CPU
        instructions that can store to user VA). Clustered by nearest symtab
        symbol; both raw and in-function counts (data-in-.text false positives
        filtered by the in-function view).
Part 2  exact rerun of _local/work/crash-root/static/usercopy_sites.py logic
        (same PRIM list, same 18-insn backward classifier) to align with the
        published 685/393 numbers; then cluster the non-ARG ("unresolved")
        sites by function and rank network-stack candidates.
Usage: python -I vml_scan.py [vmlinux] > vml_scan.out
"""
import sys, os, re, collections

sys.path.insert(0, '_local/work/crash-root/static')
from kd import Elf
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN

VML = sys.argv[1] if len(sys.argv) > 1 else 'analysis/kern/vmlinux.elf'
e = Elf(VML)

PRIM = ('__arch_copy_to_user', '_copy_to_user', '__copy_to_user', 'copy_to_user_nofault',
        '__copy_to_user_nofault', 'copy_to_iter', '_copy_to_iter', 'copy_page_to_iter',
        'skb_copy_datagram_iter', 'put_cmsg', '__put_user_1', '__put_user_2', '__put_user_4',
        '__put_user_8', 'iov_iter_copy_from_user_atomic', 'copy_to_kernel_nofault')
tgt = {}
for n in PRIM:
    for s in e.find(n, exact=True):
        tgt[s['value']] = s['name']

SEC = [s for s in e.secs if s['name'] == '.text'][0]
code = e.data[SEC['off']:SEC['off'] + SEC['size']]
md = Cs(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN)
md.skipdata = True
print('decoding .text 0x%x bytes...' % len(code))
insns = list(md.disasm(code, SEC['addr']))
print('total insns: %d' % len(insns))

UACC = ('sttr', 'sttrb', 'sttrh', 'ldtr', 'ldtrb', 'ldtrh', 'ldtrsw', 'ldtrsb', 'ldtrsh')
ua = collections.Counter()          # symbol -> count of uaccess insns
ua_raw = collections.Counter()      # mnemonic -> raw count
ua_examples = collections.defaultdict(list)
for ins in insns:
    if ins.mnemonic in UACC:
        ua_raw[ins.mnemonic] += 1
        cur = e.sym_at(ins.address)
        nm = cur['name'] if cur else '<nofunc>'
        ua[nm] += 1
        if len(ua_examples[nm]) < 3:
            ua_examples[nm].append('0x%x: %s %s' % (ins.address, ins.mnemonic, ins.op_str))

print('\n== raw uaccess mnemonic census (whole .text linear decode) ==')
for m2, c in sorted(ua_raw.items(), key=lambda kv: -kv[1]):
    print('  %-8s %d' % (m2, c))
print('  TOTAL sttr* = %d, ldtr* = %d' % (
    sum(v for k, v in ua_raw.items() if k.startswith('sttr')),
    sum(v for k, v in ua_raw.items() if k.startswith('ldtr'))))
print('  distinct functions containing sttr/ldtr: %d' % len(ua))

NETPAT = re.compile(
    r'(sock|skb|netlink|diag|seq_|proc|ip6?_|tcp|udp|raw|ping|icmp|nf_|xt_|conn|inet|fib|route'
    r'|neigh|arp|ethtool|wext|netdev|ioctl|sockopt|recvmsg|sendmsg|msfilter|mcast|igmp|packet'
    r'|tap|ppp|br_|vlan|dev_|wireless|cfg80211|nl80211|flow|hash|lookup|dump|get_|read|stats)', re.I)

def classify_dst(idx):
    for j in range(idx - 1, max(-1, idx - 19), -1):
        ins = insns[j]; m = ins.mnemonic; o = ins.op_str
        if m in ('ldr', 'ldur', 'ldrsw', 'ldrb', 'ldrh'):
            mm = re.match(r'x0, \[(x\d+)(?:, #(0x[0-9a-f]+|\d+))?\]', o)
            if mm: return 'FIELD', '%s [%s%s]' % (m, mm.group(1), ('' if not mm.group(2) else ', #' + mm.group(2)))
            if o.startswith('x0, [sp'): return 'PTR', '%s %s' % (m, o)
        if m in ('mov', 'movz', 'movk') and o.startswith('x0, x'):
            k = o.split(',')[1].strip()
            return ('ARG' if k in ('x1', 'x2', 'x3', 'x4', 'x5', 'x6', 'x7') else 'PTR'), '%s %s' % (m, o)
        if m == 'ldp' and o.startswith('x0,'):
            return 'FIELD', 'ldp ' + o
        if m in ('add', 'sub', 'orr') and o.startswith('x0, '):
            return 'PTR', '%s %s' % (m, o)
        if m == 'bl':
            return 'CALL', 'bl -> ' + (e.label(int(o[1:], 16)) or '?') if o.startswith('#') else 'bl'
    return '?', ''

def classify_len(idx):
    for j in range(idx - 1, max(-1, idx - 19), -1):
        ins = insns[j]; m = ins.mnemonic; o = ins.op_str
        if m in ('mov', 'movz') and o.startswith(('x2,', 'w2,')):
            mm = re.search(r'#(0x[0-9a-f]+|\d+)', o)
            if mm: return 'IMM', int(mm.group(1), 0)
            return 'REG', None
        if m in ('ldr', 'ldur', 'ldrh') and o.startswith(('x2,', 'w2,')):
            return 'REG', None
    return '?', None

hits = []
for idx, ins in enumerate(insns):
    if ins.mnemonic != 'bl' or not ins.op_str.startswith('#'):
        continue
    try:
        t = int(ins.op_str[1:], 16)
    except Exception:
        continue
    if t not in tgt:
        continue
    d, dd = classify_dst(idx); L, ln = classify_len(idx)
    cur = e.sym_at(ins.address)
    hits.append(dict(fn=cur['name'] if cur else '?', at=ins.address, prim=tgt[t],
                     dst=d, ddesc=dd, lk=L, lv=ln))

print('\n== part 2: 685-caliber rerun ==')
print('total user-write call sites: %d' % len(hits))
cnt = collections.Counter(h['dst'] for h in hits)
print('dst-class distribution:', dict(cnt))
unres = [h for h in hits if h['dst'] not in ('ARG',)]
print('unresolved (non-ARG) sites: %d' % len(unres))

fncnt = collections.Counter(h['fn'] for h in unres)
print('distinct functions in unresolved set: %d' % len(fncnt))
net = [(f, c) for f, c in fncnt.most_common() if NETPAT.search(f)]
print('network-ish functions in unresolved set: %d' % len(net))

print('\n== network-ranked unresolved functions (bl-site caliber) ==')
rank = []
for f, c in net:
    reglens = sum(1 for h in unres if h['fn'] == f and h['lk'] == 'REG')
    bigimm = sum(1 for h in unres if h['fn'] == f and h['lk'] == 'IMM' and h['lv'] and h['lv'] >= 32)
    sttr_n = ua.get(f, 0)
    rank.append((c + 2 * reglens + bigimm + 2 * sttr_n, f, c, reglens, bigimm, sttr_n))
rank.sort(reverse=True)
for sc, f, c, rl, bi, st in rank[:45]:
    print('  %-3d %-40s blsites=%d reglen=%d imm>=32=%d sttr=%d' % (sc, f[:40], c, rl, bi, st))

print('\n== top functions by sttr/ldtr count (inline uaccess) ==')
for f, c in ua.most_common(45):
    tag = 'NET' if NETPAT.search(f) else '   '
    print('  %s %-44s %d   e.g. %s' % (tag, f[:44], c, ua_examples[f][0] if ua_examples[f] else ''))
print('\n== sttr-containing functions that are network-ish AND appear in unresolved bl set ==')
unresfns = set(fncnt)
for f, c in ua.most_common():
    if NETPAT.search(f) and f in unresfns:
        print('  %-44s sttr/ldtr=%d blsites=%d' % (f[:44], c, fncnt[f]))
