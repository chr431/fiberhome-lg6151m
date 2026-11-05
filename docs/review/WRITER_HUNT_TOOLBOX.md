# WRITER_HUNT_TOOLBOX · 32B 记录写入者点名：可执行观测手段工具箱

> 任务：task-9（看板）｜作者：v5-analyst｜日期：2026-11-03
> 目的：回答「能否进一步扩展观测手段」——给**能直接照做**的手段卡，而不是方法论散文。
> 证据等级：E0 无证据｜E1 弱｜E2 强推断｜E3 直接观测｜E4 因果闭环。
> 引用纪律：不引用已撤回结论（88/112、自然 NE 0/4、C-138、C-145、C-016/017/018/019）；每条手段都带「判 INVALID 的条件」。
> 只读边界：本文所有设备信息来自**只读**快照（附录 A 审计），**未做任何写操作**（无 insmod / 无 echo 到 /proc / 无 dd / 无重定向）。

---

## 0. 约束（先读这一节，它决定每种手段是否可行）

### 0.1 厂商内核 5.15.134（设备只读实测 + 台账）

| 能力 | 状态 | 证据 |
|---|---|---|
| KPROBES / KPROBE_EVENTS | **无**（/sys/kernel/debug/kprobe_events 与 /sys/kernel/tracing/kprobe_events 均不存在） | 只读实测 audit5/audit7；C-144（CONFIG_KPROBES=n, CONFIG_MODVERSIONS=n） |
| FTRACE / TRACING | **无 tracing 目录**（/sys/kernel/tracing 不存在）；/proc/config.gz 里 **FTRACE=y 但未见 TRACING=y 行** | audit5/audit7（口径：grep 只打印含 = 的行，未打印=未启用或不存在） |
| PERF_EVENTS | **无 /proc/sys/kernel/perf_event_paranoid**；config 无 CONFIG_PERF_EVENTS=y | audit5/audit7 |
| pagemap | **/proc/self/pagemap 不存在**；/proc/kcore 不存在 | audit5 |
| USERFAULTFD | **无**（无 /proc/sys/vm/unprivileged_userfaultfd；C-179：syscall 是 -ENOSYS 桩，CONFIG_USERFAULTFD=n） | audit5；C-179（E3） |
| 硬件观察点（DBGWCR/DBGVCR） | **判不可用**：EL1 常开 PSTATE.D=1 且 vendor 树不编 hw_breakpoint.o（CONFIG_HAVE_HW_BREAKPOINT 未设） | kdev 05_LOG §7.1（E3） |
| SMMU / IOMMU | **无**：CONFIG_IOMMU_SUPPORT 未置；vmlinux 0 处 smmu；无 arm_smmu_*/mtk_iommu 符号 | FIX.md §7.3（E3）；本报告复核 lab 同 0 |
| STRICT_DEVMEM | **未设（=n）**：RAM 可经 /dev/mem 读；**MMIO 被拒** | C-183；C-185（读 netsys 0x15105c00 返回空） |
| 自建内核模块 | **可加载**（历史已做 dphook/patrace/rxring/tuphook/uacatcher/dmahook/funnel/wdkill/pageguard/slotguard） | 06_INSTRUMENT_FIXES F-11/F-12；03_PROBES |
| 设备级硬约束 | **panic_on_taint + panic_on_oops 都开** ⇒ 任何模块 bug ≈ 一次非计划重启 + 新数据代次 | 10_MEASUREMENT_PROTOCOL §12（已两次实证） |
| 可用只读通道（实测） | /sys/kernel/debug 已挂载且可列；/proc 下有 warp_ctrl、mtkfe、hnat、ccci_dump、ccci_log、healthdog；/sys/fs/pstore/console-ramoops-0；/proc/interrupts | audit3/audit4 |

### 0.2 lab 6.18.44（现成能力；**这是「扩展观测」的最大增量**）

| 能力 | 状态 | 出处 |
|---|---|---|
| KPROBES / KPROBE_EVENTS / DYNAMIC_FTRACE / FUNCTION(_GRAPH)_TRACER / FTRACE_SYSCALLS / UPROBE_EVENTS / TRACING | **y** | LABKERNEL.md §1 |
| PERF_EVENTS + HW_BREAKPOINT（kptr/perf paranoid 由 /init 清零） | **y** | LABKERNEL.md §1 |
| USERFAULTFD / PROC_PAGE_MONITOR | **y** | LABKERNEL.md §1 |
| PAGE_OWNER | **y**（cmdline page_owner=on） | LABKERNEL.md §1 |
| KGDB+KDB（kgdboc=ttyS0,921600） | **y** | LABKERNEL.md §1 |
| KEXEC / KEXEC_FILE | **y**（内核侧；用户态 kexec-tools 未内置，/bin/kjump 会如实报缺） | LABKERNEL.md §1、§7-5 |
| /dev/mem | **放宽（STRICT_DEVMEM=n）** ⇒ **MMIO 可读**（厂商侧被拒的那些寄存器在 lab 可读） | LABKERNEL.md §1 |
| 观测载荷 | scanary（md5 17376b74…）+ vsurv4 + 串口全量落盘 + p46 持久化 | D28 §3/§4 |

### 0.3 三条硬纪律（写进任何一次新实验的预注册）

1. **不重复已被排除的三个杠杆**（10_MEASUREMENT_PROTOCOL §5）：RX 包数 1366× 无响应；canary 重启（新栈页）无响应；eth0 环 down/up ×2 无响应。
2. **同会话 + 页级归因**（C-182）：任何 slot/页 判读必须过四检（内容域 / 变化宽度 / 偏移级归因 / 同会话）——「页级计数」不算归因。
3. **一次一变量 + 正对照 + 可判 INVALID**：没有功效计算的 A/B 不做；0 命中必须同时给出 N、LOD、正对照（否则只能是 E0/E1）。

---

## 1. 手段总表（先看这张，再按需翻卡片）

| # | 手段 | 判决类别 | 厂商可用 | lab 可用 | 目标等级 |
|---|---|---|---|---|---|
| T-01 | dropwatch（MADV_DONTNEED + mincore 回归） | VA vs PA | 是（用户态） | 是 | E2（需外部 fault 正对照） |
| T-02 | uprot / rovictim2（自 mprotect(PROT_READ) 制造可归因缺页） | VA vs PA + CPU 写 | 是（靶子禁忌见 §2.1） | 是 | E4（若 dmesg 出 PC/LR） |
| T-03 | romap（直映射别名改只读） | CPU 直映射写 vs DMA | 是（模块） | 是 | E3/E4 |
| T-04 | pte_redirect 三哨兵 | VA vs PA（终局） | **已作废**（C-174 双所有权 panic） | 若重写必须满足修复要求 | 目标 E3 |
| T-05 | madvise 迁移跟随（D6） | VA-targeted vs PA-targeted | 是（用户态） | 是 | E2 |
| T-06 | userfaultfd 点名写入者（D17） | CPU uaccess 点名 | **BLOCKED**（C-179） | **是（仅 lab）** | E4 |
| T-07 | 硬件观察点（perf hw watchpoint） | **仅受害自身写；无「谁写」判别力（U-A′）** | **判不可用** | 可装载但不解决判别力 | E1–E2 |
| T-08 | **RO-PTE 哨兵 + 故障 PC 归因（受限靶子）** | **CPU 写 vs 非 CPU 写（U-A）** | 是（模块 + 靶子纪律） | 是 | **E4** |
| T-09 | fxhook（fixup_exception 钩子） | uaccess 点名 | 是（待写） | 是 | E3 |
| T-10 | uaccess 漏斗再测（只补 embedded/atomic 口径） | uaccess 排除边界 | 是 | 是 | E2 |
| T-11 | DMA map/unmap per-device 钩子 | 引擎归因 | 是（dmahook 已交付） | 是（ftrace/kprobe 版，无模块） | E2/E4 |
| T-12 | 引擎状态快照（hnat/mtkfe/warp_ctrl/debugfs） | 引擎归因 | 是（只读） | 是 | E1/E2 |
| T-13 | 「命中即冻结」一次性冻结快照 | 引擎归因 + 全状态 | 高成本（见卡） | 是（KGDB 可控停世界） | 目标 E3/E4 |
| T-14 | 中断时间戳 ↔ 命中率相关（秒级，同会话） | 引擎/触发器归因 | 是（只读） | 是 | E2 |
| T-15 | CCCI/MD 侧通道（ttyCMIPC 裸帧 + DPMAIF/MD_WDT IRQ + ccci_dump） | 引擎归因（MD） | 是 | 是 | E2 |
| T-16 | 已有模块仪器的复用纪律（tuphook/uacatcher/patrace 的覆盖集核对） | 手段复用纪律 | 是 | 是 | — |
| T-17 | page_owner / page history | 页来源与资格 | **无 PAGE_OWNER** | **是（仅 lab）** | E3 |
| T-18 | 分配/释放链站点表（pageguard 式）+ 逆向「标记不隔离」 | 页来源与资格 | 是（模块） | 是 | E2/E3 |
| T-19 | 「养熟页池」（真实流量让页池经过 RX 缓冲态） | 消除目标页资格共线 | 是 | **必须在 lab 复做** | （前置条件，不是判决） |
| T-20 | /proc/patrace VA→PA + vmemmap/slab 对账 | VA/PA 与页身份 | 是（已交付） | 可直接读页表 | E3 |
| T-21 | 秒级引擎计数 ↔ 命中率相关（卡片见 §2.5，与 T-14 同机制） | 引擎/触发器归因 | 是（只读） | 是 | E2 |
| T-22 | 载荷 ↔ 流量构成对账（composition 级） | 触发器归因 | 是 | 是 | E2 |
| T-23 | ptrace=117 覆盖补丁（审计规则扩展 + 自建 ptrace 写者正对照） | 用户态跨进程写覆盖（U-C） | 是（0.5 人日） | 是 | E2（**有界**） |
| T-24 | 热态 + 其余 DMA map 变体（dma_direct_map_page / ops->map_page） | 引擎归因覆盖（U-D） | 是（dmahook 扩变体） | 是（ftrace 免模块） | E2 |
| S-1..S-5 | 功效/正对照/观测者排除/代次身份/槽身份四检 | 设计纪律 | — | — | 强制 |

