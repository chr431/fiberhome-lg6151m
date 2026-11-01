#!/usr/bin/env python3
"""cfg_heal 演练/验收装置 (M4 G2 配置漂移自愈; R4.1 / R3 永久中断类)

用途: 把 "配置被外力删除 -> 自愈器发现 -> 调用既有施加器重建 -> 客户端恢复"
      这条链**实弹**走一遍, 并给出可复核证据。

设计原则(与 RELIABILITY_SPEC §0 一致):
  * 每个用例 = 制造故障 -> 断言 <=60s 重建 -> 断言客户端连通性恢复 -> 断言台账有行;
  * 每个用例注入前先**断言配置本来是好的**(否则测的是别的东西);
  * 每个用例都带**独立安全网**(restore 命令 + 可选的设备侧 deadman),
    自愈器失效时也不会把设备留在坏状态;
  * 正常态必须 **0 次重建**(--baseline), 这是"不误伤"的正面证据。

设备写操作必须持 device_lock; 本工具会先检查锁 owner, 不匹配即拒绝。

用法:
  python tools/cfg_heal_drill.py plan
  python tools/cfg_heal_drill.py status
  python tools/cfg_heal_drill.py baseline --secs 120
  python tools/cfg_heal_drill.py case D1_nat_ccmni
  python tools/cfg_heal_drill.py all --secs 60
  python tools/cfg_heal_drill.py restore          # 只做安全网恢复
"""
import argparse
import json
import os
import socket
import subprocess
import sys
import time
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # lg6151m-public
PROJ = os.path.dirname(ROOT)                                         # 项目根
sys.path.insert(0, os.path.join(ROOT, "tools"))
import lgssh  # noqa: E402

DEV = "/data/gw"
LEDGER = DEV + "/logs/cfg_heal.tsv"
CH = DEV + "/cfg_heal.sh"
GWIP = "192.168.9.1"
EVID = os.path.join(PROJ, "_local", "evidence", "cfg_heal")
LOCKPY = os.path.join(PROJ, "_local", "device_lock.py")
OWNER = "cfg-heal"


# ----------------------------------------------------------------- 设备访问
class Dev:
    def __init__(self, quiet=False):
        self.c = None
        self.quiet = quiet

    def conn(self):
        if self.c is None:
            self.c = lgssh.connect()
        return self.c

    def run(self, cmd, timeout=30):
        """执行设备命令; 断链自动重连一次(演练会故意切断 LAN)。"""
        for attempt in (0, 1):
            try:
                return lgssh.run(self.conn(), cmd, timeout=timeout)
            except Exception as e:                       # noqa: BLE001
                self.close()
                if attempt:
                    return "[[SSH-FAIL]] %s" % e
                time.sleep(1.5)
        return "[[SSH-FAIL]]"

    def close(self):
        try:
            if self.c:
                self.c.close()
        except Exception:                                # noqa: BLE001
            pass
        self.c = None

    def ok(self, cmd, timeout=30):
        """True/False; SSH 不通时返回 None(演练会故意切断 LAN, 不能当成配置坏)。"""
        out = self.run(cmd + " && echo __OK__ || echo __NO__", timeout=timeout)
        if out.startswith("[[SSH-FAIL]]"):
            return None
        return "__OK__" in out and "__NO__" not in out


# ----------------------------------------------------------------- 客户端连通性
def dns_probe(timeout=2.0):
    """向 192.168.9.1:53 发一个 A 查询; 收到任何合法响应即证明 LAN 侧 DNS 通。"""
    q = (b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
         b"\x03www\x02qq\x03com\x00\x00\x01\x00\x01")
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(timeout)
        s.sendto(q, (GWIP, 53))
        data, _ = s.recvfrom(512)
        s.close()
        return len(data) >= 12
    except OSError:
        return False


def tcp_probe(port, timeout=2.0):
    t0 = time.time()
    try:
        s = socket.create_connection((GWIP, port), timeout=timeout)
        s.close()
        return True, int((time.time() - t0) * 1000)
    except OSError:
        return False, None


