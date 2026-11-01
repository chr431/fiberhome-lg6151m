#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""svc_probe.py v1.0 -- client-side service-outage probe (M3 / R3.1-R3.3 acceptance basis).

WHY: the on-device measurement (avail_watch 2s edges + fast_facts 1s) only sees
"a fact flipped". The acceptance contract (RELIABILITY_SPEC M3) is written from
the CLIENT's point of view: a client attached over WiFi/ethernet/RNDIS lost the
service for N seconds. Only a client-side probe can see that, and only a
client-side probe can catch the class of failure where the device is healthy by
its own metrics but unreachable/wedged for the client.

WHAT: every tick (default 1s) each configured path is probed with up to four
probes -- ICMP echo to the gateway, a DNS query to the gateway, a TCP connect to
:80 (GUI) and a TCP connect to :22 (SSH). Results are appended to a TSV; outages
are derived by the debounce rule in docs/SVC_MEASUREMENT.md (>=2 consecutive
failures; duration = first failure -> first success).

HONESTY RULES (enforced, not decorative):
  * a measurement gap is recorded as a gap, never as "no outage";
  * the probe self-checks for local proxy/TUN pollution before it trusts itself
    and aborts if its own traffic would leave through a tunnel (AGENTS trap:
    Mihomo/Clash TUN silently swallows or rewrites LAN traffic);
  * every sample records the source address it was sent from, so a later
    auditor can prove which interface the observation belongs to.

Usage:
  python tools/svc_probe.py selftest                 # proxy/path self-check (JSON)
  python tools/svc_probe.py run [--duration SEC]     # sample (default: forever)
  python tools/svc_probe.py derive                   # rebuild outages.tsv from samples
  python tools/svc_probe.py report --days 7 [--json] # acceptance counts + verdict
  python tools/svc_probe.py status

Evidence (NOT in the public repo, per D1):
  <evidence-dir>/samples-YYYYMMDD.tsv   raw samples, one row per (path,tick)
  <evidence-dir>/outages.tsv            derived episodes (append-only)
  <evidence-dir>/run.tsv                run start/stop + coverage gaps
  <evidence-dir>/anchors.tsv            clock anchors (local vs device epoch)
  <evidence-dir>/device/                cached device-side evidence for attribution
Default evidence dir: <repo>/../_local/evidence/svc_probe  (override: --evidence-dir
or the LG_SVC_EVIDENCE environment variable).
"""
import argparse
import json
import os
import re
import socket
import struct
import subprocess
import sys
import threading
import time

try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

VERSION = "1.7"
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_EVIDENCE = os.path.abspath(os.path.join(
    REPO, "..", "_local", "evidence", "svc_probe"))

# ---- probe cadence (per probe, seconds). See SVC_MEASUREMENT.md section 2. ----
# icmp/dns/tcp80 run every tick (1s): they are the client's actual service path.
# tcp22 runs every TCP22_EVERY seconds: a 1s SSH connect would fork a dropbear
# child AND write two authpriv syslog lines per second on a device whose syslog
# budget is 4MB (~2 days) -- i.e. the probe would become the outage it measures.
# The reduced cadence is declared, not hidden: min detectable duration for a
# probe = 2 x its cadence.
TCP22_EVERY = 60

GATEWAY = "192.168.9.1"
LAN_NET = "192.168.9."
PROXY_NET = "198.18."          # Clash/Mihomo fake-ip range
DNS_QNAME = "lg6151m"          # answered locally by dnsmasq (NXDOMAIN is a valid answer)

SAMPLE_HEADER = ("#svc_probe samples v" + VERSION +
                 " | fields: epoch_ms path src icmp_ok icmp_ms dns_ok dns_ms "
                 "tcp80_ok tcp80_ms tcp22_ok tcp22_ms note")
OUTAGE_HEADER = ("#svc_probe outages v" + VERSION +
                 " | fields: start end dur_s path probe severity attrib excluded "
                 "excl_reason evidence side")


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
def now_ms():
    return int(time.time() * 1000)


def iso(epoch_s):
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(epoch_s))


def day_str(epoch_s=None):
    return time.strftime("%Y%m%d", time.localtime(epoch_s if epoch_s else time.time()))


def _p(msg):
    print(msg, flush=True)


# --------------------------------------------------------------------------
# probes
# --------------------------------------------------------------------------
def _checksum(data):
    if len(data) % 2:
        data += b"\x00"
    s = 0
    for i in range(0, len(data), 2):
        s += (data[i] << 8) + data[i + 1]
    while s >> 16:
        s = (s & 0xFFFF) + (s >> 16)
    return (~s) & 0xFFFF


class IcmpProbe(object):
    """ICMP echo to the gateway over a raw socket bound to one source address.

    Raw ICMP is available to non-elevated users on Windows (verified on this
    host: socket(AF_INET, SOCK_RAW, IPPROTO_ICMP) succeeds without admin), so
    the 1s tick costs no subprocess.
    """

    def __init__(self, dst, src):
        self.dst = dst
        self.src = src
        self.ident = (os.getpid() ^ (hash(src) & 0xFFFF)) & 0xFFFF
        self.seq = 0
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
        if src:
            try:
                self.sock.bind((src, 0))
            except OSError:
                pass
        self.sock.settimeout(0.9)

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass

    def probe(self, timeout=0.9):
        """returns (ok:int 0/1, latency_ms:int, err:str)"""
        self.seq = (self.seq + 1) & 0xFFFF
        seq = self.seq
        payload = struct.pack("!d", time.time()) + b"svcprobe".ljust(16, b".")
        hdr = struct.pack("!BBHHH", 8, 0, 0, self.ident, seq)
        chk = _checksum(hdr + payload)
        pkt = struct.pack("!BBHHH", 8, 0, chk, self.ident, seq) + payload
        t0 = time.perf_counter()
        try:
            self.sock.sendto(pkt, (self.dst, 0))
        except OSError as e:
            return 0, -1, "send:%s" % e
        deadline = t0 + timeout
        while True:
            left = deadline - time.perf_counter()
            if left <= 0:
                return 0, -1, "timeout"
            try:
                self.sock.settimeout(left)
                data, addr = self.sock.recvfrom(2048)
            except socket.timeout:
                return 0, -1, "timeout"
            except OSError as e:
                return 0, -1, "recv:%s" % e
            if addr[0] != self.dst:
                continue
            if len(data) < 20:
                continue
            ihl = (data[0] & 0x0F) * 4
            icmp = data[ihl:]
            if len(icmp) < 8:
                continue
            typ = icmp[0]
            if typ == 0:                       # echo reply
                r_id, r_seq = struct.unpack("!HH", icmp[4:8])
                if r_id == self.ident and r_seq == seq:
                    return 1, int((time.perf_counter() - t0) * 1000), ""
            elif typ == 3:                     # dest unreachable -> path broken
                return 0, -1, "unreachable"


def _dns_packet(qname, qid):
    q = struct.pack("!HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    for label in qname.split("."):
        q += bytes([len(label)]) + label.encode("ascii")
    q += b"\x00" + struct.pack("!HH", 1, 1)     # A, IN
    return q


def dns_probe(src, dst, timeout=0.9, qname=DNS_QNAME):
    """Ask the gateway resolver. ANY DNS response (even NXDOMAIN/SERVFAIL)
    proves dnsmasq answered; a timeout proves it did not. This deliberately
    measures the resolver's liveness, not upstream reachability."""
    qid = (os.getpid() + int(time.time() * 1000)) & 0xFFFF
    pkt = _dns_packet(qname, qid)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    t0 = time.perf_counter()
    try:
        if src:
            s.bind((src, 0))
        s.settimeout(timeout)
        s.sendto(pkt, (dst, 53))
        data, addr = s.recvfrom(2048)
        if addr[0] != dst or len(data) < 12:
            return 0, -1, "baddata"
        if struct.unpack("!H", data[0:2])[0] != qid:
            return 0, -1, "qid"
        return 1, int((time.perf_counter() - t0) * 1000), ""
    except socket.timeout:
        return 0, -1, "timeout"
    except OSError as e:
        return 0, -1, "err:%s" % (e.errno or e)
    finally:
        s.close()


