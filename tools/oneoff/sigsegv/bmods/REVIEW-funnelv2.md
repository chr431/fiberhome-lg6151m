# REVIEW-funnelv2 — 嵌入拷贝扫描（D27 / funnel v2）

- 源码：`funnelv2.c` · 自检工具：`funnelv2_selftest.c` · 构建：`build_bmods.sh`
- 产物：`out/funnelv2.ko`（**v2.1：194,576 B，md5 `7943ded51d728724267551d116dafd2a`**；
  v2.0 为 195,672 B / `6c8b39bacbc0feb806bd716a800b2768`，见 §14）
- 自检产物：`out/funnelv2_selftest`（1,024,432 B，md5 `a063faa88ec19a2e9a4f44417bf2b025`）
- vermagic：`5.15.134 SMP mod_unload aarch64`（构建脚本尾部自证，与设备 5.15.134 一致）
- 性质：**会写内核文本的 B3 模块**（1 个 4 字节 `b` patch，`rmmod` 还原并读回）。
  站点/补丁原语与 `funnelcatcher.ko`（v1，D23）逐字相同。
- 依据：`_local/investigations/sigsegv-tools/phase-AB/S1-sw-gaps.md` §4.3/§5；
  `docs/SIGSEGV/05_LOG/2026-11-03-06-d23-funnel.md`（v1 实测）。

## 0. v1 → v2 差异

| 项 | v1（D23） | v2（本模块） |
|---|---|---|
| 长度 | 仅 32/16 | asm 过滤 `len ∈ [16,0x1000]`；范围外直接走被替换指令（不进 C） |
| 形状位置 | src offset 0 | 任意 16B 倍数 `o`，起点 `o0 = (-dst)&0xf`，记录 `off` |
| 快筛 | 无 | 每个 16B 步 `q1==0 && q3==0`（2 次 64-bit load） |
| 内容判据 | 家族 B（A0B2/B0A2） | 同族；另计 16B-core 探索变体（只计数） |
| dst | 不限 | 硬条件用户 VA；`stack_hint`（8MB 带）进 hot，其余进 cold |
| 环 | 64 条/CPU 统一 | hot 1024 + cold 256/CPU，独立丢包计数 |
| 全量 src | 无 | 每 CPU **首条 stack 命中**额外保存 ≤0x1000B 全量 dump |
| 正对照 | 32B pipe | 32/64/128/0xc0/0xd0 五组 + 16B-core + 8B 错位（见 §8） |

## 1. 站点与补丁原语（与 v1 相同）

- 站点：`__arch_copy_to_user` 入口 `0xffffffc00843b680`，首字 `05 00 02 8b`
  （`add x5,x0,x2`），次字 `aa 01 03 ef`（`mov x15,x1`）。
- `CONFIG_RODATA_FULL_DEFAULT_ENABLED=y` + `mark_linear_text_alias_ro()` 使
  `[_stext,_etext)` 的线性别名也 RO；直接写 `__va(pa)` 会 fault。
- 原语（逐字复用 v1）：TTBR1 页表遍历（处理 PMD/PUD leaf）→ `pfn_to_page` →
  `vmap(1 页, PAGE_KERNEL)` → 在别名写 4 字节 `b <trampoline>` → 对 image VA
  `dc civac + ic ivau`（每 CPU，`stop_machine` 内）→ 还原后 `vunmap`。
- 还原：同原语写回原 4 字节，3 次尝试 + 读回断言；`/proc` 顶部 `PATCHED` 状态。
- `dryrun=1`：定位、字校验、分支距离、PA/别名映射与读回全部执行，**不写一字节**。

## 2. trampoline 与长度过滤（最终产物实测字节）

