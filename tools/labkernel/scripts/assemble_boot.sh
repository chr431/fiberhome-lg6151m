#!/bin/bash
# assemble_boot.sh -- stage 3: pack the lab boot.img (Android boot v2, same
# header recipe as the repo's verified packer), then produce:
#   out/boot-lab-unsigned.img   (raw, for LK verify-behavior probing)
#   out/boot-lab-signed.img     (MTK mt2737 sec_level_0 chain, 32MiB padded)
set -eu
LK="$HOME/lab-kernel"
REPO="$LK/openwrt-mt6990-lg6851f"
TREE="$LK/linux-6.18.44"
SIGNTOOL="$REPO/lg6851f_sign_tool/fg370-2305-opensdk/mtk/tools/common/security/tool"
CERT1="$REPO/lg6851f_sign_tool/fg370-2305-opensdk/mtk/tools/common/security/config/mt2737/cert_config/sec_level_0/cert1/boot_cert1.der"
ROOT_KEY="$REPO/lg6851f_sign_tool/fg370-2305-opensdk/mtk/tools/common/security/sign_master/hsm_test_keys/RSA2048/ROOT"
IMAGE_KEY="$REPO/lg6851f_sign_tool/fg370-2305-opensdk/mtk/tools/common/security/sign_master/hsm_test_keys/RSA2048/IMAGE"
BOOT_PART_SIZE=33554432

KERNEL="$TREE/arch/arm64/boot/Image"
DTB="$TREE/arch/arm64/boot/dts/mediatek/mt6990-fiberhome-lg6151m.dtb"
UNSIGNED="$LK/out/boot-lab-unsigned.img"
SIGNED="$LK/out/boot-lab-signed.img"

[ -f "$KERNEL" ] || { echo "missing $KERNEL"; exit 1; }
[ -f "$DTB" ] || { echo "missing $DTB"; exit 1; }

echo "== 1. pack unsigned boot v2 (repo packer, repo meta json) =="
python3 "$REPO/scripts/lg6851f_mkbootimg_v2.py" \
    --meta "$REPO/target/linux/mediatek/image/lg6851f-boot-v2.json" \
    --kernel "$KERNEL" \
    --dtb "$DTB" \
    --out "$UNSIGNED"

echo "== 2. sign with MTK sign_flow.py (mt2737 default, hsm test keys) =="
WORK=$(mktemp -d /tmp/labsign.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/in"
cp -f "$UNSIGNED" "$WORK/in/boot.img"
cp -f "$UNSIGNED" "$WORK/in/boot.orig.img"
cd "$SIGNTOOL"
PY310="$LK/uv-python/cpython-3.10.14-linux-x86_64-gnu/bin/python3.10"
[ -x "$PY310" ] || { echo "missing python3.10 for MTK tool"; exit 1; }
PYTHONDONTWRITEBYTECODE=True \
PRODUCT_OUT="$WORK/in" \
BOARD_AVB_ENABLE= \
"$PY310" sign_flow.py image mt2737 default \
  hsm=1 \
  root_key_path="$ROOT_KEY" \
  oem_key_path="$IMAGE_KEY" \
  root_key_padding=pss 2>&1 | tee "$LK/out/sign_boot.log" | tail -15
cd "$LK"
[ -f "$WORK/in/boot-verified.img" ] || { echo "signing produced no boot-verified.img"; exit 1; }
cp -f "$WORK/in/boot-verified.img" "$SIGNED"
truncate -s "$BOOT_PART_SIZE" "$SIGNED"

echo "== 3. verify cert1 embedded in signed image =="
python3 - "$CERT1" "$SIGNED" <<'PY'
import sys
cert1 = open(sys.argv[1], 'rb').read()
boot = open(sys.argv[2], 'rb').read()
off = boot.find(cert1)
print(f"cert1 offset in signed boot: {off} (>=0 and inside 32MiB: {0 <= off < len(boot)})")
assert off >= 0
assert len(boot) == 33554432
print("SIGNED_BOOT_VERIFY=PASS")
PY

echo "== 4. checksums =="
cd "$LK/out"
sha256sum boot-lab-unsigned.img boot-lab-signed.img mt6990-fiberhome-lg6151m.dtb vsurv4 | tee SHA256SUMS.txt
md5sum boot-lab-unsigned.img boot-lab-signed.img | tee MD5SUMS.txt
ls -la boot-lab-unsigned.img boot-lab-signed.img
echo ASSEMBLE_DONE
