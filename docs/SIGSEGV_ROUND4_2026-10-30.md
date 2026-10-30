# SIGSEGV 写入源调查 · 第四轮（写入路径判定：用户态虚拟地址 / 内核 uaccess）

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

日期：2026-10-30 09:37–10:10　设备：LG6151M（本轮实验中有 3 次由我自己仪器的缺陷触发重启，均已恢复）

> 本轮目标：不再猜"谁"，而是用页表实验判定"**怎么写的**"。结论已闭环到路径级别。

## 1. 判定结论（3 条，均为实测）

| 编号 | 结论 | 判据 |
|---|---|---|
| A | 写入**不经过**内核线性映射（`phys_to_virt` 别名） | 把受害页的线性映射 PTE 改指到影子页后，受害者**照样崩**（`remap.ko`，自检已证明改指生效：别名读到 0、写别名落到影子） |
| B | 写入**不经过**物理地址（**排除一切 DMA**） | 把受害者的**用户 PTE** 改指到影子页（SIGSTOP 后拷贝，内容一致），3/3 次受害者仍在 8/41/10 s 崩溃，而**原物理页全程 0 次写入**（`remapu.ko`，`poll done new=… old=0`） |
| C | 写入使用**用户虚拟地址**（内核 uaccess 类 `copy_to_user`） | 由 A+B 夹逼：既非线性映射、也非物理地址，却随用户 PTE 走 ⇒ 只能是通过 TTBR0 的 EL1 用户拷贝（PAN 下必须走 uaccess 路径，否则会 oops；实测无 oops） |

**补强**：受害者 `stime=0`、`minflt` 恒定（31，全程不增）⇒ 它**从不进入内核**（无系统调用、无缺页）。
因此该 uaccess 写**不发生在受害者自己的 syscall/缺页上下文**，只能发生在**中断上下文**（`current` = 受害者、TTBR0 = 受害者 mm），
或某个 `use_mm()` 的内核线程里。

## 2. 由此被排除的整类解释

- **任何 DMA 主控**（WiFi / eMMC / USB / dpmaif / MDMA / SCP）——它们只能按物理地址写，B 直接反证；
- **内核线性映射上的 memcpy/memset**（`kmap`、`copy_strings`、迁移拷贝等）——A 直接反证；
- **vmalloc/vmap 别名**——B 同样反证（别名写会落在原物理页，实测 0 次）；
- **受害者自身代码**——它只跑 musl `snprintf`，`va_start` 写的是栈指针（已在活体内核上反汇编确认），写不出该记录；
- **ptrace / KSM / page poisoning / 硬件观察点**（前三条已排除，第四条本轮再次确认自检不触发）。

## 3. 记录内容与唯一相关的 AP 代码面

- 记录恒为 32 字节、16B 对齐，落在**当前 `va_list`** 上；
- 部分样本含 dpmaif 寄存器活值（r180/r094/r1e0/bat_va）；
- 在活体内核里，**唯一读取这批寄存器**的 AP 代码是 `dpmaif_dump_register`（0xffffffc00855c4d8），
  它调用 `ccci_dump_write`（格式化写日志环）与 `ccci_util_mem_dump`（按 180/16 字节 dump 内存），
  并挂在 `/proc/ccci_dump`、`/proc/ccci_log` 这套**用户可读**的调试面上。

## 4. 仍未闭环的一点

**具体是哪个函数发起这次用户拷贝**。AP 侧可用手段已用尽：
无 perf、无 kprobe、无 ftrace、硬件观察点被固件禁用；`_copy_to_user` 在镜像里被内联成 20+ 份副本，无法单点挂钩。
收口只剩两条路：(a) 拿到 vendor 内核源码，在 ccci/dpmaif 的 dump 路径上找"缓存用户指针 + 中断上下文拷贝"；
(b) 自建带 kprobe 的内核（需 vendor 驱动源码，本仓没有）。

## 5. 本轮新增工具（`tmpfiles/an3/`，不入库）

| 工具 | 作用 | 备注 |
|---|---|---|
| `remap.ko` | 拆 2MB 块映射、改**线性映射** PTE 指向影子页 | 自检通过 |
| `remapu.ko` | 改**用户 PTE** 指向新页（内容拷贝），同时轮询新旧两页 | 3/3 判定 B |
| `kread.ko` | 把任意内核 VA 段导出成二进制 proc 文件 | **必须用 bounce buffer**，否则 hardened usercopy 直接 `usercopy_abort` → panic（本轮踩过一次） |
| `vsurv3/6`、`vprobe`、`mon`、`pftest/abtest` | 受害者与速率测量 | — |

## 6. 方法论教训（并入 §7）

24. **改用户 PTE 前必须让目标进程 SIGSTOP**：否则 4KB 拷贝可能抓到"正在被写的 va_list"，把旧记录带进影子页，制造假阳性。
25. **`copy_to_user` 的源不能是内核 text**：hardened usercopy 的 `__check_object_size` 会 `usercopy_abort` → `die` → panic（`panic_on_oops=1`）。
26. **aee 会"跳过重复异常"**（dmesg 实测 `Skip duplicated exception !`）⇒ `ne_events.tsv` 是**去重后的**台账，不能当全量人口普查。
27. **速率必须同窗对照**：同一套受害者 60 s 内可以 2 起，也可以 13 起；单窗 A/B（例如"灌 kmsg 提高 5.5 倍"）在第二轮就被推翻（13 vs 10）。

