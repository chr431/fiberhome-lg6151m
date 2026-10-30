# 第十轮：四个并行逆向扫荡 + 把「所有已知的内核→用户写机制」逐个排除

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

本轮按「多逆向、广撒网」执行：四个子代理并行扫荡（内核镜像结构、17 个厂商模块、netfilter 栈、
MTK 数据面），同时我自己补了三件事：netfilter 模块拉全、探针正对照、sttr 扫描重做。

## 1. 先修正两条前提（子代理推翻了我上一轮的结论）

**(a) PAN 判断错了。** 上一轮我从镜像里有 cpu_enable_pan（含 msr pan,#1）推断「硬件 PAN 生效」，
据此认为「只有 sttr 和 copy_to_user 能写用户内存」。实际上 CONFIG_ARM64_PAN 与
CONFIG_ARM64_SW_TTBR0_PAN 两个都编进了镜像，运行时由 system_uses_hw_pan()（CPU 特性）决定。
/proc/cpuinfo 里没有 pan → 走 SW TTBR0 PAN 路径 → **uaccess 窗口内普通 str/memcpy 写用户 VA 是成功的**。

**(b) 我的 sttr 成组扫描口径有缺陷。** 原来要求 sttr 相邻，而 __arch_copy_to_user 的 n==0x20 快路径
是 sttr x7/x8 中间隔着 add/ldp，会被切成 2+2。

## 2. 重做 sttr 扫描（带别名归一化）

tmpfiles/an4/zz_sttr32.py：对每个函数跟踪 reg -> (root, off)（穿过 mov/add/sub 链，遇 bl 清空 caller-saved），
把每条 sttr 记成 (root, eff_off, size)，再找同一 root 上连续覆盖 >=24 字节的。

**结果：整个内核镜像里只有一处 —— __arch_copy_to_user 自己（span=270，偏移 0,1,3,7,15,23,31,…）。**
其余 41,694 个函数一处都没有。

## 3. netfilter 模块拉全（补上「20% 符号不在镜像里」的盲区）

kallsyms 61,689 条里 **12,365 条在模块空间**，含全部 nf_conntrack* / nft_* / wed_*。
已从设备拉下并扫描：nf_conntrack, nf_conntrack_netlink, nf_flow_table, nf_flow_table_inet/ipv4/ipv6,
nft_flow_offload, nft_ct, nf_tables, nf_nat。

| 模块 | text 函数 | sttr | copy_to_user 调用 |
|---|---|---|---|
| nf_conntrack | 136 | 0 | 1（nf_confirm，SO_ORIGINAL_DST，n=0x1c） |
| nf_conntrack_netlink | - | 0 | **0** |
| nf_flow_table | 28 | 0 | **0** |
| nft_ct / nft_flow_offload | - | 0 | **0** |
| hw_nat | 393 | 0 | 1（get_ppe_mib_ip） |

子代理结论：ctnetlink 逐字段 nla_put_be32，最大单属性 0x10；flow_offload_tuple.dst_v4 在 **+0x10** 不是 0x14；
nf_conntrack_tuple 布局确认（dst.u3.ip 确在 +0x14，sizeof 0x28）但**数值不符**（+0x10 应为 port|l3num<<16 >=0x20000，
实测高 16 位恒 0；+0x00 应是源 IP，实测是小非 IP 值）。

## 4. 探针正对照（这条最重要，把「零命中」从可疑变成可信）

子代理质疑：「__arch_copy_to_user 是单份符号，任何 read()/recvmsg() 都过它，200+ 次崩溃零命中很可疑，先做正对照」。

做了：insmod cth.ko hook_ac2u=1 nfilter=32 watch=[0x1000,0x7fffffffffff)，然后 ls、cat /proc/version、
再让 shell 装一个信号处理器（走 rt_sigaction）。
**结果 78 次命中**（ash/ping/sh 的 rt_sigaction，n=0x20，lr=__arm64_sys_rt_sigaction+0x94）。

=> **探针确实有效。零命中是结论，不是仪器故障。**

## 5. 新探针：copy_from_user 误用检测

正确代码里 copy_from_user(dst, src, n) 的 dst **永远是内核指针**。任何 dst 落在用户地址的调用都是
「把内核数据写进用户空间」的误用 —— 它走 uaccess 机制，**对 copy_to_user 钩子完全隐形**。

已在 cth.ko 里加了第三个钩子：__arch_copy_from_user+0 -> trampoline -> cth_cfu()，
只在 dst 落在 [0x1000, 0x8000000000) 时记录 + dump_stack()。**这个过滤器按构造零误报。**

已 armed 并跑过 48 个受害者 x 4 分钟：**0 命中**。

## 6. 本轮排除清单（每一条都带仪器或静态证据）

