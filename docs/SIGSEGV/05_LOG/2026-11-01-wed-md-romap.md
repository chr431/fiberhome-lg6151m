# 05_LOG · 2026-11-01 · WED 描述符族（mt7992_dbg）+ MD 共享区 VA 搜索 + romap 判据 + 「入向」降级

> 承接 [2026-11-01-ko-md-premises.md](2026-11-01-ko-md-premises.md)。本文对应 Lead 本轮 4 项。

---

## 1. `mt7992`/`mt7992_dbg` 的 `rxq_wed_layout`/`txq_wed_layout` —— **它们是"打印函数"，不是布局表**

**结论（E3，已核字节）**：`txq_wed_layout`(280B)、`rxq_wed_layout`(576B)、`wed_hif_txd_info_list`(64B)、
`txq_wa_layout`/`rxq_wa_layout`/`*_pcie1` 全部是 **AArch64 代码**（首字节 `aa1303e0`=`mov x0,x19`、`94000000`=`bl`），
不是数据表；之前的"自带布局说明"判断**要更正**：它们是 **debug dump 函数**，布局信息在它们引用的**格式字符串**里。

### 1.1 从格式字符串提取到的 WED/WiFi 描述符族词汇（E2，字符串级）
| 字符串 | 含义 | 对本调查的意义 |
|---|---|---|
| `TMAC_TXD_0` … `TMAC_TXD_7` | **TMAC 发送描述符 = 8 个字（32B）** | 与"32B 描述符"同尺寸，但**字段里没有 IP**（见下） |
| `TxDFormatType = %d` | TXD 有多种格式（v0/v1/v2/v3） | 说明 32B 内有格式相关位域 |
| `txd len= %d` / `HW AMSDU Len` / `Header Len = %d(WORD)` | TXD 里有长度（局部位域） | 与记录里的 `u32 len` **不是同一处**（记录是 host-order u32，且带 IP） |
| **`NO_INFO_WB = %d,`** | **WED "info 写回"开关** | **重要**：WED 确实有"写回 info"的概念；若 info 含 L3/L4 需进一步核 |
| `RRO RXDMAD_C` / `RxLenMismatch=0x%x` / `ExceedMax Rx Length(EL)` | **WiFi RRO 的 RX 描述符（RXDMAD）**与长度不一致检查 | RRO 是"重排序 + L3/L4 解析"引擎 ⇒ **它是最有可能产生"带 IP 的 per-packet info"的硬件单元** |
| `HIF Q0..Q5` / `MSDU Page Ring (band 0/1)` / `band0/1 TXD` | HIF 队列与 MSDU 页环 | 环/页结构（非 32B 记录） |
| `HIF group page status(0x820c0114)`、`HIF0 group page status(0x82068114)`、`HIF_TXCMD group page status(0x820c011c)` | **WiFi HIF 寄存器地址**（实测字符串里带绝对地址） | 可直接给 kdev 当"读环/读页状态"的锚点 |

### 1.2 对"记录 = WED 描述符族"的判定
* 32B 尺寸吻合（TMAC_TXD 8 字），但**WED TXD 字段表里没有任何 L3/L4 地址**（字段是长度/格式/页/队列/带宽类）；
* 之前的实测也否证：WPDMA TX 环 16B 条目 = `{PA_lo,ctrl,PA_hi,0}`，无 len/src_ip（00_STATE §10）。
⇒ **WED TXD 族排除**（E2，与 static-identity §2 一致）。
* **唯一残留下口**：**RRO 的 "info 写回"**（`NO_INFO_WB` 的存在说明该机制真实存在）。
  判据（零成本）：若有 RRO info 写回，则应能在 **RRO 的 RXDMAD 环**里看到同形 {len, addr}；
  但 RRO 是 **WiFi RX** 专用，而命中在"有线端口 ×71"的臂里仍发生 ⇒ **若记录来自 RRO，WiFi RX 必须与命中相关**。
  这正是 Lead 已让 lab 顺手采的 K1 判据（`rai0 RX / WED RX` 与命中的相关性）——**同一条判据同时判 K1 与 RRO 口子**。

