# 07 · 可部署杠杆：WED 硬件 TX 门（HW_TX_EN）与运行时消元实验

> 状态：**静态确证完成，A/B 实验待跑**（2026-11-01 00:10）。本文是 [FIX.md](FIX.md) 的 R3「关 WED offload」
> 的**实证化**：从"需要厂商"变成"一条 proc 写入 + 秒级回滚"。
> 遵守 00_STATE.md §6：canary 率只作**机制探测器**，不得当自然 NE 率。

## 1. 一句话

mtk_warp 暴露了一个**纯软件**的运行时开关 `/proc/warp_ctrl/warp1/ctrl`（HW_TX_EN）。
置 FALSE 后 `warp_wlan_tx()` 在 `wifi_tx_tuple_add()` **之前**返回 0，mtk_wed 走软件 TX 回退；
不卸模块、不重启、可秒级回滚。这就是"停掉 WED TX 元组编程"的最小杠杆。

## 2. 静态证据（可复核）

目标：`analysis/vendor/mtk_warp.ko`（sha256 `246dce7929ef15e33c21caed3d4fe43d695dfb574c0d4bd2e2363017b6ef8c37`）
反汇编语料：`prv-lg6151m/analysis/ko_corpus/mtk_warp/mtk_warp.asm`（relocation-aware）

| 位置 | 事实 |
|---|---|
| `.text+0x4548`（ctrl show） | `ldrb w1,[x22,#0xd31]` → 打印 `HW_TX_EN : TRUE/FALSE`；`ldrb w0,[x22,#0xd30]` → `ATC_EN` |
| `.text+0x5d6c..0x5da0`（ctrl write） | 解析 `"<idx> <val>"`（分隔符=空格）；idx==0 时**只** `strb w20,[x22,#0xd31]`；**无任何 MMIO 写** |
| `.text+0x5dc4`（idx==1） | ATC_EN：额外调 `wifi_chip_atc_set`，再 `strb [x22,#0xd30]` |
| `.text+0x970`（`warp_wlan_tx`） | ① `wifi_hw_tx_allow()` 为 0 → return 0；② `ldrb w0,[x19,#0xd31]`；`cbz w0,#0x990` → **return 0**；③ 否则 `wifi_tx_tuple_add()` |
| `0xd31` 全局读点 | **仅 1 处**（0x009c4，即 warp_wlan_tx 内）；另 1 处 show + 1 处 write |

调用链（跨模块）：
`mtk_wed.ko 0x8b8: bl warp_wlan_tx` → `0x8bc: cbz w0, 0x884` → `0x884: ldr x0,[x20,#0x10b8]; ldr x2,[x0,#0x40]; blr x2`
即 **返回值 0 = 走 `ops->tx`（原始软件 TX）**。mtk_wed.ko 是唯一导入 `warp_wlan_tx` 的模块（全 169 个 .ko 扫描）。

**推论（可证伪）**：HW_TX_EN=FALSE ⇒ 该 WiFi 口的 TX 不再经过 `wifi_tx_tuple_add`（WED/WDMA 元组编程）。
若 32B 记录确实由该路径写出，则记录写入率 → 0。

## 3. 杠杆操作（三条命令）

```sh
# 关（应用杠杆）
echo 0 0 > /proc/warp_ctrl/warp1/ctrl     # HW_TX_EN := FALSE
# 开（回滚）
echo 0 1 > /proc/warp_ctrl/warp1/ctrl     # HW_TX_EN := TRUE
# 看
head -2 /proc/warp_ctrl/warp1/ctrl
```

设备侧封装：`tools/oneoff/sigsegv/hwtx_gate.sh {status|off|on|verify on|off}`。
**开关不持久**：重启即回默认 TRUE（结构体字段），04:00 定时重启天然兜底。

## 4. 附带发现的运行时观测面（只读，可用于后续判决）

