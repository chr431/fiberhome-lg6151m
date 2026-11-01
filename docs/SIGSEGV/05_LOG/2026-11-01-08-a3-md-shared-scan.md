# 05_LOG · 2026-11-01-08 · A3 MD 共享区扫描（受害栈 VA 是否被 MD 侧持有）

## 1. 问题
MD/CCCI/SCP 侧共享内存里是否持有「受害进程稳定槽的用户态 VA（或其 PA、或记录载荷指纹）」？
（= VERDICT §4「MD/SCP 侧」行的前提①：存在用户 VA 导出通道。）

## 2. 假设
- H1：MD 共享区某结构中存有受害进程的栈 VA / 受害页 PA / 32B 记录载荷 → MD 侧可按 VA/PA 定位受害页。
- H0：MD 共享区不含这些值（命中数 ≤ 噪声底）。

## 3. 预测
- H1：在 MD 预留区对目标值的 8B 精确扫描命中数 > 2×噪声底且落点呈结构聚集。
- H0：各目标命中 ≤ 同区噪声值命中数。

## 4. 判据
- PASS(H1)：正对照通过（见 §4.1）且任一目标值命中数 > 2×同区噪声底、命中地址落在 MD 已知结构内。
- FAIL(H0)：正对照通过，全部目标命中 ≤ 噪声底 ⇒「无证据表明 MD 侧持有用户栈 VA」（写法遵守 §2.4 口径）。
- INVALID：正对照组失败（扫描器/mode/区域错）；或区域读出全零/不可读（内存洞）→ 该区不判。
- **正对照组（§4.1，三层）**：
  - PC-1（方法对照，全 RAM）：从 dnsmasq 受害页现场读出的两个 8B 锚点字，pascan 全 RAM 扫描**必须**命中且
    交集定位回同一页（Δ=锚点差）——证明扫描器+mode0+RAM 覆盖有效（同时它就是 patrace 替代方案，本 boot
    patrace 未装载且代理禁 insmod）。
  - PC-2（结构对照，MD 区）：对本 boot 实测的 dpmaif BAT/PIT 表区扫描 `{u64 PA, u64 0}` 16B 表项签名密度，
    必须显著高于全零基线——证明 MD 区可读且含引擎表（不是空洞）。
  - T3-explor（bat_va=0xffffffc010775000，**不作门禁**）：VERDICT §4 想用「先搜到 bat_va」当正对照，但
    「BAT 环里存着 bat_va 字面值」本身无直接证据（bat_va 是 2026-10-30 boot 的记录内容，且其 PA 跨 boot
    不定）→ 降级为探索性目标，命中才加分、不命中不判无效（理由记录在案，防硬扫硬结论）。

## 5. 样本量/功效
- 目标区：本 boot /proc/iomem 全量 reserved 洞 + /proc/ccci_dump 实测 MD 区（历史锚点 0x9048xxxx/0x906exxxx
  跨 boot 会漂移，**必须用本 boot 实测值**，§16.1/§16.3 教训）。
- 噪声底：每区同法扫 `0x1122334455667788` 与 `0xdeadbeefcafebabe`（历史 6/32 处，P-18 教训：1-2 处不构成证据）。
- LOD：单值 8B 精确匹配；命中 1-2 处且 ≤ 噪声底 = 无证据（不写「不存在」）。

## 6. 混杂与控制
- 本 boot 的槽偏移按 sampler2 实测结构常数（dnsmasq −0x1b40 / nerepair −0x3b0/−0x12d0）从**当前 pid** 的
  start_stack 重算（C-182：跨 session 偏移可沿用为结构常数，但内容统计必须本 session 内采集）。
- nerepair 是全系统 ptrace 监督者（C-175 前置）：**只观察，绝不触碰**（无 ptrace、无信号、无页表操作）。
- 值匹配只做 8B 精确：避免子串假阳（三定律）；pascan 自带噪声对照。
- 时间窗：扫描期间受害进程应保持阻塞态（不要求，但记录 ps 状态）。

## 7. 停止规则
- 任何 SEA 征兆（SSH 断/命令挂）→ 立即停该区并记录（§17.3：RAM 区 mode0 安全，MMIO 区**不扫**——本实验
  全部目标区都是 RAM 洞；SCP SRAM 0x15d00000 等 MMIO 一律不碰）。
