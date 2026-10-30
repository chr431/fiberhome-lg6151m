# NE 崩溃调查 · 第六轮（2026-10-30 下半场）

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

本轮目标：把「写入者是谁」从猜测变成证据。手段 = 活体内核镜像逆向 + 运行时内核探针
+ 厂商二进制逆向（三个子代理并行）。

结论先行：**机制类别已经证实，具体函数还没抓到。** 但排除面已经收敛到很小的范围，
并且造出了能一次命中的仪器。

---

## 1. 活体内核镜像（本轮新增的基础设施）

`/proc/kallsyms` 未被裁剪（61689 行），内核无 KASLR。用 `kread.ko` 把两段一次性 dump 出来：

| 区间 | VA | 大小 |
|---|---|---|
| Kernel code | `0xffffffc008110000`..`0xffffffc008d30000` | 0xc20000 (12.7 MB) |
| Kernel data | `0xffffffc008ed0000`..`0xffffffc009250000` | 0x380000 (3.5 MB) |

`tmpfiles/an4/mkelf.py` 把它们和 kallsyms 合成 **`analysis/kern/vmlinux.elf`**
（ELF64 aarch64，47910 个带地址的符号，可被 Ghidra/REA/capstone 直接吃）。
`tmpfiles/an4/kdis.py` 是符号感知反汇编器（`python kdis.py <sym|0xADDR> [n]`）。

> 教训 31：厂商 `ktext.bin`（Oct-22 那份）与活体内核**不一致**，反汇编是垃圾。
> 任何内核静态结论都必须基于活体 dump。

## 2. 三个子代理的逆向结论（产物在 `analysis/reports/`）

### 2.1 用户态厂商守护（vendor_daemons.md）
- 10 个二进制里只有 4 个含 ioctl：`aee_aed`(8) `ccci_mdinit`(20) `ccci_fsd`(3) `ccci_rpcd_com`(2)。
- **全局唯一的 32 字节结构 ioctl** 是 `aee_aed` 的 `MTD_MEMGETINFO`（`_IOR('M',1,struct mtd_info_user)`），
  同步、每次全量重写，**不是指针滞留原语**。
- 决定性否定：**没有任何 `F_SETOWN/F_SETSIG/O_ASYNC`、没有 `aio_*`、没有 `prctl`**；
  也**没有任何守护把栈指针存进 .data/.bss**（全量扫描 0 命中）。
- 只有 `aee_aed` 会碰别的进程的地址空间（`aee_ioctl_get_reg`/`userthread_reg`/libunwind-ptrace/`/proc/%d/smaps`）。

### 2.2 内核镜像（kernel_image.md，592 个 user-copy 站点）
- **uaccess 模型**：本 SoC **没有硬件 PAN**（`/proc/cpuinfo` 的 Features 里没有 `pan`），
  内核走 `CONFIG_ARM64_SW_TTBR0_PAN`：`uaccess_ttbr0_enable.isra.0` 会
  `mrs x1, sp_el0; ldr x1, [x1, #8]; msr ttbr0_el1, x1`。
  因此**只有 `sttr*` 和 `copy_to_user` 家族能写用户内存**，普通 `str`/memcpy 到用户地址必 fault。
- 97 个 `_copy_to_user` 本地克隆 + `__arch_copy_to_user`，共 592 个调用点；
  8 个 `.constprop.0` 把 n 烧死（0x90/4/8/8/bc/bc/bc/38），**没有 32**。
- **n==0x20 的站点共 17 个**：rt_sigaction、times、mq_getsetattr、ustat、ext4_ioctl、aed_ioctl、
  msgctl×2、wext_handle_ioctl×2、do_fcntl、do_ipv6_getsockopt、do_vfs_ioctl、put_itimerval、
  snd_timer_user_read、uart_ioctl×2。
