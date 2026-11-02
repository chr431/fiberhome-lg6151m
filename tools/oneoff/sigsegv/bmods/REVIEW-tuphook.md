# REVIEW-tuphook — mtk_warp wifi_tx/rx_tuple_add 入口窄域钩(B3)

- 源码:`tuphook.c` · 构建:`build_bmods.sh` · 产物:`out/tuphook.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`(`build_bmods.sh` 尾部自证)
- 性质:**唯一会写内核代码的 B3 模块**。只替换两个入口的第 1 条指令
  (`paciasp` -> `b trampoline`),trampoline 记 4 个参数寄存器到 per-cpu
  环形缓冲后原样执行被替换的 `paciasp` 并跳回 entry+4。全程无锁、无分配、
  栈零使用。

## 0. dryrun=1 正对照(必须先跑)

`insmod tuphook.ko dryrun=1` **不写任何一字节**,只做:

1. **函数定位**:`warp_wlan_tx` 是 mtk_warp.ko 的导出符号(见 §1),模块加载器
   跨模块解析并钉住 mtk_warp;`base = &warp_wlan_tx - 0x970`,
   `tx = base+0x7330`,`rx = base+0x7268`。
2. **kallsyms 反查正对照**:`sprint_symbol()`(EXPORT_SYMBOL_GPL,含模块符号)
   必须把 tx/rx 解析为 `wifi_tx_tuple_add+0x0/0x3f4 [mtk_warp]` /
   `wifi_rx_tuple_add+0x0/0xc8 [mtk_warp]`;同时入口字必须等于
   `0xd503233f`(paciasp)。二者任一不符 -> init 返回 -EINVAL,不加载。
3. **ops 链反查**:两条独立调用点(`sub_0`@.text+0 的 adrp+add@+4/+8 与
   `warp_entry_get_by_idx`@.text+0x1718 的 adrp+add@+0/+8)解码出的 .bss 槽
   必须一致(双重交叉验证);槽+0 = bind 数,槽+0x10 = warp entry 数组指针,
   entry 步长 0xb1a8;entry0+0x10 = key(非空才算活 bind);`ctx = entry+8`。
   然后读出 `ops=*(ctx+0x700)`,用 `sprint_symbol` 打印:
   `tx_fill=*(ops+0x18)` / `rx_fill=*(ops+0x50)` / `wo_rxcnt=*(ops+0x60)` ——
   即"填充回调是谁"的正面答案(dmesg + /proc/tuphook 都可读)。
4. 全部 dereference 走 `copy_from_kernel_nofault`(extable 修复),不产生 oops。

判定:dryrun 下 dmesg 出现两条 `name:` 行 + `bind:/ops:/cb:` 行即正对照通过;
不出现即拒绝进入 patch 模式。

## 1. 模块基址获取(module kernel api,全部有源文件证据)

设备内核 5.15.134 的导出面(**逐条在 _local/legacy/linux-5.15.134 中核实**):

| 需求 | 结论 | 证据 |
|---|---|---|
| name->addr(kallsyms) | **不可用**:`kallsyms_lookup_name` 自 5.7 起不再 EXPORT_SYMBOL;CJKPROBES=n 连 kprobe 拐杖都没有 | kernel/kallsyms.c 无 EXPORT;config `# CONFIG_KPROBES is not set` |
| 模块基址 | **用导出符号做锚**:mtk_warp 导出 `warp_wlan_tx`;模块 loader 解析未定义符号时跨模块查 `__ksymtab`,并自动建立依赖(我们加载期间 mtk_warp 不可卸载) | mtk_warp.ko `__ksymtab` 反解析:111 项含 `warp_wlan_tx`/`warp_wlan_rx`;kernel/module.c 符号解析路径 |
| addr->name | `sprint_symbol()` EXPORT_SYMBOL_GPL,kallsyms_lookup_buildid 会回落到 module 符号 | kernel/kallsyms.c:475 |
| find_module | 未导出(module.h 有声明,module.c 无 EXPORT) -> 不用 | kernel/module.c 全文 |
| 静态偏移 | 0x970/0x7330/0x7268/0x18b50/0x1718 来自设备 mtk_warp.ko(738,656 B,未 strip)的 objdump | 私有仓 ko_corpus/mtk_warp.asm |

## 2. 入口指令保存(<=4 条):实际只替换 1 条

