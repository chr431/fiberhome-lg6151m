# 05_LOG · 2026-11-01-09 · A4 FE/WED 寄存器与环 dump（D5 环池成员假设升级版）

## 1. 问题
FE EDMA / WED 的 DMA 环缓冲 PA 集合里是否包含「受害进程的栈页 PA」（H1 环池成员：
陈旧描述符/环成员指向受害页）？

## 2. 假设
- H1（环池成员）：某活环的描述符（或其 buffer 指针集）含受害页 PA → 环与受害页有直接寻址关系。
- H0：所有环的 buffer PA 集与受害页 PA 零交（在环满容量与页总数校正后，交集期望≈0）。

## 3. 预测
- H1：受害页 PA ∈ 环 dump 解出的 PA 集（且多次采样稳定出现）。
- H0：零交；受害页 PA 不在任何环的 descriptor/buffer 指针中。

## 4. 判据
- 正对照（结构性，预注册）：≥90% 解出的描述符字段自洽——buffer PA 落在 /proc/iomem 的 System RAM 段内、
  RX len 字段 ≤ 1536；且两次间隔采样间描述符内容/指针随流量变化（活性证明）。正对照不过 → dump 无效不判。
- 噪声对照：随机取 3 个「RAM 内但非受害」的页 PA 同法求交——给出偶然交集期望率作底。
- PASS(H1)：受害页 PA 出现在任一环且非单点噪声（重复采样仍在/多点）。
- FAIL(H0)：正对照过 + 零交 + 噪声对照零交 ⇒「环池不含受害页」（H1 环池成员被否）。
- INVALID：dump 静止（两次采样零变化且正对照活性项失败）；寄存器交叉验证矛盾（proc dump 与寄存器基址不一致）。

## 5. 样本量/功效
- FE：/proc/mtkfe/dump_dma 全量（edma0/1 TX ring-0 2048 项、RX ring 512×2 等，本 boot 实数）。
- WED：wed@0x15010000/wed2/wed3 寄存器窗（devread 只读 /dev/mem）+ 从寄存器解出的环基址读环内存。
- 采样 ≥2 次间隔 ≥30 s；受害页 PA 来自 A3 的双锚点解析（同 session 采集，满足 C-182 同窗要求）。

## 6. 混杂与控制
- 环 PA 集天然覆盖大页空间（每环上千 buffer）→ 必须按「环 buffer 总数 / 全 RAM 页数」给出偶然命中率基线。
- 寄存器偏移不猜：FE 偏移从 vmlinux.elf `fe_edma_hw_init`/`edma_rx_hw_init` 反汇编取证；WED 偏移从
  mtk_wed.ko 反汇编取证；取不到就明说 BLOCKED，不用「常见值」。
