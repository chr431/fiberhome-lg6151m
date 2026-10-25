#!/usr/bin/env python3
"""selftest.py -- assertion-based functional test suite for the LG6151M gateway.
v2.59 (2026-10-24 USB 轮): +t_usb_service/t_usb_dataplane(USB-C 设备模式:
  守护/UDC 绑定/SVC_TABLE + rndis0 桥接不变量, 按 USB_ENABLED 分档断言);
  t_usb_service 的 all() 误传单布尔已改直接 and 链。

Design principle: L13 (2026-10-05) -- "feature silently broken until manual
inspection" happened three times because we only checked control plane
(process running, port listening) not data plane (does traffic actually
flow through the expected path?). This suite tests BOTH:

  Layer 1  Control plane:   process alive, rule installed, port listening
  Layer 2  Data plane:      actual traffic traverses the expected interface
  Layer 3  Cross-layer:     API report matches kernel/iptables reality
  Layer 4  End-to-end:      from the PC through the gateway to the internet

v2.55 (2026-10-21 SIGSEGV 根因): logc 版本锚点 1.4 + 反链断言(二进制不得再含
  strftime 的 "%0*lld") — 记录路径去 printf 的回归护栏;
v2.54 (2026-10-21 WiFi 事故): +t_wifi_ap_service(活控制套接字/自有 hostapd/
  GUI 与 LED 判据同源); v2.51 (2026-10-20): 控制台 stdout/stderr 显式 UTF-8(GBK 终端下 ✓/✗ 打印不再中断套件). 
v2.50 (2026-10-20 stability P0/P1 batch2): +t_p0_watchdog / t_p0_boot_gate /
  t_p1_singletons / t_p1_forensics / t_p1_healthdog / t_p1_radio / t_p1_logpipe —
  限时检查、boot.healthy 门禁与 TRY_A 读回、统一监督表单实例、core_meta 取证链、
  二级监督、hostapd/wifi_guard 决策硬化、降噪/pstore/BOOT 门禁的回归护栏。
v2.48 (2026-10-20 stability batch1): +t_batch1_watchdog / t_batch1_logc_ntp;
v2.47: t_watchdog_aee 版本锚点随 watchdog v1.27; v2.46: v2.45: v2.44 (SIGSEGV 根治轮): +t_static_toolchain / t_logc /
  t_core_trap / t_watchdog_aee — P1 静态采集器、P2 静态工具链与 PATH 接管、
  P3 core 窗口守护、P4 aee 台账增量判据的回归护栏。
v2.41 (24h 日志轮): +t_v3fix_loaded — v3_fix.ko 必须恰 1 实例在 /proc/modules
  (旧产物 ELF 错位 1B 致每次开机 insmod 静默失败的回归护栏)。
v2.40 (日志加密轮): +t_logging_fine — log_keeper v1.3 增量落盘(stream/1MB 轮转/
  resync) + wan_agg/watchdog 持久化副本含 TICK/EVT 主干行; 24h 分析管线回归护栏。
v2.36 (RIL 清零轮收尾): t_agg_route_landmine 的探活路由断言改"指向任一存活
  ccmni"(v3.1 漂移按探活选口, 不再固定 ccmni2) + t_wan_alive_guard 瞬时窗口
  重采(守护重启边界不再误报 fresh=0)。
v2.35 (RIL 清零轮·终章): t_ril_single 改"RIL 守护全退役"(四件进程+procd 服务
  面零残留) + t_ril_thin 纳入 ql_ril_service + 新增 t_cell_ops_direct(写路径
  直连: endc get/cells 无 fallback + setlock/unlock 结构护栏)。
v2.34 (cells 直连轮): +t_cells_direct(直连解码护栏: 直连预取在位 + 无 fallback
  + JSON 形状完整 — mipc_cellular v0.10, 0x24 TLV 解码)。
v2.33 (RIL 收尾轮): t_ril_single 改"保留件单实例"(仅 ql_ril_service, 含 procd
  服务面在位断言) + 新增 t_ril_thin(ql_netd/mipc_submonitor 退役: 进程/服务面
  双缺席 + cells 查询活 — 拔管实验矩阵的回归护栏)。
v2.32 (netagent 摘除轮): t_ril_single 更名并收缩为三件(netagent 预期缺席) + 新增
  t_netagent_retired(netagent 退役断言: 进程/procd 服务面双缺席 + ccmni_up
  在位且被 keeper/dialer 引用 + 僵尸 IP 触发护栏在位 + 数据面通)。
v2.31: t_ril_single 更名(机制修正: SIGKILL 清场→收编制, 见 rc_netfh v3.6)。
v2.30 (2026-10-17): +t_ril_single — RIL 管道四件(mtk_netagent/ql_netd/
  ql_ril_service/mipc_submonitor)各须恰 1 实例(开机双实例实弹发现的回归护栏)。
v2.29 (2026-10-17 架构轮): 拆分护栏适配 — wan_agg v3.0 播种代码路径改指
  wan_agg_lib.sh(t_agg_pins_seed); wan_alive 的 api 消费方改指 api_sys.sh(v2.75
  域拆分); +t_agg_split(lib 在位且被主管 source/ensure_lease 不在主管) +
  t_agg_eth_daemon(wan_eth 守护活) + t_gui_apimod(六域模块在位+路由引用+
  静态面拒 *.sh 直出回归)。
v2.22 (2026-10-14 同日): 拨号单实例判据随 dial_keeper v1.3 改 PID 锁 — 护栏同步为
  锁 ↔ 活进程跨层一致断言(原脚本文本 grep 退役)。
v2.21 (2026-10-14 模组 EE 事故轮): +5G 指示灯数据面一致性护栏(灯不得在无 5G
  数据时点亮 — 事故里"灯还亮着"是第一手误判源); +拨号守护心跳/超时接线/单实例
  护栏(事故断电窗口零重拨留痕的形态 = 进程在而守护死); +log_keeper 快照转存
  标记(.snap_up)护栏。
v2.20 (2026-10-12): 移除宵断护栏(用户裁定判定不做先验, 先验时段方案整体下架);
v2.19 (2026-10-12): 有线宵断护栏(已随先验方案下架移除) —
  (wan_agg v2.28 时段内强制家宽判死; 上行每晚定时断的确定性转移)。
v2.18 (2026-10-10): +日志持久化护栏 — log_keeper 单实例/镜像新鲜(<120s)/boot
  分隔行在位(重启取证分界)。
v2.17 (2026-10-10): MLO 实况直读(mwctl dump ap_mld: 组号+双链路 BSSID/LinkID 断言,
  旧日志证据链降为回退) + AP 信道配置==实况护栏(驱动 IDC 漂移, watchdog v1.3 同判据)。
v2.16 (2026-10-10): +定时重启护栏(reboot_sched 单实例/API-conf 同源/值域) +
  配置读取同族修复: 'sort -u 任意命中'与'cat settings defaults|tail -1'两类优先级
  盲读收敛到 eff_conf()(settings 覆盖 defaults; 用户 GUI 改 GUEST=0/NTP 后不再误报)
  + token 缺席降级: bad_login/接近锁定(>=8/10)记因 skip, SSE 不再 None.encode() 崩,
  且工具不再把设备推向登录锁定。
v2.15 (2026-10-09): 有线侧探活语义护栏 — authd "up" 不得单独构成活证据
  (v2.26 数据面 ICMP 必叠加: 认证帧在途+数据面已死时 up 永新鲜 = 21:30 实弹
  eth_prio 15h 不转移); authd_state 新鲜度须与数据面一致。
v2.14 (2026-10-08): 蜂窝 conf 白名单 +ENDC_MODE(组网模式, api.sh v2.62); +t_cel_endc
  跨层一致断言(conf=API=模组读回, mipc_cellular v0.8 endc 通道); WiFi FW WARN 继续排除。
v2.13 (2026-10-08): 蜂窝 conf 多写方 schema 适配(锁键∪NM_MODE, api.sh v2.60 cell_set
  upsert 后纯制式态不再误判"无 BAND_EN"); +NTP 自管配置生效断言(defaults叠settings,
  僵尸读回归护栏); +WiFi 固件 WARN 中继(WiFi@WARN.FW,UniCmdResultRsp, 字面 BUG::)
  排除出 OOPS 计数 — 实测>1天 400+ 条而 WiFi/整机全程正常=良性固件噪声。
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
    """Login to gateway API, return the full JSON response
    ({"token":...} on success, {"error":"bad_login"/"locked"/...} otherwise).
    v2.16b: 原只回 token -- 失败与"服务器拒绝"无法区分, 调用方拿到 None 无处归因。"""
    import urllib.parse
    data = f"pass={urllib.parse.quote(password)}".encode()
    req = urllib.request.Request(
        f"http://{lgssh.HOST}/api/login", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"})
    r = urllib.request.urlopen(req, timeout=10)
    return json.loads(r.read())


_TOKEN = ["<unset>"]
_TOKEN_NOTE = [""]   # v2.16b: token 缺席原因, 供 skip 文案(不再裸 "no GUI_PASS")


def _skip_note():
    return _TOKEN_NOTE[0] or "no GUI_PASS"


def _token():
    """Cached GUI token, or None when login is unavailable.

    Mirrors lgssh's secrets resolution (LG_GUI_PASS env or device_local.py;
    v3 GUI key is GW_PASS -- WEB_PASS is the vendor web password).
    v2.16b: 登录失败(bad_login=本地 GW_PASS 与设备不符, 用户改口令后必现)与
    接近锁定阈值(>=8/10)时返回 None 并记因 — 调用方以 skip 呈现, 同时避免
    把设备推向 10次/15min 登录锁定(工具自伤用户登录)。
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
    tok = None
    if pw:
        fc = dev("cat /tmp/gui_auth.fails 2>/dev/null").strip().split()
        n = int(fc[0]) if fc and fc[0].isdigit() else 0
        if n >= 8:
            _TOKEN_NOTE[0] = f"设备登录失败计数 {n}/10 接近锁定, 跳过登录"
        else:
            j = get_token(pw)
            tok = j.get("token")
            if tok is None:
                _TOKEN_NOTE[0] = f"login {j.get('error', '?')}: 本地 GW_PASS 与设备不符(用户已改口令?)"
    _TOKEN[0] = tok
    return tok


def eff_conf(keys):
    """持有效配置 (defaults 叠 settings, settings 覆盖) — 与设备侧 cfg_load 同序:
    同键取 settings 中的值, 缺省回退 defaults。返回 {KEY: value}。
    v2.16b: 修同族优先级盲读 — 原 'sort -u + 任意命中'(t_wifi_bss/guest/mlo/cross
    见 defaults 的 GUEST=1 即判访客开, 用户在 GUI 改 GUEST=0 后 4 测试齐红)与
    'cat settings defaults | tail -1'(恒取默认值, settings 覆盖被无视)均误报;
    语义与 t_wifi_bwcons 的 head -1 对齐。"""
    out = dev("cat /data/gw/settings.conf /data/gw/defaults.conf 2>/dev/null | "
              "grep -E '^(%s)='" % "|".join(keys))
    eff = {}
    for line in out.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            k = k.strip()
            if k not in eff:          # settings 文件在前: 首次出现 = 持有效值
                eff[k] = v.strip()
    return eff


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

@test("BSS 接口集合与访客配置一致 (v1.17 配置感知)")
def t_wifi_bss():
    # v2.2: 访客可开在 ra1(2g)/rai1(5g)/双频(both)或关闭 — 期望集合由 settings 推出,
    # 并断言"该在的在、不该在的不在"(防残留 iface 与漏建)
    # v2.16b: 持有效值读取(settings 覆盖 defaults) — 原 union 盲读在 GUEST=0 后误报
    eff = eff_conf(["GUEST", "GUEST_BAND", "GUEST_PASS"])
    guest = eff.get("GUEST") == "1"
    gband = eff.get("GUEST_BAND") or "5g"
    has_pass = len(eff.get("GUEST_PASS", "")) >= 2
    want = {"ra0", "rai0"}
    if guest and has_pass:
        if gband in ("2g", "both"):
            want.add("ra1")
        if gband in ("5g", "both"):
            want.add("rai1")
    out = dev("iw dev 2>/dev/null | awk '/Interface/{print $2}' | grep -E '^ra' | sort | tr '\\n' ' '")
    have = set(out.split())
    ok = have == want
    record(t_wifi_bss._test_name, "wifi", ok,
           f"want={sorted(want)} have={sorted(have)}" if not ok else
           f"ifaces={sorted(have)} guest={bool(guest and has_pass)} band={gband}")


@test("WiFi AP 服务真实在线 (活控制套接字, 非 type AP)")
def t_wifi_ap_service():
    # 2026-10-21 事故: hostapd SIGSEGV 后驱动仍保持 AP 模式、控制 socket 文件
    # 残留、厂商 global hostapd 仍活 —— 旧的 iw "type AP"/-S/pidof hostapd 判据
    # 全部为真, WiFi 实际死了 5.5h 而 GUI/灯/看门狗一致报"正常"。
    # 真相 = 我们的 hostapd 进程 + /proc/net/unix 里的活控制套接字。
    live = dev("for i in ra0 rai0; do "
               "awk -v p=/var/run/hostapd/$i '$NF==p{f=1} END{print f?1:0}' /proc/net/unix; "
               "done").split()
    # the shared helper is also the production identity rule (argv[0]+config+exe)
    ours = dev(". /data/gw/svc_lib.sh; svc_our_hostapd | head -1").strip()
    cli = dev("for i in ra0 rai0; do "
              "hostapd_cli -i $i status 2>/dev/null | grep -c '^state=ENABLED'; done").split()
    lib = dev("grep -c '/proc/net/unix' /data/gw/svc_lib.sh 2>/dev/null").strip()
    pidof = dev("grep -c 'pidof hostapd' /data/gw/svc_lib.sh 2>/dev/null").strip()
    gui = dev("grep -c '/proc/net/unix' /data/gw/www/api_wifi.sh 2>/dev/null").strip()
    led = dev("grep -c 'svc_bss_count' /data/gw/led_mgr.sh 2>/dev/null").strip()
    ok = (live == ["1", "1"] and ours.isdigit() and cli == ["1", "1"]
          and int(lib or 0) > 0 and pidof == "0"
          and int(gui or 0) > 0 and int(led or 0) > 0)
    record(t_wifi_ap_service._test_name, "wifi", ok,
           "live=%s ours=%s cli=%s lib_unix=%s pidof=%s gui_unix=%s led_bss=%s"
           % (live, ours or "-", cli, lib, pidof, gui, led))


