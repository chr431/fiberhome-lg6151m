# 03 · 仪器登记（唯一仪器表）

> 每个探针必须有一行；没有登记的探针，其结果不得进入 `01_CLAIMS.tsv` 的 E2 以上。
> 状态：`OK` = 本地/设备已验证；`COND` = 有条件可用；`BROKEN` = 已知缺陷；`STAGED` = 已写待部署；`RETIRED` = 退役。

## 1. 总表

| ID | 探针 | 测什么 | 覆盖 | 正对照 | 状态 | 主要缺陷/备注 |
|---|---|---|---|---|---|---|
| P-01 | `va_scan.py` | 16KB 栈转储的 fault-time va_list 记录 | 106 份 h3b | 本地 71/32/3 断言 | **OK** | 修复 0x780 槽位；tag-aware |
| P-02 | `core_scan.py` | 完整 core 的 fault-time x2 记录 | 11 份 core | 本地 pf.core/6 an2 | **OK** | 需 pyelftools |
| P-03 | `vsurv4` | 新的 canary：async-signal-safe handler + 栈页 | 设备 | `kill -11` + 真实崩溃 | **OK (device)** | 自检 h4 32888B；首份随机栈 A0B2 |
| P-04 | `stackdump` + `core_meta v1.7` | 自然 NE 的 fault-time 栈窗口 | 全部 NE | 待设备 | **STAGED** | 部署前 bump core_meta 版本 |
| P-05 | `cth` | copy_to_user/cfu/PF hook | 已 hook 路径 | ac2u 78 命中；PF 已通过；cfu 事故 | **COND (PF OK; cfu BROKEN)** | cfu 正对照导致 Oops/重启（C-035）；需递归守卫/去 dump_stack/默认关 c2u；`g_hit` 上限 4000 |
| P-06 | `uw` | uaccess 窗口开启者 | ≤125 站点 | 无 | **BROKEN** | `lr`=开窗者；300 未跑；125–130 累积坏；`irq_only` 漏 kworker；`uw_in` 吞嵌套 |
| P-07 | `remap`/`remapu` | 线性映射 vs 用户 PTE | 单页 | 自检只验别名 | **BROKEN** | 无 60s 稳定性对照；改活栈 PTE 可自崩 |
| P-08 | `vro` | 只读栈页的 kernel fault | 24 进程 | PF hook 未正对照 | **COND** | 只挡用户 PTE；线性别名仍可写；无 va_list |
| P-09 | `vprobe` | 任意 live va_list 的写入 | 4 实例/30ms | 无 | **COND** | 无 N/LOD；窗口短 |
| P-10 | `pwatch`/`va2pa` | 指定 PA 的内容变化 | 单页 | 自检 | **COND** | pin 改变页生命周期；单页单次 |
| P-11 | `pfcanary` | 崩溃率代理 | 200M snprintf | 自身 | **COND** | handler 递归；速率 5.3x 不是 1:1；非自然人口 |
| P-12 | `core_meta`/`ne_events` | 崩溃台账/元数据 | 全 NE | **有**：测试自杀进程 far/pc 三方一致（v1.13, 2026-11-01） | **OK (device)** | aee 去重；core_trap 已停用；unsync；origin 可能 unknown；far/pc 依赖 coreaddr+note 头落在前 8KB（截断→空列回退） |
| P-13 | `vaguard.tsv` | 闸门命中 | 已链接二进制 | 设备 A/B | **COND** | 首命中+每 256 一行；3 次是下限 |
| P-14 | `probe_selftest` | PF/c2u/cfu/uw 正对照 | 待设备 | 设计 | **STAGED** | 源码/说明；设备测试待做 |
| P-15 | `patrace.ko` | VA→PA 解析（+页前 16B） | 单 VA | **有**：mmap 写 `PATRACE_MAGIC16` → VA→PA → 读回一致（E3） | **OK（有限）** | **缺**「同 VA 跨时刻 PA 可变」的检出能力正对照 → C-160 不可用（C-164）；补 D7 后转 OK |
| P-16 | `rxring.ko` | 内核态读 RX 环 DD 位 | 3 条环 | **无**（从未读到 DD=1） | **E0（无正对照）** | 24.9 万次扫描 0 次 DD=1；「环里没有 DD=1」**不可引用**（C-169） |
| P-17 | `dd_burst`（`dump_dma` 解析） | DD=1 写回形态 | 3 次突发 | **无** | **E0（无正对照）** | 24 快照 dd_set=0；H4（HW 写回）从未被直接观测（C-169） |
| P-18 | `pascan`（`/dev/mem` 按值搜） | 按值搜物理内存 | 全 RAM | **部分**：随机值 6 处 / 0xdeadbeef 32 处 = 噪声底 | **E1** | 缺「已知在内存里的值」正对照；「内核映像 0 命中」不可引用（C-169） |
| P-19 | `kmsglog`（/dev/kmsg 持久镜像） | 内核环全量落盘（含 pr_info fault 行） | /dev/kmsg 全记录 | **有**：aee 处理链 pr_info 行落盘（2026-11-01）；`--selftest` 游标回卷原语 PASS | **OK (device)** | 只收启动后新记录（SEEK_END 起）；环溢出丢行（SEQ 缺口在日志内自证）；8MBx2 有界；**注意**：`unhandled fault` 行在 nerepair 在役时结构性缺席（arm64 `unhandled_signal()` 要求 `!tsk->ptrace`，实测全部 pid TracerPid=nerepair）——FAR 权威来源是 P-12 的 far/pc 列，不是 kmsg |

