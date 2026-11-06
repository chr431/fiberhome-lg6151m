# 13 · 阻止写入路径普查（离线分析，2026-11-06）

> 任务：**设法阻止 32B 记录写入本身**（区别于后果层修复）。本轮为**纯离线分析**：枚举所有仍有希望的
> 阻断路径，逐条给依据 / 本地材料 / 离线任务 / 上机判决实验 / 风险。**本文不新增 E-claims**——所有
> 实证引用均来自 [01_CLAIMS.tsv](01_CLAIMS.tsv) 既有条目；本文的可行性分级是**分析性判断**（标
> `就绪/待离线/待上机`），不是观测结论。后续每条路径落地时按预注册另立 U-x 轮次出 RESULT。
>
> 基线判决（不可再翻案的部分）：写者 = **存储子系统内 post-MPU 固定功能注入引擎**（C-266），
> 位于一切可达控制面（软件 / EL1 寄存器 / SMC，C-279）与一切可读调试面（C-272）之下；
> 内容 = 本机硬件卸载流（MED hnat_info 族，C-258）；目标捕获 = 总线级实时地址跟随 + 活内容校验
> （C-239 + K9/C-221 族 + C-265）。

---

## §0 一页结论

**写入要成立，三个环节缺一不可；阻断任一环节即阻断写入：**

| 环节 | 内容 | 证据 | 本机可断性 |
|---|---|---|---|
| ① 内容供给 | FE→MED FDMA hnat_info 卸载流，经 EMI 内部观测面喂给引擎 | C-258、C-261 | **已证伪（U-K，C-300）**：环断供后 λ 仍 80%——内容非必要非充分 |
| ② 目标捕获 | 嗅探受害者 CPU store PA（实时解析）+ 槽活内容校验 + 热页选择 | C-239、C-221(K9)、C-265 | **有活口（T3/T5）** |
| **T1** | **FE→MED hnat_info 通道断供** | 引擎镜像的候选内容流；证据=环生产可计量 | **已关闭（U-K）**：2×2 证伪——环冻结后洪水 λ 仍 80%（C-300）；λ 随设备面向活动（C-297） | 判决 |
| ③ 注入通道 | post-MPU 硅引擎，无任何可达控制面 | C-266、C-272、C-276..C-279 | **本机判死；仅剩安全态/厂商（T2/T4/T7）** |

**路径优先级**（离线可推进度 × 期望收益 × 风险，§4 有矩阵）：

| # | 路径 | 一句话 | 状态 |
|---|---|---|---|
| ~~**T1**~~ | ~~FE→MED hnat_info 通道断供~~ | 引擎镜像的是这条流；把"产流"关掉，写入失去内容 | **已关闭（U-K）**：2×2 因子表证伪（C-300）——环冻结后本地洪水 λ 仍 14.2/min（80%）；λ 随设备面向活动（C-297）。杠杆 dpmaif_stop_rx_sw 保留为 MED 面工具（C-299） |
| **T2** | SIP/SMC 分发器全表 + DFD 链装载服务 | U-G6 未竟项；若 ATF 既有服务能达 DFX/DFD 配置 = 免改启动链的"引擎手柄" | 待离线（tee_b 全量反汇编在手） |
| **T3** | **放逐窗（受害栈迁入 ISU 保留 8MB）** | 引擎对保留 DRAM 窗的可达性从未被测过（C-260 是选择偏差不是禁区证据）；一半概率的大奖，实验便宜且安全 | 待离线设计；上机一轮可判 |
| **T4** | boot 链核查 → 安全态写 DRM/DFX | preloader 里有完整安全态写原语（C-274）与 SBC 运行时判定（本轮 strings 实证双路径）；若 SBC 关且 BL31 可换 = 本地最后一发"关引擎" | 待离线；**高风险末位** |
| **T5** | 目标捕获谓词探针（store 模式变形） | K9 证明捕获依赖受害者的 store 行为；测分类器对 store 形态的敏感度 | 待离线设计；机制情报为主 |
| **T6** | 后果层布防完备 | **不断写、只断 SIGSEGV 成形**；当前 nerepair=dry / slotguard=observe，后果层完全被动 | 上机决策项（数据已积累） |
| **T7** | 厂商通道 | 证据包升级；唯一确认可达"引擎本体关断"的外部路径 | 低成本可先行 |

