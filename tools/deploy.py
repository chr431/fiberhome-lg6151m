#!/usr/bin/env python3
"""deploy.py -- single source of truth for PC<->CPE deployment + drift guard.

Kills the version-drift failure class (2026-10-01 lesson: dispatcher script-name
drift made three fix experiments silently never run; /data/gw accumulated
rc_v3/v6/v7/min + wan_policy.sh.v5/.v6 corpses).

Rules:
  1. MANIFEST below is the ONLY deployment truth. Device files not in it go to
     attic/ on `attic`. Dispatcher (rc.extend.sh) may only reference manifest
     names.
  2. `push` refuses files that are tracked-but-dirty or untracked: only
     committed states deploy (git ls-files / git status enforced).
  3. Every deployed .sh gets a '#DEPLOY <git-short> <utc>' provenance stamp
     injected under the shebang (device-side self-identification: "did my fix
     even run" becomes one grep).
  4. `doctor` compares md5 both sides for every manifest entry, checks
     dispatcher references, reports drift. Exit 1 on drift (CI-able).
  5. Version registry (tools/VERSIONS.tsv) gates everything: every command
     runs `vercheck check` first (fail closed), `push` injects
     '#DEPLOY <name>:<ver> <hash> <utc>' so device copies self-identify,
     `snapshot` writes /data/gw/VERSIONS, `doctor` diffs it vs registry.

Usage:
  python tools/deploy.py doctor            # full drift report (md5 + versions)
  python tools/deploy.py push [name ...]   # deploy (default: all drifted)
  python tools/deploy.py attic             # move non-manifest /data/gw/*.sh to attic/
  python tools/deploy.py snapshot          # write /data/gw/{DEPLOY_MANIFEST,VERSIONS}
"""
import sys, os, re, hashlib, subprocess
import datetime

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 凭证外置: _local/secrets/device_local.py (LG_SECRETS_DIR 可覆盖)
SECRETS = os.path.abspath(os.environ.get("LG_SECRETS_DIR")
                          or os.path.join(REPO, "..", "_local", "secrets"))
sys.path.insert(0, SECRETS)
sys.path.insert(0, REPO)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import device_local as D  # noqa: E402  (from _local/secrets/)
import paramiko           # noqa: E402
import vercheck           # noqa: E402  (pure-stdlib; registry single source)
import lgssh              # noqa: E402  (v2.11: PinPolicy 主机密钥指纹钉死复用)

MGMT_CANDIDATES = ["192.168.9.1", "192.168.1.1", "192.168.8.1", "192.168.3.75"]
# 9.1 = v3 br-lan (current), 1.1 = v2 factory LAN, 8.1/3.75 = legacy fallbacks

