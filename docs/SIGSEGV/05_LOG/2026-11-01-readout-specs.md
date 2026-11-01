# 05_LOG · 2026-11-01 · 判读口径（mprotect / remap / pageflags / H2 点名清单）

> 交付对象：lab（执行）+ kdev（pageflags 能力）+ skeptic（记分卡）。
> 配套脚本：`_local/work/crash-root/static/page_records.py`（记录检出+差分）、`usercopy_sites.py`（调用点清单）。
> 记录形状与级别的定义见 [2026-11-01-static-identity.md](2026-11-01-static-identity.md)。

---

## 1. mprotect / remap 判读口径

### 1.1 三条会改变判决的机制事实（必须先进操作规程）

**(a) mprotect(PROT_READ) 为什么能挡 uaccess —— 且必须用它，不能用"只改 PTE"**
uaccess 写失败点不在 PTE 的可写位，而在缺页处理的 VMA 权限检查：
`access_error()` 里 `if (!(vma->vm_flags & VM_WRITE)) return 1;` ⇒ SIGSEGV ⇒ 定点修复 → `-EFAULT`，**不写**。
所以必须让 **VMA 失去 VM_WRITE**（`mprotect(PROT_READ)` 正好做到）。
⚠️ 反过来：如果只把 **PTE** 改成只读而 VMA 仍可写，写缺页会走 **COW**（`do_wp_page`）——uaccess 写**成功**，只是落到**新页**。
⇒ 那种做法会给出假阴性（"照样写进去了"），**不得使用**。

**(b) 把 B 停住（SIGSTOP）会削弱判别力 —— 这是本设计最大的混杂**
若写入者的目标是"**正在跑 printf 的那个任务的 va_list**"，那么停住的 B 根本不是候选目标，
`B_new = 0` 的原因是"**没有目标**"而不是"**被 RO 拦住**"。
⇒ mprotect 的最高级别只能是 **E2**，而且必须做**两臂**：
* 臂 α：B 在**刚命中之后立刻** SIGSTOP（B 的栈里残留热 va_list 槽，最可能仍被当作目标）；
* 臂 β：B 冷置 ≥10 min 后 SIGSTOP（对照，预期更负）。
两臂都 0 且 A 有活性 ⇒ 只写"**无证据显示对冻结页的写入**"，**不要**写成"H2 成立"。

**(c) 更干净的变体 = remap（PTE 重定向，VA 不变 / PA 变）**
没有"冻结目标"问题，且把两条路线一次分开：

| | H1/H3（PA 解析） | H2（VA 解析） |
|---|---|---|
| B 的栈页 remap 到新 PA 后 | 写入仍落到**旧 PA**（B 不再崩；旧 PA 上能读到**新记录**） | 写入跟着 **VA** 到新 PA（B 继续崩，命中点不变） |
| mprotect(RO) 后 | 照样写 | 写失败 |

⇒ **建议顺序：先 remap（判 PA/VA），再 mprotect（判 uaccess 与否）**。两者都要 A 臂作存活对照。

### 1.2 记录检出判据（脚本已实现并自测）

`page_records.py`：`stride = 8 和 16` 两遍扫描，命中条件是 32B 块内 **5 个零字** + 合法 len/ip：
```
w[p+4]=w[p+8]=w[p+0xc]=w[p+0x18]=w[p+0x1c]=0
0 < w[p+0x10] < 0x4000                      (len)
w[p+0x14] ∈ 已知本机地址集 ∪ {0}             (ip)
w[p] < 2^20 或 w[p]=0                        (A 或 B 型)
```
两型分开报告（**不可合并**）：
* **A 型**：`w[p] ≠ 0` ⇒ 记录起点就是 va_list 槽（写目标 = 活对象）
* **B 型**：`w[p] = 0` 且 `w[p+0x10] ≠ 0` ⇒ 记录起点在对象下方 16B
**去重**：候选地址相差 ≤16B 合并为 1（保留低地址）。
自测（`h4_2600_2` 的真实 8 页）：报出 **2 条**（A 型 ×2，A=89481/89489，len=1600，ip=1c28416e），与人工判读一致。

### 1.3 "新增"的定义 = **基线差分**，不是"存在"