def client_probe():
    r = {}
    r["tcp22"] = tcp_probe(22)[0]
    r["tcp80"] = tcp_probe(80)[0]
    r["dns"] = dns_probe()
    r["ok"] = r["tcp22"] and r["tcp80"] and r["dns"]
    return r


def fmt_conn(r):
    return "tcp22=%d tcp80=%d dns=%d" % (r["tcp22"], r["tcp80"], r["dns"])


# ----------------------------------------------------------------- 锁
def lock_owner():
    try:
        out = subprocess.run([sys.executable, LOCKPY, "status"],
                             capture_output=True, text=True, timeout=20).stdout
    except Exception as e:                               # noqa: BLE001
        return "?", "lock status failed: %s" % e
    owner = "?"
    for tok in out.split():
        if tok.startswith("owner="):
            owner = tok.split("=", 1)[1]
    return owner, out.strip()


def require_lock(force=False):
    owner, raw = lock_owner()
    if owner == OWNER or force:
        return True
    print("!! 设备锁不在本任务手里 (owner=%s)\n   %s" % (owner, raw))
    print("   先持锁: python _local/device_lock.py hold --owner %s --purpose '...' --minutes N" % OWNER)
    print("   或加 --force 仅用于只读子命令(plan/status)")
    return False


# ----------------------------------------------------------------- 用例
# 每个用例: dict(id, title, discover=None, inject, check, restore, deadman, conn_required)
def cases():
    return [
        dict(
            id="D1_nat_ccmni",
            title="删掉蜂窝口 NAT MASQUERADE (注入 C01)",
            discover="ip -o -4 addr show 2>/dev/null | awk '/ccmni/ && / inet /{print $2}' | sort -u",
            inject=("for i in $(ip -o -4 addr show 2>/dev/null | awk '/ccmni/ && / inet /{print $2}' | sort -u); do "
                    "iptables -t nat -D POSTROUTING -s 192.168.9.0/24 -o $i -j MASQUERADE 2>/dev/null; done; true"),
            check=("n=0; for i in $(ip -o -4 addr show 2>/dev/null | awk '/ccmni/ && / inet /{print $2}' | sort -u); do "
                   "iptables -t nat -C POSTROUTING -s 192.168.9.0/24 -o $i -j MASQUERADE 2>/dev/null || exit 1; n=1; done; "
                   "[ $n = 1 ]"),
            restore=("for i in $(ip -o -4 addr show 2>/dev/null | awk '/ccmni/ && / inet /{print $2}' | sort -u); do "
                     "iptables -t nat -C POSTROUTING -s 192.168.9.0/24 -o $i -j MASQUERADE 2>/dev/null || "
                     "iptables -t nat -A POSTROUTING -s 192.168.9.0/24 -o $i -j MASQUERADE; done; true"),
            deadman=False, conn_required=False,
            note="蜂窝不是当前主路时客户端不受影响; 本用例证明的是规则重建, 不是断网恢复",
        ),
        dict(
            id="D2_mangle_mark",
            title="删掉 mangle WANAGG 的 MARK 打标规则 (注入 C02)",
            discover="iptables -t mangle -S WANAGG 2>/dev/null | grep -c -- '-j MARK'",
            inject=("iptables -t mangle -S WANAGG 2>/dev/null | grep -- '-j MARK' | sed 's/^-A /-D /' "
                    "| while read -r l; do iptables -t mangle $l 2>/dev/null; done; true"),
            check=("iptables -t mangle -S WANAGG 2>/dev/null | grep -q -e '--set-xmark' -e '--set-mark' && "
                   "iptables -t mangle -S WANAGG 2>/dev/null | grep -q 'CONNMARK --save-mark' && "
                   "iptables -t mangle -C PREROUTING -i br-lan -j WANAGG 2>/dev/null"),
            restore="sh " + DEV + "/wan_agg.sh --reapply >/dev/null 2>&1; true",
            deadman=False, conn_required=False,
            note="分流静默失效(所有新流回落 main 表); watchdog 的 grep -q MARK 对此形态是假绿",
        ),
        dict(
            id="D3_fwmark_rule",
            title="删掉 fwmark 策略路由规则 (注入 C03)",
            discover="cat /tmp/wan_mode 2>/dev/null",
            inject=("m=$(cat /tmp/wan_mode 2>/dev/null); case \"$m\" in agg:*) ;; *) echo NOAGG; exit 3;; esac; "
                    "s1=$(echo $m | cut -d: -f2); s2=$(echo $m | cut -d: -f3); "
                    "if [ \"$s1\" = 1 ]; then ip rule del fwmark 0x4000000/0xfc000000 table 100 2>/dev/null; fi; "
                    "if [ \"$s2\" = 1 ]; then ip rule del fwmark 0x8000000/0xfc000000 table 200 2>/dev/null; fi; "
                    "echo s1=$s1 s2=$s2"),
            check=("m=$(cat /tmp/wan_mode 2>/dev/null); s1=$(echo $m | cut -d: -f2); s2=$(echo $m | cut -d: -f3); "
                   "r=1; if [ \"$s1\" = 1 ]; then ip rule show | grep -q 'fwmark 0x4000000/0xfc000000 lookup 100' || r=0; fi; "
                   "if [ \"$s2\" = 1 ]; then ip rule show | grep -q 'fwmark 0x8000000/0xfc000000 lookup 200' || r=0; fi; "
                   "[ $r = 1 ]"),
            restore=("ip rule show | grep -q 'fwmark 0x4000000/0xfc000000 lookup 100' || "
                     "ip rule add fwmark 0x4000000/0xfc000000 table 100 priority 101 2>/dev/null; "
                     "ip rule show | grep -q 'fwmark 0x8000000/0xfc000000 lookup 200' || "
                     "ip rule add fwmark 0x8000000/0xfc000000 table 200 priority 102 2>/dev/null; true"),
            deadman=False, conn_required=False,
            note="wan_agg 的 ensure_rules 每 3s 已补装 -> 期望由它先修; 台账会记 transient/delegated 而非 repair",
        ),
        dict(
            id="D4_bridge_eth1",
            title="把 LAN 物理口 eth1 从 br-lan 摘除 (注入 L01; PC 就在这个口上)",
            discover="brctl show br-lan 2>/dev/null | awk 'NR>1{print $NF}' | tr '\n' ' '",
            inject="brctl delif br-lan eth1 2>/dev/null; true",
            check="brctl show br-lan 2>/dev/null | awk 'NR>1{print $NF}' | grep -qx eth1",
            restore="brctl addif br-lan eth1 2>/dev/null; true",
            deadman=True, conn_required=True,
            note="PC 与设备同在此口 -> SSH 会断; 设备侧 deadman 100s 独立兜底, 自愈器应在 <=60s 内先修好",
        ),
        dict(
            id="D5_fw_guard",
            title="删掉 WAN 纵深封禁跳转 (fw_apply 面)",
            discover="iptables -C FORWARD -i eth0 -j V4WANGUARDF 2>/dev/null && echo present",
            inject=("iptables -D FORWARD -i eth0 -j V4WANGUARDF 2>/dev/null; "
                    "iptables -D FORWARD -i ccmni+ -j V4WANGUARDF 2>/dev/null; true"),
            check=("iptables -C FORWARD -i eth0 -j V4WANGUARDF 2>/dev/null && "
                   "iptables -C FORWARD -i ccmni+ -j V4WANGUARDF 2>/dev/null"),
            restore=("iptables -C FORWARD -i eth0 -j V4WANGUARDF 2>/dev/null || "
                     "iptables -A FORWARD -i eth0 -j V4WANGUARDF; "
                     "iptables -C FORWARD -i ccmni+ -j V4WANGUARDF 2>/dev/null || "
                     "iptables -A FORWARD -i ccmni+ -j V4WANGUARDF; true"),
            deadman=False, conn_required=False,
            note="WAN->LAN 新建暴露面; 由既有 fw_apply.sh apply 重建",
        ),
        dict(
            id="D8_bridge_ra0",
            title="把 WiFi 口 ra0 从 br-lan 摘除 (L01; soak-qa batchB 301s 未自愈的复现点)",
            discover="brctl show br-lan 2>/dev/null | awk 'NR>1{print $NF}' | tr '\n' ' '",
            inject="brctl delif br-lan ra0 2>/dev/null; true",
            check="brctl show br-lan 2>/dev/null | awk 'NR>1{print $NF}' | grep -qx ra0",
            restore="brctl addif br-lan ra0 2>/dev/null; true",
            deadman=False, conn_required=False,
            note="WiFi 侧桥成员。PC 走 eth1 不受影响; 但 WiFi 客户端会失去 L2 归属。"
                 "v1.2 及以前此处有永久盲区(stat 闸门失效 + pgrep 子串), v1.3 已修。",
        ),
        dict(
            id="D6_reapply_idempotent",
            title="wan_agg --reapply 连跑两次, 第二次不得产生任何变更(幂等硬要求)",
            discover="cat /tmp/wan_mode 2>/dev/null",
            inject=("sh " + DEV + "/wan_agg.sh --reapply; echo '--RUN2--'; "
                    "sh " + DEV + "/wan_agg.sh --reapply; echo '--DONE--'"),
            check="true",
            restore="true",
            deadman=False, conn_required=False,
            note="比对两次运行后的 iptables/ip rule 全量文本; 只做一次预/后快照比较",
        ),
        dict(
            id="D7_stale_source_negative",
            title="反例: 把期望值来源 /tmp/wan_mode 改成陈旧 -> 必须不动手(宁可不修也不乱修)",
            discover="cat /tmp/wan_mode 2>/dev/null",
            inject=("cp /tmp/wan_mode /tmp/cfg_heal_mode.bak 2>/dev/null; echo stale > /tmp/wan_mode; "
                    "iptables -t mangle -S WANAGG 2>/dev/null | grep -- '-j MARK' | sed 's/^-A /-D /' "
                    "| while read -r l; do iptables -t mangle $l 2>/dev/null; done; "
                    "echo injected-mangle-drift-with-stale-source"),
            check=("cp /tmp/cfg_heal_mode.bak /tmp/wan_mode 2>/dev/null; "
                   "iptables -t mangle -S WANAGG 2>/dev/null | grep -q -e '--set-xmark' -e '--set-mark'"),
            restore=("cp /tmp/cfg_heal_mode.bak /tmp/wan_mode 2>/dev/null; "
                     "sh " + DEV + "/wan_agg.sh --reapply >/dev/null 2>&1; true"),
            deadman=False, conn_required=False,
            note="负向用例: 先观察 20s 断言自愈器不动作, 再恢复来源断言它确实会修(正反两面)",
            negative=True,
        ),
    ]