```
0000 adrp x15, #0          0f000090   ; funnelv2_calls
0004 ldr  x16, [x15]       f00140f9
0008 add  x16, x16, #1     10060091
000c str  x16, [x15]       f00100f9
0010 sub  x15, x2, #0x10   4f4000d1   ; len-16
0014 cmp  x15, #0xff0      ffc13ff1   ; (len-16) <= 0xff0  <=> 16<=len<=0x1000
0018 b.hi 0x3c             28010054   ; out of range -> displaced insn
001c stp  x0, x1, [sp,#-0x40]!  e007bca9
0020 stp  x2, x30, [sp,#0x10]   e27b01a9
0024 mov  x3, x30          e3031eaa   ; lr = caller x30
0028 mov  x4, x29          e4031daa   ; fp = caller x29
002c bl   funnelv2_cand    00000094   ; R_AARCH64_CALL26 (loader fills)
0030 ldp  x0, x1, [sp]     e00740a9
0034 ldp  x2, x30, [sp,#0x10]  e27b41a9
0038 add  sp, sp, #0x40    ff030191
003c add  x5, x0, x2       0500028b   ; displaced instruction
0040 adrp x15, #0         0f000090   ; funnelv2_ret = site+4
0044 ldr  x16, [x15]      f00140f9
0048 br   x16             00021fd6
```

- **寄存器安全性（逐条核过 vmlinux 反汇编）**：`__arch_copy_to_user` 在
  `0xffffffc00843b684..0x...b700` 内先写 `x15,x6,x4,x3,x7,x8`，再读；`x9..x18`
  首次访问均为写。因此 trampoline 的 C 调用只破坏 x0–x18（AAPCS64 caller-saved）
  是安全的；x19–x29 由 C 编译器按 ABI 保存，x0/x1/x2/x30 由 trampoline 显式恢复。
- 长度范围外的调用只多 1 次全局计数 RMW（`funnelv2_calls`，非原子、粗略），
  不进入 C、不读 src。
- 反汇编自检（`funnelv2_cand`，.text+0x50，1192 B）：`neg w10,w0; and x27,x10,#0xf`
  即 `o0=(-dst)&0xf`；chunk 循环、`q1|q3` 快筛、A0B2/B0A2 内容判据、core16 分支
  均按 §3 生成（详见 `_local/work/d27/fv2_cand.txt`，302 条指令）。

## 3. 扫描算法（C 侧）

```
len 不在 [16,0x1000]                  -> return（asm 已过滤，此处仅防御）
dst >= 1<<44 或 dst+len 回绕          -> nonuser++，return
stack_hint = mm && dst ∈ [start_stack-8MB, start_stack+0x1000)
near      = 同带内且 dst ∈ [start_stack-256KB, ...)
!stack_hint && len>0x100              -> 1:16 采样（sampled++）
len < 32                              -> 只查 16B core（o0+16<=len）
o = o0; while (o+32 <= len):
    chunk = min(0x100, len-o); nofault 读 src+o..+chunk（失败 srcfault++ 并停）
    for k in 0,16,...:
        q0 = ld64(buf+k)
        core16(q0,buf+k) ? core16++                    # 每 16B 步，含尾部
        if k+32 > chunk: continue
        q1 = ld64(buf+k+8); q3 = ld64(buf+k+24)
        if (q1|q3) != 0: continue                      # 两 load 快筛
        q2 = ld64(buf+k+16)
        A0B2: (u32)q2∈[0x40,0x4000] && p[20] 是 unicast IPv4
              （首字节 ∉ {0,127,224..255}）；q0 低 32∈[0x1000,0x100000] 置 A_SMALL
        B0A2: q2>>32==0 && (u32)q2∈[0x1000,0x100000] && q0!=0
        命中 -> hot/cold 环（每调用最多 8 条，超出 capped++）
    if chunk < 0x100: break
    o += 0xf0                                      # 16B 重叠，覆盖跨界窗口
```

- 块读用 `copy_from_kernel_nofault`（v1 同款），坏 src 不会 oops；每次调用
  最多扫 0x1000B（≤256 个 16B 步），范围外由 asm 直接放行。
