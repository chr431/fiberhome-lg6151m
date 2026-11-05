# U-C1 · 本地源码审计：谁可能向另一个用户态进程的地址空间写 32B 记录

> 日期：2026-11-04 ｜ 性质：**零风险只读本地源码审计**，未访问设备、未作任何写操作、未改任何源代码。
> 范围：`lg6151m-public/gw/**`、公开仓 `tools/oneoff/sigsegv/**`、私有仓 `authd/`+`plugin/`、
> `analysis/kern/` 文本件（kallsyms/config），以及全项目关键词 grep。
> 纪律：每条结论带 `file:line`；本地源码与设备实证严格区分；不臆测。
> 版本钉死：`gw/bin/slotguard` 1.0 / `gw/bin/nerepair` 2.2 / `gw/bin/stackdump` 1.1（见 `tools/VERSIONS.tsv`）。

## 0. 被调查现象的既定实证（背景，本文档不重新验证）

- 32B 家族记录 `{w0 任意, w1=0, w2 = len(低32) + 大端 IPv4(高32), w3=0}` 落在受害者活 `va_list` 栈页。
- 写入被 **PTE 权限位门控**（RO 脉冲期不写：`docs/review/U-A2_PULSE_RESULT_2026-11-04.md:10,86`）；
  **不经 ex_table/fixup_exception**（`docs/review/U-B1_FXHOOK_RESULT_2026-11-04.md:29,92`）；不是 DMA（同上 U-A2:16）；
  要求受害者线程在用户态运行、不绑定每轮调用（`docs/review/WRITER_HUNT_HANDOFF.md` §一）。
- 最新机制层最优解释：**用户态写者、权限感知式写入**（U-B1:29,92），写者身份**仍未点名**（U-B1:94,120）。
- 长期判决：CPU `copy_to_user` 漏斗 2895 万次零命中（`docs/SIGSEGV/VERDICT.md:188`），厂商侧
  「按当前帧定位、非 uaccess」的写入机制未点名（VERDICT.md:141-142,191）。

---

## ① 候选清单

> 「目标 VA 是否别的进程」列中的 **Y** = 代码明确以 `pid` 参数打开/寻址另一个进程的地址空间；
> **N** = 只写调用者自己的用户缓冲（proc_read/selftest 语义）。
> 「产生 32B 形状」= 该站点写出的**内容**是否就是 `{w1=0, w3=0, w2=len|ip<<32}` 家族形状。

### C-1（最高优先）`gw/src/slotguard.c` —— 常驻守护经 `/proc/<pid>/mem` 写别的进程栈

| 项 | 内容 |
|---|---|
| 文件:行 | `gw/src/slotguard.c:418-432`（`write_mem`）、`:410`/`:425`（`/proc/%d/mem`）、`:428`（`pwrite`）、`:746-747`（调用点）、`:770-773`（SANITIZE 日志） |
| 代码片段 | `:425-428` `snprintf(path,...,"/proc/%d/mem",pid); fd=open(path,O_RDWR); r=pwrite(fd,buf,len,(off_t)va);` ；`:746-747` `expect[0]=va; expect[1]=0; expect[2]=0; expect[3]=0; write_mem(pid,va,expect,32,&perm)` |
| 写的是哪种路径 | **用户态跨进程写**：`/proc/<pid>/mem` → 内核 `mem_write` → `access_remote_vm`（GUP/FOLL_WRITE）。**不经 `__arch_copy_to_user`**（`docs/review/WRITER_HUNT_PHASE1_REVIEW.md:68` 明列此通道为漏斗/audit 盲区：`mem_write→access_remote_vm`）。 |
| 目标 VA 是否别的进程 VA | **Y**：`pid` 为白名单守护（dnsmasq/nerepair）的 pid，`va = start_stack - offset`，见 `gw/slotguard.conf:21-23`、`:305/:339/:374` 的 `/proc/%d/stat`/`syscall`/`maps` 读取。 |
| 是否产生 32B 形状 | **不产生家族形状，反而销毁它**：写入值是 `{va,0,0,0}`（`:746`），且**前置条件是槽内容已严格匹配家族形状**（`:139-162` `sg_classify`；`:736` 写前重读 `sg_classify(w2)>=0`）。即它是记录的「消费者/消毒器」，不是「生产者」。 |

