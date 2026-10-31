# 00 · 当前状态（2026-10-30 21:05）

> 本页只写“现在该信什么、下一步做什么”。每条结论的 ID 指向 [01_CLAIMS.tsv](01_CLAIMS.tsv)。
> 旧的 67%/32%、两个写入者、PIT 表项等结论已撤回，见 [ARCHIVE_MAP.md](ARCHIVE_MAP.md)。

## 1. 一句话

**记录真实、来自进程外部、不是受害者自己生成的；它精确落在 fault-time va_list，目标随进程栈布局（top-x2 恒 0x390），固定 VA 与固定 PA 都已排除。**
当前主问题：**VA-resolved 的写入是 uaccess 还是 GUP-DMA；写入者是否在 AP 可达范围。**

**2026-10-31 更新**：vsurv4 H4v1 普查 **88/112** 份 canary dump 含记录（78.6%，Wilson 95% CI **70.1–85.2%**）；`top-x2=0x390` 在 **111/112** 恒定；记录有三副本（`x2` 82、`x2-0x240` 66、`x2-0x130` 18）。canary 作为记录探测器已被验证（C-137/C-139）；自然 NE 份额 **0/4**（3 自然 core + 1 自然 .stack），Wilson 95% 上界 **49.0%**（C-142）；不能用 canary 外推（C-140）。

**判决（C-145）**：**Transport = PA/DMA（E2）**；记录 = WED TXD；页级 kprobe 判决被 `CONFIG_KPROBES=n` 阻断（C-144），故停在 E2。详见 [VERDICT.md](VERDICT.md)。

**修复（C-146..C-149）**：`nerepair` 已部署（`/data/gw/bin/nerepair` + `rc.extend v3.3` 开机自启）；修复记录家族 SIGSEGV（`Xt=sp, pc+=4`，抑制信号），覆盖所有用户进程（PID 1 + fork 跟随），排除 vsurv4 canary；**不停止 DMA 写入**（根修复需厂商驱动 R1 或 SMMU R2）。详见 [FIX.md](FIX.md)。

## 2. 已确立（E2/E3）

| ID | 结论 | 关键数字 |
|---|---|---|
| C-001 | 32B 记录可覆盖 va_list，故障地址 = word0，PC = pop_arg | pf.core: addr=0x2204e, PC=0x1014728 |
| C-002 | 按 fault-time x2 重算，103/106 在同一 32B 记录上（E2，非 E3） | 71+32+3；43 pids/one boot/40.6 min |
| C-003 | 两种形态 A0B2 71 / B0A2 32 / other 3 | 71/32/3 |
| C-005 | 转储 word0 是 va_arg 自增后；故障地址 = 自增前 | ldr/add/str/ldr；+8 |
| C-007 | B 型“错开一个字节”是 TBI/tag 截断 | B 最高字节 = IP 最后一段 |
| C-028 | word3=0 迫使 va_arg 走栈路径 | __gr_offs=0；PC=ldr x8,[x8] |
| C-036A | vsurv3 handler 不能写记录区：x2 比 sp_fault 高 8896 B | sigframe 远在下方 |
| C-049 | 40/40 次成功 ip 运行 filter.pfx/label 全零；ip 填充只在崩溃时出现 | ipdump 20× -4 + 20× -o -4 |
| C-050 | 12 个 vsurv4 栈页 pg2 ref=1025：没有泄漏的 GUP pin | 1 + pg2 pin bias 1024 |
| C-051 | 0x780 是 va_copy 暂存槽，不是“更深的 va_list 副本”；71/32 = 两个目标地址 | ap=sp+0xb0, staging=sp+0xd0, ap2=sp+0x310 |
| C-052 | 固定 VA 与固定 PA 都排除；目标是 stack-top-relative、VA-resolved | top-x2=0x390；x2 页内偏移 0x570 vs 0xf30 |
| C-053 | sh.core 是 canary2.sh 装置 shell，不是自然进程；记录有两个零字、含公网 IP | NT_PRPSINFO pr_fname=canary2.sh |
| C-055 | 空模型 0/19232；handler 伪影排除；106 份是 43 pids/one boot/40.6 min | C-002/003/004/028 降 E2 |
| C-137 | H4v1 shape 扫描：88/112 h4 含记录（A0B2/B0A2 在 x2/x2-0x240/x2-0x130）；旧 0/17 是字面字节扫描 bug | 88/112；95% CI 70.1–85.2% |
| C-139 | vsurv4 canary 是有效记录探测器；自然 NE 0/3 不是探测器伪影 | 88/112 vs 0/3 |
| C-140 | canary 记录落在自身栈、固定 top-relative 偏移；PA/DMA+页复用比 VA-targeted 更能解释（外部写入者拿不到 va_list VA）；transport 倾向 PA/DMA | 88/112；top-x2 0x390×111；w2=len\|ip |
| C-141 | core_meta v1.9 .stack/.stackerr 在真实死亡进程上验证通过 | .stack 65592 B；readable=16 |
| C-142 | 自然 NE 记录份额 0/4；Wilson 95% 上界 49.0%；自然 .stack 的 3 个 shape 都是巧合 | 0/4；≤49% |

