# U-B1 · fxhook v2 装载前 skeptic 静态审查

> 日期：2026-11-04 12:15（+0800）｜审查者：接手操作者（skeptic 帽）
> 对象：`tmpfiles/repro/kmod/fxhook.ko`（md5 `7810ac29f3b54f4dcab880edafa66135` / 183,496 B / 2026-11-01 构建，**从未上机**）＋源码 fxhook.c
> 内核：厂商 5.15.134 aarch64，panic_on_oops=1 + panic_on_taint=1（任何缺陷 = 非计划重启）
> 方法：源码精读 + **二进制 .ko 字节级反汇编**（pyelftools）+ 5.15.134 源树交叉验证。

## 0. 判决

**有条件放行**。零必改项；三条运行期约束写进预注册（§3），全部是时序纪律而非代码改动。

## 1. 必查清单逐条

### A. shim 汇编正确性 —— **通过（E3，字节级）**

从 .ko `.text` 实读（fx_shim @0x7f0，44 B）：

```
07f0 stp x29,x30,[sp,#-0x20]!     ; 建帧
07f4 mov x29,sp
07f8 str x0,[sp,#16]              ; 存 regs
07fc bl  fx_record                ; reloc CALL26→fx_record（模块内，范围自检 -EIO 兜底）
0800 ldr x0,[sp,#16]              ; 恢复 x0
0804 ldp x29,x30,[sp],#0x20       ; 撤帧
0808 stp x29,x30,[sp,#-0x20]!     ; 重放被替换指令（fixup_exception+4）
080c-0818 adrp/add/ldr/br x16     ; 跳运行期 resume（+8）
```

- **寄存器损伤分析**：`bl fx_record` 唯一 caller-clobber 是 x30（由 shim 帧保存恢复）。
  fx_record 自身反汇编证实是标准 ABI 函数（序言 `stp x28,x27 / stp x26,x25…` 保存全部
  callee-saved）。x1–x17 均不损——补丁点 +4（paciasp 之后、原 stp 之前）此刻
  fixup_exception 尚未消费任何入参（x0=regs 是唯一入参，已存恢复），**寄存器窗口安全**。
- 被替换指令重放在跳 resume **之前**执行一次（07f8），无双重执行、无跳过。

### B. PAC 规则 —— **通过**

补丁点 +4 = paciasp 之后（ARM64_PTR_AUTH_KERNEL=y 前提成立）；与 tuphook 同规则
（tuphook.c:42「+4 补丁」）。x30 在 shim 内经普通 ldp 恢复——此时尚未 eret/ret，
无 PAC 校验点，安全。

### C. x18 / SCS —— **通过（实测排除）**

- .config：`CONFIG_CC_HAVE_SHADOW_CALL_STACK=y` 仅是**能力位**；`CONFIG_SHADOW_CALL_STACK`
  本身 0 命中（未启用）⇒ 内核无影子栈，x18 无 SCS 语义。
- fx_record 428 B 全量扫描：**x18 使用 = 0**（唯一误报 0x54000a42 是 B.CC 条件跳转，
  编码字段碰巧落在 rt 解码窗）。fx_shim 同样 0。
- 兜底事实：同 zig 链 tuphook/dmahook live 数月零 x18 事故。

### D. 调用上下文 —— **通过（含 atomic 合法性）**

