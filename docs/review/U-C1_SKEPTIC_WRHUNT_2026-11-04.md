# U-C1 · wrhunt.ko v1 装载前 skeptic 静态审查

> 日期：2026-11-04｜审查者：skeptic 帽
> 对象：`D:\Repo\lg6151m-project\tmpfiles\repro\kmod\wrhunt.c`（全文精读）＋
> `D:\Repo\lg6151m-project\tmpfiles\repro\kmod\wrhunt_v1.ko`（196,968 B / md5 `1f9ab135279e0b91bb3b4598a7d2b488`，本机复算一致）
> 内核：厂商 5.15.134 aarch64，`panic_on_oops=1` + `panic_on_taint=1`（任何缺陷＝非计划重启）
> 方法：源码精读 ＋ **.ko 字节级反汇编**（pyelftools 0.33 + capstone 5.0.7）＋
> `vmlinux.elf` 离线反汇编 ＋ `linux-5.15.134/` 源树交叉验证 ＋ 已验框架（fxhook v5 / tuphook / dmahook）对照
> 前置：`U-C1_PREREG_WRHUNT_2026-11-04.md`、`U-B1_FXHOOK_SKEPTIC_REVIEW.md`

---

## 0. 证据基线（本轮实际取得的硬证据，不依赖预注册的自述）

| 项 | 实测结果 |
|---|---|
| .ko md5 / size / 类型 | `1f9ab135279e0b91bb3b4598a7d2b488` / 196968 B / ET_REL EM_AARCH64，与清单一致 |
| 4 shim 位置与长度 | `wh_shim_1`@.text+0x1d0(72B)、`_2`@0x218(72B)、`_4`@0x260(76B)、`_5`@0x2ac(72B)；`wh_record`@0x0(464B) |
| 4 个 `wh_back_*` 符号 | `0x214 / 0x25c / 0x2a8 / 0x2f0`，**全部定义于 section 1（.text），非 UNDEF** |
| 帧 | 4 shim 均为 `stp x29,x30,[sp,#-96]!` … `ldp x29,x30,[sp],#96`（0x60=96，对称） |
| 4 条 `.inst <replay>` 实际机器码 | `a9b87bfd / a9bf7bfd / a9ba7bfd / a9be7bfd` |
| vmlinux 4 个 +4 原指令 | `a9b87bfd / a9bf7bfd / a9ba7bfd / a9be7bfd`（逐字一致） |
| 4 条 replay 解码 | `stp x29,x30,[sp,#-0x80]! / #-0x10]! / #-0x60]! / #-0x20]!` |
| `.rodata.cst32` 常量表 | hook_site 全 = `base+4`；hook_resume 全 = `base+8`（H1/H2/H4/H5 实测） |
| `b .` 占位 | 4 shim 末尾均 `0x14000000`，地址恰为 `wh_back_*` |
| UNDEF 符号 | 28 个；**无 resume/back 类数据符号**；`wh_record` 的 4 条 `R_AARCH64_CALL26` 全部指向 shndx=1 的已定义全局 |
| percpu 家族 | `g_calls/g_hits/g_ring/g_ridx/g_inhook` 全部 shndx=23（`.data..percpu`）；`g_ring` size 3072 = 32×96B |
| `wh_record` percpu 寻址 | `mrs x8,tpidr_el1` + `[x8,x9]`；g_ring 用 `__per_cpu_offset[cpu]`；与 fxhook v5 同构（v4 幻影已免疫） |
| `wh_record` x18 / 睡锁 | 反汇编无 x18 引用；`.config` 无 `CONFIG_SHADOW_CALL_STACK`；3 处 `BL` = strncmp / memcpy / copy_from_kernel_nofault，均非睡眠原语 |
| 3 个新增 UNDEF 可解析性 | `param_ops_string`/`seq_lseek`/`kmalloc_order` 在 5.15.134 源树均为 `EXPORT_SYMBOL`，导出字符串物理存在于 vmlinux.elf |
| 内核 VA 探针 | `0xffff800000000000`；`.config` 有 `CONFIG_ARM64_PAN=y` ⇒ 与 v3 教训一致 |
| 4 个 +0 | 全 `paciasp d503233f`；+8 分别 `mov x29,sp` / `mov x7,x0` / `mov x29,sp` / `mov x29,sp` |
| 关键调用路径（vmlinux.elf 全 .text BL 扫描） | H2 调用者 = `__access_remote_vm+0xa4`、`get_arg_page`、`access_process_vm_for_hang`；H3 `pin_user_pages_remote` 调用者 = `process_vm_rw_core.constprop.0+0x1dc`、`vaddr_get_pfns` |

---

## ① 判决行

**拒绝（v1 as-is 不予上机）。必改项 3 条（安全 1 / 有效性 2），修正并重建 + 修订预注册后可复审。**

理由（按严重度）：

1. **存在一个 latent 的 NULL 指针解引用 panic**：`.proc_lseek = seq_lseek` 配一个**没有 `.proc_open`** 的 proc 文件 ⇒ `file->private_data == NULL` ⇒ 任何一次 `lseek()` 都会在 `seq_lseek()` 的 `mutex_lock(&m->lock)` 处 oops ⇒ `panic_on_oops=1` 直接重启。预注册 §1.4 把这一行写成「tuphook 5.15 教训」的**修复**，但 tuphook 同时有 `single_open`（private_data 有效），wrhunt 只抄了一半 —— 属「反猜测方法论」违例。
2. **整轮在数学上保证 INVALID**：预注册 §2 P1 要求 `process_vm_writev` 命中 H2，但 5.15.134 的 `process_vm_writev → process_vm_rw_core → pin_user_pages_remote`（H3，**本轮禁用**）→ `__get_user_pages_remote`，**根本不经过 H2 `get_user_pages_remote`**。H2 在 vmlinux 里只有 3 个调用者，无一来自 process_vm 路径。⇒ P1 必然失败 ⇒ 按 §2/§3/§6.3「任一正对照失败 ⇒ 整轮 INVALID」。装载一个必然作废的仪器，还要占用 15 min 联合窗 + 一次 4 点文本补丁暴露，不可接受。
3. **对照锚被装置自身污染**：go/no-go 探针与 H1 的 `copy_from_kernel_nofault` 都会触发 `fixup_exception`（H5），使预注册 §7 的「H5 calls=0 对照锚」读成 ≥1；同时预注册 §1.3/§3 承诺的 `tr`/`lr`/`pc` 调用链在代码里恒为 0（`e->lr=0; e->pc=0;`，无 `stack_trace_save`）。预注册是「结果前写死」契约，装置与契约不符必须开窗前修订。

**代码本体评价**：4 shim 的寄存器 liveness / replay / resume / 递归守卫 / percpu / 卸载回滚，字节级全部通过；上轮 3 个真缺陷家族（v2 UNDEF 数据符号 / v3 PAN 探针 / v4 percpu 幻影）**已彻底免疫**。若上述 1 条安全项改为 `no_llseek`（或把「零 lseek」升级为硬门禁并纠正文档错觉），且 2 条有效性项在预注册层修好，本模块在安全上可复审为有条件放行。

---

## ② A–J 逐条结论

### A. 4 个 shim 的寄存器 liveness —— **通过（字节级，E3）**｜风险级：**低**

4 shim 反汇编逐条同构（以 wh_shim_1 为例，capstone 实读）：

```
+0x00  stp x29,x30,[sp,#-0x60]!      建帧（96B，16 对齐）
+0x04  mov x29,sp
+0x08  stp x0,x1,[sp,#0x10]           ┐
+0x0c  stp x2,x3,[sp,#0x20]           │ 保存 x0..x7
+0x10  stp x4,x5,[sp,#0x30]           │
+0x14  stp x6,x7,[sp,#0x40]           ┘
+0x18..0x24  装 wh_record 实参（hook,far,aux,src）
+0x28  bl wh_record                   （R_AARCH64_CALL26 → shndx=1 已定义全局）
+0x2c  ldp x6,x7,[sp,#0x40]           ┐
+0x30  ldp x4,x5,[sp,#0x30]           │ 恢复 x0..x7（顺序与保存对称）
+0x34  ldp x2,x3,[sp,#0x20]           │
+0x38  ldp x0,x1,[sp,#0x10]           ┘
+0x3c  ldp x29,x30,[sp],#0x60        撤帧，恢复 PAC 签名后的 x30
+0x40  .inst <replay>                 重放被替换的 +4 stp
+0x44  b .                            → init 回填为 b resume(+8)
```

