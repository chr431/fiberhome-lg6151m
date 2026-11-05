# 审查总纲 · nerepair 效力/性能 + V5 可行性（Lead 汇总）

> 轮次：2026-11-03 晚｜Lead: lead｜四份子报告：NEREPAIR_EFFICACY / NEREPAIR_PERF / V5_FEASIBILITY / SKEPTIC_REVIEW
> 方法：仓库静态审查 + 设备**只读**实测（零写操作、零部署、未动 24 h 观察窗状态）；设备时间锚点 btime=1793699132（2026-11-03 17:45:32 +0800）= 观察窗起点。
> 证据分级：E0 无证据 / E1 弱 / E2 强推断 / E3 直接观测 / E4 因果闭环。

## 一、结论速览

| 问题 | 判决 | 等级 |
|---|---|---|
| nerepair 是否**确实减少崩溃**？ | **设备上尚未发生**：当前是 **dry-run（零修复）**，真 `REPAIR=0`。判据在真实崩溃上命中过（3 条自然样本双信道确认真家族 + 1 条观测者注入样本命中）；自然 SIGSEGV 的**崩溃层捕获率 4/20 = 20.0%（Wilson 95% CI 8.1–41.6%，下界口径）**。布防前不得宣称"已减少崩溃" | E3（状态/计数）/ E3（命中率，口径受限） |
| nerepair 的**性能影响**？ | **处理面窄、停面宽**：每个信号投递与每次 fork/clone/exec 都产生停 ⇒ 实测停事件 **≥1,522 次/s**、CPU **2.32%（寿命）/2.46–2.51%（瞬时）单核**≈35 min/日、RSS 124–128 kB。成本由**进程 churn（344–346 task/s）**决定，与崩溃率无关；真正风险是 supervisor 卡住 ⇒ 57 个 tracee 同时停（实测重启期零覆盖 **81 s**） | E3 |
| 以 lab v3.1 为基座做 V5，(a) 含蜂窝全功能？ | **可能，但不是可行**（蜂窝内核侧 CCCI/ccmni/ttyCMIPC 在 lab 内核**实测在场**；端到端 md FSM/拨号未验证） | E3 管道 / E1 端到端 |
| (b) 仅**有线/WiFi** 上行的 V5？ | **可能**：有线把握最大（lab 实测 eth up 2.5G，E3）；WiFi 需三件套实证（PCIe 已枚举 14c3:7992，但固件命名不符、mediatek/ 为空、无 wed@ 节点）；**netfilter 全家缺失** ⇒ NAT/防火墙/端口映射/访客隔离/wan_agg 全部要先补内核 config | E3 有线 / E1 WiFi / E2 netfilter |
| (c) 能否**停止 SIGSEGV 生产者**？ | **不能保证，且当前证据未支持（E0/E1）**。D28 只证明"厂商内核态环境是必要条件"（且该"必要性"表述需收窄，见 §四-1）；V5 点亮 WiFi 恰好把 C-204 认定的主载体（WiFi 客户端数据面流量）加回来 | E0/E1 |

## 二、nerepair 效力（详见 NEREPAIR_EFFICACY.md）

**设备现状（Lead + 两子代理各独立只读复核，19:20–19:42）**
- `/data/gw/nerepair.dry` 在位（0 B, Nov 1 18:01）⇒ **dry-run，不修**；`nerepair.xrep`/`slotguard.arm`/`nerepair.slotdrop` 三钥匙**全缺** ⇒ slotguard 零写。
- 日志精确计数（2060 行）：`REPAIR=0 / DREPAIR=0 / XREPAIR=0 / WOULD_XREP=0 / XFORM=0`；`WOULD_REPAIR=141`（**全部为探针 vsurv5**）、`WOULD_DREPAIR=5`。
- **自然进程 predicted repair = 4 起**（全走 deref 路径）：iptables 11:57:17 / busybox 16:24:08 / date 16:49:25 / ql_entry_auto_q 16:56:12；**4/4 逐条落在 `ne_events.tsv` 死亡台账**（dry ⇒ 确实死了）；**3/4 经 .stack 双信道复核为真家族且与 si_addr 精确对齐**，ql（which=q2）因记录落在 dump 窗口之下**无法判定**。pop 路径自然命中 **0**。
- 覆盖率：用户进程 57、被追随 56、唯一未追随 TracerPid=11617（自身）⇒ 排除自身 100%。**`STAT attached=45` 是累计 attach 事件数，不是覆盖判据**（FIX.md:254/:521 的口径须纠正）。

