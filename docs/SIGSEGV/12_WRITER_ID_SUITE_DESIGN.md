# 12 · 写入者点名收口仪器组（设计 v1.0，2026-11-04）

> **目标一句话**：部署本组仪器、跑完本设计规定的联合窗战役后，落点只有两个——
> **终局 A：写入者被精确点名（E4）**；**终局 B：写入者被证明不在软件可达区域（E3）**。
> 不允许第三个落点；若中途器件不可用/功效不足，只能写「残余未覆盖清单」，不得宣称收口。
>
> 本文是**设计**，不是结果；执行必须逐臂预注册（02_METHOD §2 模板）+ skeptic 审查。
> 前置事实链：[U-A2](../review/U-A2_PULSE_RESULT_2026-11-04.md)（PTE 门控，非 DMA）
> / [U-B1](../review/U-B1_FXHOOK_RESULT_2026-11-04.md)（不经 ex_table）
> / [U-C1](../review/U-C1_WRHUNT_RESULT_2026-11-04.md)（remote-GUP/缺页五路阴性）
> / [U-D1](../review/U-D1_RESULT_LOWRISK_2026-11-04.md)（唯一槽位 sp_call−0x100 + 记录=最近包元数据）
> / [U-E1](../review/U-E1_RESULT_PULSE_FXHOOK_2026-11-04.md)（盲目 uaccess store 排除）。
> 方法与统计纪律：[02_METHOD.md](02_METHOD.md)、[10_MEASUREMENT_PROTOCOL.md](10_MEASUREMENT_PROTOCOL.md)。

## 0. 为什么现在是收口窗口

今晚（2026-11-04）五轮合取后，写入者的机制画像已足够窄：

| # | 已钉死的约束 | 等级 | 来源 |
|---|---|---|---|
| K1 | 写入被 PTE 权限位门控（RO 脉冲抑制 ≥25×，相位锁定可写窗）——**非 MMU-blind DMA** | E3 | U-A2 |
| K2 | 不经 `fixup_exception`（两窗 0 调用，落地记录 13+61 条）——**写前检查可写性，失败不 fault** | E2/E3 | U-B1、U-E1 |
| K3 | 不经 remote-GUP（`__access_remote_vm`/`get_user_pages_remote`/`pin_user_pages_remote` 154K/696K/2 次调用 0 命中）、不经缺页路径（H4 12.7M 次 0 命中） | E2 | U-C1 |
| K4 | 非 VA 数值定向（同 VA 诱饵 0/116K passes）；需 victim 深帧/变参调用在位（纯自旋 0，busy hold 483/600 s） | E2 | U-D1 E1/E3/E3b |
| K5 | 落点 = `sp_call−0x100` 单槽反复重写；内容 = **最近真实 IP 包元数据**（±20 ms 内 169/173 匹配，双向含 LAN；len=skb/GRO 长） | E2 | U-D1 E2/E5 |
| K6 | 速率随 victim 所在 CPU 的网络负载 ~3×；写者持有或能取到最近 skb 元数据 | E2 | U-D1 E4 |
| K7 | 写入需要厂商内核态环境（lab 6.18 零写入）；随客户端数据面流量放缩 | E2 | C-213/C-204 |
| K8 | 非"盲目 uaccess store"（`copy_to_user`/`__put_user`/内联 sttr 若为写者，RO 窗内必然 fixup——实测 0） | E2 | U-E1 |

**剩余机制空间只有五族**（U-E1 §4 口径 + 补全）：