**编号说明**：正文卡片编号与总表一一对应；下文 §2 的卡片按判决类别分组。

---

## 2. 手段卡（机制 / 能判决什么 / 需要什么 / 代价与风险 / 预注册判据与停止规则 / 目标等级）

### 2.1 类别 A：VA vs PA（同会话 + 页级归因）

#### T-01 dropwatch —— 用户态 VA/PA 判别器
- **机制**：把受害进程栈的一段 band 用 MADV_DONTNEED 丢弃，随后用 mincore() 观察哪些页**在程序自己没碰的情况下重新变为常驻**。页表被走到的（uaccess/GUP）⇒ VA 解析；DMA 按 PA 写**不碰 PTE** ⇒ 保持 missing。
- **能判决什么**：写入解析是「按 VA（走页表）」还是「按 PA」。**不点名**写入者。
- **需要什么**：现成二进制（C-181：tmpfiles/repro/dropwatch/dropwatch.c，身份 34408 B / md5 aebadf7d…；旧件 29064/1696f62f 因自伤 bug 作废）；无模块、无 userfaultfd、不阻塞写者。
- **代价与风险**：完全用户态 ⇒ 无 panic 风险；但**阴性有两义**（PA/DMA，或原子上下文 uaccess 失败写）。
- **预注册判据与停止规则**：三前置——(1) 外部 fault 正对照（另一进程对同一 band 做 process_vm_writev 写记录形状 32B ⇒ 必须出 1 resident_event + 1 DW_HIT）；(2) resident_events==0 必须与「同会话该槽确有写入活性」同时成立才可判 PA；(3) 判读走 C-182 偏移级归因（fault VA 与槽的 top−K 逐字节比对，**不接受页级计数**）。缺任一 ⇒ INVALID。
- **目标等级**：E2（有正对照时）。

#### T-02 uprot / rovictim2 —— 自 mprotect(PROT_READ) 制造可归因缺页
- **机制**：让**受害进程自己**把目标栈页 mprotect(PROT_READ)（同时清 VMA 的 VM_MAYWRITE），于是任何**经该 VA 的内核态 store** 变成真 permission fault；handler 读 si_addr 并恢复。
- **能判决什么**：CPU 经该 VA 的写 ⇒ 有 PC/LR（E4 点名）；DMA 照写 ⇒ 无 fault 但内容变（判 PA/DMA 方向）。**抓不到**走 COW 被内核悄悄满足的 uaccess（kdev 05_LOG §8.2）。
- **需要什么**：用户态（rovictim 件 25,864 B / md5 1cdd83f3…）+ 靶子进程；无需模块。
- **代价与风险**：**靶子禁忌（10_MP §12.4）**：禁止把 nerepair（或任何 ptrace 监督者）当实验对象——其 mm 与 ptrace 路径竞争，加写锁极易挂死（表现为 hang→watchdog 重启）。历史事故：uprot ro on nerepair 栈页 ⇒ **hang 型重启**（C-183：pstore 无 Oops、healthdog heartbeat stale EMERGENCY RESTART）。
- **预注册判据与停止规则**：RO 窗口内**先跑 60 s 稳定对照**（窗口内崩 = INVALID，F-07 要求）；正对照 = 故意写一次合成的 32B；命中判据 = fault VA 落在槽上（不是落在页上）。一次只做一个靶子；任一跳变立即回滚。
- **目标等级**：E4（若拿到 PC/LR）+ E2（若无 fault 但内容变）。

#### T-03 romap —— 把**直映射别名**改成只读（互补臂）
- **机制**：walk init_mm 页表到 PTE，清 PTE_WRITE / 置 PTE_RDONLY + flush_tlb_kernel_range + **回读校验**（kdev 交付件 romap.ko 194,648 B / md5 314974d6…）。
- **能判决什么**：**内核态经直映射（__va(pa)）的 store** ⇒ data abort + PC/LR（E4）；DMA 不看页表 ⇒ 照写。与 T-02 互补：T-02 抓「经用户 VA」，T-03 抓「经直映射」。
- **需要什么**：自建模块（可加载）；本内核 CONFIG_RODATA_FULL_DEFAULT_ENABLED=y ⇒ 线性映射按 4 KB 页建，单页可改；遇 2 MB 块模块**拒绝并报 block=1**（不猜）。
- **代价与风险**：模块 bug ⇒ 非计划重启（panic_on_taint/oops 双开）。ro_selftest=1（模块自有 RO 页故意 store）**默认关闭**，panic_on_oops=1 时拒绝（除非 ro_selftest=2）。协议要求卸载时逐页恢复 RW 并打印 unload restore pa=… rc=0。
- **预注册判据与停止规则**：PTE 回读一致 = 机制生效（E2）；窗口内出现 data abort 且 PC/LR 落在嫌疑站点 = 点名（E4）；**60 s 稳定对照缺失即 INVALID**（旧 remapu 就栽在这里，C-013 仍 E1/open）。每 boot 只 arm 一个页；任何 taint 迹象立即 rmmod + 重启回代次。
- **目标等级**：E3/E4。

#### T-04 pte_redirect 三哨兵 —— **当前作废，复活必须按事故修**
- **机制（原设计）**：受害页 PTE 改指向新页 Q，保留 P 的直映射只读哨兵；判据：Q 命中 ⇒ VA/PTE 解析；P 命中 ⇒ 裸 PA；两边都 0 ⇒ INVALID。
- **作废原因（C-174，E3）**：模块把 alloc_page 的**内核页直接塞进用户 PTE**，没有 mm 记账/rmap ⇒ pfn 0xacdcb **双所有权**；mm 之后释放该页、页又以 vmalloc 页回到分配器时 check_free_page() 抓到不一致 ⇒ BUG: Bad page state ⇒ panic_on_taint **panic**。
- **复活前置（硬性）**：**绝不把模块自有页插进用户 PTE**（要么完整 rmap/mapcount/anon 记账，要么改用用户进程自己映射的页）；且「mprotect 只能由受益进程自做」（scorecard §8 第 4 条）。
- **代价与风险**：一次失误 = 一次 panic 重启（已实证）；模块清理路径必须能在 mm 已死时只释放页、不写 PTE。
- **预注册判据与停止规则**：三哨兵 + 正对照（模块往 P+0x100 / Q+0x200 写合成记录，扫描必须报 kind=1/kind=2）；**两边都 0 判 INVALID，不判阴性**（kdev §4）。
- **目标等级**：目标 E3；当前**不可用**。

#### T-05 madvise 迁移跟随（D6）
- **机制**：用 madvise(MADV_DONTNEED)/换页把受害页**换一个 PA**，继续监测同一 VA 上是否仍出现记录。
- **能判决什么**：跟 VA 走 ⇒ VA-targeted（H2/H5 系）；跟 PA 走 ⇒ PA-targeted（H1 系）。这是 scorecard 的「终局」判据。
- **需要什么**：现成 scanary 深度臂（--victim main）+ 预注册判据；无需新模块。
- **代价与风险**：用户态低风险；但**跨会话不可比**（10_MP §2），必须同会话对照；采样率坑（kdev §2.1：活帧寿命约 1 µs vs 5 ms 扫描周期 ⇒ 必须 --hold-us 10000）。
- **预注册判据与停止规则**：迁移前后各 ≥10 条 inj=0 命中才允许下判（kdev §2.3 功效门槛）；页级归因必须记录 VA（C-182 第 3 条）；窗口内不追加其它仪器。
- **目标等级**：E2。