**λ 三点单调性（T1 的期望依据）**：lab 极简环境 0/3600s（C-213）↔ 厂商无客户端 0.60/min（C-199）
↔ 厂商热态 13.9–20.3/min（C-204）↔ 洪水 46–58/min（C-262）。引擎是硅、不随内核消失，lab 零写的
最简解释是**内容馈源缺席**（无转发流）。由此 T1 的期望效果 = 归零或跌到背景档以下；**若残余 >0.2/min
则馈源不止一条**（同样是有价值的收口）。注意：这是分析推断，上机 A/B 前不得当结论引用
（V5_FEASIBILITY §2 对"必要条件当充分条件"的批评口径在这里同样适用）。

---

## §1 机制基线（引既有 claims，一段话版）

外部 32B 结构化写入 `{A, 0, {len, be32 流端点 IP}, 0}`，由存储子系统内 post-MPU 硅引擎落到**热栈页**
的活 va_list（及相邻槽，C-265 记录阵列）上：引擎按**每次写入实时解析**的目标地址寻的（C-239，95 次
整页迁移 λ 不坠），寻的信息源 = 受害者自身 CPU store 的物理地址流（K9 可逆冻结：跳过受害者自写 →
λ 16→0；放开 → 12.3 回弹；C-221/U-G1 §3），写入前还校验**槽内进行时的 va_list 活内容**（K9）；内容
载荷 = 本机硬件卸载转发流，唯一 {len,ip} 生产者是 medmcu 的 MED DL hnat_info 环（C-258），数据经
EMI 内部观测面（与 ISU 同面）被动喂给引擎（C-261）；写入率随客户端数据面流量放缩（C-204）。
CPU 四个异常级、八件协处理器固件、全部带 MPU 域总线 master、ISU、DFD、DRAMC-debug 可见面全部
出局（C-266 汇总表）；EL1 写 DRM 页被静默丢弃（C-276）、emicen 监视器本来是关的（C-277）、
可见 DFX 寄存器零写者签名（C-272）。

**三个环节各自的"断法"即 §3 的路径分组依据。**

---

## §2 已关闭路径清单（防翻案；重开须新证据）

| 路径 | 关闭证据 |
|---|---|
| EMI MPU 16 域拒绝（把写者挡在 DRAM 外） | 写者 post-MPU、不带域（U-G5/C-252 穷尽 + 阳性对照） |
| SMMU/IOMMU | 内核无 IOMMU（FIX §7.3，E3）；且写者非总线 master，SMMU 语义上也不覆盖 |
| rmmod 消元族 | rmmod mtk_wed 1/1 Oops（C-155）；"重启后不加载"对 hw_nat 已测：写入继续 690/1200s（C-193/X-13） |
| HW_TX_EN 软开关 | 门控惰性，该路径本负载未激活（00_STATE §10） |
| EL1 写 DRM_DEBUG_CTL（照抄厂商关法） | NS 只读、写被静默丢弃；ATF 无此 SMC（C-276 + C-264） |
| emicen 监视器 stop/init 对照 | 写者活跃时它本来是关的；init(2) = 总线挂死（C-277） |
| ISU 关断对照 | 可逆因果关断 λ 零响应（C-262）——注意这同时**给了 T3 一个安全的 8MB 保留窗** |
| EL1 观察点点名写者 pc | EL1 fire = 平台级死亡（U-G1 §2）；且身份已判（C-266），点名已无对象 |
| MADV/迁移/PTE 躲靶 | 实时跟随，95 周期 λ 不坠（C-239） |
| "点名到函数 + 单点 bl 补丁"（FIX §7.1） | 前提已死：写者不是软件（C-266） |
| pageguard（RX 环页隔离） | 前提 H1a/H1b 已证伪（FIX §2.3/X-6b）；写者也非 master |
| 换主线内核即停写（V5） | 未被支持（V5_FEASIBILITY §2 四前提全缺）；lab 零写归因于馈源缺席而非内核本体 |
| AEE 拦截解除 → 解锁 EL1 tier | 面向"点名"，身份已判死；作为写入阻断无对象 |

---

## §3 存活路径逐条

### T1 · 内容通道断供：FE→MED FDMA_HNAT_INFO

**依据链**：C-258（全固件唯一 {len,ip} 生产者 = medmcu MED DL hnat_info 环）＋ C-261（数据经 EMI
内部观测面喂引擎）＋ λ 三点单调（§0）。hw_nat 模块缺席写入继续（C-193）说明**这条通道独立于
hw_nat.ko**（分析推断：由 FE 硬件 / MED 固件 / mtk_eth 侧维持——待逆向确认武装者）。

