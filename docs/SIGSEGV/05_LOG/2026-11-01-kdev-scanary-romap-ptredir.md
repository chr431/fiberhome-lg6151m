# 2026-11-01 · kdev 仪器交付（scanary v1.2 / romap.ko / pte_redirect.ko）

> 角色：kdev（仪器作者，不上设备）。本文件记**做了什么、主机侧验证到什么程度、判据怎么预注册、还缺什么**。
> 设备侧读数由 lab 产出，本文件不含任何设备实测结论。

---

## 1 · 交付清单

| 产物 | 路径 | 尺寸 / md5 | 状态 |
|---|---|---|---|
| scanary 源码 | ~~tmpfiles/repro/scanary/scanary.c~~ | 962 行 | 主机编译零告警 |
| scanary 设备二进制 | ~~tmpfiles/repro/scanary/scanary~~ | 53,064 B / ~~269a2f529791d2cbc20290de0c8c262~~ | aarch64 static musl stripped |
| scanary 主机二进制 | ~~tmpfiles/repro/scanary/scanary_host~~ | —— | 用于自检/健康期 |
| 日志分析器 | ~~tmpfiles/repro/scanary/analyze_scanary.py~~ | —— | 命中率/页偏移/深度臂判决 |
| 执行协议 | ~~tmpfiles/repro/scanary/PROTOCOL.md~~ | —— | lab 可直接照抄 |
| romap 模块 | ~~tmpfiles/repro/kmod/romap.ko~~ | 194,648 B / ~~314974d64eef949a7796c0a751aaeff5~~ | vermagic 已核 |
| pte_redirect 模块 | ~~tmpfiles/repro/kmod/pte_redirect.ko~~ | 200,184 B / ~~e6fce6e3518438563af72b543d414e7d~~ | vermagic 已核 |
| 模块协议 | ~~tmpfiles/repro/kmod/PROTOCOL_ROMAP.md~~、~~PROTOCOL_PTEREDIR.md~~ | —— | 含判据/清理/最坏情况 |
| 模块构建链 | ~~tmpfiles/repro/kmod/build.sh~~ + ~~kfix/~~ + ~~../kincl/asm/bitsperlong.h~~ | —— | 复现 pf_manifest 链 |
| 内核导出符号检查器 | ~~tmpfiles/repro/kmod/ksymcheck.py~~ | —— | 读 __ksymtab（本 vmlinux 无该节，见 §6） |

---

## 2 · scanary：为什么它不是"又一个 canary"

现有 canary（vsurv4）只在记录落进 va_list 并致死时才留证据 → **选择效应**。
scanary 用独立线程每 5 ms 复扫 ①受害者自己的栈映射 ②一块 8 MB、永不作为栈的诱饵区，
按 32B 记录形状（R1）落盘，**崩不崩都记**。命中行直接带 ~~topva = top − VA~~ 与 ~~spva = sp_call − VA~~。

### 2.1 两个在实现过程中发现、会系统性制造假阴性的坑

**(A) 活帧低频内容扫描 = 必然假阴性。**
victim 全速时每秒重写同一批 vararg 槽 ~3×10⁶ 次；落进活帧的 32B 记录 **~1 µs 内被 victim 自己覆盖**，
5 ms 周期的扫描器看不到。这不是仪器坏了，是**采样率与目标寿命差 3 个数量级**。
→ 修法 ~~--hold-us 10000~~：victim 在自己的深帧里睡 10 ms（帧保持分配、va_list 地址不变），
覆盖率先降 4 个数量级；~~--hold-us 0~~ 保留历史全速体制用于复现崩溃。
→ **副产物推论（交 skeptic 记口径）**：真实写入率可能**远高于**崩溃率——绝大多数记录被 victim 自己抹掉，
只有极少数正好落在 va_list 上才致死。**"崩溃数"是写入数的下界，不是估计量。**

