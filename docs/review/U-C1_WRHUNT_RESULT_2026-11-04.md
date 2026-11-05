# U-C1 · wrhunt 多入口合围：结果报告（仪器验证 + 多路径阴性）

> 日期：2026-11-04 20:30（+0800）｜操作者：U-C1 接手者
> 预注册：[U-C1_PREREG_WRHUNT_2026-11-04.md](U-C1_PREREG_WRHUNT_2026-11-04.md)（v3 修订版，结果前冻结）
> skeptic：两轮审查（[v1 拒绝](U-C1_SKEPTIC_WRHUNT_2026-11-04.md) §0–④ / v2 有条件放行 §⑤）；
> 本地审计：[U-C1_LOCAL_AUDIT_2026-11-04.md](U-C1_LOCAL_AUDIT_2026-11-04.md)（11 候选，Top-1 = GUP 通道）
> 设备：同一 boot（btime 1793736016，全程无重启）；NE 台账对账见 §6。

## 0. 一页结论

**仪器做到并验证了「点名能力」，但本轮写者没有走任何一条被钩的路径。**

1. **装置**：wrhunt v4 单模块 5 入口（H1 `__access_remote_vm` / H2 `get_user_pages_remote` /
   H3 `pin_user_pages_remote`@+8 / H4 `do_page_fault` / H5 `fixup_exception`），
   **mm 身份过滤** + VA 窗过滤双门。5 点全部字节级验证，两轮 skeptic 审查通过。
2. **正对照 P1–P4 全过（这是本轮最重要的资产）**：
   - P1 `process_vm_writev` → `H3 ... aux=0x1(FOLL_WRITE) comm=vmwrite32 mm=<victim>` ✓
   - P2 `/proc/<pid>/mem pwrite` → `H1 ... aux=0x11 comm=mempoke w=2827…` —— **写入内容逐字节捕获** ✓
     （且 H2 同步 +1，验证 `access_remote_vm→get_user_pages_remote` 管道链）
   - P3 H5 go/no-go ✓；P4 `armed=0` 时同一次写 → ring 0 条 ✓
3. **联合窗（930 s，victim 正常 RW 运行）**：守护页上出现 **164 条家族记录**（λ≈10.6/min），
   5 路钩子 **hit = 0**，而活性计数为 **H1 154,460 / H2 695,614 / H4 12,702,369 / H5 0** 次调用。
   ⇒ **写者不经**：`/proc/<pid>/mem`(H1)、GUP(H2)、`process_vm_writev`(H3)、
   缺页路径(H4)、ex_table/fixup(H5)。
4. **意外点名一条真实外部访问**：`H3 ... far=0x7fcada9000(=victim 的 va_list 页) aux=0x0
   pid=11880 comm=nerepair mm=<victim mm>` —— nerepair 用 `process_vm_readv` **只读**该页做
   形状判定（与审计 `nerepair.c:279` 一致）。**这不是写者**，但证明仪器能精确区分「读/写」
   与「是谁」。

## 1. 装置演进（v1→v4，两轮 skeptic 抓出 5 个真缺陷）

| 版本 | 缺陷/变化 | 证据 |
|---|---|---|
| v1（4 入口） | skeptic 拒绝：S1 `seq_lseek` 无 `proc_open` ⇒ `private_data=NULL` ⇒ 任何 lseek NULL-deref panic；V1 `process_vm_writev` 走 `pin_user_pages_remote`（H3 被禁用）⇒ P1 结构必败；V2 H5 锚被探针污染 + 承诺的 tr/lr/pc 不存在 | 设备未上机即拦截 |
| v2（5 入口） | 修 S1=`no_llseek`、V1=加 H3@+8、V2=clear+降级判读 | skeptic ⑤：S1/V1/V2 与 H3 a–e **字节级全过**；新抓 S2（exit 日志 index/label 错位）/V3（armed=0 致假阴性）/V4（判读表矛盾） |
| v3 | 修 S2（5 路标签）、V3（单实例+re-arm）、V4（判读表） | 上机：5 点全挂、GO/NO-GO ok、rmmod 5 行 readback ok=1 |
| **v3 上机暴露的新缺陷（运行期才可见）** | **VA 是按进程独立的**：仅比数值区间会把任何进程落在同数值范围的访问当命中。观察窗 2 min 内 84 条 H4 + 15 条 H1 假阳性（`comm=pidof/cat/ip/head`，H1 的 `w=` 是 ASCII cmdline、H4 是各自栈缺页） | 设备实测逐条可辨 |
| **v4（当前）** | 加 **mm 身份过滤**：H1/H2/H3 传 x0(target mm)、H4/H5 用 current->mm；victim mm 由 `vpid=` 在 init 捕获并持引用（`find_get_pid→get_pid_task→get_task_mm`，exit `mmput`）。同一 VA 窗 + mm 门双过滤 | 假阳性 0；P1/P2/P4 与联合窗全绿 |