**崩溃层捕获率**：4/20 = **20.0%（8.1–41.6%）**；分母 = 7.01 h epoch 极差内的自然 SIGSEGV 停（跨 3 实例 + 1 复位），分子 = deref 路径命中。**注意三点限制**：(i) 实验密集期、跨 boot ⇒ 不是背景率；(ii) 熔断先于 dry 判定消费 ⇒ WOULD_* 是**截尾下界**；(iii) 适用对象是一次性工具进程，**无守护/监听父进程**样本。

**行为级正负对照（E3，但对象是探针）**：宿主回归复跑通过（mask 150/150 & 0/8、deref 17/17、v2.2 22/22 且判据从源码逐字节重生成）。

**高危残余（必须与"有效"同读）**
1. **path 2 默认（mode 0）的证据门弱于 shape_ok**（`find_record_near_stack` :658-683 不调 shape_ok）：判据是 w1==w3==0 ∧ 地址≈某小字 ±8 ∧ 该字在长度带 ⇒ **`{fault,0,0,0}` 这类零包围窗可通过**；mask_test 的 0/8 阴性**只覆盖 shape_ok，不覆盖该弱门** ⇒ "真 NULL/小指针被吞"是未被回归覆盖的假阳性面。
2. **R-11**：修完立即 `PTRACE_CONT`，**无任何 post-repair 行为校验** ⇒ 被救回的进程可能带着被污染的栈继续跑（不掩盖真实 bug 的保证只对 path 1/X1/X3 成立）。
3. 观察窗（17:45:32 起）内自然 NE **= 0**，但**并非"无家族活动"**：19:29:05 一条**只读取证命令派生的 od applet** 崩溃，其记录为规范 A0B2（q0=0x1ee27/len1601/ip=设备 LAN 地址），nerepair 记 `WOULD_DREPAIR path=p2` ⇒ **窗内写入者仍活 + path 2 在真实崩溃上命中（E4）**。该事件为 observer-induced，**分子分母双双剔除**（若并入则 5/21=23.8%，不采用）。

**判决**：(i) 行为级成立（限 armed + 判据命中，且强度分层）；(ii) 家族层预期救活 ≈ 崩溃层 **20%（8–42%）**，pop 型自然 0；(iii) 设备上**未证明减少**——要证明必须 **armed 臂 + 对照臂（或受控注入臂）**；24 h dry 窗只产出分子/分母（按 0.5–1.5/h 期望 12–36 起 SEGV，可修 2.4–7.2 起），50% 降幅仍需 ≈98 h/臂。

## 三、nerepair 性能（详见 NEREPAIR_PERF.md）

| 量 | 值 | 出处 |
|---|---|---|
| 停事件面 | **≥1,522 次/s**（下界；占全系统 ctxt 8,500/s 的 **17.9%**） | E3，两窗一致；Lead 独立复核 1,530/s、8,581/s、17.8% |
| 自身 CPU | **2.32%（寿命）/ 2.46–2.51%（瞬时）单核**；≈**35 min CPU/日**；占忙时 3.91%、四核机时 0.63%、内核态 4.54–4.68% | E3；Lead 独立复核 2.56% |
| 每停事件 | **≤16.2 µs**（点估计 13–16 µs） | E3/E2 |
| 成本驱动 | **进程 churn 344–346 task/s** ⇒ fork/clone 结构性 ≥688 停/s；本仓守护只解释 5–10 fork/s，其余 ≈335/s **归属未测** | E3/E2 |
| 内存 | RSS **124–128 kB**、VmSize 256 kB、1 线程（dnsmasq 848 kB / hostapd 4,292 kB） | E3 |
| 判据开销 | 16 KB 行走 = 4×readv(4 KB) + **2,036 次比较**（15–25 µs）；整次命中处理 40–90 µs | E2 |
| 日志 | 0.82 MB/日 ≈300 MB/年；轮转后**常驻上界 2 MB** | E3（写放大为假设性） |
| 覆盖空洞 | 重启/拉起期间全系统零覆盖 **81 s**（实测；设计上界 90–120 s） | E3 |
| 最大风险 | **不是 CPU 而是"supervisor 卡住 ⇒ 57 tracee 同时停"**（历史 5 次 284–651 s 断流 + 2 次看门狗重启） | E2/E3 |
| 设计缺口 | `:715` 第一次 16 KB 行走**不受** `xform_budget(50/s)` 约束，且 **dry-run 下照付**；最坏（进程循环触发 load 故障）≈**2% 单核** | E2/E3 |

