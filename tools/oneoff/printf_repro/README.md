# printf_repro — musl snprintf 崩溃最小复现（2026-10-21 取证轮）

> 一次性取证资产（oneoff，不登记）。**机制结论只看
> `docs/SIGSEGV_ANALYSIS.md`（§0.5 总表 → §12 → §13）**；本文件只说明"怎么复现"。
> 证据存档见 `_local/archive/stability_2026-10-21/`。

## 复现

```sh
sh tools/oneoff/printf_repro/build.sh /tmp/printf_repro_out
# 推到设备（走 deploy.py put 或任意合法通道）后：
/tmp/printf_repro_out/pfcanary ; echo rc=$?     # 2 秒内 rc=139
```

`pfcanary.c` 只做一件事：循环 `snprintf(b, 24, "%ld", i)`。设备上
**0–2 秒必崩**（约 1/1.6e6 次调用），`-O0/-O1/-O2` 全崩。

## 现场

崩溃点、坏块形态、健康基线与判据见 `docs/SIGSEGV_ANALYSIS.md` §12.3/§13.2
（含"哪些当时的判断已被推翻"）。一句话：崩在 `pop_arg` 的 va_arg。

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

## 下一步（2026-10-22 更新）

第 1、2 条已做（分层二分 + 不取地址的校验）。结论、缺口与剩余步骤见
`docs/SIGSEGV_ANALYSIS.md` §13.2/§13.4（本文不复述机制）。

## 2026-10-22 追加：P0 攻坚套件（分层二分 + 硬化补丁）

§12 的"musl printf va_list 污染"已经用下面的仪器收敛到可交付形态，结论正文见
`docs/SIGSEGV_ANALYSIS.md` §13。

| 文件 | 用途 |
|---|---|
| `p0probe.c` | 10 模式矩阵：自有可变参数 / `%ld` / `%s` / `%e` / `sprintf` / n=0 / 常量参数 / 静态缓冲 / 控制组 |
| `p0probe2.c` | 加进程内 SIGSEGV dump（寄存器、PC、PC 处 32 字节、栈窗口） |
| `p0probe3.c` | dump 增加"按寄存器指针取 96 字节" |
| `p0probe4.c` | 修掉行缓冲溢出（`b[96]`→`b[256]`），固定两位十六进制 |
| `p0probe5.c` | 直调 `vfprintf` 的模式（判断是否与 vsnprintf 层有关） |
| `p0cal.c` | **仪表校准**：炮制已知 fault，逐字段核对 dump。改 dump 后必跑 |
| `layerchk/` | 覆盖 musl stdio 三层的检查点（`p0chk.h` 的 `CHK` 宏）+ 显式无副本链（`my3_vfprintf.c`）+ 硬化补丁（`h_vfprintf.c`） |

### 复现"污染被拦下"的最小闭环

```sh
# 1) 编硬化版（pop_arg 入口 5 行 guard，见 §13.3）
sh layerchk/build.sh            # 产出 layerchk/out/{pfguard,pfctl,pfrec,pfcp,pfscope,pfchk3}
# 2) 推设备（走 deploy.py put），跑 A/B
/data/p0/pfguard 200000000      # survived calls=200000000 guard_hits=15
/data/p0/pfctl   200000000      # Segmentation fault (core dumped)
```

### 关键教训（避免重犯）

1. **先校准 dump 再下结论**。本轮最初的"寄存器与内存矛盾"全部是处理器自己的
   行缓冲溢出造成的假象。
2. 取 `&ap` 对**参数位** va_list 会物化副本（实测差 0x200），校验点要放在
   局部 va_list 或指针参数上。
3. `__vr_top = 0x1c28416e00000680` **不是**指纹：高 32 位是循环计数器形态的值，
   会出现在任意偏移。判据必须是"字段是否指向用户可访问范围 + 偏移是否为负"。
4. 改 `vfprintf.c` 的逻辑无效 —— 坏值在进入它之前就在 va_list 里了。