- 设备重启/健康异常 → 全部作废重登记。

## 8. 分析计划
- 主终点：MD 区内「槽 VA 值」命中数 vs 噪声底。
- 次终点：受害页 PA 值、载荷指纹（{len=1601,ip 192.168.9.1} 的 LE/BE 组合 2 变体）命中；全 RAM 槽 VA 扫描。
- 多重比较：目标值×区逐一独立报告，不合并 p 值；结论按三档口径写。

## 9. 变更记录（实验前）
- 设备：单 boot uptime≈20,874 s；dnsmasq pid=22070 start_stack=0x7fd85b8920（槽 VA=0x7fd85b6de0，页内 0xde0）；
  nerepair pid=2850 start_stack=0x7ffbe50cc0（槽 0x7ffbe50910/0x7ffbe4f9f0）。
- 工具：/data/repro/pascan（md5 设备侧核对）；读 /proc/<pid>/mem 用 busybox dd（页对齐 bs=4096）。
- patrace.ko 在 /data/repro/ 但**未装载**，代理纪律禁 insmod → VA→PA 改用「双锚点全 RAM 交集」（PC-1 兼任）。

## 10. 结果
（实验后追加）

## 11. 判决
（实验后追加）

## 12. 偏差与教训
（实验后追加）

## 9.1 范围变更（协调方 2026-11-01 追加）
扫描区域在 MD/CCCI/CCIF/SCP 之外追加 iomem/DT 中含 wo/wed/warp/adsp/scp 的预留区（WO 计数表嫌疑背景）。
实测：WO 内存 = DT `wocpu_boot@0x15194000 / wocpu_ilm@0x151E0000 / wocpu_dlm@0x151E8000`、SCP SRAM=0x15d00000 段——
**全部是 MMIO 窗，不在 RAM 扫描范围**；RAM 内 wo/wed/warp/adsp 类预留区经 /proc/iomem 全量核对**不存在**。
MMIO 窗经 /dev/mem 读实测**返回空**（0x15105c00 试读 16B 空、无 SEA）⇒ WO/SCP 侧 = BLOCKED（通道不可用，非 0 命中）。

## 10. 结果（2026-11-01 20:0x 执行）

**设备侧实测**：md1 MemStart 0x82000000 +0x12000000（/proc/ccci_dump）；ccb=0x94000000+0x4000000；
dnsmasq pid 22070 start_stack=0x7fd85b8920（槽 VA 0x7fd85b6de0）；nerepair pid 2850 start_stack=0x7ffbe50cc0
（槽 0x7ffbe50910 / 0x7ffbe4f9f0）。扫描=pascan 8B 精确、0x80000000-0xffffffff 全 RAM、12 值（脚本 /tmp/a3_scan.sh，本地
tmpfiles/a3_scan.sh，日志 phase-AB/a3_scan.log）。patrace 本 boot 未装载（禁 insmod）⇒ VA→PA 用双锚点全 RAM 交集替代。

**① 扫描器自污染类（新仪器教训，三定律#3 实弹）**：12 个值**每个恰有 1 个 +0xf60 偏移命中**（含两个噪声值 N1/N2）——
即 pascan 自身 argv 解析出的目标值留在自己栈页固定偏移，被自己的扫描读到。噪声值同样出现 ⇒ +0xf60 类全部判自污染剔除。
后续轮次的 +0xf68 变体同理。**凡单值恰一命中且在页尾 0xf60/0xf68 的，一律不计**。

**② PC-1（方法对照）PASS**：nerepair 页 A（VA 0x7ffbe5000）锚点 A1=0x000d0cb335116000(@+0x930) 命中 4 处、其中
**0xb0500000** 同时含金丝雀三元组锚点(@+0xaa8/ab8/ac8)且 64B 上下文与 /proc/pid/mem 读数逐字节一致 ⇒ 页 A PA=**0xb0500000**。
dnsmasq 槽页锚点 DNS2=0x7fd85b8348(@+0xe18) 命中 3 页 0xb0aa2000/0xb135c000/0xb1b1a000（+0xdc0 槽 VA 自引用、+0xe00 二进制
指针同页齐验）= 3 份 fork 副本（其一已混入回收后的 `ip addr` 文本——页复用残影）。
A2=0x60001000 饱和(32)作废；D1/D2(env 串)饱和作废。