- `q1/q3` 快筛是 2 次本地缓冲 load；`q0` 每步 1 次（core16 需要）；`q2` 仅快筛
  通过后读 1 次。

## 4. 环与 /proc

- `struct fv2_rec` = **128 B**（`BUILD_BUG_ON` 钉死）：`ts,lr,dst,src,len,off,
  q0..q3,trace[3],pid,flags,comm[16]`。
- `struct fv2_cpu` = **168,216 B/CPU**（hot 1024×128 + cold 256×128 + 4KB dump +
  计数器）；4 CPU ≈ **657 KiB**（`alloc_percpu`，非 .bss；init 日志打印实测值）。
- 写端：per-CPU 单写者、`head=(idx<<1)|guard` 无锁；嵌套/重入丢 `drop`。
- 读端 `/proc/funnelv2`：头部（site/orig/cur/patch/tramp/pa/alias/sym/filter/
  clock/calls_total）+ 每 CPU 两行计数 + hot/cold 最近 `maxread` 条（默认 32/环，
  上限 256）+ 首条 stack 命中的全量 dump（hex）。
- 读端在 guard=1 时把 `cnt` 减 1，不暴露正在写的记录；环回绕时仍可能与写端
  重叠（诊断件可接受，见 §12）。

## 5. 逐函数自审

| 函数 | 上下文/锁 | 故障路径 | 递归/睡眠 |
|---|---|---|---|
| `funnelv2_cand` | 任意上下文（含 IRQ）；无锁；只用 `this_cpu_ptr` | 所有 src 读 nofault；dst 只比较不解引用；`current->mm` 空则 stack=0 | 不睡眠；不调用 printk/alloc |
| `fv2_scan` | 被 cand 内联；栈上 0x100B 缓冲 | 块读失败 `srcfault++` 并停；chunk 步进 0xf0 保证终止 | 无 |
| `fv2_ring_put` | 同上下文；per-CPU 单写者 | guard 冲突丢 `drop`；dump 失败置 `dump_used=2` | 不睡眠 |
| `fv2_unwind` | 同上下文 | 每级 2 次 nofault；fp 非内核/非 8 对齐/不递增即停 | 无 |
| `fv2_verify` | init 上下文 | 站点字/分支距离/PA walk/别名读回任一失败即 -EINVAL/-ERANGE/-EIO，不写 | 可睡眠（init） |
| `fv2_walk_pa` | init | PUD/PMD leaf 直接取物理地址；缺页/坏表返回负码 | 无 |
| `fv2_patch_cb` | **stop_machine 回调，禁止睡眠** | 只做 1 次 4B 写 + dsb + dc/ic；原子计数与 `num_online_cpus()` 配对 | 无 |
| `fv2_write_site` | init/exit | `stop_machine` 返回值透传 | 可睡眠 |
| `fv2_install` | init | 写后站点 + 别名双读回；不符 -EIO | 可睡眠 |
| `fv2_restore` | exit/init 失败 | 3 次写回 + 读回；失败打印 RESTORE FAILED 并返回 -EIO | 可睡眠 |
| `fv2_show_ring` | seq_file 读 | 只读自有环；`sprint_symbol` 可能较重但不在热路径 | 可睡眠 |
| `fv2_show_dump` | seq_file 读 | 只读自有 dump | 可睡眠 |
| `funnelv2_init/exit` | init/exit | alloc→verify→install→proc 顺序；失败逐级回退 | 可睡眠 |

**热路径调用闭包**：`funnelv2_cand` → `copy_from_kernel_nofault`、`memcpy`、
`memset`、`fv2_ring_put`；`fv2_ring_put` → `copy_from_kernel_nofault`、`memcpy`、
`memset`。**没有** printk、alloc、mutex、可能睡眠的调用。

## 6. 调用闭包（`python check_calls.py out/funnelv2.ko ...` 实跑）

