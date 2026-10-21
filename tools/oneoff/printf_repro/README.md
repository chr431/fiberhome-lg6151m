# printf_repro — musl snprintf 崩溃最小复现（2026-10-21 取证轮）

> 一次性取证资产（oneoff，不登记）。结论正文见
> `docs/SIGSEGV_ANALYSIS.md` §12，证据存档见
> `_local/archive/stability_2026-10-21/`。

## 复现

```sh
sh tools/oneoff/printf_repro/build.sh /tmp/printf_repro_out
# 推到设备（走 deploy.py put 或任意合法通道）后：
/tmp/printf_repro_out/pfcanary ; echo rc=$?     # 2 秒内 rc=139
```

`pfcanary.c` 只做一件事：循环 `snprintf(b, 24, "%ld", i)`。设备上
**0–2 秒必崩**（约 1/1.6e6 次调用），`-O0/-O1/-O2` 全崩。

## 现场

- 崩溃点：`pop_arg` 的 va_arg；`ap->__gr_top = 0`、`__stack` 是小整数；
  整个 va_list（32 B）被写成 `{小整数, 0, 0x1c28416e00001180, 0}`。
- 该高 32 位 `0x1c28416e` 与 logc v1.3 的旧 core **完全相同** → 同一缺陷。
- 帧布局：`nl_type` 在 `ap2` 下方 0x30 字节，`nl_type[12..15]` 正压在
  `ap2.__stack/__gr_top` 上。

## 覆盖 libc 的迭代环（P0 方法）

musl 的 `vfprintf.c` 可单独编译并**显式链接在 libc.a 之前**覆盖同名符号：

```sh
M=<zig>/lib/libc/musl
"$Z" cc -target aarch64-linux-musl -O2 -D_GNU_SOURCE \
  -I"$M/src/internal" -I"$M/src/include" -I"$M/include" \
  -I"$M/arch/aarch64" -I"$M/arch/generic" \
  -c "$M/src/stdio/vfprintf.c" -o vfprintf.o
"$Z" cc -target aarch64-linux-musl -O2 -static pfcanary.c vfprintf.o -o pf_over
```

未打补丁的 `pf_over` 仍然崩 → 覆盖链有效，之后每改一版 2 秒验证。

## 已排除（均仍崩）

| 尝试 | 结果 |
|---|---|
| 上游 master 的 `vfprintf.c` | 10/10 崩 → 缺陷不在该文件逻辑 |
| `vsnprintf` 先 `va_copy` 到局部再转发 | 10/10 崩 → 不是调用边界拷贝单独造成 |
| 目标缓冲 4096 / `%d` / 固定值 | 各 5/5 崩 → 与值、格式、缓冲大小无关 |
| 诊断链（三层 va_list 校验） | 报告 va_list 进 vfprintf 时已坏；但"取 &ap 再校验"会被编译器物化副本，观测失真 |

## 下一步

1. 用 zig **从源码构建 musl**，对比 **libc 自身** `-O0/-O1/-O2`（此前只换过程序的优化级别，libc 一直是预编译 -O2）；
2. 用不取地址的字节比较或硬件观察点钉死写入指令；
3. 拿到写入者后再决定补丁形态（musl 侧 vs 编译器侧）。