> **2026-11-01 skeptic 标注（audit §10 / C-169）**：P-05（cth）的阴性 = **E1**（只覆盖已 hook 路径 + `g_hit` 可能饱和）；P-06（uw）= **E0**（无正对照、300 站点从未成功）；P-08（vro 0/12）= **E0**（03_PROBES 自述其为「目标=va_list 的必然结果」）；P-14（probe_selftest）= 未上机 → 其覆盖的 PF/c2u/cfu/uw 阴性全部 **E0/E1**。


## 2. 详细登记

### P-01 `va_scan.py`（新，已本地验证）

- **测量对象**：16KB 栈转储里 fault-time va_list 处的 32 字节；不是“扫描到的第一个记录”。
- **方法**：从 `siginfo`（`11,0,1,0` + fault addr）定位 `ucontext`（+0x130），取 `regs[2]` = fault-time x2；读 x2 处 32 字节；再读 x2-0x240 的更深副本。
- **分类**：`A0B2` / `B0A2` / `other`；tag-aware 比较 `untag(w0-8) == untag(addr)`。
- **正对照**：本地 106 份 `h3b` + `v3l`，断言 `71/32/3`；`--legacy` 复现旧 0x780 的 `71/35`。
- **已知限制**：只适用于 `vsurv3` 的 16KB 格式（header base/top + 4 pages + siginfo/ucontext）；自然 core 用 P-02。
- **状态**：OK；文件 [va_scan.py](../../tools/oneoff/sigsegv/va_scan.py)。

### P-02 `core_scan.py`（新，已本地验证）

- **测量对象**：完整 core 的 fault-time x2 处 32 字节；NT_PRSTATUS/NT_SIGINFO。
- **正对照**：`an2/c27830/36/9409/r11228/r3850`（A0B2）、`c27834`（B0A2）、`round_logc/pf.core`（A0B2）、`sh.core`（记录在场但 NULL）。
- **已知限制**：core 的 PT_LOAD 可能不含完整栈；自然 core 的“没有记录”不能当“记录不在”。
- **状态**：OK；文件 [core_scan.py](../../tools/oneoff/sigsegv/core_scan.py)。

### P-03 `vsurv4`（新 canary，STAGED）

- **目的**：替代 `vsurv3`，消除 handler 的二次污染/递归。
- **改动**：`sigaltstack`；handler 不调用 `snprintf/open/read /proc`；只用 `open/write/close/time`；手动整数格式化；缓存 `start_stack`；`SA_ONSTACK` 不带 `SA_NODEFER`；`g_in_handler` 递归守卫；固定二进制头 + 4 页栈。
- **正对照**：设备上 `raise(SIGSEGV)` 自测，确认 header 的 `addr/pc/sp/x2/x8` 与 `siginfo/ucontext` 一致；再跑 `snprintf` 循环。
- **状态**：源码/编译通过；设备测试待做。文件 [vsurv4.c](../../tools/oneoff/sigsegv/vsurv4.c)。

### P-04 `stackdump` + `core_meta v1.7`（自然 NE 栈快照，STAGED）