```
internal functions reached: cleanup_module funnelv2_cand fv2_open fv2_restore
                            fv2_ring_put fv2_show fv2_show_ring init_module
EXT CALL __alloc_percpu / __sw_hweight64 / cpumask_next / free_percpu / memcpy /
         memset / msleep / stop_machine / vmap / vunmap / copy_from_kernel_nofault /
         _printk / proc_create / proc_remove / seq_printf / seq_putc / single_open /
         sprint_symbol
```

全部为内核导出符号：`__alloc_percpu`/`copy_from_kernel_nofault`/`stop_machine`/
`vmap`/`vunmap`/`sprint_symbol` = EXPORT_SYMBOL_GPL；`__sw_hweight64`、`cpumask_next`、
`free_percpu`、`memcpy`、`memset`、`msleep`、`proc_*`、`seq_*`、`single_*` =
EXPORT_SYMBOL。`seq_read/seq_lseek/single_release` 仅经 `proc_ops` 函数指针引用
（数据重定位，不出现在 CALL26 闭包中），同样是导出符号。

## 7. 崩溃路径分析

| 风险 | 处置 |
|---|---|
| 站点字漂移 | 首字必须 == `0x8b020005`，否则 -EINVAL；`dryrun=1` 先看实测字 |
| 分支越界 | init 计算 `tramp-site`，必须 ∈ (-128MB,+128MB)，并反解码回目标比对 |
| 别名读回不符 | patch 前必须相等，patch 后再读回；不符 -EIO，不继续 |
| 页表 walk 遇大页 | PUD/PMD leaf 直接换算物理地址（不 BUG_ON）；缺页返回 -ENOENT |
| 写文本时别的 CPU 在执行 | `stop_machine` 全 CPU 停 + 每 CPU `dc civac/ic ivau/dsb/isb` |
| 4B 写非原子 | arm64 对齐 4B store 单拷贝原子；且在 stop_machine 内完成 |
| 坏 src | 全部 `copy_from_kernel_nofault`；trampoline 内无裸读 |
| 环重入 | guard 位；嵌套丢 `drop` |
| 栈开销 | trampoline 0x40 + `funnelv2_cand` 0x220（实测反汇编）= **0x260/调用**；16KB 内核栈可承受（v1 为 ~0x140，已实跑 1890s） |
| 卸载时线程仍在 trampoline | restore(stop_machine) → `msleep(100)` → 才 vunmap/free_percpu；**修正 v1 的 free→sleep 顺序**（v1 存在窄 UAF 窗口） |
| 还原失败 | 3 次尝试 + 读回；仍失败打印 RESTORE FAILED。此时**必须重启设备**，不得继续运行（模块文本即将释放，残留 `b` 会跳空） |
| 被 `rmmod -f` | 禁止：强制卸载会释放模块 .text，残留 `b` 跳进已释放页 |
| 栈带判断 | `mm->start_stack` 只读；`ss > 8MB` 防下溢；`mm==NULL` 时 stack=0（cold） |

## 8. 正对照设计 + 离线静态验证

工具 `funnelv2_selftest`：每组一个**新 pipe**，`write(payload, len)` 后
`read(fd, 栈缓冲, len)`；pipe 读走 `copy_page_to_iter → copyout →
__arch_copy_to_user`，源页偏移 = payload 偏移。记录为 A0B2
`{0x12345,0,0x680,192.168.9.145,0}`，填充 0xAA。

| 组 | len | off | dst 对齐 | 期望 |
|---|---|---|---|---|
| G1 | 32 | 0x00 | 16 | hot A0B2 @ o=0 |
| G2 | 64 | 0x10 | 16 | hot A0B2 @ o=0x10 |
| G3 | 128 | 0x60 | 16 | hot A0B2 @ o=0x60 |
| G4 | 0xc0 | 0xa0 | 16 | hot A0B2 @ o=0xa0（0xc0 内能容纳 32B 记录的最大偏移） |
| G5 | 0xd0 | 0xb0 | 16 | hot A0B2 @ o=0xb0（**D21 现场几何**：记录 VA=sp_call−0xb0） |
| G6 | 0xc0 | 0xb0 | 16 | 只命中 core16，**不得**产生 32B 记录 |
| G7 | 64 | 0x08 | 8 | hot A0B2 @ o=8（`o0=8` 对齐分支） |