---

## 2. MD 共享区 VA 搜索脚本与判读口径（给 lab）

脚本：`_local/work/crash-root/static/md_va_scan.sh`（设备侧，逐区生成 `pascan` 调用）
判读：`_local/work/crash-root/static/md_va_scan.py`（主机侧，把结果整理成"命中/噪声底/正对照"表）

### 2.1 **必须遵守的两条历史教训**
1. **/dev/mem 的 mode 语义（§17.3）**：**RAM 区**（`0x40000000-0xefffffff` 之类）用 `mode=0`（普通读）可行；
   **SRAM / MMIO 区**（如 `0x00100000` 段、`0x10000000` 外设、`0x18000000` 等）**必须 `mode=1`（ioremap）**，
   用 mode=0 会触发 **SEA（同步外部中止）→ 设备重启**。⇒ 扫描器**必须按区选 mode**，且未知区一律先 mode=1 试 1 页。
2. **噪声底**：历史实测同一 8B 值的随机命中：`0x1122334455667788` → **6 处**，`0xdeadbeef...` → **32 处（上限）**
   ⇒ **必须报"命中数 vs 噪声底"**，命中 1–2 处**不构成证据**（C-160 的自我否定正是这个坑）。

### 2.2 扫描目标（按优先级）
| # | 目标值 | 说明 |
|---|---|---|
| T1 | 受害者栈 VA：`startstack-0x390`、`startstack-0x3a0`、以及页基址 `startstack & ~0xfff` | **主假设 B 的前提**：某个结构里存了用户栈 VA |
| T2 | 同一 victim 的 `sp`（fault-time）与其页基址 | 覆盖"存 sp 而非 va_list"的变体 |
| T3 | （正对照）**bat_va** | 历史 §16.1 已证 BAT 环里存着 AP 的 kernel VA ⇒ **必须命中**，否则扫描器/区域选错，本轮判无效 |
| T4 | （噪声底）`0x1122334455667788` 与 `0xdeadbeefcafebabe` | 决定"多少命中才算显著" |

### 2.3 扫描区域（设备上按 `/proc/iomem` 实测再填；下表是历史锚点）
| 区 | 范围（历史值，需实测确认） | mode | 用途 |
|---|---|---|---|
| MD 共享 RAM（dpmaif BAT/PIT/1 MB 生产环） | `0x90480000+`、`0x904a0000`（1 MB 环）、`0x906e0000`（BAT） | **0** | T1/T2/T3 主战场 |
| `lk_medmcu_reserved` | `0xaff00000 + 0x40000` | **0** | MD 预留区 |
| `lk_medmcu_reserved_desc` | `0x9fcb0000 + 0x340000` | **0** | 描述符区 |
| MD SRAM / 外设窗口 | `0x00100000` 段、`0x0d000000` 段等（按 iomem） | **1（ioremap）** | 只在 RAM 区全阴性后做，且每区先探 1 页 |

### 2.4 判读口径（三档，必须带检出下限）
| 结果 | 判定 | 写法 |
|---|---|---|
| T3（bat_va）**0 命中** | **本轮无效**（扫描器/区域/mode 错） | "无效：正对照 0/N，先修扫描器" |
| T3 命中 且 **T1/T2 命中数 ≤ T4 噪声底** | **B 的前提①不成立** | "`T1 命中 m / 噪声底 n（m ≤ n，n=…）` ⇒ 无证据表明 MD 侧持有用户栈 VA" |
| T3 命中 且 **T1 命中数 > 2×噪声底 且命中地址落在 MD 已知结构内** | **B 的前提①成立（E2→E3）** | 直接点名：`VA 出现在 <区>+<偏移>` ⇒ 该结构就是"用户 VA 导出通道" |