**判决**：对一台四核 CPE，**2.3–2.5% 单核 = 0.6% 机时**属"可接受但不可忽略"的**开机固定税**；它换来的能力与"全量 ptrace 跟随"这一决定绑定——要降本应改跟随策略（按需 attach / 只跟关键角色），而不是"少修几次崩溃"。建议把 `:715` 纳入同一预算、并给改寄存器后的进程加一层行为校验（R-11）。

## 四、V5 可行性（详见 V5_FEASIBILITY.md）

### 4.1 本轮新增硬事实（同时改写三处既有文档措辞）
- **F-1（E3）lab 6.18 并非"零厂商内核态代码"**：`config-lab3-6.18.44:1686-1703` CCCI/ECCI/CCMNI/MEDMCU=y；`System.map.lab3` ccci/ccmni/ccif **458** 个符号；D28 同会话实机日志出现 ccmni0..20、ttyCMIPC0..、DPMAIF probe、modem_cd_init rc=0。
- **F-2（E3）lab 会话已枚举 WiFi 硬件**：`pci 0001:01:00.0 [14c3:7992]`；构建的 `mt7996e.ko` 别名含该 ID。
- **F-3（E3/E0）WiFi 四件套在设备上存在但命名不符**：设备 `/lib/firmware` 含 `WIFI_MT7992_*` + `MT7992_EEPROM.bin`，而主线期望 `mediatek/mt7996/mt7992_{wa,wm,dsp,rom_patch}.bin` 且 `/lib/firmware/mediatek` **为空** ⇒ 需名/格式映射（未验证）。
- **F-4（E3）厂商栈在载**：5.15.134；172 模块 / 163 在载（mt_wifi 8.0 MB、mtk_wed、mtk_warp、hw_nat 1.37 MB）；netfilter 类 58 在载；CCCI **内建非模块**。
- **F-5（E3）蜂窝内核侧管道在 lab 内核在场** ⇒ V5-MEMO 的"蜂窝不可能（硬边界）"应改为**"需实证"**。

### 4.2 为什么 (c) 未被支持（本题的诚实点）
D28 的零结果发生在**没有 WiFi 接口、没有客户端数据面流量**的窗口里；而 C-204 表明记录率随 **WiFi 客户端数据面流量**放缩（无客户端 0.60/min ↔ 热态 13.87–20.33/min）。**V5 的定义正是把 WiFi 与客户端加回来**。此外 F-1/F-2 说明 lab 窗的 ablation 集比文档所述**更窄**：CCCI 内核代码与 WiFi 硬件都在场。⇒ H（必要条件）**既不支持也不否定**"V5 停写"。

### 4.3 工作量级（粗算）
- 仅有线 + LAN + GUI + 观测层 + netfilter 补全：**≈25–50 人日**一次性 + 1–3 人日/月。
- 再加 WiFi：**+8–20 人日**（含固件映射失败返工）。
- 再加蜂窝：**+8–20 人日**，且带"md 起不来即止"的止损门。
- **不可行/不可直接复用**：厂商闭源用户态（mipc/RIL/ql_*）直接复用、SMMU（本内核无 IOMMU 支持）、厂商 hostapd 私有特性、v3_fix.ko 的 PPE 解绑部分。

### 4.4 若要推进"停写"，路线排序
| 排序 | 路线 | 代价 | 是否真"停写" |
|---|---|---|---|
| **A1** | FIX §7.1 点名到函数后**单调用点补丁**（find_vma 判用户栈 VMA，先 armed=0 检测版） | 1–2 人日 + 24 h 窗 | **是**（唯一可自持推进） |
| A2 | 厂商 R1（驱动侧停 DMA/bounce buffer） | 需源码/NDA + 固件升级 | 是（终局，不可自持） |
| A3 | SMMU/IOMMU | — | 不可行（E3） |
| A4 | 关 WED offload | — | 不可（rmmod 1/1 Oops；且 WED 嫌疑已弱化） |
| A5 | nerepair + slotguard（现状） | 0 增量 | **否**（后果层） |