## 3. 已撤回 / 不可再引用（X）

| ID | 旧结论 | 撤回原因 |
|---|---|---|
| C-016 | “至少两个写入者” | A/B 是同一记录的两个目标/对齐；常量是 B 的 tag |
| C-017 | “67% 可归因 / 32% 不明” | attrib.py 检查 0x780（暂存槽），不是 fault-time x2 |
| C-018 | “记录 = PIT 表项” | 活 PIT 零写；记录是 32B 上下文/网络流 |
| C-015 | “300 站点探针能点名写入者” | lr 是开窗者；300 从未成功运行 |
| C-019 | “记录 = 内核日志文本” | 单页单次；改判 aee 侧写；未独立复现（现为 open/E1） |

## 4. 未决（open）

| ID | 问题 | 当前证据 | 下一步 |
|---|---|---|---|
| C-006 | 0x780 暂存槽 vs ap2 是两个目标地址；71/32 的物理含义 | 暂存槽只活 ~10 条指令；固定写 ap2 产生不了 A0B2 | **vsurv5**：手写 va_copy 到不同暂存偏移；A0B2 跟暂存槽走/消失则 B-1 成立 |
| C-009 | sh.core 的“bystander”是否安全 | sh.core 是装置 shell；记录两个零字可把指针槽清零 | 降 E1；补良性正对照 |
| C-013/C-034 | 传输是 uaccess 还是 GUP-DMA | **判决 PA/DMA（E2，C-145）**；页级 kprobe 被 CONFIG_KPROBES=n 阻断（C-144） | 升 E3：重编内核开 KPROBES，或用户态 remap/RO 实验 |
| C-025 | 自然 NE 中记录家族占比 | 3 份自然 core 0/3 record；95% 上界 63%；canary 88/112 验证探测器 | 自然 NE 栈普查；分层；不要用 canary 外推 |
| C-026/C-038 | GUP/stale 用户指针 | 内核有完整 zerocopy 栈；模块 0 GUP 导入；驱动 dma_map_page | 查 mtk_warp/mt_wifi 的 skb frag/zerocopy；ref/use-after-unpin |
| C-035 | cth_cfu 正对照 Oops/重启 | 一次未复现；3 个候选机制 | 修 cth（递归守卫、去 dump_stack、默认关 c2u）后再跑 |
| C-044..C-048 | ip 是页级写入的受害者；HIF-TXD/FOE 形状候选 | ip 全 .text 无写 filter.pfx；mtk_wed 32B 描述符 +0x10/+0x14；hw_nat FOE IP +0x10/+0x14 | **mtk_warp**（738KB，未扫）是真正 ring/DMA；mt_wifi fh_netlink_send_to_user |

## 5. 当前方向（按优先级）

1. **P-A：mtk_warp 静态（最高价值）**。warp_wlan_tx / warp_dma_handler / warp_page_hash_get / warp_ring_init；查 skb_shinfo()->frags / skb_zcopy / dma_map_page 的入参；HIF-TXD 32B 描述符；mt_wed 薄壳；mt_wifi fh_netlink_send_to_user。
2. **P-1：vsurv5 暂存槽实验（B-1）**。手写 va_copy 到人为偏移；A0B2 是否跟着暂存槽走；B0A2 是否仍钉在 musl ap2。
3. **B-5：ref/use-after-unpin**。ref=1025 已杀泄漏 pin；若 mtk_warp 的 dma_unmap 早于 DMA/页复用，则是 use-after-unpin。
4. **B-4：三哨兵重写**。PF 按 fault PC 分类 + 迭代速率 INVALID；不要“只读 S1 + 60s”。
5. **自然 NE 普查**。3 份自然 core 0/3 record；先分层、先算 design effect；不要用 canary 外推。
6. **明确降级**：在 1–3 完成前，不再做“找那一个写入者”的新仪器/新模块。