记录会在栈里留存（冻结进程更不会自己改），所以"检出到记录"**不能**算写入发生。规程：
1. `S0`：B 停下 ≥30 s（栈静默）后、**开流量之前**取一次 8 页镜像；
2. `S0'`：再等 30 s、**零流量**再取一次 —— 要求 `diff(S0, S0') = 0`，否则**判装置无效**（自漂移）；
3. 开窗 T（≥10 min），期间 A 照跑；
4. `S1`：窗末、**恢复权限之前**取镜像；
5. `new` ⇔ 在 S1 的 p 处满足形状 **且** `S1[p..p+32] ≠ S0[p..p+32]`。
因为 B 被冻结，**任何差异必然是外部写入** ⇒ 这是本设计最硬的一点（E3 的强度来源）。
辅助口径：整幅镜像的"变化字节数"也是必报量（用来发现"整页被写"这种非 32B 事件）。

### 1.4 三档判决与统计口径

记 `A_new` = 同窗口内**存活对照 A**（未改权限、正常运行）的新增记录数；`B_new` = B 的新增数。
记 `λ̂_A = A_new / (T·n_A)` 为本次会话的写入活性速率（跨会话不可比，只用同窗口）。

| 档 | 判据（三条全满足才算） | 结论口径（照抄） |
|---|---|---|
| **H2 相容**（uaccess） | ① `A_new ≥ 3`（活性已证）② `B_new = 0` ③ T≥10 min 且 `λ̂_B·T ≥ 10`（把 B 的期望写入数按 A 的速率折算） | "**0 / ≥10 次期望观测**（检出下限 10，P(0\|H1) ≤ 4.5e-5）；存活对照 A_new = N" —— 还要注明 §1.1(b) 的冻结目标混杂 |
| **H1+H3 相容**（PA 解析） | `B_new ≥ 1`（**1 次即决**：冻结进程不可能自己写） | "**≥1 / N 快照**（B 冻结，记录只能是外部写入）⇒ 目的地址不依赖 VMA 权限 ⇒ PA/写穿透" |
| **无效** | 任一：`A_new = 0`；`S0≠S0'`；`B` 的 VMA 仍带 `w`（`/proc/<pid>/maps` 必查）；流量为零或比同会话基线低 >10×；窗口内另有 ptrace/扫描器 | "**无效窗口**：存活对照 A_new = 0 ⇒ 本窗口无写入者活性，不作为任何假设的证据（本窗口可检出的期望写入数 λ̂ = …）" |

**"0" 的写法（判据纪律）**：一律写成 `0 / N 次观测，检出下限 X`，并给正对照（A_new）。
没有 A_new ≥ 3 的 0 **不得进结论**。

### 1.5 混杂清单（逐条在报告里打勾）

| # | 混杂 | 处理 |
|---|---|---|
| C1 | 冻结目标（§1.1b） | 两臂 α/β；报告里必须写明"冻结可能使 B 不再是目标" |
| C2 | COW 假阴性（§1.1a） | 只用 mprotect 改 VMA；查 `/proc/<pid>/maps` 确认无 `w` |
| C3 | B 的页是**冷页** | 先要求 B 在窗口前 10 min 内有过命中（热页），否则负结果无意义 |
| C4 | 观测者污染 | 窗口内禁 nerepair/ptrace/patrace；A 的活跃度用来证明"设备在写" |
| C5 | 跨会话速率不可比 | 只做同窗口内 A/B 对照，报绝对数不报率 |
| C6 | B 恢复后自崩 | 顺序固定：**先恢复 PROT_READ\|WRITE → 再 SIGCONT**（Lead 已定，此处复述以防省略） |

### 1.6 lab 操作最小清单（照做即可）