两个入口第一条都是 `paciasp`(`0xd503233f`,objdump + 加载期复核):

```
wifi_rx_tuple_add  0x7268: paciasp; stp x29,x30,[sp,#-0x30]!; mov x29,sp; str x19,[sp,#0x10]
wifi_tx_tuple_add  0x7330: paciasp; stp x29,x30,[sp,#-0x60]!; mov x29,sp; ...
```

保存策略 = **隐含保存**:原字常量 `INS_PACIASP` 编译期固化,加载时先比对再
替换;trampoline 第 15 条指令原样执行 `paciasp`,再 `b entry+4`。因此不需要
“复制前 N 条指令到跳板”的指令搬运器,也就不存在分支类指令搬运的坑
(两条入口第 1 条都是 hint 级 paciasp,位置无关)。

## 3. 断点安全:BRK vs inline jmp 的选择与理由

**选 inline B(4 字节直达跳转)**,放弃 BRK。判据全部是"模块能不能用该 API":

| 方案 | 需要的 API | 设备可用性 | 结论 |
|---|---|---|---|
| BRK + break hook | `register_kernel_break_hook` | arm64 debug-monitors.c **无 EXPORT_SYMBOL** | 模块拿不到 -> 不可用 |
| kprobe | `register_kprobe` | CONFIG_KPROBES=n(连符号都不存在) | 不可用 |
| ftrace | register_ftrace_function | CONFIG_FUNCTION_TRACER=n;mtk_warp 无 `__mcount_loc` 节 | 不可用 |
| perf hw breakpoint | perf_event_create_kernel_counter | CONFIG_PERF_EVENTS=n | 不可用 |
| **inline B** | 无(纯 asm + 已导出 stop_machine) | 只需写文本窗口(§4) | **采用** |

辅助理由:(a) 4 字节对齐 store 在 arm64 单拷贝原子 —— 先取旧指令的 CPU 跑
完整原序言,先取新指令的进跳板,不存在半状态;(b) BRK 走异常路径,在 S0
"ipanic 无视 panic_on_oops" 的环境里,异常路径自身出错 = 直接重启,而 B 路径
出错最多是同一条 oops 语义且可被 dieblx 记录;(c) 跳板放**本模块 .text**
(模块区,距 mtk_warp < 128MB 恒成立;vmap 会落到 MODULES_END 之外,可能出
B 范围,故不用 vmap)。

## 4. 写内核文本的窗口(STRICT_MODULE_RWX=y 的唯一解)

模块 .text 与 mtk_warp .text 运行期都是 RO+X。可用的导出面里:
`module_alloc/__set_fixmap/get_vm_area/bpf_jit_binary_alloc/__vmalloc_node_range`
**都未导出**;`apply_to_page_range`(GPL)**已导出**但要求真实 init_mm
(`if (mm == &init_mm)` 分支才不取用户锁)。

实现:init_mm = `kthreadd(pid 2)->active_mm`(内核线程祖先,active_mm 恒为
&init_mm;`find_get_pid/get_pid_task/put_pid/__put_task_struct` 均 EXPORT_SYMBOL_GPL)。
自己走 pgd->p4d->pud->pmd->pte(全部 header inline),**pmd_leaf 直接拒绝**
(否则 apply_to_page_range 内 `BUG_ON(pmd_huge)` = oops = ipanic 重启)。
翻转写入窗口三步,全部在 stop_machine 内、全 CPU 同步:

1. `tup_flip_cb`:master 写 PTE(`pte_mkwrite`,HW_AFDBM 下 = DBM|!RDONLY),
   全 CPU 本地 `tlbi vaale1is`(与 flush_tlb_kernel_range 同 opcode)+ dsb/isb;
2. `tup_patch_cb`:master 写 1~4 个 word(本次每页最多 3/2 个),全 CPU
   `dc cvau + ic ivau + dsb + isb`(即 aarch64_insn_patch_text 的等价序列,
   只是没有 fixmap 别名所以用 PTE 窗口代替);
3. 第三个 stop_machine 把 PTE 原值写回(RO),再次全 CPU tlbi。
   只读回读校验通过后才置 installed=1。

已验证:`.text` 跳板块(2×64B + pool)经 `.balign 4096` 保证同页
(加载期再断言);mtk_warp 两个入口 0x7268/0x7330 同属 0x7000 页(加载期
断言),因此 mtk_warp 侧只用一次窗口。