#### T-06 userfaultfd 点名写入者（D17）—— **仅 lab**
- **机制**：把受害 va_list 所在页注册给 userfaultfd；任何人（本进程或外部）**首次触碰该页**都产生 fault 事件并附带阻塞任务身份。
- **能判决什么**：事件 + **非本进程**的阻塞任务 ⇒ CPU uaccess（E4 点名）；仅自身 ⇒ 调保护区；0 事件 ⇒ 仅在「同一 VA 注册前有写入活性」时才可判页表旁路（PA），否则 INVALID。
- **需要什么**：**只能 lab**（厂商侧 C-179：__arm64_sys_userfaultfd 是 mov x0,#-38; ret 条件桩，CONFIG_USERFAULTFD=n；须先做 30 s syscall 探针推翻）。
- **代价与风险**：用户态 cbuffd，无 panic 风险；但 UFFD 事件风暴会打满 CPU ⇒ 事件合并/限速，且**必须先把 victim 调到 hold 体制**。
- **预注册判据与停止规则**：事件限速（≤N/s）；正对照 = 外部进程写一次 32B 必须出 1 事件；0 事件且无「注册前活性」⇒ INVALID。
- **目标等级**：E4。
### 2.2 类别 B：CPU 写 vs 非 CPU 写

#### T-07 硬件观察点（perf hw watchpoint）—— **降级：不可用于「谁写」判决（U-A′）**
- **机制**：perf_event_open(PERF_TYPE_BREAKPOINT) 在某个**线程**的 VA 上装写监视点；命中时该线程收到事件。
- **不能判决什么（关键更正）**：**监视点按线程装载** ⇒ 装在受害（canary）线程上，只能抓到**受害自身执行**的写；**抓不到别的进程、也抓不到内核上下文**（异常处理/内核 uaccess）对该地址的 CPU 写。因此它**不能**作为「CPU 写 vs 非 CPU 写」的现场判决，也不能替代 U-A。
- **厂商侧**：CONFIG_PERF_EVENTS **未置**（analysis/kern/config-extracted.txt；本报告 audit7 读 /proc/config.gz 亦未见启用行）⇒ 连装都装不上；且厂商侧硬件观察点已被判不可用（kdev §7.1：EL1 PSTATE.D=1 + 不编 hw_breakpoint.o）。
- **lab 侧**：6.18.44 有 PERF_EVENTS + HW_BREAKPOINT，但**仍不解决判别力问题**（按线程装载是硬件/ABI 层语义）。
- **仅剩用途**：①排除「受害自身写」（低价值——受害者写自己的栈本就与记录族无关）；②lab 上做硬件级行为自检（例如验证某段用户态代码没有写越界）。
- **目标等级**：E1–E2（不足以判「谁写」）。**不要**把它写进 U-A 的替代路径。

#### T-08 RO-PTE 哨兵 + 故障 PC 归因 —— **U-A（CPU 写 vs 非 CPU 写）的推荐设计**
- **机制**：**只动权限位**，把**受限靶子**的目标页改成只读：若「记录仍出现」⇒ 写者绕过了 MMU ⇒ **非 CPU（DMA/总线主写），E4**；若「出现缺页且 fault PC 落在内核 uaccess 路径」⇒ **CPU 写并当场点名调用者（E3/E4）**。
- **受限靶子（口径照写）**：用 **vsurv4 作豁免受害进程**；nerepair 走**单 inode 豁免**（nerepair.c:341-383）；即**靶子必须豁免 nerepair 的修复**，以免 nerepair 把崩溃改写成「无 fault」而抹掉判据。
- **前置纪律（缺一即 INVALID，不得当阴性）**：
  1. **C-174**：绝不插入外来页、不改页归属（只允许改权限位）；
  2. **C-175**：不得拿 ptrace supervisor（nerepair）当**未豁免**靶子（其 mm 与 ptrace 竞争 ⇒ hang→watchdog 复位；D8-uprot 事故即此）；
  3. **C-182**：**同会话 + 页级归因**（fault VA 必须与槽逐字节比对，页级计数不算）；
  4. **C-176**：**n≥20** 才有功效（0/4 只能把上界压到 ≤52.7%）。
- **需要什么**：自建模块（uprot 已有实现，事故史见 A-4）+ 用户态配合（rovictim2 式自 mprotect 作为对照臂）。
- **代价与风险**：**中**（只改权限位；风险集中在①靶子选择②权限位回滚③60 s 稳定对照）；任何「无 fault 但全用户态停摆」⇒ 按 10_MP §12.3 记 hang 型，不得记 panic。
- **预注册判据与停止规则**：① 正对照 = 故意写一次合成 32B 必须出 fault 且 PC 落在已知写入者；② RO 窗内**先跑 60 s 稳定对照**（窗内崩/停摆 = INVALID）；③ 判读三分：记录出现且无 fault ⇒ 非 CPU；记录出现且有 fault ⇒ CPU + 点名；记录既不出现也无 fault ⇒ INVALID。
- **目标等级**：**E4**（非 CPU 或点名任一支）。

#### T-09 fxhook（fixup_exception 钩子）—— 未做、值钱
- **机制**：钩 fixup_exception，抓**被异常表 fixup 吞掉**的 uaccess 缺页的 PC/LR（uwhook 的反面：uwhook 抓成功拷贝的目标，fxhook 抓失败/被吞路径）。
- **能判决什么**：uaccess 通路里「悄悄失败但仍改了目标」或「原子上下文失败写」的口径（T-01 阴性的第二义）；若 fixup PC 落在某驱动 ⇒ 点名（E3）。
- **需要什么**：自建模块（kdev 列为「待写」）；文本钩路径 dphook 已验证（aarch64_insn_patch_text）。
- **代价与风险**：**必须上机前离线自检**（F-11 教训：4 个缺陷、2 次真 oops，每次重试 = 一次非自愿重启）。修复点：PAC 序言（首条 paciasp ⇒ 只能打 +4/+8）、per-cpu 用 tpidr_el2（VHE）、proc_ops 必须有 .proc_lseek、位移方向 + 4 路反解自检。
- **预注册判据与停止规则**：安装后**回读校验**补丁字；窗口内 fixup 计数 > 0 且正对照（故意 uaccess 失败）命中；任何 oops ⇒ 立刻停止、回滚、写事故报告（三类重启分型）。
- **目标等级**：E3。

#### T-10 uaccess 漏斗再测（**只补边界，不重复主线**）
- **已做**：__arch_copy_to_user 家族 28.96M 调用 / 292.8 MB（C-206）与 embedded 大拷贝 20.2M 调用 / 2.77M 扫描 / 735.8 MB 源（C-214），记录族 0 条指名 ⇒ 按**已测未发现**表述（不宣布物理排除）。
- **还能扩展的边界（只这三条）**：①原子上下文失败写（走 T-09 fxhook）；②inline sttr / __put_user 形式的 store（需复核 F-06 的 14 条窗口内 store）；③非 uaccess 的**普通内核 store 到用户 VA**（无 ex_table ⇒ 直接 Oops，天然可归因，属 T-08 的产值）。
- **别做**：重复整族漏斗扫描；宽扫描形状代理约 148 次/s 误报 ⇒ 任何「0 命中」不得按特异性引用。
- **目标等级**：E2（边界级）。

### 2.3 类别 C：引擎归因

#### T-11 DMA map/unmap per-device 钩子
- **机制**：在每个 dma_map_page_attrs / dma_map_sg_attrs / dma_unmap_* 调用点打钩，记录 {device, dir, page, 调用者 LR, 时间戳}，**per-device 归因**（谁 map 了受害页/受害 PA）。
- **能判决什么**：哪个引擎在触碰受害页；「页被 map 过 ⇒ 引擎有写权限」的直接证据链（E2/E4）。
- **需要什么**：**厂商侧**：现成 dmahook（C-207：已 patch dma_map_page_attrs 0xffffffc00819aef0 与 dma_map_sg_attrs 0xffffffc00819a6f4，vmap-alias 4 字节分支，fake-page 过滤器）；**lab 侧**：不必写模块——直接用 kprobe events / ftrace 挂同名函数（lab 有 KPROBES+TRACING），是最便宜的版本。
- **代价与风险**：厂商侧模块 = 每次上机一次重启风险；**dmahook 的边界必须写在结论旁**（C-207：只覆盖两个 wrapper 变体、不覆盖 stale 描述符/热态/直接 dma_direct_map_page）。lab 侧风险低（无补丁、无模块），但**要在 lab 才有**。
- **预注册判据与停止规则**：正对照 = 一次已知 DMA（如 eth RX 灌包）必须出现 map 记录并解析出 device；**覆盖缺口逐条列出**（变体数、未覆盖调用点）；fake=0 之类零结果必须附「该变体是否被调用」的计数，否则 INVALID（C-207 教训：dpmaif/fmac_write_txp 0 调用 ⇒ 站点没被行使）。
- **目标等级**：E2（覆盖内）/ E4（若某次 map 与命中同刻同页）。