- **目的**：让**自然** NE（busybox/ip/logread）也有 fault-time 栈窗口，用于“记录 vs 非记录”分类。
- **方法**：`core_meta.sh` 在写元数据/TSV 后，调用 `/data/gw/bin/stackdump <pid> <out> 16`；`stackdump` 读 `/proc/<pid>/maps` 的 `[stack]`，`pread` 最后 16 页，写 header + pages。
- **正对照**：对一个已知 `vsurv4` 进程手动调用，确认 dump 里的 va_list 地址/记录与 P-01 一致。
- **状态**：源码/编译通过；`core_meta_v1.7.sh` staged；部署前 bump `core_meta` 版本 + `chmod 755`。
- **注意**：`core_meta.sh` 是 core_pattern helper，栈快照必须在读 core 之前/同时完成；不要让它阻塞太久（16 页 = 64KB，毫秒级）。

### P-05 `cth`（COND）

- **测什么**：`__arch_copy_to_user`、`_copy_to_user+8`、`__arch_copy_from_user` 的 dst 误用、`do_page_fault`。
- **正对照**：`ac2u` 78 命中（`rt_sigaction` n=0x20）；`c2u` 只有 `cself getcwd n=6`；`cfu`/`pf` 无。
- **缺陷**：
  - `g_c2u_calls` 从未自增；`ac2u_calls` 是两个 hook 合计。
  - `g_hit` 上限 4000；200+ 崩溃窗口可能饱和；必须报告总命中/是否饱和。
  - `c2u n=32` 无正对照；`cfu` 无正对照；`pf` 无正对照。
  - `pf_lo/pf_hi` 用 raw FAR；带 tag 的 fault 可能漏。
  - `cfu` 只覆盖 `copy_from_user` dst 误用，不覆盖 `memcpy` 到用户指针。
- **状态**：COND；阴性只对“已 hook 路径”成立。
- **修复**：P-14 正对照；报告 `g_hit`/饱和；加 `c2u n=32` 用例；PF 用带/不带 tag 两个地址。

### P-06 `uw`（BROKEN，不能点名写者）

- **测什么**：`uaccess_ttbr0_enable/disable` 克隆的**开窗者**，不是窗口内的 store。
- **缺陷**：
  - `lr` 是克隆的调用者返回地址；如果开窗者调用 `memcpy`，写者在 `memcpy` 里，`lr` 仍指向开窗者。
  - 300 站点从未成功；125–130 因累积效应（160B trampoline + 调用）坏；`[125,130]` 单独好。
  - `irq_only=1` 漏 kworker/borrowed-mm；`uw_in[64]` 吞嵌套；`usp_lo/usp_hi` 可能误杀。
  - `autorevert=20s` 把观测窗限制在 20s；对 ~1/min 写者 LOD 很差。
- **状态**：BROKEN 作为“写者定位器”；仅可作为“中断上下文开窗者”筛查。
- **修复**：64B trampoline；per-CPU 深度计数；记录 `site/lr/caller/usp/depth`；`irq_only` 可配；`uw_keep` 记录实际时长；先 5/50/125 分级，不追 300。

### P-07 `remap`/`remapu`（BROKEN，uaccess 唯一阳性但未证明）

- **测什么**：线性别名 vs 用户 PTE vs 物理页。
- **缺陷**：改活栈 PTE 本身可致崩；无“重定向后稳定 60s”的对照；`remapu` 的 P0=0 不能区分“用户 PTE”与“线性别名被改指到影子”；`remap` 的自检只验别名，不验受害者稳定性。
- **状态**：BROKEN；不得作为 E2+ 的 uaccess 证据。
- **修复**：P-07 三哨兵（见 05_LOG 的预注册）。

### P-08 `vro`（COND，不是“执行绑定”判别器）

- **测什么**：只读栈页上的 kernel fault。
- **缺陷**：`PROT_READ` 只挡用户 PTE；线性别名仍可写；`vro` 没有 va_list；0/12 是“目标=va_list”的必然结果，不是“执行绑定”的独立证据；PF hook 未正对照。
- **状态**：COND；只能说明“写入与 va_list/printf 路径相关”，不能说明“中断上下文”。

### P-09 `vprobe`（COND）

- **测什么**：任意 live va_list 的写入。
- **缺陷**：无 N/LOD；30ms 窗口；深层 va_list 0 命中可能只说明“目标不是任意 va_list”。
- **状态**：COND；0 命中只能标 E1。

### P-10 `pwatch`/`va2pa`（COND）

- **测什么**：指定 PA 的内容变化。
- **缺陷**：`pin_user_pages_remote` 改变页生命周期/refcount；单页单次；§22 的“日志文本”解释两次翻转。
- **状态**：COND；需要对照页 + pin 计数 + 同刻寄存器。

### P-11 `pfcanary`（COND）