**判定（关键，反直觉点名）**：这是全项目**唯一一个「已部署、常驻、确实会向另一个用户进程地址空间写 32 字节」的代码路径**。
但它写的是**全零化的无害值**、方向与现象相反，因此**不是 32B 家族记录的写者**。
它是本项目为补偿该谜题而写的自研控制（`gw/src/slotguard.c:1-9`：文档自陈「writer is still unnamed」「does NOT stop the writes」）。
设备当前态为**零写**：`gw/slotguard.conf:12-15,21-23`（三槽全 `observe`）、`gw/src/slotguard.c:687`（`mode!=SANITIZE || !g_armed` ⇒ 直接返回 `WOULD_SANITIZE`）、`gw/rc.extend.sh:223-231` 第二钥匙；
且 `docs/review/README.md:20` 实测 `slotguard.arm` 缺失 ⇒ 「slotguard 零写」，`docs/review/SKEPTIC_ARMED_WINDOW.md:19,80` 复核三钥匙全缺。
⇒ **即便它写，形状与时机都不吻合；当前更是不写。排除为家族记录写者，但必须列为 Top 候选（见 ③）。**

### C-2 `tools/oneoff/sigsegv/auditwatch/vmpoke.c` —— `process_vm_writev` + `PTRACE_POKEDATA` 正对照触发器

| 项 | 内容 |
|---|---|
| 文件:行 | `vmpoke.c:4-5`（头注释）、`:123-137`（N×`process_vm_writev` 32B）、`:145-157`（`PTRACE_ATTACH→POKEDATA→DETACH`） |
| 代码片段 | `:135` `process_vm_writev(32B -> child+%d)`；`:152` `sys_ptrace(PT_POKEDATA, pid, ..., POKE_WORD)`；`:130-131` 每笔 32B 填 `memset(out, i&0xff, 32)` |
| 写的是哪种路径 | **用户态跨进程写**：`process_vm_writev`→`process_vm_rw_core`→`access_remote_vm`；`PTRACE_POKEDATA`→`ptrace_writedata`/`generic_ptrace_pokedata`。 |
| 目标 VA 是否别的进程 VA | **Y**：fork 出的**子进程自己的栈**（`vmpoke.c` 头「against the CHILD's own stack」）。 |
| 是否产生 32B 形状 | **否**：`process_vm_writev` 写的是 `i&0xff` 填充的 32B 正对照（`vmpoke.c:126-131`），POKEDATA 写单字 magic `0x706f6b65`（`:26`）；均非 `{w1=0,w3=0,w2=len|ip<<32}`。 |

**判定**：oneoff 取证仪器，用途是给 A2 audit 规则做正对照（`auditwatch/README.md:9-12`），非常驻、不部署（`README.md:2-3`「不注册、不常驻」）。
设备实测 A2 窗它产生 3/3 正对照行、覆盖集内其它 0 条（`docs/SIGSEGV/01_CLAIMS.tsv:180` C-189）。**排除为写者**。

### C-3 `tmpfiles/repro/vmwrite32.c`（本地 tmpfiles，非仓内活跃资产）—— 外部 32B 写正对照

| 项 | 内容 |
|---|---|
| 文件:行 | `tmpfiles/repro/vmwrite32.c:8-9`（头注释）、`:17-18` |
| 代码片段 | `:18` `ssize_t n = process_vm_writev(pid, &liov, 1, &riov, 1, 0);`（liov/riov 各 32B） |
| 写的是哪种路径 | 用户态 `process_vm_writev` 跨进程写 32 字节 |
| 目标 VA 是否别的进程 VA | **Y**：命令行 `<pid> <hexva> <32-hex-bytes>` 任意目标 |
| 是否产生 32B 形状 | **否**：内容是调用者传入的任意 32 hex bytes；头注释 `:8-9` 自陈 "external 32B write … Used as the EXTERNAL fault positive control for dropwatch"。 |

**判定**：PC/取证用正对照，不在部署链（`tmpfiles/` 为本地运行期目录，AGENTS 性质分区「用完即弃」）。**排除**。

### C-4 `tools/oneoff/sigsegv/probe_selftest/probe_selftest.c` —— 内核 `copy_to_user` 向「任意用户 VA」写 32B（正对照）

