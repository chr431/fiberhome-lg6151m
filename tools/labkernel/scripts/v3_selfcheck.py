#!/usr/bin/env python3
"""v3_selfcheck.py -- V3.1 asset-build self-check battery.

Inherited from the C1/C2/v2 battery (all re-run):
  initramfs contents + gz twin, embedding chain into vmlinux/Image,
  boot v2 header fields, signed image 32MiB + cert1, F1 console nodes
  (newc header + cpio -itv + full extraction), F2 shell path markers,
  F3 netup.

V3 checks (kept in V3.1):
  A1 thermal: config MTK_LVTS_THERMAL=y; init has tmax= heartbeat field,
     thermal limits (lab_thermal_warn/off), THERMAL_ALARM/SHUTDOWN guards.
  A2 watchdog: config MEDIATEK_WATCHDOG=y; init feeds /dev/watchdog,
     lab_wdt=off opt-out.
  A3 TRY_A autoclear: init clears the p1 misc block byte 2061 with readback
     verify, lab_trya=off opt-out.
  A4 boot card: one-page capability summary marker + BUILD_ID.
  B  reserves: /modules/*.ko present (cfg80211/mac80211/mt76/
     mt76-connac-lib/mt7996e, ELF aarch64, config =m), /bin/romount,
     /bin/kexec absent honestly documented in /bin/kjump.

V3.1 checks (D28 revalidation; the v3 image is withdrawn):
  FIX-1 TRY_A/GPT regression guard -- the A/B control block lives at p1
     offset 2060..2069 (p1 starts at sector 64); raw /dev/mmcblk0 offset
     2061 is a GPT partition-entry byte.  v3 wrote that raw byte and broke
     the GPT entries CRC.  This battery FAILS if any 2061 access omits the
     p1 device or if any raw /dev/mmcblk0 write appears in /init.
  FIX-2 window-end full scanary log to console (bytes/lines/md5 + full cat
     + D28_W1_LOG_END terminator) -- second channel beside the shell.
  FIX-3 alive_check reads /proc/<pid>/stat comm (cmdline NUL bug fixed) and
     no longer scans /proc/*/cmdline.
  Discipline: the 26 observation config symbols must be byte-identical
     to the C1/v2 config (verified against the exported v2 .config).
Prints PASS/FAIL per check; exit 1 on any FAIL.
"""
import gzip, hashlib, os, re, stat, struct, subprocess, sys, tempfile

TREE = "/root/lab-kernel/linux-6.18.44"
OUT = "/root/lab-kernel/out"
CFG_V2 = "/mnt/d/Repo/lg6151m-project/_local/work/lab-kernel/artifacts/config-lab2-6.18.44"
CERT1 = ("/root/lab-kernel/openwrt-mt6990-lg6851f/lg6851f_sign_tool/"
         "fg370-2305-opensdk/mtk/tools/common/security/config/mt2737/"
         "cert_config/sec_level_0/cert1/boot_cert1.der")

fails = []
def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL"), "|", name, "|", detail)
    if not ok:
        fails.append(name)

def md5(b): return hashlib.md5(b).hexdigest()

# ---------- 0. config: 26 observation symbols frozen vs v2 ----------
OBS26 = ["CONFIG_KPROBES", "CONFIG_KPROBE_EVENTS", "CONFIG_DYNAMIC_FTRACE",
         "CONFIG_FUNCTION_TRACER", "CONFIG_PERF_EVENTS", "CONFIG_HAVE_HW_BREAKPOINT",
         "CONFIG_USERFAULTFD", "CONFIG_PROC_PAGE_MONITOR", "CONFIG_KEXEC",
         "CONFIG_KEXEC_FILE", "CONFIG_KGDB", "CONFIG_KGDB_SERIAL_CONSOLE",
         "CONFIG_KALLSYMS_ALL", "CONFIG_UPROBE_EVENTS", "CONFIG_PAGE_OWNER",
         "CONFIG_DEBUG_FS", "CONFIG_BLK_DEV_INITRD", "CONFIG_SERIAL_8250_MT6577",
         "CONFIG_MMC_MTK", "CONFIG_SMP", "CONFIG_IKCONFIG_PROC",
         "CONFIG_FTRACE", "CONFIG_TRACING", "CONFIG_FUNCTION_GRAPH_TRACER",
         "CONFIG_KGDB_KDB", "CONFIG_PANIC_TIMEOUT"]
