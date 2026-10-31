# 04 · 记录家族（唯一分族源）

> 目的：禁止把 A/B/C/D 混成一个“总崩溃率/总记录率”。每个家族有自己的签名、样本、因果状态、传输状态和下一步。

## 1. 总表

| 家族 | 签名 | 样本 | 因果状态 | 传输状态 | 当前假设 |
|---|---|---|---|---|---|
| **A** | `{r180|r094, r1e0, bat_va, bat_pa+8}` | 3/7 份 §21 core | 记录在 fault-time va_list，能因果 | 未定（DPMAIF/MDMA？） | dpmaif/MD 的环上下文回写 |
| **B** | `{A,0,{len,ip},0}` 或 `{B,0,A',0}` | 103/106 canary dumps；`sh.core` 有良性样本 | 记录在 fault-time va_list；canary 因果；`sh` 非因果 | **未定（VA/uaccess vs PA/DMA）** | 网络/WiFi/NAT/PPE 的 flow descriptor 写到 stale PA |
| **C** | 其它小值/自指 | 3/106 | 未定 | 未定 | 可能是部分覆盖/另一种写入 |
| **D** | 非记录自然崩溃（awk poison/NULL/负偏移） | 自然 core 样本 | 独立 bug | N/A | awk 数组清理、sh NULL、sh2 负偏移等 |

## 2. 家族 A（dpmaif context）

### 2.1 签名

32 字节，16B 对齐，典型值：

```
+0x00  u32 r180 (BAT base)   | u32 r094 (PIT producer)
+0x08  u64 r1e0 (PIT base)
+0x10  u64 bat_va (kernel VA)
+0x18  u64 bat_pa + 8
```

### 2.2 样本与证据

- §21.2b：00:38:05 / 00:39:38 / 00:46:02 三份，r094 单调推进，与外推采样吻合。
- 记录含**内核 VA**（`bat_va`），来源必须是 AP 内核里的驱动结构。
- 与 B 的区别：A 不含 `{len, ip}`，B 不含 `r180/r094/bat_va`。

### 2.3 状态

- 因果：记录在 fault-time va_list，能打死进程（E2）。
- 传输：未定；可能是 DPMAIF/MDMA 的 DMA，也可能是内核 uaccess。
- 身份：dpmaif/MD 侧（排除法 + 内容），但不是“所有崩溃”的写入者。
- 下一步：如果自然 NE 里 A 占比低，不要为 A 单独开新仪器；先做 B 的传输判定。

## 3. 家族 B（network flow）

### 3.1 签名

32 字节，16B 对齐，两种形态：

```
A0B2:  +0x00 u64 A (small, 0x9d49..0x2a797)
       +0x08 u64 0
       +0x10 u32 len (0x141..0x1140)
       +0x14 __be32 ip (110.65.x.x / 10.73.x.x / 192.168.9.x)
       +0x18 u64 0

B0A2:  +0x00 u64 B (tagged {len,ip}, top byte = last IP octet)
       +0x08 u64 0
       +0x10 u64 A' (small)
       +0x18 u64 0
```

### 3.2 样本与重算

- 106 份 `h3b`：fault-time x2 = `0x7ffffff9c0`（106/106）；71 A0B2 + 32 B0A2 + 3 other。
- 71/71：更深副本（0x780）也是同一记录；32/32：更深副本健康。
- `sh.core`：自然 busybox sh 栈上有 `{0x16110,0,1c28416e:680}`，但崩溃是 NULL（0x0）——**记录在场但不因果**。
- `pf.core`：fault addr=0x2204e，PC=`va_arg`，记录在 x2——**记录因果**。

### 3.3 因果状态

- **canary（pfcanary/vsurv3）**：记录在 fault-time va_list，因果（E4）。
- **自然 sh**：记录在场，但不是本次崩溃原因（E2，机会样本）。
- **自然 ip/awk/sh2**：未在捕获栈内找到记录；awk/sh2 是不同签名；ip 的 0x157c0 在 A 范围但 PC/寄存器不像 va_list（未定）。
- **自然 NE 的记录占比**：未知；需要 P-04 栈普查。

### 3.4 传输状态（核心未决）

- 支持 uaccess：`remapu` 3/3 仍崩，P0 0 写（E1，无稳定性对照）。
- 支持 PA/DMA：`copy_to_user` 强阴性、静态 sttr/窗口阴性、记录内容是网络流、WiFi 7x、`sh` 良性记录（E1/E2，间接）。
- **未定**；三哨兵 + 只读 S1 + PF 是判决实验。