def tcp_probe(src, dst, port, timeout=0.9, banner=False):
    """Bare TCP connect (the SPEC's "TCP:80/TCP:22" probe). With banner=True the
    first bytes are read too (SSH identification string) so a listener that
    accepts but never speaks does not count as alive."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    t0 = time.perf_counter()
    try:
        if src:
            s.bind((src, 0))
        s.settimeout(timeout)
        s.connect((dst, port))
        if banner:
            s.settimeout(max(0.05, timeout - (time.perf_counter() - t0)))
            d = s.recv(64)
            if not d:
                return 0, -1, "nobanner"
            return 1, int((time.perf_counter() - t0) * 1000), ""
        return 1, int((time.perf_counter() - t0) * 1000), ""
    except socket.timeout:
        return 0, -1, "timeout"
    except ConnectionRefusedError:
        return 0, -1, "refused"
    except OSError as e:
        return 0, -1, "err:%s" % (e.errno or e)
    finally:
        s.close()


# --------------------------------------------------------------------------
# path discovery + proxy self-check
# --------------------------------------------------------------------------
def local_ipv4s():
    addrs = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addrs.add(info[4][0])
    except Exception:
        pass
    return sorted(addrs)


def source_for(dst):
    """The source address the OS would use for dst (proves the route taken)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect((dst, 80))
        return s.getsockname()[0]
    except OSError:
        return None
    finally:
        s.close()


def route_check(dst):
    """Route check without parsing a localised route table: connect a UDP
    socket (no packet is sent) and read the source address the OS picked."""
    src = source_for(dst)
    return {"dst": dst, "src": src,
            "on_lan": bool(src and src.startswith(LAN_NET)),
            "via_proxy_tun": bool(src and src.startswith(PROXY_NET))}


def selftest():
    """Prove the observation point is not polluted before trusting any number."""
    res = {"ts": now_ms(), "version": VERSION, "checks": [], "ok": True}

    def add(name, ok, detail):
        res["checks"].append({"check": name, "ok": bool(ok), "detail": detail})
        if not ok:
            res["ok"] = False

    addrs = local_ipv4s()
    lan_addrs = [a for a in addrs if a.startswith(LAN_NET)]
    proxy_addrs = [a for a in addrs if a.startswith(PROXY_NET)]
    add("local_addresses", True, {"all": addrs, "lan": lan_addrs, "proxy": proxy_addrs})
    add("lan_address_present", bool(lan_addrs),
        "no local address in " + LAN_NET + "0/24 -- client is not attached to the device LAN")

    rc = route_check(GATEWAY)
    add("route_to_gateway_on_link", rc["on_lan"],
        "source chosen for %s is %s (must be a %s address, not a tunnel)" % (GATEWAY, rc["src"], LAN_NET))
    add("no_tunnel_source", not rc["via_proxy_tun"],
        "source %s is in the Mihomo/Clash fake-ip range %s0/16: observations would be polluted"
        % (rc["src"], PROXY_NET))

    # fake-ip DNS: a foreign name resolving into 198.18/16 means a local proxy
    # resolver is in the path. It must not affect direct-to-gateway probes (we
    # bind the LAN source), but it has to be recorded in the evidence header.
    fake = []
    try:
        for info in socket.getaddrinfo("example.com", None, socket.AF_INET):
            if info[4][0].startswith(PROXY_NET):
                fake.append(info[4][0])
    except Exception as e:
        fake.append("resolve-error:%s" % e)
    res["proxy_dns_fakeip"] = fake
    res["note_proxy_dns"] = ("local resolver returns fake-ip (%s); direct gateway probes "
                             "are source-bound and unaffected, recorded for audit" % fake) if fake else ""

    # one real round-trip per probe, to prove each probe can succeed at all
    src = rc["src"]
    if src:
        icmp = IcmpProbe(GATEWAY, src)
        try:
            ok, ms, err = icmp.probe(1.0)
            add("icmp_probe_works", ok == 1, {"ok": ok, "ms": ms, "err": err})
        finally:
            icmp.close()
        ok, ms, err = dns_probe(src, GATEWAY, 1.0)
        add("dns_probe_works", ok == 1, {"ok": ok, "ms": ms, "err": err})
        ok, ms, err = tcp_probe(src, GATEWAY, 80, 1.0)
        add("tcp80_probe_works", ok == 1, {"ok": ok, "ms": ms, "err": err})
        ok, ms, err = tcp_probe(src, GATEWAY, 22, 1.0, banner=True)
        add("tcp22_probe_works", ok == 1, {"ok": ok, "ms": ms, "err": err})
    else:
        add("gateway_source", False, "no source address for " + GATEWAY)
    return res


def discover_paths(explicit=None):
    """A 'path' is one attachment to the device: (name, src address, dst)."""
    paths = []
    lan = [a for a in local_ipv4s() if a.startswith(LAN_NET)]
    if explicit:
        wanted = [x.strip() for x in explicit.split(",") if x.strip()]
        lan = [a for a in lan if a in wanted] or lan
    for i, a in enumerate(sorted(lan)):
        paths.append({"name": "eth" if i == 0 else "lan%d" % (i + 1),
                      "src": a, "dst": GATEWAY})
    return paths