## 5. 跳板(64 字节整,逐字编码已反汇编核对)

```
adr  x16, tuphook_pool     ; 本模块 .text 内 pool{R}
ldr  x17, [x16]            ; P = alloc_percpu 返回值(32 位断言)
mrs  x9, tpidr_el1         ; 本 CPU per-cpu 基(SMP=y;PREEMPT_NONE 不迁移)
add  x9, x17, x9           ; x9 = struct tup_ring(this_cpu)
ldr  x17, [x9, #0x4000]    ; head = (idx<<1)|nested_guard
tbnz x17, #0, done         ; 递归守卫:嵌套调用只跑原函数不记录
add  x17, x17, #2
str  x17, [x9, #0x4000]
ubfx x10, x17, #1, #8      ; idx = head>>1(256 条,写满覆盖)
add  x10, x9, x10, lsl #6
stp  x0, x1, [x10]         ; ctx, band
stp  x2, x3, [x10, #16]    ; skb, flags
bic  x17, x17, #1
str  x17, [x9, #0x4000]
done: paciasp              ; 被替换指令,原样执行
b    entry+4               ; init 时把 . 改成 entry+4(另一处 patch)
```

- 只碰 x9/x10/x16/x17(调用者保存的临时寄存器,AAPCS 下被调函数本就可
  任意破坏;x18 平台寄存器不碰);x0..x3 参数零破坏;sp/lr 零接触。
- 读 `[x9,#0x4000]` = `struct tup_ring.head` 偏移(BUILD_BUG_ON 固化)。
- 记录的 64B/条 = {ctx, band, skb, flags, 4×pad},环形 256 条/CPU,
  `head>>1` 单调计数,proc 按最新 N 条吐出。

## 6. 卸载还原

1. 若入口字仍是我们写的 B(`g_bent_tx/rx`),用同一窗口机制写回 paciasp,
   全 CPU icache 同步,读回断言 = `0xd503233f`;
2. 若入口字已被第三方改变 -> 只告警,不做任何写(避免破坏别人);
3. 先 `tup_uninstall()` 再 `proc_remove`/`free_percpu`;写回在 stop_machine
   内完成,此刻没有 CPU 正处于跳板中,随后其页随模块释放是安全的。

## 7. 与 ipanic / dieblx 的共存假设

- **ipanic/mrdump 假设(S0 教训)**:任何 oops(含 BRK 未处理、BUG_ON、
  缺页)都会强制重启,与 panic_on_oops=0 无关。本模块的对抗设计:
  ① 加载前全量验证(入口字、kallsyms 名、B 范围、池偏移、同页断言),
     失败 = 干净 -EINVAL,不 patch;
  ② 运行期只读路径全 nofault;
  ③ 跳板无调用/无栈/无锁/无分配 —— 唯一可发生的是对自有 per-cpu 缓冲的
     普通 store(地址恒有效),结构上不存在缺页或死锁路径;
  ④ 跳板块 `.balign 4096` 单页,窗口期只翻这一页的 RW 位,不涉及相邻页。
- **dieblx 共存**:若跳板意外出错,仍走标准 die 路径,dieblx(先加载)记录
  完整 pt_regs —— 本模块不注册任何 die/panic notifier,无优先级冲突。
- 与 kmsglog 无交互;与 ioprobe/romap 无共享状态。

## 8. 逐函数自审(锁 / 睡眠 / 故障路径 / 递归)

| 函数 | 锁 | 睡眠 | 故障路径 | 递归 |
|---|---|---|---|---|
| `tup_flip_cb` | 无(atomic + tlbi asm) | 无 | 只写自有 PTE 值;stop_machine 保证全 CPU 停驻 | 无 |
| `tup_patch_cb` | 无 | 无 | 只写已验证地址的 word;icache 维护本地化 | 无 |
| `tup_set_pte` | 无 | stop_machine 可睡眠(仅 init/exit 进程上下文) | 返回 stop_machine 错误 | — |
| `tup_patch_words` | 无 | 同上 | walk 失败/跨页/PTE 缺失 -> 错误返回;无论成败恢复 PTE | — |
| `tup_walk_pte` | 无 | 无 | pgd/p4d/pud/pmd 逐级 none/bad 检查;leaf 拒绝;pte 必须 present | — |
| `tup_get_init_mm_pgd` | 无(pid/task 引用计数 API 自带) | 无 | 任一步失败返回负码,不改状态 | — |
| `tup_resolve` | 无 | 无 | 入口字/名字不符 -EINVAL | — |
| `tup_install` | 无 | stop_machine ×2 | 每步失败即返回;入口写失败不留下跳板使用;读回失配 -> 回滚入口 | — |
| `tup_uninstall` | 无 | stop_machine | 第三方改动 -> 只告警 | — |
| `tuphook_init/exit` | 无 | module API 正常上下文 | 失败路径反向释放(proc/percpu/入口) | — |
| `tup_fill/tup_read` | mutex(进程上下文) | mutex 可睡眠,合法 | 全部 nofault;环读取改 head 再读,撕裂由 guard 写入者唯一排除 | — |
| 跳板(asm) | 无 | 无 | 仅自有 per-cpu 缓冲 store | guard 位自抑制 |

