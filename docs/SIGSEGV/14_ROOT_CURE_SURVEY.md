# 14 · 根治可能性普查（U-X 勘测轮：只读 + 静态，2026-11-07）

> 任务：为「根治 32B 记录写入问题」枚举**全部剩余可能性路径**并分级，为下一阶段立项提供入口。
> 本轮约束：**设备零写、零模块、零复位**（只读 SSH 采集）+ 本地静态分析 + 公开资料对码。
> 实证基线不变（C-266 写者=post-MPU 固定功能注入引擎；U-T 判词「本机不存在可用的写者关断手柄」）。
> 新增 claims：C-357..C-359（见 §2）；可行性分级是**分析性判断**，上机前不得当结论。

---

## §0 一页结论

**本轮三个新事实**：

1. **C-357（DRM 簇语义域钉死，公开对码）**：preloader 持有的 0x10005030/34 写原语所属寄存器簇
   = MTK **DRM（DDR Reserve Mode + DFD 调试锁存）标准基础设施**，非本机私有异常。本机序列与
   MT7986（小米 AX6000）公开启动日志的 `drm_update_reg` 序列**逐字段同形**（置 bit15 / 清 CTL2
   bit8·9·21 / 清 bits12-14）。⇒ **T4「清 bit15 关引擎」候选从"盲写"降级为"大概率错靶"**
   （bit15 是跨 SoC 标准 DRAM-init 动作，属保留/调试基础设施位），T4 进一步靠后。
2. **C-358（相位门元事实）**：仪器口径 boot→λ 全量表汇总后——**有记录以来全部 boot 均为 warm
   复位（定时/sysrq/panic/WDT/romap），断电冷启动数据为零**；同一「计划重启」类型曾产出
   高/中/低三种相位；重启方式、uptime、ISU、feed、补丁版本全部与相位无关联。
3. **C-359（自然 NE 每-boot 分布）**：基线 04:00 定时 boot 1–6 NE/h；唯一长窗高发 boot =
   11-04 04:00（156 NE / 13.8h，11.3/h）；与当日客户端热流量未分离（设备无流量历史台账）。

**根治可能性判定**（§3 逐条）：

| # | 路径 | 一句话 | 本轮变化 | 分级 |
|---|---|---|---|---|
| **R1** | **相位门工程化** | 把设备锁进低 λ 相位（重置实测可落 12–50×） | 冷启动维度确认从未测过；DDR reserve 机制给 warm 态保留以具体载体 | **首选（低风险高收益）** |
| **R4** | 后果层完备 | nerepair 周期重扫 + slotguard 槽自愈后重新布防 | 无变化；在「无本机手柄」判决下是用户可见稳定性的最短路径 | **次选（纯代码）** |
| **R0b** | T7 厂商 | 证据包 + 精准提问 | DRM 对码让提问可精准化（问 DFD/DFX 采样配置与关断位） | 并行推进 |
| **R0a** | T4 boot 链 | BL31/preloader 替换 + 安全态写 DRM/DFX | **bit15 候选弱化**；DDRPHY+0x1520 语义仍无公开源；载荷缺口维持 | 搁置（末位） |
| R0c | 时钟/电源门控 | 门控引擎时钟 | 固件串扫零候选（§2.4） | **归档** |
| R2 | 用户态隐身（T5 线） | store 形态变形 | 无变化（C-356 封顶） | **关闭维持** |
| R3 | 活动调度 | 削本地 INPUT 处理量 | 无变化（λ 驱动=C-297，但本地处理是路由器本职） | 不推荐 |
| R5 | 硬件替换 | 换设备 | 见 REPLACEMENT_FEASIBILITY | 终极兜底 |

**一句话**：本轮把 T4 的最后一个本地候选削弱，把「相位门」顶到第一优先——它不需要理解引擎
本体，只需要一个从未做过的对照（断电冷启动）和一套便宜的自动化（高相位→计划重启）。

---

## §1 基线与设备现况（本轮只读快照）

基线（不重复论证，引用既有 claims）：写者 = 存储子系统内 post-MPU 固定功能注入引擎（C-266），
位于一切可达控制面与可读调试面之下（C-272/C-279）；目标捕获 = 总线级实时地址跟随 + 活内容
校验（C-239 + K9）；λ 随设备面向活动放缩（C-297）且有 boot 相位门（C-288/C-338）；
T1/T1b/T2/T3 关闭、T5 隐身封顶（p11 在役）、T6 被动。