@test("访客 BSS 配置/隔离防火墙一致 (guest_fw)")
def t_wifi_guest():
    # v2.16b: 持有效值读取(原 union 盲读 GUEST=1 在用户关闭访客后误报)
    eff = eff_conf(["GUEST", "GUEST_BAND", "GUEST_SSID", "GUEST_PASS"])
    # v2.8: guest 有效 = GUEST=1 且有密码(无密码时 wifi_up 不建访客BSS — 首刷默认态即此)
    guest = eff.get("GUEST") == "1" and len(eff.get("GUEST_PASS", "")) >= 2
    hap2 = dev("grep -c '^bss=' /var/wlan/hap_2g.conf 2>/dev/null").strip() or "0"
    hap5 = dev("grep -c '^bss=' /var/wlan/hap_5g.conf 2>/dev/null").strip() or "0"
    fw = dev("ebtables -L 2>/dev/null | grep -c 'Bridge chain: WIFI_GUEST_'").strip()  # v1.2: filter表(不再用broute)
    # v2.11: 访客隔离强制开启(开关已删, guest_fw v1.6) — 有访客必有隔离链
    ssid_lines = dev("iw dev 2>/dev/null | grep -c ssid").strip()
    notes = f"hap2_bss={hap2} hap5_bss={hap5} guest_chains={fw} ssid_lines={ssid_lines}"
    if guest:
        # v2.11: 隔离无条件 — 每访客iface两条链(FORWARD+INPUT), both/5g=2 iface=4, 单频=2
        hap_sum = int(hap2) + int(hap5)
        ok = fw in ("2", "4") and hap_sum >= 1
        eb_in = dev("ebtables -L INPUT 2>/dev/null | grep -c 'WIFI_GUEST_'").strip()
        if eb_in == "0":
            ok = False
            notes += " NO_EBT_INPUT_CHAIN"
        # v2.5: 访客iface必须在br-lan里(hostapd动态BSS不自动入桥 — 不入桥则帧死在
        # 无IP接口, dnsmasq收不到DISCOVER, 手机卡获取IP; v1.22起wifi_up显式入桥)
        brports = dev("brctl show br-lan 2>/dev/null | awk '{print $NF}' | grep -E '^ra' | sort | tr '\\n' ' '")
        conf2 = eff.get("GUEST_BAND") or "5g"
        want_ports = set(["ra0", "rai0"])
        if conf2 in ("2g", "both"):
            want_ports.add("ra1")
        if conf2 in ("5g", "both"):
            want_ports.add("rai1")
        have_ports = set(brports.split())
        if have_ports != want_ports:
            ok = False
            notes += f" bridge_want={sorted(want_ports)} have={sorted(have_ports)}"
        # L14实弹教训(v1.1): bridge-nf=1 下桥接 DHCP 广播本地投递走 iptables
        # INPUT(physdev-in=访客口) — 隔离链必须白名单 DHCP/DNS, 否则手机卡"获取IP"
        for gif in ("ra1", "rai1"):
            chain = dev(f"iptables -S WIFI_GUEST_{gif} 2>/dev/null")
            if chain:
                if "--dport 67:68 -j ACCEPT" not in chain or "--dport 53 -j ACCEPT" not in chain:
                    ok = False
                    notes += f" {gif}:NO_DHCP_DNS_WHITELIST"
                break
    else:
        ok = hap2 == "0" and hap5 == "0" and fw == "0"
    record(t_wifi_guest._test_name, "wifi", ok, notes)


@test("MLO 状态与 dat 键一致 (v1.19)")
def t_wifi_mlo():
    # v2.4: MLO=1 -> 两带 dat 各有 1基组表(stock形态); MLO=0 -> 键必须整体缺失
    #   (键存在但全零=v1.15事故形态, 当场红)
    # v2.17: 实况直读 — mwctl dump ap_mld 的 stdout(RE 实证: dump 段走 MTK vendor
    #   netlink 封装输出干净; show 段输出进 dmesg 不可脚本化)。断言: 组号 1 +
    #   恰好 2 个 Affiliated AP, BSSID 集合=={ra0,rai0} MAC, LinkID 集合=={0,1}。
    #   旧日志证据链保留为 mwctl 不可用时的回退(不误红)。
    mlo = eff_conf(["MLO"]).get("MLO") == "1"   # v2.16b: 持有效值(原 union 盲读)
    g2 = dev("grep -h '^MldGroup=' /var/wlan/apcfg 2>/dev/null").strip()
    g5 = dev("grep -h '^MldGroup=' /var/wlan/apcfg_5 2>/dev/null").strip()
    out = dev("/usr/sbin/mwctl ra0 dump ap_mld all 2>&1")
    grp = re.search(r"AP MLD group id:(\d+)", out)
    bssids = [b.lower() for b in re.findall(r"BSSID ([0-9a-fA-F:]{17})", out)]
    links = re.findall(r"Link ID (\d+)", out)
    notes = f"mlo={int(mlo)} apcfg='{g2}' apcfg_5='{g5}'"
    if mlo:
        # v1.21: 访客BSS静态单链路组(2.4G访客token=17, 5G=18), 主BSS恒为组1
        t2 = g2.removeprefix("MldGroup=")
        t5 = g5.removeprefix("MldGroup=")
        cfg_ok = re.fullmatch(r"1;(17|0);0;0;0;0;0;0", t2) is not None and \
                 re.fullmatch(r"1;(18|0);0;0;0;0;0;0", t5) is not None
        mac0 = dev("cat /sys/class/net/ra0/address 2>/dev/null").strip().lower()
        mac5 = dev("cat /sys/class/net/rai0/address 2>/dev/null").strip().lower()
        live_ok = (grp is not None and grp.group(1) == "1" and len(bssids) == 2
                   and set(bssids) == {mac0, mac5} and sorted(links) == ["0", "1"])
        notes += f" live_grp={grp.group(1) if grp else '-'} links={links} bssids={len(bssids)}"
        if grp is None:
            # 回退: mwctl 不可用/无输出 → 日志证据链(同 v2.16b)
            mld = dev("cat /tmp/mld_boot.log 2>/dev/null | wc -l").strip()
            if int(mld or 0) == 0:
                mld = dev("grep -cE 'Create AP MLD|join MLD|Alloc ML Group|hostapd_event_bss_mlo_info' "
                          "/tmp/wifi_up.log 2>/dev/null").strip()
            if int(mld or 0) == 0:
                mld = dev("dmesg | grep -cE 'Create AP MLD|join MLD|Alloc ML Group|hostapd_event_bss_mlo_info'").strip()
            bad = dev("dmesg | grep -c 'Create AP MLD, grp(0)'").strip()
            snap_bad = str(sum(int(dev(f"grep -c 'Create AP MLD, grp(0)' {f} 2>/dev/null").strip() or 0)
                               for f in ("/tmp/mld_boot.log", "/tmp/wifi_up.log")))
            notes += f" fallback mld_logs={mld} grp0={bad}/{snap_bad}"
            live_ok = int(mld.strip() or 0) >= 1 and bad == "0" and snap_bad == "0"
        ok = cfg_ok and live_ok
    else:
        ok = g2 == "" and g5 == "" and grp is None
        notes += f" live_mld={'present!' if grp else 'none'}"
    record(t_wifi_mlo._test_name, "wifi", ok, notes)


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
    kern = dev("iw dev 2>/dev/null | grep -c 'type AP'").strip()
    # v2.2: 期望数配置感知 (主双BSS + 访客按频段开关)
    # v2.16b: 持有效值读取(原 union 盲读 GUEST=1 在用户关闭访客后误报 want=4)
    eff = eff_conf(["GUEST", "GUEST_BAND", "GUEST_PASS"])
    guest = eff.get("GUEST") == "1"
    gband = eff.get("GUEST_BAND") or "5g"
    has_pass = len(eff.get("GUEST_PASS", "")) >= 2
    want = 2
    if guest and has_pass:
        want += 2 if gband == "both" else 1
    hap = dev("ps | grep -c '[h]ostapd -B'").strip()
    ok = kern == str(want) and hap == "1"
    record(t_wifi_cross._test_name, "wifi", ok,
           f"kernel={kern} want={want} hostapd_procs={hap}")


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


@test("AP 信道配置==实况 (IDC 漂移护栏)")
def t_wifi_chcons():
    # v2.17: 驱动 IDC(LTE 共存避让)可在运行期自行搬道(实测), 生成配置的
    #   channel= 必须与实况一致(watchdog v1.5 同判据, 不一致会被它回写+记警)
    # v2.19b: 驱动搬道 → watchdog 回写存在 ≤30s 滞后, 期间读数天然不一致 —
    #   不一致时隔一轮 watchdog 周期(35s)复核一次再判, 只拦持续漂移
    ok = True
    notes = []
    attempt = 1
    for attempt in (1, 2):
        ok = True
        notes = []
        for b, vif in (("2g", "ra0"), ("5g", "rai0")):
            live = dev(f"iw dev {vif} info 2>/dev/null | awk '/channel/{{print $2}}'").strip()
            conf = dev(f"grep -m1 '^channel=' /var/wlan/hap_{b}.conf 2>/dev/null | cut -d= -f2").strip()
            notes.append(f"{b}:conf={conf or '?'}/live={live or '?'}")
            if not live or not conf or live != conf:
                ok = False
        if ok or attempt == 2:
            break
        time.sleep(35)
    record(t_wifi_chcons._test_name, "wifi", ok,
           " ".join(notes) + (f" attempt={attempt}" if attempt == 2 else ""))


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
    # v2.8: 公开套件默认无插件 — 404 视为"未部署, 跳过"(记 pass, 注明); 有则校验内容
    try:
        r = urllib.request.urlopen(f"http://{lgssh.HOST}/plugins.js", timeout=5)
        body = r.read().decode()
        ok = "LG_plugin" in body
        note = "plugin present"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            record(t_gui_plugin._test_name, "gui", True, "no plugin deployed (public kit)")
            return
        ok = False; note = f"HTTP {e.code}"
    except Exception:
        ok = False; note = "unreachable"
    record(t_gui_plugin._test_name, "gui", ok, note)


@test("API 域模块在位且静态面拒绝直出 (v2.75 拆分护栏)")
def t_gui_apimod():
    # v2.29 (api v2.75 架构轮): 路由懒加载六域模块 — 断言:
    #   ① 六模块在设备上在位(api.sh 只剩路由, 模块缺席=全部端点 unknown);
    #   ② api.sh 路由确实引用模块(拆分接线在);
    #   ③ 静态面拒绝 *.sh 直出(v3httpd v2.6; 模块与 CGI 同目录, 直出=免认证
    #      泄露服务端逻辑 — 拆分后受保护面扩大, 此回归必须钉住)。
    mods = ["api_sys.sh", "api_wifi.sh", "api_lan.sh",
            "api_agg.sh", "api_cell.sh", "api_sms.sh"]
    missing = [m for m in mods
               if dev(f"[ -s /data/gw/www/{m} ] && echo y").strip() != "y"]
    router = dev("grep -c 'api_sys.sh' /data/gw/www/api.sh 2>/dev/null").strip()
    leaked = []
    for m in ("api.sh", "api_cell.sh", "api_sys.sh"):
        try:
            urllib.request.urlopen(f"http://{lgssh.HOST}/{m}", timeout=5)
            leaked.append(f"{m}:200")   # 200 = 服务端脚本被直出
        except urllib.error.HTTPError as e:
            if e.code != 404:
                leaked.append(f"{m}:{e.code}")
        except Exception as e:
            leaked.append(f"{m}:{type(e).__name__}")
    ok = not missing and router not in ("", "0") and not leaked
    record(t_gui_apimod._test_name, "gui", ok,
           f"missing={missing or 0} router_refs={router} leaked={leaked or 0}")


@test("SSE 信号事件流 (v3httpd v2.5 + api.sh sse token 门)")
def t_gui_sse():
    # v2.9: 原始 socket 拉 /api/sse, 5s 内应收到带 rsrp 的 data: 事件
    # v2.12(P1): sse 已加 token 门 — 先验无 token 被拒, 再验带 token 出流
    import socket as sk
    try:
        s = sk.create_connection((lgssh.HOST, 80), timeout=5)
        s.settimeout(3)
        s.send(b"GET /api/sse HTTP/1.0\r\nHost: 192.168.9.1\r\n\r\n")
        head = b""
        try:
            while len(head) < 2048:
                d = s.recv(512)
                if not d:
                    break
                head += d
                if b"need_login" in head:
                    break
        except Exception:
            pass
        s.close()
        no_tok_ok = b"need_login" in head   # 头之后跟 need_login JSON(SSE 头由 v3httpd 先行)
        tok = _token()
        if tok is None:
            # v2.16b: 原 tok.encode() 直接崩(AttributeError)记红 — 无 token 时
            # 无 token 拒绝断言已成立, 带 token 流出部分降级为 skip
            record(t_gui_sse._test_name, "gui", no_tok_ok,
                   f"无token拒绝={'ok' if no_tok_ok else 'FAIL'} (skip 带token流: {_skip_note()})")
            return
        s = sk.create_connection((lgssh.HOST, 80), timeout=5)
        s.settimeout(6)
        s.send(b"GET /api/sse?token=" + tok.encode() + b" HTTP/1.0\r\nHost: 192.168.9.1\r\n\r\n")
        buf = b""
        t0 = time.time()
        while time.time() - t0 < 6:
            try:
                d = s.recv(4096)
            except Exception:
                break
            if not d:
                break
            buf += d
            if b"rsrp" in buf:
                break
        s.close()
        ok = no_tok_ok and b"text/event-stream" in buf and b"data: " in buf and b"rsrp" in buf
        note = f"{len(buf)}B notok={'Y' if no_tok_ok else 'N'}" + ("" if ok else f" head={buf[:60]!r}")
    except Exception as e:
        ok, note = False, repr(e)[:60]
    record(t_gui_sse._test_name, "gui", ok, note)


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
        record(t_gui_endpoints._test_name, "gui", True, f"skip ({_skip_note()})")
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


@test("wan_agg 拆分件在位 (lib 被 source + eth0 归属移交)")
def t_agg_split():
    # v2.29 (wan_agg v3.0 架构轮): 引擎库与 eth0 守护拆出 — 断言拆分后结构完整:
    #   ① lib 在位且被主管 source(路径引用在); ② wan_agg 不再自带 ensure_lease
    #      (eth0 归 wan_eth, 若回流=双写方); ③ 探活/FSM 仍在主管(核心职责未漂移)。
    lib_ref = dev("grep -c 'wan_agg_lib' /data/gw/wan_agg.sh 2>/dev/null").strip()
    lib_ok = dev("[ -s /data/gw/wan_agg_lib.sh ] && echo y").strip()
    nold = dev("grep -c 'ensure_lease()' /data/gw/wan_agg.sh 2>/dev/null").strip()
    fsm = dev("grep -c 'prim_want' /data/gw/wan_agg.sh 2>/dev/null").strip()
    ok = (lib_ref not in ("", "0") and lib_ok == "y"
          and nold == "0" and fsm not in ("", "0"))
    record(t_agg_split._test_name, "agg", ok,
           f"lib_ref={lib_ref} lib={lib_ok} ensure_lease_in_wan_agg={nold} fsm_in_wan_agg={fsm}")