| 项 | 内容 |
|---|---|
| 文件:行 | `probe_selftest.c:38`（hrtimer 回调）、`:62`（`pf` 分支）、`:30`（`kbuf[32]`） |
| 代码片段 | `:38` `rc = copy_to_user((void __user *)g_va, kbuf, 32);`；`:62` 同（`va` 来自 `echo "pf 0x7fff..." > /proc/probe_selftest`，`:58-59`） |
| 写的是哪种路径 | **内核 uaccess `copy_to_user`**（含 hrtimer 软中断上下文版本） |
| 目标 VA 是否别的进程 VA | **条件 Y**：`va` 是用户传入的任意用户 VA，可指向别的进程；但此模块只在 `current` 的 mm（发起写 `/proc` 的进程）下解析该 VA。 |
| 是否产生 32B 形状 | **否**：`kbuf = "PROBE_SELFTEST_32BYTES_PAYLOAD"`（`:30`），非家族形状。 |

**判定**：`docs/review/WRITER_HUNT_HANDOFF.md` 所列「待构建/设备待测」正对照模块（`tools/oneoff/sigsegv/README.md` §2 表：`probe_selftest/` 状态「设备待测」），用途是验证 cth/uw 钩子是否活着（`:1-15`）。
它是**唯一在仓内源码里真正出现「内核向指定用户 VA 写 32 字节」的 copy_to_user 站点**，因此列候选；但内容/时机/常驻性均不符，且不经 `ex_table` 的 uaccess 已被 U-B1 排除。**排除为写者**（仅作机制探针）。

### C-5 `gw/src/nerepair.c` —— ptrace 独占 tracer（SETREGSET 改寄存器）+ `process_vm_readv` 读

| 项 | 内容 |
|---|---|
| 文件:行 | `:279`（`read_mem`→`process_vm_readv`）、`:758`/`:926`/`:965`（`PTRACE_SETREGSET`）、`:987`（`PTRACE_ATTACH`）、`:1009-1010`（SETOPTIONS/CONT）、`:1145-1152`（CONT） |
| 代码片段 | `:279` `process_vm_readv(pid,&l,1,&r,1,0)`；`:758` `ptrace(PTRACE_SETREGSET,pid,NT_PRSTATUS,&iov)`（`r->regs[rn]=r->sp; r->pc+=4;`，`:756-757`） |
| 写的是哪种路径 | **读**：`process_vm_readv`（只读）；**写**：仅 `PTRACE_SETREGSET` 改**寄存器**（非内存）。`PTRACE_ATTACH` 使其成为**全进程独占 tracer**。 |
| 目标 VA 是否别的进程 VA | 寄存器层面 Y（改的是被 trace 进程的 pt_regs）；**无任何用户内存写**。全仓 `grep process_vm_writev|PTRACE_POKEDATA|pwrite|/proc/.../mem O_RDWR` 在 `nerepair.c` 零命中。 |
| 是否产生 32B 形状 | **否**：只读 32B 用于 `shape_ok` 判定（`:330,:397,:877` `read_mem(pid,va,w,32)`），从不写回内存。 |

**判定**：设备态关键旁证 —— 它是**独占 tracer**，使第三方 `PTRACE_ATTACH/POKEDATA/SETREGSET` 一律 EBUSY，故**「用户态 ptrace 型跨进程写」在 nerepair 在役期结构性不可能**（`docs/review/WRITER_HUNT_PHASE1_REVIEW.md:65-68` §4-1；C-189 亦证实 ptrace=117 被排除的代价当前为 0）。**排除为写者；且它反证了 ptrace 类第三方写者不存在。**

### C-6 `gw/src/v3_fix.c` —— 内核 netfilter 模块，改 IPv4 TTL（不写用户 VA）

| 项 | 内容 |
|---|---|
| 文件:行 | `:22`（`#include <linux/skbuff.h>`）、`:81`（`ttl_fix_fn(...struct sk_buff *skb,...)`）、`:93-113`（`iph=ip_hdr(skb); iph->ttl=...; iph->check=...`） |
| 写的是哪种路径 | 内核态对 **skb（内核线性映射）** 改写 IP 头 TTL/校验和；**无任何 `copy_to_user`/`put_user`/GUP**。 |
| 目标 VA 是否别的进程 VA | **N**（内核 skb，非用户 VA） |
| 是否产生 32B 形状 | **否** |

**判定**：我们自有内核模块（v3_fix.ko，`gw/src/v3_fix.c:1-18`），TTL 伪装 + RX unhook，写的是内核 skb。**排除**。

### C-7 `tools/oneoff/sigsegv/bmods/tuphook.c` —— 构造 `len | ip<<32` 复合字的「观测」代码

