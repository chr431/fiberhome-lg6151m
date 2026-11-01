#!/bin/bash
# build_labkernel.sh -- one-click lab-kernel rebuild (v3 recipe).
# Runs INSIDE the prepared WSL tree (~/lab-kernel): the kernel source tree
# (6.18.44 + 535 OpenWrt patches + files overlay + lg6151m DTS), musl cross
# toolchain, static busybox, payload binaries and the MTK python3.10 signer
# must already be staged. Preparation steps and environment pins are in
# tools/labkernel/README.md (sections "环境" and "从零准备").
# What this entry point does:
#   1. integrity preflight (payload md5s, console node, config lineage)
#   2. config additions (thermal + watchdog already in base; wifi modules)
#   3. Image/dtbs build, module build, module staging into initramfs
#   4. Android boot v2 pack + MTK mt2737 signature chain
#   5. full self-check battery (v3_selfcheck.py; exit 1 on any FAIL)
# Outputs (~/lab-kernel/out): boot-lab3-unsigned.img, boot-lab3-signed.img
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
LK="$HOME/lab-kernel"
[ -d "$LK/linux-6.18.44" ] || { echo "prepared tree $LK/linux-6.18.44 missing -- see tools/labkernel/README.md"; exit 1; }
bash "$HERE/v3_repack.sh"
echo "one-click done; artifacts in $LK/out (export via $HERE/v3_export.sh)"