@test("wan_eth 守护进程存活 (有线 WAN 接口管理)")
def t_agg_eth_daemon():
    # v2.29 (架构轮): wan_eth 自 wan_agg ensure_lease 拆出 — eth0 租约/NAT/路由
    #   看门狗的唯一写方; 死则家宽侧静默劣化(watchdog v1.12 30s 兜底拉起)。
    out = dev("ps | grep -c '[w]an_eth.sh'")
    ok = out.strip() not in ("0", "")
    record(t_agg_eth_daemon._test_name, "agg", ok,
           "alive" if ok else "wan_eth dead (rc19/watchdog 应拉起)")


@test("分流规则已安装 (模式感知)")
def t_agg_rules():
    # v2.10: weight 模式须有 sport 分界(tcp+udp各2); 优先/仅模式为单路全量 MARK 规则
    md = dev("grep -m1 '^MODE=' /data/gw/agg.conf 2>/dev/null | cut -d= -f2").strip() or "weight"
    mk = dev("iptables -t mangle -S WANAGG 2>/dev/null | grep -c 'MARK'").strip()
    if md == "weight":
        n = int(dev("iptables -t mangle -S WANAGG 2>/dev/null | grep -cE 'sport.*MARK'").strip() or 0)
        ok = n >= 4 and int(mk or 0) >= 4
        record(t_agg_rules._test_name, "agg", ok, f"mode={md} sport={n}")
    else:
        ok = int(mk or 0) >= 1
        record(t_agg_rules._test_name, "agg", ok, f"mode={md} mark_rules={mk}")


@test("fwmark 策略路由存在 (v4)")
def t_agg_fwmark():
    out = dev("ip rule | grep -c fwmark")
    n = int(out.strip() or 0)
    ok = n >= 1  # 至少 1 条 (主备模式可能只有单侧)
    record(t_agg_fwmark._test_name, "agg", ok, f"fwmark_rules={n}")


@test("聚合模式配置合法且一致 (v2.18 五模式)")
def t_agg_mode_cons():
    md = dev("grep -m1 '^MODE=' /data/gw/agg.conf 2>/dev/null | cut -d= -f2").strip()
    w1 = dev("grep -m1 '^W1_PCT=' /data/gw/agg.conf 2>/dev/null | cut -d= -f2").strip()
    ok = md in ("weight", "cell_prio", "eth_prio", "cell_only", "eth_only")
    note = f"mode={md} w1={w1}"
    if ok and md == "weight":
        ok = w1.isdigit() and 5 <= int(w1) <= 95   # 滑块钳制域
    # wan_agg 进程内的 pmode 无法直读, 用行为侧面: 非weight模式不应存在sport分界
    if ok and md != "weight":
        sport = int(dev("iptables -t mangle -S WANAGG 2>/dev/null | grep -cE 'sport.*MARK'").strip() or 0)
        ok = sport == 0
        note += f" sport={sport}"
    record(t_agg_mode_cons._test_name, "agg", ok, note)


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
    _if = _cell_iface()
    out = dev(f"ping -c 3 -W 2 -I {_if} 223.5.5.5 2>&1 | tail -2") if _if else "no live ccmni"
    m = re.search(r"(\d+) packets? received", out)
    ok = m is not None and int(m.group(1)) >= 1
    record(t_agg_5g_dp._test_name, "agg", ok,
           m.group(0) if m else out.strip().replace("\n", " ")[:50])


@test("有线侧探活语义护栏 (up 必叠加数据面 ICMP)")
def t_agg_w2_probe_guard():
    # 2026-10-09 21:30 实弹回归护栏: authd "up" 曾被当作充分活证据 ——
    # succ 永不复位 + 服务器周期性 Req-Identity 持续刷新 up, 认证帧在途而数据面
    # 已死时 wan_agg 恒判活, eth_prio 下 5G 待命侧 15h 无接班机会。断言两处:
    #   1) 设备端脚本语义: w2_alive 不得出现"up 直接 return 0"的裸判活
    #   2) 状态一致: authd_state=up 时数据面(eth0 ICMP)必须通(否则 = 假活态)
    src = dev("grep -n 'AUTHD_UP' /data/gw/wan_agg.sh 2>/dev/null")
    bare = re.search(r'AUTHD_UP.*return 0\s*$', src, re.M) and \
        not re.search(r'AUTHD_UP.*w2_data_alive', src)
    mism = []
    if bare:
        mism.append("w2_alive: up 仍是裸判活(未叠加数据面)")
    st = dev("cat /tmp/authd_state 2>/dev/null").split()
    if st and st[0] == "up":
        try:
            age = int(time.time()) - int(st[1])
        except (IndexError, ValueError):
            age = 999
        # v2.15 修正(实测修正: 转移进行中不是故障) ——
        #   up 新鲜(<60s)而 eth0 不通, 若此时状态机正在切换(wan_mode 或日志近 30s
        #   有 state 行), 属"正确转移中"; 只在**稳定态**下判定假活, 否则误报。
        if age <= 60:
            mode = dev("cat /tmp/wan_mode 2>/dev/null").strip()
            switched = bool(re.search(r"state:", dev(
                "tail -6 /tmp/wan_agg.log 2>/dev/null | grep -c state")))
            if mode.endswith(":0") and not switched:   # 仍在以太且刚切换过=过渡期
                switched = True
            dp = dev("ping -4 -I eth0 -c2 -W2 -s1 223.5.5.5 2>&1 | grep -c 'packets received'")
            rx = re.search(r"(\d+)", dp or "")
            if rx is None or int(rx.group(1)) == 0 and not switched:
                mism.append(f"authd up({age}s) 但 eth0 数据面不通且未在转移 = 假活态")
    record(t_agg_w2_probe_guard._test_name, "agg", not mism,
           "ok" if not mism else "; ".join(mism)[:90])


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


@test("RIL 守护全退役 (ql_ril_service/netd/submonitor/netagent)")
def t_ril_single():
    # v2.30 (2026-10-17 实弹发现): rc_netfh 开机"清场重拉"致 mtk_netagent/
    #   ql_netd/ql_ril_service 各存活两套(rc.d S22/S85 + rc_netfh 各一套) —
    #   双实例 = 未被理解的控制面冗余(ubus 仅一套注册成功另一套空转, 双 netagent
    #   同消费 netlink, 状态机深处竞态窗口未知)。
    # v3.1 (机制修正): v3.5 的 SIGKILL 清场被 procd respawn 层推翻(杀掉必复活,
    #   且 rc_netfh 与 S22/S85 并发起跑); rc_netfh v3.6 终版 = 收编制(等 rc.d
    #   套就绪只补缺席)。本护栏断言四件各恰 1 实例。
    #   (pidof 按 comm 匹配, 远端包装 shell comm="sh" 无自匹配问题。)
    # v2.35 (RIL 清零轮·终章): 读路径(cells/getbands)+写路径(setlock/endc/scan/
    #   短信)已全部直连 MIPC(mipc_cellular v0.11), ql_ril_service 与其余 RIL
    #   守护全部退役。断言: 四件进程零残留 + procd 服务面零残留。
    bad = []
    for n, svc in (("ql_ril_service", "ql_ril_service"), ("ql_netd", "ql_netd"),
                   ("mipc_submonitor", "mipc_submonitor.init"), ("mtk_netagent", "mtk_netagent")):
        c = dev(f"pidof {n} | wc -w").strip()
        if c != "0":
            bad.append(f"{n}x{c}")
        s = dev(f"ubus call service list 2>/dev/null | grep -c '\"{svc}\"'").strip()
        if s not in ("", "0"):
            bad.append(f"{svc}-svc")
    record(t_ril_single._test_name, "cellular", not bad,
           "all retired (proc=0 svc=0)" if not bad else "; ".join(bad))


@test("RIL 瘦身终态 (ql_netd/mipc_submonitor 退役)")
def t_ril_thin():
    # v2.33 (2026-10-17 RIL 收尾轮, 拔管实验): 8 项功能矩阵(AT/SIM/信号/APN/
    #   cells/bands/短信/数据面)逐件拔管实证 ql_netd 与 mipc_submonitor 零依赖;
    #   拨号终证 = 目标终态飞行往返 t+61s 自愈。退役 = rc_netfh v3.8 开机
    #   service delete + SIGKILL。ql_ril_service 保留(mipc_cellular cells 的
    #   ql_nw 路径唯一依赖 — 拔之 cells 恒返 -2147024889)。
    # 断言: ① 两件进程+procd 服务面双缺席; ② cells 查询活(保留件功能性)。
    bad = []
    for n, svc in (("ql_ril_service", "ql_ril_service"), ("ql_netd", "ql_netd"),
                   ("mipc_submonitor", "mipc_submonitor.init")):
        c = dev(f"pidof {n} | wc -w").strip()
        s = dev(f"ubus call service list 2>/dev/null | grep -c '\"{svc}\"'").strip()
        if c != "0":
            bad.append(f"{n}x{c}")
        if s not in ("", "0"):
            bad.append(f"{svc}-svc-present")
    cells = dev("/data/gw/mipc_cellular cells 2>/dev/null | head -c 40").strip()
    if '"serving"' not in cells:
        bad.append("cells-dead")
    record(t_ril_thin._test_name, "cellular", not bad,
           f"netd=0 submon=0 cells=ok {cells[:24]}" if not bad else "; ".join(bad))


@test("cells 直连解码 (mipc_cellular 0x23→0x24 TLV)")
def t_cells_direct():
    # v2.34 (2026-10-17 反编译攻坚轮): ql_ril_service 的 cells 解码逻辑已由
    #   反汇编还原(_re C_cells_decode: TLV 层 + NR 记录 0xB8 布局 + 编码公式
    #   rsrp=raw-156 / sinr=raw/2-43), mipc_cellular v0.10 直连主路径上线,
    #   libqlril 仅作回退。断言: ① 直连预取真实发生(bin 落盘); ② 无 fallback
    #   (stderr 无标记); ③ JSON 形状完整(serving/cells/n)。
    dev("rm -f /tmp/cells_direct.bin /tmp/cd.err")
    out = dev("/data/gw/mipc_cellular cells 2>/tmp/cd.err").strip()
    bin_ok = dev("[ -s /tmp/cells_direct.bin ] && echo y").strip()
    err = dev("cat /tmp/cd.err 2>/dev/null").strip()
    ok = (bin_ok == "y" and "fallback" not in err
          and '"serving"' in out and '"cells"' in out and '"n"' in out
          and "error" not in out)
    n = re.search(r'"n":(\d+)', out)
    record(t_cells_direct._test_name, "cellular", ok,
           f"bin={bin_ok} fallback={'no' if 'fallback' not in err else 'YES'} n={n.group(1) if n else '?'}"
           if ok else f"bin={bin_ok} err={err[:40]} out={out[:40]}")


@test("蜂窝写路径直连 (endc/setlock/unlock)")
def t_cell_ops_direct():
    # v2.35 (RIL 清零轮): 写路径 setlock 0x33 / endc get 0x51 / endc set 0x2D 已
    #   直连(线上格式抓包实证, 位映射 n-1/n-33/n-65 修正旧 off-by-one)。
    #   断言(只读语义): ① endc get 返回 ret=0 且含 nr_disable_mode; ② cells 无
    #   fallback; ③ unlock 幂等成功(ret=0)。
    eg = dev("/data/gw/mipc_cellular endc get 2>/dev/null").strip()
    cells = dev("/data/gw/mipc_cellular cells 2>/tmp/ce.err | head -c 40").strip()
    err = dev("cat /tmp/ce.err 2>/dev/null").strip()
    ul = dev("/data/gw/mipc_cellular unlock 2>&1 | grep -c 'ret=0'").strip()
    ok = ('"ret":0' in eg and 'nr_disable_mode' in eg
          and '"serving"' in cells and 'fallback' not in err
          and ul not in ("", "0"))
    record(t_cell_ops_direct._test_name, "cellular", ok,
           f"endc={eg[:34]} unlock={ul}" if ok else f"endc={eg[:30]} cells={cells[:24]} ul={ul}")


@test("mtk_netagent 退役 (ccmni_up 接管落地)")
def t_netagent_retired():
    # v2.32 (2026-10-17 netagent 摘除轮): 实证 netagent 是 ccmni IP 执行者(act
    #   响应含 v4/v6 全套地址而无人落地 — 无它时拨号 result:0 接口挂僵尸旧 IP)。
    #   退役设计: rc_netfh v3.7 开机 ubus service delete(procd 不再看护)+SIGKILL
    #   收尾; 职能由自研 ccmni_up.sh 承接(dial_keeper/dial_5g 共用)。
    # 断言: ① 进程与 procd 服务面双缺席; ② ccmni_up 在位且被 keeper/dialer 引用;
    #   ③ keeper 僵尸 IP 触发护栏在位(消费 wan_alive — 飞行模式往返僵尸 IP 洞);
    #   ④ 蜂窝数据面通(退役未破坏功能)。
    proc = dev("pidof mtk_netagent | wc -w").strip()
    svc = dev("ubus call service list 2>/dev/null | grep -c mtk_netagent").strip()
    cup = dev("[ -x /data/gw/ccmni_up.sh ] && echo y").strip()
    ref = dev("grep -c ccmni_up /data/gw/dial_keeper.sh /data/gw/dial_5g.sh 2>/dev/null | awk -F: '{s+=$2} END{print s}'").strip()
    zomb = dev("grep -c 'wan_alive' /data/gw/dial_keeper.sh 2>/dev/null").strip()
    cif = _cell_iface()
    dp = dev(f"ping -4 -I {cif} -c2 -W2 223.5.5.5 2>&1 | grep -c 'packets received'").strip() if cif else "0"
    bad = []
    if proc != "0":
        bad.append(f"proc=x{proc}")
    if svc not in ("0", ""):
        bad.append("procd-svc-present")
    if cup != "y":
        bad.append("ccmni_up-missing")
    if not ref.isdigit() or int(ref) < 2:
        bad.append(f"wiring={ref}")
    if zomb in ("", "0"):
        bad.append("zombie-guard-missing")
    if dp == "0":
        bad.append("dataplane-dead")
    record(t_netagent_retired._test_name, "cellular", not bad,
           f"proc=0 svc=0 cup={cup} wiring={ref} zguard={zomb} dp={dp}"
           if not bad else "; ".join(bad))


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