- **保存/恢复 x0–x7 + x29/x30 对称**：4 shim 全部确认，无遗漏、无双重恢复。`bl wh_record` 前后 x0..x7 由 shim 自有帧恢复（**不依赖 wh_record 的返回值或 x9**），因此 wh_record 作为普通 ABI C 函数可自由 clobber x0–x18。
- **wh_shim_4 的 x9**：`mov x9,x0` 只在 `bl` **之前**用于把 orig-x0(far) 搬到 x1（同时 x2=orig-x1 esr）。`bl` 之后 shim 再也不读 x9；x9 是 AAPCS64 caller-saved temp，且 `wh_record+0x080 mrs x9,sp_el0` 确实会改写它 —— 无关紧要。
- **do_page_fault 是否读 x9**：对完整 840B 函数做 capstone 操作数级严格扫描（非字符串匹配），**x8/x9/x16/x17/x18 零引用**；+8..+0x40 实读的是 x0/x1/x2（`mov x24,x0`、`mov x22,x1`、`mov x19,x2`、`mrs x0,sp_el0`），全部由 shim 帧恢复。⇒ x9 被破坏无害。（源码注释「x9 … restored by the C ABI callee」措辞不准，但代码正确。）
- **replay 逐字一致**：实测 4 条 replay 机器码 = vmlinux 4 个 +4 原指令 = `.rodata.cst16` hook_word 表，三者完全相同。
- **resume 落点**：`.rodata.cst32` 实测 4 条 resume 全 = `base+8`，**没有跳过 `mov x29,sp`**。H2 的 +8 是 `mov x7,x0`、+0xc 才是 `mov x29,sp`，回填落在 +8 ⇒ 两条都执行，无跳过。B-target 反解自检（`gotimm` 符号扩展 + `back+(gotimm<<2)==resume`）与 fxhook v5 同构，且「同构建链 fxhook v5 已同设备实跑 GO/rmmod 全链通过」（给定事实 4）⇒ shim↔kernel 距离在 ±128MB 内已实测成立。
- **PAC**：补丁在 +4（`paciasp` 之后），shim 用普通 `stp/ldp` 保存恢复已签名 x30，期间无 `autiasp`/`ret` 校验点；replay 的 stp 用入口 SP 重建原帧，函数退出 `autiasp/ret` 时 SP 与签名时一致。与 U-B1 §B 同规则。

### B. wh_record 的上下文安全性 —— **通过（含跨 hook 递归）**｜风险级：**低**

`wh_record` 反汇编：标准 ABI 序言（`sub sp,#0x60`，保存 x19–x25,x30）；3 处 `BL` = `strncmp` / `memcpy(16)` / `copy_from_kernel_nofault(32)`。

- **原语合法性**：`mrs tpidr_el1`/`mrs sp_el0`、`__this_cpu_inc`（tpidr 相对）、`jiffies`（只读）、`current->comm`/`->pid`（`sp_el0+0x618` / `+0x458`，与 fxhook v5 实测偏移一致）、`memcpy 16B`、`strncmp(...,15)`、`copy_from_kernel_nofault`（`pagefault_disable()`+extable，不睡眠）。**无 GFP_KERNEL、无 mutex、无调度、无 O(n)**。
- **四种上下文**：
  - H1 `__access_remote_vm` / H2 `get_user_pages_remote`：进程上下文、可能持 `mmap_read_lock` —— 上述原语全部可睡眠锁内合法（且不睡眠）。
  - H4 `do_page_fault`：`el0/el1_abort → local_daif_inherit → do_mem_abort → do_page_fault`，DAIF mask、atomic —— 全部原语合法，`current` 经 `sp_el0` 有效。
  - H5 `fixup_exception`：`__do_kernel_fault → fixup_exception`（fault.c:367），EL1 abort、DAIF inherit —— 同 U-B1 §D 结论。
- **H1 的 `copy_from_kernel_nofault` 递归**：潜在链是 `wh_record(H1) → nofault 读内核 buf → EL1 数据异常 → do_page_fault(H4) / fixup_exception(H5) → wh_record`。实测守卫覆盖：`g_inhook=1` 在 `+0xc8` 设置，**早于** `+0x160` 的 nofault 调用；嵌套进入 H4/H5 时 `+0xbc ldr w9,[g_inhook]` → `+0xc0 cbnz w9, #0x1b8` 直接跳尾声返回（**只累加 g_calls，不占 ring、不置 g_hits**）。关键：`+0x1b8` 是 `g_inhook=0` 清除指令（`+0x1b4 str wzr`）**之后**的地址 ⇒ 被抑制的嵌套调用不会误清外层标志，外层在 `+0x1b4` 正常清零。⇒ 无环、无无限递归、无 ring 污染。守卫是单一 per-CPU 标志，**跨 hook 生效**。
- 注：`CONFIG_ARM64_SW_TTBR0_PAN=y` / `CONFIG_ARM64_PAN=y`，H1 读的是内核 buf（TTBR1 地址），nofault 的 extable 修复路径成立，与 go/no-go 探针同机制。

### C. p_victim 过滤的正确性 —— **通过（带注记）**｜风险级：**低**

- `module_param_string(victim, p_victim, 16, 0444)`：5.15 `param_set_copystring` 校验 `strlen(val)+1 > 16` ⇒ 最长 15 字符 + NUL；`p_victim[16]` 有界。
- `strncmp(current->comm, p_victim, 15)`：`comm` 是 `TASK_COMM_LEN=16` 且恒 NUL 终止；`victim=scanary_ro_v21`（14 字符 + NUL）在 n=15 内精确比较到 NUL ⇒ 仅当 comm 恰为该串时命中。`p_victim=""` ⇒ `p_victim[0]==0` 跳过过滤（代码 `+0x070 ldrb / +0x074 cbz → +0xb0`，实测一致）。
- **误排除风险**：写者是「跨进程写」的另一方，按预注册设定为内核线程或另一进程，comm 与 `scanary_ro_v21` 不同；且预注册 §3 判读表本身要求 `comm≠scanary_ro_v21` 才点名。⇒ 同名碰撞概率极低，且即便发生也与判据方向一致。
- 注记：过滤只比 comm、不比 pid（`e->pid` 有记录但不参与过滤）。若现场出现同名内核线程，会被一并排除 —— 属可接受的低危；更严可用 `victim_pid`，但需改码重建，不值得。
- **纪律注记**：`insmod` 必须显式传 `victim=scanary_ro_v21`。预注册 §5 step 3/5 的 insmod 示例未列该参数，默认 `""` 会把 victim 自身栈窗内的缺页全部记入 ring，可能触发 §6.2「观察窗 hit≠0 ⇒ 作废」。

### D. go/no-go 的覆盖缺口与卸载安全 —— **时序可接受，但前提被 P1 缺口击穿**｜风险级：**中**（见 J/必改项 2）

- **独立 go/no-go 只探 H5**：`wh_gonogo` 用 `copy_from_kernel_nofault(0xffff800000000000)`（内核 VA、PAN-safe）触发 `fixup_exception`，与 fxhook v5 同机制、同设备实跑通过。H1/H2/H4 无独立探针 —— 源码 §377-382 与预注册 §2 均如实声明。
- **「缺口」其实比看上去小**：
  - H4 `do_page_fault` 是**最热**的钩子，系统每一次用户缺页（`do_translation_fault → do_page_fault` 或 permission fault 直入）都会经过；H4 shim 若有 replay/resume/寄存器错，**insmod 后第一个缺页就 oops**，不可能静默活到正对照。⇒ H4 由「模块存活」自测。
  - H5 由 go/no-go 探针显式自测。
  - H1+H2 由 **P2（`/proc/<pid>/mem` pwrite）一次同时验证**：实测 `mem_write → mem_rw.isra.0 → access_remote_vm wrapper → __access_remote_vm(H1) → get_user_pages_remote(H2)`。
  - 4 shim 又已字节级全验（见 A）＋ B-target 反解自检 ⇒ 残留「回填错而 go/no-go 不发现」的概率极低。**时序本身可接受**。