| 分支 | 机制 | 与 K1–K8 相容性 |
|---|---|---|
| **B1 GUP 族** | victim 上下文内非 remote `get_user_pages`/`*_fast`/`pin_*`/`follow_page` 取页后经别名写 | ✅（FOLL_WRITE 在 RO 上静默 -EFAULT = K1/K2） |
| **B2 VMA-check + 别名 store** | 写者读 `vma->vm_flags`/手翻页表确认可写，再经 `page_address()`/kmap 线性别名普通 store | ✅（先检查后写 = K1/K2；不经 GUP = B1 之外） |
| **B3 EL0 写者** | victim mm 内的外来用户态代码（注入库/printf 钩子类），只在可写期写、从不 fault | ⚠️ 相容但需解释相位知识来源（见 §6 DIS-2） |
| **B4 PTE-walk + DMA 编程** | 软件现查 PTE/权限 → 把 {victim PA, 包元数据} 写进某 DMA 环 → 引擎代写 | ✅（检查在软件、store 在 DMA；K5/K6 天然满足） |
| **B5 EL2/EL3/自主硬件** | 内核软件边界之外（安全世界/自走总线主，行为上"懂" stage-1 权限） | ✅（兜底分支） |

（EL1 直 store 到用户 VA 被 `CONFIG_ARM64_PAN=y`（U-B1 v3 探针实证）物理排除；remote 用户态写入被 K3 + E6「栈 rw-p 私有匿名无别名」排除。）

## 1. 终局判据（先写死，防漂移）

### 终局 A · 点名（目标等级 E4）

任一相机给出**身份元组** `{pc 或 lr 或 comm 或 引擎+描述符}`，且满足：

1. **排除自指**：身份 ∉ {仪器自身与 helper，victim 已知文本（scanary/musl 静态段），正对照注入}；
2. **独立复现**：第二个联合窗内同身份再次命中（或同一窗内 ≥3 次）；
3. **因果闭环**：对点名对象做定向压制（卸载/门控/防火墙该路径）后，同状态 λ 臂显示
   写入率 → 0（预注册功效：压制后 ≥2×窗口时长，0 命中且 λ 前臂 ≥10/600 s）。

满足 1+2 = E3 级点名；1+2+3 = **E4 终局**。

### 终局 B · 不在软件可达区域（目标等级 E3）

一个**联合窗**内**同时**成立以下五条（缺一不得宣 B）：

1. **暴露达标**：λ 前臂（同状态 RW）≥10/600 s；窗内落地家族记录 ≥30 条；
2. **相机全 armed**：§3 矩阵中覆盖 B1–B4 的全部相机同时在位，各自活性计数 >0
   （证明钩子活着、过滤器在工作）；
3. **窗内正对照全过**：每台相机的正对照在 armed 态命中、disarmed 态零增（U-C1 P1–P4 式双向）；
4. **零命中**：所有相机 ring 内无任何非自指条目，并按 02_METHOD §4.3 报 LOD；
5. **无自发 oops**（排除相机自身致死把窗弄脏）。

⇒ 结论句（固定表述）：
> 写入不经 {EL0 store（B3）、EL1 uaccess、EL1 线性别名 store（B1/B2 的 store 端）、
> 描述符驱动的 DMA（B4）} 中任何一条**内核软件可观测/可归因的路径**；结合 K1（权限感知），
> 写入者位于内核软件边界之外（EL2/EL3/安全侧/自主总线主），即**不在软件可达区域**。

B 的残句必须带：覆盖边界 = 各相机正对照所证明的检出域；未覆盖 = 结构性盲区清单（若有）。

## 2. 覆盖代数（机制分支 × 相机矩阵）

**设计原理：每个剩余分支必须有 ≥1 台"能看见它"的相机，且该相机的检出能力在同一窗内被
正对照证明。** 相机间允许重叠（双保险），不允许空档。