设备快照（2026-11-07 14:19，epoch 1794032350，全部只读）：

- 当前 boot = **1794020769**（11:06 启动，uptime 3.2h；非 04:00 定时——U-W 轮后手动重启）；
  本 boot 自然 NE 4 条 / 首 1.5h（≈2.6/h，中低档）。
- p11 四挂载在役（libc / /bin/busybox / wpad / /data/gw/bin/busybox，mount 实证）。
- `emiisu_ctrl = 0xdecddecd`（语义未定案；U-S 收轮记录「ISU ON」与本读数关系待核——
  0xdecd 形似 disable 魔术，[B4]）。lsmod 164 行 = 厂商模块基线（项目 kmod 0，与 U-S 一致）。
- `/data` 水位 **90%**（2123056/2495936 KB）——本轮零写；后续轮次上机前先裁日志。
- ne_events.tsv 3083 行（快照 md5 `bca397f3…`，归档 §6）。

## §2 本轮新证据

### 2.1 C-357 · DRM 簇 = MTK DDR Reserve Mode / DFD 锁存族（公开对码）

**三方独立来源交叉**：

**(a) 本机 preloader 反汇编**（既有，t4_feasibility §2，tmpfiles/ug8/scan/preloader0.img）：
`drm_rw(reg,op,mask)` @VA 0x2055c0，只接受 0x10005030（写值 |0x55000000）与
0x10005034（|0x59000000）；调用序列 = 置 bit15（op=1/mask 0x8000）、清 bit19、
清 0x10005034 的 bit8/9/21（0x100/0x200/0x200000）、异常启动分支与 DRAM init 序列内清
bits12-14（0x204d10-18 / 0x243022-32）；DRM init 路径 0x205704 亦写 0x10005040/44。

**(b) MT7986 公开启动日志**（小米 AX6000，openwrt.org toh 页 + soxrok2212 gist，
本轮拉取归档）：

```
Save DRM_DEBUG_CTL(0xa083f1)
DRM_LATCH_CTL : 0x27e71
DRM_LATCH_CTL2: 0x200a0
drm_update_reg: 1, bits: 0x8000,  addr: 0x1001d030, val: 0xa083f1   ← 置 bit15
drm_update_reg: 0, bits: 0x20000, addr: 0x1001d030, val: 0xa083f1   ← 清 bit17*
drm_update_reg: 0, bits: 0x200,   addr: 0x1001d034, val: 0x1ff      ← 清 bit9
drm_update_reg: 0, bits: 0x200000,addr: 0x1001d034, val: 0x1ff      ← 清 bit21
drm_update_reg: 0, bits: 0x100,   addr: 0x1001d034, val: 0xff       ← 清 bit8
drm_update_reg: 0, bits: 0x4000/0x2000/0x1000, addr: 0x1001d030     ← 清 bits12-14
DRM DDR reserve mode FAIL! a083f1
drm_dram_reserved: MTK_DRM_MODE(22000000)
```

与本机序列**逐字段同形**（协议形状 op/bits/addr 一致；基址 0x1001d000 vs 0x10005000 属
SoC 映射差异；*bit17 vs 本机解码 bit19 一位之差待复核，见 [B2]）。日志同时给出全名：
**"DRM DDR reserve mode"** —— DRM = DRAMC 跨复位保留/调试锁存单元。

**(c) TF-A 公开 DFD 驱动**（mt8188/mt8189/mt8195，本轮拉取归档）：寄存器图
`MTK_DRM_LATCH_CTL1/2 = DRM_BASE+0x40/44`（= 本机 0x10005040/44 同偏移）、
`MISC1_CFG_BASE+0x00..` = DFD_INTERNAL_CTL/CHAIN_LENGTH/POWER_CTL 族、
SMC `MTK_SIP_KERNEL_DFD`（magic 0x9971615x）读写 DFD 寄存器窗；写值上半字
0x9500（LATCH_CTL）/0x6600（WDT_INTERVAL）——与本机 0x55/0x59 同为
**每寄存器写保护 key** 模式。coreboot 侧同族（`dfd_init`/RESET_ON_KEEP_EN）。

**判读（四条推论，标分析性）**：
1. 0x10005030/34 = DRM_DEBUG_CTL/CTL2 语义域 = DRAMC 调试/保留模式控制；preloader 每次
   启动的标准编程，**不是本机异常武装动作**。