- **但前提不成立**：P1（process_vm_writev）根本不命中 H2（也不命中 H1/H3），是**唯一指向 GUP 主通道的正对照**，必然失败 ⇒ 按预注册硬规则整轮 INVALID。详见 J/必改项 2。
- **卸载路径安全**：`wh_remove` 对 4 个 `g_patched[h]` 逐点 `apply_patch(site, g_saved[h])`（内含 `rc==0 && back==word` 校验）＋ 二次 `rd32` 日志。`wh_gonogo` 失败先 `wh_remove()` 再返回 `-EIO`；`hook_install_one` 任一失败也先 `wh_remove()` 再 `proc_remove` —— 顺序正确。`g_saved[h]=cur` 在补丁前保存。⇒ 正对照失败时 4 点已 patched 的状态可被完整回滚，**安全**。
- 残余：`wh_remove` 在 restore 失败时只 `pr_err` 且仍置 `g_patched[h]=0`（无断言/无重试）。4 点 ⇒ 4 份「留野跳转」机会；由预注册 §5.7 / §6.7「人工确认 dmesg 逐点 readback ok=1」兜底（见 §3.3）。另：`hook_install_one` 先 patch 模块内 `wh_back_h` 再 patch site，若 site patch 返回 -EIO 但字节已写入，`g_patched[h]=0` 会跳过恢复 —— 概率极低（同一 `aarch64_insn_patch_text` 刚写完的回读），列为残余风险。

### E. 多钩子叠加的递归 / 重入 —— **通过，且不会漏 H2**｜风险级：**低**

- 实测链：`process_vm_writev` 走 H3（禁用）；`/proc/pid/mem` 走 `H1(__access_remote_vm) → H2(get_user_pages_remote)`（vmlinux `__access_remote_vm+0xa4` BL 到 H2）；GUP 内部缺页可能再进 H4/H5。
- **关键：这条链是「顺序」而非「嵌套」**。每个 shim 的 `wh_record` 在**自己函数体内完整返回**（`+0x1b4` 清 `g_inhook`）之后，被钩函数的 body 才执行、才调用下一个钩子。⇒ 进入 H2 时 `g_inhook` 已被 H1 清零，**H2 不会被漏掉**；H4、H5 同理可各自独立记录。
- ⇒ `g_inhook` 不是「链上去重」器，而是「嵌套（fault-within-wh_record）抑制」器（见 B）。一次 P2 写可产生 H1+H2 两条（甚至 +H4）ring 记录 —— 预注册 §3 明确「任一 hook 命中即可点名」，多条记录**有益无害**（互为佐证），不构成判读污染。
- 唯一被抑制的是「`wh_record` 执行期间同 CPU 上发生的嵌套异常」，正是守卫设计目的。per-CPU 单标志、非原子 `str`，但被抑制路径不清零外层标志（已验），无损坏。

### F. proc_ops / 卸载 —— **不通过（必改项 1）**｜风险级：**高（latent panic）**

`.proc_lseek = seq_lseek` 已加，但 `wh_ops` **没有 `.proc_open`**，且 `wh_read/wh_write` 是自定义 `scnprintf` 实现（不是 `seq_read`）。

5.15.134 源树实测链：

- `fs/proc/inode.c:276 proc_reg_llseek()`：`if (pde_is_permanent(pde)) return pde->proc_ops->proc_lseek(...); else if (use_pde(pde)) rv = pde->proc_ops->proc_lseek(...);` —— **无条件调用，无 NULL fallback**。`wh_ops.proc_flags = 0`（非 permanent，两个分支都走到）。
- `fs/proc/inode.c:484 proc_reg_open()`：`open = pde->proc_ops->proc_open; if (open) rv = open(inode,file);` —— `wh_ops.proc_open == NULL` ⇒ 跳过 ⇒ `file->private_data` 保持 `alloc_empty_file()` 的 `kmem_cache_zalloc` 全零值 = **NULL**。
- `fs/seq_file.c:308 seq_lseek()`：`struct seq_file *m = file->private_data;`（=NULL）→ `mutex_lock(&m->lock)` ⇒ **NULL+offset 解引用 → oops → `panic_on_oops=1` 重启**。

对照：tuphook.c:1619/1623-1627 与 dmahook.c:1023/1045-1047 **同时**有 `.proc_open = single_open`（`fs/seq_file.c:67 file->private_data = p`），所以它们的 `seq_lseek` 安全。**wrhunt 只抄了 `seq_lseek`，没抄 `single_open`** —— 预注册 §1.4「proc_lseek = seq_lseek（tuphook 5.15 教训）」是错的：它把「必须非 NULL」的教训误当成「填 seq_lseek 即修好」，反而引入一个合法的、会 NULL-deref 的函数指针。

**可达性**：busybox `cat`（顺序 read）与 `echo >`（O_WRONLY write）都不 lseek；预注册 §5.6 已写「禁 dd/seek」。⇒ 协议内不触发，属 **latent**。但：① 任何一次 `dd`/`tail -f`/`head`/`xxd`/带 lseek 的 applet 触碰即 panic；② 文档谎称已修，会让操作者**放松** U-B1 §3.2 的禁 seek 纪律 —— 这是放大风险的关键；③ 设备 `panic_on_oops=1` + LK 救砖成本。**不接受 latent panic 上机。**

**修法（二选一，均需重建 → 新五元组）**：
- 首选：`.proc_lseek = no_llseek`（`fs/read_write.c:234 EXPORT_SYMBOL`，vmlinux 中确认存在；返回 `-ESPIPE`，不触碰 private_data）。**不能**改用 `seq_lseek`+`single_open`，因为 `wh_read` 不是 `seq_read`，加 `single_open` 会破坏读路径。
- 若不重建：把「/proc/wrhunt 仅 `cat` 读、`echo` 写；**禁止任何 lseek/dd/xxd/tail/head**」升级为硬门禁，并在预注册中**明确纠正**「已修」的表述为「未修，靠纪律规避」。此为降险兜底，非等价替代。

`wh_remove` 逐点恢复 + 回读：逻辑通过（见 D）；restore 失败仅打日志的残余风险列 §3.3。

### G. 与既有已加载模块的交互 —— **通过**｜风险级：**低**

- 4 个补丁点均在**核心内核 .text**（`0xffffffc00824d114 / ...7c68 / ...6be0 / ...6740`），非模块文本；163 个已加载模块的 load/unload 不会改写这些地址。
- `hook_install_one` 在补丁前 `cur = rd32(site,&ok); if (!ok || cur != hook_word[h]) → REFUSING`：若别的模块已把 +4 改成 B（或任何非预期字），入口字校验直接失败 ⇒ **全部回滚 + 装载失败，不 panic**。⇒ 给定「无其他文本钩在役」下，rd32 入口字校验足以发现「+4 已被 patch」。
- 残余：只校验 +4，未校验 +0 / +8。若第三方改的是 +0 或 +8（本设备无此情况），shim 会 replay +4 后跳到被改的 +8 —— 概率极低，列为低危注记。

### H. H2 的 7 参数 ABI —— **通过（严格超配）**｜风险级：**低**

- `get_user_pages_remote(mm=x0, start=x1, nr_pages=x2, gup_flags=w3, pages=x4, vmas=x5, locked=x6)` 共 7 参（x0..x6）。
- vmlinux 实测 +8..+0x30：`+0x08 mov x7,x0`（把 mm 暂存到 x7，x7 是 AAPCS64 temp）、`+0x0c mov x29,sp`、`+0x10 mov w0,w3`、`+0x14 bl is_valid_gup_flags`、`+0x20 mov x0,x7`、`+0x24 bl __get_user_pages_remote`。该窗口**显式读 x0/x3/x7，不显式读 x5/x6**；但 x1/x2/x4/x5/x6 作为 ABI 实参在 `+0x24` 原封不动转发给 `__get_user_pages_remote`，仍必须保值。
- shim 保存/恢复 **x0..x7 全部 8 个**（含 x6/x7），⇒ 无论 body 读哪些，7 个实参 + x7 temp 全部原样交付。比所需更严，无缺口。

### I. H5 与 U-B1 一致性 —— **不通过（必改项 3）**｜风险级：**中（判读污染，非 panic）**

