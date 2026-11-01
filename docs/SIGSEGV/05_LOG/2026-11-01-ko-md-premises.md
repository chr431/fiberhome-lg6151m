# 05_LOG · 2026-11-01 · ko 扫描候选表 + MD/VA 前提表 + 「+64」更正

> 承接 [2026-11-01-flow-122.md](2026-11-01-flow-122.md)。本文回答 Lead 三条议程：①169 个厂商 ko 扫描；
> ②MD/SCP 侧"能按 VA 写"与"只能按 PA 写"的**前提清单**（供 romap/pte_redirect 证伪）；③对"+64 = EDMA 缓冲头"的**自我更正**。

---

## 1. 169 个厂商 .ko 扫描（只读主机文件）

### 1.1 硬限制（先说，避免过度解读）
* **169 个 ko 全部无 `.BTF`**；只有 **11 个**（全是 netfilter 家族：ip6t_NPT / ip6table_nat / nf_conntrack_ftp,pptp,sip / nf_nat_ftp,sip …）
  有 `.debug_info`，而且里面 `struct nf_conn` 等**只有声明没有成员定义**（定义在 vmlinux，而 vmlinux 无 DWARF）。
  ⇒ **无法从二进制直接取结构布局**（已试 `static/dwarfdump.py` + `ko_dwarf.py`，结论是此路不通，如实记录）。
* 因此下面的候选是**函数级/词汇级短名单**，不是结构级点名。

### 1.2 相关性排序（正向关键词命中：符号名 + .rodata 字符串）

| 模块 | 大小 | 符号数 | 关键词符号 | 说明 |
|---|---|---|---|---|
| **mtk_warp.ko** | 738 KB | 509 | **268** | WED/warp 全链路；符号含 `warp_procinfo_dump_rxinfo_`、`warp_wdma_ring_init_hw`、`wed_init`、`warp_msg_send_cmd`；字符串含 **pkt_info / tuple** |
| **mt_wifi.ko** | 13.5 MB | 10073 | **265** | 字符串含 **pkt_info / tx_info / flow_info / tuple / offload**（唯一全中的模块） |
| **hw_nat.ko** | 404 KB | 770 | **164** | `dma_read`、`mib_read`、`foe_dump_cache_entry`、`decide_qid`、`ppe_usb_rx_send`、`eth_auto_qos_worker` |
| gps_drv.ko | 373 KB | 667 | 71 | `gps_dl_hal_d2a_rx_dma_get_rx_len`（有"rx_len"取数器，GNSS 侧，与网络无关） |
| conninfra.ko | 462 KB | 1073 | 26 | `ring_emi_write_prepare`、`_ring_read_commit`（AP↔connsys ring） |
| mapfilter.ko | 86 KB | 249 | 23 | `get_tuple_from_skb`、`sp_add_rule`、`update_client_db`、`map_pkt_q_config`（WiFi↔LAN 映射/客户端库） |
| mtk_wed.ko | 17 KB | 49 | 23 | 薄壳：`wed_hif_txd_info_list`、`warp_proxy_write` |
| mtk_pci.ko | 43 KB | 118 | 21 | `pci_dma_init_rx_data_queue`、`rro_msdu_page_hash_init`（WiFi RRO 页哈希） |
| mtk_hwifi.ko | 148 KB | 387 | 18 | `bmac_write_mac_txd`、`mtk_bus_set_pao_sta_info` |
| mt7992.ko / mt7992_dbg.ko | 32/95 KB | 49 | 4/4 | `txq_wed_layout`、`rxq_wed_layout`、`wed_hif_txd_info_list`（**WED 描述符布局的"自带说明"模块**） |

### 1.3 "32B 块写"扫描（谁在代码里写 32 字节）
判据：`stp xA,xB,[xN,#off]` + `stp xC,xD,[xN,#off+16]` 紧邻（32B），或 `stp qA,qB`（32B SIMD，**全库 0 处**）。
`mt_wifi` 16792 / `gps_drv` 452 / `conninfra` 393 / `hw_nat` 355 / `mtk_warp` 344 / `mapfilter` 184（噪声大，仅用于定位）。

**按"函数名有意义"筛出的候选表**：