@test("蜂窝引擎小区列表活着 (P3 终章)")
def t_cel_tree():
    # v1.10 起: cfg 树已整体退役(rc_netfh v3.1) — 断言翻转为自研引擎:
    # mipc_cellular cells 返回服务小区(N41 带号) + 邻区列表。
    out = dev("/data/gw/mipc_cellular cells 2>/dev/null | head -c 400")
    ok = '"band":"N' in out and '"cells":[' in out
    record(t_cel_tree._test_name, "cellular", ok,
           out.strip()[:60] if not ok else "engine ok")


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
        if not dev("ls /data/gw/cellular_replay.sh 2>/dev/null").strip():
            mism.append("cellular_replay.sh 缺失(conf 为其开机重放源)")
        # v2.13: conf 是多写方共享文件(api.sh v2.60 cell_set 统一 upsert):
        #   键集合 {BAND_EN,LTE_MASK,NR_MASK,CELL_EN,CELL_i,NM_MODE}; 无锁键但含
        #   NM_MODE = 合法"未设锁"态(原判"非空必含 BAND_EN"误伤纯制式设置)。
        lines = [l for l in conf.splitlines() if l.strip()]
        keys = [l.split("=", 1)[0] for l in lines if "=" in l]
        dup = sorted({k for k in keys if keys.count(k) > 1})
        if dup:
            mism.append("重复键:" + ",".join(dup))
        bad = [l for l in lines if "=" not in l or not re.match(
            r"^(BAND_EN|LTE_MASK|NR_MASK|CELL_EN|NM_MODE|ENDC_MODE|CELL_[0-9]+)=", l)]
        if bad:
            mism.append("conf 非法行:" + bad[0][:24])
        be = re.search(r"^BAND_EN=([01])$", conf, re.M)
        ce = re.search(r"^CELL_EN=([01])$", conf, re.M)
        if re.search(r"^BAND_EN=", conf, re.M) and not be:
            mism.append("BAND_EN 值域非 0/1")
        if re.search(r"^CELL_EN=", conf, re.M) and not ce:
            mism.append("CELL_EN 值域非 0/1")
        if be and ce and be.group(1) == "1" and ce.group(1) == "1":
            mism.append("频段锁与小区锁互斥违反")
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
        record(t_cel_apisim._test_name, "cellular", True, f"skip ({_skip_note()})")
        return
    j = api("sim", tok)
    imei_api = str(j.get("imei", ""))
    imei_at = re.search(r"\b(\d{15})\b", at("AT+CGSN"))
    ok = bool(imei_at) and imei_api == imei_at.group(1)
    record(t_cel_apisim._test_name, "cellular", ok,
           f"api={imei_api[:6]}.. at={imei_at.group(1)[:6] if imei_at else '?'}..")


@test("组网模式 ENDC conf=API=模组读回一致")
def t_cel_endc():
    # api.sh v2.62 + mipc_cellular v0.8: ENDC(1=SA 2=NSA 3=SA+NSA) 三层一致
    tok = _token()
    if tok is None:
        record(t_cel_endc._test_name, "cellular", True, f"skip ({_skip_note()})")
        return
    j = api("netmode", tok)
    api_e = str(j.get("endc", ""))
    conf = dev("cat /data/gw/cellular.conf 2>/dev/null")
    m = re.search(r"^ENDC_MODE=([123])$", conf, re.M)
    raw = dev("/data/gw/mipc_cellular endc get 2>/dev/null")
    rm = re.search(r'"nr_disable_mode":(-?\d+)', raw)
    mism = []
    if api_e not in ("1", "2", "3"):
        mism.append(f"api endc={api_e!r}")
    # conf 无 ENDC_MODE = 出厂未设过, 此时 API 应为默认 3(SA+NSA, 与模组出厂一致)
    if not m:
        if api_e != "3":
            mism.append("conf 无 ENDC_MODE 且 api≠默认3")
    elif m.group(1) != api_e:
        mism.append(f"conf={m.group(1)} api={api_e}")
    if not rm:
        mism.append("modem 读回失败")
    elif m:
        rawmap = {"3": "1", "5": "2", "7": "3"}
        want = rawmap.get(rm.group(1))
        if want != m.group(1):
            mism.append(f"modem raw={rm.group(1)}(={want}) conf={m.group(1)}")
    record(t_cel_endc._test_name, "cellular", not mism,
           "ok" if not mism else "; ".join(mism)[:90])


@test("拨号兜底守护存活 (P2)")
def t_cel_keeper():
    out = dev("pgrep -f dial_keeper.sh | head -1")
    ok = bool(out.strip())
    record(t_cel_keeper._test_name, "cellular", ok, f"pid={out.strip()}" if ok else "dial_keeper 未运行")


@test("拨号守护心跳新鲜且 mipc 硬超时在线 (卡死可自愈)")
def t_cel_keeper_hb():
    # v2.21 (10-14 模组 EE 事故): 事故断电窗口零重拨留痕 — 疑似守护卡死在一次
    # mipc 调用(进程在而守护死; 旧 watchdog 只查进程存活)。护栏三连:
    # ① 心跳 /tmp/dial_keeper.hb 新鲜(≤90s, 与 watchdog v1.7 同判据; 开机 300s
    #   宽限内缺席宽容); ② mipc 调用全部走 mto() 硬超时(脚本语义断言 — 设备无
    #   timeout 命令, 裸调 = 可无限阻塞); ③ 单实例守护在位。
    alive = dev("pgrep -f 'dial_keepe[r].sh' | wc -l").strip()
    hb = dev("cat /tmp/dial_keeper.hb 2>/dev/null").strip()
    up = dev("cut -d. -f1 /proc/uptime").strip()
    age = (int(up) - int(hb)) if (hb.isdigit() and up.isdigit()) else -1
    fresh = 0 <= age <= 90
    if age < 0 and alive == "1" and up.isdigit() and int(up) < 300:
        fresh = True   # 启动宽限(与 watchdog v1.7 同语义)
    wrap = dev("grep -c 'mipc_to' /data/gw/dial_keeper.sh").strip()
    # v2.22: 单实例判据 v1.3 改 PID 锁 — 断言锁 ↔ 活进程跨层一致(替代原脚本文本 grep)
    lock = dev("cat /tmp/dial_keeper.lock 2>/dev/null").strip()
    lockok = (lock.isdigit() and dev(
        f"grep -qa dial_keeper /proc/{lock}/cmdline 2>/dev/null && echo y").strip() == "y") \
        if lock.isdigit() else False
    ok = (alive == "1" and fresh
          and wrap.isdigit() and int(wrap) >= 4
          and lockok)
    record(t_cel_keeper_hb._test_name, "cellular", ok,
           f"alive={alive} hb_age={age}s mto={wrap} lock={lock or '-'}")


@test("SMS 引擎二进制冒烟 (P4)")
def t_cel_smstool():
    # ql_sms_send_msg 直发引擎: 二进制在位+可执行+用法出口正常
    # (真实发送不做进测试 -- 产生费用; 实弹验证 2026-10-06 ret=0 已入台账)
    out = dev("/data/gw/mipc_cellular >/dev/null 2>&1; echo rc=$?")
    ok = "rc=1" in out
    record(t_cel_smstool._test_name, "cellular", ok, out.strip())


@test("GUI sms 端点 JSON 有效")
def t_cel_apisms():
    tok = _token()
    if tok is None:
        record(t_cel_apisms._test_name, "cellular", True, f"skip ({_skip_note()})")
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


@test("首刷口令自举就位 (不运行在默认口令)")
def t_sec_bootpass():
    # 首刷场景: gui_auth.conf 缺失时 login 以文档化默认口令建档(api.sh v2.23);
    # 常态断言: 文件存在且非默认口令哈希(运行在默认口令 = 仅提示, 不判死)
    import hashlib
    out = dev("cat /data/gw/gui_auth.conf 2>/dev/null").strip()
    d = hashlib.sha256(b"lg6151m").hexdigest()
    if not out:
        record(t_sec_bootpass._test_name, "security", False, "gui_auth.conf 缺失且自举未建")
        return
    on_default = out == d
    record(t_sec_bootpass._test_name, "security", True,
           "运行在默认口令!! 请改密" if on_default else "ok")


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
    # v1.5(P1): v4 链 default-deny — icmp/DHCP客户端/established 放行, 末条 DROP
    # (原 7 端口黑名单语义被包含); FORWARD 挂 V4WANGUARDF 挡 WAN->LAN 新建。
    out = dev("iptables -S V3WANGUARD 2>/dev/null")
    hook = dev("iptables -S INPUT 2>/dev/null | grep -c 'V3WANGUARD'").strip() or "0"
    fh = dev("iptables -S FORWARD 2>/dev/null | grep -c 'V4WANGUARDF'").strip() or "0"
    lines = [l.strip() for l in out.strip().splitlines() if l.strip()]
    ok = ("RELATED,ESTABLISHED -j ACCEPT" in out
          and lines and lines[-1].endswith("-A V3WANGUARD -j DROP")
          and int(hook) >= 2 and int(fh) >= 2)
    record(t_sec_wanguard._test_name, "security", ok,
           f"tail={'DROP' if lines and lines[-1].endswith('DROP') else lines[-1] if lines else 'EMPTY'} in_hooks={hook} fwd_hooks={fh}")


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
    # 过滤移到 Python 侧(lgssh 包装器管道偶发吞掉 grep -v 引号, ramoops 误报三犯):
    # 排除 aee_aed ipanic 探测噪声 / *_panic_* initcall / ramoops 初始化行;
    # 真 Oops:/BUG:/panic 必须为 0
    out = dev("dmesg | grep -iE 'Oops:|BUG:|panic'")
    # v2.13: +排除 MTK WiFi 固件 WARN 中继(HwCtrlTask_0: WiFi@WARN.FW,UniCmdResultRsp
    #   ... BUG::UniCmdResult.u4Status=0xc0000001 cid=0x2) — 固件单行 warn 中继, 非内核
    #   Oops(无寄存器dump/无调用栈), 实测>1天 400+ 条而 WiFi/整机全程正常=良性噪声;
    #   "BUG::" 只是固件日志字面串。其它 HwCtrlTask/WiFi@WARN 形态仍计为真事件。
    real = [l for l in out.splitlines()
            if not any(k in l for k in ("aee_aed", "_panic_", "ramoops", "panic_on_taint",
                                        "WiFi@WARN.FW,UniCmdResultRsp"))]
    record(t_sys_kernel._test_name, "system", len(real) == 0,
           f"events={len(real)} (噪声已滤)" + (f" first={real[0][:80]}" if real else ""))


@test("不变量看门狗活着且无未恢复故障")
def t_sys_wd2():
    # watchdog.sh (L13) 必须在跑, 且 /tmp/watchdog_state 无 key=1 残留
    alive = dev("pgrep -f watchdog.sh | head -1").strip()
    # v2.62: 排除结果探针键(dp5g/dpeth/http200/dnssvc) — 它们天然瞬态(irat 承载
    # 切换/上游抖动), 语义归可用性系统做窗口降级判定; p0 的"未恢复故障"只约束
    # 监督面键(守护/端口/规则/判决)。存在性键必须干净, 探针键只要求存在。
    state = dev("grep '=1$' /tmp/watchdog_state 2>/dev/null | grep -vE '^(dp5g|dpeth|http200|dnssvc)='")
    probes = dev("grep -cE '^(dp5g|dpeth|http200|dnssvc)=' /tmp/watchdog_state 2>/dev/null").strip()
    if state.strip():
        # v2.63: 防抖 — wan_agg 模式切换会瞬时拆装 agg_rules/fwmark(状态是迁移式
        # 快照, 单点采样会误报); 40s 后复采, 仍红才算"未恢复"
        import time as _t
        _t.sleep(40)
        state = dev("grep '=1$' /tmp/watchdog_state 2>/dev/null | grep -vE '^(dp5g|dpeth|http200|dnssvc)='")
    ok = bool(alive) and not state.strip() and probes == "4"
    det = f"pid={alive}" + (f" FAILing={state.strip().splitlines()[0]}" if state.strip() else "")
    record(t_sys_wd2._test_name, "system", ok, det)


@test("日志持久化守护活着且镜像新鲜")
def t_sys_logk():
    # v2.18: log_keeper(专项轮)单实例(防自匹配) + syslog 镜像存在/新鲜(<120s)
    # + boot 分隔行在位(重启后取证的分界依据)
    alive = dev("pgrep -f 'log_keepe[r].sh' | wc -l").strip()
    if alive != "1":
        import time as _t
        _t.sleep(2)   # tolerate a brief supervisor-restart overlap
        alive = dev("pgrep -f 'log_keepe[r].sh' | wc -l").strip()
    fresh = dev("test -f /data/gw/logs/syslog.log && "
                "[ $(( $(date +%s) - $(date -r /data/gw/logs/syslog.log +%s) )) -lt 120 ] && echo y").strip()
    sep = dev("grep -c '^===== BOOT' /data/gw/logs/syslog.log 2>/dev/null").strip()
    # v2.21: +上一 boot 快照转存标记 .snap_up 在位(tmp → tmp.prev 的归属判定;
    #   10-14 事故里 /tmp 现场被新 boot 覆盖的教训)
    snap = dev("cat /data/gw/logs/.snap_up 2>/dev/null").strip()
    prev = dev("test -d /data/gw/logs/tmp.prev && echo y").strip()
    ok = (alive == "1" and fresh == "y" and sep.isdigit() and int(sep) >= 1
          and snap.isdigit())
    record(t_sys_logk._test_name, "system", ok,
           f"daemon={alive} fresh={fresh} boot_marks={sep} snap_up={snap or '-'} prev={prev or '-'}")



@test("5G 指示灯反映数据面 (无数据不得点亮)")
def t_sys_led_dp():
    # v2.21 (10-14 模组 EE 事故实弹): 旧语义"无承载=橙常亮"在模组崩溃离线期仍亮 =
    #   谎报"5G 在"。护栏: ① led_mgr 单实例; ② 映射断言(--dry-state 干跑, 不点灯
    #   不动现场): c0 → 三色全灭(本次修复的核心语义), c1 → 仅绿亮; ③ 实况引脚 ==
    #   数据面推算值。
    # v2.22 (10-15 WAN 灯不亮实弹): v2.0 改绝对电平驱动(每轮无条件写"应为值"),
    #   外部扰动 2s 内自愈 → 不再需要"容忍一拍"的 sleep(轮询 2s)。断言收敛为
    #   **无条件一致**: 不为一致而等待 = 等待本身就是边沿触发病灶的遮羞布。
    # v2.43: 只数常驻实例 — --dry-state 一次性进程(本测试与 WAN 灯测试都会跑)
    #   会被 pgrep 计入, 造成 daemon=2 假阳性(实测)。
    n = dev("c=0; for p in $(pgrep -f 'led_mg[r].sh'); do "
            "grep -qa 'dry-state' /proc/$p/cmdline 2>/dev/null || c=$((c+1)); done; echo $c").strip()
    if n != "1":
        # a supervisor restart can briefly overlap the old and new instance;
        # re-check after it settles instead of flagging a transient duplicate
        import time as _t
        _t.sleep(2)
        n = dev("c=0; for p in $(pgrep -f 'led_mg[r].sh'); do "
                "grep -qa 'dry-state' /proc/$p/cmdline 2>/dev/null || c=$((c+1)); done; echo $c").strip()
    dry0 = dev("sh /data/gw/led_mgr.sh --dry-state 'w1 c0 b1 p1'").strip()
    dry1 = dev("sh /data/gw/led_mgr.sh --dry-state 'w1 c1 b1 p1'").strip()
    map0 = "g5g=0 g5o=0 g5r=0" in dry0
    map1 = "g5g=1 g5o=0 g5r=0" in dry1
    night = (eff_conf(["LED_NIGHT"]).get("LED_NIGHT") or "0") == "1"
    ipv4 = dev("ip -4 addr show 2>/dev/null | grep ccmni | grep -c 'inet '").strip()
    have_cell = ipv4.isdigit() and int(ipv4) > 0

    def _trio():
        return (dev("cat /sys/class/gpio/gpio475/value 2>/dev/null").strip(),
                dev("cat /sys/class/gpio/gpio473/value 2>/dev/null").strip(),
                dev("cat /sys/class/gpio/gpio474/value 2>/dev/null").strip())

    want = ("1", "0", "0") if have_cell else ("0", "0", "0")
    live = _trio()
    live_ok = night or live == want
    ok = n == "1" and map0 and map1 and live_ok
    record(t_sys_led_dp._test_name, "system", ok,
           f"daemon={n} map(c0/c1)={int(map0)}/{int(map1)} cell={ipv4} "
           f"live={''.join(live)} want={''.join(want)}" + (" night=skip" if night else ""))