```
1  B,C = 两个 vsurv4 canary；等 B 在最近 10 min 内至少 1 次命中（/data/repro/h4_<B>_*）
2  kill -STOP B ;  sleep 30
3  读 B 的栈 8 页（/dev/mem 按 patrace 给的 PA）→ S0 ; 等 30 s 再读 → S0' ; 断言 S0==S0'
4  mprotect(PROT_READ)  B 的栈 VMA（由 B 自己 fork 出的 helper 或 B 内的钩子做，需 B 可执行一个 syscall）
   —— 若做不到，改用 remap 变体（§1.1c）
5  查 /proc/B/maps 确认 [stack] 无 w   ← 不满足则中止（低风险分支）
6  开流量 T ≥ 600 s（LAN 灌流；记录设备侧 RX 包数）
7  读 B 的栈 8 页 → S1（此时仍 STOP）
8  恢复 mprotect(PROT_READ|WRITE) → kill -CONT B
9  page_records.py diff S0 S1 ; 统计 A_new（A 的 h4 增量）
10 按 §1.4 出三档结论 + §1.5 打勾
```

---

## 2. pageflags 五元组判读表（给 kdev 的能力 + 判读）

### 2.1 能力要求（最小）
给定一个 PA（patrace 已验证能给出），返回该页 `struct page` 的：
`_refcount`、`_mapcount`、`PageAnon`、`PageSlab`、`PageBuddy`、`PageCompound`、`PageSwapBacked`、`page_to_pfn` 反查校验。

**不要硬编码偏移**：在模块源码里用 `offsetof(struct page, _refcount)` / `offsetof(struct page, _mapcount)` /
`offsetof(struct page, flags)` 现算并 `pr_info` 打印一次（同时 `_Static_assert(sizeof(struct page)>=0x30)`），
本仓库无法保证与设备 `.config`（MEMCG/DEBUG_VM/SLAB_FREELIST）逐位一致。

### 2.2 判读表

记 `flags = page->flags`，`ref = atomic_read(&page->_refcount)`，`map = atomic_read(&page->_mapcount)`，
`extra = ref - map - 1`（**用原始 `_mapcount`，不要 +1**；对普通单映射匿名页 `ref=1, map=0 ⇒ extra=0`）。

| # | 条件 | 含义 | 对 W4（GUP pin）的判定 |
|---|---|---|---|
| P1 | `PageBuddy` | 页在 buddy 空闲链（未分配）⇒ 该 PA 已不是活页，patrace 拿到的是陈旧映射 | **本样本无效**（先修 PA 获取时序） |
| P2 | `PageSlab` | 页属于 slab ⇒ 与"canary 用户栈页"矛盾 | **本样本无效**（PA 错） |
| P3 | `!PageAnon` 且 `!PageSlab` 且 `!PageBuddy` | 可能是 page cache / 共享映射 / 驱动页 | 先查 `PageSwapBacked`/`page->mapping`，不要直接下结论 |
| P4 | `PageAnon` 且 `PageCompound` | 复合页（THP）⇒ `_mapcount` 语义按 head page | 用 `compound_head()` 的 `page_mapcount()` 重算 |
| P5 | `PageAnon` 且 `!PageCompound` 且 `extra == 0` | 普通匿名页，仅被页表引用 | **W4 否证**（该页无额外引用 ⇒ 无 GUP/pin） |
| P6 | `extra > 0` | 存在额外引用 | **W4 相容**（GUP/pin 候选）——但必须再排除：`PageSwapBacked`+swapcache、kcompact 迁移、`page_pool`/`netdev_alloc` 自持引用 |
| P7 | `extra < 0` | 计数异常（`_mapcount` 大于 ref） | **装置/判据错误**，报 bug，不解释为机制 |

### 2.3 与实验的配合（重要）
* **时机**：必须在**窗口进行中**读（A 正在跑、B 冻结时读 B 的页），窗口结束后页可能已变；
* **连续 3 次读数 × ≥3 个不同 canary**，且每个 canary 读 **2 个页**（命中页 + 相邻未命中页作阴性对照）；
* 判定写法：`命中页 extra = {0,0,0}（3/3）；对照页 extra = {0,0,0} ⇒ W4 在该页上否证（E2）`
  或 `命中页 extra = {1,1,1}；对照页 0 ⇒ 存在稳定额外引用（E2，指向 GUP/pin）`

---

## 3. 若 H2 成立：可疑调用点清单（vmlinux 全量扫描）