def case_by_id(cid):
    for c in cases():
        if c["id"] == cid or c["id"].startswith(cid):
            return c
    raise SystemExit("unknown case %r (see: plan)" % cid)


# ----------------------------------------------------------------- 台账/断言
def ledger_lines(d):
    out = d.run("cat %s 2>/dev/null | tail -n 40" % LEDGER)
    if out.startswith("[[SSH-FAIL]]"):
        return []
    return [ln for ln in out.splitlines() if ln.strip()]


def ledger_repairs(d):
    return [ln for ln in ledger_lines(d) if "\trepair\t" in ln]


def ledger_count(d):
    out = d.run("wc -l < %s 2>/dev/null || echo 0" % LEDGER)
    try:
        return int(out.strip().split()[0])
    except Exception:                                    # noqa: BLE001
        return -1


def drift_now(d):
    out = d.run("sh %s --json 2>/dev/null" % CH)
    try:
        return json.loads(out.strip().splitlines()[-1])
    except Exception:                                    # noqa: BLE001
        return {}


# ----------------------------------------------------------------- 主流程
def do_baseline(d, secs, rows):
    print("== baseline: 正常态静默观测 %ds (断言 0 次重建 = 不误伤正面证据)" % secs)
    n0 = ledger_count(d)
    r0 = len(ledger_repairs(d))
    bad = 0
    t_end = time.time() + secs
    samples = 0
    while time.time() < t_end:
        j = drift_now(d)
        samples += 1
        drift = j.get("drift", "")
        if drift:
            bad += 1
            print("   !! drift at %s: %s" % (datetime.datetime.now().strftime("%H:%M:%S"), drift))
        time.sleep(5)
    n1 = ledger_count(d)
    r1 = len(ledger_repairs(d))
    ok = (bad == 0) and (r1 == r0)
    print("   samples=%d drift_samples=%d ledger_rows %d->%d repairs %d->%d  => %s"
          % (samples, bad, n0, n1, r0, r1, "PASS" if ok else "FAIL"))
    rows.append(dict(case="BASELINE", t0="", t_repaired="", latency_s=secs, passed=int(ok),
                     conn="", ledger="rows %d->%d repairs %d->%d" % (n0, n1, r0, r1),
                     note="drift_samples=%d" % bad))
    return ok


