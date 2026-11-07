# VERDICT v3 · 32B 记录 SIGSEGV 家族（2026-11-03 收束版，取代 2026-11-01 版）

> 本文件是**对外主结论**。级别：E1 弱/单点 · E2 强推断 · E3 直接观测 · E4 因果闭环。
> 每条都带「复核」入口。**已撤回的旧结论**（88/112、自然 NE 0/4、「Transport = PA/DMA（E2）已定」、
> 「Writer = WED TX」、「每 RX 包一次机会 / 1.3 命中千包」）不得再引用，理由见 §3 与
> [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)。
> 本轮（2026-11-01 → 11-03）全部证据：`01_CLAIMS.tsv`（C-186..C-214）、`05_LOG/`、记分卡 §13–16。

---

## 0. 一句话（收束版）

**一个来自进程外部的 32B 结构化写入，落在受害进程「活着的」va_list 上（帧相对，E3）；
写入者身份仍未点名。收束时钉死的四条核心约束：**

1. **不经 CPU uaccess（实测内零命中）**：`__arch_copy_to_user` 家族漏斗 28.96M 次调用
   （两窗 292.8 MB 客户端热流量，C-206）＋嵌入大拷贝宽扫描 20.2M 调用 / 2.77M 次扫描 / 735.8 MB 源
   （C-214）——记录族 **0 条可指名命中**。口径：宽扫描的形状代理在良性字节上 ≈148 次/s 误报 ⇒
   「0 命中 ⇒ 物理排除」不可达，本项按**已测未发现**表述（E2）。
2. **需要厂商内核态环境**：lab 6.18 极简内核（无厂商栈/WiFi/CCI/客户端）两窗合计 3600.04 s，
   正对照与四重信道齐备，`inj=0` 真命中 **0**（厂商背景 0.36–0.60/min 的期望 22–36 条，P(0)=e⁻²²…e⁻³⁶）⇒
   H「必要条件」成立（C-213，E2）。
3. **帧相对、且目标进程无需执行**：scanary 五档深度臂命中点随人为帧深 D 精确平移
   （残差 0/0/0/0/0，每档 n≥191，C-171，E3）；纯用户态忙等 victim（从不进内核）命中率 ≥ 睡眠臂（C-191，E2）。
4. **随 WiFi 客户端数据面流量放缩**：热态（客户端 + 数据面活跃）13.9–20.3/min ↔
   无客户端背景 0.60/min ↔ WiFi 全族遮罩残余 0.17–0.20/min（C-199/C-196/C-204，E2）；
   写入是**普遍**的（健康进程栈 2/12 含记录，C-173），**崩溃数只是写入数的下界**。

**残余类别** = 厂商内核态（内建路径／未被遮罩的 .ko／MD·CCCI 侧／其它总线主）中一个
「**按当前栈帧定位、非 uaccess**」的写入机制（DMA/总线主写或其等价物）；**具体代码点/引擎未点名**。
**修复（后果层）已交付**：nerepair v2.2（信号级修复 + 家族覆盖普查）+ slotguard v1.0（热槽消毒）
已上机为**观察模式**（2026-11-03 17:45:32 起 ≥24 h 观察窗，零布防；见 §6）。

---

## 1. 记录是什么（结构身份）

### 1.1 字节布局（E3，109/117 份可定位）

```
偏移   内容
+0x00  u64  值1：17–18 位小值 A（归一化后 48957–165456），或 (addr<<32|len)
+0x08  u64  恒 0
+0x10  u64  值2：内存字节序就是 {u32 len; __be32 addr}
+0x18  u64  恒 0
```

- **A/B 两型不是两种载荷**：va_arg 的自增（+8）作用在 `__stack` 字段上——A 型它落在偏移 0，
  B 型落在偏移 +0x10（表现为 len+8）。归一化后**只有一种载荷**：`{A, 0, {len, addr}, 0}`。
- len 实测 `{321, 1600, 1601, 4416, 4480}`（+8 变体）；addr 是**流端点地址**
  （多数为同一公网对端、少量为本机 WAN/LAN/别名）。
- A 值域与历史「16B 长度型块」重合 ⇒ 与历史注入**同族**（形态对比，不作独立证据）。

### 1.2 它不可能是什么（否证见 §3）

不是 EDMA RX 描述符、不是 WED TXD / WPDMA TX 环条目、不是信号帧、不是 put_cmsg 家族、
不是 splice/sk_msg 的用户 iter、不是 mt_wifi 的 copy_to_user、不是页池描述符环 / scatterlist 条目。

---

## 2. 它落在哪里（最硬的一组观测）

### 2.1 写目标 = 活栈帧内的 va_list（**E3**）

scanary 自扫描金丝雀（自带 8 MB 诱饵区、每 5 ms 全扫、崩不崩都记），正式臂 900 s：

| epoch | D（人为加深调用帧） | 命中数 | topva（扫描上界−记录 VA） | 残差 |
|---|---|---|---|---|
| ep0 | 0 | 218 | 0x690 | 0 |
| ep1 | 0x100 | 203 | 0x790 | 0 |
| ep2 | 0x400 | 226 | 0xa90 | 0 |
| ep3 | 0x900 | 191 | 0xf90 | 0 |
| ep4 | 0x1000 | 231 | 0x1690 | 0 |

- `topva` 增量**精确等于 D**，残差 0/0/0/0/0；诱饵区记录命中 0；passes 177,041。
- ep4 的受害页 PA 与 ep0 不同页仍 231 条命中 ⇒「固定 4KB 页 / 固定页内偏移 / 固定栈顶相对偏移」三种模型**同时出局**。
- ⇒ H1a（固定 PA 陈旧描述符）、H1b、H3（直映射写固定 `__va(PA)`）、H5-as-pure-PA 全部被否证。
- 复核：`05_LOG/2026-11-01-kdev-scanary-romap-ptredir.md` + 设备 `/data/repro/scanary_A.log`。
- 限制：单臂；只覆盖 scanary 自己的 victim 线程；「写入者来自外部」仍非 E3。

### 2.2 写入是普遍的，崩溃只看落点（**E3/E2**）

- 自然长驻 daemon 栈上有**稳定记录槽**（sampler2，零模块：150 ms/轮读 `/proc/<pid>/mem`）：
  `dnsmasq` `start_stack−0x1b40` 113 次采样内容恒定；`nerepair` `start_stack−0x3b0` 60 s 内 8 种不同 q0
  （同一 VA 被反复重写）；命中时进程**阻塞在 wait4/ppoll** ⇒ 写入者不需要目标执行。
- **健康进程栈也含记录**：12 份健康 `sh/ash` 栈里 2 份/6 条（strict）⇒「崩溃数」是写入数的极小下界。
- 追加（C-191）：纯用户态忙等 victim（从不进内核）命中不打折 ⇒ 目标甚至不需要处于内核态。
- 复核：`_local/evidence/crash-root/natctl/`、lab 的 `sampler2.log`。

### 2.3 自然 NE 的影响面（**E2**）

- 4 起自然 NE（`sh cfg_heal`×2 / `tr` / `tail`）的 `.stack` **4/4** 含与 canary 完全相同的 Q2；健康基线 2/12。
- 「记录在场」≠「记录致死」：需 fault addr 对齐 + PC 证据（判据见 P-12 的 far/pc 列）。

---

## 3. 已证伪清单（**不要再引用旧结论**）

| # | 旧结论 | 否证依据 | 级别 |
|---|---|---|---|
| X-1 | 记录 = EDMA RX 描述符 | 字段级（q0 非 page_frag 形态；q1=0 ⇒ DD=0；len>驱动上限；无 L3/L4 字段） | E3 |
| X-2 | 记录 = WED TXD | `TMAC_TXD` 无 L3/L4 地址；WPDMA TX 环实测 16B `{PA_lo,ctrl,PA_hi,0}` | E2 |
| X-3 | 固定物理页 + 固定页内偏移 | 75 pid / 53 种页内偏移全部崩（模型预测仅 1–2 种能崩） | E3 |
| X-4 | 固定栈顶相对偏移 | scanary 5 档随 D 等距平移、残差 0 | E3 |
| X-5 | 硬件描述符"写回 L3/L4" | len 是软件量（1601/1664 > 1536 DMA 上限） | E2 |
| X-6 | 信号帧 | 目标在活 sp **以上** 0x22b0；信号帧恒在 sp 以下 | E3 |
| X-6b | H1a/H1b/H3（固定 PA / 陈旧 PA / 直映射 VA→PA 写） | 三者都预测"目标与活帧无关"；4 档帧深全部随 D 平移（残差 0）⇒ 出局 | E3 |
| X-7 | `put_cmsg` 家族 | cmsg_len 排不出 A；无跨 syscall 缓存用户指针窗口 | E2 |
| X-8 | `pipe_to_user`/`sk_msg_recvmsg` | dst 都是本次 syscall 自己的 iov | E3 |
| X-9 | 88/112 与"三副本" | 复算 82/112（Wilson CI 64.3–80.5）；第三份是 ASCII 伪影 | E3 |
| X-10 | 自然 NE 记录份额 0/4 | 新一批 4/4（C-142 改判） | E2 |
| **X-11** | **CPU uaccess 通道（`copy_to_user` 家族 + 嵌入大拷贝）** | **漏斗 28.96M 调用/292.8 MB、宽扫描 20.2M 调用/735.8 MB 源，记录族 0 条指名**（C-206/C-214）。**注意**：宽扫描特异性失效 ⇒ 按"已测未发现"，不按"物理排除"引用 | E2 |
| **X-12** | **mt_wifi 模块本体** | **杀开关三窗 259/305/208、R=1.31 无压制；热窗 12 个 copy_to_user 站点全观测、无记录族命中**（C-200/C-202/C-203） | E2/E4-级观测 |
| **X-13** | **hw_nat / PPE offload 路径** | **arm3 遮罩实证缺席后写入仍 690 条/1200 s**（C-193） | E2 |
| **X-14** | **WiFi 模块族（8 项遮罩）为"存在性必要条件"** | **遮罩后残余 4/1200 s、5/1800 s ≈ 无客户端背景；"压制"主因 = 客户端流量消失**（C-192/C-196/C-204） | E2 |
| **X-15** | **mtk_wed / WO 填充链为写入者** | **fill 回调 store 目标 100% 内核地址（vmalloc 栈 / linear kmalloc）；三 boot 基址复核一致**（C-197/C-211/C-212） | E2/E3 |
| **X-16** | **dma_map_page_attrs / dma_map_sg_attrs（两个变体）** | **1825 s 无客户端背景窗 fake=0 / PageAnon=0**（C-207）。边界：只此两变体 + 非热态 | E2 |
| **X-17** | **页池两数组（8×512 描述符环 + 8×scatterlist[256]）为同写者** | **91 次核对 0/13；3408 条环条目与受害者页无映射**（C-210） | E2 |
| **X-18** | **H6「内核用保存的 sp 定位用户栈」** | **纯用户态忙等（从不进内核）victim 命中率 ≥ 睡眠臂**（C-191） | E2 |

