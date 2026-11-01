#!/bin/bash
# dl_kernel.sh -- fetch linux-6.18.44.tar.xz from openwrt mirror (hash-pinned),
# github codeload as fallback race. Stall-detect + resume + many attempts.
set -u
LK="$HOME/lab-kernel"
EXPECT="0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43"
cd "$LK"

ok_owrt() {
    [ -f linux-6.18.44.owrt.tar.xz ] && \
    echo "$EXPECT  linux-6.18.44.owrt.tar.xz" | sha256sum -c - >/dev/null 2>&1
}

for i in $(seq 1 40); do
    ok_owrt && break
    echo "== owrt attempt $i $(date +%T) size=$(stat -c %s linux-6.18.44.owrt.tar.xz 2>/dev/null || echo 0)"
    curl -fL --speed-limit 20000 --speed-time 20 -C - --max-time 300 \
         --connect-timeout 12 -o linux-6.18.44.owrt.tar.xz \
         https://sources.openwrt.org/linux-6.18.44.tar.xz
    sleep 2
done

if ok_owrt; then
    echo "OWRT_DL_OK $(stat -c %s linux-6.18.44.owrt.tar.xz)"
    echo "$EXPECT  linux-6.18.44.owrt.tar.xz" | sha256sum -c -
    exit 0
fi

echo "== owrt failed after retries; trying github codeload gregkh tag =="
for i in $(seq 1 40); do
    echo "== gh attempt $i $(date +%T) size=$(stat -c %s linux-6.18.44.gh.tar.gz 2>/dev/null || echo 0)"
    curl -fL --speed-limit 20000 --speed-time 20 -C - --max-time 300 \
         --connect-timeout 12 -o linux-6.18.44.gh.tar.gz \
         https://codeload.github.com/gregkh/linux/tar.gz/refs/tags/v6.18.44 && break
    sleep 2
done
echo "GH size: $(stat -c %s linux-6.18.44.gh.tar.gz 2>/dev/null)"
exit 1