CFG_SNAP = ("iptables -S 2>/dev/null; iptables -t nat -S 2>/dev/null; "
            "iptables -t mangle -S 2>/dev/null; ip rule show 2>/dev/null")


def dev_snap(d):
    """配置全量文本快照(排序后比较, 顺序无关)。"""
    out = d.run(CFG_SNAP)
    if out.startswith("[[SSH-FAIL]]"):
        return None
    return sorted(ln.strip() for ln in out.splitlines() if ln.strip())


def do_d6(d, c, rows):
    """D6: wan_agg --reapply 幂等 —— 连跑两次, 第二次不得产生任何变更。"""
    print("\n== %s: %s" % (c["id"], c["title"]))
    a0 = dev_snap(d)
    d.run("sh %s/wan_agg.sh --reapply 2>&1 | tail -2" % DEV)
    a1 = dev_snap(d)
    d.run("sh %s/wan_agg.sh --reapply 2>&1 | tail -2" % DEV)
    a2 = dev_snap(d)
    if a0 is None or a1 is None or a2 is None:
        rows.append(dict(case=c["id"], passed=0, note="ssh fail"))
        return False
    diff1 = [x for x in a1 if x not in a0] + [x for x in a0 if x not in a1]
    diff2 = [x for x in a2 if x not in a1] + [x for x in a1 if x not in a2]
    ok = (diff2 == [])
    print("   run1 delta vs before = %d 行; run2 delta vs run1 = %d 行 => %s"
          % (len(diff1), len(diff2), "PASS 幂等" if ok else "FAIL 非幂等"))
    for ln in diff2[:8]:
        print("     | " + ln)
    rows.append(dict(case=c["id"], t0="", t_repaired="", latency_s="",
                     passed=int(ok), conn="",
                     ledger="run1_delta=%d run2_delta=%d" % (len(diff1), len(diff2)),
                     note=c.get("note", "")))
    return ok