| 项 | 内容 |
|---|---|
| 文件:行 | `:630` `lp |= (u64)ip << 32;`（`:597` `lp=len` 取自 `skb->len`、`:624` `ip` 取自 `ip_hdr(skb)->saddr`）、`:1561` `u32 ip=(u32)(lip>>32); u32 len=(u32)lip;` |
| 代码片段 | `:597-630` 从 skb 提取 `len`(u32) 与 `saddr`(4B)，组合成 `u64 len_ip`（低32=len，高32=大端 IP），与 32B 记录 w2 形状**完全同构**；`:27` 头注释明列家族 `{len in 321/1600/1601/4416/4480, ip = flow endpoint}` |
| 写的是哪种路径 | **纯读**：全部经 `copy_from_kernel_nofault` 从内核 skb 读（`:595-630`）；结果存进本模块 per-cpu ring 的 `struct tup_rec`（`:1553-1557`），**不写任何用户 VA**。全文件 `copy_to_user|put_user|process_vm|ptrace` 零命中（仅 `:650` 一个 `is_user_va` 判定）。 |
| 目标 VA 是否别的进程 VA | **N** |
| 是否产生 32B 形状 | **只构造「形状」用于识别，不写出到用户内存** |

**判定**：**本项目里唯一一处与记录 w2 字段语义完全对应的「len(低32)+IPv4(高32)」构造点**，但它是调查仪器（钩 `wifi_tx/rx_tuple_add` 入口观测 `mtk_warp` 填充回调，`bmods/REVIEW-tuphook.md:1-10`），且 D19 窗 INVALID（`docs/review/WRITER_HUNT_GAP_AUDIT.md` §1.2③）。**它是「记录形状来自网络包元数据」这一学说的源码级佐证，但不是写者**。列为线索候选。

### C-8 私有仓 `authd/` 主守护 .c —— 唯一会 `inet_addr`+`memcpy` 构造 IP 的用户守护

> 命名说明：私有仓 `authd/` 下主守护源码文件名含私有标识，按公开仓中性命名纪律不转录；
> 本审计以 **`<authd>.c`** 代称，`file:line` 对该文件有效（持私有仓读权限者可按 `authd/` 下唯一主 .c 定位）。
> 同目录登录生成脚本以 `<login_gen>.py` 代称。

| 项 | 内容 |
|---|---|
| 文件:行 | `authd/<authd>.c:294` `uint32_t ip4 = inet_addr(g_ip);`；`:303`/`:307` `memcpy(identity+ul+5,&ip4,4)`；`:188`/`:246` `write(g_fd,f,n)`（原始数据帧、`AF_PACKET` 类发送） |
| 写的是哪种路径 | 用户态**本进程内** `memcpy` 组装 802.1X/登录帧，经 `write(g_fd)` 发到网络；**无 `process_vm_*`/`ptrace`/`O_RDWR /proc/*/mem`/`copy_to_user`**（全私有仓 6 个源码文件 grep 零命中）。 |
| 目标 VA 是否别的进程 VA | **N**（本进程堆/栈缓冲） |
| 是否产生 32B 形状 | **否**：写的是认证帧内嵌 4B IP（含于 identity 字段），不是 32B `{w1=0,w3=0,w2=len|ip<<32}`。 |

**判定**：私有上行认证插件（AGENTS 铁律 7：私有标识语义只准存在于私有仓），属认证客户端，写网络帧不写别的进程内存。**排除**。`plugin/plugins.js`、`plugin/install.py`、`authd/portal_auth.py`、`authd/<login_gen>.py` 同类零命中。

### C-9 `analysis/kern/kallsyms.txt` —— 厂商内核里「写用户 VA」的符号线索