# --------------------------------------------------------------------------
# sampling
# --------------------------------------------------------------------------
class Sampler(object):
    def __init__(self, paths, evidence_dir, interval=1.0, tcp22_every=TCP22_EVERY):
        self.paths = paths
        self.dir = evidence_dir
        self.interval = interval
        self.tcp22_every = tcp22_every
        self.stop = threading.Event()
        self.icmp = {}
        self._icmp_err = {}
        self._fh = None
        self._fday = None
        self.n = 0

    def _open_day(self, d):
        if self._fday == d and self._fh:
            return
        if self._fh:
            try:
                self._fh.close()
            except Exception:
                pass
        os.makedirs(self.dir, exist_ok=True)
        p = os.path.join(self.dir, "samples-%s.tsv" % d)
        new = not os.path.exists(p)
        self._fh = open(p, "a", encoding="utf-8", buffering=1)
        if new:
            self._fh.write(SAMPLE_HEADER + "\n")
        self._fday = d

    def _emit(self, row):
        self._open_day(day_str())
        self._fh.write(row + "\n")

    def sample_once(self):
        ts = now_ms()
        tick = self.n
        self.n += 1
        rows = []
        for p in self.paths:
            src = p["src"]
            key = (src, p["dst"])
            if key not in self.icmp:
                try:
                    self.icmp[key] = IcmpProbe(p["dst"], src)
                except OSError as e:
                    self.icmp[key] = None
                    _p("warn: raw icmp unavailable (%s); icmp probe disabled for %s" % (e, src))
            ip = self.icmp.get(key)
            # 实弹(2026-11-01 03:0x): 设备崩溃重启后本机 DHCP 租约丢失,
            # raw socket 连续失败被回收成 None 后就**再也没被重建**(1635 拍无 icmp)。
            # 现在: 处于 None 时每 10 拍重试一次建 socket, 保证长时间运行不会静默降级。
            if ip is None and (tick % 10) == 0:
                try:
                    self.icmp[key] = IcmpProbe(p["dst"], src)
                    ip = self.icmp[key]
                except OSError as e:
                    _p("warn: raw icmp recreate failed (%s); retry in 10 ticks" % e)
            if ip:
                i_ok, i_ms, i_err = ip.probe(0.9)
                # a raw socket can go stale when the interface is re-plumbed
                # (cable pull, DHCP renew). Recreate it after repeated hard
                # errors so a long run cannot silently degrade to all-fail.
                if i_ok == 0 and (i_err.startswith("recv:") or i_err.startswith("send:")):
                    self._icmp_err[key] = self._icmp_err.get(key, 0) + 1
                    if self._icmp_err[key] >= 5:
                        ip.close()
                        self.icmp[key] = None
                        self._icmp_err[key] = 0
                else:
                    self._icmp_err[key] = 0
            else:
                i_ok, i_ms, i_err = -1, -1, "no_raw_socket"
            d_ok, d_ms, d_err = dns_probe(src, p["dst"], 0.9)
            t_ok, t_ms, t_err = tcp_probe(src, p["dst"], 80, 0.9)
            if self.tcp22_every and (tick % self.tcp22_every) == 0:
                s_ok, s_ms, s_err = tcp_probe(src, p["dst"], 22, 0.9, banner=True)
            else:
                s_ok, s_ms, s_err = -1, -1, "not_sampled"
            note = ",".join("%s=%s" % (k, v) for k, v in
                            (("icmp", i_err), ("dns", d_err), ("tcp80", t_err),
                             ("tcp22", s_err)) if v)
            rows.append("%d\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%s" % (
                ts, p["name"], src, i_ok, i_ms, d_ok, d_ms,
                t_ok, t_ms, s_ok, s_ms, note))
        for r in rows:
            self._emit(r)
        return rows

    def run(self, duration=0):
        os.makedirs(self.dir, exist_ok=True)
        self._log_run("start", "interval=%.2f tcp22_every=%d paths=%s" % (
            self.interval, self.tcp22_every,
            ",".join("%s/%s" % (p["name"], p["src"]) for p in self.paths)))
        t_end = time.time() + duration if duration else 0
        next_t = time.time()
        try:
            while not self.stop.is_set():
                self.sample_once()
                next_t += self.interval
                slack = next_t - time.time()
                if slack > 0:
                    time.sleep(slack)
                elif slack < -2.0:
                    # we fell behind by more than one full tick: record the gap
                    # instead of silently pretending the interval was continuous
                    self._log_run("gap", "behind=%.2fs at %s" % (-slack, iso(time.time())))
                    next_t = time.time()
                if t_end and time.time() >= t_end:
                    break
        except KeyboardInterrupt:
            pass
        finally:
            self._log_run("stop", "ticks=%d" % self.n)

    def _log_run(self, kind, detail):
        os.makedirs(self.dir, exist_ok=True)
        p = os.path.join(self.dir, "run.tsv")
        new = not os.path.exists(p)
        with open(p, "a", encoding="utf-8") as f:
            if new:
                f.write("#svc_probe run log v%s | fields: epoch_ms kind detail\n" % VERSION)
            f.write("%d\t%s\t%s\n" % (now_ms(), kind, detail))


# --------------------------------------------------------------------------
# clock anchors (device epoch vs local epoch; never do epoch math by hand)
# --------------------------------------------------------------------------
def anchor_once(evidence_dir):
    """Record (t_before, t_after, device_epoch) so a later auditor can compute
    the offset between the two clocks instead of guessing it."""
    lgssh = os.path.join(REPO, "tools", "lgssh.py")
    t0 = now_ms()
    dev = None
    try:
        out = subprocess.run([sys.executable, lgssh, "date +%s"],
                             cwd=REPO, capture_output=True, text=True, timeout=60)
        t1 = now_ms()
        m = re.search(r"\b(1[6-9]\d{8})\b", out.stdout or "")
        dev = int(m.group(1)) if m else None
    except Exception:
        t1 = now_ms()
    p = os.path.join(evidence_dir, "anchors.tsv")
    os.makedirs(evidence_dir, exist_ok=True)
    new = not os.path.exists(p)
    with open(p, "a", encoding="utf-8") as f:
        if new:
            f.write("#svc_probe clock anchors v%s | fields: local_before_ms local_after_ms "
                    "local_mid_ms device_epoch offset_s rtt_ms\n" % VERSION)
        mid = (t0 + t1) // 2
        off = (dev - mid / 1000.0) if dev else float("nan")
        f.write("%d\t%d\t%d\t%s\t%.3f\t%d\n" % (t0, t1, mid, dev if dev else "", off, t1 - t0))
    return {"device_epoch": dev, "rtt_ms": t1 - t0}