- U-B1 的「calls=0」是**联合窗内** `fixup_exception` 零调用（ex_table 排除结论）。本模块把它当「对照锚」（预注册 §7）。
- **但装置自身会制造 H5 调用**：① `wh_gonogo` 的 `copy_from_kernel_nofault(0xffff800000000000)` 显式触发一次 `fixup_exception`（这正是探针能工作的原因）；② H1 的 `copy_from_kernel_nofault(w,src,32)` 在读坏内核 buf 时同样走 `fixup_exception`。⇒ insmod 成功后 `sum_calls(H5) ≥ 1`，且 H1 路径可能在窗内继续 +1。
- ⇒ 若按预注册 §7 读「H5 calls=0」，必然误判为「环境变了」。这不是设备环境变化，是**观测者污染**（AGENTS.md 判据纪律第 3 条）。
- **处理（预注册层，结果前修订）**：insmod 后、零实验观察窗前必须 `echo clear > /proc/wrhunt` 把 4 路 g_calls 归零；并在 §7 明确「H5 锚 = clear 之后的窗内调用数」，且声明 H1 的 nofault 读可能贡献 H5 调用（属装置噪声，不改变 U-B1 结论）。U-B1 结论本身**继续成立**，本轮不推翻 —— 但预注册必须写清基线，不得事后放宽。
- 关联缺口：预注册 §1.3 承诺 `tr=<内核栈回溯4帧>` / `lr` / `pc`，§3 的 H4 E4 判据写「tr = 调用链」；而 wrhunt.c:130 注释明确 `NO stack_trace_save`，:156 `e->lr=0; e->pc=0;`，UNDEF 表**无** `stack_trace_save`。⇒ H4「点名」实际只有 comm/pid/far/esr，**没有调用链**。属预注册与装置不符，须在开窗前修订判读表（把 E4 的「tr」降级为「comm/pid 点名 + esr」，或另建带 `stack_trace_save` 的构建）。

### J. 新缺陷 / 上轮 3 家族免疫复核 —— **3 家族彻底免疫；新发现 3 项**｜风险级：**见分级**

**上轮 3 真缺陷家族（逐一实测免疫）**：

| 家族 | 复核结论 | 依据 |
|---|---|---|
| v2 UNDEF 数据符号 | **免疫** | 28 个 UNDEF 中**无任何 resume/back 类数据符号**；`wh_back_1/2/4/5` 全是 shndx=1 的 `STB_GLOBAL` **已定义**符号；4 条 shim `BL` 全部 `R_AARCH64_CALL26 → wh_record`（shndx=1）；`back_addr[]` 引用经 `.rela.init.text` 的 section 相对重定位（shndx=1），无跨模块数据符号。shim 用 `b .` 占位 + init 算 B-target 回填 + 反解自检，与 tuphook/fxhook v5 同构。 |
| v3 PAN 探针 | **免疫** | `wh_gonogo` 探针 = 内核 VA `0xffff800000000000`；`.config` `CONFIG_ARM64_PAN=y`/`CONFIG_ARM64_SW_TTBR0_PAN=y` ⇒ 用户 VA 会被 PAN 挡在翻译前，内核 VA 通过；与 fxhook v5 同设备实跑的 GO/NO-GO 通过一致。 |
| v4 percpu 幻影 | **免疫** | `g_calls/g_hits/g_ring/g_ridx/g_inhook` **全部** shndx=23（`.data..percpu`）；`wh_record` 反汇编用 `mrs x8,tpidr_el1` + `[x8,x9]`（g_calls/g_inhook/g_ridx）与 `__per_cpu_offset[cpu]`（g_ring），`sum_calls/sum_hits` 用 `per_cpu(...)`；**无「普通 static 配 __this_cpu_*」**。v4 的写偏地址事故结构性排除。 |

补充：28 UNDEF 相对 fxhook v5 的 3 个新增（`param_ops_string`、`seq_lseek`、`kmalloc_order`）在 5.15.134 源树均为 `EXPORT_SYMBOL`（kernel/params.c:535、fs/seq_file.c:342、mm/slab_common.c:977），导出字符串物理存在于 vmlinux.elf；`param_ops_ulong/int` 同族。⇒ **无 insmod「Unknown symbol」风险**（v2 的另一半也免疫）。`vermagic="5.15.134 SMP mod_unload aarch64"`、`.plt/.init.plt` 补齐、手工 `.gnu.linkonce.this_module`（+0x138 init / +0x250 exit 重定位正确）与 fxhook v5 同链先例。

**新发现（本轮原创）**：

1. **[高·panic] F 项**：`.proc_lseek = seq_lseek` 配无 `.proc_open` ⇒ `private_data=NULL` ⇒ `seq_lseek` NULL-deref panic。预注册误标为「已修」。→ 必改项 1。
2. **[中·整轮 INVALID] P1 通道缺口**：预注册 §2 P1 期望 `process_vm_writev → H2`，但 5.15.134 实测 `process_vm_writev(→__arm64_sys_process_vm_writev→process_vm_rw→process_vm_rw_core.constprop.0+0x1dc) → pin_user_pages_remote`（**H3，§1.2 已禁用**）→ `__get_user_pages_remote`。`get_user_pages_remote`(H2) 在 vmlinux 全 .text BL 扫描中**只有 3 个调用者**：`__access_remote_vm+0xa4`、`get_arg_page`、`access_process_vm_for_hang` —— 无一来自 process_vm 路径。`pin_user_pages_remote` 与 H2 是**兄弟**（都直调 `__get_user_pages_remote`），不是调用关系。⇒ P1 的 `H2 +1` **结构上不可能**；FOLL_WRITE 在 GUP 的 `check_vma_flags` 阶段返回 -EFAULT（不产生缺页）⇒ 也不会命中 H4。⇒ P1 必然失败 ⇒ 按 §2/§3/§6.3 整轮 INVALID。更根本：U-C1_LOCAL_AUDIT 的 Top-1 候选（GUP 跨进程写）恰是 process_vm_writev，本轮 4 个已装钩子**对它零覆盖**，装置达不到「广覆盖点名」目标。→ 必改项 2。
3. **[中·判读污染] I 项**：H5 对照锚被 go/no-go 探针 + H1 nofault 读污染；且预注册承诺的 `tr`/`lr`/`pc` 调用链在代码中恒为 0 / 缺 `stack_trace_save`。→ 必改项 3。

**其他小瑕疵（均不 panic、不损坏数据，列 §3.3）**：`wh_read` 在 `len>16384` 时可能越界读 16KB 缓冲（cat 不触发）；`wh_write` 的 `kb[16]` 未 NUL 终止（`strncmp(...,5)` 语义仍正确）；`wh_read` 的 `n=(int)(*off+len)` 截断老问题（同 U-B1 §L.1）；`init` 尾部 `p_armed=1` 自动武装与预注册 §1.4「armed=0 直到 go/no-go」文字不符（同 U-B1 §H，靠观察窗 hit=0 硬判据兜底）。

---

## ③ 必改项 vs 可接受风险

### 3.1 必改项 · 安全（不改就可能 panic）—— **1 条**

| # | 项 | 后果 | 修法 |
|---|---|---|---|
| **S1** | `.proc_lseek = seq_lseek` 但无 `.proc_open` ⇒ `private_data=NULL` ⇒ `seq_lseek` 的 `mutex_lock(&m->lock)` NULL-deref | 任何 lseek ⇒ oops ⇒ `panic_on_oops=1` 非计划重启；且预注册 §1.4 误称「已修」会放松禁 seek 纪律 | **首选** `.proc_lseek = no_llseek`（重建）。**或**（不重建）把「仅 cat/echo、禁一切 lseek/dd/xxd/tail/head」升级为硬门禁并**在预注册中纠正「已修」表述**；此仅为降险兜底，非等价替代。 |

> 判定依据全部来自 5.15.134 源树（fs/proc/inode.c:276/484、fs/seq_file.c:308、fs/read_write.c:234）与 .ko 的 `.rela.rodata`（`R_AARCH64_ABS64 → seq_lseek`）+ `.rodata` 中 `wh_ops` 仅 3 个非空槽位。

### 3.2 必改项 · 有效性（不改则整轮 INVALID / 判读错）—— **2 条**

| # | 项 | 后果 | 修法 |
|---|---|---|---|
| **V1** | P1 正对照 `process_vm_writev` 走 H3（禁用），不命中 H2/H1/H4 | P1 必然失败 ⇒ 预注册 §2/§3/§6.3「整轮 INVALID」；且 Top-1 候选通道零覆盖 | 二选一，**结果前写定**：(a) 启用 H3' —— 预注册 §1.2 已指出 `pin_user_pages_remote +8 = a9bf7bfd` 可重放 stp，patch `+8`、resume `+0xc`（需离线核 +8..+0x30 并新增 shim，重建）；或 (b) 把 P1 换成能命中已装钩子的对照（例如用 `/proc/<pid>/mem` 写同时作为 H1+H2 正对照，另设一条 GUP-only 对照），并同步修订 §2/§3 判读表。**不得**保留当前 P1 期望值上机。 |
| **V2** | H5 对照锚污染 + 预注册承诺的 `tr`/`lr`/`pc` 在代码中不存在 | 「H5 calls=0 锚」读成 ≥1 ⇒ 误判「环境变了」；H4 E4「tr = 调用链」无数据支撑 ⇒ 预注册契约与装置不符 | 预注册 §5 增加「insmod 后立即 `echo clear > /proc/wrhunt` 归零 4 路 g_calls」；§7 把 H5 锚定义为「clear 之后窗内调用数」并声明 go/no-go 探针 + H1 nofault 读属装置噪声；§1.3/§3 把 `tr`/`lr`/`pc` 降级为「comm/pid + far/esr 点名」或另建带 `stack_trace_save` 的构建。**U-B1 结论继续成立，不推翻。** |