---

## 4. 正向约束（收束核心）

| # | 约束 | 证据 | 级别 |
|---|---|---|---|
| Ⅰ | 写入不经 CPU uaccess（实测覆盖内） | C-206（28.96M/292.8 MB）、C-214（20.2M/735.8 MB 源） | E2 |
| Ⅱ | 写入的产生/触发需要厂商内核态环境 | C-213（lab 两窗 3600 s 零写入，期望 22–36 条） | E2 |
| Ⅲ | 帧相对；目标无需执行、无需进内核 | C-171（E3）、C-191、sampler2（C-175 系） | E3/E2 |
| Ⅳ | 随 WiFi 客户端数据面流量放缩 | C-204（13.9–20.3 / 0.60 / 0.20 per min）、C-199、C-196 | E2 |

B4 遮罩矩阵（lab v4.1 b4lab 参考镜像）分解：arm1（WiFi 族 8 项）P ⇒ 遮罩后残余率 ≈ 无客户端背景；
arm3（hw_nat）P ⇒ 690/1200 s；arm2 INVALID（mt7992 硬依赖 mtk_wed，运行时不可达）。
⇒ 写入者**不依赖**上述模块的"存在性"；依赖的是**客户端数据面流量**（约束 Ⅳ）与**厂商内核态环境**（约束 Ⅱ）。

---

## 5. 残余与覆盖边界（诚实清单）

- **未点名**：厂商内核态中"按当前帧定位、非 uaccess"的具体机制/代码点（内建内核路径、
  未被遮罩的 .ko、MD/CCCI 侧、或其它总线主）。
- **覆盖边界（不得读成"已排除"，任何引用必须带口径）**：
  - audit 窗（C-189）只覆盖 audit-on **之后 fork** 的进程（长驻守护不可见），且**不含 ptrace=117**；
  - dmahook（C-207）只覆盖 `dma_map_page_attrs`/`dma_map_sg_attrs` 两变体、非热态；
  - 漏斗不覆盖原子上下文失败写、寄存器直写等其它口径；
  - 393 个用户写站点未解析、内联 `stput`/`__put_user` 不在扫描口径、169 个厂商 `.ko` 无 BTF/DWARF；
  - SRAM/MMIO 未扫；lab 的"目标页资格"共线混杂不可消除；6.18 vs 5.15 版本差。
- **机制谜题未解**：写入者如何做到"帧跟随"（H6 削弱、H7 按进程缓存相容但未证）；
  为何对客户端数据面流量放缩。

---

## 6. 修复与兜底状态（2026-11-03）

- **nerepair v2.2**（在役）：信号级修复 + 家族覆盖普查（XFORM）；三条扩展修复 X1/X2/X3 **默认关**，
  只记 `WOULD_XREP`；`/data/gw/nerepair.xrep` 未建。
- **slotguard v1.0**（在役，观察模式）：3 s 周期扫白名单槽 + 遥测；三槽 `observe`、`slotguard.arm` 未建 ⇒
  **零内存写**；实测 0 SANITIZE / 0 WRITE_MISMATCH / 0 PERM，4 条 CANDIDATE（自学习只记录）。
- **观察窗**：起点 2026-11-03 17:45:32 +0800（boot `9129c459…`），≥24 h 后按门禁评估
  （CANDIDATE 逐条研判 ∧ WRITE_MISMATCH=0 ∧ PERM=0 ∧ 至少一槽稳定命中 ∧ 槽在 sp 之下）再决定布防。
- **部署当晚异常（如实记录）**：17:45 旧 boot 发生**全用户态停摆** → healthdog 应急复位
  （armed 看门狗 90 s 兜底，设计内保护动作正确执行；pstore 存档）。新组件与该 boot 的运行期无关
  已逐条证明（旧 boot 内存中为 watchdog v1.52 / nerepair v2.1、slotguard 未运行）；**停摆根因未定**
  （与家族活动窗口及部署自身负载同期，不作因果断言），观察窗内监控复现。
- 布防/修复原则不变：**不停止写入**；一切布防动作均以观察窗数据 + 门禁为前置（见 SLOTGUARD_DESIGN §7）。

---

## 7. 复现与证据索引

| 内容 | 位置 |
|---|---|
| claims（204 id / 174 active） | `01_CLAIMS.tsv`（`python tools/oneoff/sigsegv/claims_check.py`） |
| 本轮逐日实验记录 | `05_LOG/2026-11-02-*.md`、`05_LOG/2026-11-03-*.md`（b4/d19–d28/funnel/t1） |
| 记录形状/分类脚本 | `_local/work/crash-root/static/`、`tools/oneoff/sigsegv/static2/` |
| canary / 仪器源码与产物 | `tools/oneoff/sigsegv/bmods/`（tuphook/funnelv2/dmahook/review 文档）、`tools/oneoff/sigsegv/`（scanary/vsurv/auditwatch…） |
| lab 内核（永久资产） | `tools/labkernel/`（v3.1，`_drill_backup/labkernel/boot-lab31-signed.img` md5 `9934cca2…`） |
| 部署记录与证据 | `_local/investigations/sigsegv-tools/phase-AB/F1-deploy-observation.md`、`_local/evidence/f1-deploy/`（INDEX.md5） |
| 记分卡（对外并列页） | [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)（§16 = 收束记分） |
| 兜底设计与自审 | [SLOTGUARD_DESIGN.md](SLOTGUARD_DESIGN.md)、[REVIEW_SLOTGUARD.md](REVIEW_SLOTGUARD.md) |
| 修复台账 | [FIX.md](FIX.md) |

---

## 8. 一句话给厂商/内核侧（收束版）

> 本记录表现为「每 16B 槽 `{u64 值, u64 0}`」的 32B 写入，目标精确落在用户态**活着的 va_list** 上，
> 且目标进程阻塞、甚至纯用户态忙等时依然发生。我们已实测：**CPU uaccess 通道零命中**
> （`copy_to_user` 家族 2895 万次）、**lab 极简内核对同一 canary 零写入**（3600 s ×2 窗）、
> **写入率随 WiFi 客户端数据面流量放缩**。请在**厂商内核态路径**中排查
> 「按当前栈帧（或按进程最近栈帧缓存）的、不经 uaccess 的写入」——优先 **MD/CCCI 侧**与一切
> 「缓存用户 VA / 帧地址后再写」的私有驱动、内建路径与总线主（DMA）编程点。

---

## 9. 夜间战役增补（2026-11-05 晨，U-F1/F2）

**写入者仍未点名；本轮新增两条 E2 级出局与一次仪器事故**（详录
[../review/U-F1_RESULT_SUITE_2026-11-05.md](../review/U-F1_RESULT_SUITE_2026-11-05.md)，claims C-215..C-220）：

1. **B1（非 remote GUP 族 14 入口）出局**：wrhunt2 联合窗（23:57–00:26）14 钩活性
   27.7M/1.98M/1.60M… 次调用、ring 零事件，同窗受害者被写 208 条（全夜 549 条）；
   正对照 P1/P2/PG1 全过。
2. **B4-常驻缓存出局 + WED RXBM 环出局**：全 RAM 唯一槽位 PA 持有者 = patrace 自身
   （观察者工件→正对照，换受害者原地更新复证）；WED RXBM 环 600 s×116K 轮询零命中
   （环内现行值对照 3827/3827 全中）。
3. **romap 仪器事故**：selftest 首次真跑硬复位一次（B2 判定顺延，模块隔离）。

**残余空间收窄为**：B2'（手工内联页表走查 + kmap 别名 store，待 romap 修复版）、
B4t（同上走查后喂其它 DMA 环，待环 PA 发现 + ringpoll 扩展）、B3 残余（EL0 非探测写者，
待 DIS-2/CAM-P/CAM-W）、B5（终局 B 余项）。对外口径仍以本文件 §0 为基 + 本节增补。

## §10 增补(2026-11-05 03:2x,CAM-W Tier B 仪器战役,U-G1)

用户授权"内核取证深挖,允许多次崩溃"后的日班战役(报告
[U-G1_RESULT_WWATCH_2026-11-05.md](../review/U-G1_RESULT_WWATCH_2026-11-05.md),
claims C-221..C-227)。写者仍未点名,但拿到四件硬货:

1. **K9(新钉死约束,E2)**:写者与受害者**活 va_list 内容**耦合——监控+跳过受害者
   在目标槽的自写,λ 16/min→0~1.3/min;解除监控回弹 12.3/min;再监控再冻结
   (可逆因果开关)。写者在其 store **上游**读/校验目标槽内容(K5 的细化:
   不只需"深帧变参活动",需要该地址上正在进行时的 va_list 写入流)。
2. **EL1 观察点 fire = 本固件平台级死亡**(E2,≥3 干净复现,panic_on_oops=0 亦无
   oops,疑 MTK AEE/mrdump 拦截 EL1 debug 异常):对 EL1 写者的 watchpoint 点名
   在本固件被结构性封死;EL0 tier 全链可用(PC-U2 34/34)。
3. **漏网 5 落地零 fire(E1)**:监控期内完成写入不经 EL0/STTR 通道 ⇒ 写者 store
   形态 ∈ {EL1-plain(PAN-open)、EL1-别名、DMA};结合 §9 的 GUP 族出局,
   **B2′(别名 store)与 B4t/B5(DMA)为残余二强**,且 c5 崩溃签名(正确别名
   监控 + 短窗即整机死)与"真写者别名 store 触发 EL1 fire→平台杀"假说一致。
4. 平台事实入库:DBGPRCR 写致死(2 复现)、深睡态抹 WRP 寄存器(禁深睡后 drift=0)、
   PAGE_OFFSET=0xffffff7f80000000(AT+/dev/mem 互证)、裸 -c 模块需手写
   vermagic/__this_module(busybox 静默 rc255)。

**下一步入口**(按预期收益):① AEE 拦截解除/绕过 → 解锁 EL1 tier → alias 槽
fire 即终局 A;② 用 AEE 自己的 dump(mrdump/expdb)当"尸体证词"复检 c5;
③ romap 修复版 B2 窗;④ B4t 环发现 + ringpoll 扩展。