# --------------------------------------------------------------------------
# derive outages from samples
# --------------------------------------------------------------------------
DRILL_MAX_OPEN_S = 1800   # 未回填演练行的最大生效时长（见 attribute()）
# 演练作用域：只门控 WiFi TX / hostapd 的演练**不会**影响以太 LAN 路径的客户端观测。
# 不做这个区分，一条 1 小时、target=warp1 的硬件演练就会把同窗口内真实的 GUI/DNS
# 中断全部"排除"掉 —— 那不是审计，是把证据藏起来。（实弹：crash-root 的
# hw-drill warp1 00:12–01:13 窗口吞掉了 state-truth 的四条真实服务中断。）
_DRILL_WIFI_ONLY = ("warp", "wifi", "ra0", "rai0", "beacon", "hostapd")

PROBES = ("icmp", "dns", "tcp80", "tcp22")
PROBE_COL = {"icmp": (3, 4), "dns": (5, 6), "tcp80": (7, 8), "tcp22": (9, 10)}


def read_samples(evidence_dir, days=None):
    """yield dict rows; skips headers; tolerant to partial lines."""
    if not os.path.isdir(evidence_dir):
        return
    files = sorted(f for f in os.listdir(evidence_dir)
                   if f.startswith("samples-") and f.endswith(".tsv"))
    if days:
        cutoff = time.time() - days * 86400
        keep = []
        for f in files:
            m = re.search(r"samples-(\d{8})\.tsv", f)
            if not m:
                continue
            try:
                d = time.mktime(time.strptime(m.group(1), "%Y%m%d"))
            except ValueError:
                continue
            if d >= cutoff - 86400:
                keep.append(f)
        files = keep
    for f in files:
        p = os.path.join(evidence_dir, f)
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if not line or line.startswith("#"):
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 11:
                    continue
                try:
                    row = {"ms": int(parts[0]), "path": parts[1], "src": parts[2]}
                    for pr in PROBES:
                        ci, cm = PROBE_COL[pr]
                        row[pr] = int(parts[ci])
                        row[pr + "_ms"] = int(parts[cm])
                    row["note"] = parts[11] if len(parts) > 11 else ""
                except (ValueError, IndexError):
                    continue
                yield row


def derive_episodes(samples, merge_gap_s=2.0):
    """samples: rows of ONE path. Returns (per-probe episodes, merged incidents).
    Debounce = 2 consecutive failures (R3.1); duration = first fail -> first ok."""
    per = {pr: [] for pr in PROBES}
    for pr in PROBES:
        fails = 0
        start = None
        for r in samples:
            v = r.get(pr, -1)
            if v < 0:
                continue
            if v == 0:
                if start is None:
                    start = r["ms"]
                fails += 1
            else:
                if start is not None and fails >= 2:
                    per[pr].append({"start": start, "end": r["ms"],
                                    "dur_s": round((r["ms"] - start) / 1000.0, 3)})
                start = None
                fails = 0
        if start is not None and fails >= 2:
            per[pr].append({"start": start, "end": None,
                            "dur_s": round((now_ms() - start) / 1000.0, 3), "open": True})
    items = []
    for pr in PROBES:
        for e in per[pr]:
            items.append({"start": e["start"], "end": e["end"], "probes": [pr],
                          "dur_s": e["dur_s"], "open": e.get("open", False)})
    items.sort(key=lambda x: x["start"])
    merged = []
    for it in items:
        if merged:
            last = merged[-1]
            if it["start"] <= (last["end"] or it["start"]) + merge_gap_s * 1000:
                last["probes"] = sorted(set(last["probes"]) | set(it["probes"]))
                last["end"] = max(last["end"] or 0, it["end"] or 0) or None
                last["open"] = last["open"] or it["open"]
                if last["end"]:
                    last["dur_s"] = round((last["end"] - last["start"]) / 1000.0, 3)
                continue
        merged.append(dict(it))
    return per, merged


def severity_of(dur_s):
    if dur_s is None:
        return "SEV1"          # still open: at least as bad as >20s eventually
    if dur_s > 20:
        return "SEV1"
    if dur_s >= 5:
        return "SEV2"
    return "SEV3"


def tier_of(dur_s):
    if dur_s is None:
        return "gt20"
    if dur_s > 20:
        return "gt20"
    if dur_s >= 5:
        return "5to20"
    return "lt5"


# --------------------------------------------------------------------------
# device-side evidence (exclusion + attribution only; acceptance = client side)
# --------------------------------------------------------------------------
def device_pull(evidence_dir, quiet=True):
    """Cache device evidence used for exclusion/attribution. Read-only: no
    device lock is needed because nothing on the device is written."""
    lgssh = os.path.join(REPO, "tools", "lgssh.py")
    ddir = os.path.join(evidence_dir, "device")
    os.makedirs(ddir, exist_ok=True)
    files = {
        "reboots.tsv": "/data/gw/logs/reboots.log",
        "boot_attempts.tsv": "/data/gw/boot_attempts.tsv",   # rc.extend 写在 /data/gw（不是 logs/）
        "avail_edges.tsv": "/data/gw/logs/avail_edges.tsv",
        "ne_events_tail.tsv": "/data/gw/logs/ne_events.tsv",
        "svc_outages.tsv": "/data/gw/logs/svc_outages.tsv",
        "fast_facts_tail.tsv": "/data/gw/logs/fast_facts.tsv",
        "avail_transitions.tsv": "/data/gw/logs/avail_transitions.tsv",
        "drills.tsv": "/data/gw/logs/drills.tsv",
    }
    def ssh(cmd, timeout=120):
        try:
            out = subprocess.run([sys.executable, lgssh, cmd], cwd=REPO,
                                 capture_output=True, text=True, timeout=timeout)
            return out.stdout or ""
        except Exception as e:
            if not quiet:
                _p("warn: ssh failed: %s" % e)
            return ""

    def pull_tail(remote, max_lines=4000, chunk=400):
        """分块拉取尾部 N 行。

        实弹(2026-11-01 09:3x): 单次 tail -n 4000 只回来 8 行 —— dropbear 通道对
        一次性大块输出会截断(设备侧 tail|wc -l 明明是 1611)。改成按 400 行窗口用
        sed 分页拉, 每页独立短输出, 稳定且可诊断。**这直接决定 NE 关联的样本量**,
        少拉一次就会得出 NE 总数 0 的假结论。
        """
        try:
            n = int((ssh("wc -l < %s 2>/dev/null" % remote, timeout=60) or "0").strip())
        except ValueError:
            n = 0
        if n <= 0:
            return ""
        start = max(1, n - max_lines + 1)
        parts = []
        a = start
        while a <= n:
            b = min(a + chunk - 1, n)
            parts.append(ssh("sed -n '%d,%dp' %s 2>/dev/null" % (a, b, remote)))
            a = b + 1
        return "".join(parts)

    got = {}
    for name, remote in files.items():
        txt = pull_tail(remote)
        with open(os.path.join(ddir, name), "w", encoding="utf-8") as f:
            f.write(txt)
        got[name] = len(txt.splitlines())
    return got