| 分支 | 首选相机（点名方式） | 次选/佐证 | 正对照（窗内执行） |
|---|---|---|---|
| **B1 GUP 族** | **CAM-G**：非 remote GUP 六入口钩，`lr`=写者函数返回址 | CAM-R（别名 store 端 abort 佐证） | `vmwrite32` 走 `process_vm_writev` 命中同族入口（U-C1 P1 复用）+ `vmsplice` 探针走 `internal_get_user_pages_fast`（U-E1 §6 既议） |
| **B2 VMA-check + 别名 store** | **CAM-R**（romap）：线性别名置 RO，任何别名 store → data abort，**Oops PC 即点名**（pstore 取证，牺牲性） | CAM-G（若 walker 走标准 API 则先命中）；DIS-1（fresh/stale 判别） | 牺牲性正对照：armed 态用 `mempoke`（pwrite /proc/pid/mem → `__access_remote_vm` kmap 拷贝路径）触发**预期 oops**，pstore PC 应落 `copy_to_user_page` 路径——该对照单独短窗执行，事后强制冷启 |
| **B3 EL0 写者** | **CAM-W**（wpwatch）：对槽位 4×8B 硬件观察点（EL0+EL1 匹配），**store PC + comm 直接点名** | **CAM-P**（profcanary：victim 内 SIGPROF 自采样 pc 直方图）；**CAM-E**（脉冲臂 fault-pc 全量直方图 + 旧日志回溯审计） | victim 自身 `va_start`/`va_arg` 写槽位 = 连续在位自校准（已知 pc 集合）；`roprobe` 变体（RW 页 read(/dev/zero)→`__arch_clear_user` sttr）= EL1 端校准 |
| **B4 PTE-walk + DMA** | **CAM-D**（命中同步环取证）：低流量窗 + 每次落地记录后 ≤1 s dump 全部 DMA 环/描述符区，搜 victim 页 PA——**持有该 PA 的引擎即点名**，再离线 RE 到代码点 | **DIS-1**（PTE 迁移：fresh-follow 换页 vs stale 缓存旧页）；CAM-G（walker 若走 follow_page/follow_pte） | 取证管道正对照：把 victim PA 植入本组自建的 dummy 环缓冲，触发同一次 dump，扫描必须命中且定位正确（不动真环） |
| **B5 EL2/EL3/自主硬件** | 无相机（= 终局 B 的余项） | DIS-1/DIS-2 的结果用于收窄 B5 的表述 | — |

**两台判别臂（不给身份、给机制分类，服务 A 的因果段与 B 的表述）**：

- **DIS-1 PTE 迁移判别**（victim 驱动：存帧 → `madvise(DONTNEED)` → 复建帧 → patrace 证新 PA）：
  写者 fresh-follow（跟到新 PA）⇒ 现查页表（B1/B2/B4-fresh）；stale（旧 PA 仍被写，pascan 读旧页）
  ⇒ 缓存 PA（与 K4/D9 几何冲突，出现即翻案，预注册写出处置）。
- **DIS-2 相位随机脉冲**（ON/OFF 时长 0.5–3 ms 均匀随机，均值占空 ~50%）：
  解 U-A2 §4.3 混杂——权限门控写者 ON-fraction 仍 ≈0；调用相位门控写者 ON-fraction → ~占空。
  这同时是 CAM-W 的标准运行窗（随机相位下任何预测式写者必然撞 ON ⇒ fault/store 被抓）。

## 3. 相机规格

通用契约（每台相机必须逐条回答 02_METHOD §3 探针有效性清单）：
bl 站点 patch 手法沿用 wrhunt v3–v5/fxhook v5 已验证形态（占位 `b .` + init 回填 + 反解自检 +
rmmod 逐点回读）；异常/热路径内 **O(1)、零分配、per-CPU ring、无锁写**；单实例断言；
五元组（名/长/md5/sha256/构建命令）入档；卸载回读全绿才许结束窗口。

### CAM-0 普查（用户态，零内核风险）