| 项 | 内容 |
|---|---|
| 文件:行 | `kallsyms.txt:1171` `ptrace_access_vm`；`:1180` `ptrace_writedata`；`:1183` `generic_ptrace_pokedata`；`:1181` `__arm64_sys_ptrace`；`:8011` `get_user_pages_remote`；`:8130-8132` `__access_remote_vm`/`access_process_vm`/`access_remote_vm`；`:8429` `__arm64_sys_process_vm_writev`（另有 `:8428` compat 版）；`:12043-12045` `mem_rw.isra.0`/`mem_read`/`mem_write`；`:18142` `__arch_copy_to_user` @ `0xffffffc00843b680`；`:26015` `mtk_ccci_write_data`；`:25864` `ccci_ringbuf_write` |
| 写的是哪种路径 | ① `__arch_copy_to_user`(CPU uaccess，104 个 `_copy_to_user` constprop 克隆)；② `mem_write`→`access_remote_vm`/GUP(`get_user_pages_remote`)；③ `process_vm_writev`/`ptrace_writedata`；④ MD/CCCI 侧 `mtk_ccci_write_data`/`ccci_*` 写族（VERDICT.md:141,191 列为头号残余嫌疑）。 |
| 目标 VA 是否别的进程 VA | ①②③ 具备；④ 取决于私有驱动是否缓存用户 VA。 |
| 是否产生 32B 形状 | 符号表**不能判定内容**；`config-extracted.txt:422` `CONFIG_ARM64_PAN=y`、`:5508` `CONFIG_HARDENED_USERCOPY=y`、`:5930` `CONFIG_PANIC_ON_OOPS=y`、`:230` `USERFAULTFD=n`、`:586` `KPROBES=n` 为约束。 |

**判定**：仅为静态符号线索。设备实证已把 ①（`__arch_copy_to_user`，C-206/C-214）与 ptrace/process_vm 覆盖集（C-189）压到「已测未发现/边界内零」；**② `mem_write`/`access_remote_vm` 是 PHASE1_REVIEW:68 明确点名的未覆盖通道**；④ MD/CCCI 是 VERDICT 残余嫌疑。需上设备点名，本地不能定。

### C-10 其余 `copy_to_user` 站点（全部为「调用者自己的 ubuf」）

| 文件:行 | 语义 | 目标 VA | 形状 |
|---|---|---|---|
| `gw/src/healthdog.c:80` | `copy_from_user`（读） | N | — |
| `tools/oneoff/sigsegv/rxring.c:86` | proc_read 输出 ring 统计 | 调用者 own ubuf | 否 |
| `tools/oneoff/sigsegv/patrace.c:140` | proc_read 输出 pa 信息 | 调用者 own ubuf | 否 |
| `tools/oneoff/sigsegv/bmods/romap.c:263` | proc_read 输出页五元组 | 调用者 own ubuf | 否 |
| `tools/oneoff/sigsegv/bmods/rxcount.c:511` | proc_read 输出 rx 快照 | 调用者 own ubuf | 否 |
| `tmpfiles/an3/kread.c:28`、`tmpfiles/repro/dpscan*.c`、`buddyscan*.c` 等 ~20 处 | proc_read 输出扫描缓冲 | 调用者 own ubuf | 否 |
| `tmpfiles/an4/ktu.c:38`（`tmpfiles/repro/kmod/pte_redirect.c`、`fxhook.c` 等的 selftest） | 内核线程/工作队列 `copy_to_user` 正对照 | 借用 mm 的用户 VA（实验用） | 否（payload=0xAB 填充，`:63-64`） |

**判定**：全是 proc_read 或 selftest 语义，`dst = ubuf` 是发起读的进程自己的缓冲，**不指向第三方进程 VA**；`ktu.c` 仅证明「kthread 借用 mm 可写别人 VA」这一机制存在（`tmpfiles/an4/ktu.c:1-6`），非家族记录写者。全数排除。

### C-11 32B 记录形状的「构造点」全清单（均为测试/判据/注入，非生产写者）

| 文件:行 | 形状 | 用途 |
|---|---|---|
| `tools/oneoff/sigsegv/rectest.c:10` | `p[2]=0x0109a8c000000641ULL`（w1=w3=0） | **本进程自己 va_list** 注入，验证 nerepair 能救（头注释 `:1`） |
| `tools/oneoff/sigsegv/scanary_ro.c:1399` | `w[2]=0x0109a8c000000641ULL` | canary selftest 注入标记（`:1427` 另有负样本）；U-A2 冒烟臂观察到「写者复制注入标记」（U-A2_PULSE_RESULT §4.6） |
| `gw/src/slotguard.c:944` | `{0x0109a8c000000649ULL,0,0x1c949,0}` | 内建 selftest 的 B0A2 样本（`:943-960`），纯判定输入 |
| `tools/oneoff/sigsegv/bmods/funnel_selftest.c:18-25` | `{0x12345,0,0x680,0x9109a8c0,0,0}` | D23 漏斗正对照（经 pipe→`copy_page_to_iter`→`__arch_copy_to_user`） |
| `tools/oneoff/sigsegv/bmods/funnelv2_selftest.c:59-61` | `put_record()`/`put_core16()` | D27 正对照 payload |
| `tools/oneoff/sigsegv/nerepair_mode0_test.c:62` | `0x400 + rnd()%...` | host 判据回归 |
| `tools/labkernel/scripts/lab_init_*.sh`（`tools/VERSIONS.tsv` 记「scanary w1 预注册自启」） | lab canary 自启 | 台架 |