**本轮离线初扫（命令可复现）**：`strings -a tmpfiles/ug3/fw/medmcu_b.bin | grep -i "fdma\|hnat_info"`
命中关键件：

- 配置/生命周期函数名：`med_dl_hnat_info_init / _trigger / _cfg_hw / _host_init / _host_cfg_hw`
- **FE 侧通道寄存器面**：`[Tput] FDMA_HNAT_INFO(STATUS:0x%x, MSK:0x%x), MDMA_TXRX_DESC(STATUS/MSK)`
  与 `0x%x(FDMA_HNAT_INFO_INFO: MED view)` ——存在**可写 MSK/STATUS 语义寄存器**
- **停止路径存在**：`stop:%d, rel %d hnat_info (med_w:%d r:%d, fdma_w:%d r:%d)`（任务带 stop 标志）
- 中断接线：`set the INTC_IRQ_FESYS_FDMA_HNAT`
- AP 侧接触点线索：lab System.map 有 `ccmni_recycle_med_hnat_info`（ccmni 符号，V5_FEASIBILITY [A]5）
  ——厂商 AP 内核（CCCI 内建）应有同族符号，是 AP↔MED hnat_info 的既有接口

**离线任务（材料全在本地，纯静态）**：

1. 反汇编 `med_dl_hnat_info_init/_cfg_hw/_trigger/_host_cfg_hw`（RV33 工装已在：`tmpfiles/ug3/fw_rv_hunt.py`
   / `rv_xref.py`，gp 相对寻址升级项见 U-G4 §2）→ 拿到：FE 侧 FDMA_HNAT_INFO 使能位的确切寄存器
   偏移与置位序列、MED 侧环配置、`stop` 标志的写入者（mailbox/AT/自停条件）。
2. 对 `tmpfiles/ug3/crdump.txt`（PPE/FE 3816 寄存器 × 活跃期快照）定位 STATUS/MSK 当前值 → 确认
   运行态确实在产流。
3. 在厂商 vmlinux / mtk_eth.ko 符号（`tmpfiles/ug3/vmlinux_syms.txt`）找 AP 侧武装点（FE FDMA 描述符/
   hnat_info 发送配置）与 `*med_hnat_info*` 符号族 → 判断是否 kernel-reachable 开关。
4. 产出：一张"通道开关位表"（FE 寄存器 / MED mailbox 命令 / AP 驱动 sysfs 三档），供上机 A/B 选臂。

**上机判决实验（预注册要点，下轮立 U-H 轮）**：scanary 受害者 + 2400pps 洪水（λ 基线档 46–58/min，
功效充裕：10 min 臂期望 460–580，零结果 P(0)=e^-460）；ABAB：B 臂关通道（按位表选最小侵入档），
回滚臂恢复。**判层 I**（FIX §4.2：RR ≤0.5 且 95% CI 上界 <1，反向保护 [0.7,1.4]）。**代价三报**：
吞吐 / 延迟 / UL-DL 功能（此通道参与 DL 加速，MED `Tput` 打印暗示速率统计在用；若吞吐退化 >可接受线
则该路径降级为"证明因果"而非"可部署修复"）。**风险**：FE/MMIO 地雷纪律（8 字节对齐、先读后写、
已知语义寄存器才碰——MMIO 地雷册 #16..#21）。

**期望管理**：λ→0（馈源唯一且被断）或 λ→背景档（残余馈源）；无论哪种都是收口。

> **判决注记（2026-11-06，U-H 轮）**：T3 **关闭**——pfn_valid 保留子区窗（pl-drambuf 0x9c200000，
> /dev/mem cacheable）被同率涂画（RR 1.096/0.939 双窗，C-280）；顶层 removed 段连承载栈的
> 映射属性都没有。放逐思路整体出局，详见 [U-H_RESULT](../review/U-H_RESULT_2026-11-06.md) §2。