**(B) 同进程多栈：pthread 自供栈的 top ≠ startstack。**
analyst 判定写目标是 ~~startstack − K~~（K∈{0x5d0,0x3a0}）。scanary 的 pthread 栈是另一块 mmap，
top 完全不同 → 记录根本落不进被扫区域 → **假 0**。
→ 修法 ~~--victim main~~：victim 跑在主线程初始栈上，top == startstack，与 2552 份历史 dump 同构。
→ 反用：**main 有命中 + pthread 0 命中 ⇒ 写入者锚定 startstack**，这本身就是硬结论。

### 2.2 自检与正对照（主机实测，2026-11-01）

| 项 | 结果 |
|---|---|
| T1 诱饵区正注入 | 命中（SELFTEST_OK t1_decoy） |
| T2 栈安全区正注入 | 命中（SELFTEST_OK t2_stack） |
| T3 近似负注入 w1≠0 | **不命中**（特异性对照通过） |
| T4 历史热槽 top-0x390 | 冻结 victim 后命中；不冻结则 3/3 失败（=lab 现场观测到的竞态，已按 Lead 裁定降级为非硬判据） |
| 深度臂机制 | D=0/0x100/0x400/0x900/0x1000 → 实测 topminussp = 0x1190/0x1290/0x1590/0x1a90（pthread）、0x510/0x610/0x910/0xe10（main）：**位移 == D，精确** |
| 10 min 健康期 | **真命中 0 / 600 s**；12 条 HIT_APPEAR 全为 inj=1；9/9 活体探针命中；117,150 次 pass、平均 459 µs |
| 扫描成本 | 10 MB × stride16 ≈ 0.33–0.46 ms/pass → 5 ms 周期约 190 pass/s（约 1/4 核） |

> 检出下限的写法（判据纪律）：**0 / 600 s，检出下限 = 1 条记录/单次 pass（0.46 ms），
> 正对照 = 9 次活体探针 + 4 项启动自检全部命中。**

### 2.3 深度臂预注册判据（H1 vs H2）

- **H1（针对活 va_list 地址）** ⇔ 各 D 的中位 ~~topva~~ 随 D 单调增大且 ~~topva(0x1000)−topva(0)~~ ∈ [0.75,1.25]×0x1000，同时 ~~spva~~ 跨 D 极差 ≤ 0x40。
- **H2（固定栈顶相对偏移）** ⇔ ~~topva~~ 跨全部 D 极差 ≤ 0x40，且 ~~spva~~ 随 D 反向平移 ≈ D。
- **其它** ⇒ 新模型，立即上报。
- 功效门槛：每个 D ≥ 10 条 ~~inj=0~~ 命中才允许下判；不足 → underpowered（不得写成结论）。
- **诱饵区判据**：~~region=decoy~~ 出现任意 1 条 ~~inj=0~~ 命中 ⇒ H1/H2 都错，写入者打任意用户页。

---

## 3 · romap.ko（P1）：把直映射别名改成只读

- 机制：walk ~~init_mm~~ 页表到 PTE，清 PTE_WRITE / 置 PTE_RDONLY，~~flush_tlb_kernel_range~~，**回读校验**。
- 本内核 ~~CONFIG_RODATA_FULL_DEFAULT_ENABLED=y~~ → ~~can_set_direct_map()~~ 为真 → 线性映射按 4 KB 页建，
  单页可改、无需 split；若真遇到 2 MB 块，模块**拒绝并报 block=1**（不猜）。
- 主证据 = **PTE 回读**（MMU 走的就是这些位）；~~echo selftest~~ 在**模块自分配页**上跑同一操作（零风险）。
- 可选 ~~ro_selftest=1~~：模块自有 RO 页上做一次故意 store，预期 kernel fault、PC 落在 ~~romap_selftest_write~~。
  **默认关闭**；~~panic_on_oops=1~~ 时拒绝（除非 ~~ro_selftest=2~~ 强制），并在 /proc 与 dmesg 打印该值。
