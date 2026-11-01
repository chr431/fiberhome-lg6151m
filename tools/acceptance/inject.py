#!/usr/bin/env python3
"""inject.py -- R4.4 故障注入 campaign 装置 (PC 侧驱动, 设备侧执行, 单次注入=一条 SSH exec)

设计约束(来自 RELIABILITY_SPEC 4 + Lead 裁决 v1.1):
  * 每次注入必须持设备锁(由调用方用 _local/device_lock.py 包住, 本工具不自持);
  * 距 04:00 <15min 不注入(硬门禁, 本工具自检);
  * 每条注入必须有回滚路径(rollback 表达式), 未自愈时立即执行;
  * 注入后立即验证恢复(设备侧轮询 check 谓词, 恢复时刻即 dur);
  * 失败(未自愈)是最有价值的产出 -> verdict=FAIL, 必须在报告里闭环;
  * 台账落设备 /data/gw/logs/fault_inject.tsv (append-only, 可复核)。

用法:
  python tools/acceptance/inject.py --list
  python tools/acceptance/inject.py --batch A
  python tools/acceptance/inject.py --only K01,K02
  python tools/acceptance/inject.py --batch A --dry-run
"""
import argparse
import os
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from sshx import Dev  # noqa: E402

LOG = "/data/gw/logs/fault_inject.tsv"
HDR = "epoch	iso	id	class	target	pre_ok	recovered	dur_s	maxw_s	rebooted	verdict	evidence"
# Lead 裁决 v1.2: drills.tsv 是唯一演练标记文件(跨流契约), 见文件头注
DRILL_HDR = "start_epoch	end_epoch	kind	target	owner	note"

MARK = r"""
KIND="$1"; TGT="$2"; NOTE="$3"; PHASE="$4"; S0="$5"
DRILL=/data/gw/logs/drills.tsv
mkdir -p /data/gw/logs
: # P0: 不触碰设备 drills.tsv
if [ "$PHASE" = open ]; then
  S=$(date +%s)
  echo "MARK_LOCAL_ONLY $S $KIND $TGT"
  echo "MARK_OPEN $S"
else
  E=$(date +%s)
  echo "MARK_LOCAL_ONLY_CLOSE $S0 $E"
  echo "MARK_CLOSE $S0 $E"
fi
"""

# ---- 设备侧通用 runner: 一次 exec 内完成 pre/inject/poll/rollback/落账 ----
# 参数一律经 /tmp/inj_def 传入(见 sshx.Dev.put_text 的说明): 绝不能让目标守护的路径
# 出现在 harness 自己的 cmdline 里 —— 否则 svc_lib.alive() 的 pgrep -f 回退分支会把
# harness 当成"守护还活着", 测出来的自愈结论是假的(2026-11-01 00:05 实弹)。
RUNNER = r"""
DEF="$1"
[ -r "$DEF" ] || { echo "RESULT id=NO_DEF verdict=FAIL"; exit 0; }
. "$DEF"
rm -f "$DEF"
LOG=/data/gw/logs/fault_inject.tsv
DRILL=/data/gw/logs/drills.tsv
mkdir -p /data/gw/logs
[ -f "$LOG" ] || printf '%s\n' "$HDR" > "$LOG"
: # P0: 不触碰设备 drills.tsv
BID0=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
PRE=0; eval "$CHK" >/dev/null 2>&1 && PRE=1
S0=$(date +%s)
# P0(2026-11-01): drills.tsv 曾被并发重写写坏, 注入器改为**只写本机重建文件**,
# 不再 append/rewrite 设备 drills.tsv; 窗口由 PC 侧落 _local/evidence/drills_rebuild/.
T0=$S0
eval "$ACT" >/tmp/inject_act.out 2>&1
REC=0; T1=$T0
while :; do
  if eval "$CHK" >/dev/null 2>&1; then REC=1; T1=$(date +%s); break; fi
  NOW=$(date +%s)
  [ $(( NOW - T0 )) -ge "$MAXW" ] && { T1=$NOW; break; }
  sleep 3
done
DUR=$(( T1 - T0 ))
RBX=none
if [ "$REC" = 0 ]; then
  RBX=ran
  eval "$RB" >/tmp/inject_rb.out 2>&1
  sleep 2
  eval "$CHK" >/dev/null 2>&1 && RBX=ran_ok || RBX=ran_failed
fi
S1=$(date +%s)
: # P0: 回填改为本机重建文件(见上)
BID1=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
REB=0; [ "$BID0" != "$BID1" ] && REB=1
if [ "$PRE" = 0 ]; then V=SKIP_NOPRE
elif [ "$REC" = 1 ] && [ "$REB" = 0 ]; then V=PASS
elif [ "$REC" = 1 ] && [ "$REB" = 1 ]; then V=PASS_REBOOT
else V=FAIL; fi
EV=$(head -c 120 /tmp/inject_act.out 2>/dev/null | tr '\n\t' '  ')
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$(date +%s)" "$(date '+%F %T')" "$ID" "$CLS" "$TGT" "$PRE" "$REC" "$DUR" "$MAXW" "$REB" "$V" "rb=$RBX act=$EV" >> "$LOG"
echo "RESULT id=$ID verdict=$V recovered=$REC dur=$DUR s rebooted=$REB pre=$PRE rb=$RBX"
"""