- **测什么**：崩溃率代理。
- **缺陷**：handler 自己 `snprintf`；崩溃计数含 handler 受害；4 实例 5.3x 不是 1:1；非自然人口。
- **状态**：COND；速率不能外推到自然 NE。

### P-12 `core_meta`/`ne_events`（OK device，far/pc 轮）

- **测什么**：崩溃台账/元数据（v1.13 起行含 far=/pc=，来源 = core note 头：
  NT_SIGINFO si_addr + NT_PRSTATUS pc，偏移在真实设备 .hdr 上实证，与 P-02 解析一致）。
- **正对照（2026-11-01 设备实弹）**：测试自杀进程（/tmp/a1crash，向 0x5151dead000 写入）
  → ne_events 行 `far=0x5151dead000 pc=0x101087c`；反汇编证明 0x101087c 正是
  `str x9,[x8]`（x8=0x5151dead000）——far/pc 与二进制级真值一致；设备侧对
  同事件 .hdr 复跑 coreaddr 输出同值；自然 NE 同批也带 far/pc
  （cfg_heal sh: far=0x16ca4；aee_aed: far=0x7f98845568）。
- **缺陷**：aee 去重；`core_trap` 已停用（好），但历史盲窗仍在数据里；`unsync` 行；
  `origin` 可能 unknown；far/pc 依赖 coreaddr 在场且 note 段落在 core 前 8KB
  （多线程大 note 段截断 → 空列回退，不写坏行）；列数 10/11 与旧 8/9 并存
  （incident_ledger v1.6+/retention_audit v1.4+ 放行）。
- **状态**：OK (device)；不是 census。

### P-13 `vaguard.tsv`（COND）

- **测什么**：闸门命中。
- **缺陷**：首命中 + 每 256 次一行；`hits` 是累计值；3 次是下限。
- **状态**：COND；不能与 NE 直接相除。

### P-14 `probe_selftest`（STAGED）

- **目的**：给 PF/c2u/cfu/uw 各一个**故意触发**。
- **用例**：
  - PF：用户 `mmap` 一页 + `mprotect(PROT_READ)`；模块 `copy_to_user(va, buf, 32)`；`cth_pf` 应记录 `far`/`pc`。
  - c2u：模块直接调用 `_copy_to_user(va, buf, 32)`（若符号可导出）或用户态触发 n=32 的 `_copy_to_user`；`cth_hook` 应记录 n=0x20。
  - cfu：模块 `copy_from_user(dst=user_va, src=kernel_buf, 32)`；`cth_cfu` 应记录。
  - uw：hrtimer/tasklet 上下文对**已 pin/已存在**的用户页做 `copy_to_user`；`uw_hook` 应记录 `ENABLE` site。
- **状态**：设计/源码骨架；设备测试待做。

### P-19 `kmsglog`（/dev/kmsg 持久镜像，OK device）

- **目的**：arm64 用户态 fault 行是 pr_info，console_loglevel=4 下 console/syslog 都收不到；
  本机 (5.15 arm64) 的 show_unhandled_signals 实际暴露为 `/proc/sys/debug/exception-trace`
  （实测 2026-11-01，`kernel/show_unhandled_signals` 路径不存在），rc.extend v3.8 起每 boot 武装。
  kmsglog 直读 `/dev/kmsg`（按环全量、与 loglevel 无关）落 `/data/gw/logs/kmsg.log`。
- **方法**：SEEK_END 起只收新记录；批 ≤64KB；**写前守卫**（每次 write 前 statvfs /data，
  <100MB 先轮转再写——2026-11-01 满盘 60s 教训）；8MB×2 轮转；写失败按 seq 回卷游标重试
  （不丢不推进）；`--selftest` 验证按 seq 回卷原语。
- **正对照（2026-11-01 设备实弹）**：自杀进程事件链的 aee_aed pr_info 行
  （`pid: 28797 ... >>> /tmp/a1crash <<<` 等，prio=6）落 kmsg.log —— 证明与
  console_loglevel 无关的环全量捕获；`--selftest` 游标回卷原语（SEEK_SET0+按 seq
  前跳）设备 PASS。`unhandled ... fault (11)` 行本身**在 nerepair 在役时结构性缺席**
  （实测全 pid TracerPid=nerepair；arm64 `unhandled_signal()` 要求 `!tsk->ptrace`），
  FAR 权威来源是 P-12 far/pc 列，不是 kmsg。
- **已知限制**：只收启动后新记录（开机 backlog 归 console-ramoops/pstore 口径）；环溢出丢行
  （SEQ 缺口在日志内自证，可审计）；日志有界（8MB×2），风暴下最老记录被轮转掉。