cfg_v3 = {}
for ln in open(f"{TREE}/.config"):
    if ln.startswith("CONFIG_"):
        k, _, v = ln.strip().partition("=")
        cfg_v3[k] = v
cfg_v2 = {}
for ln in open(CFG_V2):
    if ln.startswith("CONFIG_"):
        k, _, v = ln.strip().partition("=")
        cfg_v2[k] = v
obs_ok = all(cfg_v3.get(s) == cfg_v2.get(s) and cfg_v3.get(s) is not None for s in OBS26)
check("discipline: 26 observation symbols identical to v2 config", obs_ok,
      f"{sum(1 for s in OBS26 if cfg_v3.get(s) == cfg_v2.get(s) and cfg_v3.get(s))}/26 equal")
added = sorted(set(cfg_v3) - set(cfg_v2))
removed = sorted(set(cfg_v2) - set(cfg_v3))
changed = sorted(k for k in set(cfg_v3) & set(cfg_v2) if cfg_v3[k] != cfg_v2[k])
print(f"info | config delta vs v2: +{len(added)} -{len(removed)} ~{len(changed)}",
      "| added:", ",".join(f"{k}={cfg_v3[k]}" for k in added[:24]))
for k in changed:
    print(f"info | changed: {k}: {cfg_v2[k]} -> {cfg_v3[k]}")
check("discipline: no config symbol removed or changed vs v2 (additions only)",
      not removed and not changed, f"-{removed} ~{changed}")

# config-level v3 feature gates
for sym, val in (("CONFIG_MTK_THERMAL", "y"), ("CONFIG_MTK_LVTS_THERMAL", "y"),
                 ("CONFIG_MEDIATEK_WATCHDOG", "y"),
                 ("CONFIG_CFG80211", "m"), ("CONFIG_MAC80211", "m"),
                 ("CONFIG_MT76_CORE", "m"), ("CONFIG_MT76_CONNAC_LIB", "m"),
                 ("CONFIG_MT7996E", "m")):
    check(f"config {sym}={val}", cfg_v3.get(sym) == val, f"got {cfg_v3.get(sym)}")

# ---------- 1. initramfs contents (inherited) ----------
cpio = open(f"{TREE}/usr/initramfs_data.cpio", "rb").read()
check("usr/initramfs_data.cpio is raw newc cpio", cpio[:6] == b"070701",
      f"{len(cpio)}B md5={md5(cpio)}")
INC = f"{TREE}/usr/initramfs_inc_data"
gz = open(INC, "rb").read()
check("usr/initramfs_inc_data is gzip", gz[:2] == b"\x1f\x8b", f"{len(gz)}B")
check("initramfs_inc_data gunzips to exactly initramfs_data.cpio",
      gzip.decompress(gz) == cpio, f"{len(gz)}B gz -> {len(cpio)}B cpio")
entries = subprocess.run(["cpio", "-it", "--quiet"], input=cpio,
                         capture_output=True).stdout.decode()
names = [e.strip().strip("./") for e in entries.splitlines() if e.strip()]
need = ["init", "vsurv4", "scanary", "bin/scanary_report", "bin/busybox", "data/repro"]
for n in need:
    check(f"cpio contains {n}", any(n == x.rstrip("/") or x.rstrip("/").endswith("/" + n) for x in names),
          f"{len(names)} entries total")

def cpio_walk(cpio):
    off = 0
    while off + 110 <= len(cpio):
        hdr = cpio[off:off+110]
        if hdr[:6] != b"070701":
            return
        f = lambda i: int(hdr[6+8*i:6+8*(i+1)], 16)
        namesize, filesize = f(11), f(6)
        name = cpio[off+110:off+110+namesize-1].decode()
        doff = (off + 110 + namesize + 3) & ~3
        if name == "TRAILER!!!":
            return
        fields = dict(mode=f(1), filesize=f(6), rdevmajor=f(9), rdevminor=f(10))
        yield name, fields, cpio[doff:doff+filesize]
        off = (doff + filesize + 3) & ~3