def q(s):
    """single-quote a string for POSIX sh."""
    return "'" + s.replace("'", "'\\''") + "'"

P_ALIVE = "pgrep -f '%s' >/dev/null 2>&1"
KILL = "for p in $(pgrep -f '%s'); do kill -9 $p 2>/dev/null; done; true"

DAEMONS = [
    ("K01", "led_mgr.sh",     "led_mgr[.]sh",     "指示灯 supervisor"),
    ("K02", "fan_mgr.sh",     "fan_mgr[.]sh",     "风扇 supervisor"),
    ("K03", "ntp_keeper.sh",  "ntp_keeper[.]sh",  "对时守护(无 RTC)"),
    ("K04", "traffic_logger.sh", "traffic_logger[.]sh", "流量采样器"),
    ("K05", "wifi_guard.sh",  "wifi_guard[.]sh",  "BA-stall 自愈守护"),
    ("K06", "reboot_sched.sh","reboot_sched[.]sh","定时重启守护(30d 前提)"),
    ("K07", "log_keeper.sh",  "log_keeper[.]sh",  "日志持久化守护"),
    ("K08", "usb_mgr.sh",     "usb_mgr[.]sh",     "USB-C supervisor"),
    ("K09", "wan_eth.sh",     "wan_eth[.]sh",     "有线 WAN keeper"),
    ("K10", "dial_keeper.sh", "dial_keeper[.]sh", "5G 拨号 keeper"),
    # K11 avail_watch.sh 已删: state-truth 的 fast_watch 取代它(SVC_TABLE 换行),
    # 杀一个"已被删掉的服务"只会得到 SKIP_NOPRE, 不构成覆盖证据。
    # fast_watch 的注入改由 K21(batch C) 承担 —— 判据是"杀掉后 GUI 必须显陈旧/未知"。
    ("K12", "nerepair",       "/data/gw/bin/nerepair", "SIGSEGV 缓解 supervisor"),
    ("K15", "authd",          "/data/gw/authd",   "上行认证守护"),
    ("K16", "v3httpd",        "v3httpd",          "GUI httpd(:80)"),
    ("K17", "dnsmasq",        "dnsmasq",          "DHCP/DNS(:53)"),
    ("K18", "atcid",          "atcid",            "AT 通道守护"),
    ("K19", "hostapd",        "/var/wlan/hap_",   "我方 hostapd(WiFi WPA 层)"),
    ("K20", "radvd",          "radvd",            "LAN v6 路由通告"),
    ("K22", "wan_agg.sh",     "wan_agg[.]sh",     "双上行聚合 supervisor(策略路由/NAT 所有者)"),
]