> V1/V2 均为**预注册/仪器层**修正（V1 若选 (a) 还需重建 .ko → 新五元组 → 重走离线复核链）。它们不造成 panic，但使本轮在数学上不可能产出有效 E4 判读，故与 S1 并列为「不予上机」的理由。

### 3.3 可接受风险（纪律兜底，不阻塞代码本体）

| 项 | 风险 | 兜底 |
|---|---|---|
| `wh_remove` restore 失败仅 `pr_err`、4 点各一份「留野跳转」 | 低（同 `aarch64_insn_patch_text` 已被 fxhook v5/tuphook 反复验证） | 预注册 §5.7/§6.7：rmmod 后人工确认 dmesg 4 行 `readback ... ok=1`；缺任一行 ⇒ incident + LK 救砖待命（不 rmmod 二次触发） |
| install 中途 site patch 半失败残留 B 且 `g_patched[h]=0` | 极低 | 同链先例；任何 install 失败/异常 ⇒ 不假设现场干净，评估后按 incident 走 |
| 自动武装 `p_armed=1`（init 尾部）与 §1.4 文字不符 | 低（同 U-B1 §H，已接受） | 零实验观察窗 `hit=0` 硬判据（§6.2）；**且 insmod 必须显式传 `victim=scanary_ro_v21`**，否则 victim 自身栈窗内缺页会记 ring 触发作废 |
| H4 是全局最热钩子，`wh_record` 每次用户缺页都跑 | 低（快路径 O(1)：prologue + percpu inc + `!p_armed` + 2 次窗比较 ≈ 30 条；窗内才 `strncmp(15)`；无锁无分配） | 与 fxhook v5 同构；无 `stack_trace_save`/无 O(n)；F-11 类结构性排除 |
| `wh_read` 在 `len>16384` 时可能越界读 16KB 缓冲（info-leak，非写） | 极低 | `cat` 用有界 read 且 `*off` 从 0 递增，实测全部落在缓冲内；禁 dd/大 len 工具 |
| `wh_write` 的 `kb[16]` 未 NUL 终止 | 极低 | `strncmp(kb,"clear",5)` 先比首字符即分叉；`kb[0]=='0'/'1'` 分支不依赖 NUL；无用户态泄漏、无 panic（同 fxhook v5） |
| `wh_read` 的 `n=(int)(*off+len)` 截断 + `*off=n` | 极低 | 同 U-B1 §L.1；ring 输出截断而非 crash |
| p_victim 仅比 comm 不比 pid；comm 碰撞误排除 | 低 | 写者按设定为另一进程/内核线程；与 §3 判据方向一致 |
| 只校验 +4 入口字，未校验 +0/+8 | 低 | 本设备无第三方文本钩；核心 .text 不受 163 模块 load/unload 影响 |
| H1 `copy_from_kernel_nofault` 读坏 buf 触发嵌套 H4/H5 | 低 | `g_inhook` 跨 hook 抑制已实测（B 项）；不占 ring、不误清标志 |
| v2/v3/v4 三家族 | **已免疫** | 见 J 表，字节级复核 |

---

## ④ 认可的装载时序

**当前 v1 as-is：不认可任何装载时序（拒绝）。** 下列时序仅在 §3.1 S1 与 §3.2 V1/V2 全部落实（且重建产物重新做离线入口字/五元组复核）后生效，作为复审通过后的执行序列：

```
0. 离线（结果前）：
   a. 修 S1：.proc_lseek = no_llseek（或把「零 lseek」写成硬门禁并纠正预注册表述）→ 重建
   b. 修 V1：选 H3'(patch pin_user_pages_remote +8 / resume +0xc，离线核 +8..+0x30 后新增第 5 shim)
             或改 P1 为可命中已装钩子的对照 → 同步改预注册 §2/§3 判读表
   c. 修 V2：预注册 §5 增「insmod 后 echo clear」，§7 重定义 H5 锚，§1.3/§3 去 tr/lr/pc 或声明降级
   d. 重算 .ko 五元组（FIVETUPLE.txt）；若新增/改动 shim，重跑本审查 A/H/I/J 的字节级核对；
      新 vmlinux 入口字（含 H3' 的 +8）离线逐字复核
1. deploy.py put → md5 双核 → chmod 644（.ko 不需 exec）；MSYS_NO_PATHCONV=1
2. 300 s RW λ 预检（取 stack/base/top；≥10/300s 才继续）
3. devop 持锁 insmod wrhunt.ko lo=... hi=... victim=scanary_ro_v21
   → 4 点（或 5 点）逐点 go/no-go；观察 dmesg：入口字符合、B-target 自检、GO/NO-GO ok
4. **echo clear > /proc/wrhunt**（归零 4 路 g_calls，建立 H5 干净锚）  ← V2 新增，不可省
5. 10 min 零实验观察窗：各路 hit=0（§6.2）；同时观察有无 oops/RCU-stall 迹象
   （H4 为全局热钩子，若装置存活即已自测 H4 shim 正确）
6. 正对照 P1–P4（按修订后的 P1；P2 `/proc/<pid>/mem` 一次验证 H1+H2；P3 → H5；P4 → armed=0）
   **任一失败 ⇒ 整轮 INVALID，先修仪器，不读联合窗**（§2/§6.3）
7. 联合窗 ≥900 s（victim 新进程 + 新栈窗 → 先取新 stack/base/top 再对齐；页漂移作废重来）
8. 窗末 **仅 cat /proc/wrhunt 全 ring**（禁 dd/seek/xxd/tail/head —— S1 未改码时此为硬门禁）
9. echo 0 > /proc/wrhunt → rmmod → **人工确认 dmesg 逐点 `restored ... readback ... ok=1`**
   （缺任一行 ⇒ incident，LK 救砖待命，不二次 rmmod）
10. NE 台账 / nerepair dry / 单实例前后对账
```

**全链硬门禁（沿用预注册 §6 并强化）**：任一入口 go/no-go 失败 / 入口字不符 / 补丁回读失败 / 观察窗 hit≠0 / 正对照任一失败 / 联合窗 scanner 命中 <10 / 页漂移 / 任何 oops 或 stall / rmmod readback 失败 ⇒ 立即停止；`panic_on_oops=1` 下不做「先看看再说」，LK 救砖链（`tools/lk_flash_v4.py`）待命。

---

> 审查范围声明：只读静态审查。未修改任何源码、未访问设备、未执行任何写操作（本报告文件除外）。
> 所有「实测」结论来自本机对 `wrhunt_v1.ko` / `vmlinux.elf` / `linux-5.15.134/` 的离线解析与反汇编，
> 以及任务给定的 6 条已核实外部事实与 fxhook v5 同设备实跑结论。

---

## ⑤ v2 复审（2026-11-04 晚，skeptic 二次帽）

> 对象：`wrhunt.c`（5 入口版，全文精读）＋ `wrhunt_v2.ko`（196,592 B / md5 `3c9b45138eca3000d55b3219131075f3`，
> 本机复算一致，与 `FIVETUPLE.txt` 的 v2 行一致）＋ 修订后
> `U-C1_PREREG_WRHUNT_2026-11-04.md`（§1.1/1.2/1.3/1.4/§2/§3/§5/§7）。
> 方法同 ④ 之前：pyelftools 0.33 + capstone 5.0.7 字节级反汇编；`vmlinux.elf`（.text VMA
> `0xffffffc008110000`，`sh_offset=0x1000`，与 `ktext.bin` **逐字节全等**，3104/3104 个 4K 块无差异）；
> `linux-5.15.134/` 源码交叉；全 .text 的 B/BL **原始编码**扫描（不依赖反汇编器 operand 语义）。

### 5.1 判决

**有条件放行。** 上机前须落实：**S2（1 条代码级计数标签错位——重建修正，或书面豁免并写进预注册）**
＋ **V3、V4（预注册两处契约空洞，各自只需改几句话）**。