# local (relative to repo) -> device path. Order = boot-time order.
MANIFEST = [
    ("gw/rc.extend.sh", "/data/rc.extend.sh"),         # slot dispatcher (boot entry)
    ("gw/v3_rc10.extend.sh", "/data/gw/rc19.sh"),         # rc19v2: br-lan+wifi+wan stack
    ("gw/wifi_up.sh", "/data/gw/wifi_up.sh"),      # AP bring-up (factory recipe)
    ("gw/guest_fw.sh", "/data/gw/guest_fw.sh"),    # guest-net L2/L3 isolation (vendor wifiguest.sh recipe)
    ("gw/wan_agg.sh", "/data/gw/wan_agg.sh"),       # dual-uplink aggregation supervisor (v2.8+, supersedes wan_policy2)
    ("gw/bin/multiwan_ctl", "/data/gw/multiwan_ctl"),     # vendor multiwan ioctl control (zig, links libfhdrv_net_api)
    ("gw/bin/fhstub.so", "/data/gw/fhstub.so"),        # FH symbol stubs: load libfhdrv_net_api standalone
    ("gw/udhcpc_wan.script", "/data/gw/udhcpc_wan.script"), # WAN udhcpc event hook (iface-agnostic)
    ("gw/healthdog.sh", "/data/gw/healthdog.sh"),    # userspace heartbeat
    ("gw/v3_babysit_v2.sh", "/data/gw/babysit_v2.sh"),   # boot babysitter
    ("gw/night_report.sh", "/data/gw/night_report.sh"),
    ("gw/wifi_guard.sh", "/data/gw/wifi_guard.sh"),   # BA-stall auto-recovery
    ("gw/bin/wpapmk", "/data/gw/wpapmk"),          # WPA passphrase->PMK (fh hostapd only eats wpa_psk)
    ("gw/bin/mipc_cellular", "/data/gw/mipc_cellular"),  # cellular MIPC direct CLI (P1 engine base)
    ("gw/mipc_dial_trace.sh", "/data/gw/mipc_dial_trace.sh"),  # 5G dial forensics
    ("gw/dial_5g.sh", "/data/gw/dial_5g.sh"),      # production 5G dialer
    ("gw/v2_access.sh", "/data/gw/v2_access.sh"),    # slot-B serial/SSH hardening
    ("gw/consfeed.sh", "/data/gw/consfeed.sh"),      # v2 console feeder (spawned by v2_access)
    ("gw/dial_variant.sh", "/data/gw/dial_variant.sh"),   # 5G dial param experiments (iptype/apn/plmn)
    ("gw/capture_ubus.sh", "/data/gw/capture_ubus.sh"),   # one-shot stock-dial ubus monitor capture
    ("gw/rc_netfh.sh", "/data/gw/rc_netfh.sh"),       # route A: FH modem-stack env (minimal army)
    ("gw/radvd.conf", "/data/gw/radvd.conf"),        # IPv6 SLAAC+RDNSS advert (FH radvd 1.6)
    ("gw/led_mgr.sh", "/data/gw/led_mgr.sh"),        # stock-style LED state supervisor (visual-mapped GPIOs)
    ("gw/bin/v3httpd", "/data/gw/v3httpd"),           # gateway GUI http server (:80)
    ("gw/www/api.sh", "/data/gw/www/api.sh"),        # JSON endpoints
    ("gw/www/index.html", "/data/gw/www/index.html"),    # console page
    ("gw/www/style.css", "/data/gw/www/style.css"),     # theme
    ("gw/www/app.js", "/data/gw/www/app.js"),        # SPA router+pages (v2.0)
    ("gw/fw_apply.sh", "/data/gw/fw_apply.sh"),       # port-fwd/DMZ/block installer (boot+api)
    ("gw/cellular_replay.sh", "/data/gw/cellular_replay.sh"),# cellular band/cell-lock boot replay
    ("gw/dial_keeper.sh", "/data/gw/dial_keeper.sh"),        # P2: fallback dial keeper (mobilenetwork-independent)
    ("gw/bin/shmsnap", "/data/gw/shmsnap"),          # cfgmgr tree shm snapshot tool
    ("gw/ntp_keeper.sh", "/data/gw/ntp_keeper.sh"),    # hourly NTP keeper (no RTC battery)
    ("gw/webs_revive.sh", "/data/gw/webs_revive.sh"),   # stock GUI revival (manual, self-contained)
    ("gw/fan_mgr.sh", "/data/gw/fan_mgr.sh"),        # stock-ladder thermal fan supervisor
    ("gw/fan_mode.conf", "/data/gw/fan_mode.conf"),     # performance | silent
    ("gw/bin/healthdog.ko", "/data/gw/healthdog.ko"),
    ("gw/bin/v3_fix.ko", "/data/gw/v3_fix.ko"),
    ("gw/bin/v3_steth.ko", "/data/gw/v3_steth.ko"),
    ("gw/udhcpc_eth1.script", "/data/gw/udhcpc_eth1.script"),
    ("gw/defaults.conf", "/data/gw/defaults.conf"),
    ("gw/watchdog.sh", "/data/gw/watchdog.sh"),  # L13: continuous invariant monitor
    ("gw/wedge_watch.sh", "/data/gw/wedge_watch.sh"),
    ("gw/zz_data_hook", "/data/build/rootfs/etc/init.d/zz_data_hook"),     # hook-slot watchdog (stethoscope)
]

DEVICE_SET = {remote for _, remote in MANIFEST}
# runtime tools that live in /data/gw but are not part of the deploy set
EXTRA_KEEP = ["DEPLOY_MANIFEST", "ppe_reg",
              "udhcpc_eth1.script", "portal_auth", "restore_wan.sh",
              "agg_pins.conf",   # 含用户MAC的钉死表: 设备侧自管(模板见 agg_pins.conf.example)
              "dropbear_keys",   # rc.extend v1.8 唯一属主启动的宿主密钥目录(设备侧生成)
              "DO_UBUS_CAP", "MODE.fh"]  # rc.extend.sh 运行时模式标记(dispatcher引用, 非脚本)
MD5_LINE = re.compile(r"^([0-9a-f]{32})  (.*)$", re.M)