2. T4 唯一候选「清 bit15」大概率错靶：bit15 是跨 SoC 标准 DRAM-init 置位（AX6000 同样置且
   常驻 1），属保留/调试基础设施位；清它更可能破坏 warm-reset 保留/调试而不是停写者。
3. 写者（C-266，残余子位置 DDRPHY DFX 族）**不归 DRM 簇管**——T4 载荷缺口（条件 6）维持
   且依旧无公开源（DDRPHY+0x1520 EL1 读致死）。
4. T7 提问精准化：「DFD/DFX 采样引擎在本 SKU 的配置位与关断方法」+「DRM_DEBUG_CTL 与
   DDRPHY DFX 位表」——比泛问「关引擎」可答性高。

**本机 DFD 基础设施侧证**：LK 段串口档案见 `ms_fdt_init: ddr reserve status(9502)` 与
预留内存节点 `platform-debug_dfdmcu_dump`（0xffc00000/2.5MB SRAM）——本机 DFD dump 链在位
（与 C-345「DFD 链服务与写者无关」不矛盾：那是链装载 SMC 的判决）。

### 2.2 C-358 · 相位门 boot→λ 全量表（仪器口径）与元事实

全量表见 [U-X_RESULT](../review/U-X_RESULT_2026-11-07.md) §2（60+ 数据点，来源逐行标注；
[S]=scanary 仪器口径 / [N]=自然 NE / [M]=mini 被动）。要点：

- **跨 boot 同洪水幅度**：83–161 → 6.8/min（12–24×，C-288）；~117 → 0–2/min（>50×，U-S/C-338）；
  历史 hot 46–58 ↔ idle 0.60（~80×，C-204/C-297）。
- **排除清单（数据支持）**：重启方式（panic/sysrq/计划重启三种类型都产出过高/中/低相位）、
  uptime（6.2min 高 vs 5–19min 低）、ISU 开关（C-262）、feed 状态（C-300）、补丁版本
  （p4–p11 前后皆现高/低；scanary 不在覆盖面）。
- **元事实（本轮汇总成文）**：**全部历史 boot 均为 warm 复位，断电冷启动 λ 数据为零**；
  「引擎常驻 + 相位由 boot 后活动再充能」模型与全部数据兼容但未钉死（U-L sysrq 后 ~59/min
  是"复位塌 λ"叙事最大未闭合反例，复测条件未记录）。
- **数据缺口**：① 同 boot 内 λ(t) 衰减曲线（唯一 boot 内衰减 U-A2 48.1→8.6/35min 混入真实
  流量变化）；② 冷启动 vs warm 配对（从未做过，需用户断电配合）；③ 每 boot 流量/PPS 并行
  台账（设备无此历史）；④ U-L 反例复测。

**与 C-357 的交叉**：DRM 的 DDR reserve mode 正是「DRAM/DRAMC 态跨 warm 复位保留」的硬件
机制——若引擎武装态存于 AO 域/保留态，warm 复位不清、**断电冷启动可能清**。这把「冷启动
配对实验」从枚举项升格为**有机制候选的决定性实验**（分析性判断）。

### 2.3 C-359 · 自然 NE 每-boot 分布（设备只读聚合）

ne_events.tsv 3083 行按 stack 路径内嵌 boot epoch 聚合，剔除实验污染窗
（11-06 18:00–24:00 的 tar/ping/ipfull_p5 崩溃雨 = p8/p9/拆宽验证轮；11-05 12:17/12:38
U-G 窗）后：

| boot（@时刻） | 自然 NE | 窗长 | 率 | 备注 |
|---|---|---|---|---|
| 11-01 04:13 | 26 | 8.1h | 3.2/h | sh/awk/ip |
| 11-01 13:49 | 12 | 7.1h | 1.7/h | |
| 11-03 17:45 | 21 | 2.1h | 9.9/h | U-G 窗前 |
| **11-04 04:00** | **156** | **13.8h** | **11.3/h** | **唯一长窗高发**；sh 45/ip 18/logread 18；U-A2 同 boot 仪器 λ 48→8.6/min |
| 11-05 04:00 | 5 | 0.8h | 6.1/h | |
| 11-05 14:03 | 17 | 3.7h | 4.6/h | |
| 11-06 04:00 | 10 | 2.5h | 4.0/h | |
| 11-07 04:00 | 5 | 1.6h | 2.5/h | |
| 11-07 11:06（当前） | 4 | 1.5h | 2.6/h | |