- 卸载：逐页恢复 RW 并打印 ~~unload restore pa=... rc=0~~；/proc 保留 ~~pte_before/pte_now~~ 供核对。
- 判决价值：**DMA 不看页表 → 照写；内核 CPU store → data abort + PC/LR = 身份（E4）**。

## 4 · pte_redirect.ko（P2）：三哨兵

- 受害页 PTE → 新页 Q（只替换 [47:12] 物理地址段，其余属性位原样保留），dmesg 打前后 pte 值。
- 哨兵：P（无人映射，只能经直映射读；任何改动 = 外部按 PA 写）、Q（VA 解析落点）、P0（P vs 快照 diff）。
- 检测：同一个 R1 形状规则 + "P 任意改动"粗哨兵（覆盖非完整记录）。
- 正对照 ~~echo poison / poisonq~~：模块自己往 P+0x100 / Q+0x200 写合成记录，扫描必须报 kind=1/kind=2。
- 复原：**先把 Q 内容拷回 P** 再恢复 PTE（保证受害进程栈内容一致）；mm 已死则跳过 PTE 写只释放页。
- 判据：Q 命中 → VA/PTE 解析；P 命中 → 裸 PA；两边都 0 → **INVALID，不是阴性**。

---

## 5 · 证据级别与可撤回条件（本文件自身结论）

| 结论 | 级别 | 可撤回条件 |
|---|---|---|
| scanary 的匹配器可用（含特异性） | **E3（主机）** | T1/T2/T3 任一在设备上失败 |
| 健康期 0 误报（主机 600 s） | **E2** | 设备上出现 inj=0 命中但内容明显是自身数据 |
| 深度臂 D 位移精确（机器已验） | **E3（主机）** | 设备上 EPOCH_END 的 topminussp 不随 D 变 |
| "活帧低频扫描必然假阴性" | **E2（推理+实测复现）** | 若设备上在 --hold-us 0 下仍能稳定看到活帧记录 |
| romap 的 RO 真的生效 | **E2（PTE 回读）** | 回读通过但内核 store 仍成功（NOFAULT）→ 机制失效 |
| pte_redirect 三哨兵链路可用 | **未验证** | 必须由 lab 跑 §2 poison 正对照后才成立 |

---

## 6 · 未决 / 交接

1. **设备侧读数全部待 lab**：scanary 自检（v1.2）、臂 A（--victim main）、romap 自检、pte_redirect §2 正对照。
2. **ksymcheck.py 在本 vmlinux 上不可用**：~~analysis/kern/vmlinux.elf~~ 只有 ~~.text/.data/.symtab~~ 六个节，
   **没有 __ksymtab**，无法判"是否 EXPORT_SYMBOL"。已改为对源码树 grep + 已知可用模块（patrace/rxring）的符号集。
   风险：某符号未导出 → insmod 报 ~~Unknown symbol~~（不崩设备，贴回来改实现即可）。
3. **构建链两处必要修补**（否则 zig cc 编不过 vendor 树）：
   - ~~kincl/asm/bitsperlong.h~~（vendor 树缺该头）；
   - ~~kmod/kfix/asm/stat.h~~（vendor 树 ~~asm/stat.h~~ 与 uapi 的 ~~struct stat64~~ 重定义）。
   这两条属构建链事实，不改内核源码。
4. **rxown.ko 未做**（Lead 已降级为 P3）：analyst 已否证"记录=RX 描述符"，rxown 只剩"环里是否持有受害页"这一个用途，而该问题 lab 用 patrace + dump_dma 就能答。
5. **scanary 未做的加强项**（按需再排）：多实例（每实例一块栈，扩大覆盖）、~~--churn-sec~~ 换页臂、命中时自动抓该页 32 B 之外前后各 256 B 上下文。

---

## 7 · 追加交付（同日 13:00 后）