def sh(cmd, timeout=30):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                          timeout=timeout, cwd=REPO).stdout.strip()


def connect(tries=2):
    import time
    # v2.10: env 覆盖支持(与 lgssh 凭证链对齐) — 轮换窗口期 device_local 已是新
    # 口令而设备仍是旧口令, rotate_toor 经 LG_TOOR_PASS 注入旧口令调用本工具
    hosts = [os.environ["LG_HOST"]] if os.environ.get("LG_HOST") else MGMT_CANDIDATES
    user = os.environ.get("LG_TOOR_USER") or D.TOOR_USER
    pw = os.environ.get("LG_TOOR_PASS") or D.TOOR_PASS
    for _ in range(tries):
        for ip in hosts:
            try:
                c = paramiko.SSHClient()
                # v2.11: 指纹钉死(lgssh.PinPolicy, 见 lgssh v1.3); 未配置指纹时兼容旧行为
                c.set_missing_host_key_policy(
                    lgssh.PinPolicy() if lgssh.PIN else paramiko.AutoAddPolicy())
                c.connect(ip, port=22, username=user, password=pw,
                          timeout=10, allow_agent=False, look_for_keys=False,
                          banner_timeout=20)
                return c, ip
            except Exception:
                continue
        time.sleep(2)
    sys.exit("!! no mgmt path to CPE (tried %s)" % hosts)


def ssh_cmd(c, cmd, timeout=25, stdin_data=None):
    si, so, se = c.exec_command(cmd, timeout=timeout)
    if stdin_data is not None:
        si.write(stdin_data)
        si.flush()
        si.channel.shutdown_write()
    return so.read().decode(errors="replace")


def remote_exists(c, path):
    return ssh_cmd(c, "[ -e %s ] && echo y" % path).strip() == "y"


def git_state(local):
    """('clean'|"DIRTY", 'tracked'|'UNTRACKED') for a manifest member."""
    rel = local.replace("/", "\\") if os.name == "nt" else local
    tracked = sh('git ls-files --error-unmatch "%s" 2>nul' % rel if os.name == "nt"
                 else 'git ls-files --error-unmatch "%s" 2>/dev/null' % rel) != ""
    dirty = sh('git status --porcelain -- "%s"' % local) != ""
    return ("DIRTY" if dirty else "clean"), ("tracked" if tracked else "UNTRACKED")


def stamp(local, data):
    """Inject/refresh '#DEPLOY <name>:<ver> <hash> <utc>' under the shebang
    (device copy only). Version comes from tools/VERSIONS.tsv -- registry
    misses are fatal (fail closed)."""
    if not local.endswith(".sh"):
        return data
    try:
        ver = vercheck.version_of(local)
    except KeyError:
        sys.exit("!! %s 无版本注册行(tools/VERSIONS.tsv) -- 先登记再部署" % local)
    hash_ = sh("git log -1 --format=%%h -- %s" % local) or "no-git"
    line = "#DEPLOY %s:v%s %s %s" % (local, ver, hash_,
                                     datetime.datetime.utcnow().strftime("%Y%m%dT%H%MZ"))
    text = data.decode("utf-8")
    lines = text.split("\n")
    if lines and lines[0].startswith("#!"):
        if len(lines) > 1 and lines[1].startswith("#DEPLOY"):
            lines[1] = line
        else:
            lines.insert(1, line)
    else:
        lines.insert(0, line)
    return "\n".join(lines).encode("utf-8")


def local_md5(path):
    try:
        return hashlib.md5(open(path, "rb").read()).hexdigest()
    except OSError:
        return None


def remote_md5s(c):
    out = ssh_cmd(c, "md5sum %s 2>/dev/null" % " ".join(r for _, r in MANIFEST))
    return {m.group(2): m.group(1) for m in MD5_LINE.finditer(out)}