#### T-12 引擎状态快照（只读通道，实测清单）
- **机制**：把各引擎的**只读状态**按需快照，做「命中时刻 vs 基线」成对比较。
- **可用节点（本轮只读实测，audit3/audit4）**：
  - /proc/hnat/：hnat_mib、hnat_entry、hnat_dma、hnat_dbg、hnat_type、hnat_usage、hnat_med、cpu_reason、dvfs_debug_level/dvfs_en/dvfs_force_opp/…（hw_nat 引擎）；
  - /proc/mtkfe/：dump_dma（**注意 C-185：缓存快照，35 s 与 1.2 MB 定向流量后字节一致 ⇒ 不能当实时**）、dbg_dma、dbg_level、users；
  - /proc/warp_ctrl/：conf、tracer、warp1（WED tuple 门控 C-154 用过）；
  - /sys/kernel/debug/：mtketh/（mt7530sw_regs、phy_regs、reset…）、ccmni/ccmni_md1、mtk_hwifi/（bus、bus_trans、chips、interface、wsys）、dma_pools/、lru_gen、extfrag、ramdisk_pages、gpio、pinctrl、pwm。
- **能判决什么**：引擎级「是否在动」（MIB 增量）、「环里有没有受害页」（注意缓存陷阱）、中断/状态与命中的先后（配合 T-14）。
- **需要什么**：只读（cat/head）；**写入型节点列入禁用清单**：/sys/kernel/debug/mtketh/mt7530sw_reg_w、phy_reg_w、reset，/proc/hnat/* 的写语义字段。
- **代价与风险**：**读也可能有副作用**（部分 dump 触发硬件读/大输出 ⇒ 只 head 限幅、单次、不轮询）；C-184 教训：**扫描器自身污染**必须排除。
- **预注册判据与停止规则**：命中前后快照**成对**采集（同会话、≤1 s 间隔）；先做**迟滞对照**（无命中的同长度窗口取同样快照）以排除「dump 本身改变状态」；dump_dma 类缓存通道**不得**单独用于「环里有没有」的判决（C-185）。
- **目标等级**：E1/E2（结构性；单靠快照到不了 E3）。

#### T-13 「命中即冻结」一次性冻结快照（高成本、最高信息量）
- **机制**：把「命中检测」与「全状态冻结」串成一个仪器：一旦命中（canary 命中 / 槽内容变化）立即**停世界**并抓：全部引擎 ring、寄存器、页表项、内核栈。
- **两条实现路线**：
  1. **模块路线（厂商侧）**：命中即在原子上下文写 pstore/预置缓冲（**热路径必须 O(1)**；F-11 教训：锁内 O(n) 扫描 ⇒ RCU stall panic；dpquar 教训：热路径逐页加引用会抽干工作集）；冻结数据经 pstore 或 /data 缓冲落盘。
  2. **lab 路线**：**KGDB/KDB**（kgdboc=ttyS0,921600）在嫌疑 store 点设断点，命中即停世界抓寄存器与回栈；或 PERF + kprobe 组合。lab 还能直接 **/dev/mem 读 MMIO**（厂商侧被拒），等价于「无需模块的寄存器快照」。
- **能判决什么**：一次命中即可拿到**写入者 PC/LR**（E4）与当时全部引擎状态（E2/E3）；唯一可能一次收敛的手段。
- **代价与风险**：**最高**。厂商侧：模块 bug = panic 重启（已多次实证）；热路径不 O(1) = 系统卡死/RCU stall；冻结缓冲需预分配（GFP 约束：**GFP_KERNEL 采样抓不到 MOVABLE 页**——dpclamp v1.0 147K 采样 0 命中；要抓用户态来源页必须 GFP_HIGHUSER_MOVABLE，且要**自适应退火 + __GFP_NORETRY + cond_resched**，否则 2026-10-23 00:48 的 25 min 渐进冻结 + RCU-stall panic 会重演）。lab 侧：停世界在 921600 串口上很慢，只适合仪器环境。
- **预注册判据与停止规则**：先做**空仪器**（只注册、不冻结）跑通 + rmmod 无异常；冻结窗口 ≤N 次（避免风暴）；每次冻结后校验「设备仍可用」；任何 hang ⇒ 按三分法记录（hang ≠ panic）。
- **目标等级**：E4（若抓到 PC/LR）。

#### T-14 中断时间戳 ↔ 命中率相关（秒级、同会话）
- **机制**：1 Hz 采样 /proc/interrupts 的**每引擎 IRQ 计数**与相应 MIB，和命中率做同会话相关。
- **已有 IRQ 锚点（本轮只读实测，audit3）**：mt7992-wed（IRQ 18，单 CPU 695,294 次）、ccif_wo_isr(21)、CCIF_AP_DATA(294/295，32,756)、MD_WDT(296)、DPMAIF_AP(298，6,107)、MED_RX_IRQ(299，CPU3 5,832)、SCP WDT(495)、MBOX_ISR(28–35,301)。
- **能判决什么**：把「记录率」与**具体引擎的活动量**在 1 s 粒度对齐（哪个引擎先动）；D6/引擎归因的低成本旁证。
- **需要什么**：只读（cat /proc/interrupts + /proc/hnat/hnat_mib）；可复用既有采样框架。
- **代价与风险**：1 Hz 读 /proc 很轻；风险在**归因**：C-157（记录 IP 是流量构成的反映）、C-156（命中成簇与泊松零模型一致，无超额）⇒ **不要把相关写成因果**，也不要把簇当机制。
- **预注册判据与停止规则**：预注册「先动」定义（如命中跳变前 ≤3 s 内引擎计数阶跃）；必须给出**零模型对照**（同期无命中窗口的同计算）；未给 p 值/P 值不下结论。
- **目标等级**：E2。

#### T-15 CCCI/MD 侧通道（**本轮新增：lab 内核上该通道其实在场**）
- **机制**：MD/CCCI 是有自己处理器与 DMA 的**第二执行域**；状态可经 /dev/ttyCMIPC*（MIPC 裸帧，magic 0x84195424）、/proc/ccci_dump、/proc/ccci_log、/proc/ccci_lp_mem、/proc/ccci_sib 与 IRQ（DPMAIF_AP / MED_RX_IRQ / MD_WDT）观测。
- **能判决什么**：MD 侧是否活动、MD 数据面是否与命中同期；回答「V5 里 MD 是否是生产者的一部分」。
- **需要什么**：厂商侧只读节点 + gw/bin/mipc_cellular（自制、零 RIL，直接读 ttyCMIPC）；**lab 侧同类通道在**（V5 报告 F-5：lab 内核引导期注册了 ccmni0..20 与 ttyCMIPC0..N）。
- **代价与风险**：/proc/ccci_dump 可能是大 dump ⇒ head 限幅；C-184 教训：**MD 保留区（CCB 0x94000000-0x9820ffff、medmcu desc、lk_medmcu）经 /dev/mem 不可读 ⇒ 那里的「0」是 INVALID 不是阴性**；扫描器自身污染类命中必须剔除。
- **预注册判据与停止规则**：读数前先做**可读性映射**（哪些区可读），不可读区一律 NA（10_MP §11：未知写 NA，禁止用 0 充「未测」）；MD 侧结论不得外推到 AP 侧写入者身份。
- **目标等级**：E2。

#### T-16 已有模块仪器的复用（别再重造）
- **tuphook v1.4/live（F-11）**：WED tuple fill 入口捕获，7409 次调用、已 live 验证；结论见 C-197/C-211/C-212（fill 目标 100% 内核地址、0 受害者页命中；三 boot 基址一致）。**它是「环目标」仪器，不是「写入者」仪器**——再用前先问它能不能答新问题。
- **uacatcher（F-12）**：12 个 mt_wifi copy_to_user 站点捕获（正对照已过）；结论见 C-200/C-203。同上：只覆盖 12 个 call-style 站点。
- **patrace**：VA→PA（echo "<pid> <hexva>" > /proc/patrace）——**这是写语义**，本文档只读边界内不得使用；实验时按 10_MP §12.1 bring-up 流程。
- **教训**：仪器复用前必须核对**覆盖集**与本次问题是否同集，否则会把「站点没被行使」读成阴性（C-207 的 fake=0 与 C-195 的「未布防」都属此类）。

### 2.4 类别 D：页来源与资格（消除目标页资格共线）

#### T-17 page_owner / page history —— **仅 lab**
- **机制**：lab 的 CONFIG_PAGE_OWNER=y + page_owner=on；/sys/kernel/debug/page_owner 给出**每页的分配者（pid/调用栈）与顺序**；配合 PROC_PAGE_MONITOR 做页级溯源。
- **能判决什么**：受害页的**「资格」**——是否曾经是 RX 缓冲/DMA 目标页；直接把「目标页资格共线」从「不可消除的混杂」变成**可测变量**。
- **需要什么**：lab 内核；用户态读 debugfs；scanary 命中时记录受害页 PA/VA。
- **代价与风险**：page_owner 有内存/性能开销（大内存节点尤甚）；lab 内存节点 480 MB 保守值 ⇒ 采样要限幅、限定窗口；dump 可能很大 ⇒ head/increment 模式。
- **预注册判据与停止规则**：先做**正对照**（一次已知 RX 流量后，检查相关页 owner 链里出现 netdev/DMA 站点）；命中页与对照页**同批**取 owner；若命中页 owner 链里**从未出现** RX/DMA 站点 ⇒ 资格假设在该窗内不成立（**强结论**，可写）。
- **目标等级**：E3。