> **进度注记（2026-11-06，U-I 轮）**：离线位图已成——MED 固件（tinysys-medmcu-RV33_A，VA=文件
> 偏移）的 hnat_info 配置块 = **MED 视图 0x38013000**（STATUS/MSK 对 +0x30/34/38/3c 等，C-289）；
> 停止路径 = `med_ipi_stop_rx_handler` 任务（0xa5a5a5a5 邮箱魔法）+ AP 内核 `mtk_ipi_send`/
> `med_stop_ack_ipi_handler` 同族——**厂商 AP↔MED 停止协议存在**。AP 读相：FE 0x15104xxx 块
> **活体**（运动索引/描述符指针，洪水窗实测，C-290），但其运动归属（hnat_info 环 vs 常规 PPE
> 数据面）未钉死；MED-cfg 块的 AP 别名未解（0x15103000/0x15105000 全零）⇒ **断供写臂按预注册
> 门禁跳过**（盲写=可能杀整网）。下轮两路：① MED 运行时表（0xaff00000）fdma 计数器速率 ↔
> 0x15104xxx 运动配对钉归属；② ug6/full.txt 挖 mtk_ipi_send 通道表走厂商 IPI 停止协议。
> 工具：tmpfiles/ug3/fw_t1_xref.py。详见 [U-I_RESULT](../review/U-I_RESULT_2026-11-06.md) §4。

> **判决注记（2026-11-06，U-J 轮）**：三件事——① 映射钉死 **AP=MED−0x22500000**（0x38013000↔0x15b13000
> 逐值吻合，C-292）；② **AP 侧对 FE→MED 通道寄存器不可达**（dump 标签 0x15105900/0x15105a00 与
> 全 8 个候选别名全零/不符，C-294）⇒ **"AP 寄存器断供"分支关闭**，剩余唯一带语义钥匙=厂商 IPI
> （`mtk_ipi_send` 族，kmod 构建被内核头树缺失阻断 → 下轮先重建头树）；③ **链①受质疑**（C-295）：
> hnat_info 环生产 ~0.55 rec/s 稳态、**我们的洪水开/关不改变它**，而 λ 的流量三点单调是既有实证
> ⇒ "环记录=写者内容馈源"简单链不被观测支持；判定实验=同一负载下"经转发路径 vs 本地 INPUT"
> （C-258 修订入口）。计量面=/proc/medhw/cr_dump 索引族（六点序列在档），环基 0x9fed08c0 可读
> （dpwr cacheable 读有陈旧风险，C-296）。详见 [U-J_RESULT](../review/U-J_RESULT_2026-11-06.md)。

> **判决注记（2026-11-06，U-K 轮）**：**T1 关闭（链①证伪）**。2×2 因子表：feed 冻结后本地
> 洪水的 λ 仍达 14.2/min（feed-on 的 80%，C-300）——内容通道既非必要（断供不阻止激增）也非
> 充分（U-J：环稳产而 λ 6× 变）。λ 的真实驱动=**设备面向的处理活动**（本地 INPUT 17.7/min
> ≫ 转发 4.6 ≈ 空闲 2.6，C-297；转发被 hnat 硬件旁路）。**"断内容通道饿死写者"路线无主张
> 空间**——写者注入调度跟随活动模式，靶标捕获跟随 store 形态（W1 签名），二者拼成完整机制
> 图景。供给杠杆 `dpmaif_stop_rx_sw()`（环冻结 ≥8min，start 不逆转，复位恢复，C-299）保留
> 为 MED 面实验工具。详见 [U-K_RESULT](../review/U-K_RESULT_2026-11-06.md)。

### T2 · ATF 既有服务全表：SIP 分发器 + DFD 链装载

**依据**：U-G6 §4 明记未竟——"MTK_SIP SMC 号表未提取（分发器在 0x125cc+）"；运行时服务清单含
**DFD 链装载**（装载 = 存在配置面）。[DRAMC-ATF] 访问器已判死（唯一 caller = 崩溃路径，C-264），
但分发器**全表**未提尽——是否存在未被字符串 xref 暴露的服务号（如 DFD 链配置、tinysys 装载的
参数化路径）能达 DFX/观测面配置，纯静态可答。

**材料（全在）**：`tmpfiles/ug6/`：`tee_b.bin`（代码@0x440）、`full.txt`（34,221 指令全注解）、
`allxrefs.txt`（2,159 条）、`tee_analyze.py`。顺带项：0x1f003000/0x1f028000/0x1f005000 三个
ATF 专属 mmap 窗口的**主人识别**（全镜像唯一出现，U-G6/U-G7 两轮未解——若它们是观测面配置窗，
价值直接升格）。

**离线任务**：从 0x125cc 分发器抽全 case 表 → 每个服务号 → handler → 参数语义；DFD 链装载 handler
重点（能否装空链 / 卸载 / 改目标）；tinysys mmap 表（0x26490，43 项）与三窗口对账。

**上机（若出候选）**：emiuctl.ko 直调 SMC 模式已验证（C-262 用过）；λ 对照同 T1。风险：SMC 参数错
→复位（授权内，U-G6 已示警）。若全表提取后确认无手柄 → T2 关闭，同样收口（"ATF 无路"从枚举级
升级为全表级）。