def doctor():
    c, ip = connect()
    print("mgmt via %s   (UTC %s)\n" % (ip, datetime.datetime.utcnow().strftime("%F %T")))
    rem = remote_md5s(c)
    drift = []
    for local, remote in MANIFEST:
        lp = os.path.join(REPO, local)
        lm = local_md5(lp)
        rm = rem.get(remote)
        st, tr = git_state(local)
        # stamped copy differs from local by design; compare content minus stamp
        if lm is None:
            flag = "LOCAL-MISSING"
        elif rm is None:
            flag = "device-missing"
        elif local.endswith(".sh"):
            # running ash scripts must NOT be rewritten just for a stamp
            # (busybox reads scripts incrementally) -> compare content only
            dev_txt = ssh_cmd(c, "grep -v '^#DEPLOY ' %s 2>/dev/null | md5sum" % remote).split()[0]
            flag = "OK" if lm == dev_txt else "DRIFT"
        else:
            flag = "OK" if lm == rm else "DRIFT"
        marks = [x for x in (st, tr) if x not in ("clean", "tracked")]
        print("%-22s %-28s %-8s %-10s %s" % (local, remote, flag, st[:5], " ".join(marks)))
        if flag != "OK" or marks:
            drift.append((local, flag, marks))
    # dispatcher sanity: only manifest names referenced
    disp = ssh_cmd(c, "grep -oE '/data/gw/[A-Za-z0-9_.-]+' /data/rc.extend.sh | sort -u")
    allowed_refs = DEVICE_SET | {"/data/gw/" + k for k in EXTRA_KEEP}
    bad_refs = [r for r in disp.split() if r not in allowed_refs]
    print("\ndispatcher refs: %s%s" % (disp.replace("\n", " "), ("  !! UNKNOWN: %s" % bad_refs) if bad_refs else ""))
    # stray device scripts
    keep_base = {os.path.basename(r) for r in DEVICE_SET} | set(EXTRA_KEEP)
    strays = [s for s in ssh_cmd(c, "ls /data/gw/*.sh 2>/dev/null").split()
              if os.path.basename(s) not in keep_base]
    if strays:
        print("stray device scripts (attic candidates): %s" % " ".join(strays))
    # device VERSIONS vs registry (version-level drift, complements md5)
    reg = {r[0]: r[1] for r in vercheck.load_registry()}
    vout = ssh_cmd(c, "cat /data/gw/VERSIONS 2>/dev/null")
    stale = []
    for line in vout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[0] in reg and parts[1] != reg[parts[0]]:
            stale.append("%s device=v%s local=v%s" % (parts[0], parts[1], reg[parts[0]]))
    if stale:
        print("VERSIONS stale (%d): %s" % (len(stale), "; ".join(stale)))
        drift.extend(stale)
    c.close()
    if drift or bad_refs:
        print("\nVERDICT: DRIFT (%d issues)" % (len(drift) + len(bad_refs)))
        return 1
    print("\nVERDICT: CLEAN")
    return 0


def push(names=None):
    targets = MANIFEST
    if names:
        targets = [t for t in MANIFEST if t[0] in names or os.path.basename(t[1]) in names]
        if not targets:
            sys.exit("!! no manifest entry matches %s" % names)
    c, ip = connect()
    print("pushing via %s" % ip)
    for local, remote in targets:
        lp = os.path.join(REPO, local)
        st, tr = git_state(local)
        if st == "DIRTY" or tr == "UNTRACKED":
            print("REFUSED %-22s %s/%s -- commit it first" % (local, st, tr))
            continue
        data = open(lp, "rb").read()
        if local.endswith(".sh"):
            assert b"\r\n" not in data, "CRLF in %s" % local
            # never rewrite a script whose content already matches (stamps are
            # deployed only alongside real changes; running ash reads lazily)
            dev_txt = ssh_cmd(c, "grep -v '^#DEPLOY ' %s 2>/dev/null | md5sum" % remote).split()[0] if remote_exists(c, remote) else None
            if dev_txt == hashlib.md5(data).hexdigest():
                print("%-22s -> %-26s SKIP (content equal, stamp-only)" % (local, remote))
                continue
        elif remote_exists(c, remote) and ssh_cmd(c, "md5sum %s" % remote).split()[0] == hashlib.md5(data).hexdigest():
            print("%-22s -> %-26s SKIP (identical)" % (local, remote))
            continue
        data = stamp(local, data)
        ssh_cmd(c, "mkdir -p %s" % os.path.dirname(remote))
        ssh_cmd(c, "cat > %s && chmod +x %s" % (remote, remote), stdin_data=data)
        got_out = ssh_cmd(c, "md5sum %s 2>/dev/null" % remote).split()
        got = got_out[0] if got_out else "ABSENT"
        want = hashlib.md5(data).hexdigest()
        print("%-22s -> %-26s %s" % (local, remote, "OK" if got == want else "MD5-MISMATCH"))
    c.close()