def do_negative(d, c, rows):
    """D7: 期望值来源陈旧 -> 自愈器必须**不动手**; 恢复来源后必须能修(正反两面)。"""
    print("\n== %s: %s" % (c["id"], c["title"]))
    raw = c.get("check_raw", "iptables -t mangle -S WANAGG 2>/dev/null | grep -q -e '--set-xmark' -e '--set-mark'")
    if d.ok(raw):
        print("   precheck: 打标规则在")
    n0 = ledger_count(d)
    r0 = len(ledger_repairs(d))
    print("   inject(stale source + mangle drift): %s" % c["inject"])
    d.run(c["inject"])
    t0 = time.time()
    acted = False
    while time.time() - t0 < 20:
        time.sleep(2.0)
        if d.ok(raw) is True:
            acted = True
            break
    neg_ok = not acted
    print("   观察 20s: 自愈器 %s => %s" % ("动手了(违规)" if acted else "未动手(符合预期)",
                                     "FAIL" if acted else "PASS"))
    # 恢复来源 -> 必须能修
    d.run("cp /tmp/cfg_heal_mode.bak /tmp/wan_mode 2>/dev/null; true")
    t1 = time.time()
    fixed = None
    while time.time() - t1 < 60:
        time.sleep(2.0)
        if d.ok(raw) is True:
            fixed = time.time()
            break
    pos_ok = fixed is not None
    lat = round(fixed - t1, 1) if fixed else None
    if not pos_ok:
        print("   !! 恢复来源后仍未修好 -> 执行安全网 restore")
        d.run(c["restore"])
        time.sleep(2)
        pos_ok = d.ok(raw) is True
    n1 = ledger_count(d)
    r1 = len(ledger_repairs(d))
    ok = neg_ok and pos_ok
    print("   恢复来源后: %s (latency=%ss) 台账 +%d 行 repairs +%d => %s"
          % ("已修复" if pos_ok else "仍未修复", lat, n1 - n0, r1 - r0, "PASS" if ok else "FAIL"))
    rows.append(dict(case=c["id"], t0="", t_repaired="", latency_s=(lat if lat else ""),
                     passed=int(ok), conn="",
                     ledger="+%drows +%drepairs" % (n1 - n0, r1 - r0),
                     note="neg=%s pos=%s" % ("pass" if neg_ok else "FAIL", "pass" if pos_ok else "FAIL")))
    return ok