| 产物 | 路径 | 尺寸 / md5 | 说明 |
|---|---|---|---|
| scanary v1.3 | ~~tmpfiles/repro/scanary/scanary~~ | 56,544 B / ~~2518a289a18a0856aae49a82005dc983~~ | 加 **CTX 上下文抓取**：命中时在写哨兵**之前**拷 32B 前后各 256 B（含 topva/spva/ep/D），默认上限 200 条（~~--ctx~~），超限只计数 |
| loopcanary | ~~tmpfiles/repro/loopcanary/loopcanary~~ | 33,672 B / ~~de40768b7afc90b973bcf7fd30f72038~~ | 因果阶梯五臂 A/B/C/D/E + ~~--spin/--seconds/--handler~~ |
| loopcanary 协议 | ~~tmpfiles/repro/loopcanary/PROTOCOL.md~~ | —— | 含速率对齐要求与预注册判据 |

### 7.1 硬件观察点（EL1-only DBGWCR/DBGWVR）可行性：**判不可用**

| 事实 | 证据 |
|---|---|
| 钩点存在 | ~~do_debug_exception~~ @ 0xffffffc008127124，size 264，入口 ~~d503233f a9bb7bfd 910003fd a9025bf5~~；首条是 **PACIASP**，故文本钩只能打 +4/+8 |
| KDE 不是障碍 | ~~enable_debug_monitors(DBG_ACTIVE_EL1)~~ 会置 ~~DBG_MDSCR_KDE~~（debug-monitors.c:91），符号在 kallsyms |
| **真正的障碍 = PSTATE.D** | arm64 上 D=1 屏蔽 debug 异常，内核正常执行期 D 恒为 1；而 vendor 树 **arch/arm64 下 local_dbg_enable/local_dbg_save 零调用**（CONFIG_HAVE_HW_BREAKPOINT 未设，Makefile:49 不编 hw_breakpoint.o）⇒ 本内核没有任何在 EL1 打开 D 的路径 |
| 结论 | 要收 EL1 观察点必须在整机内核态常开 D，等于把每次匹配的 store 都送进文本钩 handler，不可重入上下文一旦命中即不可恢复；**不做** |

**替代（同属 E4，风险低一个量级）**：RO 模式 —— 把受害页自己的用户 PTE 清 PTE_WRITE 并暂停 victim：
受害者不写（无风暴）；**内核态经该 VA 的 store 触发权限 fault，dmesg 打 PC/LR = 写入者**；DMA 不受影响。
与 romap（抓经直映射的 store）互补，两者 + pte_redirect 可把 H1/H2/H3/DMA 一次分开。

### 7.2 loopcanary：速率不平权会让整个因果阶梯失效

x86_64 实测（2 s）：A 1.81e6/s、B 4.12e7/s、C 1.28e4/s、D 3.26e6/s、E 2.66e7/s —— **最大差 3200 倍**。
直接比"死亡数/分钟"是错的。已加 ~~--spin N~~ + EXIT 打印 ~~rate_per_s~~，协议规定以最慢臂为锚、其余臂压到 ±20%，未对齐的一轮作废。

### 7.3 口径补充（对 skeptic 的自曝）

scanary 的命中数是**下界**：形状规则只覆盖 R1，且被 victim 自己覆写掉的写入（活帧寿命 ~1 µs vs 扫描周期 5 ms）根本看不到。
**canary/scanary 的"命中率"都只是暴露率的下界，不是写入率。**

---

## 8 · 追加（H1 定案后的点名仪器）

**H1 已定**（scanary 深度臂：写目标随 va_list 走、D 精确平移、spva 恒 0x210）⇒ 写者按**用户 VA**解析。
点名路线收窄为 H2(uaccess) / H5(pin)，对应三个仪器：

| 仪器 | 路径 | 状态 |
|---|---|---|
| ~~uwhook.ko~~ | 钩 ~~__arch_copy_to_user~~ 入口，记录 dst∈[lo,hi) 的 {dst,len,**LR**,pid} | **已交付** 174,376 B / ~~8dcf095168ac0eabb3e4494e23faa6da~~ |
| ~~fxhook.ko~~ | 钩 ~~fixup_exception~~，抓"被 fixup 吞掉的 uaccess 缺页"的 PC | **待写**（下一步） |
| ~~rovictim~~ | mprotect(PROT_READ) 受害 va_list 页 + handler 恢复，制造可归因缺页 | **已交付** 25,864 B / ~~1cdd83f3d882eb827af4edf39145709e~~ |