## 6. 停止规则

- 不做没有功效计算的 A/B；阵发过程的单窗差异不算效应。
- 不把 canary 崩溃率当自然 NE 率；不把 canary 记录家族当全部 NE。
- 不在没有正对照的情况下引用“0 命中”。
- 不把不同家族混成一个“总速率”。
- 不在一个窗口里改两个变量。
- 不把“记录在栈上”直接当成“记录导致本次崩溃”；必须 fault addr 对齐 + PC 证据。
- 不把“记录在场”当成“记录因果”；sh.core 的零字可以造成 later NULL。

## 7. 本轮交付物

| 文件 | 状态 |
|---|---|
| docs/SIGSEGV/ 本目录 | 新建，当前事实源 |
| tools/oneoff/sigsegv/va_scan.py | 106 份 71/32/3；legacy 71/35 |
| tools/oneoff/sigsegv/core_scan.py | 6 份 an2 5 A0B2 + 1 B0A2 |
| tools/oneoff/sigsegv/natural_scan.py | h4/sd 解析 |
| tools/oneoff/sigsegv/vsurv4.c | 设备自检通过；h4 32888B；随机/固定栈 A0B2/B0A2 |
| tools/oneoff/sigsegv/stackdump.c | aarch64 编译；host 通过 |
| tools/oneoff/sigsegv/core_meta_v1.7.sh | staged |
| tools/oneoff/sigsegv/probe_selftest/ | PF 通过；cfu 事故；uw 待测 |
| tools/oneoff/sigsegv/ipdump.c | 40/40 成功 ip 无 fill；ip 填充只在崩溃 |
| docs/SIGSEGV/05_LOG/2026-10-30-02-v4-first.md | vsurv4/ipdump/PA 结果 |
| docs/SIGSEGV/05_LOG/2026-10-30-01-reset.md | 106 份重分类 |


## 8. 2026-10-30 21:15 · mtk_warp 静态（P-1/P-2）

- **WED TX ring 条目存 PA**：wed_tx_ring_reset（0x2078）步长 0x50，entry+0x10 = DMA 地址（PA）；wed_fdesc_init（0x22d4）把 fdesc[0x20] 的 64 位地址写进 16B HW 描述符 {u64 dma_addr; u64 ctrl}。
- **reset 路径有序**：warp_reset_hw（0xc964）先写 stop bit（ctx+0x208）并轮询 100 次，之后才 wed_tx_ring_reset；warp_ring_exit 也是先 warp_dma_ctrl_hw(ctx,0) 再 reset。reset 不是 stale-PA 窗口。
- **free_dma_tx_pkt（0x1bfc）**：dma_unmap_page_attrs → __dev_kfree_skb_any；先 unmap 再 free，但**不清 fdesc/ring，也不等硬件完成**。这是运行期 TX completion 的剩余 stale-PA 窗口。
- **RX token**：wed_release_rx_token（0x22c0）是 4 指令 stub；wed_acquire_rx_token（0x224c）调回调；RX refill 仍未闭合。
- **GUP/zerocopy 否定**：mtk_warp/mt_wifi/mtk_hwifi 0 个 GUP/pin/iov_iter/skb_zcopy；5 个 dma_map_page_attrs 全是内核 kaddr 且显式拒绝 vmalloc。
- **形状**：ip 的 .bss 填充是 17 个 16B {A,0}，与 17 个 WED TXD 对齐；32B 记录 = 两条相邻 16B TXD；txdmad DW0..DW3 的位域仍待 dump_txinfo 读出。
- **覆盖缺口**：fh_netlink_send_to_user 的实现模块不在 17 个 .ko/kallsyms 里。