**判定**：全部是**本进程自注入 / 正对照 / 判据输入**，没有一处把该形状「写向另一个进程的地址空间」。
`0x0109a8c0` 是 `192.168.9.1` 的大端十进制（LAN 网关地址，`gw/boot_gate.sh:78`、`gw/src/v3httpd.c:51` 等大量出现，均为配置/绑定/IP 文本，**非写内存**）。
`0x641`=1601、`0x649`=1609、`0x680`=1664 是实测包长（nerepair 注释 `gw/src/nerepair.c:296-297`：「observed real lens 1601/1664/57497..72085」）。
⇒ **本地源码里不存在「构造 32B 家族形状并写向别的进程 VA」的生产代码。**

---

## ② 明确排除的（附理由）

| # | 对象 | 排除理由（带 file:line） |
|---|---|---|
| E-1 | 全 `gw/**` 的 .sh/.js | 无任何跨进程写原语；唯二 `/proc/*/mem` 出现是注释（`gw/core_meta.sh:29,135`）与只读消费者（`gw/src/stackdump.c:142` `open(O_RDONLY)`+`pread`，`gw/src/slotguard.c:404-415` 读路径）。`dd` 读见 `tools/oneoff/sigsegv/d10/d10_slotwatch.sh:17`（`dd if=/proc/$P/mem`，只读 32B 计数）。 |
| E-2 | 全 `gw/src/*.c` 的 `copy_to_user`/`put_user`/`sttr`/`iov_iter`/`process_vm_writev`/`PTRACE_POKEDATA` | **零命中**（`grep` 全表：`gw/src/` 仅 `healthdog.c:80` 一个 `copy_from_user`，其余 C 文件的写均为本进程缓冲或内核 skb）。`gw/src/logc.c:834-886` 的 `memcpy` 是日志环形缓冲内核/本进程写，`gw/src/wpapmk.c` 是 SHA1 上下文，均与跨进程无关。 |
| E-3 | 私有仓 `authd/`+`plugin/` 全部 6 个源码文件 | `process_vm\|ptrace\|PTRACE_POKE\|O_RDWR.*proc\|pwrite\|access_remote_vm\|mem_write\|copy_to_user` **全零命中**；`authd/<authd>.c:294,303,307` 的 IP 构造只进本进程认证帧（`:188,246` `write(g_fd)`）。 |
| E-4 | 「用户态 ptrace 型第三方跨进程写」 | `gw/src/nerepair.c:987` `PTRACE_ATTACH` 是**全进程独占 tracer**（`docs/review/WRITER_HUNT_PHASE1_REVIEW.md:65-68` §4-1 结构性关闭；C-189 `01_CLAIMS.tsv:180`）。 |
| E-5 | `__arch_copy_to_user` 携带家族内容 | 设备实证：D23 漏斗 28.96M 调用族内容 0（`01_CLAIMS.tsv:197` C-206）、D27 宽扫描判据不能闭合（`:205` C-214）、mt_wifi 12 站点全观测（`:194` C-203）；U-B1 fxhook 219 s `calls=0` 再排除 ex_table/uaccess-fixup（`docs/review/U-B1_FXHOOK_RESULT_2026-11-04.md:29,92`）。 |
| E-6 | DMA / 总线主写 | U-A2 脉冲实验正面拒绝（`U-A2_PULSE_RESULT_2026-11-04.md:10,86`）；`bmods/dmahook.c:5-8` 的 DMA 学说已被后续实验改判。 |
| E-7 | 内核 `copy_to_user` 的常规 proc_read / selftest 面 | 见 C-10、C-11；`dst=ubuf` 是调用者自身缓冲；`probe_selftest.c:38,62`/`ktu.c:38` 是显式正对照，非常驻。 |
| E-8 | `process_vm_readv` 读取方（`gw/src/nerepair.c:279`、`tools/oneoff/sigsegv/ipdump.c:71`） | 只读；`ipdump.c:1-12` 头注释自陈 "read-only ptrace observation"。 |

---

## ③ 最可疑 Top-3 + 可直接上设备的验证建议