- 540 个 `sttr` → 372 个 run，长度 1..270，**没有 32 字节 run**。
- CCCI/dpmaif/aee 的 dump 家族（`ccci_dump_write`/`ccci_util_mem_dump`/`dpmaif_dump_register`/
  `aee_dump_stack_top_binary`）**完全不做用户拷贝**；`aee_dump_ccci_debug_info` 是死桩
  （`mov w0,#-1; ret`）。`aed_ioctl` 的 32 字节写目标是调用者自己的 ioctl 参数。
- 全局扫描：**没有任何全局变量/长生命周期结构缓存 `void __user *`**。

### 2.3 内核模块（vendor_modules.md）
- 六个模块里**唯一的 32 字节 user copy** 在 `hw_nat.ko`（cmd 0x9，同步 ioctl，同一指针进出）。
- `mt_wifi.ko`：313 个逻辑拷贝点，**全部**是 ioctl/wext/proc 同步上下文，目标都从当次 `iwreq` 重读；
  本 build 没有 fw-log/coredump/dbdc 的 proc 接口（fw log 走 UDP）。
  我独立复核：`mt_wifi.ko` 的 .text 共 951160 条指令，**sttr 数量 = 0**。
- `conninfra.ko` 是唯一「延迟推送」设计：`connsys_log_read_to_user(user_buf,len)` +
  `connlog_to_user_register(type,cb)` + IRQ 喂环形缓冲 + 排空线程做
  `__check_object_size` → `__arch_copy_to_user(user_buf+off, ring_seg, len)`。
  **拉下来的模块里没有任何一个 import `connsys_*`/`connlog_*`——消费者模块没被拉下来。**

## 3. 本轮最重要的发现：借用 mm 的 uaccess 是真实存在的

因为 SW TTBR0 PAN，内核态 uaccess 会把 TTBR0 设成 `current_thread_info()->ttbr0`。
对**内核线程/工作队列**来说那不是 `current->mm`（为 NULL），而是**该 CPU 上最后一个用户任务的
`active_mm`**。所以一个 kworker 完全可以把数据写进**任意一个进程**的地址空间。

我写了 `tmpfiles/an4/ktu.c`（`ktu.ko`）做正对照，实测：

```
ktu: [workqueue] comm=kworker/3:11 mm=0000000000000000 active_mm=ffffff802d849a40 ti_ttbr0=0xfe526000
ktu: [workqueue] copy_to_user(0x7ffffff000, 32) -> 0  (0 = SUCCESS)
ktu: [kthread] comm=ktu_kthread mm=0000000000000000 active_mm=ffffff802d848b40 ti_ttbr0=0xfe526000
ktu: [kthread] copy_to_user(0x7ffffff000, 32) -> 0  (0 = SUCCESS)
```

**没有 mm 的内核线程，32 字节 `copy_to_user` 成功落进用户地址空间。** 这解释了我们此前
所有"诡异"特征：受害者没有任何系统调用、stime=0、不 fault、写入却出现在它的页表里。

> 教训 32：以前测"内核线程有没有 mm"测的是 `current->mm`，那是错的。
> 对 uaccess 有意义的是 `current_thread_info()->ttbr0` / `active_mm`。

## 4. 运行时探针（本轮造出来的仪器）

`tmpfiles/an4/cth.c` → `cth.ko`：用自带的 TTBR1 页表遍历器把内核 text 临时改成可写，
在函数入口打 `b` 跳到模块内的 trampoline，采集参数后原样恢复寄存器再跳回。

已实现并可用的三个探针：

| 探针 | 打点 | 采集 |
|---|---|---|
| ac2u | `__arch_copy_to_user+0` | to / from / n / lr / comm / pid / cpu / mm / active_mm / in_interrupt |
| c2u | `_copy_to_user+8` | 同上 |
| pf | `do_page_fault+4` | far / esr / 出错指令 pc / comm / 上下文 |

已验证：patch 字节读回一致（`48 83 57 16` = 记录的 b 指令）；`rmmod` 会恢复原指令
（**不恢复会立刻崩：pc=模块地址、level-3 translation fault**，已实测并修好）；
自测 `cself` 的 `getcwd` 被正确捕获（`n=0x6`，`lr=__arm64_sys_getcwd+0x1cc`）。

## 5. 本轮的决定性否定