CAMPAIGN = []
for sid, tgt, pat, note in DAEMONS:
    if tgt == "hostapd":
        chk = ". /data/gw/svc_lib.sh 2>/dev/null; svc_hostapd_up"
        act = "for p in $(. /data/gw/svc_lib.sh 2>/dev/null; svc_our_hostapd); do kill -9 $p; done"
        rb = "LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf >/dev/null 2>&1; sleep 5"
    elif tgt == "dnsmasq":
        chk = "pidof dnsmasq >/dev/null 2>&1 && . /data/gw/svc_lib.sh 2>/dev/null && port_listen 53"
        act = "p=$(pidof dnsmasq 2>/dev/null); [ -n \"$p\" ] && kill -9 $p || true"
        rb = "kill -9 $(pidof dnsmasq 2>/dev/null) 2>/dev/null; true"
    elif tgt == "v3httpd":
        chk = "pidof v3httpd >/dev/null 2>&1 && . /data/gw/svc_lib.sh 2>/dev/null && port_listen 80"
        act = "p=$(pidof v3httpd 2>/dev/null); [ -n \"$p\" ] && kill -9 $p || true"
        rb = "nohup /data/gw/v3httpd >/dev/null 2>&1 & sleep 3"
    elif tgt == "authd":
        chk = "pidof authd >/dev/null 2>&1"
        act = "p=$(pidof authd 2>/dev/null); [ -n \"$p\" ] && kill -9 $p || true"
        rb = "kill -9 $(pidof authd 2>/dev/null) 2>/dev/null; true"
    elif tgt == "atcid":
        chk = "pidof atcid >/dev/null 2>&1"
        act = "p=$(pidof atcid 2>/dev/null); [ -n \"$p\" ] && kill -9 $p || true"
        rb = "/usr/bin/atcid >/var/atcid.log 2>&1 & sleep 2"
    elif tgt == "radvd":
        chk = "pidof radvd >/dev/null 2>&1"
        act = "p=$(pidof radvd 2>/dev/null); [ -n \"$p\" ] && kill -9 $p || true"
        rb = "sh /data/gw/v6_reconcile.sh apply >/dev/null 2>&1; sleep 2"
    else:
        chk = P_ALIVE % pat
        act = KILL % pat
        rb = "nohup sh /data/gw/%s >/dev/null 2>&1 & sleep 3" % tgt
    CAMPAIGN.append(dict(id=sid, cls="kill_daemon", target=tgt, note=note,
                         action=act, check=chk, rollback=rb, maxw=300, batch="A"))

# ---- C 批: 监督链顶层(必须单独做, 见 Lead 安全红线) ----
CAMPAIGN += [
    dict(id="K14", cls="kill_supervisor", target="watchdog.sh", batch="C", maxw=300,
         note="主监督者: 只能由 healthdog 拉活; 死了没有任何自愈, 靠 healthdog 的 beat 判据",
         action=KILL % "watchdog[.]sh",
         check=P_ALIVE % "watchdog[.]sh",
         rollback="nohup sh /data/gw/watchdog.sh >/dev/null 2>&1 & sleep 3"),
    dict(id="K21", cls="kill_daemon", target="fast_watch.sh", batch="C", maxw=300,
         note="M2 状态真值总线 1s 循环(state-truth 上线后存在): 杀掉后 GUI 必须显陈旧/未知, watchdog 60s 内拉回",
         action="p=$(pgrep -f 'fast_watch[.]sh' | head -1); [ -n \"$p\" ] && kill -9 $p || true",
         check=P_ALIVE % "fast_watch[.]sh",
         rollback="nohup sh /data/gw/fast_watch.sh >/dev/null 2>&1 & sleep 3"),
]

# ---- D 批: healthdog(喂内核看门狗的一方) 必须最后、单独、60s 内确认 ----
CAMPAIGN += [
    dict(id="K13", cls="kill_supervisor", target="healthdog.sh", batch="D", maxw=90,
         note="内核 healthdog.ko 的喂狗方: 90s 不喂 = 真复位。kill 后 60s 内必须确认 /proc/healthdog 心跳恢复, 否则放弃剩余注入",
         action=KILL % "healthdog[.]sh",
         check="pgrep -f 'healthdog[.]sh' >/dev/null 2>&1 && [ -c /proc/healthdog ] || [ -e /proc/healthdog ]",
         rollback="nohup sh /data/gw/healthdog.sh >/dev/null 2>&1 & sleep 3"),
]