@test("WAN 指示灯反映家宽数据面 (绝对电平自愈)")
def t_sys_led_wan():
    # v2.22 (10-15 实弹): eth0 有公网 IP/数据面通而 WAN 灯灭。根因两层:
    #   ① 执行方式: led_mgr v1.x 边沿触发(if [ "$NS" != "$ST" ] 才写), 外部
    #      写方改灯后状态串不变 → 永不纠回。实测: 状态 b1 起 5h 内一次没写。
    #   ② 写方冲突: watchdog 告警闪 WAN 灯, 闪完停在 0 = 直接把灯留在误值。
    #   v2.0 修复: 绝对电平驱动 + 写权单一化(watchdog 告警迁到 5G 橙灯)。
    # 护栏(全都不扰动现场): ① 干跑映射 b0→wan=0 / b1→wan=1; ② watchdog 源码
    #   不再引用 5g_evb_voice(写权唯一化), 且引用 gpio473(告警灯新家);
    #   ③ 实况亮度 == 数据面推算值(绝对电平驱动下必须一致, 不等一拍)。
    dry0 = dev("sh /data/gw/led_mgr.sh --dry-state 'w1 c1 b0 p0'").strip()
    dry1 = dev("sh /data/gw/led_mgr.sh --dry-state 'w1 c1 b1 p1'").strip()
    map0 = "wan=0" in dry0
    map1 = "wan=1" in dry1
    night = (eff_conf(["LED_NIGHT"]).get("LED_NIGHT") or "0") == "1"
    # 写权唯一化断言必须只看**代码写方**, 不看注释/说明文字(源码里明文提及
    # 5g_evb_voice 的历史解释是允许的)。取非注释行中含 echo>/写语义的行。
    wd_wan = dev("grep -v '^[[:space:]]*#' /data/gw/watchdog.sh 2>/dev/null | "
                 "grep -c '5g_evb_voice'").strip()
    wd_alert = dev("grep -v '^[[:space:]]*#' /data/gw/watchdog.sh 2>/dev/null | "
                   "grep -c 'gpio473'").strip()

    # 家宽数据面实况(与 led_mgr 同源判据: 网关优先 + 公网兜底)
    bb_gw = dev("head -1 /tmp/wan.gw 2>/dev/null").strip()
    probe = "ping -4 -I eth0 -c1 -W2 -s1 %s" % (bb_gw or "223.5.5.5")
    bb = dev("sh -c '%s >/dev/null 2>&1 && echo 1 || echo 0'" % probe).strip()
    want = "1" if bb == "1" else "0"
    # class 节点(5g_evb_voice)是主通道; gpio292 被 leds-gpio 占用(sysfs 路径
    # 不存在, set_wan 已回落 class) —— 以 class 亮度为准, sysfs 缺席不判失败。
    cls = dev("cat /sys/class/leds/5g_evb_voice/brightness 2>/dev/null").strip()
    live_ok = night or cls == want
    ok = map0 and map1 and wd_wan == "0" and wd_alert != "0" and live_ok
    record(t_sys_led_wan._test_name, "system", ok,
           f"map(b0/b1)={int(map0)}/{int(map1)} wd_wan_refs={wd_wan} wd_alert_refs={wd_alert} "
           f"bb={bb} class_led={cls} want={want}" + (" night=skip" if night else ""))



def _agg_conf():
    """读聚合配置(MODE/W1_PCT), 缺省回退。"""
    mode = dev("grep -m1 '^MODE=' /data/gw/agg.conf 2>/dev/null | cut -d= -f2").strip() or "eth_prio"
    pct = dev("grep -m1 '^W1_PCT=' /data/gw/agg.conf 2>/dev/null | cut -d= -f2").strip() or "30"
    return mode, pct


_CELL_IF_CACHE = []


def _cell_iface():
    """实际承载数据的 ccmni 口(v2.36/2.37): 多口并存时按探活实证选, 不用"第一个
    有 IP"—— 旧 PDN 未 deact 干净常有僵尸口(有 IP 无数据), 会导致护栏假红。
    探针目标与 wan_agg 同源(多样/非白名单); 结果缓存(单次 selftest 内不变)。"""
    if _CELL_IF_CACHE:
        return _CELL_IF_CACHE[0]
    cands = dev("ip -o -4 addr show 2>/dev/null | grep ccmni | grep inet "
                "| cut -d' ' -f2").split()
    pick = ""
    for c in cands:
        for tg in ("180.76.76.76", "119.29.29.29", "8.8.8.8"):
            if dev(f"ping -4 -I {c} -c1 -W2 {tg} 2>/dev/null | grep -q ttl && echo ok").strip() == "ok":
                pick = c
                break
        if pick:
            break
    _CELL_IF_CACHE.append(pick)
    return pick

def _wan_alive_state():
    """读 wan_agg 发布的判活结论(唯一权威): (home, cell, fresh)。
    v2.36: 新鲜度在**设备侧**计算 — PC 与设备时钟可能不同步(实测差 8h:
    设备跑 UTC 而 PC 是 CST), 用 PC time.time() 比对设备 ts 会恒判过期。"""
    wa = dev("cat /tmp/wan_alive 2>/dev/null; date +%s").splitlines()
    if not wa:
        return None, None, False
    m = re.search(r"home=([01]).*cell=([01]).*ts=(\d+)", wa[0])
    if not m:
        return None, None, False
    try:
        now = int(wa[-1].strip())
    except ValueError:
        return m.group(1), m.group(2), False
    return m.group(1), m.group(2), abs(now - int(m.group(3))) <= 30

def _dry_primary(mode, a1, a2, pct=""):
    """干跑主路推导(--dry-primary), 不碰现场。"""
    out = dev(f"sh /data/gw/wan_agg.sh --dry-primary {mode} {a1} {a2} {pct}").strip()
    m = re.search(r"primary=(\S+)", out)
    return m.group(1) if m else "?"


@test("蜂窝侧不再抢 main 表默认 (聚合路由地雷)")
def t_agg_route_landmine():
    # v2.24 (2026-10-15 实测复核): 蜂窝侧 main 表默认路由只作"探活可达"用途, metric
    #   必须劣于家宽备用默认(200)。旧值 50 插在家宽主默认(0)与备用(200)之间: 主默认
    #   被外力(租约/认证刷新)冲刷后无看门狗补, 未打标流量(netagent/DNS/NTP + 丢标记
    #   的转发流)会静默改走蜂窝并长期滞留 = 真实的"流量偏好蜂窝"路径。
    #   wan_agg v2.30: metric 50→250 + 补家宽主默认存在性看门狗。
    # 断言(不扰动现场): ① main 表不存在 metric<200 的 ccmni 默认(缺 metric 同样违规);
    #   ② 探活路由(metric 250)在位; ③ 家宽主力模式下家宽主默认(dev eth0 无 metric)在位。
    # v2.27: 状态感知 —— metric<200 的 ccmni 默认只有在"家宽是主路"时才是地雷;
    #   蜂窝为主路时(宵断自动转移/仅蜂窝/权重偏蜂窝)它就是**预期的** metric-0 主默认。
    rts = dev("ip route show default 2>/dev/null").splitlines()
    ccmni_lines = [l for l in rts if "ccmni" in l]
    land = []
    for l in ccmni_lines:
        m = re.search(r"metric (\d+)", l)
        if not m or int(m.group(1)) < 200:
            land.append(l.strip())
    probe = any("metric 250" in l for l in ccmni_lines)
    # v2.36: 探活路由可能指向任意 ccmni(v3.1 承载漂移按探活实证选口), 只要求
    #   这条路由指向**当前有 IPv4 的** ccmni(僵尸口不算)。
    live_ccmni = dev("ip -o -4 addr show 2>/dev/null | grep ccmni | grep 'inet ' "
                     "| awk '{print $2}'").split()
    probe = probe and any(any(c in l for c in live_ccmni) for l in ccmni_lines if "metric 250" in l)
    eth_pri = [l for l in rts if "dev eth0" in l and "metric" not in l]
    mode, pct = _agg_conf()
    home, cell, _fresh = _wan_alive_state()
    exp = _dry_primary(mode, cell or "1", home or "1", pct)
    if exp == "w2":      # 家宽主路: 不得有抢默认的蜂窝条目, 且家宽主默认须在位
        ok = probe and not land and bool(eth_pri)
    elif exp == "w1":    # 蜂窝主路: metric-0 蜂窝主默认是预期(地雷不成立)
        ok = probe and bool(land)
    else:                # 双死/未知: 只要求探活路由在位, 不猜
        ok = probe
    record(t_agg_route_landmine._test_name, "system", ok,
           f"mode={mode} exp={exp} alive={cell or '?'}/{home or '?'} "
           f"ccmni_defaults={len(ccmni_lines)} landmine={len(land)} "
           f"probe250={int(probe)} eth0_primary={int(bool(eth_pri))}"
           + (f" bad='{land[0][:30]}'" if (land and exp == "w2") else ""))


@test("流量统计口径 = Linux 发送路径 (非网卡报告值)")
def t_traffic_source():
    # v2.24 (2026-10-15 实弹): 蜂窝网卡 tx_bytes 会被厂商卸载路径的记账灌入无佐证的
    #   批量增量(实测 1 秒 +1,221,373B/813 包, 而同期 qdisc 仅 +29B/1 包、ccmni2 抓包
    #   只有 6 个探针包; 无 IP/无路由且 DOWN 的 ccmni1 也记了 47MB)。拿它当"蜂窝用量"
    #   展示=长期高估。traffic_logger v1.2 / api v2.72 起蜂窝上行改用 qdisc(Linux 路径)。
    # 断言: ① /api/traffic 的蜂窝 tx 等于 qdisc Sent 值(容差 8KB, 覆盖两次读取间的探针);
    #   ② watchdog 存在偏差护栏(该信号必须可见而非静默); ③ 记录网卡与路径的当前差值。
    tok = _token()
    if tok is None:
        record(t_traffic_source._test_name, "system", True,
               "skip — 无 GUI token(" + (_TOKEN_NOTE[0] or "未配置") + ")")
        return
    # v2.38: 同口比对 — 先让 API 报出它实际取样的口(/api/traffic 的 if 字段),
    #   再在该口上做 qdisc 前后读数。双方各自"选活口"会在多 ccmni 并存时错配。
    j0 = api("traffic", tok)
    cif = str(j0.get("if") or "") or _cell_iface()
    nd = dev(f"cat /sys/class/net/{cif}/statistics/tx_bytes 2>/dev/null").strip()
    # 区间校验: API 取到的值必须落在**调用前后两次 qdisc 读数之间** —— 对任意流量
    #   速率都成立(蜂窝承载客户端流量时, 两次读取间会有真实增量, 固定容差会误判)。
    qd0 = dev(f"tc -s qdisc show dev {cif} 2>/dev/null | awk '/Sent/{{print $2; exit}}'").strip()
    j = api("traffic", tok)
    qd1 = dev(f"tc -s qdisc show dev {cif} 2>/dev/null | awk '/Sent/{{print $2; exit}}'").strip()
    guard = dev("grep -c 'cell stats divergence' /data/gw/watchdog.sh 2>/dev/null").strip()
    api_tx = str(j.get("tx", ""))
    qd = qd1
    try:
        a, b, c = int(qd0), int(qd1), int(api_tx)
        gap = int(nd) - b
        near = (a <= c <= b) if b >= a else abs(c - b) <= 65536   # 重置回退小容差
    except ValueError:
        # v2.39: 冷启动瞬间新 ccmni 可能尚无 qdisc Sent 行(接口未承载流量) —
        #   API 自身在 qdisc 缺失时回退 netdev, 护栏同口径比对, 不判红。
        gap = -1
        near = nd.isdigit() and api_tx.isdigit() and int(api_tx) == int(nd)
    ok = bool(cif) and nd.isdigit() and (qd.isdigit() or near) and near and guard not in ("", "0")
    record(t_traffic_source._test_name, "system", ok,
           f"if={cif} api_tx={api_tx} qdisc[{qd0},{qd}] netdev={nd} netdev_minus_qdisc={gap} guard={guard}")



@test("未打标主路由聚合模式推导 (v4 与 v6 同源)")
def t_main_primary():
    # v2.31 (用户裁定): 未打标主路(本机自身 + 丢标记的转发流)不写死优先级 —— 由
    #   "模式+权重+真实存活"推导; main 表唯一写方 = wan_agg.main_primary_apply(),
    #   每周期复位(level-driven)。原先 v4 只在迁移瞬间决定、v6 完全没人管(靠两侧
    #   RA metric 固定偏好蜂窝)。
    # 断言: ① 五种模式×存活组合的映射(--dry-primary 干跑, 不碰现场);
    #   ② 现场 v4 与 v6 的未打标选路指向**同一**接口;
    #   ③ 且等于现场"模式+真实存活"推导出的主路; ④ 无 metric<200 的 ccmni v4 默认。
    def want(mode, a1, a2, pct=""):
        return _dry_primary(mode, a1, a2, pct)
    cases = [("eth_prio", "1", "1", "", "w2"), ("cell_prio", "1", "1", "", "w1"),
             ("cell_only", "1", "1", "", "w1"), ("eth_only", "1", "1", "", "w2"),
             ("weight", "1", "1", "30", "w2"), ("weight", "1", "1", "70", "w1"),
             ("eth_prio", "1", "0", "", "w1"), ("cell_prio", "0", "1", "", "w2"),
             ("eth_prio", "0", "0", "", "none")]
    bad = [f"{m}/{a}{b}:{want(m, a, b, p)}!={e}" for m, a, b, p, e in cases
           if want(m, a, b, p) != e]
    mode, pct = _agg_conf()
    # 存活态取 wan_agg 发布的权威结论(不再各自探测, 与判活唯一权威一致)
    home, cell, _fresh = _wan_alive_state()
    a1 = cell or "1"
    a2 = home or "1"
    exp = want(mode, a1, a2, pct)
    v4 = dev("ip route get 223.5.5.5 2>/dev/null | head -1")
    v6 = dev("ip -6 route get 2400:3200::1 2>/dev/null | head -1")
    ifc4 = "eth0" if "dev eth0" in v4 else ("cell" if "ccmni" in v4 else "?")
    ifc6 = "eth0" if "dev eth0" in v6 else ("cell" if "ccmni" in v6 else "?")
    exp_ifc = {"w1": "cell", "w2": "eth0"}.get(exp, "?")
    # 地雷断言由 t_agg_route_landmine(状态感知)负责, 此处只管映射与一致性
    ok = (not bad) and ifc4 == ifc6 and ifc4 == exp_ifc
    record(t_main_primary._test_name, "system", ok,
           f"map_bad={len(bad)} live={mode}/{pct} alive={a1}{a2} exp={exp} "
           f"v4={ifc4} v6={ifc6}" + (f" {bad[0]}" if bad else ""))