### 8.1 uwhook 的钩子事实（vmlinux 核对，写入协议）

- ~~__arch_copy_to_user~~ @ 0xffffffc00843b680，入口指令字 **0x8b020005 = add x5,x0,x2，无 PAC 序言**（与 do_debug_exception 不同，后者首条是 paciasp）。
  → 可直接改写第 1 条指令；shim 里重放该指令后跳到 +4。
- 打补丁走 ~~aarch64_insn_patch_text~~（0xffffffc008122394，dphook.ko 同一路径已验证）。
- **安全阀**：site ≠ baked 0xffffffc00843b680、或入口字 ≠ 0x8b020005 ⇒ 拒绝装载，一个字节都不改。
- 热路径 O(1)：区间比较 → per-CPU 槽（preempt_disable）→ 返回；无 printk / 无锁 / 无睡眠。
- 卸载还原 + 回读校验，回读不等于原字 ⇒ 明确报错（内核文本处于被改状态）。

### 8.2 RO 臂的判据坑（skeptic 提出，已采纳并落到 rovictim 的实现里）

**只清 PTE_WRITE 而 VMA 仍 VM_WRITE ⇒ EL1 uaccess 写触发 do_wp_page（COW）→ 写成功到新页 → RO 陷阱不报 → 假阴性。**
修法：用 ~~mprotect(PROT_READ)~~ 同时清掉 VMA 的 VM_MAYWRITE，使写成为真正的 permission fault。
**口径**：RO 臂只能抓"内核经该 VA 的 store（PF 带 PC/LR，E4）"，**抓不到**"走 COW 被内核悄悄满足的 uaccess"。

### 8.3 本日仪器清单（主机可复核）

~~tmpfiles/repro/scanary/~~（v1.3）、~~tmpfiles/repro/loopcanary/~~、~~tmpfiles/repro/rovictim/~~、
~~tmpfiles/repro/kmod/~~（romap / pte_redirect / uwhook / build.sh / kfix / ksymcheck）。
每个仪器都带：预注册判据、正对照、失败退化、卸载恢复、最坏情况（重启无残留）。
---

## 9 · pte_redirect 两次事故（C-174 / D15）· 仪器作废

| # | 现象 | 根因 |
|---|---|---|
| 1 | `uwhook` insmod 后首个 copy_to_user 跳到 0xffffffffc008b684 → IABT → 重启 | shim 用 movz/movk 手拼返回地址，第 2 个 16 位块写错（0xc008 应为 0x0843） |
| 2 | pte_redirect 重定向后 `BUG: Bad page state pfn:acdcb` → `panic_on_taint` → 重启 | 用 `alloc_page(GFP_KERNEL)` 的内核页直接 `set_pte_at` 进用户 PTE：mm 从未按 anon 记账、无 rmap 条目 ⇒ 该 pfn **双重归属**，释放到 vmalloc 路径时被 check_free_page 抓 |

**关键数字**：pstore2 的 `pfn:acdcb` 与 lab 日志 `pte_after=0xe80000acdcbf43` 的页帧**完全一致** ⇒ 出事的是我们换上去的 Q 页，不是 victim 的页。

**样本计数**：2/2 次上机都导致非计划重启；本机 `panic_on_oops=1` **且** `panic_on_taint` 已设 ⇒ bad_page 只加 taint 就 panic。