要点：① 四个「干净」04:00 定时 boot 里 11-04 一枝独秀（2–4× 于其余）；② 但 11-04 白天有
真实客户端热流量（U-A2 记录），**自然口径尚不能把「相位」与「流量」分离**（缺协变量台账）；
③ 受害者集合稳定 = busybox 家族（sh/ip/logread/awk/grep），与仪器口径结论一致。

### 2.4 静态扫死角记录（负结果也入档）

- **spmfw/mcupm/sspm 固件串扫**（解压后 strings）：无 DFX/dfd/引擎时钟门候选；sspm 仅
  infra sleep 计数/PMSR/DEVAPC 域串，mcupm 仅 CPU DVFS。⇒ **R0c 时钟/电源门控归档**
  （除非 preloader 时钟树分析翻案，无证据可达）。
- **WSL openwrt-mt6990-lg6851f SDK**：仅签名工具链（已知，C-348 用），无 dramc/dfd 头文件。
- **公开代码搜索**：`0x10005030/34` 无公开命中（网络索引不收裸代码）；TF-A/coreboot DFD
  驱动是唯一公开语义源（已尽收 §2.1）。

## §3 根治可能性逐条

### R1 · 相位门工程化（本轮升为首选）

**机制**：λ 有 boot 级 12–50× 相位差（C-288/C-338），重置是已知可把高相位打落的手段
（但不可靠：U-L 反例）。若相位可控，等于把写入率按量级压到背景档——虽不消灭引擎，
但达成「事实上的根治量级」。

**三条子路径**：
- **R1a 冷启动判别**（决定性实验，只读观测）：预注册断电冷启动 + warm 配对，同负载 λ 对照。
  若冷启动恒低相位 ⇒ 「低相位锁定」存在物理入口（且与 DDR reserve 保留态机制自洽）；
  若冷启动也高 ⇒ 相位由 boot 后流量史决定，转 R1c。**需用户断电配合，本轮只读未做**。
- **R1b 相位自动管理**（可部署缓解）：watchdog 已有 λ 观察能力——加「高相位检测 → 计划
  重启（限频/冷却窗）」策略。工程量小、风险低（重启本身是每日例行）、收益量级 = λ×12–50↓。
  负面：U-L 反例说明重置不保证落低相位——策略须带「重置后复测 + 最多 N 次熔断」。
- **R1c 流量协变量台账**：sampler 扩展记录每 boot 客户端 PPS/RX-TX（写入 /data 前先看水位），
  把 C-359 的「相位 vs 流量」分离——这是 R1a/R1b 的判据地基。

### R4 · 后果层完备（用户可见稳定性的最短路径）

C-284 否决布防的两个缺口都是**代码侧可修**：nerepair V1 重扫缺陷（覆盖 23%）与 slotguard
槽漂移（S-5）。在「本机无引擎手柄」的判决下，修好这两件再评布防 = 停止家族 NE 杀进程的
最短工程路径（写仍在，R-11 边界重申）。纯代码开发，设备上机仅验证。

### R0 · 引擎关断

- **R0a T4 boot 链**：技术前提（SBC 关/私钥/协议解码）不变，但**唯一候选 bit15 本轮弱化**
  （§2.1 推论 2）；DDRPHY+0x1520 位语义无公开源，条件 6 缺口维持。剩余静态价值 =
  preloader 完整 DRM/DFD 簇对码（找异常启动分支差异）+ bit17/19 差异复核（zig objdump）。
  **维持搁置；上机仍需单独立轮 + 明示授权。**
- **R0b T7 厂商**：证据包升级 v2——附 C-357 对码材料，提问改为「DFD/DFX 采样引擎 SKU
  配置与关断位 + DRM_DEBUG_CTL/DDRPHY DFX 位表」。成本不变，可答性提升。
- **R0c 时钟/电源门控**：归档（§2.4 零候选）。

### R2/R3/R5 · 已封顶/不推荐/兜底

R2（隐身）：C-356 四连阴性封顶，p11 即终态。R3（活动调度）：λ 随本地 INPUT 走（C-297）
但 DNS/GUI/authd 本地处理是路由器本职，架构级减负空间有限，不投入。R5（硬件替换）：
REPLACEMENT_FEASIBILITY 在档，终极兜底。

## §4 下一步排序（建议）