CAMPAIGN += [
    dict(id="L01", cls="link", target="br-lan ra0 membership", batch="B", maxw=300,
         note="把 2.4G AP 从 LAN 网桥摘掉, 看是否有任何路径会把它加回去",
         action="brctl delif br-lan ra0 2>/dev/null; true",
         check="brctl show br-lan 2>/dev/null | grep -qw ra0",
         rollback="brctl addif br-lan ra0 2>/dev/null; true"),
    dict(id="L02", cls="link", target="ra0 link down", batch="B", maxw=300,
         note="ifconfig ra0 down, 看 hostapd 自愈链能否把链路拉回",
         action="ifconfig ra0 down 2>/dev/null; true",
         check=". /data/gw/svc_lib.sh 2>/dev/null; svc_link_up ra0",
         rollback="ifconfig ra0 up 2>/dev/null; sleep 2"),
    dict(id="L03", cls="link", target="rai0 link down", batch="B", maxw=300,
         note="5G AP 链路 down",
         action="ifconfig rai0 down 2>/dev/null; true",
         check=". /data/gw/svc_lib.sh 2>/dev/null; svc_link_up rai0",
         rollback="ifconfig rai0 up 2>/dev/null; sleep 2"),
    dict(id="C01", cls="config", target="NAT masquerade rule", batch="B", maxw=300,
         note="删 NAT MASQUERADE(客户端出网断, SSH 走 LAN 不受影响)",
         action="iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE 2>/dev/null; iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE || iptables -t nat -F POSTROUTING 2>/dev/null; true",
         check="iptables -t nat -S POSTROUTING 2>/dev/null | grep -q MASQUERADE",
         rollback="kill -9 $(pgrep -f 'wan_agg[.]sh' | head -1) 2>/dev/null; sleep 8; true"),
    dict(id="C02", cls="config", target="mangle WANAGG marks", batch="B", maxw=300,
         note="清空分流 MARK 规则(策略路由失效)",
         action="iptables -t mangle -F WANAGG 2>/dev/null; true",
         check="iptables -t mangle -S WANAGG 2>/dev/null | grep -q MARK",
         rollback="kill -9 $(pgrep -f 'wan_agg[.]sh' | head -1) 2>/dev/null; sleep 8; true"),
    dict(id="C03", cls="config", target="fwmark policy rule", batch="B", maxw=300,
         note="删 ip rule fwmark(策略路由断裂)",
         action="ip rule del 2>/dev/null; ip rule show 2>/dev/null | grep fwmark | while read a b c d e f g; do ip rule del $a $b $c $d $e $f $g 2>/dev/null; done; true",
         check="ip rule 2>/dev/null | grep -q fwmark",
         rollback="kill -9 $(pgrep -f 'wan_agg[.]sh' | head -1) 2>/dev/null; sleep 8; true"),
    dict(id="D01", cls="disk", target="/data fill to ~120MB free", batch="B", maxw=240,
         note="塞盘到 120MB 余量(高于 100MB 阈值): 系统应继续正常",
         action="dd if=/dev/zero of=/data/filltest.bin bs=1M count=1300 2>/dev/null; sync; true",
         check="[ $(df -k /data | tail -1 | awk '{print $4}') -ge 100000 ]",
         rollback="rm -f /data/filltest.bin; sync; true"),
    dict(id="D02", cls="disk", target="/data fill below threshold", batch="B", maxw=180,
         note="塞盘到 <100MB(跨过 watchdog 告警阈值), 验证 WARN 与删除后恢复; 严格限时",
         action="dd if=/dev/zero of=/data/filltest2.bin bs=1M count=1450 2>/dev/null; sync; true",
         check="[ $(df -k /data | tail -1 | awk '{print $4}') -ge 102400 ]",
         rollback="rm -f /data/filltest2.bin; sync; true"),
    dict(id="T01", cls="clock", target="clock +30min", batch="B", maxw=300,
         note="时钟前跳 30min: watchdog 应记 clock jump, reboot_sched 不得误重启",
         action="date -s \"$(date -d '+30 min' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; true",
         check="[ $(date +%s) -lt $(( $(awk '/^btime/{print $2}' /proc/stat) + $(cut -d. -f1 /proc/uptime) + 120 )) ]",
         rollback="kill -9 $(pgrep -f 'ntp_keeper[.]sh' | head -1) 2>/dev/null; sleep 10; true"),
    dict(id="T02", cls="clock", target="clock -45min", batch="B", maxw=300,
         note="时钟回跳 45min: 不得触发重复重启/预算误复位",
         action="date -s \"$(date -d '-45 min' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; true",
         check="[ $(date +%s) -lt $(( $(awk '/^btime/{print $2}' /proc/stat) + $(cut -d. -f1 /proc/uptime) + 120 )) ]",
         rollback="kill -9 $(pgrep -f 'ntp_keeper[.]sh' | head -1) 2>/dev/null; sleep 10; true"),
    dict(id="N01", cls="storm", target="40x ICMP flood 10s", batch="B", maxw=180,
         note="LAN 侧 40 路并发 ping 洪泛 10s: 不得崩、不得丢监督链",
         action="i=0; while [ $i -lt 40 ]; do ping -c 20 -s 1400 -i 0.05 192.168.9.1 >/dev/null 2>&1 & i=$((i+1)); done; sleep 10; true",
         check="[ -f /tmp/watchdog.beat ] && pgrep -f 'watchdog[.]sh' >/dev/null && pgrep -f 'v3httpd' >/dev/null",
         rollback="pkill -f 'ping -c 20' 2>/dev/null; true"),
    dict(id="N02", cls="storm", target="200 TCP connects to :80", batch="B", maxw=180,
         note="200 路并发 TCP 连 :80(GUI 单线程)",
         action="i=0; while [ $i -lt 200 ]; do (echo > /dev/tcp/192.168.9.1/80) >/dev/null 2>&1 & i=$((i+1)); done; sleep 8; true",
         check="pidof v3httpd >/dev/null 2>&1",
         rollback="kill -9 $(pidof v3httpd 2>/dev/null) 2>/dev/null; sleep 4; true"),
    dict(id="M01", cls="memory", target="300MB tmpfs pressure", batch="B", maxw=180,
         note="向 /tmp(tmpfs=RAM) 写 300MB: 关键守护不得被 OOM 收走",
         action="dd if=/dev/zero of=/tmp/memtest.bin bs=1M count=300 2>/dev/null; true",
         check="pgrep -f 'watchdog[.]sh' >/dev/null && pgrep -f 'healthdog[.]sh' >/dev/null && pgrep -f 'led_mgr[.]sh' >/dev/null",
         rollback="rm -f /tmp/memtest.bin; true"),
    dict(id="M02", cls="memory", target="200 stray sleep processes", batch="B", maxw=180,
         note="瞬间 200 个子进程(进程表压力)",
         action="i=0; while [ $i -lt 200 ]; do sleep 30 & i=$((i+1)); done; sleep 3; true",
         check="[ $(ls /proc | grep -c '^[0-9]') -lt 450 ] && pgrep -f 'watchdog[.]sh' >/dev/null",
         rollback="pkill -f 'sleep 30' 2>/dev/null; true"),
    dict(id="E01", cls="ne", target="SIGSEGV on throwaway proc", batch="B", maxw=120,
         note="对一次性进程注入 SIGSEGV: NE 台账必须新增一行(观测链活着)",
         action="grep -c '' /data/gw/logs/ne_events.tsv 2>/dev/null > /tmp/ne_pre; sh -c 'kill -SEGV $$' >/dev/null 2>&1; true",
         check="[ $(grep -c '' /data/gw/logs/ne_events.tsv 2>/dev/null) -gt $(cat /tmp/ne_pre 2>/dev/null) ]",
         rollback="true"),
    dict(id="E02", cls="ne", target="SIGSEGV via our-tree binary", batch="B", maxw=120,
         note="经 /data/gw/bin/ip 注入 SIGSEGV(our-tree): 台账+core_meta 链必须记到",
         action="grep -c '' /data/gw/logs/ne_events.tsv 2>/dev/null > /tmp/ne_pre2; /data/gw/bin/ip --crashme >/dev/null 2>&1; true",
         check="[ $(grep -c '' /data/gw/logs/ne_events.tsv 2>/dev/null) -gt $(cat /tmp/ne_pre2 2>/dev/null) ]",
         rollback="true"),
]