| # | 候选 | 证据 | 若成立的可证伪预测（反证条件） |
|---|---|---|---|
| **K1** | `mt_wifi` 的 **flow_info / pkt_info / tx_info** 一族的 per-packet 结构 | 唯一同时含 5 个关键词的模块 | **已被部分否证**：WiFi TX 路径在命中时 `rai0_tx = 0`（08_CORRELATION 臂2）、HW_TX_EN 门控 A/B 无响应（C-154，但因门控惰性不算证伪）。⇒ 若要复活，必须是 **RX** 侧 flow_info；判据：命中时 `rai0_rx`/WED RX 计数应相关（可零成本测） |
| **K2** | `mtk_warp` 的 **`warp_procinfo_dump_rxinfo_`** 对应的 "RX info" 结构 | 函数名直指"dump RX info" ⇒ 存在每 RX 描述符的 32B/16B info | 若记录来自它，则 `/proc/warp_ctrl/*/procinfo` 应能看到同形字段；判据：**读该 proc 节点比对 {len, addr}**（零成本） |
| **K3** | `hw_nat` 的 `foe_dump_cache_entry` / `dma_read` | hw_nat 自己经 DMA 窗口读 PPE 表；dump 数据结构 32B 级 | 若记录是 FOE cache 的 dump 结构，则 `/proc/hnat/*` 应暴露同样字段（**当前全空 ⇒ 无法证实**，见 08_CORRELATION 方法论笔记 B） |
| **K4** | `mapfilter` 的 `update_client_db` / `sp_add_rule` | 客户端库/规则 32B 条目；含 `get_tuple_from_skb` | 若成立 ⇒ 记录应绑定 **LAN 客户端 IP**；实测 82% 是**公网对端** ⇒ **弱否证**（除非客户端库也存对端） |
| **K5** | `mtk_pci` 的 `rro_msdu_page_hash_init`（WiFi RRO 页哈希） | RX 聚合页哈希表，条目 16B 级 | WiFi 专用 ⇒ 与"有线端口 ×71"矛盾 ⇒ **否证**（08_CORRELATION 臂2） |
| **K6** | `mtk_wed` 的 `wed_hif_txd_info_list` | TXD info 列表（16B 条目，与历史"16B 槽"同形） | 已在 C-154/§10 实测：**WPDMA TX 环条目 16B = {PA_lo, ctrl, PA_hi, 0}，不含 len/src_ip** ⇒ **否证** |

**⇒ ko 扫描的净结论**：厂商模块里**没有任何可以直接点名的结构**（无 DWARF/BTF）；
短名单收敛到 **K1（mt_wifi RX flow_info）/ K2（warp rxinfo）** 两个可再用零成本手段验证的候选，
其余 4 个已有否证或无法证实。**这不支持"AP 侧某个厂商模块写 32B"的强主张。**

---

## 2. MD/SCP 侧"能按 VA 写" vs "只能按 PA 写"：前提清单（供 romap/pte_redirect 证伪）

设受害者页 V→P。实验：**romap**（保持 V 不变，把 V 映射到新的 P′）。

| 模型 | 必须成立的前提（全部） | romap 后的预测 | pte_redirect（V→诱饵 P″）后的预测 | pageflags |
|---|---|---|---|---|
| **A1：MD 自己走 AP 页表（VA→PA 翻译）** | ①MD 能读 AP DRAM（成立）②**MD 拿到目标 mm 的 TTBR0/ASID**（AP 侧必须导出；**目前无任何已知导出通道**）③MD 固件实现 4 级页表 walker ④处理 TLB/硬件更新 | **写入跟随 V → P′**（受害者继续崩；P′ 上出现记录） | 写入落 **诱饵 P″** ⇒ **我们在诱饵区抓到记录** | extra = 0 |
| **A2：AP 代理（MD 给 VA，AP 代码 uaccess/GUP 写）** | ①AP 驱动持有该用户 VA（缓存/泄漏）②MD 触发该驱动 | 跟随 V | 落诱饵 P″ | extra = 0 |
| **A3：GUP/IOMMU pin（IOVA→P 的映射已建立）** | ①某时刻对 V 做过 pin（FOLL_WRITE）②设备经 IOVA 写 | **仍写 P**（旧 PA）；受害者**不再崩**，P 上出现记录 | **仍写 P**，诱饵**干净** | **extra > 0**（pin 位） |
| **B：MD 按 PA 打 + 偏移来自 VA 派生量** | ①某结构里存了**用户栈 VA**（或 sp/startstack）②MD 读该结构并按 PA 写 | 仍写 P（旧 PA） | 仍写 P，诱饵干净 | extra = 0 |