def push_serial(names=None):
    """Deploy via the serial console daemon (serial_cmd.py) -- the only path
    when no network route to the CPE exists. b64 line-by-line + on-device
    decode + md5 verify. Text (.sh) files only."""
    import base64, subprocess as sp
    targets = [t for t in MANIFEST if t[0].endswith(".sh")]
    if names:
        picks = []
        for n in names:
            for t in targets:
                if t[0] == n or os.path.basename(t[1]) == n or t[0].startswith(n) or os.path.basename(t[1]).startswith(n):
                    picks.append(t)
        targets = picks
    def scmd(cmd, t=60):
        r = sp.run([sys.executable, os.path.join(REPO, "tools", "serial_cmd.py"), "--t", str(t), cmd],
                   capture_output=True, text=True, timeout=t + 40)
        return r.stdout
    for local, remote in targets:
        lp = os.path.join(REPO, local)
        data = open(lp, "rb").read()
        assert b"\r\n" not in data, "CRLF in %s" % local
        b64 = base64.encodebytes(data).decode().splitlines()
        scmd("rm -f /tmp/dp.b64")
        for i, chunk in enumerate(b64):
            out = scmd("echo %s >>/tmp/dp.b64" % chunk, 20)
            if i % 20 == 0:
                print("  %s: %d/%d" % (local, i + 1, len(b64)))
        want = hashlib.md5(data).hexdigest()
        # v2.1 (2026-10-03 教训: 串口噪声打坏 b64 行, 首推 v6.0 损坏上设备):
        # md5 失配自动整文件重推, 最多 3 次; 仍失配则醒目报错退出非零
        for attempt in range(1, 4):
            out = scmd("openssl base64 -d </tmp/dp.b64 > %s 2>/tmp/dp.err; chmod +x %s; md5sum %s" % (remote, remote, remote), 30)
            got = [l for l in out.splitlines() if want in l]
            if got:
                break
            print("%-22s attempt %d MD5-MISMATCH -- rewriting whole file" % (local, attempt))
            scmd("rm -f /tmp/dp.b64")
            for chunk in b64:
                scmd("echo %s >>/tmp/dp.b64" % chunk, 20)
        print("%-22s -> %-26s %s" % (local, remote, "OK" if got else "MD5-MISMATCH"))
        if not got:
            print(out[-200:])
            sys.exit(5)


def attic():
    c, ip = connect()
    keep_names = {os.path.basename(r) for _, r in MANIFEST}
    extra = EXTRA_KEEP   # runtime tools kept in place
    strays = [s for s in ssh_cmd(c, "ls /data/gw/ 2>/dev/null").split()
              if s not in keep_names and s not in extra and s.endswith(".sh")]
    if not strays:
        print("nothing to attic"); c.close(); return
    print("attic: %s" % " ".join(strays))
    ssh_cmd(c, "mkdir -p /data/gw/attic && cd /data/gw && mv %s attic/ 2>/dev/null" % " ".join(strays))
    print("kept in place: manifest + %s" % " ".join(sorted(extra)))
    c.close()


def snapshot():
    c, ip = connect()
    lines = ["# DEPLOY_MANIFEST written %s UTC" % datetime.datetime.utcnow().isoformat()]
    vlines = ["# VERSIONS (name<TAB>ver<TAB>device_md5<TAB>local_md5) written %s UTC"
              % datetime.datetime.utcnow().isoformat()]
    reg = {r[0]: r for r in vercheck.load_registry()}
    for local, remote in MANIFEST:
        lp = os.path.join(REPO, local)
        lm = local_md5(lp)
        rm = ssh_cmd(c, "md5sum %s 2>/dev/null" % remote).split()
        lines.append("%s  %s  local=%s" % (rm[0] if rm else "-", remote, lm or "-"))
        row = reg.get(local)
        vlines.append("%s\t%s\t%s\t%s" % (local, row[1] if row else "?",
                                          rm[0] if rm else "-", lm or "-"))
    body = "\n".join(lines) + "\n"
    ssh_cmd(c, "cat > /data/gw/DEPLOY_MANIFEST", stdin_data=body)
    ssh_cmd(c, "cat > /data/gw/VERSIONS", stdin_data="\n".join(vlines) + "\n")
    print(body)
    print("(device /data/gw/VERSIONS written; local diff via: vercheck.py device)")
    c.close()