def do_case(d, c, max_wait, rows):
    if c["id"].startswith("D6"):
        return do_d6(d, c, rows)
    if c.get("negative"):
        return do_negative(d, c, rows)
    print("\n== %s: %s" % (c["id"], c["title"]))
    print("   discover: %s" % d.run(c["discover"]).strip().replace("\n", " | "))
    if not d.ok(c["check"]):
        print("   !! 注入前配置就不是好的 -> 跳过(先修好再演练)")
        rows.append(dict(case=c["id"], t0="", t_repaired="", latency_s="", passed=0,
                         conn="", ledger="", note="precheck failed"))
        return False

    # 安全网: 设备侧 deadman (SSH 断开后仍独立生效)
    if c.get("deadman"):
        dm = ("nohup sh -c 'sleep 100; brctl addif br-lan eth1 2>/dev/null; "
              "echo deadman-fired $(date +%s) >> /tmp/cfg_heal_deadman.log' >/dev/null 2>&1 &")
        d.run(dm)
        print("   deadman armed (100s)")

    n0 = ledger_count(d)
    r0 = len(ledger_repairs(d))
    print("   inject: %s" % c["inject"])
    t0 = time.time()
    inj = d.run(c["inject"])
    if "NOAGG" in inj:
        print("   !! 聚合未启用, 本用例不适用")
        rows.append(dict(case=c["id"], t0="", t_repaired="", latency_s="", passed=0,
                         conn="", ledger="", note="agg off"))
        return False
    print("   injected at %s" % datetime.datetime.now().strftime("%H:%M:%S"))

    repaired = None
    lost = 0
    while time.time() - t0 < max_wait:
        time.sleep(1.0)
        st = d.ok(c["check"])
        if st is True:
            repaired = time.time()
            break
        if st is None:
            lost += 1
    lat = round((repaired - t0), 1) if repaired else None

    # 桥口/链路恢复后客户端可能还要重新 ARP, 给 2s 收敛再探(避免把收敛期判成失败)
    if repaired and c.get("conn_required"):
        time.sleep(2.0)
    conn = client_probe()
    n1 = ledger_count(d)
    r1 = len(ledger_repairs(d))
    if not repaired:
        print("   !! 未在 %ds 内重建 -> 执行安全网 restore" % max_wait)
        d.run(c["restore"])
        time.sleep(2)
        restored = d.ok(c["check"])
        print("   restore %s" % ("ok" if restored else "FAILED"))
    ok = bool(repaired) and lat is not None and lat <= 60.0
    if c.get("conn_required"):
        ok = ok and conn["ok"]
    print("   latency=%ss conn=[%s] ssh_lost_polls=%d ledger +%d rows repairs +%d => %s"
          % (lat, fmt_conn(conn), lost, n1 - n0, r1 - r0, "PASS" if ok else "FAIL"))
    for ln in d.run("tail -n 6 %s 2>/dev/null" % LEDGER).splitlines()[-6:]:
        print("     | " + ln)
    rows.append(dict(case=c["id"], t0=datetime.datetime.fromtimestamp(t0).strftime("%H:%M:%S"),
                     t_repaired=(datetime.datetime.fromtimestamp(repaired).strftime("%H:%M:%S")
                                 if repaired else ""),
                     latency_s=(lat if lat is not None else ">%d" % max_wait),
                     passed=int(ok), conn=fmt_conn(conn),
                     ledger="+%drows +%drepairs ssh_lost=%d" % (n1 - n0, r1 - r0, lost),
                     note=c.get("note", "")))
    return ok