### T3 · 放逐窗：受害栈迁入保留 DRAM 窗（ISU 8MB @0xbf000000）

**依据与空白**：C-260 记录历史命中 PA 全在可分配 RAM、与全部保留窗不相交——但那是**选择偏差**
（保留窗里从来没有 va_list 活动），**不是"引擎写不进保留窗"的证据**。引擎对保留 DRAM 窗的可达性
= 从未测试的空白。若引擎注入有地址范围限制（例如只画 AP-normal 孔径），把关键进程的栈放进保留窗
= 对指定进程的**真阻断**。

**窗口选择**（唯一干净候选）：ISU buf `0xbf000000/8MB`——DRAM 背书（C-262 实验直接 md5 过 buf
内容）；ISU 已被因果关断且可逆验证（C-262：disable → buf 冻结，λ 不受影响）；DT 已保留（内核不碰）。
排除：MCUPM 上 768KB 访问中止（U-G4）、md 环在役、DFD buf 是引擎目标、wocpu 属 WiFi。

**离线任务**：设计文档 + 双件代码（编译不部署）——
1. `exile.ko`：char dev，mmap = `remap_pfn_range` 保留窗 PFN（项目内 patrace/dpquar 族成熟模式）；
   侧门 `paof`（VA→PA 断言用，复用 patrace 语义）。
2. scanary 变体 `scanary_exile`：工作线程栈取自 exile 映射（pthread attr 或手切 sp），其余行为
   逐字同 scanary（matcher/rules 串不变，md5 单独钉）。
3. 预注册：两臂 λ（普通栈 vs 放逐栈，同会话同 boot ABAB）+ PA 断言（patrace 核全部命中 PA ∈ 窗内）
   + 前提门（全量 /proc/iomem 确认窗在 System RAM 段内——§27.2 全量纪律）+ ISU 保持关断的侧门
   断言（窗 md5 抽验）。
4. 安全边界：只迁**实验受害者**；上机一轮判生死。

**判读**：B 臂 λ=0（A 臂 ≥20/10min，热态实际 460+）⇒ **放逐可用** → 后续给 dnsmasq/dropbear/v3httpd
等关键守护做栈放逐（LD_PRELOAD + 切栈，工程量另评）；λ 不坠 ⇒ 引擎范围不限 RAM 窗，T3 关闭收口。
**风险低**：普通 DRAM 写、ISU 已关、无 MMIO。

### T4 · boot 链核查 → 安全态写（最后的本地"关引擎"机会）

**依据**：C-274——preloader（eMMC boot0，4MB Thumb-2，md5 `a9785c43…`）持有 **DRM_DEBUG_CTL 完整
安全态写原语**（0x55c0 掩码清位 bits12-14 + 魔术写协议 `0x10005030|0x55000000` /
`0x10005034|0x59000000`）；C-276——NS/EL1 写同协议被静默丢弃 ⇒ **同一写只有安全态能落**。
本轮 strings 复核 preloader 含 `SBC_EN = 0/1`、`img_auth_required`、`seclib_sec_boot_enabled`——
**SBC 是运行时判定**（efuse/标志），本项目能刷自制内核过 LK 强烈暗示后段校验未开，但 tee 分区是否
在鉴权集内**必须离线定案，不得推断**。

**离线任务（纯静态，材料在 `tmpfiles/ug8/scan/preloader0.img`）**：

1. 追 SBC_EN 判定源（efuse 读点 / boot flag）与**鉴权镜像集**（tee/lk 是否 covered）。
2. SBC 关 ⇒ BL31 替换可行性：tee_b 结构已知（MTK TEE 头 0x200 + 签名 0x334 + 代码@0x440）；
   patch 点 = BL31 启动早期用既有魔术协议清 DRM_DEBUG bit15 / 写 DFX 关断字（**位语义厂商级未知**）。
3. SBC 开 ⇒ T4 关闭归档。
4. （顺带）preloader 里 INTC_IRQ_FESYS_FDMA_HNAT / DFX 家族的全部写点清单——与 T1/T2 对账。

**风险（必须先写死）**：DRAMC/DRM 位语义未知——乱写可能破坏 DRAM 校准 ⇒ **失稳/变砖类不可逆风险**；
BL31 替换砖风险；boot0/tee 分区**不在现有刷机管线内**（管线只覆盖 p26），需先扩展管线 + 原件备份 +
可回滚介质计划，单独立轮。**定位：T1/T2/T3 之后的末位手段**；"位语义"只有厂商文档能解（与 T7 并轨）。