### 结论
- **pte_redirect 作废**（D15 = INVALID，不记阴性）；代码与两次 pstore 原文保留为证据。
- 替代 `uprot.ko`（只改权限位：PTE 写位 + VMA VM_WRITE；**不分配、不换页、不碰 rmap、不动引用计数**）已构建，但**未上机**，等 Lead 裁决风险。
- 事故后我给所有文本钩子模块加的流程：**空模块先跑 → 机器码逐字 dump 核对跳转目标 → go/no-go → 失败自动回滚**。

### 吸取的判据教训（写给自己）
「模块能装载且没立刻崩」**不等于**「模块是对的」。pte_redirect 在 redirect/poison 阶段一切正常（chgP/chgQ 都看到了），
坏的是**页的生命周期**——它在几十秒后才以完全无关的栈（kworker/free_work）爆出来。
凡是要插入/替换页表项的仪器，必须自带「页账目断言」和「自有页自测」，否则不许上机。
### 9.1 代码级核账（Lead 要求：zero/rebase 是否释放页）

对 ~~pte_redirect.c~~ 全量 grep 所有释放原语，结果如下（可复跑）：

```
$ grep -nE "__free_pages|free_page|put_page|vfree|vmalloc|kfree" pte_redirect.c
236:  if (q) __free_pages(q, 0);        <- do_redirect 的分配失败回滚路径
237:  if (snap) __free_pages(snap, 0);  <- 同上
238:  if (qsnap) __free_pages(qsnap, 0);<- 同上
296:  if (R.Q) __free_pages(R.Q, 0);    <- do_stop / rmmod
297:  if (R.SNAP) __free_pages(R.SNAP, 0);
298:  if (R.QSNAP) __free_pages(R.QSNAP, 0);
329/332: kfree(b)                      <- /proc 读缓冲，无关
```

**zero 路径**只有两句（源码原文）：
```c
memset((void *)__va(R.pa_p) + off, 0, 32);   /* 旧页 P：走直映射 */
memset(page_address(R.Q) + off, 0, 32);      /* 新页 Q：memset     */
```
**rebase 路径**只有两句 ~~memcpy~~（把 P/Q 内容拷进快照并清计数）。

⇒ **两条路径都不释放任何页**。Lead 的「zero 很可能释放/替换页」这一判读**与代码不符**，需更正。

### 9.2 真正的机制（代码定位）

问题在 ~~do_redirect~~ 本身，不在 zero：

```c
q = alloc_page(GFP_KERNEL | __GFP_ZERO);          /* 内核页，refcount=1        */
memcpy(page_address(q), (void *)__va(pa), PAGE_SIZE);
np = __pte(attr | (qpa & ...));                   /* 保留属性，只换页帧        */
set_pte_at(mm, vpage, ptep, np);                  /* 塞进用户页表 —— 到此为止   */
```

缺的是 mm 侧的记账：**没有 ~~prep_new_page()~~、没有 ~~page_add_new_anon_rmap()~~、没有 anon 计数**。
于是该 pfn 处于「页表里有、mm 账上没有」的双重归属状态：mm 侧把这次映射当成一个它不认识的页，
我们的 ~~R.Q~~ 又把它当自己的页；任一侧先释放，另一侧就成了悬空引用，最终由分配器在**完全无关的上下文**（kworker/free_work）爆出来。

pstore 的 ~~pfn:acdcb~~ 与 lab 日志 ~~pte_after=0xe80000acdcbf43~~ 的页帧完全一致 ⇒ 出事的正是我们换上去的 Q 页。

### 9.3 结论（按 Lead 裁决）

- **pte_redirect 停用**，不再上机；代码与两次 pstore 原文保留为证据。
- 若要重写，必须走 ~~do_anonymous_page~~/页迁移那套完整记账（~~prep_new_page~~ + ~~page_add_new_anon_rmap~~ + mm counter），
  或在 **不做页替换** 的前提下只改权限位（~~uprot~~ 思路）——后者已构建但按裁决**暂不上**。
- 事故后强制流程：**空模块先跑 → 机器码逐字 dump → go/no-go → 失败自动回滚**；
  且凡插入/替换页表项的仪器必须自带「页账目断言」，否则不许上机。