**⇒ 判决矩阵（kdev 只需三次观测）**
1. romap 后**跟随 V** ⇒ A1/A2（VA 解析）成立；**留在 P** ⇒ A3/B 成立。
2. 若"留在 P"：再看 **pageflags extra** —— `>0` ⇒ A3（GUP pin，**无需任何 VA 来源**，与 scanary 的"随 D 移动"矛盾，见下）；`=0` ⇒ B（必须存在 VA 导出通道）。
3. 若"跟随 V"：看 **pte_redirect 诱饵区**是否出现记录 ⇒ 出现 = 确认 VA 解析（这是最硬的 E3）。

**⚠️ 关键逻辑约束（务必写进 kdev 的判据）**
* scanary 已证"命中点随 D 移动（16B 粒度）" ⇒ **A3（纯 PA + 固定偏移）不可能**，因为它对 D 无感；
  ⇒ 若 romap 显示"留在 P"，剩下的只能是 **B（PA + VA 派生偏移）**，而 **B 的前提①"某结构里存了用户栈 VA"是必须点名的对象**。
* **B 的前提①可以用现有工具直接搜**（零新仪器）：历史 §16.1 已证 **dpmaif BAT/PIT 环里存着 AP 的 kernel VA（bat_va）**
  ⇒ 那条共享通道**确实在传 VA**。**⇒ 用 `pascan`/`dreg` 在 MD 共享区（PIT 4KB×N、BAT、1 MB 生产环、`lk_medmcu_reserved`）
  里搜"受害者栈 VA"（`startstack-0x390/-0x3a0` 或其页基址）**：
  找到 ⇒ **VA 导出通道当场点名（E3）**；搜不到（带正对照：先搜 bat_va 必须命中）⇒ B 的前提①不成立 ⇒ 只剩 A1/A2。

---

## 3. 更正：「+64 = EDMA 0x40 缓冲头」不成立；「记录在 L3 之后」要降级

我上一轮把 `4480 = 3×1472 + 64` 里的 64 说成"厂商 EDMA 的 0x40 缓冲头"。**这条我撤回**，理由是结构性的：
厂商驱动做的是 `dma_map_single(buf+0x40, 1536)` 且 `skb->data += 0x40`（见 static-identity §2.1），
**64B 头room 不在 `skb->len` 里**，因此任何"L3 之后长度"都不可能含这 64B。
**更稳的读法**：`4416 = 64×69`、`4480 = 64×70` —— 它们是**相邻的两个 64 的整数倍**（`1600=64×25`、`1664=64×26` 同理），
所以"64"更像**长度本身的 64B 粒度**，而不是某个头部的固定加数。

**对推论的影响（承认降级）**：
* 原先"记录携带 L3/L4 量 ⇒ 结构在 L3 之后"（E2）**降为 E1**。理由有两条，任一条都足够：
  ① lab 的受控流（LAN UDP 6 万包 / 独特帧长 777、1234）**零响应** ⇒ "len = 同一条流的 L3 长度"**从未被直接验证**；
  ② 我的 +64 解释被否 ⇒ 连"长度是后聚合 skb 长度"也失去一个旁证。
* 保留的弱证据：长度谱 {321, 1600/1601, 4416/4480} 与"bulk TCP/UDP 流的段/聚合长度"**自洽**，且 4416/4480 > MTU 只能由 GRO/RRO 产生
  ⇒ **"长度是某个聚合后的量"仍然成立（E2）**，但"聚合发生在 AP 的 L3 之后"降为 **E1**（也可能发生在 MD/硬件侧，如 RRO/LRO）。

---

## 4. 一页备忘

* 本文所有 ko 结论都是"**函数级短名单**"，**不是结构级点名**（无 BTF/DWARF，已用 `dwarfdump.py` 证伪该路径）。
* 两个"可零成本验证"的候选：**K2 `/proc/warp_ctrl/*/procinfo` 里找 {len, addr}**、**K1 看 rai0 RX 是否随命中相关**。
* 一条"零新仪器、可能当场点名"的实验：**在 MD 共享区搜受害者栈 VA**（带 bat_va 正对照）。