用 `cth.ko` 在 115 起真实崩溃（`h3_*.bin` 与受害者日志里的 fault 地址
`0x2dbb9 / 0x18cb6 / 0x229ff / 0xa8fec8de00000636 / 0x28416e00000640 …` 与既有记录完全同族）
的时间窗内测得：

| 实验 | 过滤 | 结果 |
|---|---|---|
| 全上下文 `copy_to_user` | `nfilter=32`，地址=整个用户空间，**无 comm 过滤** | **0 命中** |
| 仅内核/中断上下文 | `ctx_filter=1`（`mm==NULL` 或 `in_interrupt()`），n 不限，地址=整个用户空间 | **0 命中** |
| 仅内核线程 | `only_nomm=1`，`nfilter=32` | **0 命中** |
| 受害者自身 | `watch_comm=vsurv3`，地址=栈顶页，n 不限 | **0 命中**（受害者对自己的栈顶页根本没有 user copy） |

静态侧同样为空：内核镜像 0 个 32 字节 `sttr` run、0 个 32 字节 `put_user` 组；
`mt_wifi.ko` 0 个 `sttr`。

**⇒ 这次写入既不是 `copy_to_user`，也不是内核镜像里的 32 字节内联 `put_user`。**

## 6. 另一个硬事实：目标绑在「主线程的初始栈」上

做了 8 个 `vdeep`：`main()` 阻塞在 `read()`，`snprintf` 循环跑在 pthread 栈上（va_list 在 pthread 栈）。
3 分钟、同期 115 起崩溃，**这 8 个一次都没被打中**。

⇒ 写入目标不是"任意线程当前的 va_list"，而是**主线程 `start_stack-0xc0` 这一带**。
这解释了为什么 10 个 pfcanary core 的偏移恒为 −0xc0。

## 7. 现在的画像（诚实版）

已确证：
1. 32 字节记录写在主线程 `start_stack-0xc0`（= 活着的 `va_list`）。
2. 走受害者自己的用户页表；不是线性映射、不是 DMA。
3. 机制类别可用：无 mm 的内核上下文能写进借来的进程地址空间（正对照已跑通）。
4. 不是 `copy_to_user`（四种过滤、115 起崩溃、仪器字节级校验在位）。

未确证：**具体是哪条 `sttr`。**

剩下的唯一可能 = **某条内联 `sttr` uaccess 存储**，且位于**尚未拉下来分析的模块**里
（内核镜像与已分析的 6 个模块都已排除；设备上有 172 个 .ko）。

## 8. 下一步（明确的收口路径）

A. **拉全部 172 个 .ko，扫 32 字节 `sttr` 组**（脚本 `tmpfiles/an4/modsttr.py` 已就绪）。
   先用 4 字节编码过滤（`(w & 0x3FE00C00) == 0x38000C00`）把含 `sttr` 的模块挑出来，再反汇编。
B. 若命中模块 → 直接读函数，确认 32 字节结构。
C. 若仍为空 → 上 **540 站点 sttr 探针**（设计已定：每个站点 patch 成 `bl tramp`，
   tramp 用 per-CPU scratch 页重放原指令再跳回；表由 capstone 离线生成）。

## 9. 教训

- **教训 33**：`only_nomm` 这类过滤会漏掉 softirq/tasklet（那里 `current` 是被打断的用户任务，
  `mm != NULL`）。要用 `mm==NULL || in_interrupt()`。
- **教训 34**：改内核 text 的模块**必须在 exit 里恢复原指令**。否则 `rmmod` 后下一次调用
  就跳到已卸载的模块地址（本次实测：level-3 translation fault，整机重启）。
- **教训 35**：探针的 `lr` 对"经 `_copy_to_user` 克隆"的调用没有意义（lr 指向克隆内部），
  必须靠 `dump_stack()` 看真实调用链。
- **教训 36**：`struct pt_regs` 的 `pstate` 偏移是 **264**（regs[31]@0, sp@248, pc@256），
  写成 272 会把 `orig_x0` 当 pstate，user/kernel 判断整体反转。