def cpio_file(cpio, want):
    for name, fields, data in cpio_walk(cpio):
        if name.strip("./") == want:
            return data
    return None

def cpio_entry(cpio, want):
    for name, fields, data in cpio_walk(cpio):
        if name.strip("./") == want:
            return fields
    return None

init_b = cpio_file(cpio, "init")
scan_b = cpio_file(cpio, "scanary")
rep_b = cpio_file(cpio, "bin/scanary_report")
check("init carries V3.1 banner + BUILD_ID",
      init_b is not None and b"LG6151M LAB KERNEL V3.1" in init_b
      and b'BUILD_ID="labkernel-v3.1' in init_b)
check("init carries scanary w1 invocation (unchanged vs C2 arm)",
      init_b is not None and b"/scanary --victim main --duration 1800" in init_b)
check("init vsurv4 still started", init_b is not None and b"/vsurv4" in init_b)
check("scanary is ELF aarch64",
      scan_b is not None and scan_b[:4] == b"\x7fELF"
      and struct.unpack("<H", scan_b[18:20])[0] == 183,
      f"{len(scan_b)}B" if scan_b else "missing")
check("scanary_report non-empty sh",
      rep_b is not None and rep_b.startswith(b"#!/bin/sh") and b"HIT_APPEAR" in rep_b)

# ---------- 1b. F1: /dev/console + /dev/null nodes (inherited) ----------
S_IFMT, S_IFCHR = 0o170000, 0o020000
con = cpio_entry(cpio, "dev/console")
nul = cpio_entry(cpio, "dev/null")
check("F1: cpio contains dev/console", con is not None)
check("F1: dev/console is char device mode 0600 size 0",
      con is not None and (con["mode"] & S_IFMT) == S_IFCHR
      and (con["mode"] & 0o777) == 0o600 and con["filesize"] == 0,
      f"mode={oct(con['mode']) if con else '?'}")
check("F1: dev/console rdev is 5:1",
      con is not None and con["rdevmajor"] == 5 and con["rdevminor"] == 1,
      f"rdev={con['rdevmajor']}:{con['rdevminor']}" if con else "?")
check("F1: cpio contains dev/null char 1:3 mode 0666",
      nul is not None and (nul["mode"] & S_IFMT) == S_IFCHR
      and (nul["mode"] & 0o777) == 0o666
      and nul["rdevmajor"] == 1 and nul["rdevminor"] == 3,
      f"mode={oct(nul['mode'])} rdev={nul['rdevmajor']}:{nul['rdevminor']}" if nul else "absent")
tv = subprocess.run(["cpio", "-itv", "--quiet"], input=cpio,
                    capture_output=True).stdout.decode()
tv_con = [ln for ln in tv.splitlines() if ln.rstrip().endswith("dev/console")]
check("F1: cpio -itv lists dev/console as char dev 5:1",
      bool(tv_con) and "crw" in tv_con[0]
      and re.search(r"5,\s*1", tv_con[0]) is not None,
      tv_con[0].strip() if tv_con else "absent")
with tempfile.TemporaryDirectory() as td:
    subprocess.run(["cpio", "-id", "--quiet"], input=cpio, cwd=td, check=True)
    for dev, maj, mmin, perm in (("console", 5, 1, 0o600), ("null", 1, 3, 0o666)):
        p = f"{td}/dev/{dev}"
        try:
            st = os.stat(p)
            ok = stat.S_ISCHR(st.st_mode) and os.major(st.st_rdev) == maj \
                 and os.minor(st.st_rdev) == mmin and (stat.S_IMODE(st.st_mode) == perm)
            check(f"F1: extraction recreates dev/{dev} c {maj}:{mmin} {oct(perm)}", ok,
                  f"rdev={os.major(st.st_rdev)}:{os.minor(st.st_rdev)} mode={oct(stat.S_IMODE(st.st_mode))}")
        except FileNotFoundError:
            check(f"F1: extraction recreates dev/{dev} c {maj}:{mmin}", False, "absent after cpio -id")