def put():
    """标准文件推送接口: put <local> <remote> [--mode 755]
    二进制安全(ssh stdin 管道) + 原子替换(临时文件 + mv) + md5 强校验
    (写后即校验, mv 后复核, 3 次重试; 任何失败保持设备原文件不动).
    字节精确: 不注入 #DEPLOY 戳 -- 需要溯源戳的 manifest 文件走 push."""
    import time as _t
    argv = sys.argv[2:]
    mode = None
    if "--mode" in argv:
        i = argv.index("--mode")
        mode = argv[i + 1]
        del argv[i:i + 2]
    if len(argv) != 2:
        sys.exit("usage: deploy.py put <local> <remote> [--mode 755]")
    local, remote = argv
    if not os.path.isfile(local):
        sys.exit("!! 本地文件不存在: %s" % local)
    if not remote.startswith("/"):
        sys.exit("!! remote 必须是以 / 开头的绝对路径(得到 %r)。"
                 "Git-Bash/MSYS 会把 /xx 转成 Windows 路径——调用时加 MSYS_NO_PATHCONV=1" % remote)
    data = open(local, "rb").read()
    want = hashlib.md5(data).hexdigest()
    c, ip = connect()
    print("put %s -> %s:%s (%d bytes, md5 %s)" % (local, ip, remote, len(data), want))
    tmp = remote + ".putting"
    try:
        for attempt in range(1, 4):
            ssh_cmd(c, "rm -f %s" % tmp, timeout=10)
            try:
                si, so, se = c.exec_command("cat > %s" % tmp, timeout=120)
                si.write(data)
                si.flush()
                si.channel.shutdown_write()
                rc = so.channel.recv_exit_status()
            except Exception as e:
                print("  attempt %d: 通道异常 %r" % (attempt, e))
                _t.sleep(1)
                continue
            if rc != 0:
                print("  attempt %d: cat rc=%d err=%s" % (attempt, rc, se.read()[:120]))
                _t.sleep(1)
                continue
            if mode:
                ssh_cmd(c, "chmod %s %s" % (mode, tmp), timeout=10)
            out = ssh_cmd(c, "md5sum %s" % tmp, timeout=30)
            got = out.split()[0] if out.split() else None
            if got != want:
                print("  attempt %d: md5 %s != %s (损坏, 重推)" % (attempt, got, want))
                _t.sleep(1)
                continue
            ssh_cmd(c, "mv -f %s %s" % (tmp, remote), timeout=15)
            out2 = ssh_cmd(c, "md5sum %s" % remote, timeout=30)
            verify = out2.split()[0] if out2.split() else None
            if verify == want:
                print("put OK (双次 md5 一致): %s" % remote)
                return 0
            print("  attempt %d: mv 后复核失败 %s" % (attempt, verify))
            _t.sleep(1)
        sys.exit("!! put FAILED: 3 次尝试 md5 均不一致, 设备原文件未改动")
    finally:
        ssh_cmd(c, "rm -f %s" % tmp, timeout=10)
        c.close()


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "doctor"
    # 版本注册表预检: 注册表/MANIFEST/磁盘/架构图任何不一致 -> 拒绝一切操作
    if not vercheck.check():
        sys.exit("!! 版本注册表不一致, 先修复再操作")
    # 文档结论审计 (L16): 结论/代码版本绑定漂移 -> 拒绝 push (防"修了代码忘了翻案")
    import doc_audit
    if cmd in ("push", "put", "snapshot") and not doc_audit.audit(verbose=True):
        sys.exit("!! 文档结论台账有违规(STALE-CODE/未登记断言), 复审后 "
                 "`doc_audit.py refresh <id>` 或修正文档")
    if cmd == "push" and "--serial" in sys.argv:
        sys.argv.remove("--serial")
        names = [a for a in sys.argv[2:] if not a.startswith("-")]
        push_serial(names or None)
        sys.exit(0)
    fn = {"doctor": doctor, "push": push, "put": put,
          "attic": attic, "snapshot": snapshot}[cmd]
    if cmd == "push":
        names = [a for a in sys.argv[2:] if not a.startswith("-")]
        rc = fn(names or None)
        # post-deploy selftest (L13: 部署后自动验证, 非 push 之外的操作)
        if rc in (0, None) and "--no-test" not in sys.argv:
            print("\n--- post-deploy selftest ---")
            st = subprocess.run(
                [sys.executable, os.path.join(REPO, "tools", "selftest.py")],
                cwd=REPO, timeout=120)
            if st.returncode != 0:
                print("!! selftest FAILURES after deploy -- check above")
                rc = 1
        sys.exit(rc)
    sys.exit(fn())