方法（`usercopy_sites.py`，已跑）：枚举 .text 里全部 `bl` 到用户写原语
（`_copy_to_user`/`__arch_copy_to_user`/`_copy_to_iter`/`skb_copy_datagram_iter`/`copy_page_to_iter`/`put_cmsg`/`__put_user_*`）
的站点 **685 个**，对每个站点回扫 ≤18 条指令，按 **x0（目的地址）的来源** 分类：
`FIELD`（`ldr x0,[xS,#off]`，**来自数据结构**，Lead 要的目标）/ `ARG`（`mov x0,x1..x7`，来自本次 syscall 参数）/
`PTR`（来自 callee-saved 寄存器，**多数其实是 syscall 参数被存到 x19/x20**，故列为低优先）/`CALL`（来自另一次调用）/`?`。

**已知偏差（必须写在报告里）**：`PTR` 类 393 个里绝大多数是"syscall 参数存进 callee-saved 寄存器"，
本启发式**无法**把它们与真正的数据派生区分 —— 所以 TIER 排序只信 `FIELD` 与"迭代器类"，不信 `PTR`。

### 3.1 TIER-1：目的地址**从结构里取**（6 个，全量、可穷举）

| 函数 | 原语 | 站点 | 目的地址来源 | 长度 | 备注 |
|---|---|---|---|---|---|
| `mtk_do_priv_ioctl` | `_copy_to_user` | 0xffffffc00859d26c | `ldr [x19,#0x10]` | 24 | **厂商 MTK**，ioctl 里从结构取用户指针 |
| `mtk_qdma_ioctl` | `_copy_to_user` | 0xffffffc00896ea70 | `ldr [x23,#0x10]` | 16 | **厂商 MTK QDMA**，同上 |
| `copy_msqid_to_user` | `_copy_to_user` | 0xffffffc00837e808 | `ldr [x19,#0x58]` | 120 | SysV msg，源头仍是 syscall 参数 |
| `__htab_map_lookup_and_delete_batch` | `_copy_to_user` | 0xffffffc0081fe9b8 | `ldr [x22,#8]` | 4 | eBPF htab batch |
| `pipe_to_user` | `copy_page_to_iter` | 0xffffffc0082b998c | `ldr [x0]` | REG | splice/pipe，**迭代器不是当前 syscall** |
| `sk_msg_recvmsg` | `copy_page_to_iter` | 0xffffffc008806fe8 | `ldp x0,x3,[sp,#0x68]` | REG | BPF sockmap |

**读法**：只有前两个是"厂商驱动在 ioctl 里用结构里的指针当目的地址"的形态；
但它们长度是 **24/16 < 32**，**与 32B 记录不直接匹配** ⇒ 只能解释"小于 32B 的写"，**不是候选写入者**，
除非它们的调用点被内联/循环成 ≥32B（需逐站点看反汇编，我可以随时补）。

### 3.2 TIER-2：迭代器类（目的地由 `iov_iter` 决定，可能**不是**本次 syscall 的）

`_copy_to_iter` 26 个站点 / `skb_copy_datagram_iter` 23 个 / `copy_page_to_iter` 6 个。
其中"**迭代器来自保存的上下文**"（而非 `msg->msg_iter`）才是 H2 的候选：
`pipe_to_user`（splice 到 pipe）、`sk_msg_recvmsg`（BPF sk_msg 队列）、`skb_splice_bits` 系。
**判据**：若命中确实来自这一类，则 `iov_iter` 里的 `ubuf` 必须是 victim 的栈 VA —— 打点直接看 `iter->ubuf`。

### 3.3 TIER-3：常量长度 ≥ 32 的 118 个站点（**只保留"能晚于 syscall 执行"的**）

绝大多数是"syscall 把结构拷回调用者"（stat/rusage/times/ioctl/statfs…），目的地 = 本次 syscall 参数 ⇒ **低优先**。
真正危险的是**可以晚于 syscall 执行**的：
* `do_notify_resume` → `copy_siginfo_to_user`（len 512/48）：信号投递期写；目的地由 `sp/altstack` 派生 ——
  **已被 §6 的"信号帧恒在 sp 以下"否证**（本样本目标在活 sp 以上 0x22b0）；