#### T-18 分配/释放链站点表 + 「标记不隔离」（pageguard 的逆向用法）
- **机制**：复用 FIX.md §2 的站点表（生产侧 mtk_rx_alloc_edma 0xffffffc008596174 / fe_edma_open 0xffffffc008589ba0；消费侧 alloc_zeroed_user_highpage_movable 0xffffffc00812724c / wp_page_copy 0xffffffc0082494a4，guard word 已给），但**不隔离页**——只**打标记/计数**（哪个页曾进 RX 池、后来又成了谁的匿名页）。
- **能判决什么**：把「受害页曾经是 RX 页」这条**因果链**从推测变为实测（E2/E3）；也是厂商侧无 page_owner 时的替代。
- **需要什么**：自建模块（可加载）；哈希表 ≤2 MiB + 计数（**不要 quarantine**，避免 dpquar 式「扣页抽干工作集」）。
- **代价与风险**：**pageguard 当前前提不利**（FIX §2.3：依赖 PA 写，而 H1a 已被几何证伪 E2）⇒ **不要把它当选修课**，只当「页来源」观测；模块 bug = 重启；热路径 O(1)（F-11 教训）。
- **预注册判据与停止规则**：判据 = **同一页**在生产站点 mark 后、在消费站点被计到、且随后该页出现在命中集合中（三事件同页）；black_hits 单独不算证据（FIX §2.3 明写「只看 black_hits 只证明机制在转」）。任何 taint 立即 rmmod。
- **目标等级**：E2/E3。

#### T-19 「养熟页池」（**前置条件，不是判决**）
- **机制**：在 lab 上用**真实流量**（有线 RX 灌包 + 点亮 WiFi 后的客户端流量）让页池经历「网络缓冲 → 释放 → 再分配」的完整历史，再跑 scanary 观测。
- **能判决什么**：消除**目标页资格共线**——让「lab 零结果」不再能被「目标页从未当过 RX 缓冲」解释。**这是把 lab 从『干净但可疑』变成『干净且可信』的必要前置。**
- **需要什么**：lab 内核 + 有线流量（现成）+ WiFi 点亮（mt7996e + 固件四件套/EEPROM，见 V5 报告 F-3：需名/格式映射）+ 客户端流量生成器；环境清单（见 §4.2）。
- **代价与风险**：**养熟同时会重新引入数据面流量**（V5 报告 §2 的核心混杂）⇒ 必须**分窗**：先「无流量 baseline」，再「养熟后静置窗」，最后「带流量窗」，一窗一变量。
- **预注册判据与停止规则**：养熟判据 = 页池统计（/proc/buddyinfo、/proc/pagetypeinfo、page_owner）中出现可核对的 RX 页历史；若养不熟（如 WiFi 点不亮）⇒ 如实写「资格共线未消除」，**不得**改用「厂商内核零结果」外推。
- **目标等级**：—（前置条件）。

#### T-20 /proc/patrace + vmemmap/slab 对账
- **机制**：/proc/patrace 把用户 VA 转 PA 并回读该页前 16 B（已验收）；配合 /dev/mem 读 RAM 做**页级对账**。
- **能判决什么**：VA→PA 即时映射（判「固定 PA」模型）、命中页与内核结构的同页关系。
- **需要什么**：patrace.ko（已交付）；/dev/mem（RAM 可读）。
- **代价与风险**：全 RAM 扫描是噪声底（C-160 教训：对照扫描同样命中 ⇒ 「找到引用」不成立）；**不得**用「在内存里找到 PA」做结论，除非有**已知在内存里的值**作正对照（scorecard §7 第 3 行）。
- **预注册判据与停止规则**：任何扫描必须带**噪声对照**（随机值 + 已知值）；命中数须显著高于噪声底；观测者自身（argv/栈）命中必须剔除（C-184 第 1 类自污染）。
- **目标等级**：E3（映射事实）/ E1（「持有引用」类推断）。

### 2.5 类别 E：流量侧（**避开已排除路线**）

#### T-21 秒级引擎计数 ↔ 命中率相关
见 T-14（同一工具，归因到引擎）。**不要**重做「注入已知包长/源 IP 找因果链」——C-186 已 0/46，H4 未复活。

#### T-22 载荷 ↔ 流量构成对账（composition 级）
- **机制**：记录的 len/ip 与**当时的流量构成**（WAN vs LAN、对端分布、连接数）对账。
- **能判决什么**：记录来自哪一类流；**不能**判决单包级因果。
- **需要什么**：抓包（设备侧 tcpdump 或 PC 侧）+ 记录样本（h4/scanary CTX）；已有工具链。
- **代价与风险**：C-157（两种 IP 分布是时段流量构成差异）、C-186（记录 ip 反映流量构成、len 与单包长度无关）⇒ 任何「某条流导致写入」需**多目的地/多构成对照**，否则会把「路径/目的地复合体」误归因（AGENTS 陷阱表：腾讯 CDN 误判案例）。
- **预注册判据与停止规则**：预先定义构成分组与每组**最小命中样本**；跨会话不可比（10_MP §2）；不得用记录 IP 反推单对端。
- **目标等级**：E2。

### 2.6 类别 F：统计与设计纪律（**每次实验强制**）

| # | 项 | 强制内容 | 出处 |
|---|---|---|---|
| S-1 | 功效与停止规则 | 两臂功效计算（Poisson, α=0.05 双侧, power=0.8）；热槽 0.62/s ⇒ 10 min 臂约 372 事件、可检出 50% 削减（1.3 min/臂）；自然 NE 0.5/h 需 94.2 h/臂才检出 50% ⇒ **自然 NE 只能当长期监视** | C-178 |
| S-2 | 两层验收 | 层 I = 写入活动（热槽 distinct-content 速率）；层 II = 后果（REPAIR 率/家族死亡/自然 NE）。nerepair 之类后果层修复**只按层 II 验收**，写入不变是预期 | C-178 |
| S-3 | 观测者排除 | 判据/仪器自身不得进入被观测集合（全量集合 + token 精确 + 排除自身/祖先）；扫描器 argv 自污染必须剔除 | AGENTS 判据三定律；C-184 |
| S-4 | 代次与身份 | 每次重启 = 新代次（跨代次不可比）；上机件五元组（名/字节/md5/构建时间/源码 diff）钉死；三类重启分开记（panic / hang→watchdog / 冷复位） | 10_MP §12.1/§12.2/§12.3/§13 |
| S-5 | 槽身份四检 | 内容域（A 值 40k–220k、mod 256 无集中）/ 变化宽度（+0x10..+0x17 是否在变）/ 偏移级归因（fault VA 逐字节比对）/ 同会话 | 10_MP §12.6；C-182 |

---

### 2.7 类别 G：覆盖缺口补丁（审计 U-C / U-D）

#### T-23 ptrace=117 覆盖补丁（U-C）—— **BEST 性价比**
- **机制**：现有 auditwatch 规则**明文排除 ptrace=117**（C-189 覆盖边界）⇒「覆盖集内零」不能外推。补法两条：①审计规则**加入 117** 类（注意发布者有独占 ptrace 会污染 kmsg：需限频/改用 per-task 过滤）；②**自建用户态对照**：一个已知的 ptrace 写者进程，向受害进程的 va_list 槽写记录形状 32B，审计必须命中（正对照）。
- **能判决什么**：**用户态 ptrace 型跨进程写**是否存在（有界覆盖集内）。
- **需要什么**：auditwatch 规则改动（仪器侧，非新模块）+ 自建对照程序；0.5 人日。
- **代价与风险**：低；唯一风险是 kmsg 洪泛（独占 ptrace owner + shared printk ratelimit）⇒ 必须限频与错峰。
- **预注册判据与停止规则**：正对照必须 1/1 命中；**结论一律写「有界」**：只覆盖审计规则覆盖集，不得写「用户态跨进程写不存在」。停止规则：正对照未命中 ⇒ 判 INVALID，先修仪器。
- **目标等级**：E2（有界）。

#### T-24 热态 + 其余 DMA map 变体（U-D）
- **机制**：dmahook 现状只覆盖 dma_map_page_attrs / dma_map_sg_attrs 两个变体、且只在**非热态**（C-207 边界）。补法：扩挂 dma_direct_map_page / ops->map_page 变体，并在**热态窗**（WiFi 客户端数据面活跃）重跑。
- **能判决什么**：受害页是否经由这些变体被 map（引擎归因的覆盖面补齐）。
- **需要什么**：dmahook 扩变体（现成件改造）+ 1 个热态窗；0.5 人日 + 1 窗。
- **代价与风险**：低（模块已成熟）；但**覆盖率必须逐条列缺口**（哪些变体没挂、哪些站点 0 调用 = 未行使而非无命中，C-207 教训）。
- **预注册判据与停止规则**：正对照 = 已知 DMA（eth RX 灌包）必须出现在两变体上；fake=0 类零结果必须附「该变体被调用次数」。
- **目标等级**：E2。