- **设备安全面：通过。** S1 已实质修复且是「整类关闭」（见 5.2），H3 新增面 a–e 全部字节级通过（见 5.3）。
- **有效性面：通过。** V1 修复后 P1 结构可达（`process_vm_rw_core.constprop.0+0x1dc → pin_user_pages_remote`
  实测 BL 指向），V2 的锚/降级与代码一致。
- **不放行的剩余理由全部是「判读/执行契约」而非「会不会 panic」**：S2 会让 `rmmod` 那一行 dmesg
  把 H4 的计数打成 H5（`do_page_fault` 的调用数极大，足以让人误判 §7 的 H5 锚被击穿）；
  V3 照字面执行会让联合窗在 `armed=0` 下 hit 恒 0（而 calls 照增，正好假冒成「多路径阴性」）；V4 让 §3 与 §7 对同一个 `calls=0` 给出相反判决。

### 5.2 S1 / V1 / V2 逐项复核

#### S1（`.proc_lseek = seq_lseek` + 无 `.proc_open` ⇒ NULL-deref）—— **已修（整类关闭）**

| 证据 | 实测 |
|---|---|
| UNDEF 表 | 28 个；**`seq_lseek` 已消失**，**`no_llseek` 在列**（`param_ops_string` 同时在场，`module_param_string` 链完整） |
| `wh_ops.proc_lseek` 槽 | `wh_ops` 基址 `.rodata+0x30`（96 B）；`.rela.rodata+0x58`（= `wh_ops+0x28`）`R_AARCH64_ABS64 → no_llseek` |
| `wh_ops.proc_open` 槽 | `wh_ops+0x38` **无重定位** ⇒ 值为 0（NULL），与 v1 相同，但这次无害 |
| `no_llseek` 语义 | `linux-5.15.134/fs/read_write.c:230-234`：函数体只有 `return -ESPIPE;`，`EXPORT_SYMBOL` ⇒ **不触碰 `private_data`** |
| `proc_reg_llseek` | `fs/proc/inode.c:276` 起仍是无条件 `pde->proc_ops->proc_lseek(file,offset,whence)`（无 NULL 兜底）⇒ 现在落到一个合法的、不 deref 的默认实现 |

**额外做的整类排查（v1 只点了 lseek 一处，这里确认没有第二处同族陷阱）**：`proc_reg_read_iter`
（inode.c:290-303）同样**无条件**调用 `proc_ops->proc_read_iter`，是同一类 NULL-deref 形状；
但 `proc_create` 只在 `proc_ops->proc_read_iter != NULL` 时安装 `proc_iter_file_ops`
（inode.c:673-682），`wh_ops.proc_read_iter == NULL` ⇒ 实际装的是 `proc_reg_file_ops`（无 `.read_iter`），
`preadv/splice` 都到不了那条路径。其余槽 `pde_read/pde_write/pde_poll/pde_ioctl/pde_mmap/
pde_get_unmapped_area` **全部有 NULL 检查**。⇒ **S1 已修，且不是「补一处」，是整类封死。**

#### V1（P1 走 H3、v1 里 H3 被禁用 ⇒ P1 必败）—— **已修**

- 5 入口表与地址逐条实测（`.rodata` 静态表 + vmlinux 逐字）：
  `hook_site`@`.rodata+0xb8..0xdf` = `…d114 / …7c68 / …7ca8 / …6be0 / …6740`；
  `hook_resume`@`+0xe0` = `…d118 / …7c6c / …7cac / …6be4 / …6744`（H3 = **+0xc** ✓）；
  `hook_word`@`+0x108` = `a9b87bfd / a9bf7bfd / a9bf7bfd / a9ba7bfd / a9be7bfd`；
  `hook_name`@`+0x90` → `access_remote_vm / get_user_pages_remote / pin_user_pages_remote /
  do_page_fault / fixup_exception`（addend 43/60/82/7/27，与 `.rodata.str1.1` 实串逐一对应）。
- vmlinux 五个入口字：`d503233f / d503233f / **37100123** / d503233f / d503233f`；五个 site 字
  = 表值（逐字一致）；`H3` 的 `site-4` 是 `d503233f`（paciasp），`site` 是 `a9bf7bfd`。
- **P1 通道（本轮核心）**：全 .text 原始编码 B/BL 扫描，
  `pin_user_pages_remote 0xffffffc008247ca0` 的直接引用 **2 处**：
  `bl @0xffffffc00825c35c in process_vm_rw_core.constprop.0+0x1dc`、`bl @0xffffffc00864c180 in vaddr_get_pfns+0x64`。
  对照 `get_user_pages_remote` 仍是 3 处（`__access_remote_vm+0xa4`、`get_arg_page+0x48`、
  `access_process_vm_for_hang+0x64`）——**依旧无一来自 process_vm**，与 v1 结论一致 ⇒ v1 的 P1 确实不可能命中，
  v2 的 H3 则结构上必中。
- **一个容易被忽略的正确性细节（加分项）**：H3 的 `wh_record` 在 `+8` 取 `aux = x3`，而 `gup_flags |= FOLL_PIN`
  的 `orr w3,w3,#0x40000` 在 `+0xc` —— 即 **aux 保留调用方原始 flags，FOLL_WRITE(0x1) 不会被 FOLL_PIN 淹没**，
  正好满足 §2 P1 的 `aux&FOLL_WRITE` 判据。（FOLL_GET=0x04、FOLL_WRITE=0x01、FOLL_PIN=0x40000 已对
  `include/linux/mm.h:2855/2857/2874` 核实。）
- 顺带实测了 §1.1 的入参表，全部正确：`__access_remote_vm(mm,addr,buf,len,gup_flags)`（mm/memory.c:5171）、
  `do_page_fault(far,esr,regs)`（fault.c:522）、`fixup_exception(regs)`（extable.c:9）。

#### V2（H5 锚污染 + `tr/lr/pc` 不存在）—— **已修（一处引用残留）**

| 要求 | 状态 | 证据 |
|---|---|---|
| §5 增 `echo clear`（insmod 后） | **已加** | §5 step 4 |
| 正对照后二次清零 | **已加** | §5 step 7（v1 没有，这次做了） |
| `clear` 必须覆盖 5 路 | **代码实测通过** | `wh_write` 0xa60-0xaec：`cpumask_next` 循环内 `str xzr,[x9,#0]` + `stp xzr,xzr,[x9,#8]` + `stp xzr,xzr,[x9,#0x18]` ⇒ `g_calls[0..4]` 全清；`g_hits` 同构；`str wzr,[x9,x23]`（x23=percpu+0x2c）= `g_ridx` 归零 |
| §7 H5 锚 = clear 之后窗内调用数 + 声明探针噪声 | **已改** | §7 原文；与代码一致（go/no-go 在 `p_armed=0` 时只 `inc g_calls`、不占 ring；H1 的 nofault 读发生在 `g_inhook=1` 之后，嵌套 H4/H5 只计 calls） |
| §1.3/§3 把 `tr/lr/pc` 降级为 comm/pid+far+esr | **已改** | §1.3 明写「本装置不采集栈回溯」；§3 的 H4 行写「comm/pid + far + esr（本装置无栈回溯）」。代码侧：UNDEF 无 `stack_trace_save`；`wh_record` 唯一 3 个 `bl` = strncmp/memcpy/copy_from_kernel_nofault；`e->lr=e->pc=0` 是显式清零（0x138-0x14c 的 `movi v0.2d,#0` + 三次 `str q0` 覆盖 e+0x10/0x18/0x20/0x28） |

**残留（并入 5.6 V4）**：§7 写「step 4 `echo clear` 之后、联合窗内的 H5 调用数」，但联合窗的真实基线是
**step 7 的第二次 clear**（step 4 之后还要跑 P1–P4，P3 本身就会给 H5 +1）。数值上等价（两次 clear 都清零），
只是引用错了一步——但既然是「结果前写死的契约」，步号指错就有事后解释空间。

### 5.3 H3 新增面 a–e（逐条）

**a. `+0` 的 `tbnz` 分支是否被补丁破坏？—— 不破坏，且路径本身是自洽的。**

vmlinux 实读 `pin_user_pages_remote`（入口 `0xffffffc008247ca0`）：