`/proc/warp_ctrl/warp1/` 下有 `cfg/cr/ctrl/rx/rxbm/stat/tx/wdma/wed/wo/wo_aee`：

| 文件 | 用途 |
|---|---|
| `tx` | WED/WPDMA TX 环（BASE/CNT/CIDX/DIDX/MIB）+ WED_TX0/1_MIB 计数 |
| `wed` | `echo 3 [ring] [idx]` 打印 TX ring cell；`echo 4 ...` RAW；`echo 9` TX reset；`echo 5` DBG（含 WED_TXD_DW0..DW4） |
| `rx` | WED RX 环 + WPDMA RX 环 |
| `stat` | warp 实例指针/日志级别 |
| `wo` | WO 固件状态（DEV_000000 / 20241115171820 / MCU Alive） |

`/proc/hnat/*`（hw_nat）另有 hnat_setting/dbg/entry/dma 等只读面。

## 5. A/B 实验协议（lead 已批准，2026-11-01）

**主指标**：4× vsurv4 canary（`/data/repro/vsurv4`）命中率，**按 canary-CPU-秒归一**（消除 CPU 争用混淆）。
**副指标**：自然 NE（`/data/gw/logs/ne_events.tsv` 增量）、nerepair STAT。
**代价**：rai0 关联客户端的 tx bytes 速率（被动，不注入流量）、loadavg、WED_TX1_MIB 速率。

| 臂 | 时长 | HW_TX_EN |
|---|---|---|
| pilot | 5 min | TRUE（估率） |
| A 基线 | 20 min | TRUE |
| B 干预 | 20 min | **FALSE** |
| C 恢复 | 15 min | TRUE |

中止条件（任一）：客户端 tx 速率归零且 60s 不恢复；loadavg 翻倍且持续 5min；异常内核日志/Oops；B 臂 canary 反而升高。
回滚：`echo 0 1 > ctrl`；结束必须确认 `HW_TX_EN: TRUE`。

## 6. 结果（2026-11-01 00:12–00:47，窗口 1）

**判决：HW_TX_EN 门控对记录写入率无效 → WED tuple 路径在本负载下不是（或未激活的）写入者。**
（措辞按 Lead 要求收紧：真正的"证伪"要等 §9 的 rmmod mtk_wed 实验。）

### 6.1 三个必报的数

| 指标 | A 臂 HW_TX_EN=TRUE | B 臂 HW_TX_EN=FALSE | 结论 |
|---|---|---|---|
| canary 命中（主） | 456 次 / 20.3 min | 246 次 / 8.1 min | — |
| 归一：命中/千个 WED TX 包 | **1.519** | **1.390** | 比值 **0.915（95% CI 0.783–1.068）** |
| 自然 NE（副） | +1（1602→1603） | +0 | 75 min 对 0.5/h 基线**无功效**，不作结论 |
| 吞吐（rai0 客户端 tx） | 24.6 MB/min | 36.4 MB/min | 比值 1.48（**无下降**） |
| loadavg | 12.63 | 12.50 | 无变化 |

若 tuple 路径是写入者，B 臂应为 0；实测 246 次，且按 TX 包归一后**无任何下降**。
吞吐/load 也无变化 → 该门控对这条流量**根本没生效**（见 §9 的诊断项：可能 tuple 路径本来就未被调用）。

### 6.2 为什么这条流量可能本来就不走 tuple 路径

`warp_wlan_tx()` 有两个前置门：① `wifi_hw_tx_allow()`（mt_wifi 回调，ops->hw_tx_allow）；
② HW_TX_EN。任一门返回 0 就跳过 `wifi_tx_tuple_add()`。本次实验只控制了 ②，没有控制 ①。
→ 若 ① 本来就为 0，则 HW_TX_EN 是**惰性**的，本次"无变化"不代表 tuple 路径不是写入者。

### 6.3 副产物：canary 已是标定过的高速探测器（对全队有用）

