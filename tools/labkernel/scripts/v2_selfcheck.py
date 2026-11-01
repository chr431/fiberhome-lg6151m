#!/usr/bin/env python3
"""v2_selfcheck.py -- V2 repack self-check battery.

Inherited from c2_selfcheck.py (the C1 27-item battery, all re-run):
  1. initramfs contents (usr/initramfs_data.cpio raw newc + gz twin):
     init/vsurv4/scanary/bin/scanary_report/bin/busybox/data/repro present;
     /init carries the V2 banner and the pre-registered scanary window-1
     invocation; ./scanary is an aarch64 ELF.
  2. embedding chain: vmlinux embeds the cpio.gz byte-identical at
     __initramfs_start; the same bytes occur inside the raw Image.
  3. boot v2 header: ANDROID!, page 2048, gzip payload == Image bytes,
     dtb d00dfeed at the computed page-aligned offset, name/cmdline match.
  4. signed image: exactly 32 MiB and cert1 DER embedded.

New V2 checks (defect fixes):
  F1  cpio contains dev/console as char device 5:1 mode 0600 size 0, and
      dev/null as char 1:3 mode 0666 -- asserted BOTH by newc header parse
      AND by a full `cpio -id` extraction (device nodes recreated on disk,
      os.stat major/minor verified).  This is the fix for the v1 panic
      "Attempted to kill init" after rdinit=/bin/sh.
  F2  /init provides the interactive shell path: setsid cttyhack handoff,
      respawn loop, hb-slow heartbeat, scanary-exited-early truncation,
      and /bin/sh + cttyhack/setsid applet symlinks are all in the archive.
  F3  /bin/netup present, #!/bin/sh, carries the 169.254/16 zero-conf plan.
Prints PASS/FAIL per check; exit 1 on any FAIL.
"""
import gzip, hashlib, os, stat, struct, subprocess, sys, tempfile

TREE = "/root/lab-kernel/linux-6.18.44"
OUT = "/root/lab-kernel/out"
CERT1 = ("/root/lab-kernel/openwrt-mt6990-lg6851f/lg6851f_sign_tool/"
         "fg370-2305-opensdk/mtk/tools/common/security/config/mt2737/"
         "cert_config/sec_level_0/cert1/boot_cert1.der")

fails = []
def check(name, ok, detail=""):
    print(("PASS" if ok else "FAIL"), "|", name, "|", detail)
    if not ok:
        fails.append(name)

def md5(b): return hashlib.md5(b).hexdigest()

# ---------- 1. initramfs contents (inherited) ----------
cpio = open(f"{TREE}/usr/initramfs_data.cpio", "rb").read()
check("usr/initramfs_data.cpio is raw newc cpio", cpio[:6] == b"070701",
      f"{len(cpio)}B md5={md5(cpio)}")
INC = f"{TREE}/usr/initramfs_inc_data"
gz = open(INC, "rb").read()
check("usr/initramfs_inc_data is gzip", gz[:2] == b"\x1f\x8b", f"{len(gz)}B")
check("initramfs_inc_data gunzips to exactly initramfs_data.cpio",
      gzip.decompress(gz) == cpio, f"{len(gz)}B gz -> {len(cpio)}B cpio")
print(f"info | cpio={len(cpio)}B md5={md5(cpio)} | embedded gz={len(gz)}B md5={md5(gz)}")
entries = subprocess.run(["cpio", "-it", "--quiet"], input=cpio,
                         capture_output=True).stdout.decode()
names = [e.strip().strip("./") for e in entries.splitlines() if e.strip()]
need = ["init", "vsurv4", "scanary", "bin/scanary_report", "bin/busybox", "data/repro"]
for n in need:
    check(f"cpio contains {n}", any(n == x.rstrip("/") or x.rstrip("/").endswith("/" + n) for x in names),
          f"{len(names)} entries total")

def cpio_walk(cpio):
    """yield (name, fields dict, data bytes) for every newc entry"""
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
        fields = dict(ino=f(0), mode=f(1), uid=f(2), gid=f(3), nlink=f(4),
                      mtime=f(5), filesize=f(6), devmajor=f(7), devminor=f(8),
                      rdevmajor=f(9), rdevminor=f(10), namesize=f(11))
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
check("init carries V2 banner", init_b is not None and b"LG6151M LAB KERNEL V2" in init_b)
check("init carries scanary w1 invocation (unchanged vs C2 arm)",
      init_b is not None and b"/scanary --victim main --duration 1800" in init_b)
check("init vsurv4 still started", init_b is not None and b"/vsurv4" in init_b)
check("scanary is ELF aarch64",
      scan_b is not None and scan_b[:4] == b"\x7fELF"
      and struct.unpack("<H", scan_b[18:20])[0] == 183,
      f"{len(scan_b)}B" if scan_b else "missing")
check("scanary_report non-empty sh",
      rep_b is not None and rep_b.startswith(b"#!/bin/sh") and b"HIT_APPEAR" in rep_b,
      f"{len(rep_b) if rep_b else 0}B")

# ---------- 1b. F1: /dev/console + /dev/null nodes in the cpio ----------
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
nul_ok = (nul is not None and (nul["mode"] & S_IFMT) == S_IFCHR
          and (nul["mode"] & 0o777) == 0o666
          and nul["rdevmajor"] == 1 and nul["rdevminor"] == 3)
