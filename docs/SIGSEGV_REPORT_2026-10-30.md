# SIGSEGV 家族调查报告（2026-10-30 定稿）

> 本文是 2026-10-22 至 10-30 全部工作的**闭环版**：只写"实测确认"与"实测排除"，
> 过程见 `SIGSEGV_ANALYSIS.md` §1–§24。

## 1. 一句话结论

进程崩溃不是 printf 的缺陷，而是**外部写进 32 字节"引擎上下文记录"**覆盖了 `va_list`/指针；
记录内容与 **dpmaif 寄存器的实时值逐字段吻合**，落点是用户页，且**只在进程执行时发生**。

## 2. 已证实的机制链

| 环节 | 证据 | 强度 |
|---|---|---|
| 记录是 32 字节、16B 对齐 | 7 份 core 的 `va_list` 处逐字节相同结构 | 已证实 |
| 记录含**实时** dpmaif 寄存器 | `{r180\|r094, r1e0, bat_va, bat_pa+8}`；r094 与 5 s 采样外推吻合 `0x8fb44b70→0x8fb45350→0x8fb47240` | 已证实 |
| 记录含内核 VA（`bat_va`） | ⇒ 来源是 AP 内核里的驱动结构 | 已证实 |
| 落点是用户页（栈/.bss） | core 的 PT_LOAD 反查；`va2pa.ko` 实测 PA | 已证实 |
| 只在执行时发生 | 空闲 `sleep` 栈页 8 min **0 次写**；自旋进程 1–2 起/min | 已证实 |
| 不是随机撒网 | 512 MB 金丝雀 1.5 h **0 命中**；1 GB 分配 **0 命中** | 已证实 |

## 3. 已排除（全部为实测，不是推理）

| 假设 | 判据 |
|---|---|
| musl printf / va_list 自身缺陷 | 坏值由外部写入；静态化后同崩 |
| 日志环与用户内存普遍重叠 | 1 GB 分配 + 40 条 kmsg 标记 → 0 命中 |
| 日志环写普通进程栈 | 灌 256 KB 日志后查 `sleep` 栈 → 0 处 |
| aee 崩溃报告路径 | 停 aee 后崩溃率 2.14 起/min（未降） |
| 我们自己的 procfs 读取 | 停掉 snapwatch/dpscan9 采样后速率不降（1.7 起/min） |
| MD 引擎 DMA 写上下文 | 内容与 MD/SCP DRAM dump 无交集；§15 的 RV33 store 级硬负结论 |
| 页尾 0xfc0 是硬约束 | 实测落点页内偏移 0x270/0x290/0x480/0x940/0xb48，0xfc0 只是其中一种同余 |

## 4. 复现与观测工具（本轮新建，全部可复用）

| 工具 | 作用 | 位置 |
|---|---|---|
| `pfcanary` | 200M 次 snprintf，崩溃率 0.76–4 起/min（随实例数 1:1） | `/data/repro/pfcanary` |
| `va2pa.ko` | 用户 VA → 物理地址（走进程页表，`pin_user_pages_remote`） | `tmpfiles/repro/va2pa.c` |
| `pwatch.ko` | 按 PA 轮询比对，命中打 jiffies 时间戳 | `tmpfiles/repro/pwatch.c` |
| `logbuf.ko` | 读内核日志缓冲地址/长度 | `tmpfiles/repro/logbuf.c` |
| `core_meta.sh` v1.6 | 每次崩溃留 4 KB note 头（PC/寄存器/故障地址）+ 完整 core 6 份 | `gw/core_meta.sh` |
| 构建链 | `zig cc -target aarch64-freestanding` + 内核头 + `kincl` | `tmpfiles/repro/pf_manifest.txt` |

## 5. 崩溃现场的三类落点（core 实测）

| 进程 | PC | 符号 | 故障地址 | 被写的值 |
|---|---|---|---|---|
| `grep` | 0x4e30f8 | `tre_make_trans+0x154`（musl 正则建树） | 0x2a14a | 0x2a146（树节点指针） |
| `grep` | 0x4caee0 | `vgetopt32+0x1dc`（busybox 选项解析） | 0x159ae | 0x159ae（va_list 游标） |
| `ip` | 0x10a64d8 | —（strip） | 0x22f58 | 0x22f58（字符串指针） |
| `pfcanary` | 0x1014728 | musl `va_arg` | 0x1247b / 0x1f620000 | 32 字节上下文记录 |

⇒ 闸门（vfprintf 硬化）只覆盖"printf 读 va_list"这一类；其余三类都不经过它。

## 6. 唯一未闭环项

**32 字节记录的写入者身份**。最强候选：ccci/mipc 驱动的调试缓冲（文本形态即其寄存器 dump），
页面释放后又被分配给进程，驱动仍在写。缺的证据是 vendor 内核里该缓冲的分配/释放路径
（源码不在手上，需反汇编内核镜像里引用 `rt_req_sta3` 的函数）。

## 7. 建议的下一步（按性价比）

1. 反汇编 vendor 内核镜像 → 定位 `rt_req_sta3` 的引用函数 → 看 dump 写入哪个指针；
2. 检查该指针所指页是否 `memblock_reserve`；若漏，即为根因，修法是"开机预留这批页"；
3. 若短期无法改内核：把 `va_list` 硬化推广到 `vgetopt32`/正则建树等已知落点（成本低、非根治）。

## 8. 数据与现场

- `/data/gw/logs/ne_events.tsv`：崩溃台账（含 args/origin/unsync 标记）
- `/data/gw/logs/cores/raw/*.core|.hdr`：完整 core 6 份 + 每次崩溃的 4 KB note 头
- `/data/repro/{pfc_runs.log,r094.log,canary.log}`：复现器与寄存器采样
- 提交：`bea0c32` `1c5f45c` `3e892cb` `d435667`（分析正文 §21–§24）