### 4.5 决定性实验（把 (c) 从"未支持"推进的唯一一步，详见 V5_FEASIBILITY §7）
N0（lab 基线）→ N1（+mt7996e/AP，0 客户端）→ N2（+客户端持续数据面）**只加不减**，配**同夜厂商内核正对照臂**、环境清单（证明 ablation 集真实）、形式要件 + 信道三重 + 判据三定律合规；主终点 = `inj=0` 计数（存在/消失二分）。若 N2 率 ≥13.87/min ⇒ 零结果的 P(0)≈e^-416，功效≈1；若 N2 为零，上界 ≈0.05–0.1/min（rule-of-three，带暴露已证实前提）。

## 五、必须回改的既有文档（不自行调和，出处并列见各报告 §8/§12）

1. **D28 §3/§11 + C-213 + 00_STATE + LABKERNEL.md:29**：删"零厂商内核态代码/无 CCI"，改为"**无厂商 .ko、无厂商用户态、无 WiFi 接口与客户端**"；蜂窝拆成"**内核侧在场（E3）/端到端未验证（E1）**"。H 口径随之收窄。
2. **LABKERNEL-V5-MEMO:30-31**：lab DTS **已有** pcie/consys 节点，缺的是 **wed@ 节点**（WED offload 不可用）。
3. **FIX.md:65/:69**："150/150 的 w0<2²⁴"错，实为 **114/150**（36 条 B0A2 复合字）；">95%"在 150 条语料上复算为 **87.3%**（131/150），且 0–597004/1733 个取值来自**另一 2322 份 census**（分母偷换）；:69 的 awk 复现不出该统计。
4. **FIX.md:254/:521**：`attached=` 不能作覆盖率判据（实测 45 vs 实时 56–58）——改用实时 `TracerPid` 全量普查。
5. **FIX.md §0.2**："D2 硬门/没有记录证据就绝不修"须**分强度**：path 1/X1/X3 过 shape_ok，**path 2 默认只过弱门**；补 mode 0 的阴性回归（[C] 项）。
6. **FIX.md §1.3 V1/V2** 是 v1.7 口径：v2.2 已加**每 10 min 全量重扫**（:1109）与 **PID1 60 s 重试**（:1107）。
7. **00_STATE 页首"观察模式"** → 明确写 **dry-run（零修复）**，并记录三把钥匙（xrep/arm/slotdrop）全缺与本次只读锚点。
8. **C-142 位置口径 vs `natne_scan.py`**（0x1390–0x77c0）——引用前必须统一（FIX 附录已自认）。
9. **新立案**：slotguard 于 18:58:11 自身崩溃（`pc` 落在自身 text、`far=0xffffffffffffffd8`、0 条家族记录、nerepair 正确 PASS shape-fail）——**新出现的组件故障，需独立归因**。
10. **观测纪律新增**：设备**只读**取证本身会 fork 被跟踪子进程并**注入事件**（19:29:05 od 即实证）⇒ 任何窗口统计必须扣除观测者自产事件，并在做观测时最小化设备端 applet 调用。

## 六、未决 / 无法核实（不得当结论用）
- 写入者身份仍未点名；transport 未定（H2/H5/H6 竞争）。
- armed 后的真实效力（REPAIR 率、自然 NE 下降）**未测**——需写操作与更长窗口，须另行批准。
- 344/s churn 中 ≈335/s 的归属未测；停等延迟分布、3 s attach 停顿频率未测。
- 蜂窝 md FSM/可拨号性、WiFi 固件可加载性、主线 mt7996e 在本板的吞吐/稳定性、lab 的"目标页资格"共线——全部未验证。
- V5 人日估算为区间工程判断（E1）。

## 七、交付物（均 untracked 新增，无 tracked 文件改动，未 commit）