> **重要几何修正**：32B 记录放在 0xc0 拷贝的 0xb0 处**物理上不成立**
> （0xb0+32=0xd0 > 0xc0）。S1 §4.2 表中“n=0xc0, o=0xb0”只能是 **16B core**
> （q7 槽单 16B），或 32B 记录必须放在 0xa0（q6+q7），或拷贝长度 ≥0xd0。
> 因此正对照把“四组”定义为 G1–G4（32/64/128/0xc0），另加 G5（0xd0/0xb0，
> 现场同构）与 G6（0xc0/0xb0 core16）把该几何分别覆盖。

离线镜像 `_local/work/d27/sim_scan.py` 逐行复刻 asm 过滤 + C 扫描（chunk/重叠/
o0/快筛/内容/core16），对 7 组 payload 实跑：

```
G1-32B@0           len=0x020 off=0x00 mis=0 o0=0 hits=[(0, 'A0B2')] core16=1 quick=1 bytes=32 OK
G2-64B@0x10        len=0x040 off=0x10 mis=0 o0=0 hits=[(16, 'A0B2')] core16=1 quick=1 bytes=64 OK
G3-128B@0x60       len=0x080 off=0x60 mis=0 o0=0 hits=[(96, 'A0B2')] core16=1 quick=1 bytes=128 OK
G4-0xc0@0xa0       len=0x0c0 off=0xa0 mis=0 o0=0 hits=[(160, 'A0B2')] core16=1 quick=1 bytes=192 OK
G5-0xd0@0xb0       len=0x0d0 off=0xb0 mis=0 o0=0 hits=[(176, 'A0B2')] core16=1 quick=1 bytes=208 OK
G6-0xc0-core16     len=0x0c0 off=0xb0 mis=0 o0=0 hits=[] core16=1 quick=0 bytes=192 OK
G7-64B@8-mis8      len=0x040 off=0x08 mis=8 o0=8 hits=[(8, 'A0B2')] core16=1 quick=1 bytes=56 OK
asm_len_ok(0xf)=False OK / (0x10)=True / (0xfff)=True / (0x1000)=True / (0x1001)=False
RESULT: ALL OK
```

**注意**：每个 A0B2 记录的第二个 16B（`{len,ip}`）本身也满足 core16 形状，
所以 G1–G5/G7 的 `core16=1` 是预期行为；core16 是**超集计数**，不能单独作为
H_emb 判据（判据见预注册文档 §5）。

## 9. 与 S1 规格的偏差/实现说明

1. **dst 硬条件**：S1 §4.3 D 明确 `stack_hint` “只标注、不丢弃”。实现为：
   用户 VA 是硬条件；stack 带（8MB）进 hot，非 stack 进 cold；非 stack 且
   len>0x100 按 1:16 采样。判决只看 hot（`FV2_F_STACK`）命中。
2. **长度范围外计数**：asm 在进入 C 前过滤 `[16,0x1000]`，范围外不计数（保持
   v1 的零开销快路径）。范围外占比可由 `calls_total − Σ(eligible+nonuser)`
   粗略界定；v1 已实测 `cand32≈235/s`、`cand16≈397/s`（D23）。
3. **每记录 4KB src**：1280 条 × 4KB = 5MB/CPU，与“~0.5MB”预算冲突。实现为
   每条记录存 32B 命中内容 + src VA + off，另给每 CPU **首条 stack 命中**
   保存 ≤0x1000B 全量 dump（4KB/CPU，总计 +16KB）。