## 9. 静态自检(`python check_calls.py out/tuphook.ko`)

```
init_module     -> EXT __alloc_percpu / sprint_symbol / INT tup_patch_words
tup_patch_words -> EXT find_get_pid / get_pid_task / put_pid / __put_task_struct
                   / stop_machine / memset / refcount_warn_saturate
tup_read        -> EXT copy_from_kernel_nofault / sprint_symbol / cpumask_next
                   / mutex_lock / mutex_unlock / __arch_copy_to_user / ...
tup_flip_cb / tup_patch_cb -> (无外部调用)
```

关键断言:**两个 stop_machine 回调闭包内 0 个外部调用**(锁/分配/printk
全不在内),与非原子/原子上下文纪律一致。全部未定义符号均为内核导出
(`memstart_addr`/`gic_nonsecure_priorities` 也已核实 EXPORT_SYMBOL,且
dieblx/romap 在设备上已验证过同款引用)。

## 10. 残余风险(必须先读)

1. **写文本窗口**:PTE 变 RW 与写回 RO 之间的窗口跨越一次 stop_machine,
   期间若第三方并发写同一页会竞争 —— 该页是 mtk_warp 只读代码,正常运行
   无写者,窗口内也无人执行(F-07 纪律)。
2. **B 距离**:跳板在本模块 .text,与 mtk_warp 同属 128MB 模块区 -> 恒在
   B 范围;加载期仍断言 |delta|<128MB,超界即拒绝(不 patch)。
3. **per-cpu 偏移 32 位**:P 存在 pool 里只写低 32 位并断言 `P<2^32`;
   PERCPU 单元偏移通常远小,越界即拒绝加载。
4. **IRQ 嵌套**:守卫位让嵌套调用跳过记录(仍正常执行原函数)—— 数据
   质量影响,不是安全问题;proc 头行打印 guard 值便于发现。
5. **PAC**:sysctl/内核自检均启用 PTR_AUTH;跳板原样执行 paciasp,若某天
   入口首条不再是 paciasp,加载期断言会直接拒绝(不盲跳)。
6. mtk_warp 卸载:依赖使然(引用导出符号),我们加载期间它卸不掉。

## 11. 上机验证序列(F-07 纪律)

```
0. deploy.py put out/tuphook.ko /data/repro/tuphook.ko   (.ko 只被 insmod 读,644 即可)
1. insmod dieblx.ko                     # 黑匣子先到位
2. insmod tuphook.ko dryrun=1           # 正对照:名称/偏移/ops 链,零 patch
   dmesg | grep tuphook                 # 期望:base=... tx=... rx=...;两行 name:;
                                        # bind:/ops:/cb: 三行
3. cat /proc/tuphook                    # dryrun 模式头 + 空环
4. rmmod tuphook
5. insmod tuphook.ko                    # patch 模式(先健康态观察 60s)
   dmesg | grep tuphook                 # INSTALLED tx_b=... rx_b=... back_*
6. (产生 wifi tx/rx 流量) cat /proc/tuphook   # 记录 + ops/cb 名
7. rmmod tuphook && dmesg | grep "restored"  # 还原读回
```

## 12. 最大残余风险

一次非自愿重启的唯一现实路径:跳板在极早期(guard 置位前)遇到自身内存
异常 —— 但跳板只触碰 alloc_percpu 的自有缓冲,且加载期已断言 P<2^32,
结构上不可达;其次是写窗口内 stop_machine 死锁(无锁回调,无 printk),
结构上同样不可达。两者都停留在"设计论证 + 静态检查",上机前不可替代运行
验证。