5.15.134 源码链：`el1h_64_sync_handler → el1_abort → local_daif_inherit → do_mem_abort
→ __do_kernel_fault → fixup_exception`（fault.c:367，唯一数据面调用者；另 kprobes.c:288）。
el1_abort `local_daif_inherit(regs)` ⇒ **fixup_exception 运行于关闭抢占/中断的异常上下文**。
fx_record 快路径用的原语在该上下文全部合法：`mrs far_el1`（系统寄存器）、`smp_processor_id`
（读 cpu_number）、percpu inc（this_cpu_inc 原子）、`jiffies`（只读）、`current`（读
thread_info，无分配无锁无调度）。armed 路径的 `memcpy(…,16)` 无故障可能（源 current->comm
常驻内存）。**无 GFP_KERNEL、无 mutex、无 O(n) 遍历**——A-7 类教训不适用。
far_el1 有效性：fixup_exception 只会在缺页异常的同步路径里被调，el1_abort 读 FAR 后
（354 行）到 do_mem_abort 传递的是同一异常，中途无嵌套异常写入 FAR 的窗口（IRQ 在
DAIF inherit 前被硬件 mask，嵌套页故障即 BUG 而非正常路径）⇒ far 读数可信（E2）。

### E. 热路径开销 —— **通过**

未武装快路径：`mrs far` → cpu id → inc → `if (!p_armed) return` ≈ 7 条指令 O(1)。
fixup_exception 正常运营频率 = ex_table 命中率（uaccess 失败/探测读），设备低负载下
预计 <1/s 量级；武装后窗内 far 过滤同样 O(1) 两条比较。rate limit 窗口用 percpu
jiffies 桶，无锁。F-11（锁内 O(n)）结构性排除。

### F. far_el1 窗口过滤语义 —— **通过（含 el0 混淆评估）**

fixup_exception 仅由 **EL1 数据 abort**（is_el1_instruction_abort 反向门，fault.c:367）
与 kprobes 单步（kprobes.c:288，此时 far 是断点地址非数据地址——见约束 3）到达。
EL0 uaccess 缺页走 do_page_fault 用户路径，**不经过 fixup_exception** ⇒ 无 el0/el1 混淆。
kernel-mode 读用户地址（TTBR0 walk）产生的 far 是用户 VA，正落在 [lo,hi) 窗 ⇒
`copy_from_kernel_nofault` 型外部 CPU 写会被记录——这正是 Phase-2b 要抓的信号。

### G. go/no-go —— **通过**

`copy_from_kernel_nofault(0xdead0000)` 路径实锤（HAVE_GET_KERNEL_NOFAULT=y，arm64
`__get_kernel_nofault → __raw_get_mem → __get_mem_asm` 带 `_ASM_EXTABLE(1b,3b)`，
uaccess.h:269）⇒ 缺页 → __do_kernel_fault → **fixup_exception 必被调**。
g_calls 是普通 ulong 跨 CPU 读取：go/no-go 循环 100ms 轮询，仅作存活性判断，
弱一致可接受（E2）。0xdead0000 在 KERNEL_DS 下走 TTBR0：init_mm 用户区未映射 ⇒
translation fault ⇒ 路径成立。

### H. armed=1 自动武装 vs 协议 armed=0 —— **接受自动武装（降险取舍）**

fx_install 成功尾部 `p_armed=1`（:218）与协议 §2「armed=0」矛盾——版本漂移属实。
**取舍：不改码**（重编=新五元组=重走全链，而改动只影响观察窗语义）。理由：
armed 的危害面 =「观察窗内 far∈窗 的缺页被记 ring」；本实验窗 [lo,hi) 是实验专用
va_list 页，零实验观察期内**该页不会被任何 uaccess 触碰**（scanary 未跑、无 rovictim）
⇒ ring 预期为空，观察窗语义保持。已把「观察窗内 `hit` 必须为 0」升级为硬判据（预注册 §4）。

### I. proc_ops 缺 .proc_lseek —— **通过（5.15 无害）**

5.15.134 `proc_reg_llseek`（fs/proc/inode.c:276-286）**无条件调用** `proc_ops->proc_lseek`，
无 NULL→no_llseek fallback —— tuphook 注释属实。但 fx_ops 只注册 read/write：
`proc_create` 时 `pde->proc_ops` 为 fx_ops，llseek 路径会在 `use_pde` 后调 **NULL 函数指针**
⇒ 理论 crash。**实测边界**：busybox `cat`/`echo`（shell 重定向）不调 lseek
（O_RDONLY 顺序读）；唯一风险是 `dd`/某些 busybox applet 用 lseek。**约束 2：设备上
对 /proc/fxhook 只允许 cat 与 echo 重定向，禁止 dd/seek 类工具**。
（tuphook 同缺项 live 验证数月 = 实证低危；dmahook 已补 seq_lseek。）