### T5 · 目标捕获谓词探针（store 模式变形）

**依据**：K9（跳过受害者自写 → 引擎放弃，说明捕获依赖 store 行为）+ C-239（实时地址跟随）+ C-265
（热页 + 多槽）。若捕获谓词依赖 store **形态**（宽度/序列/邻接）而非纯地址流，则形态变形可致盲。

**离线任务**：scanary 变体设计——va_list 初始化 store 改形不改义：(a) `strb×N` 逐字节；(b) `stp`
拆两条 `str`；(c) 先写诱饵字后回写真值。每形一个臂。

**上机**：10 min/臂 λ 对照（功效同 T1）。

> **判决注记（2026-11-06，U-H 轮）**：谓词**强形态敏感**且签名已钉死——同址同值手写流全不可见，
> 补 4×`stp q`（32B FP 保存事务）即恢复 0.86（C-282/C-283）⇒ T5 升格为**可部署缓解候选**：
> 自研二进制变参 prologue 拆宽改形=隐身（厂商二进制不可及；此消彼长风险待测），详见
> [U-H_RESULT](../review/U-H_RESULT_2026-11-06.md) §3。**期望管理**：E0→E1 探针——λ→0 的形态 = 分类器绕过
（潜在 libc 级缓解，给自研关键二进制重编；成本高收益存疑，至少机制情报）；全部不坠 ⇒ 捕获谓词
= 纯地址流，T5 关闭并反哺机制模型（K9 的"内容耦合"归因到槽校验而非 store 形态）。

> **判决注记（2026-11-06，U-I 轮）**：**隐身落地成立（首个可部署级阳性）**——真实二进制去掉
> 变参 prologue 的 FP 保存（stealth2 shim：不存 q0–q7、vr_offs=0）后 **600s 零外写**
> （同窗对照 68，P=e^-68，C-287）；子因矩阵修正签名定义：**连续 FP 源寄存器保存区写入突发**
> （nat2q 1.041：≥2 邻接 32B 即满；qoff 1.004：对齐无关；nat8s 0.547：16B 同址同值减半仍
> 可见），且孤立 32B 物化+散布 spill 零触发（W2 边界）——宽度是放大器不是开关（C-285/C-286）。
> 注意"拆宽"（U-H 的 str-q shim）**不够**：其 FP-store 台账 11/调用≈原生可见（0.868）——正确
> 落地形态是**不保存 FP**（自研无 FP 变参二进制 ABI 自洽）。前提清单 6 项已清 3；剩余：热 boot
> 复验、此消彼长长窗（本轮弱阴性）、printf 热路径代价、真守护部署。另：写者强度 **boot 依赖**
> （同洪水 λ 83–161/min→复位后 6.8/min，C-288）——跨 boot 比较必须同 boot 配对。详见
> [U-I_RESULT](../review/U-I_RESULT_2026-11-06.md) §2/§3。

> **判决注记（2026-11-06，U-P 轮）**：**补丁命中数 ≠ 覆盖**——v5 busybox 106 站点在错误
> 路径 4/4 SIGSEGV（3 条 va_list 拷贝被误补 0x408c68..70），ip-full 2 站点静态无效
> （`stp q0,q0` memset 类；`ip neigh` 崩溃为既有 vendor 家族：40 条部署前历史）。v6 语义
> 校验（prologue+vr_offs+首 call 前+拷贝排除）后取 **v5∩v6**：busybox 58（p6s，功能等价+
> 错误路径 0 信号+20min soak 0）、libc 140（=p4）、wpad 24（=p5）、ip 0（stock）。
> **静态 gw busybox 仍未覆盖**（本轮 21:30–31 仍被写者击杀：led_mgr/awk NE）。
> **验收口径**：ip neigh / phy_info / gw 静态 busybox 属既有家族，单列或剔除，不计入 p6s。
> 详见 [U-P_RESULT](../review/U-P_RESULT_2026-11-06.md) §0/§3。

> **判决注记（2026-11-06 U-Q 轮）**：**保存突发掩蔽对静态 busybox 家族封顶**——p8
> （197 站点，含 v6 独有 q2..q7）上线后长驻 shell/awk/sed 仍以既有频率死亡；决定性
> 对照 **p9 把 255 个 q0..q7 保存全部 nop**，挂载后 276s `cut` 仍 SIGSEGV，pc=0x4c8728
> (vgetopt32) 与台账 **29 条历史同族** ⇒ 该家族不由 FP 保存突发驱动（候选解释：引擎
> 直瞄 32B va_list 结构体本身/页属性写）。p9 破坏浮点、p10（vr_offs=0）破坏整数变参，
> 均拒用。覆盖面（四件）已补齐，稳定性未达成；下一步必须动引擎侧。详见
> [U-Q_RESULT](../review/U-Q_RESULT_2026-11-06.md) §4/§5。