**方法论教训（写进纪律）**：静态审查（两轮 skeptic）无法发现「VA 数值区间过滤 = 跨进程假阳性」
——这只有**运行期数据**能揭示。观察窗的价值正在于此；本轮 v3 的作废不是浪费，是它抓住了 v4 的设计前提。

## 2. 正对照（P1–P4，预注册 §2）

```
P1 vmwrite32 19491 7fcada9470 <32B>   → ev H3 far=0x7fcada9000 aux=0x1 pid=15116 comm=vmwrite32 mm=<victim>
P2 mempoke   19491 7fcada9480 <0x21..0x40> → ev H1 far=0x7fcada9480 aux=0x11 pid=15117 comm=mempoke
                                          w=2827262524232221,302f2e2d2c2b2a29,3837363534333231,403f3e3d3c3b3a39
                                          （= 逐字节写入内容 0x21,0x22,…,0x40）＋ H2 同步 +1
P3 go/no-go                               → GO/NO-GO ok H5_calls=1
P4 armed=0 后重复 P2                       → ring 0 条（calls 可增）
```

⇒ 装置对「跨进程写」的检出能力 **E4 级**：能同时给出 comm/pid/mm/far/写内容/FOLL_WRITE 位。

## 3. 联合窗数据

| 项 | 值 |
|---|---|
| victim | scanary_ro_v21 pid 19491，`--ro 0`（RW，不停放），1500 s 跑满（`EXIT reason=duration`，295,251 passes） |
| 窗 | insmod 20:01:04 → victim 结束 20:19:36（**930 s**），全程 `armed=1` |
| mm 过滤 | `victim_mm=0xffffff80103b7480`（init 打印，exit 释放） |
| scanner 命中（窗内 EV>570 s） | **164 条家族记录**（`len=1664`，ip 字段为设备自身 WAN 地址；全部 `page=0x7fcada9000`=ap 页） |
| H1 `__access_remote_vm` | calls **154,460** / hit **0** |
| H2 `get_user_pages_remote` | calls **695,614** / hit **0** |
| H3 `pin_user_pages_remote` | calls 2 / hit 0（清基线后） |
| H4 `do_page_fault` | calls **12,702,369** / hit **0** |
| H5 `fixup_exception` | calls **0**（与 U-B1 一致） |
| 窗内 nerepair 只读命中（clear 前） | 1 条：`H3 aux=0x0 comm=nerepair far=ap 页` ⇒ 监督者读形状，非写者 |

**判读（预注册 §3 第 4 行落位）**：H1–H4 ring 中无 `comm≠victim` 条目、calls 巨量、
scanner 命中 164 ≫ 10 ⇒ **「有检出能力的多路径阴性」（E2，机制收窄，非点名）**。

## 4. 机制收窄（与 U-A2 / U-B1 合取）

已排除（有仪器在场的阴性）：

| 路径 | 实验 | 结论 |
|---|---|---|
| DMA / 总线主写 | U-A2 脉冲（PTE 门控 ≥25× 抑制，z=−6.2） | 排除 |
| 内核 uaccess 失败（ex_table/fixup） | U-B1 fxhook calls=0；本轮 H5 再证 | 排除 |
| `/proc/<pid>/mem` GUP 写 | 本轮 H1（154K 调用 0 命中，P2 证明可检出） | **排除** |
| `process_vm_writev` GUP 写 | 本轮 H3@+8（P1 证明可检出） | **排除** |
| 任何经页表的缺页写（EL0/EL1） | 本轮 H4（12.7M 调用 0 命中） | **排除** |

**剩余候选**（按概率）：
1. **内核成功 uaccess 写**（`copy_to_user` 的 constprop 克隆 / 内联 `sttr` / `__put_user`）——
   C-206/C-214 只扫过 `__arch_copy_to_user` 主入口（28.96M 调用零家族内容），
   但 104 个 constprop 克隆与内联站点未覆盖（VERDICT.md:145 自陈 393 个用户写站点未解析）；
2. **私有驱动「缓存用户 VA 再写」**（审计 Top-2：`mt_wifi` 168 个 `copy_to_user` 包装，
   dst 取自常驻描述符 `{buf@+0x10, out_len@+0x18}`，可陈旧）——若该驱动持 `kthread_use_mm`
   借用 victim mm，则完全绕过 GUP 与缺页路径，只在 `__arch_copy_to_user` 可见。