nul_detail = (f"mode={oct(nul['mode'])} rdev={nul['rdevmajor']}:{nul['rdevminor']}"
              if nul else "absent")
check("F1: cpio contains dev/null char 1:3 mode 0666", nul_ok, nul_detail)
# cpio -itv secondary view: char device with major 5 minor 1
import re
tv = subprocess.run(["cpio", "-itv", "--quiet"], input=cpio,
                    capture_output=True).stdout.decode()
tv_con = [ln for ln in tv.splitlines() if ln.rstrip().endswith("dev/console")]
check("F1: cpio -itv lists dev/console as char dev 5:1",
      bool(tv_con) and "crw" in tv_con[0]
      and re.search(r"5,\s*1", tv_con[0]) is not None,
      tv_con[0].strip() if tv_con else "absent")
# THE unpack verification: extract the archive, nodes must reappear on disk
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

# ---------- 1c. F2: shell path in /init + applet symlinks ----------
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
sh_e = cpio_entry(cpio, "bin/sh")
check("F2: bin/sh present for rdinit=/bin/sh", sh_e is not None,
      f"mode={oct(sh_e['mode']) if sh_e else '?'} (symlink to busybox)")
for app in ("bin/setsid", "bin/cttyhack"):
    e = cpio_entry(cpio, app)
    d = cpio_file(cpio, app)
    check(f"F2: cpio contains {app} symlink to busybox",
          e is not None and (e["mode"] & S_IFMT) == 0o120000
          and d is not None and d.rstrip(b"\x00") == b"busybox",
          f"mode={oct(e['mode']) if e else '?'} target={d!r}" if e else "absent")

# ---------- 1d. F3: netup ----------
net = cpio_file(cpio, "bin/netup")
net_e = cpio_entry(cpio, "bin/netup")
check("F3: bin/netup present, sh script, executable bit",
      net is not None and net.startswith(b"#!/bin/sh")
      and net_e is not None and (net_e["mode"] & 0o111) == 0o111,
      f"{len(net) if net else 0}B")
check("F3: netup carries 169.254/16 zero-conf plan",
      net is not None and b"169.254.9." in net and b"/16" in net)

# ---------- 2. embedding chain (inherited) ----------
syms = {}
for ln in open(f"{TREE}/System.map"):
    p = ln.split()
    if len(p) == 3:
        syms.setdefault(p[2], int(p[0], 16))
s0, ssize_va = syms.get("__initramfs_start"), syms.get("__initramfs_size")
check("System.map has __initramfs_start/__initramfs_size",
      s0 is not None and ssize_va is not None,
      f"start={hex(s0) if s0 else '?'} size_sym={hex(ssize_va) if ssize_va else '?'}")

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

# ---------- 3. boot v2 header (inherited, reads boot-lab2) ----------
boot = open(f"{OUT}/boot-lab2-unsigned.img", "rb").read()
check("boot magic ANDROID!", boot[:8] == b"ANDROID!")
kernel_size = struct.unpack("<I", boot[8:12])[0]
page_size = struct.unpack("<I", boot[36:40])[0]
hdr_ver = struct.unpack("<I", boot[40:44])[0]
hdr_size = struct.unpack("<I", boot[0x66C:0x670])[0]
dtb_size = struct.unpack("<I", boot[0x670:0x674])[0]
dtb_addr = struct.unpack("<Q", boot[0x674:0x67C])[0]
check("page size 2048 / header v2 / header_size 1660",
      page_size == 2048 and hdr_ver == 2 and hdr_size == 1660,
      f"page={page_size} hdr={hdr_ver} hdr_size={hdr_size}")
k_off = page_size
check("kernel payload is gzip", boot[k_off:k_off+2] == b"\x1f\x8b", f"kernel_size={kernel_size}")
gunz = gzip.decompress(boot[k_off:k_off+kernel_size])
check("kernel payload gunzips to exact Image bytes", gunz == img,
      f"gunzip {len(gunz)}B == Image {len(img)}B")
check("arm64 Image magic ARM\\x64 @0x38", gunz[0x38:0x3C] == b"ARM\x64")
d_off = ((k_off + kernel_size + page_size - 1) // page_size) * page_size
check("dtb payload d00dfeed at aligned offset",
      boot[d_off:d_off+4] == b"\xd0\x0d\xfe\xed", f"dtb_off={hex(d_off)} dtb_size={dtb_size} dtb_addr={hex(dtb_addr)}")
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

# ---------- 4. signed image (inherited, reads boot-lab2) ----------
sgn = open(f"{OUT}/boot-lab2-signed.img", "rb").read()
check("signed image is 32MiB", len(sgn) == 33554432, f"{len(sgn)}B")
cert1 = open(CERT1, "rb").read()
check("cert1 embedded in signed image", sgn.find(cert1) >= 0, f"offset {hex(sgn.find(cert1))}")

import hashlib as _h
print("SUMMARY md5:", md5(boot), "unsigned;", md5(sgn), "signed")
print("SUMMARY sha256:", _h.sha256(boot).hexdigest(), "unsigned;", _h.sha256(sgn).hexdigest(), "signed")
print(f"checks failed: {len(fails)}{':' if fails else ''} {fails if fails else '-- ALL PASS'}")
sys.exit(1 if fails else 0)
