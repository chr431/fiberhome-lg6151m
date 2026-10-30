# 00 · 当前状态（2026-10-30 21:05）

> 本页只写“现在该信什么、下一步做什么”。每条结论的 ID 指向 [01_CLAIMS.tsv](01_CLAIMS.tsv)。
> 旧的 67%/32%、两个写入者、PIT 表项等结论已撤回，见 [ARCHIVE_MAP.md](ARCHIVE_MAP.md)。

## 1. 一句话

**记录真实、来自进程外部、不是受害者自己生成的；它精确落在 fault-time va_list，目标随进程栈布局（top-x2 恒 0x390），固定 VA 与固定 PA 都已排除。**
当前主问题：**VA-resolved 的写入是 uaccess 还是 GUP-DMA；写入者是否在 AP 可达范围。**

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
| C-013/C-034 | 传输是 uaccess 还是 GUP-DMA | 固定 VA/PA 排除；VA-resolved；copy_to_user 强阴性；ref=1025 杀死泄漏 pin | **mtk_warp** GUP/zerocopy 静态；三哨兵按 B-4 重写 |
| C-025 | 自然 NE 中记录家族占比 | 3 份自然 core 0/3 record；95% 上界 63% | 自然 NE 栈普查；分层；不要外推 |
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