## §11 增补(2026-11-05 日班 U-G2:PE-store 彻底出局 + WED 全族出局)

[U-G2_RESULT](../review/U-G2_RESULT_2026-11-05.md),claims C-228..C-234。三轮合取后判决:

1. **写者=非 PE 代理(E2,C-228)**:EL0/STTR(U-G1)+EL1 双 VA 形态 store(本日 171 落地零 fire)
   ⇒ 32B 记录由 **DMA 类引擎或 EL2+ 代写**——B2' 的"store 侧"终局出局(其"走查/门控侧"仍可能为内核)。
2. **WED 复合体全族出局(E2,C-229)**;hw_nat 内核模块出局(E1,C-232,硅核保留);
   无 RAM 常驻状态(E2,C-231);无反调试感知(E2,C-230,K9 细化为受害者执行保真度门控)。
3. 剩余点名通道(按结构吻合度):**mtk_eth EDMA/QDMA 环**(灌流即 eth1 路径,内容=len+ip、
   时序 ±20ms 全吻合)> PPE 硅核 FOE > ccci/dpmaif > B5。ringfind 需全量重扫(本次 6% 截断)。
4. 事故纪律:厂商 debug/MMIO 接口默认有害(4 复位);观察者工件分类学入档;探索扫描禁静默截断。

对外口径:§0 基线 + §9/§10/§11 增补;写者未点名,机制面已收敛为"非 PE 代写+内核级门控"。

## §12 · U-G3 长窗战役(2026-11-05 下午):机制类级点名——总线级实时地址跟随写者;软件面全负闭环