**③ 目标值结果（剔自污染后）**：噪声底 N1=5、N2=1（全 RAM/2GB）。
- 槽 VA（dns/neA/neB）：MD 保留子区 **0**；AP RAM 各 1-3 处且全部归因于受害者自身 fork 副本页/自身结构页（上下文验证）。
- bat_va=0xffffffc010775000：真 MD 保留区 0（唯一 0x92021f60 为自污染类）；AP RAM 1 处 0xb0bd8940（qctx 合法居所）。
  **T3 正对照未成立**（bat_va 在 MD 区无合法命中）——按 §4.1 预注册降级，不判本轮无效，但 MD 区内容敏感性论证只能靠噪声底。
- FP2(变体)：MD 0；FP1({1601,192.168.9.1})：≥32（半 RAM 截断）= 常见值类；其 0x911ce960/0x911cf560/0x91c84560/0x91c87560
  四处"MD 带"命中经 iomem 精分**全落 AP System RAM 带 [0x8d560000,0x935fffff]**，且**非** FE 环池成员页（769 页池核对），
  内容为冻结的 {内核VA×2, __switch_to+0xe0, 0x5360c8, 0, {len=1601,ip}, 0} 结构（6 min 零变化；0xffffffc008117690 符号化
  =__switch_to+0xe0；另两个 0xffffffc01xxxxxxx VA 无现行模块对应——模块槽残址假设 E1）。归**噪声级探索项**。

**④ 可读性正对照（判据纪律关键补丁）**：MD1 镜像带各子区（0x82/0x83/0x85/0x89f8/0x8b/0x8d0/0x936xxxxx）dd 实读**可读**
（含零内容区）；但 **CCB 0x94000000/0x95000000、medmcu desc 0x9faa0000/0x9fcb0000、lk_medmcu 0xaff00000 经 /dev/mem 读
返回空（不可访问，无 struct page 类保留）**。pascan 对这些页 n<=0 静默跳过 ⇒ **这些区的"0 命中"无效**。

**⑤ 槽在场性**：扫描窗内 dns 槽 8/8 为活 va_list 形态（无记录）；nerepair 槽 A 8 样本内 {4,0}→{1,0x7f98844e80} 小值翻动
（wait4 状态类，C-182 口径），均未见记录族 32B。

## 11. 判决
- **MD1 镜像/运行带（可读部分）：H0**——槽 VA/页 PA/bat_va/FP2 命中 0 ≤ 噪声底 ⇒「无证据表明该带持有用户栈 VA」（写法合规）。
- **CCB(64MB 主共享区)/medmcu desc/lk_medmcu：INVALID+BLOCKED**——/dev/mem 不可读，需 ioremap 类通道；本会话禁模块 ⇒
  A3 主战场未攻克，**不得**写成阴性。
- MD/SCP 侧点名（VERDICT §4 行）：本通道本轮**不可达**；建议下轮 ①LK raw shell 期直扫（无内核限制）或 ②专用 ioremap 只读助手
  （需 Lead 批准新 oneoff 二进制走 /dev/mem mmap 试验——mmap 通道未试）。
- 新增 claims：C-184（自污染类 + 可读性地图 + MD1 带零命中）。

## 12. 偏差与教训
- **pascan 自污染**：扫描器进程自身的 argv 派生值落其栈页固定偏移（本例 +0xf60），被自身扫描命中——单值单命中且页尾固定
  偏移者必须当观测者污染剔除；根治=扫描前把目标值经不可预测途径传入（文件读入）或扫描时排除自身栈页。
- **"0 命中"三重陷阱**（本轮实弹）：①自污染假阳；②区域不可读假阴（CCB 无 struct page → pread 空 → 静默跳页）；
  ③常见值类（FP1 ≥32）无区分度。判据必须分别对三者设对照。
- 历史教训 retro：md_va_scan.sh 的旧轮"MD 区扫描"结论如涉及 CCB/medmcu 带，需按 ② 复核其可读性前提。