**当前判决**：H-GUP 否定（0.9）；H-TOUSER 否定（0.95，warp 无 copy_to_user）；H-STALE 仍活（0.6），落点是 free_dma_tx_pkt/运行期 TX completion，而不是 reset 路径。下一步：P-C（RX 缓冲页释放+填毒+记录 PA）判决，P-B 补 free_dma_tx_pkt 的调用者（ops 结构），P-D 找缺失的 FiberHome 模块。

## 9. 测量偏差（2026-10-31，vaguard / nerepair）

- **vaguard**（自建 busybox/ip/logc/mipc_cellular/v3httpd 的 vfprintf 闸门）在自然进程里**修复**记录家族：vaguard.tsv **49 次**（44 ip、4 awk、1 ping），这些**不进** ne_events/cores → 自然 NE 普查 **0/4 是 post-guard 下界**（C-152），不能当作无偏的自然份额。
- **vsurv4 canary 不链 vaguard**（build_usr.sh 无 vaguard.o）→ **h4 88/112 不受影响**（C-137/C-139 仍成立）。
- **ip 的 .bss filter 填充**不是 printf 类 → **40/40 结论不受影响**；但 ip 的总崩溃数被闸门压低（44 次 printf 命中被修），ip 的自然 NE 计数偏低。
- **nerepair** 现已对全部进程修复同一家族（vsurv4 除外）→ **修复后自然 NE 不再可比**；干净的自然份额窗口需**停闸门 + 停 nerepair**（canary 仍记录 h4）。
- 闸门 49 次命中的时间跨度 ≈42 h（epoch 1793183044..1793333882）→ ≥1.17 次/小时的记录家族事件（受闸门覆盖的二进制内）；因闸门在写 core/h4 之前就修复，不能换算成自然份额（C-153）。

## 10. 运行时消元：HW_TX_EN 门控实验（2026-11-01 00:12–00:47，C-154）

**判决**：把 mtk_warp 的 `HW_TX_EN`（`/proc/warp_ctrl/warp1/ctrl`）置 FALSE，**不改变** 32B 记录写入率。
→ **WED tuple 路径在本负载下不是（或未被激活的）写入者**；"证伪"待 rmmod mtk_wed 实验。

**关键数字**（4× vsurv4 canary，按 WED TX 包归一）
- A 臂（TRUE）：456 命中 / 20.3 min / 300,152 TX 包 = **1.519 命中/千包**
- B 臂（FALSE）：246 命中 / 8.1 min / 176,990 TX 包 = **1.390 命中/千包**
- 比值 **0.915（95% CI 0.783–1.068）**；吞吐 24.6→36.4 MB/min（无下降）、loadavg 12.63→12.50（无变化）
- 自然 NE：A +1、B +0 → 75 min 窗口对 0.5/h 基线无功效，**不作结论**（§6 停止规则）

**静态依据**：`warp_wlan_tx`(.text+0x970) 读 `[ctx+0xd31]`（HW_TX_EN），为 0 则 return 0，跳过
`wifi_tx_tuple_add`；`ctrl` 写处理器(.text+0x5d6c) 只 `strb`，无 MMIO 写；mtk_wed.ko 0x8b8 调
`warp_wlan_tx`、0x8bc `cbz w0` → 0 则走 `ops->tx` 软件回退。**门控是惰性的可能原因**：
`warp_wlan_tx` 还有第一道门 `wifi_hw_tx_allow`（mt_wifi 回调），本次未控制。

**副产物（测量学）**：canary 命中率 **1.3–1.5 次/千个 WED TX 包、20–35 次/min**（4 实例），
B 臂 8 min 即 246 命中（P(0)=e^-246）→ **后续机制 A/B 只需 5–10 min/臂**；
自然 NE 仍必须 ≥6 h（canary 暴露率≈100% vs 自然进程≈0，不可互推）。

**证据**：`_local/evidence/crash-root/hwtx_*.jsonl`（主机侧）；设备 `/data/repro/h4_*.bin`（334→1243）；
`docs/SIGSEGV/07_LEVER.md` §6；`tools/oneoff/sigsegv/hwtx_gate.sh`（门控脚本，status/off/on/verify）。
**下一实验**：02:17–02:42 —— P1 WARP_DBG_INF + TX ring cell dump（形状比对）→ P2 rmmod/insmod 往返 → P3 rmmod 10min A/B。