* `signalfd_copyinfo`(128)：signalfd 的 read() —— 目的地是本次 read 的缓冲（当前 syscall）；
* `aed_ioctl`(336/344/32/48)、`fsm_md_data_ioctl`(104)、`proc_generate_kernel_notify_read`/`proc_generate_wdt_read`：
  **厂商** proc/ioctl 路径，需逐个看是否有"缓存用户指针/延后拷贝"；
* `linereq_read_unlocked`(48)/`lineinfo_watch_read_unlocked`(288)：GPIO chardev 的 kfifo→user 拷贝（当前 read）。

### 3.5 TIER-1 逐站点复核（2026-11-01，含一处**自我更正**）

**更正**：`copy_msqid_to_user.constprop.0` 与 `__htab_map_lookup_and_delete_batch` 里，
前者是**假阳性**（我的回扫跨了函数边界：站点就在函数入口，`mov x2,#0x78; bl _copy_to_user`，dst = **x0 = syscall 参数**）；
后者 dst 来自 bpf attr 副本、len=4。**真 FIELD 站点 = 4 个**，逐条：

| 站点 | 关键指令 | 长度 | 能否 32B | 目的来源 |
|---|---|---|---|---|
| `mtk_do_priv_ioctl` 0x859d26c | `mov x2,#0x18; ldr x0,[x19,#0x10]; bl _copy_to_user` | 24 | **否**（无循环） | `ifreq.ifr_data`（+0x10） |
| `mtk_qdma_ioctl` 0x896ea70 | `mov x2,#0x10; ldr x0,[x23,#0x10]; bl _copy_to_user` | 16 | **否** | 同上 |
| `pipe_to_user` 0x82b998c | `ldr x3,[x19,#0x10]`(sd->u.userptr) `ldr w2,[x2,#8]`(sd->len) → `copy_page_to_iter` | runtime | **能** | **splice_desc 里的用户指针** |
| `sk_msg_recvmsg` 0x8806fe8 | sk_msg sg[] → page/offset/length + 当前 msg_iter | runtime | 能 | 当前 msg_iter（**非**结构） |

⇒ **静态穷举口径（带检出下限）**：`0 / 4 个真 FIELD 站点能产生"固定 ≥32B 且目的来自结构"的写`；
但启发式对 **393 个 PTR 类站点未解析** ⇒ 只能说"TIER-1 可穷举且都不匹配"，**不能说"没有候选"**。
**H2 排第一位的候选 = `pipe_to_user`**（唯一"目的来自结构 + runtime 长度 + 可跨 syscall"的形状）。

### 3.4 "点名"打点方案（每个候选站点可独立 A/B）

对 TIER-1/2/3 的任一站点，把 `bl <primitive>` 前面插一段（模块内联桩 / 指令替换到 trampoline）：
```
if (dst 落在 [victim_va-0x20, victim_va+0x20)) { 记录 (caller, dst, len, victim_pid); }
```
* **判据**：哪个站点被调用时 `dst == victim 的 va_list VA`（即 `startstack-0x390` 或 `-0x3a0`），**它就是写入者**；
* **功效**：canary 命中率 1.2~20/min（同会话），插桩开销 O(1) ⇒ 10 min 窗口内期望 12~200 次命中，
  命中那一瞬必然经过该站点 ⇒ 一次窗口就能点名（不需要统计功效）；
* **必须先做的正对照**：用 `rectest`（自己往 va_list 里注入记录）确认桩能命中自己；
* **停止规则**：若一个窗口内所有候选站点都没有 `dst ∈ 窗口` 的调用，则"H2 = 用户态目的地址"整体被否，
  应转向 `iov_iter->ubuf` / `kvec` / DMA（即 H1/H3）。

---

## 4. 一句话总结

* **先 remap（判 PA/VA，无冻结混杂）→ 再 mprotect（判 uaccess）→ 同时 pageflags 五元组（判 pin）**；
* 三档判决的 0 必须带 `检出下限 + 存活对照`；
* 若判 H2：**TIER-1 只有 6 个站点可穷举**，TIER-2 看 `iter->ubuf`，TIER-3 只查"能晚于 syscall"的那几个厂商路径，
  最后用 `bl` 打点 + "dst 是否等于 victim va_list VA" 在**一个窗口**内点名。