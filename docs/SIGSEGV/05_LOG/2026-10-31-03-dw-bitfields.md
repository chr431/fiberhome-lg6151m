# 2026-10-31-03 DW 位域与记录映射（C 轨道）

## 0. 预登记
- 假设：32B 记录 = 一个 WED TXD（8 DWs）；16B txdmad = 4 DWs；记录内容 = TXD 的 DW0/DW2 载荷，DW1/DW3=0。
- 判据：h4 记录的 w2 = len | ip<<32；len 在 [0x100,0x10000]；ip 是 __be32。
- 正控：h4_11451 的 x2 记录；负控：自然 .stack 的 3 个 shape 巧合。

## 1. 实测记录内容（h4_11451_1，x2=0x7fe87b8530）
```
w0 = 0x14d8b            (A, small)
w1 = 0
w2 = 0x0109a8c000000641 (len=0x641=1601, ip=0x0109a8c0=1.9.168.192)
w3 = 0
```
- x2-0x240 副本：w0=0x14d83，w2 相同；x2-0x130 不是记录。
- 结论：记录 = **一个 WED TXD**，DW0/DW2 载荷、DW1/DW3=0；w2 的 len+ip 与“WED TXD 长度 + 包 IP”一致。

## 2. 静态布局
- `wed_tx_ring_reset`（0x2078）：entry stride 0x50；`+0x00 len`、`+0x08 VA`、`+0x10 PA`；`str w27,[x1,#4]` 写 0x80000000 标志。
- `wed_fdesc_init`（0x22d4）：把 64-bit dma_addr 写进 16B HW desc。
- `.rodata.str1.1`：txdmad DW0..DW3（16B）、WED_TXD_DW0..DW7（32B）。
- 推断（E1）：txdmad = {DW0/DW1 = addr, DW2/DW3 = len/flags}；WED TXD = 2×txdmad；记录 = TXD 的 DW0=A、DW1=0、DW2=len|ip、DW3=0。

## 3. 与 h4 普查的一致性
- 88/112 h4 含记录；记录在 x2/x2-0x240/x2-0x130 三副本；top-x2=0x390 恒定。
- 记录 w2 的 len/ip 与 WED TXD 语义一致（C-138）。
- **transport 倾向 PA/DMA**：外部写入者若走 uaccess/VA，无法解释它如何拿到 canary 的 va_list VA；PA/DMA + 页复用（canary 栈页 = 回收的 WED TX 页）能解释 88/112 与固定 top-relative 偏移（C-140）。
- 剩余决定性实验：页级 probe（pgprobe）或 pg2 的 RO/remap 实验。