@test("数据面判活不落入白名单陷阱 (宵断可见/唯一权威)")
def t_wan_alive_guard():
    # v2.26 (2026-10-16 00:06 宵断实弹): 判活目标若落在"白名单式切断"仍放行的集合里
    #   (运营商 DNS 223.5.5.5/120.53.53.53 + 接入网关), 就会出现"探测恒过而客户端全死"
    #   → 灯/GUI/自动转移全部谎报家宽正常, 用户只能手动切"仅蜂窝"。实测同时段:
    #   223.5.5.5/120.53.53.53/网关 全通, 180.76.76.76/119.29.29.29/8.8.8.8 全 100% 丢包。
    # 断言: ① wan_agg 的探测目标 ≥3 个且**不含**白名单目标; ② 判活唯一权威 = /tmp/wan_alive
    #   且新鲜(守护在跑); ③ led_mgr 与 api 已改为消费该文件(不再自带一套判据);
    #   ④ 现场一致性: 多样目标经 eth0 的实测可达性 == 发布的 home 判活值。
    src = dev("grep -m1 '^PROBE_V4=' /data/gw/wan_agg.sh 2>/dev/null").strip()
    targets = src.split("=", 1)[1].strip().strip('"').split() if "=" in src else []
    wl = {"223.5.5.5", "120.53.53.53"}
    bad = [t for t in targets if t in wl]
    reach = sum(1 for t in targets
                if dev(f"ping -4 -I eth0 -c1 -W2 -s1 {t} 2>/dev/null | grep -q ttl && echo y").strip() == "y")
    home, _cell, fresh = _wan_alive_state()
    if not fresh:   # v2.36: 瞬时窗口(守护刚重启/环循边界) → 重采一次再判
        import time as _t
        _t.sleep(6)
        home, _cell, fresh = _wan_alive_state()
    home = home or "?"
    expect = "1" if reach > 0 else "0"
    # v2.29 (api v2.75 拆分): api.sh 的 wan_alive 消费代码随 status 迁入 api_sys.sh
    cons = [dev(f"grep -c 'wan_alive' /data/gw/{f} 2>/dev/null").strip() for f in ("led_mgr.sh", "www/api_sys.sh")]
    ok = (len(targets) >= 3 and not bad and fresh and home == expect
          and all(c not in ("", "0") for c in cons))
    record(t_wan_alive_guard._test_name, "system", ok,
           f"targets={len(targets)} in_whitelist={len(bad)} reachable={reach} home={home} "
           f"expect={expect} fresh={int(fresh)} consumers={cons}" + (f" bad={bad[0]}" if bad else ""))


@test("钉死表缺省播种 (缺失不再报错/静默失效)")
def t_agg_pins_seed():
    # v2.28: 活文件 /data/gw/agg_pins.conf 是**设备侧自管**(含个人 MAC, 不入库;
    #   deploy.py 的 EXTRA_KEEP, 不参与部署/体检 md5 比对) —— 但"文件缺失"会让
    #   wan_agg 的钉死重放循环报错(weight 模式下该分支每环循执行, 报错重复)且钉死
    #   机制静默失效。现从随版本部署的**只读基线** agg_pins.default 缺省才写地播种。
    # 断言: ① 设备上基线在位且**不含任何 MAC 行**(隐私 + 避免误钉); ② 活文件在位
    #   且带基线说明(播种生效; 用户经 GUI 编辑时注释行被保留, 说明不丢);
    #   ③ 播种逻辑在位(结构护栏; v2.29/架构轮: 随 conf 管理迁入 wan_agg_lib.sh,
    #   检查两处 — 主管启动调 agg_conf_seed, 库内含播种本体); ④ 活文件仍在
    #   EXTRA_KEEP(自管, 防被仓库空版本覆盖 —— 那会静默清空用户钉死, 即 L10 那类事故)。
    base_lines = dev("cat /data/gw/agg_pins.default 2>/dev/null | wc -l").strip()
    base_macs = dev("grep -v '^#' /data/gw/agg_pins.default 2>/dev/null | grep -c .").strip()
    live_doc = dev("grep -c 'MAC 钉死表' /data/gw/agg_pins.conf 2>/dev/null").strip()
    seed = dev("grep -c 'agg_pins.default' /data/gw/wan_agg_lib.sh 2>/dev/null").strip()
    seed_call = dev("grep -c 'agg_conf_seed' /data/gw/wan_agg.sh 2>/dev/null").strip()
    dp = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tools", "deploy.py")
    keep_ok = False
    try:
        t = open(dp, encoding="utf-8").read()
        keep_ok = ('"agg_pins.conf"' in t) and ("EXTRA_KEEP" in t)
    except OSError:
        pass
    ok = (base_lines.isdigit() and int(base_lines) > 3 and base_macs == "0"
          and live_doc not in ("", "0") and seed not in ("", "0")
          and seed_call not in ("", "0") and keep_ok)
    record(t_agg_pins_seed._test_name, "agg", ok,
           f"baseline_lines={base_lines} baseline_macs={base_macs} live_doc={live_doc} "
           f"seed_code={seed} seed_call={seed_call} extra_keep={int(keep_ok)}")


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


@test("NTP 服务器自管配置生效 (defaults叠settings)")
def t_sys_ntp():
    # api.sh v2.59+: 树退役后 NTP 走自管 conf — API 必须回叠加持有效值
    # (settings 覆盖 > defaults 出厂 > 内置兜底), 否则即僵尸读回归
    tok = _token()
    if tok is None:
        record(t_sys_ntp._test_name, "system", True, f"skip ({_skip_note()})")
        return
    j = api("ntp", tok)
    # v2.16b: 持有效值(settings 覆盖 defaults) — 原 'cat settings defaults | tail -1'
    # 恒取 defaults 行, 用户设置过 NTP_SERVER 即误报
    srv = eff_conf(["NTP_SERVER"]).get("NTP_SERVER") or "ntp.aliyun.com"
    # v2.16b: 时区运行态 == 持有效值(/etc/TZ→tmpfs 重启即失的回归护栏;
    # 时区偏移会连带把定时重启窗口整体平移)
    tz = eff_conf(["TZ"]).get("TZ") or "CST-8"
    live = dev("cat /etc/TZ 2>/dev/null").strip()
    ok = (bool(j.get("ntp_server")) and bool(j.get("date")) and j["ntp_server"] == srv
          and live == tz and j.get("tz") == tz)
    record(t_sys_ntp._test_name, "system", ok,
           f"ntp={j.get('ntp_server')} tz={j.get('tz')}/{live}" if ok else
           f"api={j.get('ntp_server')!r} conf={srv!r} tz_api={j.get('tz')!r} tz_live={live!r} tz_conf={tz!r}")


@test("定时重启守护单实例且与配置同源 (默认每日 04:00)")
def t_sys_reboot_sched():
    # 守护单实例(防自匹配: [d] 技巧, 原命令含本模式串会自计);
    # API 回值 = conf 叠加持有效值(僵尸读回归护栏, 与 NTP 同族);
    # 值域 HH:MM 强校验(坏值会让守护静默回退默认, 用户设置白设)
    n = dev("pgrep -f 'reboot_sche[d].sh' | wc -l").strip()
    conf = eff_conf(["REBOOT_TIME"]).get("REBOOT_TIME") or "04:00"
    tok = _token()
    if tok is None:
        record(t_sys_reboot_sched._test_name, "system", n == "1",
               f"daemon={n} (skip api: {_skip_note()})")
        return
    j = api("reboot_sched", tok)
    ok = (n == "1" and re.match(r"^([01]\d|2[0-3]):[0-5]\d$", j.get("time", "") or "")
          and j.get("time") == conf)
    record(t_sys_reboot_sched._test_name, "system", ok,
           f"daemon={n} api={j.get('time')} conf={conf}")


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


@test("v3_fix 内核模块在位 (TTL 伪装/RX 解绑)")
def t_v3fix_loaded():
    # v2.41 (24h 日志轮, 2026-10-18): 旧产物 ELF 节表整体错位 1 字节(文件在某处
    #   被插入 1B), 内核 "Invalid ELF section hdr(type 768)" 拒载 — 每次开机
    #   insmod 都静默失败, TTL 伪装/RX 解绑长期死着无人知晓(典型 L13)。
    #   重建修复; 本护栏断言模块恰 1 实例在 /proc/modules。
    n = dev("grep -c v3_fix /proc/modules").strip()
    ok = n == "1"
    record(t_v3fix_loaded._test_name, "system", ok,
           f"/proc/modules v3_fix={n}" + ("" if ok else " (rc19 insmod failed? see rc19.log)"))


@test("日志细粒度与 24h 持久化管线 (log_keeper v1.3 增量)")
def t_logging_fine():
    # v2.40 (日志加密轮): 静态 — log_keeper 必须是增量追加(stream/STREAM_CAP/
    #   resync), 而不是旧的 tail 32K 覆盖快照; 动态 — wan_agg/watchdog 的持久化
    #   副本已落盘且含 TICK/EVT 主干行(部署后首轮即应出现)。
    st = dev("grep -c 'STREAM_CAP=1048576' /data/gw/log_keeper.sh 2>/dev/null").strip()
    sm = dev("grep -c 'stream()' /data/gw/log_keeper.sh 2>/dev/null").strip()
    rs = dev("grep -c 'stream resync' /data/gw/log_keeper.sh 2>/dev/null").strip()
    dn = dev("grep -c 'SYSLOG_DROP' /data/gw/log_keeper.sh 2>/dev/null").strip()
    wa = dev("wc -c < /data/gw/logs/tmp/wan_agg.log 2>/dev/null || echo 0").strip()
    wt = dev("tail -n 300 /data/gw/logs/tmp/wan_agg.log 2>/dev/null | grep -cE 'TICK|EVT'").strip()
    wd = dev("wc -c < /data/gw/logs/tmp/watchdog.log 2>/dev/null || echo 0").strip()
    wdt = dev("tail -n 300 /data/gw/logs/tmp/watchdog.log 2>/dev/null | grep -c 'TICK'").strip()
    ok = (st not in ("", "0") and sm not in ("", "0") and rs not in ("", "0")
          and dn not in ("", "0")
          and int(wa or 0) > 0 and int(wt or 0) > 0
          and int(wd or 0) > 0 and int(wdt or 0) > 0)
    record(t_logging_fine._test_name, "system", ok,
           f"cap={st} stream={sm} resync={rs} denoise={dn} wan={wa}B/{wt}evt wd={wd}B/{wdt}tick")


@test("静态工具链在位且守护已切换 (SIGSEGV P2)")
def t_static_toolchain():
    # v2.44 (SIGSEGV 根治轮): vendor musl 动态链接的 grep/awk/sh/ip 是崩溃家族
    #   本体; 静态 busybox(1.36.1)+静态 iproute2(6.3.0) 经 /data/gw/sbin 农场
    #   接管 PATH。断言: 农场指向正确目标、applet 数量、运行中的 watchdog 解释器
    #   已是静态 busybox、其 environ 的 PATH 前置了 /data/gw/sbin。
    bb = dev("test -x /data/gw/bin/busybox && echo y").strip()
    ipv = dev("/data/gw/bin/ip -V 2>/dev/null").strip()
    lcv = dev("/data/gw/bin/logc -V 2>/dev/null").strip()
    shl = dev("readlink /data/gw/sbin/sh 2>/dev/null").strip()
    ipl = dev("readlink /data/gw/sbin/ip 2>/dev/null").strip()
    grl = dev("readlink /data/gw/sbin/grep 2>/dev/null").strip()
    n = dev("/data/gw/bin/busybox --list 2>/dev/null | wc -l").strip()
    wp = dev("pgrep -f 'watchdog[.]sh' | head -1").strip()
    exe = dev("readlink /proc/%s/exe 2>/dev/null" % wp).strip() if wp else ""
    envp = dev("tr '\\0' '\\n' < /proc/%s/environ 2>/dev/null | grep '^PATH=' | head -1" % wp).strip() if wp else ""
    ok = (bb == "y" and "iproute2-6.3.0" in ipv and "logc" in lcv
          and shl.endswith("/busybox") and ipl.endswith("/ip")
          and grl.endswith("/busybox") and int(n or 0) >= 300
          and exe.endswith("/busybox") and "/data/gw/sbin" in envp)
    record(t_static_toolchain._test_name, "system", ok,
           "bb=%s ip=%s logc=%s sh=%s ip=%s grep=%s applets=%s wd_exe=%s path_ok=%s"
           % (bb, ipv[:18], lcv, shl, ipl, grl, n, exe,
              "/data/gw/sbin" in envp))


@test("logc 静态采集器在位且帧无异常 (SIGSEGV P1)")
def t_logc():
    # v2.44: log_keeper/diag_dump 必须走 logc, 不再调用厂商 logread;
    #   logc 实跑 5 条且 stats 的 bad_frames/resyncs 为 0; 最近一轮守护
    #   采集的 /tmp/logc.stats 也无异常(证明真实环流解析正常)。
    v = dev("/data/gw/bin/logc -V 2>/dev/null").strip()
    use = dev("grep -c '^LOGC=/data/gw/bin/logc' /data/gw/log_keeper.sh 2>/dev/null").strip()
    old = dev("grep -c '^[[:space:]]*logread ' /data/gw/log_keeper.sh 2>/dev/null").strip()
    out = dev("/data/gw/bin/logc -l 5 --stats-file /tmp/selftest_logc.stats "
              ">/tmp/selftest_logc.out 2>/dev/null; echo RC=$?; "
              "wc -l < /tmp/selftest_logc.out; grep -cE '^[A-Z][a-z]{2} [A-Z][a-z]{2} ' "
              "/tmp/selftest_logc.out; cat /tmp/selftest_logc.stats 2>/dev/null").strip()
    lines = out.splitlines()
    rc = lines[0] if lines else ""
    nlines = lines[1] if len(lines) > 1 else "0"
    nfmt = lines[2] if len(lines) > 2 else "0"
    stats = " ".join(lines[3:])
    live = dev("cat /tmp/logc.stats 2>/dev/null").strip()
    ok = (v.startswith("logc") and use not in ("", "0") and old in ("", "0")
          and rc == "RC=0" and nlines.isdigit() and int(nlines) > 0
          and nfmt == nlines
          and "bad_frames=0" in stats and "resyncs=0" in stats
          and "bad_frames=0" in live and "resyncs=0" in live)
    record(t_logc._test_name, "system", ok,
           "ver=%s use=%s old=%s %s lines=%s fmt=%s live_ok=%s"
           % (v, use, old, rc, nlines, nfmt,
              ("bad_frames=0" in live and "resyncs=0" in live)))