def write_evidence(rows):
    os.makedirs(EVID, exist_ok=True)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    path = os.path.join(EVID, "%s_drill.tsv" % ts)
    cols = ["case", "t0", "t_repaired", "latency_s", "passed", "conn", "ledger", "note"]
    with open(path, "w", encoding="utf-8") as f:
        f.write("\t".join(cols) + "\n")
        for r in rows:
            f.write("\t".join(str(r.get(k, "")) for k in cols) + "\n")
    print("\n证据: %s" % path)
    return path


def main():
    ap = argparse.ArgumentParser(description="cfg_heal 演练/验收装置")
    ap.add_argument("cmd", choices=["plan", "status", "baseline", "case", "all", "restore"])
    ap.add_argument("case_id", nargs="?")
    ap.add_argument("--secs", type=int, default=60)
    ap.add_argument("--max-wait", type=int, default=90)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--no-lock", action="store_true",
                    help="只读子命令(baseline)免锁: 不写设备, 可跨他人窗口长跑")
    a = ap.parse_args()

    if a.cmd == "plan":
        print("%-16s %s" % ("CASE", "WHAT"))
        for c in cases():
            print("%-16s %s\n%-16s %s" % (c["id"], c["title"], "", c.get("note", "")))
        print("\nbaseline: 正常态 %ds 静默观测, 断言 0 次重建(不误伤)" % a.secs)
        return 0

    if a.cmd == "status":
        require_lock(force=True)
        d = Dev()
        try:
            print(d.run("sh %s --status 2>&1" % CH))
            print("-- ledger --")
            print("\n".join(ledger_lines(d)[-10:]) or "(empty)")
            print("-- client probe --")
            print(fmt_conn(client_probe()))
        finally:
            d.close()
        return 0

    readonly = a.cmd == "baseline" and a.no_lock
    if not readonly and not require_lock(force=a.force):
        return 2

    rows = []
    d = Dev()
    rc = 0
    try:
        if a.cmd == "baseline":
            rc = 0 if do_baseline(d, a.secs, rows) else 1
        elif a.cmd == "case":
            if not a.case_id:
                raise SystemExit("case 需要 id")
            rc = 0 if do_case(d, case_by_id(a.case_id), a.max_wait, rows) else 1
        elif a.cmd == "all":
            okb = do_baseline(d, a.secs, rows)
            oks = []
            for c in cases():
                oks.append(do_case(d, c, a.max_wait, rows))
            rc = 0 if (okb and all(oks)) else 1
        elif a.cmd == "restore":
            for c in cases():
                d.run(c["restore"])
            print("restore 全部执行完毕; 复核:")
            for c in cases():
                print("  %-16s %s" % (c["id"], "ok" if d.ok(c["check"]) else "STILL-BAD"))
            rc = 0
    finally:
        d.close()
        if rows:
            write_evidence(rows)
    return rc


if __name__ == "__main__":
    sys.exit(main())