# ---------- 1c. F2 + A-block markers in /init ----------
check("F2: init has setsid cttyhack shell handoff",
      init_b is not None and b"setsid cttyhack sh -c 'exec sh </dev/console >/dev/console 2>&1'" in init_b)
check("F2: init has plain-sh fallback handoff",
      init_b is not None and init_b.count(b"exec sh </dev/console >/dev/console 2>&1") >= 2)
check("F2: init respawns shell on exit",
      init_b is not None and b"shell exited -- respawning in 3s" in init_b)
check("F2: init keeps heartbeat (in-window 10s + post-window 60s hb-slow)",
      init_b is not None and b"[hb $i]" in init_b and b"[hb-slow $j]" in init_b)
check("F2: init truncates window when scanary exited early",
      init_b is not None and b"scanary_exited_early" in init_b)
for app in ("bin/setsid", "bin/cttyhack"):
    e = cpio_entry(cpio, app)
    d = cpio_file(cpio, app)
    check(f"F2: cpio contains {app} symlink to busybox",
          e is not None and (e["mode"] & S_IFMT) == 0o120000
          and d is not None and d.rstrip(b"\x00") == b"busybox",
          f"mode={oct(e['mode']) if e else '?'} target={d!r}" if e else "absent")
check("A3: init auto-clears TRY_A (p1 misc block, byte 2061) with readback + lab_trya=off opt-out",
      init_b is not None and b"TRYA_CLEARED" in init_b
      and b"TRYA_CLEAR_FAILED" in init_b and b"lab_trya=off" in init_b)

# ---------- 1c-1. V3.1 FIX-1: TRY_A write-target / GPT safety assertion ----------
# Requirement (D28 report sections 9b/11): the TRY_A write target MUST be
# p1@2061.  Raw /dev/mmcblk0 offset 2061 belongs to the GPT partition entries
# and writing it corrupts the GPT entries CRC.  This is the permanent
# regression assertion for that defect: the battery refuses to pass a build
# whose /init regresses to the raw-device form.
init_lines = init_b.splitlines() if init_b else []
off_lines = [ln for ln in init_lines if b"seek=2061" in ln or b"skip=2061" in ln]
off_bad = [ln for ln in off_lines if (b"$P1" not in ln and b"mmcblk0p1" not in ln)]
check("V3.1/GPT guard: every byte-2061 access goes through the p1 misc device",
      init_b is not None and bool(off_lines) and not off_bad,
      f"{len(off_lines)} offset lines" if not off_bad else repr(off_bad[:2]))
check("V3.1/GPT guard: no raw /dev/mmcblk0 write in /init (forbidden: GPT entry bytes)",
      init_b is not None and re.search(rb"of=/dev/mmcblk0(?!p)", init_b) is None)
check("V3.1/GPT guard: TRY_A target is p1@2061, single byte, zero-filled",
      init_b is not None and b"P1=/dev/mmcblk0p1" in init_b
      and b'dd if=/dev/zero of="$P1" bs=1 seek=2061 count=1' in init_b)
check("V3.1/GPT guard: A/B control block shape printed before and after",
      init_b is not None and b"skip=2060 count=10" in init_b
      and b"p1[2060..2069] before:" in init_b)
check("A2: init feeds /dev/watchdog every 10s + lab_wdt=off opt-out",
      init_b is not None and b"WDT: feeder armed" in init_b and b"lab_wdt=off" in init_b)
check("A1: heartbeat carries tmax + thermal limits cmdline-overridable",
      init_b is not None and b"tmax=" in init_b and b"lab_thermal_warn" in init_b
      and b"lab_thermal_off" in init_b)
check("A1: thermal guards present (alarm + protective shutdown)",
      init_b is not None and b"THERMAL_ALARM" in init_b and b"THERMAL_SHUTDOWN" in init_b)
check("A4: boot card present",
      init_b is not None and b"BOOT CARD -- capability summary" in init_b)
check("V3.1/FIX-2: window-1 end ships the full scanary log to console",
      init_b is not None and b"WINDOW-1 END" in init_b
      and b"W1_LOG_BYTES=" in init_b and b"W1_LOG_LINES=" in init_b
      and b"cat /data/repro/scanary_c2_w1.log" in init_b
      and b"D28_W1_LOG_END" in init_b)