### 3.5 当前假设

> 一个网络数据面（WiFi/NAT/PPE）按**过期 PA** 写 32 字节 flow descriptor；目标页被回收成用户栈/堆；只有落在活指针上才崩。写入本身可能是正常数据面行为，异常的是**目标地址**。

这个假设能解释：`sh` 良性记录、512MB 金丝雀 0 命中、WiFi 7x、`copy_to_user` 阴性、记录内容。它**不能**解释：`remapu` 的 P0=0（除非实验假阳性，或 DMA 跟随 GUP/PTE）；所以三哨兵是必要的。

## 4. 家族 C（其它）

- 3/106：
  - `{0x603,0x273,0x5c3,0x5d5}`（8151 n=1）
  - `{0x12de,0x12d6,0x12d6,0x7bb}`（8156 n=6）
  - `{0xb55,0xb4d,0xb4e,0x54d}`（8189 n=2）
- 形态不像 A/B；可能是部分覆盖、另一种写入、或 handler 递归的残留。
- 不并入 B；单独记录，等更多样本。

## 5. 家族 D（非记录自然崩溃）

| core | 进程 | fault addr | 签名 | 判定 |
|---|---|---|---|---|
| `crash_awk.core` | busybox awk | 0x4 | `x8=0xfefefefefefefeff` poison | 独立 bug（awk 数组清理？） |
| `sh.core` | busybox sh | 0x0 | NULL；栈上有 B 记录 | B 记录 bystander + 独立 NULL bug |
| `sh2.core` | busybox sh | -0x28 | 负偏移 | 独立 bug |
| `core_ip.core` | ip | 0x157c0 | 小值；未找到记录 | 未定（可能是 B 的 A，也可能是独立小值 bug） |

规则：

- D 不得算进“记录率”；D 的修复与 B 分开。
- 自然 NE 的 48% 是 busybox；如果 D 占多数，“一个写入者”战略对总体 NE 的收益有限。
- 下一步：P-04 自然 NE 栈普查，把 D 从 B 里分出来。

## 6. 分族判据（可复制）

对任一转储/ core：

1. 找 fault-time `x2`（ucontext 或 NT_PRSTATUS），不是硬编码槽位。
2. 读 `x2` 处 32 字节；按 A/B/C 签名分类。
3. 比较 `untag(word0 - 8)` 与 `si_addr`：相等 → 记录在 `__stack`，本次崩溃与记录一致；不等 → 记录可能在 `__vr_top` 或不是本次原因。
4. 看更深副本（x2-0x240）：同记录 → 拷贝前写入；健康 → 拷贝后写入。
5. 看 `sh` 型：记录在场但 fault 不在记录上 → **bystander**，不能算记录因果。
6. 看 `awk` 型：poison/NULL/负偏移 → D，不算记录。

## 7. 禁止事项

- 把 A 的 `{r180,...}` 当成 B 的 `{len,ip}`。
- 把 B 的 71/32 当成“两个写入者”。
- 把 `sh` 的“记录在场”当成“记录导致”。
- 把 D 的崩溃算进“记录率”。
- 用 canary 的 103/106 外推到自然 NE。


## 8. 2026-10-30 21:00 更正（skeptic/ipdump/vsurv4）

- 0x780 是 va_copy 暂存槽（snprintf 帧 0x370：ap=sp+0xb0，staging=sp+0xd0，ap2=sp+0x310；printf_core 帧 0x1fa0），不是“更深的 va_list 副本”。71/32 = 两个目标地址（0x780/0x9c0），不是写前/写后拷贝；C-006 降 open。
- sh.core 是 canary2.sh 装置 shell，不是自然进程；C-009 降 E1。记录有两个零字（+0x08/+0x18），可把指针槽清零，bystander 推断不安全。
- B IP 含公网（sh.core 43.141.55.137）；C-008 改为“本机或远端网络地址”。
- vsurv4 固定（0x7ffffffd40）与随机（0x7fcc.../0x7ff9...）栈都命中；top-x2=0x390，但 x2 页内偏移 0x570/0xf30 不同；固定 VA 与固定 PA 都排除；目标 stack-top-relative、VA-resolved。
- ipdump 40/40 次成功 ip 运行 filter.pfx/label 全零；ip 填充只在崩溃时出现；ip 是受害者/传感器，不是 ip 源码 bug。
- pg2 ref=1025（1 + pg2 pin bias 1024）：没有泄漏的 GUP pin；GUP-DMA 泄漏 pin 分支死，use-after-unpin 仍可能。