- 只读纪律：**绝不写任何寄存器**；/proc/mtkfe/dbg_dma 与 /proc/warp_ctrl/* 是写触发接口，一律不用。
- /proc/mtkfe/dump_dma 与寄存器读数交叉验证（环基址一致性）。

## 7. 停止规则
- devread 读 MMIO 出现异常/设备失联 → 停（RAM 读 mode0 安全；MMIO 只读 DEVMEM=y、IO_STRICT_DEVMEM=n 环境，
  但仍按 §17.3 纪律小心 netsys/wed 窗口，逐寄存器小步读）。
- 设备重启 → 全部作废重登记。

## 8. 分析计划
- 主终点：受害页 PA（dnsmasq 槽页；nerepair 两槽页）∈ ∪环PA集？
- 次终点：环 PA 集与 MD 区表项 PA 的交（A3 联动）；描述符 32B 形态与记录形态的再比对（仅登记，不重复 C-138/X-1）。
- 统计：偶然交集期望 = 环去重 PA 数 × (受害页数 / 全 RAM 可用页数)。

## 9. 变更记录（实验前）
- FE 驱动内建于 vmlinux（fe_edma_* @ 0xffffffc0085876xx..，/proc/kallsyms 实测）。
- DT 实测：ethsys@0x15000000(0x10000)、netsys@0x15100000(0x20000)、wed@0x15010000/wed2@0x15011000/
  wed3@0x15012000（各 0x10000）。
- 既有基线：_local/evidence/crash-root/dump_dma_hot_1793509192.txt（13:00 采样，604,699 B）。
- devread 计划：zig cc aarch64 静态小助手（读 /dev/mem 偏移，hexdump 32B/行），经 deploy.py put 上机 + chmod 755。

## 10. 结果
（实验后追加）

## 11. 判决
（实验后追加）

## 12. 偏差与教训
（实验后追加）

## 10. 结果（2026-11-01 20:1x 执行）

**环资产**：/proc/mtkfe/dump_dma（快照，604,699 B；13:00 旧快照 md5 0880ce65 ≠ 本轮 5b083a9e）：
edma-0 tx0@PA 0x9a4e0000(2048×0x20)、edma-1 tx0@0x9cbd0000(2048)、edma-0 rx0@0x9a468000(512)、
edma-0 rx1@0x9a708000(512)、edma-1 rx0@0x9a484000(512)。条目形态 RX={u32 bufPA, u32 0x60000, 0×6}，TX={0, 0xc0000000, 0×6}。

**proc 快照=静态**：35 s 间隔与 1.2 MB 真流量后两次 cat **逐字节相同**（md5 5b083a9e 三连）⇒ proc 输出是缓存快照非实时渲染。

**DRAM 直读环**（dd /dev/mem，样本 r?1/r?2/r?3 + t?1/t?2）：内容与快照同构；20 s 间隔与 1.2 MB 流量后 md5 不变。
**ringmon**（新 oneoff，zig cc aarch64 静态，28,512 B / md5 81b997a98765aa1059988e0fda01f490，源码
tools/oneoff/sigsegv/ringmon.c，设备 /tmp/ringmon）以 ~90 k 扫/s × 5 s × 3 环采样 w1 bit31(DD)：
- 空闲臂：dd_scans=0/454 k-458 k 扫（三环全 0）；
- 流量臂（并发 3 MB raw_pull）：dd_scans=0/213 k-458 k 扫（三环全 0；rA 扫速减半=CPU 被软中断抢占的旁证）。
⇒ **活性正对照（描述符随流量变化）FAIL**。仪器偏差登记：ringmon 的 dd_total 计数输出损坏（printf 可变参数态，
两次修格式未除根），弃用该字段，活性判据以 dd_scans+W0 差分为准。

**寄存器取证与读取**：vmlinux 反汇编（capstone+pyelftools，symtab 定位）：
- `edma_rx_hw_init.isra.0`@0xffffffc008588a8c：RX 环基址寄存器 = 单元基 + ((cpu+64·ring)+0x5d0)<<4（即 +0x5d00+0x400·ring+0x10·cpu），
  +4=count(0x200)，+8=[ring+0x20]，CPU 绑定写 +0x5e08+0x400·ring；
- `edma_tx_hw_init`@0xffffffc0085888c8：TX 环基址 = +0x5c00+0x400·ring，+4=0x800，+8=[ring+0x24]，+0x208=1 使能。
- 实读 netsys 0x15105c00（16 B，dd /dev/mem）：**返回空**（无 SEA，设备无恙）⇒ /dev/mem 对 MMIO 拒读 ⇒
  **FE/WED 寄存器交叉验证 BLOCKED**（同因 WED wed@0x15010000-0x15012fff 不再试；/proc/mtkfe/dbg_dma 与
  /proc/warp_ctrl/* 为写触发接口，按只读纪律不使用）。

**静态池解析**（rA1/rB1/rC1/tA1/tB1 本地解析）：
- 三 RX 环各 257 个去重缓冲页（512 条目 page_frag 复用），并集 769 页，池范围 0x905e0000-0x9cbb7000；
  **结构性正对照 PASS**：0 个非 RAM PA（iomem 全段核对）；TX 环 0 缓冲指针（闲置格式）。
- **受害页求交：空**（0xb0500000 / 0xb0aa2000 / 0xb135c000 / 0xb1b1a000 ∉ 池；池整体在 0x90-0x9c 带，与受害 0xb0-0xb1 带不相交）。
- 噪声对照：3 个随机 RAM 页 ∉ 池 ✓（池占比 769/约 34 万页 ≈ 0.23%）。

## 11. 判决（D5/H1 环池成员）
- **静态池层面：受害页 ∉ 任何可 dump 的 FE 环缓冲集**（在"该池=快照+内存一致的预注册缓冲集"意义上）。
- **活环层面：INVALID**——活性正对照失败（3 MB 定向流量下 0 DD、环内容零变化），无法证明所 dump 环即承载 LAN 流量的
  当前活环（快照基址可能陈旧或完成路径写他处）；寄存器交叉验证又被 /dev/mem MMIO 拒读阻断。
- WED 环：BLOCKED（MMIO 拒读；写触发接口不合规）。**D5 本轮=静态阴性 + 活性无效**，不得升格为「环池不含受害页」的强结论。
- 对应 claims：C-185。联动：A3 的 FP1"MD 带"命中页经核对非本池成员（见 08 §10③）。

## 12. 偏差与教训
- **proc dump_dma 是缓存快照**：任何基于它的"实时环"结论都无效；下一轮需先解决快照刷新条件（dbg_dma 写触发语义未取证）。
- **活性判据与流量方向解耦失败即 INVALID**：0 DD 既可能是"环非活"也可能是"完成写在别处"——两种解释都阻止 D5 升格。
- ringmon 的 printf 可变参数在 zig/musl 静态构建下两次输出损坏（%llu 与混型参数），教训：设备侧小工具一律用
  定宽 %u/%x 分段打印，不用 %llu 混排。
- /dev/mem 对 MMIO 与无 struct page 的保留区（CCB 等）分别表现为「读空」与「跳页」——两者都**静默**，必须显式设
  可读性对照（本轮补的 16 B 探针法成本极低，应进 SOP）。