check("V3.1/FIX-2: window-end log carries an on-device md5",
      init_b is not None and b"busybox md5sum /data/repro/scanary_c2_w1.log" in init_b)
check("V3.1/FIX-3: alive_check reads /proc/<pid>/stat comm",
      init_b is not None and b"/proc/[0-9]*/stat" in init_b
      and b"comm=${s#*(}" in init_b)
check("V3.1/FIX-3: alive_check no longer scans /proc/*/cmdline",
      init_b is not None and b"/proc/[0-9]*/cmdline" not in init_b)
check("F3: init auto-runs /bin/netup",
      init_b is not None and b"/bin/netup > /dev/console 2>&1 &" in init_b)

# ---------- 1d. F3 + B helpers ----------
net = cpio_file(cpio, "bin/netup")
check("F3: bin/netup present, sh script, executable bit",
      net is not None and net.startswith(b"#!/bin/sh")
      and cpio_entry(cpio, "bin/netup") is not None
      and (cpio_entry(cpio, "bin/netup")["mode"] & 0o111) == 0o111,
      f"{len(net) if net else 0}B")
check("F3: netup carries 169.254/16 zero-conf plan",
      net is not None and b"169.254.9." in net and b"/16" in net)
ro = cpio_file(cpio, "bin/romount")
ro_e = cpio_entry(cpio, "bin/romount")
check("B: bin/romount present, executable, ro-mount helper",
      ro is not None and ro.startswith(b"#!/bin/sh")
      and ro_e is not None and (ro_e["mode"] & 0o111) == 0o111
      and b"mount -t" in ro and b"-o ro" in ro)
kj = cpio_file(cpio, "bin/kjump")
kj_e = cpio_entry(cpio, "bin/kjump")
check("B: bin/kjump present, executable, kexec helper",
      kj is not None and kj.startswith(b"#!/bin/sh")
      and kj_e is not None and (kj_e["mode"] & 0o111) == 0o111
      and b"kexec -l" in kj)
check("B: kjump honestly reports missing userland kexec",
      kj is not None and b"not bundled" in kj)

# ---------- 1e. B: wifi reserve modules in the archive ----------
MODS = ["modules/cfg80211.ko", "modules/mac80211.ko", "modules/mt76.ko",
        "modules/mt76-connac-lib.ko", "modules/mt7996e.ko"]
for m in MODS:
    d = cpio_file(cpio, m)
    check(f"B: cpio contains {m} (ELF aarch64)",
          d is not None and d[:4] == b"\x7fELF"
          and struct.unpack("<H", d[18:20])[0] == 183,
          f"{len(d)}B" if d else "missing")
nmods = sum(1 for x in names if x.startswith("modules/") and x.endswith(".ko"))
# discipline law #2 (substring vs precise): the init *comment* says "insmod
# manually" (documentation of the reserve). An actual auto-load would be an
# execution line referencing the staged paths -- assert THAT is absent.
auto_load = init_b is not None and (
    re.search(rb"^insmod ", init_b, re.M) is not None
    or b"insmod /modules/" in init_b
    or b"modprobe" in init_b)
check("B: no module auto-load execution in /init (docs mention insmod, code must not)",
      not auto_load, f"{nmods} .ko staged in /modules (not loaded)")

# ---------- 2. embedding chain (inherited) ----------
syms = {}
for ln in open(f"{TREE}/System.map"):
    p = ln.split()
    if len(p) == 3:
        syms.setdefault(p[2], int(p[0], 16))
s0, ssize_va = syms.get("__initramfs_start"), syms.get("__initramfs_size")
check("System.map has __initramfs_start/__initramfs_size",
      s0 is not None and ssize_va is not None)
vml = open(f"{TREE}/vmlinux", "rb").read()
e_phoff = struct.unpack("<Q", vml[0x20:0x28])[0]
e_phentsize, e_phnum = struct.unpack("<HH", vml[0x36:0x3A])
def v2o(vaddr):
    for i in range(e_phnum):
        ph = vml[e_phoff+i*e_phentsize: e_phoff+(i+1)*e_phentsize]
        p_type, _fl, p_off, p_va, _pa, p_fsz = struct.unpack("<IIQQQQ", ph[:40])
        if p_type == 1 and p_va <= vaddr < p_va + p_fsz:
            return p_off + (vaddr - p_va)
    return None