| 文件 | 行数 | md5 |
|---|---|---|
| docs/review/NEREPAIR_EFFICACY.md | 385 | `4f8f32e485ceaf2241652a0e9f966dd9` |
| docs/review/NEREPAIR_PERF.md | 367 | `0e2e1ff23b669cfb80abb92bdc2929b6` |
| docs/review/V5_FEASIBILITY.md | 370 | `d6893fedfb432860f83f2f10190127fc` |
| docs/review/SKEPTIC_REVIEW.md | 243（含修订验证 addendum:201-243） | `2f975e9b2bc9842fe209c6c04e4cef56` |
| docs/review/NEREPAIR_MODE0_NEGATIVES.md | 236 | `bb352bfd5ca99f3e01cc6523a8c190f3` |
| docs/review/ARMED_WINDOW_2026-11-03.md | 159（**带生成戳，每次重生成会变**） | `5e4012c3b98e833d785ae6d1eca61eae` |
| docs/review/SKEPTIC_ARMED_WINDOW.md | 96（布防事实 10/10 + S1–S8 预注册口径） | `7bcdd3bf63cc351c48b8d5f28260d56c` |
| docs/review/WRITER_HUNT_GAP_AUDIT.md | 185（含附录 A 未检验清单 U-A…U-K） | `b85bff71bf1cdc8c98351ee7a5b84ba2` |
| docs/review/WRITER_HUNT_TOOLBOX.md | 473（Top-3 = U-A/U-B/U-C；§5 交叉表无漏项） | `c7e4758205aec1e927f5854e2a674f98` |
| docs/review/EXPERIMENT_U-A1_RO_SLOT.md | 77（U-A1 预注册，RO 目标 = 活 va_list 页） | `5f7d0995…` |
| docs/review/WRITER_HUNT_PHASE1_REVIEW.md | 325（§6.11–6.15 判读表/裁定/终判 + §7 phase-1 收束） | `eebc2e04aaf077a86e66bd9b9ca0882c` |
| docs/review/U-A1_ROPTE_2026-11-04.md | 83（本轮结果：未判定 ≤E1 + 上界 0.1/min；装置修复史；失败账本；下一轮设计） | 见文件 |


> SKEPTIC_REVIEW.md 的结论表钉死的是**修订前**版本（fb82c59c / f97b024a / 5615b0e6）；其 **addendum（:201 起）**逐条验证 11 项已落地、1 项部分（LOW-12 已由 perf 在 §12#5 闭环）、0 项未落地，并复述四条红线。
> 修订验证后的残余 nit 已处理：efficacy 的 n=1 投影句已删（改为"由背景率承载、窗内 n=0 不提供速率信息"）、perf 的 LOW-12 互指已补、V5 的 MT76_LEDS 口径差建议列入待对账（Lead 记于本节）。

## 八、第二轮（2026-11-03 19:55 起）· 实机布防 + 写入者点名弹药

**1) 实机布防（用户授权，devop 持锁）**：19:55:21 `rm /data/gw/nerepair.dry` + `kill -USR2 <pid>` = dry→armed，**进程内切换、无重启、无覆盖空洞**（pid/starttime 未变）；XREP/slotguard 仍关。回滚 = `kill -USR2`（免重启）或 `touch /data/gw/nerepair.dry`。布防核对 10/10 见 SKEPTIC_ARMED_WINDOW.md。

**2) 采集链（只读）**：`tools/oneoff/review/arm_watch.py` 每 600 s 一轮 → `watch.tsv`（计数器时间序列）/ `arm_log_merged.txt`（抗轮转合并全日志）/ `survival.tsv`（R-11 被修进程存活，9 列 first_alive+last_alive）/ `triage.tsv` + `derepair_window.log`（mode 0 弱门分诊，REVIEW≥2 且≥30% 触发告警）/ `ALERTS.txt`。含"拉到行数 == 设备 wc -l"完整性断言。

**3) 两项口径升级（本轮审查副产品）**：① **kmsg 双重不可见**——arm64 `unhandled fault` 要求 `!ptrace`，nerepair 一 attach 该信道即缺席；布防后被修崩溃不进 NE 台账 ⇒ 唯一记录是 REPAIR 行，**不得以 NE 归零宣称崩溃停止**（窗口报告 §E6/§E7 已固化，含 `行数 ≥ ΔSTAT` 限流断言）。② **mode 0 弱门假阳性面**已量化（构造窗 100% 接受、稀疏栈 27–89%；v2.3 形状校验窗可 0/4,209 全拒且 0/150 丢真）——布防期以 triage 逐条复核。