```
+0x00  37100123  tbnz w3,#2, +0x24        ← FOLL_GET(0x04) ⇒ WARN 路径
+0x04  d503233f  paciasp
+0x08  a9bf7bfd  stp x29,x30,[sp,#-0x10]!  ← ★补丁点
+0x0c  320e0063  orr w3,w3,#0x40000       ← FOLL_PIN，resume
+0x10  910003fd  mov x29,sp
+0x14  97ffff5b  bl  __get_user_pages_remote
+0x18  a8c17bfd  ldp x29,x30,[sp],#0x10
+0x1c  d50323bf  autiasp
+0x20  d65f03c0  ret
+0x24  d4210000  brk  #0x800               ← tbnz 落点（WARN）
+0x28  928002a0  mov  x0,#-0x16           （-EINVAL）
+0x2c  d65f03c0  ret
```

- 关键事实：**`tbnz` 在 `+0`，在 `paciasp`（`+4`）之前**。命中 FOLL_GET 时它跳到 `+0x24`，
  **既不执行 `paciasp` 也不执行 `autiasp`**（`+0x24..+0x2c` 只有 brk / mov / ret）⇒ 该路径在
  「无签名、无认证」上是**平衡的**，不是「已 paciasp 却跳过 autiasp」的坏形状。
- 我们的补丁在 `+8`，而 `tbnz` 在 `+0` 就分叉了 ⇒ **FOLL_GET 路径根本不经过被补丁的那条指令**，
  与 v1 补丁在 `+4` 时同理（此时 `+4` 也不在路径上）。
- `brk #0x800` 是 WARN（bug_handler 后 `regs->pc += 4`），返回后落到 `+0x28 mov x0,#-EINVAL; ret`，
  与编译器布局完全自洽。⇒ **(a) 通过，无新风险。**
- 附带：正常 `process_vm_writev` 的 `gup_flags` 不含 FOLL_GET（0x04），必走 `+4→+8`。

**b. `+0xc = 320e0063` 是否读 callee-saved（w19 等）？—— 不读；即使读也安全。**

- capstone 实解：`320e0063` = **`orr w3, w3, #0x40000`**（只读 w3），不是 `mov w19,...`。
- 更一般地：shim 在 `bl` 前把 **x0–x7 全部**存进自有帧，`bl` 后逆序恢复，因此被补丁函数在 `+0xc` 之后
  读到的 x0–x7 与未打补丁时完全一致；x19–x28 由 `wh_record` 作为 AAPCS C 函数保证 —— 实测其序言
  `stp x30,x25 / stp x24,x23 / stp x22,x21 / stp x20,x19`、尾声对称恢复，**它用到的 callee-saved 全部保存**，
  且**完全不引用 x18**（config 无 `CONFIG_SHADOW_CALL_STACK`；`CONFIG_ARM64_PTR_AUTH=y` 只用 x30）。

**c. `wh_shim_3` 与 `wh_shim_2` 是否同构对称？—— 逐指令一致。**

两者均为 72 B：`stp x29,x30,[sp,#-96]!` → `mov x29,sp` → `stp x0,x1,[sp,#16]` / `stp x2,x3,[sp,#32]` /
`stp x4,x5,[sp,#48]` / `stp x6,x7,[sp,#64]` → `mov x2,x3`（aux=gup_flags，**先于**清零）→ `mov x3,#0`（src）
→ `mov x1,x1` → `mov x0,#2` → `bl wh_record` → `ldp x6,x7/[0x40]`、`ldp x4,x5/[0x30]`、`ldp x2,x3/[0x20]`、
`ldp x0,x1/[0x10]` → `ldp x29,x30,[sp],#96` → replay → `b .`。**保存/恢复完全对称，96 B 帧 16 对齐。**

**d. 5 条 `.inst` replay 与各自 patch 点原指令是否逐字一致？—— 一致；5 个 `wh_back_*` 全在 .text。**

| shim | 文件偏移 | replay 字（实读字节） | 对应 site 在 vmlinux 的字 | 结论 |
|---|---|---|---|---|
| wh_shim_1 | +0x210 | `fd7bb8a9` = `0xa9b87bfd` | `0xffffffc00824d114` = `a9b87bfd` | ✓ |
| wh_shim_2 | +0x258 | `fd7bbfa9` = `0xa9bf7bfd` | `0xffffffc008247c68` = `a9bf7bfd` | ✓ |
| wh_shim_3 | +0x2a0 | `fd7bbfa9` = `0xa9bf7bfd` | `0xffffffc008247ca8` = `a9bf7bfd` | ✓ |
| wh_shim_4 | +0x2ec | `fd7bbaa9` = `0xa9ba7bfd` | `0xffffffc008126be0` = `a9ba7bfd` | ✓ |
| wh_shim_5 | +0x334 | `fd7bbea9` = `0xa9be7bfd` | `0xffffffc008126740` = `a9be7bfd` | ✓ |

`wh_back_1..5` = `0x214/0x25c/0x2a4/0x2f0/0x338`，**shndx 全为 1（.text），非 UNDEF**；
每个都是 shim 末尾的 `0x14000000 b .`。`bl wh_record` 的 5 条 `R_AARCH64_CALL26` 全部 `shndx=1`（同模块已定义）。
注：源码里的 `hook_replay[]` 数组**没有进 .ko**（无引用，被编译器删掉）——真值在 shim 的 `.inst` 字节里，已逐条核。
另注：源码 `replay` 注释把 H1 的帧写成 `#-0x60`，实为 `#-0x80`（仅注释错，编码对）。

**e. 5 元素表是否一一对应、地址正确？—— 是；init 的下标映射也逐条验了。**

`.init.text` 实读（带重定位标注）：`shim_addr[0..1]=shim1,shim2`（`stp x8,x9,[x19]`）、
`shim_addr[2..3]=shim3,shim4`（`stp x8,x9,[x19,#0x10]`）、`shim_addr[4]=shim5`（`str x8,[x19,#0x20]`）；
`back_addr[0..4]=back1..back5` 同构；安装循环 `cmp x23,#5 / b.ne` ⇒ **正好 5 轮**。
`shim3` 的 `mov x0,#2` 与 `H3=2` 一致；`shim4→#3、shim5→#4` 都随重编号改对了（v1 里 shim_4 是 `#2`）。
⇒ **e 通过。**

### 5.4 `p_victim` 硬门禁评估（用户问题 4）

- **门禁本身成立且方向安全**：`module_param_string(victim, p_victim, 16, 0444)` 的 kparam_string 实测
  `maxlen=16`（`.rodata+0x20 = 10 00 00 00`，string 指针重定位 → `p_victim`），`param_set_copystring`
  拒 `strlen+1 > 16` ⇒ 参数不可能被静默截断；`p_victim=""` 时 `ldrb/cbz` 直通（不误杀）。
- **过滤顺序正确**：`wh_record` 里窗口判断 → victim 判断 → `g_inhook` → 才写 ring；
  victim 自身命中**只 `inc g_calls`，不占槽、不 `inc g_hits`** ⇒ §6.2 的 `hit=0` 不会被 victim 的
  2 MB 栈活动打穿（这正是 v1 点名的那条污染）。
- **失败方向是「作废」不是「误点名」**：忘传参数 ⇒ victim 自身缺页进 ring ⇒ §6.2 判 INVALID，不会产出假 E4。
- **两条建议（非阻塞）**：
  1. insmod 前加一行 `cat /proc/<victim_pid>/comm` 与参数**逐字**对比。`comm` 是 exe basename 截 15 字符，
     若实际进程名不是 `scanary_ro_v21`（换名/软链），过滤会静默失效——结果仍是 INVALID，但白烧一轮。
  2. 预注册里写清「过滤只比 comm、不比 pid」（同名内核线程会被一并排除，低危，v1 已接受）。

### 5.5 多钩子完整性：`wh_remove` / 回滚 / 索引越界（用户问题 5）