1. **R1a 冷启动配对实验**（预注册；用户断电配合；scanary + 真实流量双口径）。
2. **R1c 流量协变量台账**（sampler 扩展，固件写另行预注册；注意 /data 90% 先裁）。
3. **R4 nerepair/slotguard 代码修复** → 布防门禁复评。
4. **R0b T7 证据包 v2**（附 DRM 对码）。
5. **R0a 静态补完**（zig objdump 复核序列；完整簇对码报告）——纯离线。
6. R0c 归档；R2/R3 不投入。

## §5 三栏

**[A] 已核实（本轮，等级标注）**
1. C-357：DRM 簇语义域 = MTK DDR Reserve Mode/DFD 锁存族；本机 preloader 序列与 MT7986
   公开日志逐字段同形（bit17/19 一处差异待复核除外）。E2（本地反汇编 × 外部公开日志 ×
   TF-A 公开源码三方交叉）。
2. C-358：全部历史 boot 皆 warm 复位、冷启动数据为零；同型重置产出过三种相位。E2（台账汇总）。
3. C-359：自然 NE 每-boot 分布；11-04 boot 156 NE/13.8h 唯一长窗高发。E1（单源设备台账，
   聚合口径新；实验污染窗已剔除但剔除边界是人工判定）。
4. 设备快照五项（§1）。E1。

**[B] 未核实（不得当结论）**
1. bit15 具体语义（公开日志佐证「标准置位」，仍非位表/datasheet）。
2. 本机 bit19 vs AX6000 bit17 差异真伪（t4 解码复核未做——zig objdump 可做）。
3. 「相位=可再充能状态」模型；冷启动是否清引擎武装态（R1a 就是为此设计）。
4. `emiisu_ctrl=0xdecddecd` 语义及与 U-S「ISU ON」记录的关系。
5. DRM/DFD 簇与写者的因果方向（当前只有「同在 DRAMC 域」的地理相邻，无因果链）。

**[C] 需设备/授权**
1. R1a 冷启动配对（用户断电配合；观测只读）。
2. R1b/R1c 部署（固件写，另行预注册）。
3. R4 上机验证（固件写）。
4. T4 任何上机动作（单独立轮 + 明示授权；本轮建议搁置）。

## §6 材料与证据索引

| 件 | 位置 | md5（首 8） |
|---|---|---|
| AX6000(MT7986) 公开启动日志 | `_local/evidence/b4b/ux/ax6000_mt7986_bootlog_public.log` | 7b49fb36 |
| TF-A/coreboot 公开 DFD 源（8 件） | `_local/evidence/b4b/ux/{tfa_dfd.*,plat_dfd_81xx.*,cb_dfd.c}` | 见 md5s.txt |
| ne_events 快照（3083 行） | `_local/evidence/b4b/ux/ne_events_2026-11-07.tsv` | bca397f3 |
| reboots.log 快照 | `_local/evidence/b4b/ux/reboots_2026-11-07.log` | f04e6d33 |
| 证据清单 | `_local/evidence/b4b/ux/md5s.txt` | — |
| preloader 反汇编解码（既有） | `tmpfiles/repro/t4_feasibility.md` §2 | — |
| 本机 LK 串口档案（ddr reserve 行） | `_local/investigations/sigsegv-tools/phase-AB/c2-serial/console-s1-20261101-2303.log` | — |
| 相位门全量表 | [U-X_RESULT](../review/U-X_RESULT_2026-11-07.md) §2 | — |
| 公开来源 | openwrt.org/toh/xiaomi/redmi_ax6000（boot log）；gist soxrok2212 03e08ec（raw）；TF-A master `plat/mediatek/drivers/dfd/`（mt8188/mt8189 plat_dfd + dfd.c）；coreboot `src/soc/mediatek/common/dfd.c` | — |

> **进度注记（2026-11-07 U-Y 轮，低风险上机）**：R1 获得首个受控输入（C-360）——同 boot
> 7 臂 2.2h：基线 λ 慢漂降 12.31→6.33/min（≈2×/2.2h，**无快衰减**，U-A2 流量混杂解释
> 加强）；洪水放大 ×2.4–2.7 三臂稳定；**真实 WAN ≈23 B/s 全程而基线 12+/min 持续** ⇒
> λ = 相位分量（boot 级、流量无关）× 活动分量的因子模型首个受控支撑。R1b 检测窗可按
> 小时计；新增备选臂「等待降档」（若慢漂降在多 boot 复现，高相位或有小时级自愈——
> 免重启）。emiisu [B4] 解除（ISU 现值=ON，0xdecddecd=使能魔术，C-361）；bit19 逐指令
> 定案入 C-357 注记。R1a 冷启动配对仍待用户断电配合。