`/etc/ld.so.preload` 存在性；全进程 `/proc/*/environ` 的 LD_PRELOAD；长驻守护 maps 异常
（`memfd:`/`[deleted]`/非标准路径 .so）；高频道读者普查（谁在轮询 /proc/*/maps|smaps）。
**目的**：把 B3 的"外来代码从哪来"先验清掉。产出普查表，异常条目离线 RE。

### CAM-G · 非 remote GUP 族入口钩（wrhunt v4 扩展 = U-C1 §4 既议 H6/H7）

- **入口集（符号已于 2026-11-04 22:4x 上机核验全 FOUND）**：
  `get_user_pages`、`__get_user_pages`、`internal_get_user_pages_fast`、`pin_user_pages`、
  `pin_user_pages_fast`、`get_user_pages_unlocked`、`follow_page_mask`、`follow_pte`。
- **过滤**：`current->mm ?: current->active_mm` == victim mm（kthread 借用 mm 情形，
  U-C1 §4 既议）∧ `start..start+nr` 覆盖守护页。
- **记录**：`{入口, start, nr, gup_flags(FOLL_WRITE/FOLL_PIN), lr, comm, pid, ts}`；
  `lr` 即写者函数返回址——**单条命中即 E3 级点名**。
- **风险**：`internal_get_user_pages_fast` 热度高于 H1–H3；shim 必须 ≤10 指令 +
  per-CPU 计数 + armed 过滤前置（沿用 v5 手法）。

### CAM-R · romap 线性别名相机（牺牲性点名）

romap.ko（在档 `314974d6…`）复活 + 联合窗集成：GUP-pin 守护页（防迁移/换页把别名判据弄脏）
→ 线性别名 PTE 置 RO → 窗内任何 kmap/`page_address` store → data abort → Oops（pstore 留
PC/LR/comm）→ 冷启恢复（LK 路径预注册）。**预期 oops 不是事故，是点名动作**——预注册必须写明
"本臂以一次计划内重启换取身份"；合法别名读者（nerepair process_vm_readv 只读）不触发。
窗长上限 600 s（λ≥10/600 s 时期望 ≥100 落地，足够）。

### CAM-W · wpwatch 硬件观察点相机（Tier B：直写调试寄存器）

**预检已证**（2026-11-04 22:4x）：本内核**无 perf core、无 hw_breakpoint 框架**
（`perf_event_create_kernel_counter`/`perf_bp_event`/`hw_breakpoint_handler` kallsyms 全
MISSING、`/sys/bus/event_source/devices` 空）⇒ 不能走 perf 内核计数器；CPU = 4×Cortex-A53
（architected debug，WRPS 预期 4 槽）。故 Tier B 规格：

1. 模块在 4 CPU 上直写 `DBGWVRn/DBGWCRn`（BAS=8B，PAC=EL0+EL1，load/store 均、
   地址匹配），监视频槽位 w0/w1/w2/w3（=4 槽满配；w3 含 victim `__gr_offs` 自写噪声，
   由 pc 分类吸收）；
2. 拦截分发：`do_debug_exception`（kallsyms FOUND）内 WATCHPT EC 分发前 bl 站点接管；
   未见框架 ⇒ 原生路径对本异常大概率 `do_bad`→die，必须由相机接管；
3. **步过引擎**：命中记录 `{pc, comm, tgid, mm, DBGFAR, ts}` 后临时 disable 本槽 →
   置 MDSCR_EL1.SS + PSTATE SS 单步执行该指令 → SS 异常回调中恢复观察点
   （复刻 arm64 hw_breakpoint 语义，模块内实现）；
4. mm 条件启停：`__switch_to`（FOUND）bl 站点，`next->mm != victim_mm` 时清 enable 位
   （防跨进程同 VA 假阳性——U-C1 v3 教训的观察点版）；
5. 自校准：victim `va_start`/`va_arg` 写槽（已知 pc 集）连续命中 = 相机存活证明；
   `roprobe`-RW 变体 = EL1 端校准。
**风险最高件**（异常上下文 + 单步 + 调试寄存器）：只允许进 S4，skeptic 双签 + LK 救砖 +
首次装载限 60 s 冒烟。若预检发现 WRPS<4 或自校准不绿 → **B3 降级为 CAM-P+CAM-E+逻辑闭合**
（见 §6 判决树注 2），终局 B 的表述相应收窄。

### CAM-P · profcanary（victim 内自采样直方图，零内核件）

scanary v25 增模式：调用窗内 SIGPROF 高频采样，记 pc 直方图（1 ms，内核无参与）。
任何落在 victim 已知文本 ∪ musl 静态段 ∪ vDSO 之外的 pc 峰值 = **B3 直接证据**
（pc + 当时 /proc/self/maps 反查归属模块）。限制：采样率对短驻写者覆盖有限，
只作 B3 的正向证据源，阴性不排除。

### CAM-E · fault-pc 直方图 + 回溯审计（半免费）

- 前向：scanary v25 把脉冲臂 `PULSE_VFAULT` 从采样 1/10000 改为**全量 pc 直方图**
  （异常 handler 内 `ucontext->pc` 归桶，无 IO）——任何非已知自写 pc 的 fault 即 B3 的
  "探测式写者"现形（RO 窗内试探 = fault = 被点名）；
- 回溯：审计既有 `ua2_pulse.log`/`ue1_victim.log` 采样条目的 pc 是否 100% ∈ 已知自写集。

### CAM-D · 命中同步环取证（B4 点名主相机）

低流量窗（λ 3–10/min，环周转慢——20kpps 时描述符寿命 ~50 µs，而 λ 低流量时环条目寿命
秒级，**这是对 00_STATE §14.1 rxring 三阴性的工况修正，不是重跑旧实验**）：

1. scanner 每检出一笔落地记录 → 立即（同进程，≤1 s）触发取证：dump 已知全部 DMA 环
   （FE/PPE/WED/WO/EDMA×2，`edma dump` + dpreg MMIO 读环基）+ `pascan` 全 RAM 搜
   **victim 页 PA**（自建 dummy 环植入作管道正对照）；
2. 命中环 → 引擎点名 → 离线 RE 该引擎驱动定位写环的代码点（mtk_warp 738KB 未扫区是
   首选——00_STATE §8 既列）；
3. 与 DIS-1 合取：fresh-follow + 环命中 ⇒ B4 链条闭合（E4）。

## 4. 战役计划（S0–S4 分级；每级独立预注册）

| 级 | 内容 | 新内核风险 | 产出 |
|---|---|---|---|
| **S0 预检** | 已完成项见 §5（今晚实测）；待办：WRPS 槽数读取（CAM-W 冒烟件内）、`edma dump`/dpreg 在低流量态的环可见性、scanary v25 构建+host 自测 | 零 | 预检表（本文 §5 起头，逐次追加） |
| **S1 零风险层** | CAM-0 普查 + CAM-E 回溯审计 + CAM-P 试跑（600 s，RW，无脉冲） | 零 | 异常普查表；B3 先验收窄；可能直接终局 A（若外来 pc 峰现形） |
| **S2 联合窗 Ⅰ** | CAM-G（六入口）+ fxhook v6 常开 + CAM-E 前向 + scanary 脉冲臂；λ 前后臂 bracket；窗 1200 s | 低（手法全验证） | B1 判决：命中 lr ⇒ 候选终局 A；零命中 ⇒ B1 出局（带 LOD） |
| **S3 联合窗 Ⅱ** | CAM-D 低流量窗 + DIS-1 迁移臂；（S2 零命中后）CAM-R 牺牲臂独立短窗 | 中（romap 计划内 oops 一次） | B4 判决 + B2 store 端点名/排除 |
| **S4 联合窗 Ⅲ（终局窗）** | CAM-W Tier B + 全部可共存相机同窗；DIS-2 随机相位 | 高（skeptic 双签） | B3 判决；若全绿零命中 → **终局 B** |
| **S5 因果闭环** | （仅终局 A 路径）对点名对象定向压制 → λ→0 复验 | 视对象 | E4 收口；转 R1 修复或 SLOTGUARD 布防评估 |

**每窗共同协议**（硬规则，缺一窗废）：

1. λ 前臂同状态 RW ≥10/600 s，不足不开窗（U-A1 §0.0 设计级前置）；
2. 暴露核算表预注册（λ×窗长×占空，期望 ≥30 落地）；
3. NE 台账窗前后对账 + nerepair 全程 dry + 单实例断言；
4. 时间锚 `date +%s` 双侧记录；流量协变量按 10_MEASUREMENT_PROTOCOL §4 采集；
5. 装载序：devop 持锁 → insmod → 10 min 零实验观察 → 正对照（armed/disarmed 双向）
   → 实验窗 → 回读卸载全绿 → 拉取（行数+字段数+md5 三断言）；
6. LK 救砖路径（tools/lk_flash_v4.py）在每个含内核件的窗口预注册中引用；
7. 停止规则：任何相机活性计数=0、自指 oops、guard band 违例 → 该窗作废重开。

## 5. S0 预检已核项（2026-11-04 22:40–22:50，lgssh 只读实测）

| 项 | 值 | 影响 |
|---|---|---|
| 内核 | `Linux OpenWrt 5.15.134 #0 SMP aarch64` | 全部手法按 5.15 arm64 口径 |
| CPU | 4×（`Features: fp asimd … lrcpc dcpop`，A53 级） | CAM-W per-CPU 4 份；WRPS 待冒烟确认 |
| perf/hw_breakpoint | **无**（perf 系符号全 MISSING、event_source 目录空） | CAM-W 只能 Tier B（直写调试寄存器） |
| PAN | =y（U-B1 v3 探针实证） | EL1 直 store 用户 VA 物理排除，§0 B 表合法 |
| kptr_restrict | 0 | kallsyms 地址可用，bl 站点解析链不变 |
| `/proc/config.gz` | 无 | CONFIG 清单以符号/行为探测为准 |
| H7 入口符号 | `get_user_pages`/`__get_user_pages`/`internal_get_user_pages_fast`/`pin_user_pages`/`pin_user_pages_fast`/`get_user_pages_unlocked`/`follow_page_mask`/`follow_pte` **全 FOUND** | CAM-G 入口集冻结 |
| 既有入口符号 | `do_page_fault`/`fixup_exception`/`__arch_copy_to_user`/`__access_remote_vm`/`get_user_pages_remote`/`pin_user_pages_remote`/`do_debug_exception`/`__switch_to` 全 FOUND | wrhunt/fxhook/romap/wpwatch 解析链可用 |

## 6. 判决树

```
S1: CAM-0/E/P
 ├─ 外来 pc/异常条目 ──────────────→ 候选终局 A（S5 因果闭环）
 └─ 阴性 ↓
S2: CAM-G 联合窗
 ├─ lr 命中（非自指）──────────────→ 候选终局 A
 └─ 0 命中（活性计数>0, LOD 达标）→ B1 出局 ↓
S3: CAM-D + DIS-1 (+CAM-R)
 ├─ 环持 victim PA / romap abort PC → 候选终局 A（B2/B4；RE 定代码点）
 ├─ DIS-1 stale（旧 PA 仍被写）──→ 翻案分支：缓存 PA 模型复活，
 │                                    预注册处置（重跑 D9 几何 + 环取证追旧 PA 持有者）
 └─ 双阴性 ───────────────────────→ B2/B4 的可观测路径出局 ↓
S4: CAM-W 终局窗（+DIS-2）
 ├─ store PC 命中 ────────────────→ 候选终局 A（B3）
 ├─ DIS-2 = 调用相位门控 ─────────→ B3 重新加权（写者挂调用相位，非权限感知；
 │                                    S2/S3 的阴性不受影响，B5 表述调整）
 ├─ DIS-2 = 权限门控 + CAM-W 零命中→ **终局 B**（§1 五条全满足时）
 └─ CAM-W 器件不可用/不绿 ────────→ 降级终局：B3 未闭合，
      结论 = "B1/B2/B4 已出局；B3/B5 待 CAM-W 修复后判决"（不得宣 B）
```

**注**：
1. 任一级出候选 A 即停止升级、转 S5；S5 压制失败 ⇒ 该候选降级重查（预注册写明）。
2. CAM-W 是 B3 与"终局 B 完整性"的唯一缺口闭合件；它不绿时终局 B 不可宣（诚实边界）。
3. 全程遵守 00_STATE §6 停止规则与 10_MEASUREMENT_PROTOCOL 会话内对照律。

## 7. 复用资产表（不重复造轮子）

| 资产 | 出处 | 在本组的角色 |
|---|---|---|
| scanary_ro v21–v24 | tools/oneoff/sigsegv/ | victim 装置（v25 = +pc 直方图 + SIGPROF 采样 + DIS-1/DIS-2 模式） |
| wrhunt v4（mm 双过滤）+ vmwrite32/mempoke | tmpfiles/repro/kmod/ | CAM-G 骨架与 P1/P2 正对照 |
| fxhook v5/v6 + roprobe | 同上 | fixup 常开相机 + CAM-W EL1 校准变体 |
| romap.ko | 同上（`314974d6…`） | CAM-R 本体（复活+集成） |
| pte_redirect/patrace/pascan/rxring/dpreg | 同上 + oneoff | DIS-1 PA 验证 / CAM-D 环取证 |
| λ/暴露核算与预注册模板 | 10_MEASUREMENT_PROTOCOL / TEMPLATE_EXPERIMENT | §4 每窗协议 |
| nerepair/slotguard | gw/bin | 全程 dry / observe（不动） |

## 8. 风险登记（吸取本语料已付学费）

| 风险 | 教训来源 | 对策 |
|---|---|---|
| 热路径钩 O(n) → RCU stall panic | dpquar v1.3（2026-10-22 KE） | 全部 shim O(1) ≤10 指令，过滤前置 |
| percpu 幻影地址写 | fxhook v4 `__this_cpu_inc` 事故 | 一律 `DEFINE_PER_CPU` + 汇总读 |
| zig 链接 GLOBAL UNDEF → insmod 拒载 | fxhook v2/uwhook | `b .` 占位 + init 回填 + 反解自检（v3 手法） |
| VA 数值过滤跨进程假阳性 | wrhunt v3（84 条假阳） | mm 身份门（v4）；CAM-W 加 `__switch_to` 启停 |
| 改活栈 PTE 自崩 | pte_redirect C-174 panic | DIS-1 改为 victim 驱动 madvise，不碰别人 PTE |
| 计划内 oops 被当事故 | —（新） | CAM-R 预注册明示牺牲语义 + pstore 取证单 + 冷启 SOP |
| 观察点自噪声淹没 ring | va_arg 写槽实测 ~10⁵/min 级 | pc 直方图分类 + 每 CPU ring 上限 + 采样降载 |
| 跨会话速率不可比 | 10_PROTOCOL §2 | 一切判读限窗内；λ 前后臂 bracket |
| 无正对照阴性 | C-169 | §1 终局 B 第 3 条硬门 |

## 9. 与仓库纪律的关系

- 全部新件落 `tools/oneoff/sigsegv/`（源码）与 `tmpfiles/repro/kmod/`（构件）——oneoff
  **不进注册表**（防复活为活资产）；五元组在 FIVETUPLE.txt 追加；
- 本文档 = docs/ 可不登记；全文中性命名，leak_check 复核通过；
- 设备侧一切新文件经 deploy.py put（md5 门禁；exec 型脚本 chmod 755 + doctor 复核）。

---

> **状态（2026-11-05 晨）**：S1+S2+S3 已执行——B1/B4c/WED-RXBM 出局（E2）、romap 事故隔离（B2 未判）、
> 全夜 549 条落地。详录 [../review/U-F1_RESULT_SUITE_2026-11-05.md](../review/U-F1_RESULT_SUITE_2026-11-05.md)。
> 下一序 = romap 修复（B2）→ 环 PA 发现 + ringpoll 扩展（B4t）→ CAM-W/DIS-2（B3）。
>
> **执行顺序建议**：S0 收尾 → S1（一夜）→ S2（一夜）→ 按 §6 树走。
> 每级实验日志落 `05_LOG/2026-11-XX-XX-*.md`，结论入 01_CLAIMS.tsv，
> 终局写入 VERDICT v4 并回填本页状态行。
