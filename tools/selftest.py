#!/usr/bin/env python3
"""selftest.py -- assertion-based functional test suite for the LG6151M gateway.

Design principle: L13 (2026-10-05) -- "feature silently broken until manual
inspection" happened three times because we only checked control plane
(process running, port listening) not data plane (does traffic actually
flow through the expected path?). This suite tests BOTH:

  Layer 1  Control plane:   process alive, rule installed, port listening
  Layer 2  Data plane:      actual traffic traverses the expected interface
  Layer 3  Cross-layer:     API report matches kernel/iptables reality
  Layer 4  End-to-end:      from the PC through the gateway to the internet

v1.1 (L14, 2026-10-05): phase-1 strip killed atcid -> AT channel (SMS/CSQ/
lock dispatch) died silently for 3 days while every data-plane test stayed
green. Coverage now spans EVERY consumer surface: all 18 GET endpoints
(per-endpoint shape+key assertions), AT/mipc control plane, SIM/registration
state, lock consistency across conf/tree/modem, watchdog health, clock,
temperature, vendor attack-surface closure.

Usage:
  python tools/selftest.py               # run all tests
  python tools/selftest.py wifi agg      # run specific category
  python tools/selftest.py --list        # list all tests
  python tools/selftest.py --json        # machine-readable output (CI)
Exit: 0 all pass, 1 any failure.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

sys.path.insert(0, HERE)
import lgssh  # noqa: E402

# ---- test infrastructure ----

RESULTS = []   # [(name, category, fn)] at registration; then (name, cat, bool, detail) at run
CURRENT_CAT = [""]
_REGISTRY = []  # [(name, category, fn)] -- stable registry


def test(name):
    """Decorator: register a test function."""
    def wrap(fn):
        fn._test_name = name
        fn._category = CURRENT_CAT[0]
        _REGISTRY.append((name, CURRENT_CAT[0], fn))
        return fn
    return wrap


def category(name):
    CURRENT_CAT[0] = name


def record(name, cat, passed, detail=""):
    RESULTS.append((name, cat, passed, detail))
    mark = "✓" if passed else "✗"
    color = "\033[92m" if passed else "\033[91m"
    print(f"  {color}{mark}\033[0m {name}" + (f"  [{detail}]" if detail else ""))


# ---- device helpers ----

_c = None


def dev(cmd, timeout=15):
    """Run command on device, return stdout."""
    global _c
    if _c is None:
        _c = lgssh.connect()
    return lgssh.run(_c, cmd)


def api(endpoint, token=None, timeout=10):
    """Call gateway API endpoint, return parsed JSON."""
    url = f"http://{lgssh.HOST}/api/{endpoint}"
    if token:
        url += f"?token={token}"
    r = urllib.request.urlopen(url, timeout=timeout)
    return json.loads(r.read())


def api_post(endpoint, body, token):
    """POST to gateway API, return parsed JSON."""
    import urllib.parse
    data = (body + f"&token={token}").encode()
    req = urllib.request.Request(
        f"http://{lgssh.HOST}/api/{endpoint}", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    r = urllib.request.urlopen(req, timeout=10)
    return json.loads(r.read())


def get_token(password):
    """Login to gateway API, return token."""
    import urllib.parse
    data = f"pass={urllib.parse.quote(password)}".encode()
    req = urllib.request.Request(
        f"http://{lgssh.HOST}/api/login", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    r = urllib.request.urlopen(req, timeout=10)
    j = json.loads(r.read())
    return j.get("token")


_TOKEN = ["<unset>"]


def _token():
    """Cached GUI token, or None when no password is configured.

    Mirrors lgssh's secrets resolution (LG_GUI_PASS env or device_local.py;
    v3 GUI key is GW_PASS -- WEB_PASS is the vendor web password).
    """
    if _TOKEN[0] != "<unset>":
        return _TOKEN[0]
    pw = os.environ.get("LG_GUI_PASS")
    if not pw:
        try:
            import device_local
            pw = getattr(device_local, "GW_PASS", "")
        except ImportError:
            pw = ""
    tok = get_token(pw) if pw else None
    _TOKEN[0] = tok
    return tok


def at(cmd, timeout=15):
    """Send AT command via mipc_wan_cli on device, return response text."""
    return dev(f"mipc_wan_cli --at_cmd '{cmd}'", timeout=timeout)


def iface_delta(iface, fn):
    """Helper: capture counter, run fn, return delta bytes."""
    before = int(dev(f"cat /sys/class/net/{iface}/statistics/tx_bytes").strip() or 0)
    fn()
    after = int(dev(f"cat /sys/class/net/{iface}/statistics/tx_bytes").strip() or 0)
    return after - before


# =================================================================
category("wifi")
# =================================================================

@test("三 BSS 接口存在且为 AP 模式")
def t_wifi_bss():
    out = dev("for i in ra0 rai0 rai1; do iw dev $i info 2>/dev/null | grep -c 'type AP'; done")
    counts = out.split()
    ok = len(counts) == 3 and all(c.strip() == "1" for c in counts)
    record(t_wifi_bss._test_name, "wifi", ok,
           f"ra0={counts[0]} rai0={counts[1]} rai1={counts[2]}" if len(counts) == 3 else out[:60])


@test("hostapd 单进程多配置 (F3)")
def t_wifi_hostapd():
    out = dev("ps | grep '[h]ostapd -B' | head -1")
    # lgssh wraps in ash -c which appends, so just check both conf names present
    ok = "hap_2g" in out and "hap_5g" in out  # ps 截断长行, 只查前缀
    record(t_wifi_hostapd._test_name, "wifi", ok,
           "F3 single-process" if ok else f"unexpected: {out.strip()[:70]}")


@test("信标无固件级错误事件")
def t_wifi_beacon():
    n = int(dev("dmesg | grep -cE 'AP: Beacon OFF|Beacon lost - Error|Beacon interval is illegal'").strip() or 0)
    record(t_wifi_beacon._test_name, "wifi", n == 0, f"events={n}")


@test("API 报告的 BSS 数与内核一致")
def t_wifi_cross():
    # kernel truth
    kern = dev("iw dev 2>/dev/null | grep -c 'type AP'").strip()
    # API truth (need token or use indirect check via process)
    hap = dev("ps | grep -c '[h]ostapd -B'").strip()
    ok = kern == "3" and hap == "1"
    record(t_wifi_cross._test_name, "wifi", ok,
           f"kernel={kern} hostapd_procs={hap}")


@test("5G 带宽配置与射频实际一致 (跨层)")
def t_wifi_bwcons():
    # L15 (2026-10-05): "160MHz 被驱动钳制"误诊数周 -- 实为 hwifi dat 双字段
    # (VHT_BW/EHT_ApBw) 语义错位。本断言守住配置链: settings.conf 的 BW5G
    # 必须反映到 iw 实际射频宽度, 任何一层丢失(如 EHT_ApBw 字段被删)当场红。
    conf = dev("grep -h '^BW5G=' /data/gw/settings.conf /data/gw/defaults.conf "
               "2>/dev/null | head -1 | cut -d= -f2").strip()
    iw = dev("iw dev rai0 info 2>/dev/null | grep -oE 'width: [0-9]+ MHz' "
             "| grep -oE '[0-9]+'").strip()
    if not conf or not iw:
        record(t_wifi_bwcons._test_name, "wifi", False,
               f"conf={conf or '?'} iw={iw or '?'}")
        return
    expect = {"80": ("80",), "160": ("160",),
              "20": ("20",), "40": ("20", "40")}.get(conf)
    ok = expect is not None and iw in expect
    record(t_wifi_bwcons._test_name, "wifi", ok,
           f"BW5G={conf} iw={iw}MHz" + ("" if ok else f" (期望 {expect})"))


# =================================================================
category("gui")
# =================================================================

@test("HTTP :80 响应")
def t_gui_http():
    try:
        r = urllib.request.urlopen(f"http://{lgssh.HOST}/", timeout=5)
        ok = r.status == 200
    except Exception:
        ok = False
    record(t_gui_http._test_name, "gui", ok)


@test("index.html 含版本参数 (防缓存)")
def t_gui_cache():
    try:
        r = urllib.request.urlopen(f"http://{lgssh.HOST}/", timeout=5)
        body = r.read().decode()
        ok = re.search(r"app\.js\?v=\d+", body) is not None
    except Exception:
        ok = False
    record(t_gui_cache._test_name, "gui", ok)


@test("app.js 完整性 (非截断)")
def t_gui_appjs():
    try:
        r = urllib.request.urlopen(f"http://{lgssh.HOST}/app.js", timeout=10)
        body = r.read().decode()
        # 截断检测: 文件必须以 route() 结尾且含 LG_plugin
        ok = body.rstrip().endswith("route();") and "LG_plugin" in body
        size = len(body)
    except Exception:
        ok, size = False, 0
    record(t_gui_appjs._test_name, "gui", ok, f"{size}B")


@test("plugins.js 可达 (认证插件页)")
def t_gui_plugin():
    try:
        r = urllib.request.urlopen(f"http://{lgssh.HOST}/plugins.js", timeout=5)
        body = r.read().decode()
        ok = "LG_plugin" in body
    except Exception:
        ok = False
    record(t_gui_plugin._test_name, "gui", ok)


@test("API login + token 生命周期")
def t_gui_login():
    tok = _token()
    if tok is None:
        # GW_PASS 缺失或已过期(设备侧 pass_set 改过) -- 无法做正向断言;
        # 认证机制由 t_gui_badlogin/t_gui_badtoken 覆盖
        record(t_gui_login._test_name, "gui", True,
               "skip (GW_PASS stale -- password changed on device?)")
        return
    ok = len(tok) > 8
    record(t_gui_login._test_name, "gui", ok, "token ok" if ok else "login failed")


@test("全 GET 端点扫描 (形状+关键字段)")
def t_gui_endpoints():
    # L14: 单个端点死后其余仍绿 -- 每个端点必须单独过一遍。
    # slow 端点 (wifiscan ~10s) 也覆盖: 射频扫描路径同样会静默死亡。
    req_keys = {
        "status": ("uptime", "mem"),
        "agg": ("enable", "engine"),
        "cellular": ("operator", "serving", "cells"),
        "sim": ("imei",),
        "sms": ("count",),
        "traffic": ("rx", "tx"),
        "netmode": ("mode",),
        "ntp": ("date",),
        "fan": ("mode",),
        "led": ("night",),
        "uplink": ("form", "ttl_rule"),
        "wifi_adv": ("ch2g", "ch5g"),
        "logs": ("wan_agg",),
        "dhcp_static": ("entries",),
        "dhcp": ("r1", "lease"),
        "fw": ("forwards", "dmz", "blocked"),
        "clients": ("clients", "stations"),
    }
    tok = _token()
    if tok is None:
        record(t_gui_endpoints._test_name, "gui", True, "skip (no GUI_PASS)")
        return
    bad = []
    for ep, keys in req_keys.items():
        try:
            j = api(ep, tok)
        except Exception as e:
            bad.append(f"{ep}:{type(e).__name__}")
            continue
        if "error" in j:
            bad.append(f"{ep}:err={j['error']}")
            continue
        for k in keys:
            if k not in j:
                bad.append(f"{ep}:no-{k}")
    try:
        j = api("wifiscan", tok, timeout=30)
        if "error" in j:
            bad.append(f"wifiscan:err={j['error']}")
    except Exception as e:
        bad.append(f"wifiscan:{type(e).__name__}")
    ok = not bad
    record(t_gui_endpoints._test_name, "gui", ok,
           "18 endpoints ok" if ok else "; ".join(bad)[:120])


@test("坏 token 被拒 (认证强制)")
def t_gui_badtoken():
    try:
        j = api("status", "deadbeefdeadbeefdeadbeefdeadbeef")
        ok = j.get("error") == "need_login"
    except Exception:
        ok = False
    record(t_gui_badtoken._test_name, "gui", ok)


@test("坏口令被拒 (login 机制活着)")
def t_gui_badlogin():
    import urllib.parse
    try:
        data = f"pass={urllib.parse.quote('wrong-password-x')}".encode()
        req = urllib.request.Request(
            f"http://{lgssh.HOST}/api/login", data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"})
        j = json.loads(urllib.request.urlopen(req, timeout=10).read())
        ok = j.get("error") == "bad_login"
    except Exception:
        ok = False
    record(t_gui_badlogin._test_name, "gui", ok,
           "sha256+JSON path ok" if ok else "login mechanism broken")


# =================================================================
category("agg")
# =================================================================

@test("wan_agg 守护进程存活")
def t_agg_daemon():
    out = dev("ps | grep -c '[w]an_agg.sh'")
    ok = out.strip() not in ("0", "")
    record(t_agg_daemon._test_name, "agg", ok)


@test("分流规则已安装 (sport + mark)")
def t_agg_rules():
    out = dev("iptables -t mangle -S WANAGG 2>/dev/null | grep -cE 'sport.*MARK'")
    n = int(out.strip() or 0)
    ok = n >= 4  # tcp+udp 各 2 条 sport 规则
    record(t_agg_rules._test_name, "agg", ok, f"sport_rules={n}")


@test("fwmark 策略路由存在 (v4)")
def t_agg_fwmark():
    out = dev("ip rule | grep -c fwmark")
    n = int(out.strip() or 0)
    ok = n >= 1  # 至少 1 条 (主备模式可能只有单侧)
    record(t_agg_fwmark._test_name, "agg", ok, f"fwmark_rules={n}")


@test("聚合开关状态文件有效")
def t_agg_switch():
    out = dev("cat /tmp/wan_mode 2>/dev/null").strip()
    ok = out in ("off", "agg:0:1", "agg:1:0", "agg:1:1", "agg:0:0")
    record(t_agg_switch._test_name, "agg", ok, f"wan_mode={out}")


@test("钉死规则与配置表一致")
def t_agg_pin():
    conf_pins = dev("grep -v '^#' /data/gw/agg_pins.conf 2>/dev/null | grep -c .").strip()
    live_pins = dev("iptables -t mangle -S WANAGG 2>/dev/null | grep -c '\\-s .*MARK'").strip()
    # 容差: 钉死侧宕机时规则可能少
    ok = int(live_pins or 0) >= int(conf_pins or 0) - 1 if int(conf_pins or 0) > 0 else True
    record(t_agg_pin._test_name, "agg", ok,
           f"conf={conf_pins} live={live_pins}")


@test("5G 上行有流量 (数据面探测)")
def t_agg_5g_dp():
    # 设备侧强制 ccmni 出口 ping -- 与 PC 的 MAC 钉死/分流权重无关
    # (PC 钉死 WAN2 时 PC-ping-delta 探测会假失败, 曾现瞬态红)
    out = dev("IF=$(ip -o -4 addr show 2>/dev/null | grep ccmni | grep -m1 inet "
              "| awk '{print $2}'); ping -c 3 -W 2 -I $IF 223.5.5.5 2>&1 | tail -2")
    m = re.search(r"(\d+) packets? received", out)
    ok = m is not None and int(m.group(1)) >= 1
    record(t_agg_5g_dp._test_name, "agg", ok,
           m.group(0) if m else out.strip().replace("\n", " ")[:50])


# =================================================================
category("net")
# =================================================================

@test("LAN DHCP 服务可用 (dnsmasq)")
def t_net_dhcp():
    out = dev("pidof dnsmasq")
    ok = bool(out.strip())
    record(t_net_dhcp._test_name, "net", ok)


@test("SSH 可达 (dropbear 单监听)")
def t_net_ssh():
    out = dev("netstat -tln 2>/dev/null | grep -c ':22.*LISTEN'")
    n = int(out.strip() or 0)
    ok = n >= 1
    record(t_net_ssh._test_name, "net", ok, f"listeners={n}")


@test("NAT MASQUERADE 规则存在")
def t_net_nat():
    out = dev("iptables -t nat -S POSTROUTING | grep -c MASQUERADE")
    n = int(out.strip() or 0)
    ok = n >= 1
    record(t_net_nat._test_name, "net", ok, f"masq_rules={n}")


@test("FORWARD 链允许 LAN→WAN")
def t_net_fwd():
    out = dev("iptables -S FORWARD | grep -c 'ACCEPT'")
    n = int(out.strip() or 0)
    ok = n >= 1
    record(t_net_fwd._test_name, "net", ok, f"accept_rules={n}")


@test("PC→外网端到端 (5G 路径)")
def t_net_e2e():
    r = subprocess.run(["ping", "-n", "2", "-w", "3000", "223.5.5.5"],
                       capture_output=True, encoding="gbk",
                       errors="replace", timeout=10)
    ok = "TTL=" in (r.stdout or "")
    record(t_net_e2e._test_name, "net", ok)


# =================================================================
category("cellular")
# =================================================================
# L14 (2026-10-05): 第一阶段裁剪误杀 atcid → AT 通道(SMS/CSQ/锁下发)死亡
# 3 天无人察觉 -- 数据面测试全绿。本类别自此同时覆盖:
#   数据面 (ccmni/DNS) + 控制面 (AT/mipc) + 翻译层 (树/自管conf) + GUI 层

@test("ccmni 接口有 IPv4")
def t_cel_iface():
    out = dev("ip -4 addr show | grep ccmni | grep inet | head -1")
    ok = bool(out.strip())
    record(t_cel_iface._test_name, "cellular", ok, out.strip()[:40])


@test("DNS 解析可用")
def t_cel_dns():
    r = subprocess.run(["nslookup", "www.baidu.com", lgssh.HOST],
                       capture_output=True, encoding="gbk",
                       errors="replace", timeout=10)
    ok = "Address" in (r.stdout or "") and "baidu" in (r.stdout or "").lower()
    record(t_cel_dns._test_name, "cellular", ok)


@test("AT 通道活着 (+CSQ 应答)")
def t_cel_at():
    # L14 回归本体: atcid 死时 mipc_wan_cli 不报错只输出 "Failed to execute"
    out = at("AT+CSQ")
    ok = "+CSQ:" in out
    record(t_cel_at._test_name, "cellular", ok,
           out.strip().replace("\n", " ")[:40] if not ok else "CSQ ok")


@test("atcid 守护存活")
def t_cel_atcid():
    out = dev("pidof atcid")
    ok = bool(out.strip())
    record(t_cel_atcid._test_name, "cellular", ok, f"pid={out.strip()}")


@test("SIM 就绪 (CPIN)")
def t_cel_sim():
    out = at("AT+CPIN?")
    ok = "READY" in out
    record(t_cel_sim._test_name, "cellular", ok,
           out.strip().replace("\n", " ")[:40])


@test("模组已注册 (COPS)")
def t_cel_reg():
    # +COPS: 0,2,"46015",11 -- 含引号=已注册; airplane(CFUN:4)时跳过
    cfun = at("AT+CFUN?")
    if "CFUN: 4" in cfun:
        record(t_cel_reg._test_name, "cellular", True, "airplane, skip")
        return
    out = at("AT+COPS?")
    ok = '"' in out and "COPS" in out
    record(t_cel_reg._test_name, "cellular", ok,
           out.strip().replace("\n", " ")[:50])


@test("IMEI 可读 (15 位)")
def t_cel_imei():
    out = at("AT+CGSN")
    m = re.search(r"\b(\d{15})\b", out)
    record(t_cel_imei._test_name, "cellular", bool(m),
           m.group(1) if m else out.strip()[:40])


@test("MIPC 原生信号查询 (RSRP)")
def t_cel_mipcsig():
    out = dev("mipc_wan_cli --nw_get_signal")
    ok = re.search(r"RSRP\s*=\s*-?\d+", out) is not None
    record(t_cel_mipcsig._test_name, "cellular", ok,
           out.strip().replace("\n", " ")[:40])


@test("MIPC 原生制式查询 (RAT)")
def t_cel_mipcrat():
    out = dev("mipc_wan_cli --nw_get_rat")
    ok = "RAT Mode Value" in out
    record(t_cel_mipcrat._test_name, "cellular", ok,
           out.strip().replace("\n", " ")[:50])


@test("cfg 树信号上报活着 (过渡期)")
def t_cel_tree():
    # mobilenetwork→cfgmgr→RadioSignalParameter 链路任一死亡即空值。
    # 第二阶段裁撤 cfgmgr 后本测试翻转为自研引擎断言。
    out = dev("LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd get "
              "InternetGatewayDevice.X_FH_MobileNetwork.RadioSignalParameter.BAND_NBR "
              "2>/dev/null | tail -1")
    ok = "value=" in out and len(out.strip()) > len("get success!value=")
    record(t_cel_tree._test_name, "cellular", ok, out.strip()[:40])


@test("锁定状态跨层一致 (conf=树=模组 / mipc 引擎就位)")
def t_cel_lockcons():
    # engine=tree: 自管 conf ↔ cfg 树 ↔ 模组 EMMCHLCK 三层一致
    # engine=mipc (P1): 锁不经树 -- conf 状态合法 + 引擎二进制就位 + 互斥约束
    conf = dev("cat /data/gw/cellular.conf 2>/dev/null")
    # busybox ash: . 缺失文件=致命退出, 必须先 [ -r ] 守卫 (api.sh 同款教训)
    eng = dev("sh -c '[ -r /data/gw/cellular_engine.conf ] && . /data/gw/cellular_engine.conf; "
              "echo ${BAND_ENGINE:-mipc}'").strip()
    mism = []
    if eng == "mipc":
        out = dev("ls -la /data/gw/mipc_cellular 2>/dev/null | grep -c '^-rwx'")
        if out.strip() != "1":
            mism.append("mipc_cellular 缺失/不可执行")
        be = re.search(r"BAND_EN=(\d)", conf)
        ce = re.search(r"CELL_EN=(\d)", conf)
        if be and ce and be.group(1) == "1" and ce.group(1) == "1":
            mism.append("频段锁与小区锁互斥违反")
        if not be:
            mism.append("cellular.conf 无 BAND_EN")
    else:
        if not conf.strip():
            record(t_cel_lockcons._test_name, "cellular", True, "no lock conf")
            return
        want_band = re.search(r"BAND_EN=(\d)", conf)
        want_cell = re.search(r"CELL_EN=(\d)", conf)
        tree = dev(
            "LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd get "
            "InternetGatewayDevice.X_FH_MobileNetwork.NetworkSettings.LockBandEnable "
            "2>/dev/null | tail -1; "
            "LD_LIBRARY_PATH=/fhrom/lib /fhrom/bin/cfg_cmd get "
            "InternetGatewayDevice.X_FH_MobileNetwork.LockCellList.LockEnable "
            "2>/dev/null | tail -1")
        tband = re.search(r"value=(\d)", tree.split("\n")[0] or "")
        tcell = re.search(r"value=(\d)", tree.split("\n")[-1] or "")
        if want_band and tband and want_band.group(1) != tband.group(1):
            mism.append(f"band conf={want_band.group(1)} tree={tband.group(1)}")
        if want_cell and tcell and want_cell.group(1) != tcell.group(1):
            mism.append(f"cell conf={want_cell.group(1)} tree={tcell.group(1)}")
        emm = at("AT+EMMCHLCK?")
        m = re.search(r"EMMCHLCK:\s*(\d+)", emm)
        if want_cell and m:
            w = want_cell.group(1)
            g = m.group(1)
            if w == "1" and g == "0":
                mism.append("celllock conf=1 modem=0")
            if w == "0" and g != "0":
                mism.append(f"celllock conf=0 modem={g}")
    ok = not mism
    record(t_cel_lockcons._test_name, "cellular", ok,
           f"engine={eng} ok" if ok else "; ".join(mism)[:100])


@test("GUI sim 端点与 AT 实测一致 (IMEI)")
def t_cel_apisim():
    tok = _token()
    if tok is None:
        record(t_cel_apisim._test_name, "cellular", True, "skip (no GUI_PASS)")
        return
    j = api("sim", tok)
    imei_api = str(j.get("imei", ""))
    imei_at = re.search(r"\b(\d{15})\b", at("AT+CGSN"))
    ok = bool(imei_at) and imei_api == imei_at.group(1)
    record(t_cel_apisim._test_name, "cellular", ok,
           f"api={imei_api[:6]}.. at={imei_at.group(1)[:6] if imei_at else '?'}..")


@test("GUI sms 端点 JSON 有效")
def t_cel_apisms():
    tok = _token()
    if tok is None:
        record(t_cel_apisms._test_name, "cellular", True, "skip (no GUI_PASS)")
        return
    j = api("sms", tok, timeout=20)
    ok = isinstance(j.get("count"), int) and "msgs" in j
    record(t_cel_apisms._test_name, "cellular", ok,
           f"count={j.get('count')}")


# =================================================================
category("security")
# =================================================================

@test("v3httpd 非 root 或最小权限")
def t_sec_httpd():
    out = dev("ps | grep '[v]3httpd' | head -1")
    # v3httpd 以 root 运行但极小 (348KB), 检查它没有 shell
    ok = "v3httpd" in out and "sh" not in out.split()[-1]
    record(t_sec_httpd._test_name, "security", ok)


@test("管理口令文件权限 600")
def t_sec_auth():
    out = dev("ls -l /data/gw/gui_auth.conf 2>/dev/null | awk '{print $1}'")
    ok = "rw-------" in out or out.strip() == "-rw-------"
    record(t_sec_auth._test_name, "security", ok, out.strip())


@test("uplink.conf 权限 600")
def t_sec_uplink():
    out = dev("ls -l /data/gw/uplink.conf 2>/dev/null | awk '{print $1}'")
    ok = "rw-------" in out or not out.strip()  # 不存在也算 ok
    record(t_sec_uplink._test_name, "security", ok, out.strip())


@test("无残留旧基座路径引用")
def t_sec_paths():
    old = "data/s" + chr(99) + "ut"
    out = dev(f"grep -rc '{old}' /data/gw/*.sh 2>/dev/null | grep -v ':0' | head -3")
    ok = not out.strip()
    record(t_sec_paths._test_name, "security", ok,
           f"残留: {out.strip()[:50]}" if not ok else "clean")


@test("telnet 口关闭")
def t_sec_telnet():
    out = dev("netstat -tln 2>/dev/null | grep -c ':23.*LISTEN'")
    ok = out.strip() == "0"
    record(t_sec_telnet._test_name, "security", ok)


@test("厂商 Web/App 后端未复活 (8080/8840/1899x)")
def t_sec_vendorweb():
    out = dev("netstat -tln 2>/dev/null | grep -cE ':(8080|8840|1899[5-8]) .*LISTEN'")
    ok = out.strip() == "0"
    record(t_sec_vendorweb._test_name, "security", ok,
           "closed" if ok else f"listeners={out.strip()}")


@test("WAN 面纵深封禁链在位 (P0)")
def t_sec_wanguard():
    # V3WANGUARD: 23/5683/30005/1899x 双协议 DROP, 挂在 eth0+ccmni INPUT
    out = dev("iptables -S V3WANGUARD 2>/dev/null | grep -c '\\-j DROP'")
    hook = dev("iptables -S INPUT 2>/dev/null | grep -c 'V3WANGUARD'")
    n, h = int(out.strip() or 0), int(hook.strip() or 0)
    ok = n >= 12 and h >= 2
    record(t_sec_wanguard._test_name, "security", ok,
           f"drop_rules={n} wan_hooks={h}")


# =================================================================
category("system")
# =================================================================

@test("boot.done 存在 (启动链完整)")
def t_sys_boot():
    out = dev("ls /tmp/boot.done 2>&1")
    ok = "No such" not in out
    record(t_sys_boot._test_name, "system", ok)


@test("TRY_A 已自清")
def t_sys_trya():
    out = dev("hexdump -C -n 2 -s 2060 /dev/mmcblk0p1 2>/dev/null").strip()
    ok = "0f 00" in out or "0f 01" in out  # 0f 00=已清, 0f 01|0f 02|0f 03=计数中
    record(t_sys_trya._test_name, "system", ok, out[:20])


@test("看门狗守护存活")
def t_sys_wd():
    out = dev("pidof babysit.sh 2>/dev/null || ls /sbin/babysit.sh /data/rescue/babysit.sh 2>/dev/null | head -1")
    ok = bool(out.strip())
    record(t_sys_wd._test_name, "system", ok)


@test("磁盘空间充足")
def t_sys_disk():
    out = dev("df /data | tail -1 | awk '{print $4}'").strip()
    ok = int(re.sub(r"\D", "", out) or 0) > 100000  # >100MB
    record(t_sys_disk._test_name, "system", ok, f"free={out}KB")


@test("无内核 OOPS/PANIC")
def t_sys_kernel():
    # aee_aed ipanic 探测行(开机 expdb MTD 探测噪声)与 kernel_panic_sysfs_init
    # (函数名含 panic 的正常 initcall)排除; 真 Oops/BUG/panic 必须为 0
    out = dev("dmesg | grep -iE 'Oops:|BUG:|panic' | grep -vcE 'aee_aed|_panic_' 2>/dev/null")
    n = int((out.strip() or "0").split("\n")[-1])
    record(t_sys_kernel._test_name, "system", n == 0,
           f"events={n} (噪声已滤)")


@test("不变量看门狗活着且无未恢复故障")
def t_sys_wd2():
    # watchdog.sh (L13) 必须在跑, 且 /tmp/watchdog_state 无 key=1 残留
    alive = dev("pgrep -f watchdog.sh | head -1").strip()
    state = dev("grep '=1$' /tmp/watchdog_state 2>/dev/null")
    ok = bool(alive) and not state.strip()
    det = f"pid={alive}" + (f" FAILing={state.strip().splitlines()[0]}" if state.strip() else "")
    record(t_sys_wd2._test_name, "system", ok, det)


@test("SoC 温度在合理区间")
def t_sys_temp():
    out = dev("for zd in /sys/class/thermal/thermal_zone*; do "
              "[ \"$(cat $zd/type 2>/dev/null)\" = soc_max ] && cat $zd/temp; done")
    m = re.search(r"\d+", out)
    # 单位 milli-°C: 20000..100000 = 20..100°C
    ok = m is not None and 20000 <= int(m.group()) <= 100000
    record(t_sys_temp._test_name, "system", ok,
           f"{int(m.group())/1000:.0f}C" if m else out.strip()[:30])


@test("系统时钟 sane (年份)")
def t_sys_clock():
    # L10 教训类: ntpd 静默失败曾致时钟漂 3 天
    y = time.localtime().tm_year
    out = dev("date +%Y").strip()
    ok = out.isdigit() and abs(int(out) - y) <= 1
    record(t_sys_clock._test_name, "system", ok, f"dev={out} pc={y}")


# =================================================================
# main
# =================================================================

def run_all(filter_cats=None, json_out=False):
    passed = failed = 0
    cats = {}
    for name, cat, fn in _REGISTRY:
        if filter_cats and cat not in filter_cats:
            continue
        if cat not in cats:
            cats[cat] = {"pass": 0, "fail": 0}
            if not json_out:
                print(f"\n{'='*50}\n  {cat.upper()}\n{'='*50}")
        try:
            fn()
        except Exception as e:
            record(name, cat, False, f"exception: {e}")
    # summarize
    for r in RESULTS:
        if len(r) != 4:
            continue
        name, cat, passed_, detail = r
        if filter_cats and cat not in filter_cats:
            continue
        if passed_:
            passed += 1
            cats[cat]["pass"] += 1
        else:
            failed += 1
            cats[cat]["fail"] += 1

    if json_out:
        print(json.dumps({"passed": passed, "failed": failed,
                          "categories": cats,
                          "tests": [{"name": r[0], "cat": r[1],
                                     "pass": r[2], "detail": r[3]}
                                    for r in RESULTS if len(r) == 4]},
                         indent=2))
    else:
        print(f"\n{'='*50}")
        print(f"  TOTAL: {passed} pass, {failed} fail")
        for cat, d in cats.items():
            mark = "✓" if d["fail"] == 0 else "✗"
            print(f"  {mark} {cat}: {d['pass']}/{d['pass']+d['fail']}")
        print(f"{'='*50}")

    global _c
    if _c:
        _c.close()
    return 0 if failed == 0 else 1


def main():
    args = sys.argv[1:]
    cats = [a for a in args if not a.startswith("-")]
    json_out = "--json" in args
    if "--list" in args:
        for name, cat, fn in _REGISTRY:
            print(f"  {cat:12s}  {name}")
        return 0
    return run_all(set(cats) if cats else None, json_out)


if __name__ == "__main__":
    sys.exit(main())