emb_size = struct.unpack("<Q", vml[v2o(ssize_va):v2o(ssize_va)+8])[0]
check("__initramfs_size == embedded gz length", emb_size == len(gz),
      f"size_sym={emb_size} gz={len(gz)}")
o0 = v2o(s0)
emb = vml[o0:o0+emb_size]
check("vmlinux embeds cpio.gz byte-identical", md5(emb) == md5(gz),
      f"vmlinux offset {hex(o0)} len {len(emb)}")
img = open(f"{TREE}/arch/arm64/boot/Image", "rb").read()
check("Image contains cpio.gz at a stable offset", img.find(gz) >= 0,
      f"Image offset {hex(img.find(gz))} len {len(img)}")

# ---------- 3. boot v2 header (inherited, reads boot-lab31) ----------
boot = open(f"{OUT}/boot-lab31-unsigned.img", "rb").read()
check("boot magic ANDROID!", boot[:8] == b"ANDROID!")
kernel_size = struct.unpack("<I", boot[8:12])[0]
page_size = struct.unpack("<I", boot[36:40])[0]
hdr_ver = struct.unpack("<I", boot[40:44])[0]
hdr_size = struct.unpack("<I", boot[0x66C:0x670])[0]
check("page size 2048 / header v2 / header_size 1660",
      page_size == 2048 and hdr_ver == 2 and hdr_size == 1660)
k_off = page_size
check("kernel payload is gzip", boot[k_off:k_off+2] == b"\x1f\x8b", f"kernel_size={kernel_size}")
gunz = gzip.decompress(boot[k_off:k_off+kernel_size])
check("kernel payload gunzips to exact Image bytes", gunz == img,
      f"gunzip {len(gunz)}B == Image {len(img)}B")
check("arm64 Image magic ARM\\x64 @0x38", gunz[0x38:0x3C] == b"ARM\x64")
d_off = ((k_off + kernel_size + page_size - 1) // page_size) * page_size
check("dtb payload d00dfeed at aligned offset",
      boot[d_off:d_off+4] == b"\xd0\x0d\xfe\xed", f"dtb_off={hex(d_off)}")
name = boot[48:64].rstrip(b"\0").decode(errors="replace")
cmdline = (boot[64:576] + boot[608:608+1024]).split(b"\0")[0].decode(errors="replace")
check("boot name mt6990", name == "mt6990", repr(name))
check("header cmdline == bootopt only (stock-matching; real args in DTB)",
      cmdline.strip() == "bootopt=64S3,32N2,64N2", repr(cmdline))
dts = subprocess.run(["dtc", "-I", "dtb", "-O", "dts", f"{OUT}/mt6990-fiberhome-lg6151m.dtb"],
                     capture_output=True).stdout.decode(errors="replace")
bootargs = ""
for ln in dts.splitlines():
    if "bootargs" in ln:
        bootargs = ln
check("dtb chosen/bootargs carries serial console + init=/init",
      "console=ttyS0,921600" in bootargs and "init=/init" in bootargs,
      bootargs.strip()[:160])

# ---------- 4. signed image (inherited, reads boot-lab31) ----------
sgn = open(f"{OUT}/boot-lab31-signed.img", "rb").read()
check("signed image is 32MiB", len(sgn) == 33554432, f"{len(sgn)}B")
cert1 = open(CERT1, "rb").read()
check("cert1 embedded in signed image", sgn.find(cert1) >= 0, f"offset {hex(sgn.find(cert1))}")

import hashlib as _h
print("SUMMARY md5:", md5(boot), "unsigned;", md5(sgn), "signed")
print("SUMMARY sha256:", _h.sha256(boot).hexdigest(), "unsigned;", _h.sha256(sgn).hexdigest(), "signed")
print(f"checks failed: {len(fails)}{':' if fails else ''} {fails if fails else '-- ALL PASS'}")
sys.exit(1 if fails else 0)