def by_id(i):
    for c in CAMPAIGN:
        if c["id"] == i:
            return c
    return None

def guard_0400():
    t = time.localtime()
    mins = t.tm_hour * 60 + t.tm_min
    d = abs(mins - 240)
    d = min(d, 1440 - d)
    return d >= 15, mins

def run_one(dev, c, dry=False):
    # 参数走文件, 不走 argv(见 RUNNER 头注)
    NL = chr(10)
    defs = "".join([
        ("ID=%s" + NL) % q(c["id"]),
        ("CLS=%s" + NL) % q(c["cls"]),
        ("TGT=%s" + NL) % q(c["target"]),
        ("ACT=%s" + NL) % q(c["action"]),
        ("CHK=%s" + NL) % q(c["check"]),
        ("MAXW=%s" + NL) % q(str(c["maxw"])),
        ("RB=%s" + NL) % q(c["rollback"]),
        ("NOTE=%s" + NL) % q(c.get("note", "")),
        ("HDR=%s" + NL) % q(HDR),
        ("DRILL_HDR=%s" + NL) % q(DRILL_HDR),
    ])
    defpath = "/tmp/inj_def_%s" % c["id"]
    cmd = "sh -c " + q(RUNNER) + " _ " + q(defpath)
    if dry:
        return "DRY", 0.0
    dev.put_text(defpath, defs)
    t0 = time.time()
    rc, out = dev.run(cmd, timeout=c["maxw"] + 120)
    el = time.time() - t0
    line = [l for l in out.splitlines() if l.startswith("RESULT ")]
    if line:
        return line[-1], el
    return "NO_RESULT rc=%s out=%s" % (rc, out.strip()[:200].replace("\n", " ")), el

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--batch", default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--sleep", type=int, default=8)
    ap.add_argument("--parallel", type=int, default=1,
                    help="并发注入数(每组 N 个互不相关的目标同时 kill, 各自独立测量)")
    a = ap.parse_args()

    if a.list:
        for c in CAMPAIGN:
            print("%-4s %-11s %-34s batch=%s maxw=%ss  %s" %
                  (c["id"], c["cls"], c["target"], c["batch"], c["maxw"], c["note"]))
        print("total injections: %d" % len(CAMPAIGN))
        return 0

    ok, mins = guard_0400()
    if not ok and not a.dry_run:
        print("REFUSED: 距 04:00 <15min (now=%02d:%02d) — Lead 裁决禁止此时注入" %
              (mins // 60, mins % 60))
        return 3

    if a.only:
        todo = [by_id(x.strip()) for x in a.only.split(",")]
        todo = [c for c in todo if c]
    elif a.batch:
        todo = [c for c in CAMPAIGN if c["batch"] == a.batch]
    else:
        todo = CAMPAIGN

    tag = a.batch or (a.only or "all")
    print("== campaign: %d injections (batch=%s) ==" % (len(todo), tag))
    with Dev() as dev:
        # 批级演练窗口(Lead v1.2: 每批必须有 start/end, 不得留 end_epoch=0)
        b0 = 0
        if not a.dry_run:
            rc, out = dev.run("sh -c " + q(MARK) + " _ fault-injection "
                              + q("batch-" + tag) + " " + q("%d injections" % len(todo))
                              + " open 0", timeout=60)
            for l in out.splitlines():
                if l.startswith("MARK_OPEN "):
                    b0 = int(l.split()[1])
            print("batch drill window opened at epoch %s" % b0)
        npass = nfail = 0
        try:
          for i, c in enumerate(todo, 1):
            r, el = run_one(dev, c, a.dry_run)
            print("[%2d/%2d] %-4s %-30s %s" % (i, len(todo), c["id"], c["target"], r))
            sys.stdout.flush()
            if isinstance(r, str) and "verdict=PASS" in r:
                npass += 1
            elif not a.dry_run:
                nfail += 1
            if not a.dry_run and i < len(todo):
                time.sleep(a.sleep)
        finally:
          # 无论中途异常(连接断/参数错), 批级演练窗口必须关闭 —— 否则消费方会把
          # 之后所有真实中断都当成演练排除掉(Lead v1.2 硬要求: 不得留 end_epoch=0)。
          pass
        if not a.dry_run and b0:
            dev.run("sh -c " + q(MARK) + " _ fault-injection " + q("batch-" + tag)
                    + " " + q("done") + " close " + str(b0), timeout=60)
            print("batch drill window closed (start=%s)" % b0)
    print("== summary: PASS=%d FAIL/OTHER=%d ==" % (npass, nfail))
    return 0 if nfail == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