### T6 · 后果层布防完备（**不断写，只断 SIGSEGV 成形**；列为完整性）

**当前事实（必须先摆正）**：nerepair v2.2 = **dry-run 不修**（V5_FEASIBILITY T-5 只读锚点，
2026-11-03 19:21：`mode=dry attached=45 … repaired=0`，全日志真 REPAIR=0）；slotguard v1.0 =
observe 未布防（SLOTGUARD §7：24 h 复盘点 11-04 17:46 已过，门禁未评估）。**即：今天设备上的
后果层是完全被动的，家族 NE 仍在真实杀进程**（U-G3/G4 窗 +18/+20 自然 NE 即证）。

**上机决策项（数据已积累 ≥3 天，只差读取与研判）**：
(a) nerepair dry→armed：G0–G6+G2b 门禁数据（WOULD_REPAIR / NEAR reason=insn 规模 / repair-loop / 覆盖率）；
(b) slotguard 布防评估：4 条 CANDIDATE 逐条研判 + WRITE_MISMATCH=0 ∧ PERM=0 ∧ 槽稳定命中 ∧ 槽在
sp 之下（§7 门禁原文）；
(c) XREP 三路径（X1/X2/X3）按 WOULD_XREP ↔ SEGV 逐条对照后单独决策。
**边界重申**：布防后写仍在（R-11），内存破坏面不变；"阻止 SIGSEGV"字面达成 ≠ "阻止写入"。

> **判决注记（2026-11-06，U-H 轮）**：两项布防均被门禁数字否决——nerepair 覆盖 56/240=23%
> （V1 重扫缺陷量化）、slotguard 白名单槽 match=0+CANDIDATE 漂移（S-5 实锤）（C-284）；
> 维持 dry/observe，修复入口在代码侧。

### T7 · 厂商通道（外部）

VERDICT §8 已有对外一段话；可升级为**证据包**：{len,ip} 载荷样本（公网 IP 掩码后）、λ-流量标度
三点、lab 对照窗、post-MPU 判决链全文（C-266/C-272/C-279）、preloader DRM 魔术协议与 0x8303 复位值
（C-274/C-276）、DDRPHY+0x1520 家族读致死记录。**请求三件**：引擎身份与关断方法 / LK 级 DFX 配置项
/ DRM_DEBUG 位语义表。成本低可先行；周期不可控。注意公开仓纪律：证据包走私有渠道时按两仓规范处置。

---

## §4 优先级矩阵

| 路径 | 离线就绪度 | 上机成本 | 期望收益（λ） | 风险 | 建议序 |
|---|---|---|---|---|---|
| T1 通道断供 | 高（材料全在，函数名/寄存器面已见） | 中（ABAB + 位表） | 归零或归背景（决定性） | 中（FE 寄存器地雷，可控） | **1** |
| T3 放逐窗 | 高（设计+双件代码一轮可出） | 低（一轮 A/B） | 二元：真防护 或 收口 | 低 | **2** |
| T2 SMC 全表 | 高（34K 指令反汇编在手） | 低（若有候选：emiuctl 直调） | 二元：手柄 或 ATF 全表级关闭 | 中（SMC 参数错复位，授权内） | **3** |
| T6 后果层布防 | —（数据已积累） | 低（读取+研判+touch） | 不动 λ；止崩 | 低（双钥匙/回滚在） | **4（与 1-3 并行，无耦合）** |
| T5 谓词探针 | 中（变体设计简单） | 低 | 机制情报为主 | 低 | 5 |
| T7 厂商 | 高（材料在） | — | 外部、周期不可控 | 低 | 随时可发 |
| T4 boot 链 | 中（preloader 在手） | **高**（管线扩展+备份+砖险） | 引擎关断（若 SBC 关且位语义可解） | **高（不可逆类）** | 末位 |

**排序理由**：T1/T3/T2 都是"一轮可判、失败即收口"的实验；T4 是唯一可能"真关引擎"的本地路径但
砖级风险 + 位语义依赖厂商（与 T7 并轨更稳）；T6 与所有路径正交，随时可做。