| 机制 | 排除方式 |
|---|---|
| copy_to_user | 钩子 + 正对照（78 命中）→ 200+ 次崩溃零命中 |
| copy_from_user 误用 | 新钩子（零误报）→ 0 命中 |
| uaccess 窗口内的普通 memcpy/memset | 内核 267 个窗口逐个扫 → 0；169 个模块 → 0 |
| 内联 sttr 成组写 | 别名归一化重扫 → 全镜像只有 __arch_copy_to_user 自己一处 |
| 模块内联 sttr | 169 个模块 sttr 总数 = 7，无 32 字节成组 |
| conntrack tuple | 布局确认，数值不符 |
| flow table / nft offload | dst_v4 在 +0x10；模块无 ucopy |
| hw_nat / mtk_wed / PPE | hw_nat 唯一 copy_to_user 在 get_ppe_mib_ip；mtk_wed 被 strip 且无 ucopy |
| MTK 数据面描述符 | TX 8B / BAT 24B / PIT 16B，**都没有 IP 字段** |
| ppp_async（全 169 模块唯一 n==0x20 的用户拷贝） | **模块未加载**（lsmod 无 ppp） |
| 用户态守护 | 调试模式全关后照崩 |

## 7. 这意味着什么

**所有已知的内核→用户写机制都已被排除，而且每一种排除都配了可复现的仪器或静态证据。**

剩下只有两种可能：
1. **某条基础测量是错的** —— 最可疑的是第四轮「写走受害者自己的用户页表」那条
   （GUP + kmap 路径与「固定线性别名」在实验设计上不可区分）；
2. **写入根本不经过 uaccess** —— 但第四轮 A/B 两个实验都指向「经用户页表」。

下一轮应该做的事：**用新设计重做「写从哪里来」这条基础测量**，而不是继续找新的代码形状。
具体：把受害者的目标页同时做三件事 —— (a) 用户 PTE 指向影子页、(b) 线性别名指向第二个影子页、
(c) 两个影子页都加哨兵；一次崩溃就能判定写落在哪一侧。第四轮的实验只做了其中一侧。

## 8. 本轮教训

- **教训 46**：探针必须先做**正对照**再采信零命中。子代理这条质疑是对的。
- **教训 47**：静态扫描的**分组口径**会决定结论。要求「相邻」会把 sttr x7/x8 … add … sttr x7/x8 切成 2+2，
  从而得出「没有 32 字节成组写」的错误结论。必须做别名归一化 + 按覆盖字节数算。
- **教训 48**：CONFIG_* 的存在 != 运行时生效。cpu_enable_pan 在镜像里不代表硬件 PAN 在用；
  必须查 /proc/cpuinfo 的 CPU 特性。

---

## 9. 最后一块拼图：uaccess 窗口内的普通 store（本轮补做）

上一节的窗口扫描只看了窗口内的**函数调用**（`bl memcpy` 之类）。窗口内的**普通 store 指令**没查过，
而 SW TTBR0 PAN 下那正是「隐形写用户内存」的最后一种形态。

`tmpfiles/an4/zz_winstore.py`：在内核镜像里找出 **1032 个完整 uaccess 窗口**（`bl enable` … `bl disable`），
逐个列出窗口内的 `str`/`stp`/`strb`/`strh`/`stur`/`stnp`。

**结果：全部 1032 个窗口里只有 14 条普通 store，而且每一条的目标都是栈（`[sp, #...]`）——**
**没有任何一条写向用户指针。**

分布：`packet_ioctl` 4、`do_ipv6_getsockopt` 3、`rawv6_ioctl` 3、`fault_in_readable` 2、
`parse_usbdevfs_streams` 1、`snd_pcm_common_ioctl` 1。

## 10. 于是负结果是完备的 —— 这本身是结论

| 可能的「内核→用户写」路径 | 状态 |
|---|---|
| `copy_to_user` / `__arch_copy_to_user` | 已挂探针 + 正对照 78 命中 → 200+ 次崩溃 **0 命中** |
| `copy_from_user` 目标误为用户地址 | 新探针（零误报）→ **0 命中** |
| uaccess 窗口内调用 `memcpy`/`memset` | 内核 267 窗口 + 169 模块 → **0** |
| uaccess 窗口内普通 `str`/`stp` | 1032 窗口 → **14 条，全部写栈** |
| 内联 `sttr` 成组写 | 别名归一化重扫 → 全镜像只有 `__arch_copy_to_user` 自己 |
| 模块内联 `sttr` | 169 模块 sttr 总数 7，无成组 |
| 模块 uaccess 窗口内 store | 17 厂商模块 → **0** |

**所有已知形态都被直接证据排除。这在逻辑上只有一个出口：某条基础测量是错的。**

最可疑的是第四轮「写走受害者自己的用户页表」：那个实验把用户 PTE 重定向到新页后
**观察到受害者仍然崩溃**，据此判定「写跟随用户 PTE」。但重定向一个**活栈页**的 PTE 本身就可能
（TLB/ASID/内容一致性）让受害者崩溃 —— 该实验缺少「重定向后先稳定运行一段再统计」的对照，
所以它可能是假阳性。

### 下一轮的正确动作

重做第四轮的基础测量，这次要带**三哨兵**和**重定向有效性自检**：

1. 目标页用户 PTE → 影子页 S1（内容复制）；
2. 原物理页 P0 的**线性别名** → 影子页 S2（内容复制）；
3. S1 的线性别名保持原样（这样仍能用 `page_address(S1)` 读它）；
4. 三个页都加哨兵，先让受害者**稳定运行 60 秒**（证明重定向本身不致病），再进入统计窗口；
5. 同时 armed `do_page_fault` 钩子，任何内核态 fault 都记录 `far`+`pc`。

判据：记录落在 S1 → 经用户 PTE；落在 S2 → 经线性映射；落在 P0 → 绕过两者（直接物理地址/DMA）。