- **状态**：OK (device)；文件 `gw/src/kmsglog.c`（二进制 `/data/gw/bin/kmsglog`，rc.extend v3.8+ 自启）。

## 3. 仪器使用纪律

1. 先正对照，再采信阴性。
2. 先报 N/LOD/饱和，再报 0。
3. 先确认 arming 窗口，再报“没有”。
4. 先确认观测者效应（栈/PTE/pin/dump_stack），再报“差异”。
5. 先确认日志完整性（时间戳/丢行/截断），再报“速率”。
6. 任何仪器改动 → 更新本表 + 重新正对照；旧数据不得与新仪器混算。

## 4. 本轮（2026-11-02/03）仪器增补（收束登记）

> 补记原则：只登记"其结果已被 `01_CLAIMS.tsv` 引用"的仪器；细节/正对照/缺陷史见各自 review 与 claims 证据列。
> 本表不改变 §3 纪律：引用阴性必须同时引用覆盖边界。

| ID | 探针 | 测什么 | 窗口规模 | 正对照 | 状态 | claims/复核 |
|---|---|---|---|---|---|---|
| P-20 | `funnelcatcher`（v1；`__arch_copy_to_user` 入口漏斗 + 族内容判据） | CPU uaccess 是否携带记录族 | 热窗 1230 s（191 MB 客户端流量） | 2/2（lr=copyout+0x3c，fp 链完整） | OK（退役） | C-206；阴性=已测未发现 |
| P-21 | `funnelv2` **v2.1**（漏斗 + 嵌入大拷贝宽扫描；ko `7943ded5…`） | 同上 + 大拷贝内嵌路径 | 1358 s / 20.2M 调用 / 2.77M 扫描 / 735.8 MB 源 | 窗内 7/7 | OK | C-214；**宽扫描形状代理 ≈148/s 误报 ⇒ 特异性失效（判据须加 lr 黑名单/族统计门）** |
| P-22 | `tuphook` **v1.6**（mtk_warp/wed tuple fill 入口 + 栈目标采集） | fill 链路 store 目标 | live 7409 调用 / 4 CPU；v1.6 106 s / 21 样本 / 3047 fill | dryrun + 站点读回原字 | OK | C-197/211/212；4 缺陷 2 oops 的修复史 = C-198 |
| P-23 | `dmahook`（`dma_map_page_attrs`/`dma_map_sg_attrs` 入口 + 伪页过滤） | DMA map 是否含受害页 | 1825 s 背景窗（+900 s 站点窗） | dryrun + selftest（PAGE/SG 各 1） | OK | C-207；**边界=只两变体、非热态** |
| P-24 | `dieblx`（die/panic notifier 黑匣子） | 仪器事故全事件落盘 | 全事故现场 | 多次实弹 | OK | 仪器事故取证依赖（C-198 等） |
| P-25 | `wdkill`/`wdone`（mt_wifi copy_to_user 站点 stub 杀开关/一次性恢复） | 站点级行为消融 | 三窗 900 s | 站点读回原字 | OK | C-202/203 |
| P-26 | `uacatcher`（D20；mt_wifi 12 站点捕获） | 站点调用观测 | 热窗 900 s | 12/12 站点验证 | OK | C-200/C-203（E4 级观测） |
| P-27 | `auditwatch`（audit netlink 客户端 + `vmpoke` 正对照） | 用户态 `process_vm_*` 跨进程写 | 30 min 窗 | 3/3 | OK（on-device） | C-189；**边界：只覆盖 audit-on 后 fork 的进程；不含 ptrace=117** |
| P-28 | `scanary`/`vsurv4`/`vsurv5`（自扫描金丝雀） | 记录写入探测（崩不崩都记） | 多臂（900 s 深度臂等） | 自检注入 + 诱饵区 0 | OK | C-137/171/191/199/209 |
| P-29 | `sampler2`（用户态槽采样，无模块） | 写入活性（单位时间内容变化） | 600 s / 25 进程 / 43 槽 | 内容恒定/变化自证 | OK | C-175 系 / C-199 / C-204 基线 |
| P-30 | `patrace`/`pascan2`/`rxcount`/`arrwatch`/`rangescan` | VA→PA / 按值搜 / 环位 / 数组 / 范围 | 各自窗口 | 各自（部分自带；见历史 P-15/P-16/P-17 缺口） | COND/有限 | 见各自 review 与 claims |