@test("core 捕获窗口守护在位 (SIGSEGV P3)")
def t_core_trap():
    # v2.44: core_trap 必须常驻(watchdog 自愈)、持锁、RLIMIT_CORE=unlimited;
    #   core_pattern 在窗口外必须是 aee 管道(窗口内允许 /tmp/core.%p)。
    run = dev("pgrep -f 'core_trap[.]sh' | head -1").strip()
    lock = dev("cat /tmp/core_trap.lock 2>/dev/null").strip()
    alive = dev("kill -0 %s 2>/dev/null && echo y" % lock).strip() if lock else ""
    pat = dev("cat /proc/sys/kernel/core_pattern 2>/dev/null").strip()
    lim = dev("grep -i 'Max core file size' /proc/%s/limits 2>/dev/null | awk '{print $6}'" % run).strip() if run else ""
    rc19 = dev("grep -c 'core_trap.sh' /data/gw/rc19.sh 2>/dev/null").strip()
    wd = dev("grep -c 'core_trap' /data/gw/watchdog.sh 2>/dev/null").strip()
    # v2.51: normal operation now goes through core_meta.sh, which records the
    # crash metadata and then execs aee_core_forwarder (same behaviour).
    pat_ok = ("aee_core_forwarder" in pat or "core_meta.sh" in pat) or (
        "/tmp/core.%p" in pat
        and dev("test -f /tmp/core_trap.active && echo y").strip() == "y")
    ok = (bool(run) and bool(lock) and alive == "y" and lim == "unlimited"
          and pat_ok and int(rc19 or 0) > 0 and int(wd or 0) > 0)
    record(t_core_trap._test_name, "system", ok,
           "pid=%s lock=%s alive=%s lim=%s pat=%s rc19=%s wd=%s"
           % (run, lock, alive, lim, pat, rc19, wd))


@test("watchdog aee 台账增量判据 (SIGSEGV P4)")
def t_watchdog_aee():
    # v2.44: 内核 DABT 行被 printk 限流后 dmesg 计数会低估; watchdog 必须同时
    #   以 aee db_history 行数增量为判据, 且基线文件与当前行数一致(±1 轮窗口)。
    code = dev("grep -c 'watchdog_aeecount' /data/gw/watchdog.sh 2>/dev/null").strip()
    cnt = dev("cat /tmp/watchdog_aeecount 2>/dev/null").strip()
    hist = dev("wc -l < /data/log/aee_exp/db_history 2>/dev/null").strip()
    st = dev("grep -cE '^core_?trap=' /tmp/watchdog_state 2>/dev/null").strip()
    ver = dev("grep -c 'watchdog v1.34 start' /tmp/watchdog.log 2>/dev/null").strip()
    # v2.62: /tmp/watchdog.log 会被 TICK 轮转(约 8h 挤掉横幅) — 持久 syslog 兜底
    vers = dev("grep 'watchdog v1' /data/gw/logs/syslog.log 2>/dev/null | tail -1 | grep -c 'v1.34 start'").strip()
    if ver == "0" and vers == "1":
        ver = "1"
    ok = False
    if code not in ("", "0") and cnt.isdigit() and hist.isdigit():
        ok = abs(int(cnt) - int(hist)) <= 2 and int(st or 0) > 0 and int(ver or 0) > 0
    record(t_watchdog_aee._test_name, "system", ok,
           "code=%s base=%s hist=%s state=%s ver=%s" % (code, cnt, hist, st, ver))


@test("stability P0/P3: 限时/3 次确认/统一监督表/心跳 (v1.29)")
def t_p0_watchdog():
    # v1.29: the primitives moved into svc_lib.sh; grep both files so the test
    # asserts "the implementation exists somewhere in the shared framework".
    code = dev("for p in 'tmo()' 'is_toolfault' 'toolfault()' 'strike()' 'rl_ok' "
               "'port_listen()' 'SVC_TABLE' 'svc_supervise' 'watchdog.beat' "
               "'boot_gate.sh --check'; do "
               "cat /data/gw/watchdog.sh /data/gw/svc_lib.sh 2>/dev/null | grep -c -- \"$p\"; done").split()
    code = [int(x) for x in code if x.strip().isdigit()]
    hbs = dev("for f in /tmp/led_mgr.hb /tmp/fan_mgr.hb /tmp/wan_eth.hb "
              "/tmp/log_keeper.hb /tmp/ntp_keeper.hb /tmp/wifi_guard.hb "
              "/tmp/traffic_logger.hb /tmp/reboot_sched.hb /tmp/core_trap.hb "
              "/tmp/healthdog.hb /tmp/dial_keeper.hb; do [ -s \"$f\" ] && echo y; done | wc -l").strip()
    st = dev("grep -cE '^(dnsmasq|dropbear|v3httpd|authd|ntp_keeper|traffic_logger|"
             "wifi_guard|reboot_sched|led_mgr|fan_mgr|wan_eth|log_keeper|core_trap|"
             "healthdog|dial_keeper)=' /tmp/watchdog_state 2>/dev/null").strip()
    beat = dev("cat /tmp/watchdog.beat 2>/dev/null").strip()
    up = dev("cut -d. -f1 /proc/uptime").strip()
    fresh = beat.isdigit() and up.isdigit() and (int(up) - int(beat)) < 180
    ok = (len(code) == 10 and all(c > 0 for c in code)
          and int(hbs or 0) >= 11 and int(st or 0) >= 15 and fresh)
    record(t_p0_watchdog._test_name, "system", ok,
           "code=%s hb=%s states=%s beat=%s fresh=%s" % (code, hbs, st, beat, fresh))


@test("stability P0: boot_gate 真门禁 + TRY_A 读回 + 尝试台账")
def t_p0_boot_gate():
    ex = dev("for f in /data/gw/boot_gate.sh /data/rescue/babysit.sh; do "
             "[ -x \"$f\" ] && echo y; done | wc -l").strip()
    hv = dev("sed -n 's/^boot_id=//p' /data/gw/boot.healthy 2>/dev/null | tail -1").strip()
    st = dev("sed -n 's/^stable=//p' /data/gw/boot.healthy 2>/dev/null | tail -1").strip()
    cur = dev("cat /proc/sys/kernel/random/boot_id 2>/dev/null").strip()
    done = dev("test -f /tmp/boot.done && echo y").strip()
    tryb = dev("dd if=/dev/mmcblk0p1 bs=1 skip=2061 count=1 2>/dev/null | /data/gw/bin/busybox od -An -tu1 | tr -d ' '").strip()
    att = dev("tail -n 1 /data/gw/boot_attempts.tsv 2>/dev/null").strip()
    chk = dev("/data/gw/boot_gate.sh --check >/dev/null 2>&1; echo $?").strip()
    timer = dev("grep -c 'sleep 120; touch /tmp/boot.done' /data/gw/rc19.sh 2>/dev/null").strip()
    ok = (ex == "2" and hv == cur and st == "1" and done == "y" and tryb == "0"
          and "result=healthy" in att and chk == "0" and timer == "0")
    record(t_p0_boot_gate._test_name, "system", ok,
           "exec=%s healthy_id=%s..%s stable=%s done=%s try_a=%s att=[%s] check_rc=%s timer=%s"
           % (ex, hv[:8], cur[:8], st, done, tryb, att[:60], chk, timer))


@test("stability P1: 服务监督表单实例 (每守护恰 1 个)")
def t_p1_singletons():
    pats = ["watchdog", "led_mgr", "fan_mgr", "dial_keeper", "log_keeper",
            "wan_agg", "wan_eth", "wifi_guard", "ntp_keeper", "traffic_logger",
            "reboot_sched", "core_trap", "healthdog", "boot_gate"]
    out = dev("for p in %s; do echo -n \"$p=\"; pgrep -f \"/data/gw/${p}[.]sh\" 2>/dev/null | wc -l; done"
              % " ".join(pats)).strip()
    bad = []
    # boot_gate exits by design after the 10-minute observation window; when it
    # is gone, stable=1 in boot.healthy is the proof that it finished its job.
    _stable = dev("sed -n 's/^stable=//p' /data/gw/boot.healthy 2>/dev/null | tail -1").strip()
    for ln in out.splitlines():
        if "=" in ln:
            k, v = ln.split("=", 1)
            if v.strip() != "1":
                if k == "boot_gate" and v.strip() == "0" and _stable == "1":
                    continue
                bad.append("%s:%s" % (k, v.strip()))
    record(t_p1_singletons._test_name, "system", not bad,
           "bad=%s all=%s" % (bad or "none", " ".join(out.split())))


@test("stability P1: 残余崩溃取证链 (core wrapper/logc/selftest/census)")
def t_p1_forensics():
    pat = dev("cat /proc/sys/kernel/core_pattern 2>/dev/null").strip()
    ex = dev("[ -x /data/gw/core_meta.sh ] && echo y").strip()
    fwd = dev("[ -x /sbin/aee_core_forwarder ] && echo y").strip()
    lv = dev("/data/gw/bin/logc -V 2>/dev/null").strip()
    st = dev("/data/gw/bin/logc --selftest 2>&1; echo rc=$?").strip()
    fz = dev("/data/gw/bin/logc --fuzz 40 2>&1; echo rc=$?").strip()
    # v1.4: strftime's "%0*lld" must not be linked in any more -- that musl
    # vfprintf path is where 109 on-device SIGSEGVs died (2026-10-21).
    noc = dev("grep -a -F -c '%0*lld' /data/gw/bin/logc 2>/dev/null").strip()
    cen = dev("grep -c 'ne_census' /data/gw/log_keeper.sh /data/gw/watchdog.sh 2>/dev/null").split()
    met = dev("ls /data/gw/logs/cores/meta 2>/dev/null | wc -l").strip()
    ok = (pat.startswith("|/data/gw/core_meta.sh") and ex == "y" and fwd == "y"
          and lv == "logc 1.4" and noc == "0"
          and "rc=0" in st and "PASS" in fz and "rc=0" in fz
          and len(cen) == 2 and all(int(x) > 0 for x in cen if x.isdigit()))
    record(t_p1_forensics._test_name, "system", ok,
           "pattern=[%s] wrapper=%s fwd=%s logc=%s printf_sym=%s selftest=[%s] fuzz=[%s] census=%s meta_files=%s"
           % (pat, ex, fwd, lv, noc, st[-100:], fz[-100:], cen, met))


@test("stability P1: healthdog 综合判据 (稳定窗后 arm / 防环)")
def t_p1_healthdog():
    hd = dev("cat /proc/healthdog 2>/dev/null").strip()
    st = dev("grep -c 'ARM REFUSED' /tmp/healthdog.log 2>/dev/null").strip()
    start = dev("grep -c 'start v1.6' /tmp/healthdog.log 2>/dev/null").strip()
    hb = dev("cat /tmp/healthdog.hb 2>/dev/null").strip()
    up = dev("cut -d. -f1 /proc/uptime").strip()
    fresh = hb.isdigit() and up.isdigit() and (int(up) - int(hb)) < 90
    # armed=1 is legitimate only after a stable window; the heartbeat file and
    # the v1.6 start line are mandatory either way.
    ok = (int(start or 0) >= 1 and fresh and "armed=" in hd)
    record(t_p1_healthdog._test_name, "system", ok,
           "hd=[%s] start=%s hb=%s fresh=%s refused=%s" % (hd, start, hb, fresh, st))


@test("stability P1: hostapd/wifi_guard 决策硬化")
def t_p1_radio():
    hp = dev("for p in 'control socket' 'clients=' 'svc_hostapd_up' 'recover hostapd'; do "
             "grep -c -- \"$p\" /data/gw/watchdog.sh; done").split()
    wg = dev("for p in 'STREAK' 'bounce budget' 'stations' 'boot_bounces'; do "
             "grep -c -- \"$p\" /data/gw/wifi_guard.sh; done").split()
    hp = [int(x) for x in hp if x.strip().isdigit()]
    wg = [int(x) for x in wg if x.strip().isdigit()]
    en = dev("hostapd_cli -i ra0 status 2>/dev/null | grep -c '^state=ENABLED'").strip()
    hb = dev("cat /tmp/wifi_guard.hb 2>/dev/null").strip()
    up = dev("cut -d. -f1 /proc/uptime").strip()
    fresh = hb.isdigit() and up.isdigit() and (int(up) - int(hb)) < 90
    ok = (len(hp) == 4 and all(x > 0 for x in hp) and len(wg) == 4
          and all(x > 0 for x in wg) and en == "1" and fresh)
    record(t_p1_radio._test_name, "system", ok,
           "hostapd_checks=%s wifi_guard_checks=%s enabled=%s hb_fresh=%s"
           % (hp, wg, en, fresh))


@test("stability P1: 取证降噪/pstore/BOOT 门禁/logc 统计")
def t_p1_logpipe():
    fore = dev("cat /sys/module/healthdog/parameters/forensic 2>/dev/null").strip()
    noise = dev("awk '/^===== BOOT/{n=0} /FORENSIC D:/{n++} END{print n+0}' /data/gw/logs/dmesg.log 2>/dev/null").strip()
    ps = dev("ls /data/gw/logs/pstore 2>/dev/null | wc -l").strip()
    psrc = dev("test -s /sys/fs/pstore/console-ramoops-0 && echo y").strip()
    bootga = dev("grep -c 'boot_btime' /data/gw/log_keeper.sh 2>/dev/null").strip()
    bidw = dev("cat /data/gw/logs/.boot_id 2>/dev/null").strip()
    bidc = dev("cat /proc/sys/kernel/random/boot_id 2>/dev/null").strip()
    stats = dev("cat /tmp/logc.stats 2>/dev/null").strip()

    def kv(k):
        for part in stats.replace("\n", " ").split():
            if part.startswith(k + "="):
                return part.split("=", 1)[1]
        return ""

    bad = kv("bad_frames"); rs = kv("resyncs"); io = kv("io_errors")
    pstore_ok = int(ps or 0) >= 1 or psrc != "y"
    met = dev("tail -n 1 /data/gw/logs/stability_metrics.tsv 2>/dev/null").strip()
    metn = dev("wc -l < /data/gw/logs/stability_metrics.tsv 2>/dev/null || echo 0").strip()
    ok = (fore == "0" and noise == "0" and pstore_ok
          and int(bootga or 0) > 0 and bidw == bidc and io == "0"
          and bad.isdigit() and rs.isdigit() and int(bad) <= 2 and int(rs) <= 2
          and int(metn or 0) > 0 and "logc_rc=" in met and "repairs_1h=" in met)
    record(t_p1_logpipe._test_name, "system", ok,
           "forensic=%s forensic_lines=%s pstore=%s src=%s boot_btime=%s boot_id_match=%s stats=[%s] metrics=%s/[%s]"
           % (fore, noise, ps, psrc, bootga, bidw == bidc, stats, metn, met[:120]))