### 2.5 一次扫描的预算
历史 `pascan` 扫全 RAM（523,008 页）能跑完；本表各区合计 ≈ 1.4 GB ≈ 35 万页 ⇒ **单区 ≥2 min，全表 ~15 min**，
必须后台化 + 轮询（设备侧纪律）。**每区单独输出**，任何 SEA/超时立即跳下一区并记录。

---

## 3. romap / pte_redirect 可执行判据清单（给 kdev）

前置：受害者 canary 保持运行；记录其 `startstack`、当前 `x2`；**先取一次基线**（页内无记录）。

| 步 | 操作 | 期望观测 | 判定 |
|---|---|---|---|
| S0 | 基线：读受害者页（PA=P）与页内容 | 无记录 | 装置有效 |
| S1 | **romap**：保持 V 不变，把 V 重新映射到新物理页 P′（`mremap`/自建 PTE 重定向） | — | — |
| S2 | 观察 T（≥10 min，A 臂（未改动的 canary）作存活对照） | ①A 有命中（活性）②看 V 是否还崩 ③读 **P（旧页，现已不属于受害者）** 与 **P′** | **P′ 上出现记录** ⇒ **A1/A2（VA 解析）**；**P 上出现记录而 P′ 干净** ⇒ **A3/B（PA 写）** |
| S3 | 若 S2 判 A3/B：对同一页做 **pageflags**（`_refcount-_mapcount-1`） | `extra>0` ⇒ **A3（pin）**；`extra=0` ⇒ **B（PA + VA 派生偏移，必须有 VA 导出通道）** | 见 §2 的 T1/T2 搜索 |
| S4 | **pte_redirect**：保持页表项存在但指向**诱饵物理页 P″**（`0xdead` 填满、我们独占） | 诱饵 P″ 出现 32B 记录 ⇒ **确证 VA 解析（E3）**；诱饵始终干净 ⇒ 排除 VA 解析 | 这是最硬的一步 |

**正/负对照（缺一即无效）**
* 正对照 1：`rectest` 自注入（往 va_list 写记录）必须被检出 ⇒ 判据本身有效；
* 正对照 2：A 臂在同一窗口必须有 ≥3 次命中 ⇒ 写入者活着；
* 负对照：**未改动的 B2 canary**（同进程、同页不变）应与 A 同样有命中；若 B2 也为 0 ⇒ 全局无活性 ⇒ 无效。

**无效条件**：A 臂 0 命中；诱饵页被内核分配走（`PageBuddy=0` 且非我们持有）；remap 后受害者栈不可写（进程立刻死且非记录家族）；
观测者（nerepair/patrace）在窗口内运行。

**期望的"一锤定音"组合**：`S4 诱饵出现记录` + `S3 extra=0` ⇒ **VA 解析（AP 侧 uaccess 或 MD 走页表）**；
若同时 §2 的 T1 命中 MD 区 ⇒ 那就是**MD 走 AP 页表/或 AP 导出 VA** 的完整证据链（E3）。

---

## 4. 「入向」结论的降级（Lead 要求写清）

上一轮我用"**GRO 只在接收方向**"推出"82% 的记录对应入向报文 ⇒ 122.227.201.3 是源"。
**该推理依赖"聚合发生在 AP 的 GRO"**。若聚合实际发生在 **MD/硬件侧（RRO / hw_lro / LRO）**，则：
* 长度仍可能是"聚合后的量"（E2 保留），但**方向推断不再成立**（RRO 是 WiFi **RX** 引擎，hw_lro 也是 RX；不过 MD 侧若有独立的聚合路径，方向就无从判定）；
* ⇒ **"入向"降为 E1**，`addr` 的语义（"对端地址" vs "目的地址"）**同时降为 E1**。
**能把它救回来的最小证据**（任一条即可）：①抓到 `122.227.201.3` 的连接方向（`/proc/net/tcp` 的 local/remote 对，或 conntrack 的 `src/dst`）；
②一次**单方向**投递实验（只从 alias 侧发 / 只向 alias 侧发，看记录里的 addr 是哪一个）——这条 lab 已经在做，结论以它为准。