⇒ **下一步仪器 = H6 `__arch_copy_to_user` + mm/VA 双过滤**（唯一剩下的 CPU 写路径）。
技术要点（预判）：该函数是纯汇编叶子（入口 `8b020005`=`add x5,x0,x2`，无 paciasp/无 stk 帧），
补丁点 +0、replay 首指令、resume +4；mm 判定用 `current->mm ?: current->active_mm`
（kthread 借用 mm 的情形），并比对 victim_mm。风险与 shim 形态同 H3 但更热，需再走 skeptic。

## 5. 采集件与五元组

| 文件 | 设备路径 | md5 |
|---|---|---|
| wrhunt_v1.ko（拒绝，未上机） | 本地 | `1f9ab135279e0b91bb3b4598a7d2b488` |
| wrhunt_v2.ko（复审通过但未上机，被 v3 取代） | 本地 | `3c9b45138eca3000d55b3219131075f3` |
| **wrhunt_v3.ko（上机：观察窗暴露 VA 假阳性）** | /data/repro/ | `758205ef1687d13586d0f0e34f77a25f` |
| **wrhunt_v4.ko（上机：mm 过滤，本轮判决依据）** | /data/repro/ | `5ecb4d882faad81d33a33aee1b3d2686` |
| vmwrite32（P1 helper） | /data/repro/ | `613a105f2f708f3ad564deeacac0a602` |
| mempoke（P2 helper） | /data/repro/ | `04a57241c443558a647ef68e92223786` |
| uc1_v4_events.txt（v4 窗末 /proc/wrhunt 快照） | /data/repro/ | `f88bf46e37eac4098294a5fabe239367` |
| uc1_joint.log（1500 s victim 日志） | /data/repro/ | `9527dd20dbd812fce48afeffa32e76cf` |
| uc1_v3_events.txt（v3 假阳性证据，116 行） | /data/repro/ | `c62e5b08e2df4d94bcec5a8d75306b5a` |
| uc1_lambda.log（λ 预检 74 条/300 s） | /data/repro/ | `0249badab5584222b7de47dc4957d060` |

## 6. 完整性对账

- **rmmod**：5 行 `restored ... readback ... ok=1` 全部出现（`a9b87bfd/a9bf7bfd/a9bf7bfd/a9ba7bfd/a9be7bfd`），
  `unloaded calls:H1=154472 H2=695686 H3=2 H4=12703947 H5=0`（S2 修复后 5 路标签正确）、`lsmod` 0。
- **NE 台账**：1799 → 1947（+148）。**逐条对账**：+132 条集中在 18:00–19:00（任何仪器装载之前，
  傍晚流量高峰的同族进程崩溃）；wrhunt v3 窗内 1 条、v4 窗内 **0 条**；
  **0 条来自 scanary/wrhunt/vmwrite32/mempoke/insmod/rmmod**。⇒ 仪器零责任。
- **nerepair**：全程 dry（STAT `xrep=0 repaired=0`）；其 segv 计数含 victim 自写 fault（dry 观察）。
- **设备**：同一 boot，ups 15:53→16:35，无重启；load 7.5–9.0（幻影负载常态）。

## 7. 三栏

### [A] 已核实
- 5 入口装置字节级验证 + 两轮 skeptic + 上机 go/no-go + P1–P4 正对照全过。
- mm 过滤后 VA 巧合假阳性为 0（v3 的 84 条假阳性 vs v4 的 0）。
- 联合窗 930 s：164 条家族记录 vs 5 路 hit=0，活性计数 H4 12.7M / H2 696K / H1 154K。
- nerepair 只读命中（aux=0、pid 11880、ap 页）——仪器可精确区分读/写与身份。
- 卸载干净、NE 零归因、nerepair dry。

### [B] 未核实
- 写者身份（本轮把 5 条 CPU 路径排除，剩 `__arch_copy_to_user` 族未测）。
- H3 的两条 calls（窗内）内容未展开（hit=0 已足够，但未查是否 nerepair 周期读取）。
- victim 的 1 次 selfcrash（selftest T4 注入导致，P3 同机制；EXIT selfcrash=1）。

### [C] 必须上设备才能确认
- H6 `__arch_copy_to_user` 钩（含 mm 过滤与 constprop 克隆覆盖策略）→ 点名最后一条 CPU 路径。
- 若 H6 也阴性 ⇒ 转向「私有驱动缓存 VA + kthread_use_mm」专项（审计 Top-2），
  以及 D28 lab 对照复现。