@test("stability batch4: awk 数组/logcut 回归护栏 (SIGSEGV 家族)")
def t_batch4_awk_arrays():
    # busybox awk 1.36.1: ANY runtime array (empty via split("", A)/delete A,
    # or filled) can make its exit cleanup dereference NULL in ~1% of runs
    # (2026-10-21 core: ldr w0,[x19,#4] with x19=0).  On-device A/B: empty
    # array 4/400, mid-file anchor 2/300, no array 0/400.  delta() therefore
    # uses our static logcut and no deployed script may use awk arrays.
    hits = dev("grep -lF 'split(\"\"' /data/gw/*.sh /data/gw/www/*.sh 2>/dev/null | wc -l").strip()
    dl = dev("grep -cF 'delete B' /data/gw/log_keeper.sh 2>/dev/null").strip()
    ak = dev("grep -c 'awk -v last=' /data/gw/log_keeper.sh 2>/dev/null").strip()
    lv = dev("/data/gw/bin/logcut -V 2>/dev/null").strip()
    ls = dev("/data/gw/bin/logcut --selftest 2>&1; echo rc=$?").strip()
    ok = (hits == "0" and dl == "0" and ak == "0" and lv == "logcut 1.0"
          and "PASS" in ls and "rc=0" in ls)
    record(t_batch4_awk_arrays._test_name, "system", ok,
           "split_empty_files=%s delete_B=%s awk_delta=%s logcut=%s selftest=[%s]"
           % (hits, dl, ak, lv, ls[-80:]))


@test("usb: 设备模式服务面 (usb_mgr 守护/gadget绑定/键位)")
def t_usb_service():
    # USB 轮 (2026-10-24): 厂商遗留 g1 gadget 链 + usb_mgr 服务补完.
    #   控制面: 守护活 + UDC 绑定 + SVC_TABLE 行; 状态面: status 输出形状.
    # 按当前 USB_ENABLED 分档断言(1=在役契约; 0=全灭契约).
    en = dev("sh /data/gw/usb_mgr.sh status 2>/dev/null | head -1").strip()
    dpid = dev("pgrep -f 'usb_mgr[.]sh daemon' 2>/dev/null").strip()
    udc = dev("cat /config/usb_gadget/g1/UDC 2>/dev/null").strip()
    row = dev("grep -c 'usb_mgr' /data/gw/svc_lib.sh 2>/dev/null").strip()
    st = dev("sh /data/gw/usb_mgr.sh status 2>/dev/null").strip()
    keys = (("enabled=" in st) and ("udc=" in st) and ("bridge=" in st)
            and ("adbd=" in st) and ("gate=" in st) and ("getty=" in st))
    if "enabled=1" in en:
        ok = (dpid != "" and udc == "11201000.usb" and row != "0" and keys)
        note = "on daemon=%s udc=%s" % (dpid or "MISSING", udc)
    elif "enabled=0" in en:
        ok = (udc != "11201000.usb" and keys)
        note = "off udc=[%s] (unbound expected)" % udc
    else:
        ok, note = False, "status unreadable"
    record(t_usb_service._test_name, "system", ok, note)


@test("usb: RNDIS 数据面不变量 (rndis0 桥入 br-lan)")
def t_usb_dataplane():
    # 数据面: enabled=1 时 rndis0 必须是 br-lan 成员且 UP — "PC 即 LAN 客户端"
    # 的充要条件; enabled=0 时必须不在桥中(隔离不变量).
    en = dev("sh /data/gw/usb_mgr.sh status 2>/dev/null | head -1").strip()
    br = dev("brctl show br-lan 2>/dev/null | grep -cw rndis0").strip()
    fl = dev("cat /sys/class/net/rndis0/flags 2>/dev/null").strip()
    iup = "1" if fl.startswith("0x") and (int(fl, 16) & 1) else "0"
    if "enabled=1" in en:
        ok = (br == "1" and iup == "1")
        note = "bridge=%s ifup=%s" % (br, iup)
    elif "enabled=0" in en:
        ok = (br == "0")
        note = "bridge=%s (detached expected)" % br
    else:
        ok, note = False, "status unreadable"
    record(t_usb_dataplane._test_name, "system", ok, note)


@test("census batch: pidof/pgrep 自研替代在位 (procmatch)")
def t_batch4_procmatch():
    # busybox pidof is ~2.7 crashes/day (logs/ne_events.tsv) and pgrep -x is
    # quirky; the farm now points pidof/pgrep at the static, printf-free
    # procmatch.  Guard: version, farm resolution, and live behaviour.
    v = dev("/data/gw/bin/procmatch -V 2>/dev/null").strip()
    rd_pid = dev("readlink /data/gw/sbin/pidof 2>/dev/null").strip()
    rd_pg = dev("readlink /data/gw/sbin/pgrep 2>/dev/null").strip()
    pid = dev("pidof logd 2>/dev/null").strip()
    pg = dev("pgrep -f 'log_keeper[.]sh' 2>/dev/null").strip()
    ok = (v == "procmatch 1.0" and rd_pid.endswith("/procmatch")
          and rd_pg.endswith("/procmatch") and pid != "" and pg != "")
    record(t_batch4_procmatch._test_name, "system", ok,
           "ver=%s pidof=%s pgrep=%s logd=[%s] lk=[%s]" % (v, rd_pid, rd_pg, pid, pg))


@test("stability batch3: 统一监督/锁/心跳 + netcfg 串行化 + logc fuzz")
def t_p2_batch3():
    # Structural batch 3 (2026-10-20): one supervision/lock/heartbeat library,
    # netcfg writer serialization, static parsers, and the logc fuzz harness.
    sl = dev("for p in 'SVC_TABLE' 'svc_lock()' 'svc_hb()' 'svc_bss_count()' "
             "'svc_zombies()' 'svc_dmesg_count()'; do "
             "grep -c -- \"$p\" /data/gw/svc_lib.sh; done").split()
    sl = [int(x) for x in sl if x.strip().isdigit()]
    nl = dev("for p in 'netcfg_lock()' 'flock' 'netcfg_repair()'; do "
             "grep -c -- \"$p\" /data/gw/netlock.sh; done").split()
    nl = [int(x) for x in nl if x.strip().isdigit()]
    daemons = ["ntp_keeper", "traffic_logger", "reboot_sched", "fan_mgr", "wan_eth",
               "wifi_guard", "log_keeper", "core_trap", "healthdog", "boot_gate",
               "led_mgr", "dial_keeper"]
    dlock = dev("for f in %s; do grep -c 'svc_lock ' /data/gw/$f.sh; done"
                % " ".join(daemons)).split()
    dlock = [int(x) for x in dlock if x.strip().isdigit()]
    writers = ["wan_agg.sh", "wan_agg_lib.sh", "wan_eth.sh", "rc_netfh.sh",
               "fw_apply.sh", "ccmni_up.sh", "guest_fw.sh"]
    wl = dev("for f in %s; do grep -c 'netcfg_lock' /data/gw/$f; done"
             % " ".join(writers)).split()
    wl = [int(x) for x in wl if x.strip().isdigit()]
    flock = dev("/data/gw/bin/busybox --list 2>/dev/null | grep -cx flock").strip()
    fz = dev("/data/gw/bin/logc --fuzz 100 2>&1; echo rc=$?").strip()
    rows = dev("grep -c '|sh /data/gw/' /data/gw/svc_lib.sh 2>/dev/null").strip()
    led = dev("test -f /data/gw/logs/netcfg_repairs.tsv || test -f /tmp/netcfg_repairs.tsv; echo $?").strip()
    ok = (len(sl) == 6 and all(x > 0 for x in sl)
          and len(nl) == 3 and all(x > 0 for x in nl)
          and len(dlock) == len(daemons) and all(x > 0 for x in dlock)
          and len(wl) == len(writers) and all(x > 0 for x in wl)
          and flock == "1" and "PASS" in fz and "rc=0" in fz
          and int(rows or 0) >= 11 and led == "0")
    record(t_p2_batch3._test_name, "system", ok,
           "svc=%s netlock=%s daemons=%s writers=%s flock=%s rows=%s ledger=%s fuzz=[%s]"
           % (sl, nl, dlock, wl, flock, rows, led, fz[-80:]))


@test("fixstack: dpquar/dpclamp 在位且 v1.4 遥测面活着 (§8.10.2/§8.11)")
def t_fixstack():
    # SIGSEGV 修复栈部署契约: 双模块装载, dpquar 补丁生效, dpclamp v1.4 的
    # /proc v2 遥测(deep/burst/trig/seed 段 + pfns 导出)可读 —— 自载/热换后
    # 的常驻断言。sched 计数前进性由 avail_sampler 的 SW_STUCK 通道覆盖。
    dq = dev("head -1 /proc/dpquar 2>/dev/null").strip()
    dc = dev("head -1 /proc/dpclamp 2>/dev/null").strip()
    d2 = dev("grep -c '^deep deeps=' /proc/dpclamp 2>/dev/null").strip()
    b2 = dev("grep -c '^burst bursts=' /proc/dpclamp 2>/dev/null").strip()
    t2 = dev("grep -c '^trig episodes=' /proc/dpclamp 2>/dev/null").strip()
    ring = dev("grep -c '^ring$' /proc/dpclamp 2>/dev/null").strip()
    sd = dev("grep -c '^seed fed=' /proc/dpclamp 2>/dev/null").strip()
    pf = dev("test -r /proc/dpclamp_pfns; echo $?").strip()
    ok = (dq.startswith("dpquar patched=1")
          and dc.startswith("dpclamp") and "clamped=" in dc
          and d2 == "1" and b2 == "1" and t2 == "1" and ring == "1"
          and sd == "1" and pf == "0")
    record(t_fixstack._test_name, "system", ok,
           "dpquar=[%s] dpclamp=[%s] deep=%s burst=%s trig=%s ring=%s seed=%s pfns_rc=%s"
           % (dq[:44], dc[:64], d2, b2, t2, ring, sd, pf))



@test("avail: 可用性采样器/数据文件/API 域在位 (P1)")
def t_avail():
    # AVAILABILITY_DESIGN P1: sampler 由 log_keeper v2.9 10min 驱动(CYC=1 首采),
    # watchdog v1.31 提供 cycle 新鲜度键与分频/访客/radvd 判决键。
    gap = dev("up=$(cut -d. -f1 /proc/uptime); hb=$(cat /tmp/avail_sampler.hb 2>/dev/null); "
              "[ -n \"$hb\" ] && echo $((up - hb)) || echo -1").strip()
    roster = dev("wc -l < /tmp/avail_last 2>/dev/null").strip()
    keys = dev("for k in bss2g bss5g radvd cycle http200 dnssvc dp5g dpeth; do "
               "grep -c \"^$k=\" /tmp/watchdog_state 2>/dev/null; done").split()
    hf = dev("test -f /data/gw/logs/avail_hourly.tsv; echo $?").strip()
    tf = dev("test -f /data/gw/logs/avail_transitions.tsv; echo $?").strip()
    syn = dev("sh -n /data/gw/avail_sampler.sh 2>&1 && sh -n /data/gw/www/api_avail.sh 2>&1; echo $?").strip()
    rte = dev("grep -c '^    avail)' /data/gw/www/api.sh 2>/dev/null").strip()
    ok = (gap.lstrip("-").isdigit() and 0 <= int(gap) <= 1500
          and roster.isdigit() and int(roster) >= 24
          and len(keys) == 8 and all(x == "1" for x in keys)
          and hf == "0" and tf == "0" and syn == "0" and rte == "1")
    record(t_avail._test_name, "system", ok,
           "hb_gap=%s roster=%s keys=%s hf=%s tf=%s syntax=%s route=%s"
           % (gap, roster, keys, hf, tf, syn, rte))

@test("avail: NE 假归因演练 (v1.5: 死者≠活实例不得置 deg)")
def t_avail_ne_drill():
    # 2026-10-25 假红实弹的证伪演练 (判据变更必须带演练): 注入一条
    # cmdline=watchdog.sh 的伪 NE 行 + 回退 ne 游标 + 手动跑一轮采样器,
    # 断言 sys.supervisor 不产生 op->deg (主实例全程健康, 11:03 事故里
    # 死者是部署残留实例)。结束后删伪行并把游标钉回真实行数, 不留污染。
    pre = dev("wc -l < /data/gw/logs/ne_events.tsv").strip()
    pretr = dev("wc -l < /data/gw/logs/avail_transitions.tsv").strip()
    if not (pre.isdigit() and pretr.isdigit()):
        record(t_avail_ne_drill._test_name, "system", False, "ledger unreadable")
        return
    dev("printf '%s\t99999\tsh\tsig=11\texe=/data/gw/bin/busybox"
        "\targs=sh /data/gw/watchdog.sh\n' >> /data/gw/logs/ne_events.tsv")
    dev("sed -i \"4s/.*/%s/\" /tmp/avail_sess" % pre)
    dev("sh /data/gw/avail_sampler.sh >/dev/null 2>&1; echo ran", timeout=45)
    sup = dev("tail -n +%d /data/gw/logs/avail_transitions.tsv 2>/dev/null | "
              "grep -c 'sys.supervisor'" % (int(pretr) + 1)).strip()
    lv = dev("grep '^sys.supervisor|' /tmp/avail_last 2>/dev/null | "
             "cut -d'|' -f4").strip()
    # cleanup: 伪行删除 + 游标钉回真实行数(防下一窗重扫全史)
    dev("sed -i '$d' /data/gw/logs/ne_events.tsv; "
        "_n=$(wc -l < /data/gw/logs/ne_events.tsv); sed -i \"4s/.*/$_n\" /tmp/avail_sess")
    ok = (sup == "0" and lv == "op")
    record(t_avail_ne_drill._test_name, "system", ok,
           "supervisor_transitions_in_window=%s level=%s" % (sup, lv))


def main():
    # v2.51: the suite prints ✓/✗; a Windows GBK console raised
    # UnicodeEncodeError mid-run (aborting deploy.py's post-deploy gate).
    for _s in (sys.stdout, sys.stderr):
        try:
            _s.reconfigure(encoding="utf-8", errors="replace")
        except Exception:
            pass
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