命中率 **1.3–1.5 次/千个 WED TX 包**、20–35 次/min（4 实例）。因此：
- 任一 A/B 只需 **5–10 min/臂**即可判 50% 量级的效应（本次 B 臂 8 min 就有 246 命中，P(0)=e^-246）；
- 不需要再开 75 min 长窗；**但**自然 NE 仍必须 ≥6 h 窗口（暴露率差异，见 §8.1）。

### 6.4 实验纪律记录

- 冒烟（10 s）通过：FALSE→TRUE 往返 + 客户端 tx 继续增长；中止条件未触发（loadavg 7.3→12.6 未翻倍）。
- 回滚：`echo 0 1 > ctrl` 已执行并 `cat` 确认 **HW_TX_EN: TRUE**；4 个 canary 已 kill（count=0）；锁已 release。
- `/data/gw/logs/drills.tsv` 已写 `kind=hw-drill, owner=crash-root, target=warp1`（epoch 1793463169–1793466829）。

## 9. 下一步（按 Lead 批准的 02:17–02:42 槽位）

| 步骤 | 内容 | 判据 |
|---|---|---|
| P1 诊断（5 min） | `echo 2 > /proc/warp_ctrl/warp1/stat`（WARP_DBG_INF）→ dmesg 找 `wifi_tx_tuple_add` 日志；同时按实时 CIDX dump WED TX ring cell（`echo 3 [ring] [idx] > wed`，输出走 **dmesg** 不是 stdout） | 有 tuple 日志=路径活跃→6.1 的"无变化"是真证伪；无日志=路径未激活→降级为"未激活" |
| P1b 形状比对 | 把 ring cell 的 DW0..DW3 与 h4 记录的 `{0x14d8b, 0, 0x00000641, 0x0109a8c0}` 比对 | 相同=记录就是 WED TXD |
| P2 往返（10 s） | `rmmod mtk_wed` → `lsmod` → `insmod /lib/modules/5.15.134/mtk_wed.ko` → `lsmod` → 客户端 tx 是否续增 | 往返失败→放弃正式实验 |
| P3 正式（10+5 min） | rmmod → canary 10 min → insmod → 恢复 5 min | 命中→0 且 **WiFi 数据面仍活**（客户端 tx 字节在涨）才算阳性；"WiFi 死了所以没 TX"=假阴性，必须排除 |

**硬件级备选（若 rmmod 不可用）**：`warp_reset_hw` 用 `and w1,w1,#0xfffffffe; str w1,[base+0x208]` 停 WED TX DMA
（`WED_GLO_CFG=0x40000045`，bit0=TX DMA enable）。可用 `echo 0 1 0x208 0x40000044 > /proc/warp_ctrl/warp1/cr` 直接写。
**代价**：停 WED TX DMA 很可能同时停掉 WiFi 数据面 → 与 rmmod 同样的假阴性风险。


## 7. 证据文件

- 原始时间序列：`_local/evidence/crash-root/hwtx_<stamp>.jsonl`（主机侧，不入公开仓）
- 分析：`python _local/work/crash-root/analyze_hwtx.py <jsonl>`
- 设备侧：`/data/repro/h4_*.bin`（canary 命中转储）、`/data/repro/exp_hwtx/v4_*.log`

## 8. 风险与边界

1. **不能证明"自然 NE 归零"**：canary 的 va_list 暴露率≈100%，自然进程接近 0；二者不可互推（00_STATE §6）。
   自然 NE 的 A/B 需要 ≥6h（功效见 §6 结论）。
2. **只覆盖 WiFi TX 方向**：以太/5G 方向不经 `warp_wlan_tx`。
3. **性能代价**：软件 TX 回退使每包多一次 CPU 处理；量化见 §6。
4. **开关不持久**：重启回 TRUE，若要长期开启需 rc 钩子（会与 M1-M4 的测量口径耦合，需 Lead 决策）。