---

## §5 判据与功效备忘（复用 FIX §4 体系，勿另造）

- **主判据 = 层 I 目标 λ**（scanary 受害者真命中，inj=0 口径）；ABAB、10–15 min/臂、同会话同 boot；
  RR ≤ 0.5 ∧ 95% CI 上界 < 1.0；A 两臂反向保护 [0.7, 1.4]；三指标（槽速率/canary/自然 NE）同窗同向。
- 热态 λ 46–58/min（洪水）⇒ 10 min 臂期望 460–580，**零结果的 P(0)≈e^-460**——一轮即决定性。
- 停止规则照 00_STATE §6：跨 boot 不比速率；无正对照的阴性不算；一窗一变量。

---

## §6 三栏

**[A] 已核实（本轮离线）**
1. 本文引用的全部实证条目 = 01_CLAIMS.tsv 既有 claims（C-221/239/258/260/261/262/265/266/270/272/
   274/276/277/279 等），未新增。
2. 本地材料在位：`tmpfiles/ug3/fw/`（7 固件）、`tmpfiles/ug6/`（tee_b + full.txt + allxrefs.txt +
   tee_analyze.py）、`tmpfiles/ug8/scan/preloader0.img`（4MB）、`tmpfiles/ug3/crdump.txt`（PPE/FE
   寄存器全景）、`tmpfiles/ug3/vmlinux_syms.txt`。
3. medmcu_b.bin strings 含 `med_dl_hnat_info_{init,trigger,cfg_hw,host_init,host_cfg_hw}`、
   `FDMA_HNAT_INFO(STATUS/MSK)`、`stop:%d … hnat_info` 路径、`INTC_IRQ_FESYS_FDMA_HNAT`（命令在 §3-T1，可复现）。
4. preloader0.img strings 含 `SBC_EN = 0/1`、`img_auth_required`、`seclib_*`（SBC 运行时判定存在，
   替换可行性可离线定案）。

**[B] 未核实（分析性判断，上机/深挖前不得当结论）**
1. "FE→MED 通道独立于 hw_nat.ko 由谁武装"——由 C-193 反推，未直证武装者。
2. "断通道 ⇒ λ 归零"——λ 三点单调是必要条件证据，充分性必须 A/B。
3. "引擎对保留窗的可达性"——两个方向都没证据，T3 就是为它设计的。
4. SBC 当前状态、tee 分区是否在鉴权集、DRM 位语义——全部未知，T4 的三个先决问题。
5. T5 捕获谓词对 store 形态的依赖度——未知。

**[C] 必须上设备（下轮入口）**
1. T1 位表落地后的 ABAB 关断对照（U-H 轮，预注册先行）。
2. T3 放逐窗 A/B（exile.ko + scanary_exile，前提门：全量 iomem + ISU 关断断言）。
3. T2 若出 SMC 候选：emiuctl 直调对照。
4. T6 三项布防决策数据的读取与研判（nerepair G 门禁 / slotguard 门禁 / XREP 对照）。
5. T4 若离线判 SBC 关：管线扩展与备份方案单独立轮审批。

---

## §7 证据与材料索引

| 内容 | 位置 |
|---|---|
| claims 台账 | [01_CLAIMS.tsv](01_CLAIMS.tsv)（`claims_check.py` 复核） |
| 判决正文 | [VERDICT.md](VERDICT.md) §15–§18（C-256..C-279） |
| 机制三环节原文 | U-G1 §3（K9）/ U-G3 §1（C-239）/ U-G6 §3（C-261）/ U-G7 §0（C-262/265/266） |
| medmcu 固件 | `tmpfiles/ug3/fw/medmcu_b.bin`（+gz 台账见 U-G4 §3） |
| tee_b 反汇编 | `tmpfiles/ug6/{full.txt,allxrefs.txt,tee_analyze.py}` |
| preloader | `tmpfiles/ug8/scan/preloader0.img`（md5 `a9785c43…`，C-274） |
| PPE/FE 寄存器全景 | `tmpfiles/ug3/crdump.txt` / `crall.txt` |
| 验收判据体系 | [FIX.md](FIX.md) §4（层 I/II、三指标、八假象） |
| 后果层现状 | [SLOTGUARD_DESIGN.md](SLOTGUARD_DESIGN.md) §7；V5_FEASIBILITY T-5（nerepair dry 锚点） |
| 内核替代边界 | [../review/V5_FEASIBILITY.md](../review/V5_FEASIBILITY.md) §2/§6 |