---

## 3. Top-3 最小执行集（每条 ≤1 页设计）

> **覆盖规则（Lead 定）**：Top-3 必须覆盖审计附录 A 的 **U-A（CPU 写 vs 非 CPU 写）+ U-B（D6 同会话 VA/PA）+ U-C（ptrace=117 覆盖缺口）**。下表按此重排；原「页来源三事件」与「引擎秒级相关」降入第二梯队（写明判决对象与优先级）。

### TOP-1 · U-A：RO-PTE 哨兵 + 故障 PC 归因（厂商侧，受限靶子；约 0.5–1 人日 + 30 min 窗）
- **判决对象**：**CPU 写 vs 非 CPU 写**（U-A）。
- **步骤**：① 选**受限靶子**：vsurv4 作豁免受害进程（nerepair 走单 inode 豁免 nerepair.c:341-383），**靶子必须豁免 nerepair 的修复**；② 只动权限位把目标页改为只读（绝不插入外来页/改归属，C-174）；③ 用户态配合的 rovictim2 式自 mprotect 作**对照臂**；④ 同会话两窗，页级归因记录 fault VA 并与槽逐字节比对（C-182）；⑤ 正对照 = 故意写一次合成 32B 必须出 fault。
- **预注册判据**：记录仍出现且无 fault ⇒ **非 CPU（E4）**；记录出现且有 fault 且 PC 落在内核 uaccess 路径 ⇒ **CPU 写 + 当场点名（E3/E4）**；记录不出现且无 fault ⇒ INVALID。
- **判 INVALID**：无 60 s 稳定对照；靶子未豁免 nerepair；页级（而非偏移级）归因；n<20（C-176 功效）。
- **设备风险**：中（改权限位；D8-uprot 的历史事故正是**靶子选错**——本设计在**受限靶子**下可复活，见 §5 与 §2.2 T-08）。
- **人日**：0.5–1。
- **等级目标**：E4。

### TOP-2 · U-B：D6 同会话迁移跟随（madvise 换 PA；现成 scanary 变体；约 0.5–1 人日）
- **判决对象**：写入按 **VA** 还是按 **PA** 解析（VA/PA 终局判决）。
- **步骤**：① lab 或厂商侧同会话；② victim 用 scanary 的 main 栈 + hold 体制（--hold-us 10000，避免活帧被自己覆写，kdev §2.1）；③ 迁移前后各 ≥10 条 inj=0 命中；④ 命中点相对 VA 与相对旧 PA 双记录。
- **预注册判据**：迁移后仍落**同 VA 相对位置** ⇒ VA-targeted；跟**旧 PA**/消失 ⇒ PA-targeted；两者都不成立 ⇒ 新模型，立即上报。
- **判 INVALID**：跨会话拼接（必须同会话）；页级归因；未达每档 ≥10 命中（功效不足）。
- **设备风险**：低（用户态）。
- **人日**：0.5–1。
- **等级目标**：E3。

### TOP-3 · U-C：ptrace=117 覆盖补丁（审计规则扩展 + 自建对照；约 0.5 人日）
- **判决对象**：**用户态 ptrace 型跨进程写**是否存在（audit 明文排除 117，C-189）。
- **步骤**：① 审计规则加入 117 类（限频、per-task 过滤，避免独占 ptrace 的 kmsg 洪泛）；② 自建 ptrace 写者向受害槽写记录形状 32B 作**正对照**，审计必须命中。
- **预注册判据**：正对照 1/1 命中；结论**必须有界**（只覆盖审计覆盖集）。
- **判 INVALID**：正对照未命中（先修仪器）；把结论写成「用户态跨进程写不存在」。
- **设备风险**：极低。
- **人日**：0.5。
- **等级目标**：E2（有界）。

### 第二梯队（不占 Top-3 名额；按判决对象与优先级排序）
| 序 | 条目 | 判决对象 | 优先级 | 人日 |
|---|---|---|---|---|
| 四 | T-18b「页来源三事件同页」（原 TOP-1） | 受害页是否曾经是 RX/DMA 池页（D5/U-E、U-I 方向） | 中（依赖 D5 的可行化，见 §5.5） | 1 |
| 五 | T-24 热态 dmahook 扩变体（U-D） | 其余 map 变体 + 热态是否触碰受害页 | 中（0.5 人日，现成件改造） | 0.5 + 1 窗 |
| 六 | T-14 + T-12 引擎秒级相关 + 快照（原 TOP-3） | 哪个引擎先动（旁证） | 中（用来缩小四/五的候选集） | 0.5 |
| 七 | D13 S 臂（SIGSTOP 冻结 + /dev/mem 直读 8 页栈） | 写入者是否需要目标处于运行态 | 低（可搭在六的同会话里做 rider） | 0.25 |

---

## 4. 只能在 lab 做的清单 & lab 复现前置

### 4.1 只能在 lab（厂商侧结构性不可用）
1. **T-06 userfaultfd 点名**（厂商 CONFIG_USERFAULTFD=n，C-179 E3）。
2. **T-07 硬件观察点**（lab 可装载；但**按线程装载 ⇒ 只抓受害自身写，对「谁写」无判别力**（U-A′）；厂商侧另有 EL1 PSTATE.D + 无 hw_breakpoint.o + 无 PERF_EVENTS）。
3. **T-11-lab ftrace/kprobe 版 DMA 归因**（无模块、无补丁、探针可瞬时增删）。
4. **T-17 page_owner 页级溯源**（厂商无 PAGE_OWNER）。
5. **T-13-lab KGDB 冻结 + /dev/mem 读 MMIO**（厂商 MMIO 被拒，C-185）。
6. **T-19 页池养熟 + 环境清单**（lab 是唯一能同时控制「有无 WiFi/客户端/厂商 .ko」的环境）。