> 说明：本地源码**无法点名写者**（见 ④）。Top-3 按「是否真的会写别的进程 VA」+「是否与未覆盖通道吻合」+「是否仍在运行」排序，
> 不是「谁最像记录生产者」——因为**仓内没有任何代码生产该形状并写向别人**，写者极可能是**厂商内核/私有驱动或某个未入库的常驻实体**。

### Top-1：`/proc/<pid>/mem` → `mem_write` → `access_remote_vm`（GUP/FOLL_WRITE）通道
- **理由**：这是 **PHASE1_REVIEW:68 亲笔点名的「真正未覆盖」通道**——不经 `__arch_copy_to_user`（D23/D27 漏斗看不见）、
  不经 ptrace（A2 audit 掩码 `{270,271,117}` 看不见，`auditwatch/README.md:9-12`）、`audit` 无法用路径 watch 稳定命中 procfs。
  它天然满足 U-A2/U-B1 全部约束：走 CPU/MMU（PTE 门控✓）、不进 `fixup_exception`（✓，GUP 写不是 uaccess fixup）、
  需要目标进程「活着且有可写页」（与「受害者运行态」约束同向）。
  **仓内唯一走这条路径的常驻代码是 `gw/src/slotguard.c:425-428`（C-1）**，虽其写出值非家族形状、且当前零写。
- **上设备验证建议（只读为主，零/低风险）**：
  1. **先证伪我们自己的常驻件**：`deploy.py doctor` + 设备上只读核 `ls -l /data/gw/slotguard.arm`、`grep MODE /data/gw/logs/slotguard.log`、
     `cat /proc/$(pidof slotguard)/stat`（S 态）、`wc -l` 台账确认 `g_wrote=0`。C-1 若为真写者，其日志必有 `SANITIZE`/`WRITE_MISMATCH` 行（`gw/src/slotguard.c:770-773`）——与 48/min 命中率对账即可当场排除/确认。
  2. **补 A2 覆盖盲区**：重开 `auditwatch` 规则，把 `syscall` 掩码扩到 **`openat`/`write`/`pwrite64` + 路径含 `/proc/` 且含 `/mem`**，
     或按 `WRITER_HUNT_PHASE1_REVIEW.md:71` ② 做零成本能力自检：自建 helper 向受害进程写 magic，看现有观测能否看见（看不见 ⇒ 缺口由猜测升级为实测 E3）。
  3. **入口钩子（1–2 人日，需 LK 救砖兜底 + skeptic 签字）**：按 `PHASE1_REVIEW:71` ③ 钩 `mem_rw`/`access_remote_vm`
     （`kallsyms.txt:12043,8130`，`mem_write@0xffffffc0082f0b30`），记录 `pid/comm/目标 VA/长度/写内容前 32B/LR`；
     与 U-A2 脉冲臂对齐，`RO` 段若出现「非 victim 的 GUP 写」即当场点名。
  4. 参考 U-B1 §6 的 **T-03 romap** 作为并行判别：内核普通 store 会吃 data abort 点名，用户态/GUP 写不受影响。

### Top-2：厂商内核态「按当前帧定位、非 uaccess」的私有驱动 / MD-CCCI 侧
- **理由**：`VERDICT.md:141-142,191` 收束版点名的头号残余；`kallsyms.txt:26015` `mtk_ccci_write_data`、
  `:25864` `ccci_ringbuf_write`、`:53fxxx-58xxxx` 大量 `ccci/md_*` 写族符号；`bmods/REVIEW-wdkill.md`/
  `REVIEW-wdone.md` 记录 `mt_wifi` 的 168 个 `copy_to_user` 包装调用「dst 取自常驻描述符 {buf@+0x10,out_len@+0x18}
  （可陈旧）」（`wdkill.c:5-8`、`wdone.c:5`）——即「缓存用户 VA 后再写」的同类机制。
  D28 lab 极简内核零写入（`VERDICT.md:189`）把嫌疑收窄到厂商内核态环境。
- **上设备验证建议**：① B4 风格遮罩矩阵（`WRITER_HUNT_GAP_AUDIT.md` §1.1 B4）对 `md/`+CCCI+未遮罩 .ko 做集合级消融；
  ② 内核 `sttr`/inline `put_user` 站点普查（kallsyms 有 104 个 `_copy_to_user` constprop 克隆，`VERDICT.md:145` 自陈 393 个用户写站点未解析）；
  ③ `tuphook.c:630` 已证 `len|ip<<32` 来自 skb，沿 `wifi_*_tuple_add` 填充回调的 `ops+0x18/0x50` 链（`bmods/REVIEW-tuphook.md` §0-3）追「谁把 skb 元数据写进常驻描述符」。

