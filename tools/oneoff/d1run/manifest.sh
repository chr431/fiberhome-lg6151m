#!/bin/sh
# manifest.sh -- 仪器运行清单 + 负结果纪律的最小实现（2026-10-27）
#
# 用法（设备侧）：
#   . /data/gw/logs/d1/manifest.sh
#   mf_begin <run_name>
#   ... 采集 ...
#   mf_end <note>
#
# 产出 <run_name>.manifest.txt，含：构建哈希 / vermagic / 模块参数 /
# 起止 wall_epoch / uptime 前后 / lsmod 前后 diff / 计数器的上限与饱和标志。
#
# 铁律（本项目 2026-10-27 一轮得出的，见 SIGSEGV_ANALYSIS.md §7）：
#   1. 任何「零」必须写成「0 / N 次观测，检出下限 X」
#   2. 计数器先查上限，再谈「噪声 ≈ 0」
#   3. 数据文件第一列恒为 wall_epoch
#   4. vmalloc 地址跨重启不稳定，必须运行时解析后经模块参数传入

MF_DIR=${MF_DIR:-/data/gw/logs/d1}
MF_NAME=""
MF_T0=0
MF_UP0=""

mf_begin() {
  MF_NAME="$1"
  MF_T0=$(date +%s)
  MF_UP0=$(cut -d' ' -f1 /proc/uptime)
  {
    echo "# manifest $MF_NAME"
    echo "start_epoch=$MF_T0"
    echo "start_uptime=$MF_UP0"
    echo "kernel=$(uname -r)"
    echo "cmdline=$(cat /proc/cmdline)"
    echo "--- lsmod before ---"
    lsmod
    echo "--- module params before ---"
    for m in $(lsmod | awk 'NR>1{print $1}'); do
      d=/sys/module/$m/parameters
      [ -d "$d" ] || continue
      for p in "$d"/*; do
        [ -f "$p" ] || continue
        echo "$m.$(basename $p)=$(cat $p 2>/dev/null)"
      done
    done
  } > "$MF_DIR/$MF_NAME.manifest.txt"
}

mf_end() {
  local note="$1"
  local t1 up1
  t1=$(date +%s)
  up1=$(cut -d' ' -f1 /proc/uptime)
  {
    echo "end_epoch=$t1"
    echo "end_uptime=$up1"
    echo "duration_s=$((t1 - MF_T0))"
    echo "note=$note"
    echo "--- lsmod after ---"
    lsmod
  } >> "$MF_DIR/$MF_NAME.manifest.txt"
  {
    sed -n '/--- lsmod before ---/,/--- module params before ---/p' "$MF_DIR/$MF_NAME.manifest.txt" | grep -v -- '---' | sort > /tmp/.mf_a
    lsmod | sort > /tmp/.mf_b
    echo "--- lsmod diff (before -> after) ---"
    diff /tmp/.mf_a /tmp/.mf_b
    rm -f /tmp/.mf_a /tmp/.mf_b
  } >> "$MF_DIR/$MF_NAME.manifest.txt"
  echo "manifest written: $MF_DIR/$MF_NAME.manifest.txt"
}

# mf_zero <label> <count> <floor_desc>
# 负结果的标准写法：没有它，任何「0」都不许写进结论。
mf_zero() {
  printf '%s\t0/%s observations\tfloor=%s\n' "$1" "$2" "$3"
}

# mf_vmap <PA>  -- 从 /proc/ccci_dump 解析驱动为保留内存建的 vmap VA（跨重启不稳定，勿硬编码）
mf_vmap() {
  grep -a "vmap_reserved_mem: ($1" /proc/ccci_dump | tail -1 | sed 's/.*(//; s/)//'
}