### 4.2 lab 复现前置（缺一不可，逐条可核）
1. **WiFi 点亮**：按序 insmod cfg80211→mac80211→mt76→mt76-connac-lib→mt7996e + 固件就位；**已知缺口**：主线期望 mediatek/mt7996/mt7992_{wa,wm,dsp,rom_patch}.bin，设备只有厂商命名四件套且 mediatek/ 空（V5 报告 F-3）⇒ 先做名/格式映射；PCIe 已枚举 14c3:7992（F-2，E3）。
2. **客户端流量**：PC 关联 + 恒定速率 fetch（可复用既有 n3exec 脚本与 app.js 通道）。
3. **页池养熟**：有线 RX 灌包 + WiFi 客户端流量，让页池经历 RX 缓冲态（T-19）。
4. **环境清单（每窗必记）**：uname -r、ls /sys/class/net/、ls /dev/ttyCMIPC*、dmesg 中 ccci 段计数、PCIe 枚举行、lsmod 计数。
5. **判活/判据对齐**：判活用全量 /proc/*/stat 的 comm 精确比较 + 排除自身/父；判据与脚本**逐字对齐**（scanary matcher：len∈[0x40,0x20000] + ip_class∈{1,2}；后验栈扫描：LEN_MIN,MAX=0x400,0x20000 + 仅首段 IP）——两套不是同一判据，三语料必须同一套重扫。

---

## 5. 与 task-8 审计（WRITER_HUNT_GAP_AUDIT 附录 A）的机械交叉核对

> 规则（Lead 定）：Top-3 必须覆盖 **U-A（CPU 写 vs 非 CPU 写）+ U-B（D6 同会话 VA/PA）+ U-C（ptrace=117 覆盖缺口）**，或给等价说明；表外条目须写「判决对象 + 优先级」；对不上即记漏项。
> **结论：无漏项。** §3 的 Top-3 已按 U-A / U-B / U-C 重排（TOP-1/2/3）；表外条目（U-E/U-G/U-H/U-J/U-K）在下表逐条给状态与优先级。

### 5.1 U-A … U-K 逐行

| 审计条目 | 我的 T-id / TOP-id | 状态 | 理由 / 替代路径 |
|---|---|---|---|
| **U-A** CPU 写 vs 非 CPU 写的现场判决 | **T-08（RO-PTE 哨兵 + 故障 PC 归因）+ TOP-1** | **已覆盖** | 受限靶子：vsurv4 作豁免受害进程，nerepair 走单 inode 豁免（nerepair.c:341-383）；只动权限位；记录仍出现 ⇒ 非 CPU（E4）；缺页且 PC 落内核 uaccess 路径 ⇒ CPU + 当场点名（E3/E4）。前置 C-174/C-175/C-182/C-176（§2.2 T-08） |
| U-A′ 不得用硬件监视点敷衍 U-A | **T-07（已降级）** | **已覆盖（降级说明）** | 监视点**按线程装载** ⇒ 装受害线程只抓受害自身写，**抓不到别的进程/内核上下文** ⇒ 对「谁写」无判别力；厂商 CONFIG_PERF_EVENTS 未置（analysis/kern/config-extracted.txt；audit7 读 config.gz 亦未见），lab 有 HW_BREAKPOINT 也不解决 |
| **U-B** 同会话 VA/PA 判别（D6 迁移跟随） | **T-05 + TOP-2** | **已覆盖** | 必须同会话 + 页级/偏移级归因（C-182）；每档 ≥10 命中（功效门槛）；跨会话即 INVALID |
| **U-C** 用户态 ptrace=117 型跨进程写 | **T-23 + TOP-3** | **已覆盖** | 审计规则扩 117（限频 + per-task 过滤）+ 自建 ptrace 写者正对照；**结论一律「有界」**（只覆盖审计覆盖集） |
| U-D 热态 + 其余 DMA map 变体 | **T-24（= T-11b）** | **已覆盖（第二梯队五）** | dmahook 扩 dma_direct_map_page / ops->map_page + 热态窗；覆盖率缺口逐条列（0 调用 = 未行使，非无命中） |
| U-E 环池成员 D5（含 DD=1 正对照） | **T-12（dump_dma/ring 只读通道）+ 第二梯队四（T-18b 三事件同页）** | **降级（替代，非同一实验）** | 见 §5.3：D5 卡在「描述符 liveness 正对照从未构造」（C-169）与「dump_dma 是缓存快照」（C-185）；T-18b 改问**页生命周期**，替代**有界** |
| U-F 原子上下文失败写 / 内联 stput,__put_user | **T-09（fxhook）+ T-10（边界②）** | **已覆盖（可执行性=待写模块）** | fxhook 未实现；风险同 F-11 ⇒ 必须离线自检 + 安装回读门禁 |
| U-G 393 用户写站点 / 169 厂商 .ko 无符号 | — | **未纳入** | 判决对象=站点级普查完备性；需 DWARF/BTF 或大规模反汇编 + F-06 窗口枚举复核；≥3 人日、上限 E2，且**不解决「谁写」**；优先级低于 U-A/U-B/U-C |
| U-H SRAM / MMIO 目标面 | **T-13-lab（/dev/mem 读 MMIO）；厂商侧需 ioremap 模块** | **部分覆盖** | lab STRICT_DEVMEM=n 可直接读（唯一现成路径）；厂商侧需新模块（dpreg/dphook 经验），列第二梯队之后 |
| U-I 目标页资格共线（lab 零结果成因） | **T-17（page_owner）+ T-18（标记）+ T-19（养熟）** | **已覆盖（仅 lab + 前置链）** | 前置链：**WiFi 点亮（F-2/F-3）→ 客户端流量 → 页池养熟 → 环境清单**；缺一即如实写「共线未消除」，不得改用厂商侧零结果外推 |
| U-J H7（按进程缓存「最近 va_list」VA）直接判决 | — | **未纳入（待设计）** | 判决对象=「按进程缓存的 VA」；无现成仪器/判据，设计成本未知；**若 U-B 判 VA，H7 升为必做**（优先级跳升） |
| U-K H6 vs H7 分离（多会话重跑 C-191） | — | **未纳入（属排期，非新手段）** | 判决对象=单会话 vs 跨 boot 差异；器材与判据全现成（scanary 忙等/睡眠臂），属既有手段重复；上限 E2、优先级低 |

### 5.2 Lead 指定清单逐行（6 未执行 + 2 最便宜缺口 + 4 结构性不可达）

| 指定条目 | 我的 T-id / TOP-id | 状态 | 理由 / 替代路径 |
|---|---|---|---|
| D5 环池成员 | 第二梯队四（T-18b）+ T-12 | **降级（可行化替代）** | 见 §5.3；D5 原文需要 DD=1 活体正对照，而 DD=1 从未被观测（C-169）、dump_dma 是缓存快照（C-185） |
| D6 迁移跟随 | **T-05 + TOP-2** | **已覆盖** | 同会话 + 页级归因；E3 目标 |
| D7 patrace 同 VA 跨时刻 PA 可变性正对照 | **T-20** | **已覆盖** | T-20 已含「映射事实 + 噪声对照」；执行须按 10_MP §12.1 bring-up（patrace 是**写语义**接口） |
| D13 S 臂（SIGSTOP 冻结 + /dev/mem 直读 8 页栈） | **第二梯队七（搭 T-21/T-12 会话做 rider）** | **已覆盖（并入第二梯队）** | 机制 = T-20 的 /dev/mem 直读 + 冻结语义；判决对象=写入者是否需要目标运行态；成本 0.25 人日 |
| D16 process_madvise(MADV_DONTNEED) | **T-05 的外部驱动变体** | **已覆盖** | 见 §5.4；额外前置=合格靶子（有活性非 ptrace 槽，≥5 次内容变化/10 min，C-177） |
| D1-D2（同会话 A/B/A；UDP vs SSH） | **未纳入 + 替代=T-22 + S-1** | **未纳入（理由）** | 它们是**写入者路径归因**的排期实验（LAN-only ×71 停在 E1），不是「新观测手段」；设计要点已由 S-1（同会话/功效）+ T-22（构成对账）覆盖；若纳入应作为 T-22 的实施臂，优先级中 |
| **ptrace=117 覆盖**（最便宜缺口） | **T-23 + TOP-3** | **已覆盖** | 0.5 人日；结论必须有界 |
| **热态 dmahook**（最便宜缺口） | **T-24** | **已覆盖（第二梯队五）** | 0.5 人日 + 1 热态窗；dmahook 现成件扩变体 |
| D17 userfaultfd 点名 | **T-06（lab）** | **降级：厂商侧永久关闭 / lab 侧可用** | 厂商 CONFIG_USERFAULTFD=n 是**编译期**决定（C-179 E3）⇒ 厂商路径**永久关闭**（除非重编内核）；lab 有 USERFAULTFD=y ⇒ T-06 在 lab 可跑（非全局关闭） |
| D15 pte_redirect | **T-04** | **降级：可复活但须重写（不建议优先）** | 事故=C-174（模块自有页插入用户 PTE ⇒ 双所有权 ⇒ bad page ⇒ panic_on_taint）；**非永久关闭**，但复活成本高、优先级低（U-A 的 RO-PTE 路线更安全） |
| D8-uprot（全用户态停摆） | **T-02 / T-08** | **降级：原实现对当时靶子关闭；受限靶子下可复活** | 见 §5.5（与审计脚注口径一致） |
| rovictim2b（BLOCKED） | **T-02** | **降级：可复活（条件明确）** | BLOCKED 的直接原因=**从未出现活动槽**（C-176）＋ n=4 功效不足（≤52.7% 上界）；复活条件=合格自然活跃槽（非 ptrace 靶子）+ n≥20 |

### 5.3 D5 与「页来源三事件同页」的关系（Lead 指定必写）

- **D5 问的是静态池成员**：受害页 PA 是否出现在 RX 环/池里；其硬前置是**先构造 DD=1 活体描述符正对照**（从未成功，C-169），且现成的 dump 通道（/proc/mtkfe/dump_dma）是**缓存快照**（C-185）——这两点使 D5 在本代内不可执行。
- **「三事件同页」（第二梯队四 / T-18b）问的是页生命周期**：同一页是否在生产站点（RX 页分配）被 mark → 在消费站点（匿名页分配）被计到 → 随后出现在命中集合。
- 因此**不是同一实验**，而是**同一底层问题的可行化替代**：绕开「描述符 liveness」卡点，用分配器站点回答「这页曾是 RX 页」。
- **替代有界**：它**不能**回答 D5 的原始问法「那一刻环里是否武装着指向它的条目」；且它需要**自己的正对照**（一次已知 DMA 页穿过两个站点）。

### 5.4 D16 与 T-05 的关系（Lead 指定必写）

- 两者是**同一判别类**（页表重排后看记录落点还在不在），差别只在**驱动者**：T-05/D6 由 victim **自己** madvise；D16 由**外部 process_madvise** 驱动。
- 所以 D16 = T-05 的**外部驱动变体**，已被 T-05 覆盖；其额外前置：靶子必须是**有活性的非 ptrace 槽**（≥5 次内容变化/10 min；nerepair 槽只能作对照观测），并检查 madvise 返回值/读回全 0/PA 变化/进程存活（C-177）。

### 5.5 D8-uprot 口径对齐（与审计脚注一致）

- 审计把 D8-uprot 记为「结构性不可达（全用户态停摆）」，**那是针对当时的靶子与实现**，不是机制本身：
  1. **拿 ptrace supervisor（nerepair）当靶子** ⇒ mm 与 ptrace 竞争 ⇒ hang→watchdog 全用户态停摆（C-175/C-183）；
  2. **把外来页插进用户 PTE** ⇒ 双所有权 ⇒ bad page ⇒ panic_on_taint（C-174）。
- **在受限靶子下可复活为 U-A 路径**：vsurv4 作豁免受害进程、nerepair 走单 inode 豁免（nerepair.c:341-383），**只动权限位**（不插页、不改归属），并满足 C-182（同会话+页级归因）与 C-176（n≥20）。见 §2.2 T-08 与 §3 TOP-1。

### 5.6 /sys/module/*/sections 只读复核（对卡片的影响）