- **C-239(核心)**:MIG 实验(95×整页 MADV_DONTNEED 回收,槽 PA 全量迁移)记录持续同 VA 新 PA、λ 40.7/min 不坠 ⇒ 写者**每次写入实时解析目标**(无缓存 PA);结合 VA 在任何可读面不存在 ⇒ **机制=总线级嗅探受害者 CPU store 物理地址**——K9 冻结/回弹因此获得机制级解释(冻结自写=地址流消失)。
- **C-235/236/237**:全部已知环(µs 轮询)+ PPE/FE 3816 寄存器(活跃期 8 快照)+ 全部 carveout(SSPM/medmcu/wocpu/WED)对目标 PA **零出现** ⇒ 写者状态完全在软件可读面之外。
- **C-238**:内容源=硬件旁路转发流(三接口 tcpdump 零吻合、多接口公共 IP、GRO 聚合长度)。
- **C-241**:`scp_bus_tracker@0x15f52000` 安全实读=19 条目同构带宽配额监控(活计数器)——按主控总线事务观测基础设施在役实证(载体族代表)。
- **C-240/242**:boot 不变式;EthMD32=PHY 固件出局;HSDMA 未探测出局;"陈旧硅核"解释修正(每 boot 正常配置)。
- **C-243**:SRAM 全量 readl 循环=硬复位×2(#12/#13,授权内);memcpy_fromio 小读幸存。
- **身份归口**:EMI/互连级观测基础设施或 EL3 监视代理;**下一步=ATF/bl31(LK 链读闪)+EMI MPU 勘察+消融级联**(U-G3_RESULT §3)。


## §13 · U-G4 晚间续战(2026-11-05):协处理器层全穿透;地址锁存收至 GC 核 TCM / EMI-hw / EL3

- **C-244**:medmcu SRAM(128KB)、SSPM SRAM(160KB)kHz 级重扫×200k、MCUPM 可读区、MED DRAM(ms)——**全部零命中**(活受害者);单 memcpy_fromio 安全(致死模式=readl 循环/audio 块)。
- **C-245**:medmcu 固件功能全曝光=MED 桥(FDMA_HNAT_INFO=eth 流信息入 MED 的机制通道、sw_map/bat 地址表、UL latch snapshot、GC×3 微码引擎、bus tracker 属主)——载体类完全吻合。
- **C-246**:46 分区 GPT 全图;7 个 1MB 固件分区 Linux 直读已拉齐;dd/mmap 语义澄清(C-237 维持)。
- **C-247**:audio SRAM 读致死第 2 复现(#15=#13);#14 自发未归因。
- **剩余身份空间**:GC 核 TCM(medhw-gc0/1/2)/ EMI-DRAMC 硬件观测器 / EL3(tee/ATF)。下轮第一刀=**MED 消融**(λ 归零与否二分)——需 atci 协议或 poweroff 工具打通(U-G4_RESULT §2)。



## §14 · U-G5 EMI 全面武器化(2026-11-05 晚):16 域穷尽消融——写者不在任何 EMI MPU 管辖域;GC 核与全部总线 master 类出局

- **C-249**:EMI MPU 寄存器模型全解(64KB 粒度 SA/EA、16 域×2bit APC、高索引优先、00=放行/11=拒绝、违例三寄存器 0x1f0/1f8/1fc)且 EL1 可编程;**A53 CPU 访问豁免**(祭品 touch/evict/verify 法,全 APC 不阻)。
- **C-252(本轮核心)**:活受害者槽位 64KB 块上 **d0..d15 全部 16 域逐一拒绝**(18 有效窗+活性断言,λ 基线 36–70/min):**λ 无一崩塌** ⇒ 写者不发出任何普通互连级 DRAM 写 ⇒ **写者走 A53/EL3 CPU 豁免路径,或为 EMI/DRAMC 内部注入**。同窗违例 2400+ 条(全为网络页池 DMA、地址非槽页)= 仪器阳性对照(C-251)。
- **推论(排除)**:GC 核(medhw-gc0/1/2)与一切协处理器/外设总线 master 若为写者,其写必带域号、某域拒绝必崩 λ——未崩 ⇒ **全类排除**(身份空间自 U-G4 的三类收缩为二类)。
- **C-250**:EMI ISU=在役总线采样单元(8MB 活缓冲、事务 PA 对),但其 con-reg 对 EL1 读写皆总线挂起(#17/#18,魔数 0xDECDDECD/0xDEC0DEC0)——**ISU 控制面 EL3 独占**,ISU=观测者而非(直接)记录写者(缓冲无 32B-record 族)。
- **C-253**:crash #16..#21 六连全归因(region31 卫生/ISU con 读写/拒全风暴/违例积压/DDRPHY 地雷);MMIO 地雷册三类扩编。
- **身份空间(U-G5 后)**:**{EL3/ATF 驻留代码(on A53), EMI/DRAMC 内部引擎}**。决胜件=tee_b(BL31 mt6990,本地)静态分析:DRM_DEBUG_CTL 处理器、ISU 编码路径、sspm_base 引用(唯一出现)。


---

## 15. U-G6 · 终局判决:写者 = EMI/DRAMC 内部硅引擎(post-MPU 注入)(2026-11-05 晚)

> 决胜件=tee_b(BL31 mt6990,TF-A v1.6)静态全读 + 全固件词汇扫描 + 设备保留内存/DFD/ISU 复查;
> 本轮零硬复位。报告=docs/review/U-G6_RESULT_2026-11-05.md;claims C-256..C-261。

**判决:32B 记录写者不是任何软件,而是存储子系统内部的硅引擎(post-MPU 注入,EL3 门禁控制面),
内容=本机硬件卸载流(MED hnat_info 族)。**

| 层 | 出局证据 |
|---|---|
| EL0 用户态 | U-G1:非 STTR |
| EL1 内核(含 linear-map 别名) | C-228:alias+uva 双 VA store watch,171 落点零触发 |
| EL2 | 无 hypervisor(/dev/kvm 无、无 kvm 模块、CPE 内核 EL1)——C-257 |
| EL3/BL31 | C-256:静态全读(34,221 指令/807 字串全 xref),无 32B-record 存储形状、无流/网络词汇、无每包触发;运行时服务全部枚举(DRAMC-ATF 调试访问器/音频 BANK 常量查询/EMI-MPU setter/connsys-GPS remap/固件装载/崩溃 dump/DFD 链) |
| 全部协处理器+总线 master(GC×3/SSPM/MCUPM/SPM/DPM/MED/wocpu/PPE/EDMA/WED) | U-G5:16 域穷尽拒绝 λ 不塌(阳性对照 2400+ 违例);modem 管辖由内核专用 MD 违例机器佐证(C-259) |

⇒ 写者的 DRAM 写端口**不带任何 EMI MPU 域**——同类只有 CPU 端口(全软件出局)与 MPU 之后的
内部通路 ⇒ **存储子系统内部注入**。内容源唯一=medmcu(MED DL hnat_info/pit_nat 环,C-258),
但其本体 MPU 管辖出局(C-259)⇒ 流数据经 EMI 内部观测面(与 ISU 同面)喂给注入引擎。C-239 的
总线级活址跟随观察成立,机制归宿即该 post-MPU 层(窥探点注入)。

**命名级嫌疑对(均 EL3 门禁、均有 DRAM 写能力,本轮均无法以名字排除)**:
1. **EMI-ISU**(自有 0x80B 记录族在 8MB 保留 buf;无 32B 族;con 寄存器 EL1 读写皆致死 #17/#18)
2. **DRAMC DRM_DEBUG 族**([DRAMC-ATF] 访问器在 BL31;AO/NAO 可见调试寄存器读=0;DDRPHY+0x1520 致死)

窗口几何(C-260):历史命中 PA 全在可分配 RAM,与 ISU(0xbf000000+8M)/md 环(0x82–0x98 块)/
DFD(0xffc00000)/wocpu(0xa1be–0xa3fa)全部保留窗口不相交;ISU buf 无 32B 族;DFD buf 为静态
位图 ⇒ 写者无固定保留窗口、无已知缓冲含其记录(与每写解析一致)。

**下一发点名弹(已具备,零地雷路径)**:内核导出的 SMC 控制路径(mtk_emiisu_control +
emiisu_ctrl_store sysfs;DRAMC-ATF 访问器的 SMC 号待从 SIP 分发器提取)⇒ λ-vs-引擎关断对照:
经 SMC 逐一关断 ISU/DRAMC-debug,λ 塌者为名。后果层修复(nerepair v2.2 + slotguard)维持现役。


---

## 16. U-G7 · 终极点名弹:写者 = **无可达控制面的 post-MPU 固定功能注入(存储子系统内硅)**(2026-11-05 深夜)

> 报告=docs/review/U-G7_RESULT_2026-11-05.md;claims C-262..C-266;本轮零硬复位。

**主刀:EMI-ISU 可逆因果关断对照**(C-262):
厂商 `mtk_emiisu_control(0/1)` 经 emiuctl.ko(kallsyms 定位)调用;关断经 **buf-md5 冻结**验证真实生效、
重开经 **buf 恢复翻转**验证;λ 全程 48.0/47.9/48.6/51.4(min⁻¹,669 真命中,受害者活,2400pps 洪水)——
**对 ISU 状态零响应 ⇒ ISU 出局**。附带修正 C-250(con 真址=0x11d810,EL1 可控;#17/#18 死于错地址)。

**其余控制面同轮闭合**:DRAMC-ATF 访问器=崩溃路径专用、无 SMC 入口;DRM_DEBUG 可见寄存器=0(未武装);
SPE 不存在;EMI 寄存器页/协处理器 SRAM 无环基址持址者;命中=栈顶两页多偏移记录阵列、冷 decoy 零真命中(C-265)。

**终局身份(C-266)**:全部可命名代理(4 个 CPU 异常级、8 件固件、全部带域 master、ISU、DFD、DRAMC-debug、SPE)
因果或状态出局 ⇒ 写者为**存储子系统内 post-MPU 固定功能注入引擎,位于一切可达控制面(软件/EL1 寄存器/SMC)之下**;
唯一不可读的残余子位置=**DDRPHY DFX 族(DDRPHY_AO_CHx+0x1520,EL1 读即致死)**。

**工程结论**:本机不存在可达的根除开关 ⇒ **后果层修复(nerepair v2.2 + slotguard,现役)即正解**;
根除路径只存在于厂商文档/EL3 调试固件/LK 级 DFX 配置,非本机可控。判定战役到此收束。


### §16.1 证据认识论(判定性质说明)

C-266 为**排除法结论,非正面锁定**。分层:
1. **正面**:写者行为/输出(32B 形态、内容族、λ-流量标度、热页集中、活址跟随、冷 decoy 零命中)=直接测量。
2. **半正面**:写路径不带任何 MPU 域(U-G5 穷尽+阳性对照)=对写者自身的性质断言;但该性质不区分 CPU 端口与内部硅。
3. **纯排除**:CPU 四级软件、全部带域 master、ISU(可逆因果干预)、DFD、DRAMC-debug 可见面、SPE 逐一出局 ⇒ 剩余=无可达控制面的 post-MPU 代理。
4. **盲区标注(最弱环)**:"DDRPHY DFX 残余子位置"=唯一读不到的寄存器家族,**是"看不见"的标签,不是"就在那"的证据**。
技术保留:结论依赖 MPU 域模型逆向正确(三源互证)+端口语义分类完备(无未知第三类端口)两假设。
正面锁定所需(边界事务截获/DFX 读出/厂商文档)均不在本机能力内;"本机无根除开关"本身即排除法产物,行动结论不受影响。


## 17. U-G8(2026-11-05 深夜)· DFX 正面读出:可见面零签名,终局身份正面强化

**死亡 dump 武器化**:BL31 复位路径把完整 DRAMC/DDRPHY 调试寄存器集打印到串口——含 EL1
读即致死的 `DDRPHY_AO_CHA/CHB+0x1520`。sysrq-b 按需触发(4/4),~20ms 打完,字节在复位
完成前离机;"死之前把数据传出"由此成立且已归档(1.45MB 原始串口流)。

**四窗矩阵**(空闲/活跃 × 年轻/长稳):

| 窗 | uptime | λ | +0x1520×2 | DBG0 | 判 |
|---|---|---|---|---|---|
| #1 空闲·长 | 2.58h | 0 | 0x80080007 | 0x8 | 基准 |
| #2 活跃·年轻 | 6.2min | 46/min | 0x84080007 | 0xc | 与 #3 同态 |
| #3 空闲·年轻 | 4.2min | 0 | 0x84080007 | 0xc | **否定 bit22/bit2 写者相关性** |
| #4 活跃·长 | 32.5min | 40/min | **0x80080007** | **0x8** | **与 #1 逐位全同** |

⇒ **匹配生命周期相位时,写者活跃与空闲在全部 12 个可读 DFX/DRAMC-debug 寄存器上逐位
相同**(C-270):bit22/bit2=DRAM 引导后 settling 态(年轻恒置、长稳清、洪水不重置);
RGU SW_WDT 不对称=内核年龄伪影;C-254"未武装"修正(真址 0x10005030=0x8303,C-268)。

**对 §16.1 认识论的更新**:第 4 层"盲区标注"升级为**已读、有界、零痕迹**——DFX 族的可读
子集不含写者状态;写者在一切控制面(§16)与一切可读调试面(本轮)之下。本机正面钉定的
可达上限至此:**可见面无签名 + 控制面无手柄**,写者=存储子系统内无可观测手柄的固定功能
注入;跨过上限只剩厂商文档/EL3 调试固件/边界事务截获。工程结论不变:nerepair+slotguard。

### §17.1 追补修正（2026-11-06 清理轮）
环形日志语料（15 个历史死亡 dump）证伪 §17 的"bit22/bit2=DRAM 生命周期"机制规则（4.1h 仍
置位、21min 已清零）；**核心判决不变且更强**：writer-active 与非 writer 死亡在可见 DFX 集上
取值分布完全重叠（两类都出现 0x8408/0x8008）⇒ 可见面不存在写入者专属取值。单对快照
（#1 vs #4）同一不再作为论证主据；6 项寄存器级结论中此项降级为"分布重叠"，其余（零签名、
dump 武器化、ATF 缓冲零、EL1 非 NS-mask、C-254 修正）全部维持。见 C-272。

## 18. U-G9(2026-11-06 凌晨)· 自我关断实验:两条候选全出局

**DRM_DEBUG_CTL(唯一破译了写协议的调试控制面)**:按 preloader 魔术协议(值|0x55000000、companion|0x59000000)
从 EL1 做四次写(原值/清 bit15/置 bit16/companion)→ 读回全部不变、无异常 ⇒ **该页 NS 只读,写仅安全态可执行**;
ATF 又无此 SMC(U-G7)⇒ "照抄厂商关 DRM 调试"在本机不可行(C-276)。
**emicen EMI 监视器**:写入者活跃时它**本来就是关的**(+0xf8=0)⇒ 非写者;`init(2)` 启动调用 = **总线挂死**
(纯挂起、WDT 复位、无 Oops),不可用作对照(C-277)。
**两次复位全自愈**(#22 自伤未对齐 MMIO 读/对齐故障;#23 init 挂死),无手动上电、无启动环;两组死亡 dump
(+0x1520=0x8008)仍无写者签名(C-272 一致)。
**判决**:EL1 可达的"关"不存在;写者在一切可达控制面之下(C-266/C-272),仅安全固件/厂商内部可动。

## 19. U-H(2026-11-06 日间)· 阻断路径首批上机判决:T3 放逐关闭 / T5 签名钉死 / T6 门禁量化

> 报告=docs/review/U-H_RESULT_2026-11-06.md;claims C-280..C-284;预注册+修订 A/B 同日先行;
> 零硬复位,设备终态干净(模块 163 基线/受害者 0/ISU ON)。

1. **C-280(放逐窗关闭)**:同进程双 victim 配对实验——保留子区窗(pl-drambuf 0x9c200000,
   /dev/mem cacheable 直映)栈与匿名栈被**同率涂画**(RR 1.096/0.939 双窗,λ_A 100–153/min,
   功效超门 50×;两臂各一次同 pc/同几何真实击杀;窗内冷区 0)⇒ **注入无 DRAM 范围/buddy 限制,
   13_BLOCK_PATHS T3 关闭**;顶层 removed 段(ISU 窗)因非缓存映射根本不能承载栈(未对齐即 SIGBUS,
   实测)。
2. **C-282/C-283(谓词钉死,本轮最大机制收获)**:同址同值的**手写 store 流四种形态全不可见**
   (对照 118–331,esink 证明流在跑);编译器变参与手写的差分被单变量臂定位——**补上 4×`stp q`
   (32B FP 保存事务)即可见性从 0 恢复到 0.86** ⇒ 目标捕获签名=**变参 prologue 的 32B 事务流**
   (用户态唯一常规 32B store;记录本身也是 32B——自洽)。K9/C-239 的"活 va_list 流"触发器
   由此获得结构级解释;并浮出**可部署缓解候选**:自研二进制变参 prologue 改形(拆宽)=隐身
   (待落地轮,含此消彼长监控)。
3. **C-284(后果层门禁量化)**:nerepair 覆盖 56/240=**23%**(V1 重扫缺陷实锤;本 boot 家族击杀
   hostapd/ip/sh 全在未挂接集)⇒ 不 arm;slotguard 白名单槽 match=0+CANDIDATE 槽漂移
   (dnsmasq 0x12b0→0x1640,S-5 实锤)⇒ 不布防;XREP 同因关闭。两修复入口均代码侧
   (周期重扫/槽自愈),留待后续轮。

对外口径:§0 基线 + §15–§18 增补 + 本节;写者身份不变(post-MPU 固定功能注入,C-266/C-272/C-279),
本轮是**阻断路径**的首批经验判决。

## §20 U-I 轮（2026-11-06 下午）：T5 隐身落地成立 + 签名子因钉死 + T1 位图/活体面

报告=[U-I_RESULT_2026-11-06.md](../review/U-I_RESULT_2026-11-06.md)；claims C-285..C-291；
预注册 U-I_PREREG（修订 A 先行落档）。本轮 1 次自伤复位（#24，E0，自动恢复）。

1. **C-285/C-286(签名终版)**:natfp 跨 boot 复验 RR=1.245;子因四臂——nat2q 1.041(≥2 邻接
   32B 即满)、qoff 1.004(对齐无关)、nat8s 0.547(16B 同址同值减半仍可见)⇒ 签名=**连续
   FP 源寄存器保存区写入突发**;再由 W2 边界(孤立 32B 物化+散布 spill 零触发)钉死:
   是**保存区模式**,不是"出现 q 源/32B 事务"本身。
2. **C-287(方案 A 核心前提设备级成立)**:真实二进制去掉变参 prologue 的 FP 保存
   (stealth2:no-FP-save shim,vr_offs=0)**600s 零外写**(对照 68,P=e^-68);str-q shim
   (stealth1,台账 11/调用)≈原生(0.868)——可见度随 FP-store 台账定量排序。前提清单 6 项
   已清 3,剩:热 boot 复验、此消彼长长窗、性能代价、真守护部署。
3. **C-288(写者强度 boot 依赖)**:同洪水 λ 83–161/min→复位后 6.8/min(塌 12–24×)——
   boot 态门控写者武装强度;跨 boot λ 比较必须同 boot 配对。
4. **C-289/C-290(T1 半步)**:MED 静态位图(0x38013000 配置块/STATUS-MSK 对/停止 IPI 任务/
   AP 侧 mtk_ipi_send 族)+ AP 活体面(0x15104xxx 运动索引/描述符,洪水窗实测)——断供的
   两条干净路径成形(MED 运行时表速率配对 / IPI 停止协议);盲写臂按门禁正确跳过。
5. **C-291(纪律)**:#24=busybox seq 十六进制端点输出十进制被 %lx 吞——MMIO 批读偏移必须
   显式十六进制化;入 AGENTS 候选。

对外口径:§0 基线+§15–§20;写者身份不变;**阻断路径首次拿到可部署级阳性(T5 隐身)**,
T1 保持"一轮可判"待下轮钉归属。

## §21 U-J 轮（2026-11-06 傍晚）：stealth2 热 boot 复验成立 + T1 映射/计量面 + 链①质疑

报告=[U-J_RESULT_2026-11-06.md](../review/U-J_RESULT_2026-11-06.md)；claims C-292..C-296；
预注册 U-J_PREREG（无修订）。零复位。

1. **C-293（T5 落地前提 3 清）**:stealth2 热 boot 复验 **0/52**（P=e^-52）；两 boot 合计
   0/120（P=e^-120）；printf 热路径性能代价 0.9996（passes 比）。方案 A 剩余前提：真守护
   部署 + 此消彼长第三窗。
2. **C-292（映射钉死）**:AP = MED − 0x22500000（三块逐值验证）；MED CR dump 标签=AP 视图。
3. **C-294（T1 AP 面关闭）**:FE→MED hnat_info 通道寄存器从 AP 总线不译码（8 别名全零/不符）
   ⇒ "AP 寄存器断供"分支关闭；剩余唯一带语义的钥匙=厂商 IPI（kmod 被头树缺失阻断 →
   下轮先重建头树）。
4. **C-295（链①质疑，本轮最大意外）**:hnat_info 环生产 ~0.55 rec/s 稳态，**洪水开/关不变**；
   λ 的流量三点单调仍成立 ⇒ "环记录=写者内容馈源"简单链不被观测支持；下轮判定实验=
   同一负载下"转发 vs 本地 INPUT"区分（C-258 链①修订入口）。
5. **C-296（仪器面）**:/proc/medhw/{cr_dump,dram} 入册；dpwr cacheable 读 DMA-DRAM 陈旧
   风险实锤（两遍逐字节相同）→ 环内容权威读需 O_SYNC /dev/mem 或 MED 侧路径。

对外口径:§0 基线+§15–§21。写者身份不变；T5=双 boot 隐身+零代价；T1=控制面地图完成
（AP 面闭、IPI 待 kmod、链①待判定实验）。

## §22 U-K 轮（2026-11-06 夜）：链①证伪 → **T1 关闭**；头树重建 + 供给杠杆落地

报告=[U-K_RESULT_2026-11-06.md](../review/U-K_RESULT_2026-11-06.md)；claims C-297..C-301；
预注册 U-K_PREREG（无修订）。零 Oops/WDT；一次计划内复位恢复 MED。

1. **C-300（2×2，终判）**：feed 开 空闲 2.58 / 本地洪水 17.72；feed 冻结 空闲 1.38 /
   本地洪水 **14.20**（RR 0.80）⇒ 断内容通道**不能**阻止流量 λ 激增；结合 U-J（环稳产而
   λ 6× 变）⇒ **C-258 链①证伪（非必要非充分）**；写者调度的是**活动模式**。
2. **C-297（流量类别）**：λ 本地 INPUT 17.7 ≫ 转发 4.6 ≈（1.8×）空闲 2.6；转发被 hnat
   硬件旁路 ⇒ λ 随"设备面向处理活动"排序。与 U-H/U-I 的 hot 档（全为本地 INPUT）自洽。
3. **C-299（首个供给杠杆）**：`dpmaif_stop_rx_sw()` 冻结 hnat_info 环 ≥8min；start 不逆转；
   复位恢复（0.68 rec/s）。**T1 作为根治路径关闭**——但该杠杆保留为"证伪工具"与 MED 面
   实验入口。
4. **C-298（基建）**：内核头树重建三级验证（编译/加载/功能）⇒ kmod 能力恢复（KASLR 关，
   静态地址直取），IPI/任意调用壳等后续工作解锁。
5. **程序路线落点**：本地阻断路径四条已关（引擎控制面 T1/T3 + 内容断供），**T5 隐身是唯一
   设备级验证通过的缓和**（双 boot 0/120、零代价）；程序重心正式转 **Scheme A 落地
   （真守护部署）+ T6 后果层修复（nerepair 重扫）**；T2/T4 仅存理论价值。

对外口径：§0 基线+§15–§22。写者身份不变；**"阻断写入"的本地科学空间在 U-K 收口**——
剩余可行面=进程级隐身（T5）+ 后果层（T6）+ 厂商/启动链（T2/T4，低值）。

## §23 U-L 轮（2026-11-06 夜）：写者"刻意"假设的判别——活流采样坐实；供给环假设否证

报告=[U-L_RESULT_2026-11-06.md](../review/U-L_RESULT_2026-11-06.md)；claims C-302..C-305。
零 Oops/WDT；一次计划内复位恢复 MED（"start 不恢复、复位才恢复"两轮复现）。

1. **C-302（记录内容）**：12 869 条注入记录携带**真实活流端点**——712 个真实 IP（设备 WAN、
   LAN 客户端、腾讯/阿里/微软 CDN 云），长度成类，**按流成串**（最长 49 连）⇒ 记录=活流采样，
   静态模板假设死；H-A（遥测采样引擎）获观测级强支持。
2. **C-303（落点几何）**：注入落点为**帧相对离散族**（top−0x5a0 主流，随我们的帧配置变化）
   ⇒ 地址锚定写入——目标由被触发帧构造，不是固定/随机地址。
3. **C-304（真环+stop 双验证）**：真环寄存器块 = **0x15b38000**（base/len/idx/thr/enable=
   0x101/chan）与 **0x15b28080**（2× 速率）；stop 在**真索引**上复测冻结（U-K 的 feed-OFF
   行成立——此前监控值确为副本）；start 不恢复、复位恢复；环率 0.34/s ≠ λ 0.99/s（无锁步）。
4. **C-305（用户供给假设→否证）**：环不缺失（已使能、在服务、内容为 TX 描述符）；冻结环不
   阻止栈上沉积；沉积地址由受害者帧构造 ⇒ **补/绑消费端与环不能改变异常写入**；唯一杠杆仍是
   改 store 形态（T5）。honeypot 槽不被吸引（槽选择由触发地址驱动，非内容驱动）。

对外口径：§0 基线+§15–§23。"刻意杀人"的解释收敛为：**它是活流采样器，把样本址锚沉积到
恰好长得像投递槽的 32B 邻域**；变参帧是用户态唯一长得像槽的东西——误报类，非意图类。

## §24 U-M 轮（2026-11-06 夜）：T5 落地——进程级隐身进入厂商面

报告=[U-M_RESULT_2026-11-06.md](../review/U-M_RESULT_2026-11-06.md)；claims C-306..C-309。
零 Oops/WDT；部署在线可回滚（umount 三行）。

1. **C-306（形态）**：设备 musl 的变参 prologue=8×`str q` 升序单发（24 组），非 zig 的
   stp-q 对；`%f` 正常。补丁目标由此精确化。
2. **C-307（落地）**：二进制补丁器打掉 prologue 的 FP 保存区写入——**libc（191 站点）+
   busybox（161）+ dnsmasq（16）**三件 bind-mount 部署；功能全绿；**全系统新进程**的
   libc 变参调用即时隐身，busybox 全家即时隐身；dnsmasq 下次 respawn 生效。
3. **C-308（事故与规则）**：gw 静态 busybox 的 shape-B 过匹配致段错误→备份恢复验证；
   shape-B 规则加严（精确 4 对 32B 布局）为后续静态二进制的准入条件。
4. **C-309（覆盖与边界）**：wpad 等其余守护仅 libc 面覆盖（自身件未补丁）；静态二进制
   未覆盖；击杀率下降**未证**（A/B 功效不足；两热窗 NE 零新增=弱阳性）。
   下轮：持久化（启动集成）+ wpad/其余补丁 + 整机 24h A/B 判收益。

对外口径：T5 已从"自研重编方案"落地为**在线、可回滚的系统级部署**；其力学（消灭 FP 保存
区突发）与 C-282/283/286 一致；收益评价待 24h 对照。

## §25 U-N 轮（2026-11-06 夜）：T5 持久化过 reboot 实测 + 24h 验收窗开启

报告=[U-N_RESULT_2026-11-06.md](../review/U-N_RESULT_2026-11-06.md)；claims C-310..C-313。

1. **C-310（持久化）**：rc19 v2.40 在 boot t=27.4s 自检并挂载隐身 libc（dmesg 可证）；
   reboot 后系统全绿（selftest 103/105 与基线同档）。回滚=单条 umount。
2. **C-311（方法）**：v4 严格补丁器（libc 140 站点）+ **三态对照电池**成为二进制补丁的
   准入门槛——U-M 单命令冒烟不足的教训正式成规。
3. **C-312（澄清）**：grep -r 在 stock libc 同样崩溃=设备既有缺陷，U-M 的"补丁嫌疑"平反；
   健康探针禁用 grep -r /etc。
4. **C-313（验收）**：T0=1793967674 起 24h 窗口；一键验收脚本就位；**覆盖=libc 面**
   （busybox/wpad 自指纹未覆盖，二进制补丁待 v5+沙箱）。24h 判据冻结于 RESULT §0。

对外口径：T5 的"持久化"里程碑完成；覆盖面诚实定位为 libc 面；下一步（v5+沙箱→应用二进制）
与验收结果挂钩。

## §26 U-O 轮（2026-11-06 夜）：T5 覆盖面拉满——四件套上线，24h 验收窗 T0=1793970002

报告=[U-O_RESULT_2026-11-06.md](../review/U-O_RESULT_2026-11-06.md)；claims C-314..C-317。

1. **C-314（部署）**：libc 140 / busybox 动态 106 / wpad 24 / ip-full 2 站点，四态电池与
   60×10 压测全等 → 四件 bind-mount；rc19 v2.41 自检后逐件挂载；**reboot 实测四挂载全在**
   （dmesg 26.4s）；新 hostapd 实例已运行补丁 wpad（inode 证据）。
2. **C-315（无需补丁的类）**：dnsmasq/logread/aee_aed 零站点 → printf 全走 libc → libc 面
   已覆盖。
3. **C-316（拒绝项）**：gw 静态 busybox 149 站点但 applet 分派坏 → 拒部署原文件保真；留 v6。
4. **C-317（方法）**：虚拟 digest 漂移平反 = 参照物过期；每轮必须重验 stock 对照。

对外口径：T5 从"libc 面"扩展到"libc+三大动态应用（busybox/wpad/ip）+ 类级覆盖
（dnsmasq/logread/aee 经 libc）"；24h 后一次性验收（acc_report v3）。

## §27 U-P 轮（2026-11-06 夜）：busybox 稳定性判决与 v5→v6 交集修复

报告=[U-P_RESULT_2026-11-06.md](../review/U-P_RESULT_2026-11-06.md)；claims C-318..C-324。
零 Oops/WDT；两次计划内重启（rc19 v2.42 挂载验证 + v2.43 持久 boot.log 验证）。

1. **C-318（判决）**：p5 补丁 busybox **不稳定且可确定复现**——`ls/cat/tar` 对缺失文件
   4/4 SIGSEGV（far=0x48，pc=libc+0x51ffc），同命令 stock 0/6 干净；NE 4 行 exe=P/busybox。
2. **C-319（根因）**：v5 shape-B 把错误函数的 3 条 `stp q0,q1` **va_list 拷贝**
   （0x408c68..70）当保存区 nop；vsnprintf 读到未初始化 va_list（`__stack=0x48`）。
   漏判原因：copy-pattern 只看紧邻 2 条（`ldp q0,q1,[x24]` 在 6 条前），且 shape-B 无
   vr_offs 签名要求。核心寄存器/帧链/反汇编三重一致。
3. **C-320（ip-full 同轮）**：v5 把 2 条 `stp q0,q0`（memset 类）误补（0x449e88/90）
   → **静态无效**；p5 期 `ip neigh` 反复 SIGSEGV（pc=far=0x1001200000028，NE 6+ 行）。
   该命令台账有 **40 条部署前（stock）历史**（最早 1793689702），回滚后 21:34 仍见
   stock 行（far=0x32e52）⇒ 崩溃是**既有 vendor 家族**，不单一归因 p5；拒绝 p5 的依据
   是两处确定性误补（v6 交集=0）。
4. **C-321（v6+交集）**：v6 严格校验（prologue 内 + vr_offs + 首 call 前 + 已加载 q 拷贝
   排除 + ≥4 q 升序）后取 **v5∩v6**：busybox **58**、libc **140**（与 p4 逐字节相同）、
   wpad **24**（与 p5 相同）、ip-full **0**（与 stock 相同）。**命中数不是覆盖指标。**
5. **C-322（p6s 验证/部署）**：13 组功能输出逐字节一致（含 `awk %.3f`=3.142、
   `printf %f`）；8 类错误路径 ×30 双栏 **0 信号**；重启后 ×20 复验 0；20 分钟生产
   soak 4 worker × ~1192 次，全部 `SOAK_END sig=0`；rc19 **v2.43** 三挂载
   （libc_p4/busybox_dyn_p6s/wpad_p5）+ 持久 boot 标记（t=25s
   `1793973483 25 libc=1 bb=1 wpad=1`）；ip-full 不再挂载；T0=1793973483。
6. **C-323（残余）**：开机 149s 一条 vendor 管道 `grep PSE_OQ_STA3` SIGSEGV
   （far=0x1520d，pc=libc+0x4680c）；同输入 200× + 30 随机 + 10 构造差分全 0 ⇒
   判为瞬时输入/写者事件，**不归因 p6s**，保留开放未知。gw 静态 busybox 仍未覆盖
   （21:30–31 awk/led_mgr NE 行即证）。
7. **C-324（既有 vendor 家族，验收口径）**：`ip neigh` 40 条部署前历史；`cat
   /proc/mtketh/phy_info` 3 条（2 条部署前，far=0x2b059/0x2e435/0x31f3）；gw 静态
   busybox 的 led_mgr/awk 持续被杀（far=0x130b7/0x4/0x1，pc 静态件）。均
   origin=vendor-tree/our-tree，与 T5 补丁无关；24h 验收按家族单列/剔除。

对外口径：busybox 面从"106 站点但确定性崩溃"修成"**58 站点验证子集且功能等价**"；
ip-full 回滚 stock（p5 的两条误补不可接受）；24h 验收改用 acc_report **v5**（3 挂载 +
boot.log），既有 vendor 家族单列。


## §28 U-Q（2026-11-06 深夜）：静态 busybox p8 上线；保存突发掩蔽封顶

**结论**：覆盖面补齐（libc/dyn busybox/wpad/static busybox 四件全部验证子集在役），
但**稳定性未达成**——p9（255 个 q0..q7 保存全去）对照仍在挂载后 276s 被同 pc 家族击杀，
证明该受害者类不由 FP 保存突发驱动。下一步必须动引擎侧（T1/T2/T3）或验证
"32B va_list 结构体直瞄"假设。

1. **C-325（U-O 拒绝再判）**：gw 静态 busybox 的"sh applet 无法分派"是**测试命名假象**：
   busybox 按 argv[0] 选 applet，二进制不叫 `busybox` 时 `./x sh -c` 必报 applet not
   found。改名 `busybox` 后，v5/v7/p8/p9 全量 **402 applet `--help` 输出+退出码逐字节
   一致**；34 项功能电池（含 8/9 个 FP 实参、`awk %.3f`）一致；设备原生 p8 的
   `printf %f`/`awk print` 逐位正确。
2. **C-326（v6 prologue 误拒 + v7 修正）**：静态 busybox v5 **149** = v6 **137** +
   v5 独有 **12**（`bb_error_msg` 0x408e3c..50、`msg_and_die_if_script` 0x4719bc..d0 的
   q2..q7 真保存块）。v6 `find_prologue` 在向后扫描时把函数**前驱**的尾调用 `bl` 当成
   "call-before-save" 而拒绝；v7 改为先找标记再拒绝标记与保存之间的 call。p8 = 149 +
   48 个 v6 独有 q2..q7（`bb_perror_msg`/`bb_error_msg_and_die`/`bb_perror_msg_and_die`/
   `bb_herror_msg_and_die`/`ioctl_or_perror`/`status_line_bold`/`message`/`log*`）= **197**。
3. **C-327（q0/q1 必须保留）**：v7 全集 255（含 q0/q1）使 `awk print 3.14159` →
   `3.47668e-310`、`awk %.3f`→`0.000`、`busybox printf '%f'`→`0.000000` ⇒ q0/q1 是前
   两个 FP 实参通道；p8 只补 q2..q7，浮点输出逐位正确。
4. **C-328（p8 部署）**：rc19 **v2.45** 第四挂载
   `/data/stealth/busybox_static_p8 → /data/gw/bin/busybox`；boot.log
   `1793977510 25 libc=1 bb=1 wpad=1 gw=1`、`1793978317 25 ... gw=1`；四件 md5
   `dc38797e/af5f1d75/ad381d37/36e3b4df`；gw 脚本 `sh` 经 `/data/gw/sbin/sh` 解析，
   重启后长驻脚本 inode=17387（p8 源）在役；**T0=1793978317**。
5. **C-329（阴性判决）**：p7 窗口 ~30 min 内 3 死（`svc_lib` t=107s pc=0x466eec；
   `wan_agg` t=1378s pc=0x4d5474；incident `awk` t=1752s pc=0x4b31cc）；p8 窗口 `sed`
   t=203s 死 pc=**0x4c8728 (vgetopt32)**；**p9 = 255 个 q0..q7 保存全 nop**，挂载后
   276s `cut` 仍死，pc=**0x4c8728**，far=0x1daf8——与台账 **29 条既有同 pc** 完全同族。
   ⇒ 对静态 busybox 家族，FP 保存突发掩蔽已到顶；候选解释：引擎直瞄 32B va_list
   结构体本身（musl va_list 恰 32B，与记录同宽）或按页属性写。
6. **C-330（p9/p10 拒用 + 终态）**：p9 破坏浮点；p10（32 个 `mov w?,#-0x80`→`#0`）
   在 qemu 上 `printf "%d %s"` 直接 SIGSEGV ⇒ 整数变参也依赖 vr_offs=-128。终态保留
   **p8**（最大验证覆盖 + 功能等价），rc19 v2.45 + 四挂载 + T0=1793978317；selftest
   **104/105**（唯一红 = wan_agg 不变量，源于 t=1378s shell 死亡，随后自愈）。

对外口径：**"全覆盖"= 四类观察受害者的验证子集全部在役**（libc 140 / dyn bb 58 /
wpad 24 / static bb 197）；**"稳定"未达成**——静态 busybox 既有 434 条崩溃家族
（pop_arg 61/hash_clear 58/get_meta 34/vgetopt32 29…）不因保存掩蔽改变；用户空间
缓解封顶，下一轮转引擎侧。

## §29 U-R（2026-11-07 凌晨）：p9 对照范围修正；p11 覆盖补全上线；T1/T3 残余路径复核

**触发**：U-Q 的 p9 阴性判决需要复核（用户问"隐身为何无法完全骗过写入者"）。

**新证据（离线 census）**：静态 busybox 有 399 条 q→[sp] 存储（390 `str q` + 9 `stp q`），
v7 只补 255；未补 144 中 **40 条组成五个完整 q0..q7 升序块**（ioctl_or_perror_and_die /
zbc_posix_error_fmt / fmtstr / out1fmt / ash_msg_and_raise_error）。漏因：pre-index 帧
（`stp xN,xM,[sp,#-imm]!` 无 `sub sp`）+ va_start 在保存块之后（`-0x80` 可晚于首个
`bl`）+ 跨函数 q 加载护栏。⇒ p9 **不是零签名对照**，"保存突发封顶"的强命题不成立。

1. **C-331（p9 范围）**：p9 = 255/399，未补 5 个完整块 ⇒ 强命题不成立；U-Q 的"封顶"
   应降级为"255 条匹配站点掩蔽不足"。
2. **C-332（p11 上线）**：p11 = p8 197 + 30（5 块 q2..q7）+ 1（ioctl 第二块 q7）=
   **228**；q0/q1 保留（浮点）；普查未补升序 q 块 = 0；qemu 402 help/34 电池/14 定向
   全等；设备 44 项仅 `df` 8KB、9×30 零信号；rc19 v2.46 上线，boot.log `1793980462 25
   libc=1 bb=1 wpad=1 gw=1`，md5 eedfbe41，T0=1793980462；首 NE=T0+322s vendor
   iptables（非 gw busybox）。
3. **C-333（T3 范围）**：C-280 只测 pfn_valid 子区窗 0x9c200000/2MB；**ISU 顶层保留窗
   0xbf000000/8MB 从未测**（/dev/mem pfn_valid=0 非缓存，未对齐 SIGBUS）；U-H 的
   `exilewin.c` 因 `pgprot_cached` 在 5.15 不存在**从未编译**；U-R 保留 VMA 默认
   PAGE_SHARED 后可构建（`exilewin.ko` 123800B, md5 c9c80e1c），`scanary_exile` 已支持
   `--win-dev /proc/exilewin` ⇒ ISU 分支是待测路径，不是负结果。
4. **C-334（T1 范围）**：C-300 关闭的是内容馈源；厂商 MED IPI 任务停止
   （`mtk_ipi_send` 0xffffffc0084b9ab8 / `med_stop_ack_ipi_handler` 0xffffffc0085a3c14 /
   0xa5a5a5a5 邮箱）在 C-298 头树重建后可构建，但从未上机；emiuctl 单参不够，需多参
   kmod + IPI 通道/消息 RE；预期值低，作为任务层收口。廉价未测项：4 CPU 亲和性、
   纯 CPU 负载、非缓存栈、栈偏移。

**对外口径**：p11 是"功能等价 + 覆盖补全"的可部署件（T0=1793980462，观察中）；
T3 的 ISU 窗与 T1 的 IPI 停止是两条尚未上机的可行路径；下一步优先 T3b（exilewin）。

## §30 U-S（2026-11-07 凌晨）：T3 ISU 顶层窗上机（阴性）；p11 覆盖补全仍死；写者相位门

1. **C-335（T3 关闭）**：ISU 顶层保留窗 0xbf000000/8MB 在缓存映射（pfn_valid=1、
   unaligned RW ok、1MiB store 419µs）下，587s 同进程双 victim：stackA **1147** /
   stackE **1075** 次 inj=0 外写，**RR=0.937**（预注册 [0.7,1.4]），冷窗/诱饵 0
   ⇒ 引擎照画 ISU 窗。C-280（pfn_valid 子区窗）+ 本轮（顶层窗）⇒ **T3 全面关闭**，
   放逐到 DRAM 保留窗不再有主张空间。
2. **C-336（p11 判决）**：p11 228 站点、未补升序 q 块=0，仍出现 gw 静态 busybox
   `awk` 击杀（1793983563，**pc=0x4b31cc hash_clear**，far=0x4，与 U-Q p7/台账 58 条
   同族）⇒ q2..q7 全覆盖不足；**FP 保存掩蔽不是该家族机制**。死亡在实验负载窗内，
   率不可当基线，但 PC/家族精确。
3. **C-337（仪器修正）**：U-H 的 exilewin 因 `pgprot_cached()` 在 5.15 不存在**从未
   编译**；保留 VMA 默认 PAGE_SHARED 后可构建（c9c80e1c）；`/proc/exilewin` 报
   **pfn_valid=1**（U-H 注释写 0 是错的；/dev/mem SIGBUS 是非缓存映射）；wmd5 增
   `snapvia`（RO mmap 被 EINVAL，RW 映射可用）。
4. **C-338（相位门）**：p11 boot 高 λ ~100/min（uptime 18–28min）；计划重启后低 λ
   **0–2/min**（port 9 与 U-H ug1 37777 合成洪水均拉不起来）；ISU 窗 primer 仅
   12–18/min；分进程 per-CPU arm 不继承注意力（CPU0 窗口 arm 2/1 per 60s）⇒
   per-CPU/纯 CPU 判别**欠功效**，需真实客户端高 λ 窗、同进程/同页设计。

**对外口径**：**T3 彻底关闭**（pfn_valid 子区窗 + ISU 顶层窗两种都测过）；**p11 覆盖
补全不解决静态 busybox 家族**（hash_clear 0x4b31cc 仍在）；写者受 boot/真实流量相位
门控。下一步：引擎侧 T1b（MED IPI 任务停止）/T2（SMC 全表）/T4（安全态），或 va_list
结构体直瞄/页层判别。

## §31 U-T（2026-11-07 夜）：洪水杠杆；p13 关闭；per-CPU 放大器；根修复收口

1. **C-339（洪水 λ 杠杆）**：无洪水基线 1.5–2.8/min；U-H 原版 ug1（PC→192.168.9.1:37777，
   3×800pps）把 λ 拉到 **7–68/min**（lam3 18/104s；unpinned 24+24/240s；ABAB unpinned
   26/68/35/40 events/60s），且每条记录载荷=洪水包 `{len 321/1601, ip 192.168.9.1}`。
   C-338 的"合成洪水无效"限定为该低相位 boot/条件；跨 boot 比较仍守 C-288。
2. **C-340（真实受害者记录闭环）**：gw 静态 busybox `grep` 在 1793985809 死亡
   （pc=0x4c8728 vgetopt32、far=0x263cd，与 U-Q p9 同 PC）；stack dump 0xf3c8 精确
   32B 记录 `{0x263cd,0,{0x141,192.168.9.1},0}`，0xf3e8 紧邻**完好 va_list**
   （stack=gr_top=0x7fc0b5d480、vr_top=0x7fc0b5d450、gr_offs=-0x28、vr_offs=-0x80）
   ⇒ 记录=洪水包、精确替换一条活 va_list、p11 挡不住、逐槽命中。
3. **C-341（p13 关闭）**：vr_top+16/vr_offs-16 重基语义正确（reb_test rc=6；busybox 37
   站点/scanary 4 站点功能全等），但真实编译器变参+重基 basereb **114 vs base 121
   events/300s（RR=0.94）**；合成长臂同向 ⇒ 写者活内容校验不依赖规范字面值。**p13 关闭**。
4. **C-342（per-CPU pin 是仪器放大器）**：scanary 洪水下 unpinned 26–68 events/60s vs
   pinned CPU0/1/2/3 全 **0**；可见性随 CPU 集大小单调（2-CPU=2、3-CPU=12、全 CPU=13–68）。
   但无扫描线程的被动单线程 mini/mini2（真实编译器变参，10ms sleep 稳定栈）pinned/
   unpinned 均 **~1 记录/60s**，迁移 60 次也不变 ⇒ scanary 的高 λ 被其**扫描线程跨 CPU
   读栈**放大，pin 抑制放大器而非真实攻击面。**pin 不得作为服务缓解宣传**。补充（C-346）：
   迭代数两端一致（itA/itE≈5908–5937、passes≈11719–11794）排除工作负载假象；wb=none 仍
   15–26 APPEAR/60s（哨兵写回只加 REWRITE）；独立进程 reader（/proc/pid/mem 每 5ms 读栈顶
   64KB，pin 到另一 CPU）不放大（1 vs 1）；**mini5 同进程跨 CPU reader 线程（300 个活且不
   覆写的 va_list 槽，60s）三臂均 0 记录** ⇒ "同 ASID 跨 CPU 栈访问"假说也否证，放大器机制
   未定（候选：printf 重负载 32B 密度/pthread 栈布局/5ms 密集扫描时序；C-347）。真实单线程
   速率不能用栈快照测（循环会覆写槽），需停顿采样。
5. **C-343（隐身天花板）**：bb_p11 残余 `str q→[sp]` 162、`stp q→[sp]` 9、`stp q→非 sp`
   **363**（va_list 拷贝）；U-H/U-I 证明 32B q 事务是写者指纹 ⇒ 真隐身须拆宽（1→2 指令
   扩展：trampoline 或编译器级改造），非本轮可交付。
6. **C-344/C-349（T1b）**：MED stop IPI 主路径 = 停 RX read-agent→必复位 MED
   （`RESET_TYPE_MD_EXCEP`，core0 halt ≤1s），0xa5a5a5a5 不存在于 medmcu_b.bin（CCCI tail
   pattern）。**force_stop 分支反而可达**：`needforcestop` @0xffffffc009221a18 的唯一置 1 写者
   `force_md_stop` 经 `dev_char_close`（open+close /dev/ccci_monitor）触发，或由 EL1 kmod 写 1
   并在同一回调内发 chan13；`RESET_TYPE_MD_FORCE_STOP` 只 notify、不置 scp_ready=0、不跑
   scp_reset_flow ⇒ **窗口 >1s 且可任意长**。但停 MED RX = 数据面停摆，λ 与流量耦合不可归因
   ⇒ 只能作任务级实验，不是干净根修复。
7. **C-345（T2 关闭）**：BL31 SIP 全表 **58/58 FID**；DRM/DFX 仅崩溃 dump 只读 + 早期启动
   魔术写（SMC 0x506 门控）；唯一引擎邻接服务 0x8200040E 只能改 DFD 崩溃链 SRAM 且受
   `[0x2c008]==1` 门控、与写者无关；三个 ATF mmap 窗口（0x264e0 表第 19-21 项）零代码引用。
   **无写者关断手柄**。
8. **C-348（T4）**：**SBC 实测为关**（2026-11-01 LK 日志 `SBC_EN = 0, SEC_LEVEL: 0`；自建签名
   镜像被接受 `boot_a cert chain vfy pass`）；现役 tee_b 内嵌 cert1 与 SDK 一致、ROOT/IMAGE
   私钥在手 ⇒ **BL31 重签技术可行**。但关引擎载荷未知：preloader DRM_DEBUG_CTL（VA 0x2055c0）
   是常驻前代码、BL31 无此码无 SMC；每次启动清 bits12-14 而运行时本就为 0（厂商关法=no-op）；
   唯一未清 bit15 只有置位路径、无清位代码；DDRPHY+0x1520 不可读；p24/p37 无回滚。**技术开放、
   载荷未知、不推荐上机**（盲写 bit15 有 DRAM 校准/变砖风险）。

**对外口径**：**本机无可用根修复手柄**——T1/T3 关闭；T1b 主路径关闭（force_stop 分支窗口
>1s 但停数据面、不可归因）；T2 全表关闭；T4 技术前提已具备（SBC 关、BL31 可重签）但**关引擎
载荷未知**，按目标判不推荐上机，只余 T7（厂商）。p13 关闭；p11 封顶于 363 条 32B va_list
拷贝；洪水是可靠 λ 放大器；scanary 的 per-CPU 隐身是仪器放大器效应（wb/跨进程 reader/同进程
跨 CPU reader 均不能复现），pin 不得作为服务缓解。下轮：放大器机制收口（停采样/被动连续检测器）、
32B 拆宽 trampoline 工程、T4 载荷位定义/DDRPHY 读法、T7 位定义。

## §32 U-V（2026-11-07 凌晨）：官方固件静态分析——零引擎邻域变更；PIT_NAT 第一候选消费者；官方无指纹规避

对象：RP0102（BUILDNUM 476，2025-12-25）与 RP0103（92249，2026-09-09）官方固件双备份
离线 diff + 记录消费者搜索 + 官方组件 32B 事务普查（全程未触碰设备）。

1. **C-350（内核 diff 零内存子系统变更）**：20.2MB Image 全 delta 仅 72B，分解为分段重链接
   位移（0/+576/+592/+56/−512/+72）；kallsyms names 流对齐 diff = **全内核仅 +2 符号**
   （`__refcount_sub_and_test.constprop.0`、`dev_put`，插入点 ccmi_open 前=CCCI/conninfro
   dev_put refcount 硬化），0 删除 0 改名；新字符串仅 `ccmni_start_xmit`/`port_mirror`；
   mm/EMI/MPU/DFX/mrdump 符号两版零变更。⇒ 厂商同产品线 8.5 个月未触碰写者邻域任何代码，
   **不存在"厂商已修复版本"可跟**（T7 仍是唯一外路）。
2. **C-351（B 家族记录第一候选合法消费者 = DPMAIF PIT/PIT_NAT）**：内核内建全套 PIT_NAT
   函数与 dump 串（`dpmaif_dump_partial_pit_nat`、`rel_rx_med_pit_entry`、
   `PitNat: phy/virt/size`、`pit_nat_idx` 等）；PIT_NAT 条目=modem 写/AP dpmaif 驱动读的
   包摘要描述符（bat/ptr+len+IPv4），与记录 `{A,0,{len,ip},0}` 同形（A=0x263cd 为 index 量级）。
   mrdump=后果层、emimpu=MPU 层，均不读该格式。⇒ **用户态不存在合法消费者**；写者产出
   PIT_NAT 形状的事务但投放到错地址。闭环需设备实测：dump PIT_NAT 环对照故障记录（下轮）。
3. **C-352（官方组件无 32B 指纹规避）**：exec 节 32B q 事务普查 libc 1872 / wpad 642 /
   busybox 290 / dropbear 122 / dnsmasq 75 / … / ccci_rpcd_com 0；RP102==RP103 逐项全等。
   官方核心组件事务密度远超 p11 残余（363+9）而历史受害者仍集中 busybox ⇒ 命中率随
   **活 va_list 使用面/进程形态**（K9）走，不随二进制指纹密度走；"官方原版即安全"被否；
   32B 拆宽（C-343）仍是唯一代码级隐身增强。

一句话：**官方在内存子系统上零动作（无可跟修复）；记录的"合法家"在 DPMAIF PIT_NAT 环
（待设备闭环）；官方组件与自改组件同带 32B 指纹——隐身只能靠改造自身代码（拆宽），不靠
"回到官方"。**

## §33 U-W（2026-11-07 午前）：PIT_NAT 否定；32B 拆宽工程交付但效果阴性

1. **C-353（PIT_NAT ≠ 家族 B 记录）**：环 live dump（kmod 直读驱动日志 VA，524/5450 非空）解码
   为 16B×2 `{hdr,len,bat_off,idx | bat_off2,DRAM_PA}`；len 连续 0x140..0x143 证实包长语义
   （321B 洪水包吻合），但**无 IPv4 字段**（全环 c0a809xx 0 命中）⇒ C-351 的"第一候选消费者"
   否定；B 家族消费者回到未知 flow/route-key 类。
2. **C-354（掩码修正，重要教训）**：STP 与 LDP 只差 bit22（0xAD0 vs 0xAD4），旧掩码 0xFF800000
   把 142 条 LDP 误当 STP ⇒ trampoline 把 va_list 加载改成垃圾覆盖，是本轮全部"机制崩溃"
   假象的根因。正确掩码 0xFFC00000；真值 372 stp q（sp 10 / 非 sp 362，与 U-T 363 吻合）。
3. **C-355（拆宽交付）**：362 站点 1:1 `b tramp`（12B：2×str q + 回跳；b 不触 x30/栈/flags），
   PT[0] 扩展 + 8KB tramp 块，md5 7f4f4ee9；qemu 10/10、真机 50 applet --help 逐字节、
   功能全等、3500 次调用零塌。
4. **C-356（效果阴性，隐身线封顶）**：v7 挂载+洪水窗内仍在**历史同族 PC** 崩溃
   （wan_agg 0x4d5474 = C-329 p8 台账；cfg_heal pop_arg far=0x1ddf6 ≈ p9 0x1daf8 类）；
   p11 对照 0/700 与 v7 二臂 0/1300 ⇒ 噪声内无差别，与 C-329（p9 全 q-save NOP 仍死）一致
   ⇒ **32B 事务宽度不是目标捕获键**。拆宽不能作为隐身增强；生产回滚 p11（eedfbe41）。

一句话：记录不是 PIT_NAT 条目；32B 拆宽工程做成了且功能等价，但**不改变命中**——隐身维度
至此封顶（p9/p11/p13/拆宽四连阴性），引擎侧（T7）与后果层是仅剩方向。

## §34 U-X（2026-11-07 午后）：根治可能性勘测——DRM 簇公开对码；相位门全量表；R 路径分级

> 只读 + 静态勘测轮（设备零写/零模块/零复位）。主交付 =
> [14_ROOT_CURE_SURVEY.md](14_ROOT_CURE_SURVEY.md)；轮次日志与相位门全量表 =
> [U-X_RESULT](../review/U-X_RESULT_2026-11-07.md)。

1. **C-357（DRM 簇 = MTK 标准 DDR Reserve Mode/DFD 锁存族）**：本机 preloader 的 0x10005030/34
   写原语（t4 §2 解码）与 MT7986/AX6000 公开启动日志的 `drm_update_reg` 序列**逐字段同形**
   （置 bit15 / 清 +0x34 的 bit8·9·21 / 清 bits12-14），日志给出全名 "DRM DDR reserve mode"；
   TF-A mt8188/8189/8195 DFD 驱动给出同偏移 LATCH_CTL（+0x40/44）寄存器图与同款每寄存器写
   key（0x95xx/0x66xx vs 本机 0x55/0x59）⇒ preloader DRM 编程是**跨 SoC 标准每次启动动作**，
   非本机异常武装；**T4 唯一候选「清 bit15」降级为大概率错靶**，T4 维持搁置；DDRPHY+0x1520
   位语义仍无公开源，T4 载荷缺口（条件 6）不变。
2. **C-358（相位门元事实）**：boot→λ 全量表（60+ 点，U-X_RESULT §2）——全部历史 boot 皆
   warm 复位、**断电冷启动数据为零**；同型计划重启产出过高/中/低三种相位；重启方式/uptime/
   ISU/feed/补丁版本全部排除。复位杀不掉引擎但改武装强度（C-288/C-338）；DDR reserve 机制
   （C-357）给 warm 态保留以具体载体 ⇒ **冷启动配对升格为相位门决定性实验**。
3. **C-359（自然 NE 每-boot 分布）**：干净 04:00 boot 1–6 NE/h；11-04 04:00 boot 156 NE/13.8h
   唯一长窗高发（与 U-A2 热流量窗同 boot）——自然口径尚不能分离相位与流量（无每 boot 流量台账）。
4. **负结果入档**：spmfw/mcupm/sspm 串扫零时钟门候选 ⇒ R0c（时钟/电源门控引擎）归档；
   WSL SDK 无 dramc/dfd 头；公开代码搜索 0x10005030/34 零命中（TF-A/coreboot DFD 是唯一
   公开语义源，已尽收）。

**R 路径分级（下一阶段入口，详见 14 §3/§4）**：R1 相位门工程化（冷启动配对 > 流量台账 >
高相位自动重启管理）**首选**；R4 后果层代码修复（nerepair 重扫/slotguard 自愈→布防复评）
**次选**；R0b T7 证据包 v2（附 DRM 对码，提问精准化）并行；R0a T4 静态补完（zig objdump
复核 bit17/19 + 完整簇对码）纯离线保留；R0c 归档；R2/R3 关闭维持。

## §35 U-Y（2026-11-07 傍晚）：受控 λ(t) 首曲线——无快衰减/洪水放大稳定/零流量基线；emiisu 收口

> 低风险上机轮（零复位/零 kmod/零服务变更/零 /data 业务写）。预注册 7 臂 ABAB，
> 同 boot 1794020769，2.2h。[U-Y_RESULT](../review/U-Y_RESULT_2026-11-07.md)；claims C-360/C-361。

1. **C-360（λ(t) 首曲线）**：基线 12.31→12.71→9.86→6.33/min（**慢漂降 ≈2×/2.2h**，
   RR A2/A1=0.51）；洪水放大 **×2.45/×2.73/×2.40 三臂稳定**；epoch 节拍全程 60.00s
   （零扫描饥饿伪影）；**真实 WAN ≈23 B/s 全程** ⇒ 基线 12+/min 是**流量无关的相位
   分量**——λ = 相位(boot 级) × 活动(负载) 因子模型首个受控支撑。U-A2 快衰减
   （5.6×/35min）受控不复现（慢 6 倍），其流量混杂解释被加强。自然 NE 与仪器 λ
   解耦（2.2h 仅 +1 busybox NE vs 1979 仪器命中）。
2. **C-361（emiisu 收口）**：`mtk_emiisu_control` = on≠0 写 **0xdecddecd** / on==0 写
   0xdec0dec0（直写寄存器）；现读数 ⇒ **ISU ON**——U-X 快照 [B4] 矛盾解除；
   emiisu_ctrl_store 为裸 u32 直写通道。
3. **bit19 定案**（C-357 注记更新）：preloader init 0x205704 逐指令 = SET bit15 /
   CLEAR **bit19** / CTL2 三清——t4 解码确认；AX6000 bit17 为真实 SoC 代差。
4. **仪器教训**（入 LESSONS）：设备侧长循环 shell 采样禁掺 netfilter/sysctl/磁盘读
   （v1 do_wait 挂起实证）；scanary 日志块缓冲——跨臂统计须全量拉取按 EV 重算。
5. **R1 输入**：相位 boot 级稳定（2.2h 连续）⇒ R1b 检测窗可小时计；新观察「慢漂降」
   若复现，高相位或有小时级自愈——R1b 可加免重启"等待降档"备选臂。