| 项 | 实测 | 结论 |
|---|---|---|
| `wh_remove` 循环 | `.text+0x33c`：`ldr w8,[g_patched+h*4]` → `cbz` 跳过 → `apply_patch(site,g_saved[h])` → `rd32` 校验 → 失败走 `pr_err`，成功走 `pr_info` → `str wzr,[g_patched+h*4]`；`cmp x25,#5 / b.eq` 收尾 | **5 点全覆盖，无越界**（`g_saved[5]/g_patched[5]`） |
| init 失败回滚 | `.init.text+0x4e4`（install 失败）与 `+0x520`（GO/NO-GO 失败）都是 `bl wh_remove` → `proc_remove` → `g_pe=NULL` → 返回 | **两条路径都先回滚** |
| GO/NO-GO 失败分支 | `+0x410 cmp x25,x21; b.eq +0x514` → 打印 FAILED → `wh_remove` → `proc_remove` → `-EIO` | 正确 |
| `sum_calls` 越界 | `g_calls` 是 `DEFINE_PER_CPU(unsigned long, g_calls[5])`（size 40）；`per_cpu(g_calls[h],c)` 编译为 base+h*8；`wh_gonogo` 用 `[percpu+0x20]` = **index 4 = H5** ✓；`wh_read` 的头循环 `cmp x24,#5` ⇒ 0..4 | **无越界** |
| percpu 家族 | `g_calls/g_hits/g_ring/g_ridx/g_inhook` 全在 `.data..percpu`（shndx 23）；`wh_record` 用 `mrs tpidr_el1` + `[x8,x9]`，`g_ring` 走 `__per_cpu_offset[cpu]` | v4 幻影族仍免疫 |
| 残余（同 v1，未恶化） | restore 失败只 `pr_err` 且仍清 `g_patched[h]`；install 中途 site 写失败时 `wh_back_h` 已改成 `b resume` 但不可达 | §6.7「5 行 readback ok=1」兜底 |

### 5.6 新必改项（3 条）

| # | 项 | 后果 | 修法 |
|---|---|---|---|
| **S2** | `wrhunt_exit` 的计数索引与标签错位：`pr_info("... H1=%lu H2=%lu H4=%lu H5=%lu", sum_calls(0),sum_calls(1),sum_calls(2),sum_calls(3))` —— 重编号后 index 2 是 **H3**、index 3 是 **H4**，真 H5（index 4）**根本不打印**（`.exit.text` 实读：`w0=0,1,2,3` 四次 `bl sum_calls`，格式串 `...H1 H2 H4 H5`）。同一族：`READY 4 hooks`（dmesg 实际装 5 个）、`MODULE_DESCRIPTION(... 4 kernel entry points)`、源码头注释 `FOUR` / `H3 ... is DISABLED`、`insmod wrhunt.ko ...` 用法行缺 `victim=` | `rmmod` 时 dmesg 会把 `do_page_fault` 的巨量调用数打成 `H5=`，与 §7 的 H5 锚**直接对撞**（最坏：把干净的一轮判成「ex_table 路径被击穿」）。这正是 AGENTS.md「判据集合必须等于判定对象」的反面 | **首选**改一行（`sum_calls(4)`、标签 H3/H4/H5）并重建 → 新五元组 → 只需重跑 5.3(d)、5.3(e) 与 site 表（表内容不变）；**或**不重建，但必须在预注册 §1.4/§5 明写「exit 行不可用于判读、H5 只认 `/proc/wrhunt`；`READY 4 hooks` 文案系已知错位，以 5 行 `hooked` 计数」 |
| **V3** | §5 step 8 的「victim 新进程 + 新栈窗 → 先取新 stack/base/top **再 insmod 对齐**」与三处硬约束冲突：① `lo/hi` 是 0444 只读模块参数，不重装不能换窗；② step 6 的 **P4 会把 `armed` 置 0**，全流程没有任何一步重新 `echo 1`；③ 若真二次 insmod，必须先 rmmod，而 §1.4/§6.7 要求**每次 rmmod 都逐点回读 5 行**，§5 没有这一步。危险在于 `wh_record` 的顺序是 `inc g_calls` → `if (!p_armed) return`：armed=0 时 **calls 照增、hit 恒 0**，于是联合窗读出来正好满足 §3 第 4 行「各路 calls>0 且 hit=0」⇒ 被误判成「多路径阴性 E2」 | 一轮实验白烧 + 可能产出错误的 E2（「写者不走任何已钩入口」）——正是本轮最想避免的误判 | 二选一并在 §5 写死：(a) **单实例**：全程用同一个 victim（step 2 那个），step 7 之后再插 **`echo 1 > /proc/wrhunt`**，删掉 step 8 的「再 insmod 对齐」；(b) **双实例**：step 6 后插「`echo 0` → `rmmod wrhunt_v2` → 核 5 行 readback ok=1 → 起新 victim → 取新 base/top → 重装 → **重做 step 4/5**（10 min 零实验窗）→ 再进联合窗」。注意 `echo 0` 本身不会改 calls，别把它当 re-arm |
| **V4** | §3 判读表两处与装置语义不符：① 「某路 `calls=0` ⇒ 该路钩子失效 ⇒ 部分 INVALID」与 **§7「H5 窗内 `calls=0` ⇒ 与 U-B1 一致」直接矛盾**——H5 是唯一以 0 为正结果的钩子（它的存活性由 P3/go-no-go 证明）；② 「H1/H2/H3/H4 均 0（**含 scanary 自身**）」与 `p_victim` 过滤后 victim 事件**根本不入 ring** 的事实不符（应表述为「无 `comm≠victim` 的条目；`calls` 可增，含 victim 自身」） | 窗末读数时同一个人面对同一份文档会得出相反判决 | §3 第 5 行加「H1–H4 除外 H5」；第 4 行改「（calls 可增，含 scanary 自身；ring 内无 `comm≠victim` 条目）」 |

### 5.7 建议（非阻塞，但都是一行成本）

1. §7 的「step 4 `echo clear` 之后」改为「**step 7 的 `echo clear` 之后**」（数值等价，引用对齐）。
2. §0 第 7 行仍写「点名写者（comm/pid/**LR/调用链**）」、§1 标题仍写「装置（wrhunt **v1**，单模块 5 入口）」——与 §1.3 的降级、与 v2 产物不一致。
3. §5 step 10 的 `rmmod` 建议写全 `rmmod wrhunt_v2`（`modinfo name=wrhunt_v2`；`/proc/wrhunt` 与模块名不同，容易打错）。
4. §1.3 的记录格式块写成 `ev hook=H1..H5 j=… cpu=…`，实际输出是 `ev cpu=%d H%d %s … w=%lx,… j=%llu`（字段顺序/名字不同，内容一致）。
5. insmod 前加 `cat /proc/<victim_pid>/comm` 逐字比对（见 5.4）。
6. 设备侧 `md5sum wrhunt_v2.ko` 与 `FIVETUPLE.txt` 再核一次（§5 step 1 已有，强调别省）。

### 5.8 认可的装载时序（引修订后预注册 §5，含上述修正）

```
0. 离线：按 S2 修/豁免决定 → 若重建，更新 FIVETUPLE 并重跑 ⑤5.3(d)(e) 的字节核对
1. deploy.py put → 设备侧 md5sum 双核 → chmod 644
2. 起 victim（**这一个进程贯穿到 step 9**）→ 300 s RW λ 预检（≥10/300s）→ 取 stack/base/top
   → cat /proc/<pid>/comm 与 victim 参数逐字比对
3. devop 持锁 insmod wrhunt_v2.ko lo=<base> hi=<top> victim=scanary_ro_v21
   → dmesg 应有 5 行 "H%d ... hooked" + "back-branch self-check" 无错 + "GO/NO-GO ok"
   （"READY 4 hooks" 是已知文案错位，按 5 行 hooked 计数）
4. echo clear > /proc/wrhunt
5. 10 min 零实验观察窗：/proc/wrhunt 各路 hit=0（calls 可增，属正常设备活动）
6. 正对照 P1–P4（P1 期望 H3∧FOLL_WRITE；P2 期望 H1(含 w0..w3)+H2；P3 期望 H5+1；P4 期望 ring 不增）
7. echo clear > /proc/wrhunt
7b. **echo 1 > /proc/wrhunt**（V3 修正：P4 已把 armed 置 0；不 re-arm 则 hit 恒 0 而 calls 照增，最像「真阴性」）
8. 联合窗 ≥900 s：**同一 victim、同一 lo/hi**。若确需换 victim ⇒ 先 echo 0 → rmmod wrhunt_v2
   → 核 5 行 readback ok=1 → 取新 base/top → 重装 → 重做 step 4/5/6 后才许进窗
9. 窗末仅 cat /proc/wrhunt（禁 dd/seek/xxd/tail/head）
10. echo 0 → rmmod wrhunt_v2 → dmesg **5 行** "H%d restored ... readback ... ok=1"（缺一行 ⇒ incident）
11. NE 台账 / nerepair dry / 单实例前后对账
```

> 复审范围声明：只读静态审查，未改源码、未访问设备。本节所有「实测」来自本机对 `wrhunt_v2.ko`、
> `vmlinux.elf`（含与 `ktext.bin` 的全等性校验）、`kallsyms.txt`、`linux-5.15.134/` 的离线解析与反汇编。
> 本轮**没有**改动任何被审对象，只追加本文件。