### J. 回滚完整性 —— **通过（附风险注记）**

`fx_remove`：apply_patch(恢复)+rd32 回读 + 日志；restore 失败仅打日志的残余风险 =
现场留一个 4 字节 B→模块 VA 的补丁，rmmod 后模块卸载 ⇒ 野跳转 = 下一次
fixup_exception 调用时 panic。概率极低（aarch64_insn_patch_text 已被 tuphook/tuphook
同链反复验证），但**约束 1：rmmod 后必须人工确认 readback ok=1 行出现在 dmesg**，
不出现立即记 incident 并重启窗口计划（LK 救砖兜底）。
go/no-go 失败路径：fx_remove 先回滚再返回 -EIO，`fxhook_init` 再 proc_remove——顺序正确。

### K. vermagic / 手工模块段 —— **通过（同链先例）**

MODULE_INFO(vermagic,"5.15.34 SMP mod_unload aarch64") + 手工 `.gnu.linkonce.this_module`
与 tuphook/dmahook 同构（同 build.sh 产物已 live）。

### L. 其他发现

1. `fx_read` 的 `n = (int)(*off + len)` 截断逻辑在超大 off 下为负——ring 输出截断而非
   crash（scnprintf 有界）；busybox cat 从 0 读，不受影响。
2. `fx_write` 的 `strncmp(kb,"clear",5)` 后落回 `kb[0]=='0'/'1'` 分支——"clear" 首字符
   'c' 不匹配，语义正确。
3. `g_calls` 非原子（普通 ulong +=）在多 CPU 并发下可能少计——只影响 liveness 计数，
   不影响判决字段（hit ring percpu 独立）。
4. **未注册版权 .plt/.init.plt 段 hack 已在源码（:316-317）**——zig freestanding 缺段
   的已知补法，同链验证过。

## 2. 结论表

| 项 | 结论 | 风险级 |
|---|---|---|
| A shim/寄存器 | 字节级通过 | — |
| B PAC | 通过 | — |
| C x18/SCS | 实测排除（二进制扫描 0 引用 + config 未启用） | — |
| D atomic 上下文 | 全原语合法 | — |
| E 热路径 | O(1)，低频 | — |
| F far 语义 | EL1-only，无混淆 | — |
| G go/no-go | ex_table 路径实锤 | — |
| H armed=1 | 接受（观察窗判据收紧兜底） | 低 |
| I proc_lseek | NULL 在 5.15 是真风险 ⇒ **禁 dd/seek 类读** | 低（纪律兜底） |
| J 回滚 | 逻辑通过；restore 失败后果列明 ⇒ **必须人工确认 readback** | 低 |
| K vermagic | 同链先例 | — |
| L 其他 | 3 项小瑕疵均不触发 panic | — |

## 3. 运行期约束（预注册直接引用）

1. **rmmod 后必须看到** `restored 0xffffffc008126740 to a9be7bfd (readback a9be7bfd ok=1)`，
   否则按 incident 走（LK 救砖待命）。
2. **/proc/fxhook 只用 cat 读、echo 写**；禁止 dd/xxd/seek 类工具触碰（proc_lseek=NULL）。
3. **kprobes 场景旁注**：本 boot 无 KPROBES（config=n），kprobes.c:288 路径不可达，
   far 语义唯一来源 = 数据缺页 ⇒ 窗口过滤干净。
4. 观察窗（10 min 零实验）内 `hit` 必须为 0（armed=1 已自动生效，见 H 的理由）。
5. 全程 devop 持锁；任何 oops/stall 迹象 ⇒ 立即停止一切并评估（不 rmmod 二次触发）。