def load_device_evidence(evidence_dir):
    ddir = os.path.join(evidence_dir, "device")
    ev = {"reboots": [], "boots": [], "ne": [], "edges": [], "dev_outages": [],
          "drills": [], "wan_alive": []}

    def lines(name):
        p = os.path.join(ddir, name)
        if not os.path.exists(p):
            return []
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            return [l.rstrip("\n") for l in f if l.strip()]

    # reboots.log: "2026-10-31 04:00:16 REBOOT target=04:00 late=0min uptime=2943s"
    for l in lines("reboots.tsv"):
        m = re.match(r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\s+REBOOT", l)
        if m:
            try:
                ts = int(time.mktime(time.strptime(m.group(1), "%Y-%m-%d %H:%M:%S")))
            except ValueError:
                continue
            ev["reboots"].append({"ts": ts, "line": l})
    # boot_attempts: "btime=... epoch=... result=healthy fast=0 boot_id=..."
    for l in lines("boot_attempts.tsv"):
        m = re.search(r"epoch=(\d{10})", l)
        if m:
            ev["boots"].append({"ts": int(m.group(1)), "line": l})
    # ne_events: "epoch pid comm sig=11 exe=... args=..."
    for l in lines("ne_events_tail.tsv"):
        p = l.split("\t")
        if len(p) >= 4 and p[0].isdigit():
            ev["ne"].append({"ts": int(p[0]), "pid": p[1], "comm": p[2], "sig": p[3],
                             "exe": p[4] if len(p) > 4 else "",
                             "args": p[5] if len(p) > 5 else ""})
    # avail_edges: "epoch <date> <time> id edge_down|edge_up detail"
    # The timestamp is written as "$(date +%s) $(date '+%F %T')", i.e. it spans
    # three whitespace fields, and one historical line has a malformed date
    # field. Locate the event token and take the token before it as the id, so
    # both layouts parse the same way.
    for l in lines("avail_edges.tsv"):
        p = l.split()
        if not p or not p[0].isdigit():
            continue
        for i, tok in enumerate(p):
            if tok in ("edge_down", "edge_up") and i >= 1:
                ev["edges"].append({"ts": int(p[0]), "id": p[i - 1], "ev": tok})
                break
    # drills.tsv (Lead contract v1.2): start_epoch end_epoch kind target owner note
    # Written by the fault-injection campaign owner only. Any client-visible
    # outage overlapping a drill window is induced, not a firmware defect, so it
    # is excluded from acceptance -- and listed, so the exclusion stays auditable.
    for l in lines("drills.tsv"):
        if l.startswith("#"):
            continue
        p = l.split("\t")
        if len(p) >= 3 and p[0].isdigit():
            try:
                st = int(p[0])
                en = int(p[1]) if p[1].isdigit() else 0
            except ValueError:
                continue
            ev["drills"].append({"start": st, "end": en, "kind": p[2],
                                 "target": p[3] if len(p) > 3 else "",
                                 "owner": p[4] if len(p) > 4 else "",
                                 "note": p[5] if len(p) > 5 else ""})
    # fast_facts wan.alive rows (upstream state, for the R3.4 upstream exclusion):
    # "epoch_ms<TAB>wan.alive<TAB>ok<TAB>lat<TAB>home=1,cell=0,age=3"
    for l in lines("fast_facts_tail.tsv"):
        p = l.split("\t")
        if len(p) >= 5 and p[1] == "wan.alive" and p[0].isdigit():
            ev["wan_alive"].append((int(p[0]),
                                    ("home=1" in p[4]) or ("cell=1" in p[4])))
    # device-side outage ledger (present once fast_facts lands)
    for l in lines("svc_outages.tsv"):
        if l.startswith("#"):
            continue
        p = l.split("\t")
        if len(p) >= 8 and p[0].isdigit():
            ev["dev_outages"].append({"start": int(p[0]), "end": p[1], "dur": p[2],
                                      "path": p[3], "probe": p[4], "sev": p[5],
                                      "attrib": p[6], "excluded": p[7]})
    return ev


EDGE_FOR_PROBE = {
    "tcp80": [("gui.serve", "sys.gui/v3httpd"), ("gui", "sys.gui/v3httpd")],
    "tcp22": [("ssh.banner", "sys.ssh/dropbear")],
    "dns": [("dns.pids", "lan.bridge/dnsmasq")],
    "icmp": [("br.up", "lan.bridge/br-lan"), ("eth.carrier", "wan.ethernet")],
}
NE_FOR_PROBE = {
    "tcp80": ["v3httpd"],
    "tcp22": ["dropbear"],
    "dns": ["dnsmasq"],
    "icmp": [],
}


def attribute(inc, ev):
    """Return (attrib, evidence_ref, excluded, excl_reason). Attribution must be
    evidence-backed; 'unknown' is a first-class answer (R3.5)."""
    t0 = inc["start"] / 1000.0
    t1 = (inc["end"] / 1000.0) if inc["end"] else time.time()
    # 0) drill window (Lead contract v1.2): induced outage, excluded from
    #    acceptance but kept in the ledger. An unfinished drill (end_epoch=0)
    #    is treated as still open so a forgotten close cannot leak fake outages
    #    into the acceptance count.
    for d in ev.get("drills", []):
        _t = (d.get("target") or "").lower()
        if any(k in _t for k in _DRILL_WIFI_ONLY) and inc.get("path") not in ("wifi", "rndis"):
            continue          # WiFi 域演练不影响以太/RNDIS 路径的观测
        # end_epoch=0 表示"注入进行中"。但一行忘记回填的演练如果被当成无限期，
        # 会把之后所有真实中断都排掉 —— 那是另一种自欺。因此给未回填行设上界
        # DRILL_MAX_OPEN_S（默认 30min），超界按 start+上界关闭，并在报告里列为
        # stale_open 告警（可审计），而不是静默放大排除范围。
        dend = d["end"] if d["end"] else min(now_ms() // 1000,
                                             d["start"] + DRILL_MAX_OPEN_S)
        if t0 <= dend + 30 and t1 >= d["start"] - 30:
            # 排除理由要如实反映"为什么不算"：维护性重启(Lead 裁决 v1.3)记
            # maintenance，故障注入/演练记 drill。两者都不进验收三档，但审计时
            # 必须能区分"我们自己重启设备"和"我们杀服务做演练"。
            _k = (d.get("kind") or "").lower()
            _why = "maintenance" if "maintenance" in _k else "drill"
            return ("%s/%s" % (_why, d["target"] or d["kind"]),
                    "drills.tsv:%d-%d" % (d["start"], d["end"]), 1, _why)
    # 1) planned reboot window (reboots.log entry -2min .. +4min)
    for rb in ev["reboots"]:
        if rb["ts"] - 120 <= t0 <= rb["ts"] + 240:
            return "reboot", "reboots.log:" + rb["line"].split()[1], 1, "planned_reboot"
    # 2) any boot attempt near the incident = restart (counts; not excluded)
    for bt in ev["boots"]:
        if bt["ts"] - 60 <= t0 <= bt["ts"] + 300:
            return "reboot(unplanned)", "boot_attempts:" + bt["line"][:40], 0, ""
    # 2.5) upstream supplier outage (R3.4): only the resolver probe failed AND the
    #      device reported both uplinks down in the same window. The gateway ICMP
    #      probe is inherently immune (the gateway IS the device), so this rule can
    #      only ever apply to forwarding-type probes such as dns.
    if set(inc["probes"]) <= {"dns"} and ev.get("wan_alive"):
        pts = [up for (t, up) in ev["wan_alive"]
               if t0 * 1000 - 5000 <= t <= t1 * 1000 + 5000]
        if pts and not any(pts):
            return "upstream", "wan.alive:both-uplinks-down@window", 1, "upstream"
    # 3) device-side edges of the same component inside the window
    refs = []
    comps = []
    for pr in inc["probes"]:
        for eid, comp in EDGE_FOR_PROBE.get(pr, []):
            for e in ev["edges"]:
                if e["id"] == eid and t0 - 8 <= e["ts"] <= t1 + 8:
                    comps.append(comp)
                    refs.append("avail_edges:%s@%d" % (eid, e["ts"]))
    # 4) NE events for the probe's component
    for pr in inc["probes"]:
        for name in NE_FOR_PROBE.get(pr, []):
            for ne in ev["ne"]:
                if name in (ne.get("args") or "") and t0 - 10 <= ne["ts"] <= t1 + 10:
                    comps.append(name)
                    refs.append("ne_events:%s@%d" % (name, ne["ts"]))
    if comps:
        uniq = sorted(set(comps))
        return "/".join(uniq), ";".join(sorted(set(refs))[:4]), 0, ""
    return "unknown", "", 0, ""


# --------------------------------------------------------------------------
# report
# --------------------------------------------------------------------------
THRESH = {"lt5": (5.0, 1.0), "5to20": (1.0, 1.0), "gt20": (1.0, 7.0)}


def build_report(evidence_dir, days=7, pull=False):
    if pull:
        device_pull(evidence_dir, quiet=True)
    ev = load_device_evidence(evidence_dir)
    cutoff_ms = int((time.time() - days * 86400) * 1000)
    rows = [r for r in read_samples(evidence_dir, days=days) if r["ms"] >= cutoff_ms]
    paths = sorted({r["path"] for r in rows})
    by_path = {p: [r for r in rows if r["path"] == p] for p in paths}

    incidents = []
    for p in paths:
        _, merged = derive_episodes(by_path[p])
        for m in merged:
            inc = {"path": p, "start": m["start"], "end": m["end"],
                   "dur_s": m["dur_s"], "probes": m["probes"],
                   "open": m.get("open", False)}
            inc["severity"] = severity_of(inc["dur_s"])
            inc["tier"] = tier_of(inc["dur_s"])
            a, ref, exc, why = attribute(inc, ev)
            inc["attrib"], inc["evidence"] = a, ref
            inc["excluded"], inc["excl_reason"] = exc, why
            incidents.append(inc)
    incidents.sort(key=lambda x: x["start"])

    total_win_s = days * 86400
    measured_s = {}
    for p in paths:
        ts = sorted(r["ms"] for r in by_path[p])
        m = 0
        for a, b in zip(ts, ts[1:]):
            if b - a <= 5000:
                m += (b - a) / 1000.0
        measured_s[p] = int(m)

    tiers = {k: {"count": 0, "seconds": 0.0, "incidents": []} for k in THRESH}
    for inc in incidents:
        if inc["excluded"]:
            continue
        t = tiers[inc["tier"]]
        t["count"] += 1
        t["seconds"] += inc["dur_s"] or 0.0
        t["incidents"].append(inc)
    verdict = {}
    for k, (lim, per_days) in THRESH.items():
        rate = tiers[k]["count"] / (days / per_days)
        verdict[k] = {"limit": lim, "per_days": per_days, "rate": round(rate, 3),
                      "pass": rate < lim}
    out = {
        "version": VERSION, "generated_at": iso(time.time()), "window_days": days,
        "evidence_dir": evidence_dir, "paths": paths,
        "coverage": {"window_s": total_win_s, "measured_s": measured_s,
                     "pct": {p: (round(100.0 * measured_s[p] / total_win_s, 2)
                                 if total_win_s else 0) for p in paths}},
        "counts": {k: tiers[k]["count"] for k in THRESH},
        "verdict": verdict,
        "pass_all": all(v["pass"] for v in verdict.values()) and bool(paths),
        "excluded": [i for i in incidents if i["excluded"]],
        "drills": {"windows": ev.get("drills", []),
                   "open": [d for d in ev.get("drills", []) if not d["end"]],
                   "stale_open": [d for d in ev.get("drills", [])
                                  if not d["end"]
                                  and (now_ms() // 1000) - d["start"] > DRILL_MAX_OPEN_S],
                   "excluded_incidents": [i for i in incidents
                                          if i["excl_reason"] == "drill"]},
        "incidents": incidents,
        # R3.2 双端测量：设备侧台账必须也有数据。这里给出设备侧中断条数与
        # 最近几条，供验收报告与客户端口径交叉核对（客户端仍是验收口径）。
        "device_side": {"outages": len(ev["dev_outages"]),
                        "recent": ev["dev_outages"][-5:],
                        "note": ("device-side ledger present" if ev["dev_outages"]
                                 else "device-side ledger empty/missing (fast_facts "
                                      "not yet wired or no outage observed)")},
        "device_evidence": {"reboots": len(ev["reboots"]), "ne": len(ev["ne"]),
                            "edges": len(ev["edges"]),
                            "device_outages": len(ev["dev_outages"])},
    }
    return out


def ne_correlate(evidence_dir, days=1, window=60, pull=False, out=None):
    """NE(设备侧 SIGSEGV 事件) × 客户端可见中断 的时序关联（正式证据，Lead 指定）。

    对 ne_events.tsv 里每条 NE，取客户端在 [NE-window, NE+window] 内的全部采样：
      win_samples  窗口内有效采样数（icmp/dns/tcp80 任一被采到即算一拍）
      win_fails    窗口内"任一探针失败"的采样数
      max_gap_s    窗口内相邻采样的最大间隔（用于判测量缺口）
      verdict      gap / client_outage / single_fail / no_client_impact

    诚实边界（必须随结果一起引用）：
      * **no_client_impact 是观测事实，不是"NE 无害"的证明**。探测器只有 1s 粒度、
        只有 eth 一条路径；NE 可能造成过 <2s 的瞬断（低于去抖阈值）或只影响 WiFi 客户端。
      * gap 表示该 NE 时刻客户端没在测 —— 不计入分子分母，也不得算作"无害"。
      * 时间重叠不等于因果。
    """
    if pull:
        device_pull(evidence_dir, quiet=True)
    ev = load_device_evidence(evidence_dir)
    cutoff_ms = int((time.time() - days * 86400) * 1000)
    rows = [r for r in read_samples(evidence_dir, days=days) if r["ms"] >= cutoff_ms]
    paths = sorted({r["path"] for r in rows})

    # 每个路径一条按时间排序的"任一探针失败"序列
    seq = {}
    for p in paths:
        pts = []
        for r in rows:
            if r["path"] != p:
                continue
            vals = [r.get(k, -1) for k in ("icmp", "dns", "tcp80")]
            vals = [v for v in vals if v >= 0]
            if not vals:
                continue
            pts.append((r["ms"], 0 if any(v == 0 for v in vals) else 1))
        pts.sort()
        seq[p] = pts

    incidents = []
    for p in paths:
        _, merged = derive_episodes([r for r in rows if r["path"] == p])
        for x in merged:
            inc = {"path": p, "start": x["start"], "end": x["end"],
                   "dur_s": x["dur_s"], "probes": x["probes"]}
            a, ref, exc, why = attribute(inc, ev)
            inc.update({"attrib": a, "evidence": ref, "excluded": exc,
                        "excl_reason": why})
            incidents.append(inc)

    lines = []
    tally = {}
    for ne in ev["ne"]:
        ts = ne["ts"]
        if ts * 1000 < cutoff_ms:
            continue
        tms = ts * 1000
        nsamp = nfail = 0
        maxgap = 0
        last = None
        for p in paths:
            pts = seq.get(p) or []
            for ms, ok in pts:
                if tms - window * 1000 <= ms <= tms + window * 1000:
                    nsamp += 1
                    if ok == 0:
                        nfail += 1
                    if last is not None and ms - last > maxgap:
                        maxgap = ms - last
                    last = ms
                elif ms > tms + window * 1000:
                    break
        # 覆盖判据: 2*窗口 秒里至少有 25% 的拍(1s 节拍)才算"在测"
        need = max(4, int(2 * window * 0.25))
        if nsamp < need:
            verdict = "gap"
        elif nfail >= 2:
            verdict = "client_outage"
        elif nfail == 1:
            verdict = "single_fail"
        else:
            verdict = "no_client_impact"
        tally[verdict] = tally.get(verdict, 0) + 1
        # 同窗口内是否有已排除的中断（演练/重启），供读者判断
        hits = [i for i in incidents
                if (i["start"] / 1000.0) - window <= ts <= ((i["end"] or now_ms()) / 1000.0) + window]
        ex = ""
        if hits:
            i = hits[0]
            ex = "%s:%s:%s" % (i["excluded"], i["excl_reason"] or "-", i["attrib"])
        lines.append("%d\t%s\t%s\t%d\t%d\t%d\t%s\t%s\t%s" % (
            ts, ne.get("comm", "?"), ne.get("sig", ""), nsamp, nfail, int(maxgap / 1000),
            verdict, (hits[0]["dur_s"] if hits else ""), ex))

    hdr = ("#ne_vs_outage v1.1 | window=+-%ds | fields: ne_epoch ne_comm ne_sig "
           "win_samples win_fails max_gap_s verdict outage_dur_s outage_flags" % window)
    text = hdr + "\n" + "\n".join(lines) + ("\n" if lines else "")
    dst = out or os.path.join(evidence_dir, "ne_vs_outage.tsv")
    with open(dst, "w", encoding="utf-8") as f:
        f.write(text)

    _p("NE × 客户端可见中断关联（窗口 ±%ds，%dd）" % (window, days))
    _p("  NE 总数 %d" % len(lines))
    for k in ("client_outage", "single_fail", "no_client_impact", "gap"):
        if tally.get(k):
            _p("    %-16s %d" % (k, tally[k]))
    measured = tally.get("client_outage", 0) + tally.get("single_fail", 0) + tally.get("no_client_impact", 0)
    if measured:
        _p("  在测时段内 NE 造成客户端可见中断(≥2 失败): %d/%d = %.1f%%"
           % (tally.get("client_outage", 0), measured,
              100.0 * tally.get("client_outage", 0) / measured))
        _p("  **这是观测事实，不是 NE 无害的证明**（1s 粒度/单路径/2s 去抖下限）")
    if tally.get("gap"):
        _p("  另有 %d 条 NE 落在测量缺口期，不计入分子分母" % tally["gap"])
    _p("  -> %s" % dst)
    return {"ne_total": len(lines), "tally": tally, "out": dst,
            "window_s": window, "days": days, "measured_ne": measured}


def print_report(o):
    _p("svc_probe report v%s  window=%dd  generated=%s"
       % (o["version"], o["window_days"], o["generated_at"]))
    _p("paths: %s" % (", ".join(o["paths"]) or "(none)"))
    for p in o["paths"]:
        _p("  coverage[%s]: %.2f%% measured (%ds of %ds)"
           % (p, o["coverage"]["pct"][p], o["coverage"]["measured_s"][p],
              o["coverage"]["window_s"]))
    ds = o["device_side"]
    _p("device-side ledger: %d outage(s)  [%s]" % (ds["outages"], ds["note"]))
    _p("")
    _p("%-8s %6s %8s %8s %s" % ("tier", "count", "limit", "rate", "verdict"))
    for k in ("lt5", "5to20", "gt20"):
        v = o["verdict"][k]
        _p("%-8s %6d %8.2f %8.3f %s" % (k, o["counts"][k], v["limit"], v["rate"],
                                         "PASS" if v["pass"] else "FAIL"))
    _p("")
    # auditable exclusions: a reviewer must be able to see WHAT was dropped and
    # WHY without trusting us (Lead contract v1.2).
    dw = o["drills"]["windows"]
    if dw:
        _p("drill windows excluded from acceptance (%d):" % len(dw))
        for d in dw:
            _p("  %s .. %s  kind=%-12s target=%-12s owner=%-10s %s"
               % (iso(d["start"]), iso(d["end"]) if d["end"] else "(open)",
                  d["kind"], d["target"], d["owner"], d["note"]))
        if o["drills"]["open"]:
            _p("  WARN: %d drill window(s) still open (end_epoch=0) -- capped at %d min; "
               "ask the injector to close them"
               % (len(o["drills"]["open"]), DRILL_MAX_OPEN_S // 60))
        if o["drills"]["stale_open"]:
            _p("  WARN: %d drill row(s) open longer than %d min -- treated as closed at "
               "start+%d min (NOT open-ended, so real outages are not hidden)"
               % (len(o["drills"]["stale_open"]), DRILL_MAX_OPEN_S // 60,
                  DRILL_MAX_OPEN_S // 60))
        _p("")
    _p("incidents (%d, excluded %d):" % (len(o["incidents"]), len(o["excluded"])))
    for i in o["incidents"]:
        _p("  %s dur=%7.1fs %-5s %-5s probes=%-20s attrib=%-20s%s %s"
           % (iso(i["start"] / 1000.0), i["dur_s"] or -1.0, i["severity"], i["tier"],
              ",".join(i["probes"]), i["attrib"],
              " EXCLUDED(%s)" % i["excl_reason"] if i["excluded"] else "        ",
              ("ev=" + i["evidence"]) if i["evidence"] else ""))


# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="client-side service outage probe (M3)")
    ap.add_argument("--evidence-dir",
                    default=os.environ.get("LG_SVC_EVIDENCE") or DEFAULT_EVIDENCE)
    sub = ap.add_subparsers(dest="cmd", required=True)

    ps = sub.add_parser("selftest")
    ps.add_argument("--json", action="store_true")

    pr = sub.add_parser("run")
    pr.add_argument("--duration", type=int, default=0)
    pr.add_argument("--interval", type=float, default=1.0)
    pr.add_argument("--paths", default=None)
    pr.add_argument("--tcp22-every", type=int, default=TCP22_EVERY)
    pr.add_argument("--anchor-every", type=int, default=300)
    pr.add_argument("--skip-selftest", action="store_true")

    pd = sub.add_parser("derive")
    pd.add_argument("--days", type=int, default=0)
    pd.add_argument("--quiet", action="store_true")

    pn = sub.add_parser("necorr")
    pn.add_argument("--days", type=int, default=1)
    pn.add_argument("--window", type=int, default=60)
    pn.add_argument("--pull", action="store_true")
    pn.add_argument("--out", default=None)

    pp = sub.add_parser("report")
    pp.add_argument("--days", type=int, default=7)
    pp.add_argument("--json", action="store_true")
    pp.add_argument("--pull", action="store_true")

    sub.add_parser("status")

    ns = ap.parse_args(argv)
    ed = ns.evidence_dir

    if ns.cmd == "selftest":
        res = selftest()
        if ns.json:
            print(json.dumps(res, ensure_ascii=False, indent=1))
        else:
            _p("SELFTEST %s" % ("OK" if res["ok"] else "FAILED"))
            for c in res["checks"]:
                _p("  [%s] %-26s %s" % ("ok" if c["ok"] else "!!", c["check"],
                                        json.dumps(c["detail"], ensure_ascii=False)))
        return 0 if res["ok"] else 2

    if ns.cmd == "run":
        if not ns.skip_selftest:
            st = selftest()
            os.makedirs(ed, exist_ok=True)
            with open(os.path.join(ed, "selftest.json"), "w", encoding="utf-8") as f:
                json.dump(st, f, ensure_ascii=False, indent=1)
            if not st["ok"]:
                _p("REFUSING TO MEASURE: self-check failed. Fix the observation "
                   "point first; a polluted probe reports confident lies.")
                return 2
        paths = discover_paths(ns.paths)
        if not paths:
            _p("no path to %s found (no local address in %s0/24)" % (GATEWAY, LAN_NET))
            return 2
        smp = Sampler(paths, ed, interval=ns.interval, tcp22_every=ns.tcp22_every)
        if ns.anchor_every:
            def _anch():
                while not smp.stop.is_set():
                    try:
                        anchor_once(ed)
                    except Exception:
                        pass
                    smp.stop.wait(ns.anchor_every)
            threading.Thread(target=_anch, daemon=True).start()
        _p("svc_probe v%s sampling %s every %.2fs -> %s"
           % (VERSION, ", ".join("%s(%s)" % (p["name"], p["src"]) for p in paths),
              ns.interval, ed))
        smp.run(duration=ns.duration)
        return 0

    if ns.cmd == "derive":
        out = os.path.join(ed, "outages.tsv")
        rows = list(read_samples(ed, days=ns.days or None))
        paths = sorted({r["path"] for r in rows})
        ev = load_device_evidence(ed)
        n = 0
        with open(out, "w", encoding="utf-8") as f:
            f.write(OUTAGE_HEADER + "\n")
            for p in paths:
                _, merged = derive_episodes([r for r in rows if r["path"] == p])
                for m in merged:
                    inc = {"path": p, "start": m["start"], "end": m["end"],
                           "dur_s": m["dur_s"], "probes": m["probes"]}
                    a, ref, exc, why = attribute(inc, ev)
                    # flags: tcp22 是 60s 节拍，必须自曝其最小可判时长，
                    # 否则会被误读成 1s 口径（见 SVC_MEASUREMENT.md 1.2）
                    fl = "cadence=60" if "tcp22" in m["probes"] else ""
                    f.write("%d\t%d\t%.3f\t%s\t%s\t%s\t%s\t%d\t%s\t%s\tclient\t%s\n" % (
                        m["start"] // 1000, int((m["end"] or now_ms()) // 1000),
                        m["dur_s"] or 0.0, p, ",".join(m["probes"]),
                        severity_of(m["dur_s"]), a, exc, why, ref, fl))
                    n += 1
        if not ns.quiet:
            _p("derived %d episodes from %d samples -> %s" % (n, len(rows), out))
        return 0

    if ns.cmd == "necorr":
        ne_correlate(ed, days=ns.days, window=ns.window, pull=ns.pull, out=ns.out)
        return 0

    if ns.cmd == "report":
        o = build_report(ed, days=ns.days, pull=ns.pull)
        if ns.json:
            print(json.dumps(o, ensure_ascii=False, indent=1))
        else:
            print_report(o)
        return 0 if o["pass_all"] else 1

    if ns.cmd == "status":
        if not os.path.isdir(ed):
            _p("no evidence dir %s" % ed)
            return 1
        _p("evidence dir: %s" % ed)
        for f in sorted(os.listdir(ed)):
            fp = os.path.join(ed, f)
            if os.path.isfile(fp):
                _p("  %-28s %10d bytes  %s" % (f, os.path.getsize(fp),
                                               iso(os.path.getmtime(fp))))
        rows = list(read_samples(ed, days=1))
        if rows:
            last = rows[-1]
            _p("last sample: %s (%.1fs ago) path=%s icmp=%d dns=%d tcp80=%d tcp22=%d"
               % (iso(last["ms"] / 1000.0), (now_ms() - last["ms"]) / 1000.0,
                  last["path"], last["icmp"], last["dns"], last["tcp80"], last["tcp22"]))
        return 0
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