### Top-3：未入库 / 长期驻留的用户态实体（nerepair 独占 tracer 之前就存在的守护）
- **理由**：U-B1 最优解释是**用户态写者、权限感知式写入**（`U-B1_FXHOOK_RESULT:29,92`）；C-189 的覆盖边界是
  「只覆盖 audit-on **之后 fork** 的进程，长驻守护不可见」（`01_CLAIMS.tsv:180`）；`WRITER_HUNT_GAP_AUDIT.md` §1.4
  把「长驻 daemon 的跨进程写」列为从未被有效检验。U-A2 冒烟臂还观察到「写者复制注入标记」（`U-A2_PULSE_RESULT` §4.6），
  行为学上像读-改-写的用户态实体。
- **上设备验证建议**：① 在**开机早期**（nerepair 起来前、或 `kill -STOP` 其 tracer 的空窗）装 audit 规则，
  覆盖全部长驻守护的 `process_vm_writev`/`ptrace`/`mem` 通道；② 用 `svc_lib.sh` 的「argv token 精确 + 全量集合」判据
  枚举所有常驻进程的 `/proc/<pid>/mem` fd 与 `TracerPid`，找「持有别的进程 mem fd」者（纯 `/proc` 只读）；
  ③ 复用 `d10_slotwatch.sh:17` 的只读 32B 槽轮询，对「记录出现时刻」与「各守护 cpu/utime 增量」做同一锚点（`date +%s`）时间轴对齐。

---

## ④ 一句总判决

**本地源码不能点名写者**：全项目（含私有认证插件）**不存在任何「构造 32B 家族形状 `{w1=0,w3=0,w2=len|ip<<32}` 并写向另一个用户进程地址空间」的生产代码**——
所有该形状的构造点（`rectest.c:10`、`scanary_ro.c:1399`、`slotguard.c:944`、`funnel*_selftest.c`）都是自注入/正对照/判据输入，
所有跨进程写站点（`slotguard.c:428`、`vmpoke.c:135,152`、`vmwrite32.c:18`、`probe_selftest.c:38,62`）写出的内容都不是家族形状且非常驻或当前零写；
结合设备侧已排除 CPU uaccess / ptrace / DMA（`VERDICT.md:188`、`U-B1_FXHOOK_RESULT:29`、`U-A2_PULSE_RESULT:10`），
写者必在**厂商内核/私有驱动或未入库长驻实体**中，本地静态审计只能把嫌疑收窄到 **`/proc/<pid>/mem→access_remote_vm`（Top-1，PHASE1_REVIEW:68 亲笔未覆盖通道）**、
**MD/CCCI 类「缓存用户 VA 再写」私有驱动**（Top-2）、**audit 覆盖盲区内的长驻用户态进程**（Top-3），最终点名必须上设备按 ③ 验证。

---

## 附：审计覆盖与口径边界（诚实清单）

- **只读合规**：全程 `grep`/`cat`/`sed`/`Read`，无 `deploy.py`、无 SSH、无设备会话、无源码改动；本报告本身是唯一新增文件。
- **未深挖**：`analysis/kern/{vmlinux.elf,ktext.bin,kdata.bin}` 二进制未做反汇编（任务书允许「列线索即可」）；
  `_local/legacy/linux-5.15.134` 上游内核树只作机制参照（其 `mm/process_vm_access.c:298`、`fs/proc/base.c:868`、
  `mm/memory.c:5171-5249` 等为标准内核路径，非本项目代码）；`tmpfiles/`、`_local/` 为本地运行期/归档区，非部署资产。
- **私有仓口径**：`authd/`+`plugin/` 源码按任务书本地可读，结论仅写「有无跨进程写原语」，不转述任何认证机制细节（遵守公开仓中性命名门禁 `tools/leak_check.py:33`）。
- **边界**：C-206/C-214/C-189/C-203 的设备结论按「已测未发现 / 覆盖有界」引用，不升级为「物理排除」
  （`WRITER_HUNT_GAP_AUDIT.md` §2 三类偷换）；`slotguard` 当前零写结论依赖 `docs/review/README.md:20` 与
  `SKEPTIC_ARMED_WINDOW.md:19,80` 的实测锚点，若设备态已变需以设备只读复核为准。
