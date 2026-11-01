#!/usr/bin/env python3
"""c2_selfcheck.py -- C2 repack self-check battery (re-runs the C1 checks).

1. initramfs contents (usr/initramfs_data.cpio.gz): gunzip -> cpio list must
   contain init/vsurv4/scanary/bin/scanary_report/bin/busybox/data/repro; the
   extracted /init must carry the C2 banner and the pre-registered scanary
   window-1 invocation; ./scanary must be an aarch64 ELF.
2. embedding chain: bytes at [__initramfs_start,__initramfs_end) inside
   vmlinux == cpio.gz (md5), and the same bytes occur inside the raw Image
   (initramfs travels inside Image -> gzip -> boot.img kernel payload).
3. boot v2 header: ANDROID! magic, page 2048, gzip magic at page 1, payload
   gunzips to the exact Image bytes, dtb payload starts with d00dfeed at the
   computed page-aligned offset.
4. signed image: exactly 32 MiB and cert1 DER embedded.
Prints PASS/FAIL per check; exit 1 on any FAIL.
"""
import gzip, hashlib, struct, subprocess, sys

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

# ---------- 1. initramfs contents ----------
# 6.18 pipeline: usr/initramfs_data.cpio = raw newc archive;
# usr/initramfs_inc_data = gzip of it (the payload incbin'd into vmlinux).
import os
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

# extract ./init and ./scanary from the cpio stream (newc format walk)
def cpio_file(cpio, want):
    off = 0
    while off + 110 <= len(cpio):
        hdr = cpio[off:off+110]
        if hdr[:6] != b"070701":
            return None
        f = lambda i: int(hdr[6+8*i:6+8*(i+1)], 16)
        namesize, filesize = f(11), f(6)
        name = cpio[off+110:off+110+namesize-1].decode()
        doff = (off + 110 + namesize + 3) & ~3
        if name == "TRAILER!!!":
            return None
        if name == want:
            return cpio[doff:doff+filesize]
        off = (doff + filesize + 3) & ~3
    return None

init_b = cpio_file(cpio, "init") or cpio_file(cpio, "./init")
scan_b = cpio_file(cpio, "scanary") or cpio_file(cpio, "./scanary")
rep_b = cpio_file(cpio, "bin/scanary_report") or cpio_file(cpio, "./bin/scanary_report")
check("init carries C2 banner", init_b is not None and b"LG6151M LAB KERNEL C2" in init_b)
check("init carries scanary w1 invocation",
      init_b is not None and b"/scanary --victim main --duration 1800" in init_b)
check("init vsurv4 still started", init_b is not None and b"/vsurv4" in init_b)
check("scanary is ELF aarch64",
      scan_b is not None and scan_b[:4] == b"\x7fELF"
      and struct.unpack("<H", scan_b[18:20])[0] == 183,
      f"{len(scan_b)}B" if scan_b else "missing")
check("scanary_report non-empty sh",
      rep_b is not None and rep_b.startswith(b"#!/bin/sh") and b"HIT_APPEAR" in rep_b,
      f"{len(rep_b) if rep_b else 0}B")

# ---------- 2. embedding chain ----------
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
# ELF64 program headers -> vaddr to file offset
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

# ---------- 3. boot v2 header ----------
boot = open(f"{OUT}/boot-lab-unsigned.img", "rb").read()
check("boot magic ANDROID!", boot[:8] == b"ANDROID!")
# Header layout = repo packer lg6851f_mkbootimg_v2.py (BOOT_V2_HEADER_SIZE=1660):
#   10x u32 @8 (kernel_size, kernel_addr, ramdisk_size, ramdisk_addr,
#   second_size, second_addr, tags_addr, page_size, header_version, os_version),
#   name[16] @48, cmdline[512] @64, id[32] @576, extra_cmdline[1024] @608,
#   recovery_dtbo_size @1632, recovery_dtbo_offset u64 @1636,
#   header_size @1644, dtb_size @1648, dtb_addr u64 @1652.
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

# ---------- 4. signed image ----------
sgn = open(f"{OUT}/boot-lab-signed.img", "rb").read()
check("signed image is 32MiB", len(sgn) == 33554432, f"{len(sgn)}B")
cert1 = open(CERT1, "rb").read()
check("cert1 embedded in signed image", sgn.find(cert1) >= 0, f"offset {hex(sgn.find(cert1))}")

import hashlib as _h
print("SUMMARY md5:", md5(boot), "unsigned;", md5(sgn), "signed")
print("SUMMARY sha256:", _h.sha256(boot).hexdigest(), "unsigned;", _h.sha256(sgn).hexdigest(), "signed")
sys.exit(1 if fails else 0)
