#!/bin/bash
# make_lg6151m_dts.sh -- derive mt6990-fiberhome-lg6151m.dts from the repo's
# boot-verified LG6851F board DTS + our stock LG6151M DTB facts.
#
# Decision record (see C1 report §DTS):
#  - Skeleton = repo dts (real-hardware-verified to userspace on the same
#    FiberHome MT6990 CPE firmware framework; core SoC nodes proven identical
#    to our stock DTB: memory, cpus, uart0/1, mmc, pinctrl, scpsys).
#  - Changed: model, compatible, chosen/bootargs (lab cmdline, no root=).
#  - Everything else kept byte-identical to the verified skeleton.
set -eu
SRC="$HOME/lab-kernel/openwrt-mt6990-lg6851f/target/linux/mediatek/dts/mt6990-fiberhome-lg6851f.dts"
DST="$HOME/lab-kernel/out/mt6990-fiberhome-lg6151m.dts"

LAB_ARGS='console=tty0 console=ttyS0,921600n1 earlycon=8250,mmio32,0x11002000 loglevel=8 ignore_loglevel initcall_debug init=/init page_owner=on mtk_printk_ctrl.disable_uart=0 clk_ignore_unused fw_devlink=off deferred_probe_timeout=10 panic=10 kgdboc=ttyS0,921600 pci=pcie_bus_safe'

python3 - "$SRC" "$DST" "$LAB_ARGS" <<'PY'
import sys
src, dst, lab_args = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()

# 1. model
old_model = 'model = "FiberHome Pro LG6851F";'
new_model = 'model = "FiberHome LG6151M lab kernel";'
assert text.count(old_model) == 1, "model line not unique"
text = text.replace(old_model, new_model)

# 2. compatible
old_compat = 'compatible = "fiberhome,lg6851f\\0mediatek,mt6990";'
new_compat = 'compatible = "fiberhome,lg6151m\\0mediatek,mt6990";'
assert text.count(old_compat) == 1, "compatible line not unique"
text = text.replace(old_compat, new_compat)

# 3. chosen bootargs: replace the whole assignment (single-quoted DTS string,
#    tabs inside are fine to drop -- we supply the full lab cmdline).
import re
pat = re.compile(r'bootargs = "[^"]*";')
matches = pat.findall(text)
assert len(matches) == 1, f"bootargs lines: {len(matches)}"
text = text.replace(matches[0], 'bootargs = "%s";' % lab_args)

header = """/*
 * FiberHome LG6151M (MT6990/T830) lab/instrument kernel board DTS.
 * Derived: mt6990-fiberhome-lg6851f.dts (community repo 13179415360/
 * openwrt-mt6990-lg6851f, main branch) -- real-hardware verified skeleton.
 * Local facts cross-checked against the LG6151M stock boot DTB
 * (md5 686160767c2340a09919ad0f0e10a68b, model evb6990_cpe_mt7992_emmc):
 * memory/cpus/uart@11002000/uart@11003000/mmc@11230000/mmc@11240000/
 * pinctrl@10004000/power-controller@12001000 all match the skeleton.
 * Changes vs skeleton: model, compatible, chosen/bootargs (initramfs lab
 * cmdline, no root=). Lab kernel C1, 2026-11-01.
 */

"""
open(dst, "w", encoding="utf-8").write(header + text)
print("wrote", dst)
print("lab bootargs:", lab_args)
PY
echo OK
