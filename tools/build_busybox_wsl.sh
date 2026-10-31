#!/bin/sh
# build_busybox_wsl.sh v2.0 -- rebuild busybox 1.36.1 (aarch64, static, musl).
# Run inside WSL2/Ubuntu or any x86_64 Linux.
#
# v2.0 (2026-10-31 vaguard 退役轮): 移除 va_list 闸门链接 —— 单层防御定案,
#   进程内故障统一由 nerepair(ptrace supervisor)拦截修复; 闸门的历史拦截
#   (49 次)发生在底层污染源仍活跃的时代, 该源自旧内核修复栈退役后已消失。
#   自建 busybox 的定位自本轮起是**纯工具链**(402 applet 全集 + 1.36.1 语义
#   基线; 原厂件缺 timeout/comm/base64 等, 7 个守护脚本依赖 PATH 型 timeout,
#   ~900 处 PATH 型文本工具调用按 1.36.1 调校), 不再承担任何防务。
#   附带收益: 构建不再依赖仓外对象(_local/build/vaguard.o)与 musl 源码头文件。
#   断言反转: 产物必须**不含** vaguard 残留; 若 BB 源树是 v1.1 时代打过
#   trylink 补丁的(grep 得到 vaguard), 自动重解压干净树。
#
# Why a GNU musl cross toolchain and not zig: busybox's kbuild host tools,
# scripts/trylink (gcc-only linker flags), strip and the applet table each fight
# a clang/zig driver; the GNU toolchain is the supported path
# (docs/SIGSEGV_ANALYSIS.md section 20.1).  With the GNU driver trylink needs
# no patching at all (the v1.1 patch existed only to inject the guard object).
#
# Inputs (env):
#   TC_DIR      musl cross toolchain root      (default ~/aarch64-linux-musl-cross)
#   BB_SRC      existing busybox source tree   (default: download 1.36.1)
#   OUT         output binary                  (default: <repo>/gw/bin/busybox)
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
TC=${TC_DIR:-$HOME/aarch64-linux-musl-cross}
BB=${BB_SRC:-}
OUT=${OUT:-$REPO/gw/bin/busybox}
WORK=${WORK:-$HOME/bb-build}

need() { command -v "$1" >/dev/null 2>&1 || { echo "missing: $1" >&2; exit 1; }; }
need make; need gcc; need tar; need python3; need curl

mkdir -p "$WORK"

if [ ! -x "$TC/bin/aarch64-linux-musl-gcc" ]; then
    echo "== fetching musl cross toolchain (108 MB) into $TC"
    curl -L -o "$WORK/musl-cross.tgz" https://musl.cc/aarch64-linux-musl-cross.tgz
    mkdir -p "$(dirname "$TC")"
    tar xf "$WORK/musl-cross.tgz" -C "$(dirname "$TC")"
fi
export PATH="$TC/bin:$PATH"

if [ -z "$BB" ]; then
    BB=$WORK/busybox-1.36.1
    if [ ! -d "$BB" ]; then
        echo "== fetching busybox 1.36.1"
        curl -L -o "$WORK/bb.tar.bz2" https://busybox.net/downloads/busybox-1.36.1.tar.bz2
        tar xjf "$WORK/bb.tar.bz2" -C "$WORK"
    fi
    # v2.0: v1.1 时代的树可能被注入过闸门对象 —— 检出即重解压干净树
    if grep -q "vaguard" "$BB/scripts/trylink" 2>/dev/null; then
        echo "== BB tree carries the v1.1 guard patch -- re-extracting clean"
        rm -rf "$BB"
        tar xjf "$WORK/bb.tar.bz2" -C "$WORK"
    fi
    grep -q "vaguard" "$BB/scripts/trylink" 2>/dev/null && {
        echo "trylink still polluted (no clean tarball?)" >&2; exit 1; }
fi

echo "== configuring and building (defconfig + CONFIG_STATIC, no guard)"
cd "$BB"
make defconfig >/dev/null
sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
make -j"$(nproc)" CROSS_COMPILE=aarch64-linux-musl- SKIP_STRIP=y \
     LDFLAGS="-static -no-pie"

file busybox | cut -c1-90
# v2.0: 断言反转 —— 闸门已退役, 产物必须干净(vfprintf 防线由 nerepair 单层接管)
if strings busybox | grep -q vaguard.tsv; then
    echo "!! guard residue in binary -- refusing to install" >&2; exit 1
fi
cp busybox "$OUT"
chmod 755 "$OUT"
echo "== installed $OUT ($(stat -c%s "$OUT") bytes, guard-free)"