| 模块 | sections 目录 | .text / .data 可读性 | 结论 |
|---|---|---|---|
| mtk_wed | 存在（17 个条目，**均为点前缀隐藏文件**） | 可读：.text=0xffffffc00154a000，.data=0xffffffc00154d000（本 boot） | **可用** |
| mtk_warp | 存在 | 可读：.text=0xffffffc000ae5000（本 boot） | **可用** |
| mt_wifi | 存在 | 可读：.text=0xffffffc000da1000（本 boot） | **可用** |

- **先前「mtk_wed/sections 列出为空」是 ls 不显示点文件的**观测伪影**，不是模块缺 sections**；C-212 的引用**成立**（本条不构成待对账项，撤回我早前的「待复核」标注）。
- **对卡片的影响**：① **T-16**（模块仪器复用）：模块基址可经 /sys/module/<mod>/sections/{.text,.data} 直接读，**不必依赖 kallsyms**（mtk_wed 符号被 stripped）；tuphook 的 ops 寻址仍必须用 **ops-relative 偏移**（C-212：ops=base+0x3130，tx_fill=base+0xf8，rx_fill=base+0x374），**不得**用 sprint_symbol 名称门。② **T-13**（冻结快照）：可在冻结时把模块基址与 .text/.data 一并固化，便于把 PC 反查回模块内偏移。

---

## 附录 A：设备只读侦察审计（观测者污染留痕）

| # | 时刻（设备 UTC / 本地 +0800） | 内容 | 结果要点 |
|---|---|---|---|
| audit3 | 2026-11-03T12:10:41Z（20:10:41）uptime=8708 | cmdline / mount / debugfs 列表 / tracing / /proc 引擎节点 / interrupts / meminfo / buddyinfo / pagetypeinfo / /sys/module / kptr / /dev/mem / pstore | debugfs 已挂载（mtketh/ccmni/mtk_hwifi/dma_pools/lru_gen…）；无 tracing；有 hnat/mtkfe/warp_ctrl；IRQ 表含 mt7992-wed(18)、DPMAIF_AP(298)、MED_RX_IRQ(299)、CCIF_AP_DATA(294/295)、MD_WDT(296) |
| audit4 | 2026-11-03T12:10:55Z（20:10:55）uptime=8722 | 各 debugfs 子目录 ls / 模块 sections / /proc/hnat 与 /proc/mtkfe 列表 | hnat 有 20+ 只读节点（hnat_mib/hnat_entry/hnat_dma…）；mtkfe 有 dbg_dma/dump_dma/users；warp_ctrl 有 conf/tracer/warp1；mtk_wed/sections 当时显示为空 —— **已被 audit8/audit9 推翻：那是 ls 不列点文件的观测伪影，实际可用**（见 §5.6） |
| audit5 | 2026-11-03T12:11:30Z（20:11:30）uptime=8758 | pagemap / tracing / kprobe_events / perf sysctl / config.gz / iomem / kcore / uffd sysctl | **无 pagemap、无 tracing、无 kprobe_events、无 perf sysctl、无 kcore、无 uffd sysctl**；/proc/config.gz 在场（35,081 B） |
| audit6 | 2026-11-03T12:11:54Z（20:11:54）uptime=8782 | zcat 尝试 | 设备无 zcat（命令失败，如实记录） |
| audit7 | 2026-11-03T12:12:03Z（20:12:03）uptime=8791 | 用自建 busybox zcat 读 config 子集 | 仅打印含 = 的行：**BPF=y、RODATA_FULL_DEFAULT_ENABLED=y、MODULES=y、DEVMEM=y、DEBUG_FS=y、FTRACE=y**；**未见** PERF_EVENTS/KPROBES/USERFAULTFD/PAGE_OWNER/IOMMU_SUPPORT/HW_BREAKPOINT/KEXEC/ARM_PMU 的启用行（口径：未见 = 未启用或不存在，按「未启用」使用） |

| audit8 | 2026-11-03T12:16:10Z（20:16:10）uptime=9038 | 逐模块 sections 目录与文件（mtk_wed/mtk_warp/mt_wifi/mt7992/mtk_hwifi/mtk_pci），含不带 2>/dev/null 的错误回显 | 六个模块的 sections 目录**均存在**；mtk_wed/sections 为 17 个**点前缀隐藏文件** ⇒ 普通 ls 看不到（伪影根因）；mtk_wed/.text、/.data 与 mtk_warp、mt_wifi 的 sections 均可读 |
| audit9 | 2026-11-03T12:16:27Z（20:16:27）uptime=9054 | cat 模块 sections 基址 | mtk_wed .text=0xffffffc00154a000 / .data=0xffffffc00154d000；mtk_warp .text=0xffffffc000ae5000；mt_wifi .text=0xffffffc000da1000（本 boot） |

**边界声明**：全部 9 次访问（audit3–audit9，2026-11-03 20:10:41 → 20:16:27 +0800）均为**只读**（echo/uname/cat/ls/grep/head/zcat 到 stdout），无重定向、无 insmod、无 echo 到 /proc、无 dd、无 kill/reboot；单次快照、**未轮询**、合计 9 次且在 6 分钟窗口内完成（避开 armed 窗口的轮询高峰）；设备 uptime 连续（8708→9054），观察窗未受影响。

## 附录 B：历史事故与仪器状态索引（引用前先读）

| # | 事件/结论 | 出处 | 对本工具箱的约束 |
|---|---|---|---|
| A-1 | **rmmod mtk_wed 1/1 触发 Oops + 自动重启** | C-155；FIX §7.4 | 运行期卸载类杠杆禁用；只能「重启后不加载」 |
| A-2 | **pte_redirect 双所有权 ⇒ BUG: Bad page state ⇒ panic**（D15 INVALID） | C-174 | 绝不把模块自有页插进用户 PTE（T-04） |
| A-3 | **uwhook IABT 自伤**（两处 16-bit 块写错） | C-183 | 文本钩必须离线自检 + 安装后回读 |
| A-4 | **uprot ro on nerepair 栈页 ⇒ hang→watchdog 重启** | C-183；10_MP §12.4 | 靶子禁忌：不用 ptrace 监督者做 RO/PTE 实验 |
| A-5 | tuphook 四缺陷、两次真 oops（percpu 64 位 / tpidr_el2 VHE / proc_lseek / 位移方向） | F-11 | 模块必须过「离线自检 + 4 路反解 + 回读门禁」 |
| A-6 | uacatcher 两次崩溃（.text pool 不可写 / 符号地址与运行期不一致） | F-12 | 可写数据一律放 .data + 安装期回读 |
| A-7 | 热路径 O(n)/锁内扫描 ⇒ RCU stall panic；逐页加引用 ⇒ 抽干工作集 | AGENTS 陷阱表（dpquar/dpclamp 教训） | 冻结/标记类仪器必须 O(1)、预算有界 |
| A-8 | GFP_KERNEL 采样抓不到 MOVABLE 页（147K 采样 0 命中）；批量 MOVABLE ⇒ 25 min 冻结 + RCU-stall panic | AGENTS 陷阱表（dpclamp v1.0/v1.2） | 页级采样必须 GFP_HIGHUSER_MOVABLE + 退火 + __GFP_NORETRY + cond_resched |
| A-9 | dropwatch 阴性两义；需外部 fault 正对照 | C-181 | T-01 的前置三条件 |
| A-10 | 硬件观察点判不可用（PSTATE.D / 无 hw_breakpoint.o）；且**按线程装载** ⇒ 对「谁写」无判别力（U-A′） | kdev §7.1；Lead/skeptic 技术更正 | CPU vs 非 CPU 二分**不要用监视点**；用 **T-08（RO-PTE 哨兵 + 故障 PC 归因，受限靶子）** |
| A-11 | 槽身份四检；页级归因不算 | C-182；10_MP §12.6 | 任何 slot/页判读的前置（S-5） |
| A-12 | /proc/mtkfe/dump_dma 是**缓存快照**；环 liveness 控制失败 | C-185 | T-12 的 dump_dma 通道不得单独用于「环里有没有」 |
| A-13 | MD 保留区经 /dev/mem 不可读 ⇒ 那里的 0 是 INVALID | C-184 | 不可读区写 NA（10_MP §11） |
| A-14 | 扫描器自身污染：被扫值命中扫描器自己的栈页 | C-184 第 1 类 | 观测者排除（S-3） |
| A-15 | 两层验收 + 功效门槛 | C-178 | 写入活动与后果分开报；自然 NE 只做长期监视 |
| A-16 | 已排除三杠杆：流量 1366×、新栈页、环重置 | 10_MP §5 | 不要重复 |
| A-17 | D10 语义（注入长度）已 0/46，H4 未复活 | C-186 | 不要重复注入长度路线（T-21 注解） |