4. **core16**：探索性、只计数不记录；且是 A0B2 后半段的超集（见 §8 注）。
5. **卸载顺序**：修正 v1 的 `free_percpu` 先于 `msleep` 的顺序（§7）。
6. **环读取**：guard=1 时读端不暴露在写记录；回绕撕裂仍可能存在（§12）。

## 10. 扫描开销估算（热路径）

| 调用形态 | 额外内存访问 |
|---|---|
| len ∉ [16,0x1000] | 1 次全局计数 load + 1 store（其余 2 条 ALU + 分支） |
| len ∈ 范围，dst 非用户 | 2 次比较后返回（无 src 读） |
| len ∈ 范围，用户 dst，非 stack 且 len>0x100 | 1/16 概率进入下面的扫描 |
| 扫描（长度 L） | 约 `0.31·L` 次 load + `0.125·L` 次 store + `≈L/240` 次 nofault 调用 |

- 每 16B 步：`q0`(1) + `q1/q3`(2) + 块拷贝均摊(2 load/2 store) ≈ **5 load + 2 store**。
- L=32 → 1 步 ≈ 7 load；L=0x80 → 8 步 ≈ 40 load；L=0x100 → 16 步 ≈ 80 load；
  L=0x1000 → 256 步 ≈ **1280 load + 512 store**（≈1–2 µs @ A55 2.2GHz）。
- D23 实测漏斗 15.6k 次/s；若 10% 在范围内、均值 128B，≈ **62k load/s**；
  即使 100% 在范围内且均值 128B，≈0.6M load/s（<0.05% 单核）；最坏全 4KB
  也仅 ≈20M load/s（≈1% 单核）。块读走 L1 本地缓冲，快筛不触用户内存。

## 11. 加载/卸载序列与执行建议

```
# 0) 离线核对（不写任何东西）
insmod /data/gw/funnelv2.ko dryrun=1
dmesg | tail -20            # 期望 site word=8b020005、delta in-range、alias readback ok
cat /proc/funnelv2          # 顶部 dryrun；filter 行正确；calls_total=0

# 1) 正式安装（只改 1 条 4B 分支）
insmod /data/gw/funnelv2.ko
cat /proc/funnelv2          # 顶部 PATCHED；站点读回 = patch 字

# 2) 正对照（窗口内执行一次）
/data/gw/funnelv2_selftest
cat /proc/funnelv2          # 期望 comm=funnelv2_selftest 的 5 条 hot A0B2
                            # (len=32/o=0, 64/0x10, 128/0x60, 0xc0/0xa0, 0xd0/0xb0)
                            # + 1 条 o=8（G7）；core16 计数增加；G6 无 32B 记录

# 3) 收窗
rmmod funnelv2
dmesg | tail -5             # 期望 restored site word 8b020005 (readback ok)
cat /proc/funnelv2          # 应已消失
```

**执行建议（设备线）**：热窗 ≥1200 s；客户端持续拉 `app.js`（≥50 KB/s）复现
D23 的流量形态；每 5 s 轮询 `/proc/funnelv2` 落盘；正对照在窗口内做一次并
用 `comm/pid` 排除；收窗后核对 `calls_total`、`eligible`、`a0b2/b0a2`、
`core16`、`recd_hot/cold`、`srcfault`、`drop`。若 hot 出现非对照 A0B2，
优先看 `lr_sym`/`tr0..tr2`/`off`/`doff` 与 D21 的 `spva=0xb0` 对齐。

## 12. 残余风险

1. **栈开销**：每次 c2u 进入 C 的调用多 0x260B 内核栈；深层调用链（NFS/加密）
   理论上可能逼近 16KB 上限。缓解：只有 `len∈[16,0x1000]` 才进 C；仍建议
   首窗短（≥300 s）观察无 oops 后再拉长。
2. **环回绕撕裂**：读端在写端回绕覆盖旧记录时可能读到半新半旧字段；判决看
   多条记录的一致性（lr/off/comm），不依赖单条。
3. **`calls_total` 非原子**：多 CPU 并发 RMW 会丢计数；只作量级参考，
   精确分母用每 CPU `eligible+nonuser` 之和。