**4) 写入者点名："手段接近穷尽"不成立**：6 项预注册判决实验从未执行（D5/D6/D7/D13/D16/D1-D2）、4 项结构性不可达，且文档把**排期条件句**读成了既有结论；收口依据是停止规则而非方法耗尽。U-A（CPU 写 vs 非 CPU 写）定位为 **RO-PTE 哨兵 + 故障 PC 归因**（硬件监视点因按线程装载被否；厂商 PERF_EVENTS 未置）；lab 独有插桩（ftrace/kprobe/page_owner/KGDB/MMIO 可读）需先做"WiFi 点亮 + 客户端流量 + 页池养熟 + 环境清单"前置。

## 九、文件索引与状态（2026-11-05 清理轮更新）

> §七 称"均 untracked、未 commit"是 2026-11-03 当轮的事实；2026-11-05 清理轮已把全部
> 调查文档**脱敏后一次性入库**（WAN IP 一律掩码为 110.65.xx.28）。本条为现行状态索引。

| 轮次/主题 | 文件 | 一句话 |
|---|---|---|
| 总纲 | README.md（本文） | nerepair 效力/性能 + V5 可行性汇总 |
| nerepair 效力 | NEREPAIR_EFFICACY.md / NEREPAIR_PERF.md / NEREPAIR_MODE0_NEGATIVES.md | 效力子报告 / 性能子报告 / mode0 弱门假阳性面 |
| V5 | V5_FEASIBILITY.md | lab 基座可行性（含 F-1..F-5 硬事实） |
| 布防窗 | ARMED_WINDOW_2026-11-03.md / SKEPTIC_ARMED_WINDOW.md / SKEPTIC_REVIEW.md | 布防观测报告（生成物）/ 布防核对+预注册口径 / 独立评审 |
| U-A1 | EXPERIMENT_U-A1_RO_SLOT.md / U-A1_ROPTE_2026-11-04.md | RO-PTE 哨兵预注册 / 结果（未判定 ≤E1） |
| U-A2 | U-A2_PREREG_PULSE_2026-11-04.md / U-A2_PULSE_RESULT_2026-11-04.md | 脉冲实验预注册 / 结果 |
| U-B1 | U-B1_PREREG_FXHOOK_2026-11-04.md / U-B1_FXHOOK_RESULT_2026-11-04.md / U-B1_FXHOOK_SKEPTIC_REVIEW.md | fxhook 预注册 / 结果 / 评审 |
| U-C1 | U-C1_PREREG_WRHUNT_2026-11-04.md / U-C1_WRHUNT_RESULT_2026-11-04.md / U-C1_LOCAL_AUDIT_2026-11-04.md / U-C1_SKEPTIC_WRHUNT_2026-11-04.md | 写者猎杀预注册 / 结果 / 本地审计 / 评审 |
| U-D1 | U-D1_PREREG_LOWRISK_2026-11-04.md / U-D1_RESULT_LOWRISK_2026-11-04.md | 低风险通道预注册 / 结果 |
| U-E1 | U-E1_PREREG_PULSE_FXHOOK_2026-11-04.md / U-E1_RESULT_PULSE_FXHOOK_2026-11-04.md / U-E1_SKEPTIC_2026-11-04.md | 脉冲+fxhook 预注册 / 结果 / 评审 |
| U-F1 | U-F1_PREREG_GUP14_2026-11-04.md / U-F1_RESULT_SUITE_2026-11-05.md | GUP14 预注册 / 套件结果 |
| U-G1..U-G8 | U-G*_RESULT/PREREG_2026-11-0*.md | EMI MPU/ISU/EL3/BL31/DFX 决胜链（判决见 docs/SIGSEGV/VERDICT.md §12–§17） |
| 武器手册 | WRITER_HUNT_TOOLBOX.md / WRITER_HUNT_GAP_AUDIT.md / WRITER_HUNT_PHASE1_REVIEW.md / WRITER_HUNT_HANDOFF.md | 手段清单 Top-3 / 未检验项审计 / 阶段一判读 / 交接 |