4. **stack 带 8MB 假设**：默认 `RLIMIT_STACK=8MB`；若 victim 用 `setrlimit`
   扩栈，栈底可能低于 `start_stack-8MB`，会落入 cold（仍记录，但不在 hot）。
   `/proc` 的 `stack_cold`/`cold` 环可用于复核。
5. **家族内容判据的取值域**：A0B2 的 `len∈[0x40,0x4000]`、unicast IPv4；
   B0A2 的 `A'∈[0x1000,0x100000]`。域外变体不记录（与 v1/D23 同口径）。
6. **0xc0/0xb0 的物理限制**（§8）：若现场确实由 0xc0 拷贝携带，v2 只能通过
   core16 看到 q7 的 16B 核心；32B 判据要求拷贝 ≥0xd0 或记录在 0xa0。
   这一点必须写进执行线报告，不能把 core16=0 当作“0xc0 路径已排除”。
7. **站点参数**：`site=` 只应在 dryrun 核对后使用缺省值；错误站点可能在
   insmod 时 oops（`panic_on_oops=y` → 重启）。

## 13. 复跑

```
# 构建（zig，无需 kbuild；产物在 out/）
sh lg6151m-public/tools/oneoff/sigsegv/bmods/build_bmods.sh

# 调用闭包
python lg6151m-public/tools/oneoff/sigsegv/bmods/check_calls.py \
       lg6151m-public/tools/oneoff/sigsegv/bmods/out/funnelv2.ko \
       init_module funnelv2_cand fv2_ring_put fv2_open fv2_show cleanup_module

# 离线扫描镜像（正对照静态验证）
python -I _local/work/d27/sim_scan.py
```

## 14. v2.1 设备线修正（2026-11-03，dryrun 门禁发现）

- **缺陷**：v2.0 用 `alloc_percpu(struct fv2_cpu)` 承载 168,216 B/CPU。5.15 的
  `pcpu_alloc()` 对单块 `size > PCPU_MIN_UNIT_SIZE`（32 KiB）直接
  `WARN("illegal size (%zu) or align (%zu) for percpu allocation")` 并返回 NULL；
  首次 `insmod dryrun=1` 在 `pcpu_alloc+0xbc` 产生 WARNING（非 oops），
  `init_module` 返回 -12，`/proc/funnelv2` 未创建。**仪器未进入任何窗**。
- **修法（最小）**：`fv2_cpus` 改为普通指针，`vzalloc(num_possible_cpus() *
  sizeof(struct fv2_cpu))` 一次性分配；快路径用
  `&fv2_cpus[raw_smp_processor_id()]`，show/init 循环用 `&fv2_cpus[cpu]`，
  回收 `vfree`。**环容量（hot 1024/cold 256/dump 4 KiB）、记录格式、扫描逻辑、
  patch 原语、正对照 payload 全部不变**。`raw_smp_processor_id()` 与 v1/v2.0
  的 `this_cpu_ptr` 同为“不关抢占取 CPU 号”，不改变既有单写者前提（诊断件）。
- **调用闭包变化**：`__alloc_percpu`/`free_percpu` → `vzalloc`/`vfree`
  （均为 `EXPORT_SYMBOL`，check_calls.py 实跑确认）。
- **复验**：dryrun 通过 —— `word=8b020005`、`delta=-111404672 (in-range)`、
  `pa=00000000fdc3b680 off=680`、`alias=ffffffc008097000 readback ok`、
  `/proc` 顶部 `dryrun`、`calls_total=0`；`rmmod` 后站点恢复 `8b020005`（dmesg
  `restored site word 8b020005 (readback ok)`）。
- **产物**：`out/funnelv2.ko` 194,576 B / md5 `7943ded51d728724267551d116dafd2a`
  （v2.0 = 195,672 B / `6c8b39ba…`）。自检工具未重建，md5 仍 `a063faa8…`。
