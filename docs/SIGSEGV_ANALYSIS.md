# logread SIGSEGV 家族：取证+逆向结论（2026-10-19 起；**2026-10-22 复核**）

> 本文是 [INCIDENT_2026-10-19.md](INCIDENT_2026-10-19.md) §2 的续篇与深度闭环：
> 对三份 logread core、libc.so、logread.bin 的完整逆向，加上设备侧补充取证。
> 取证脚本与产物在本地 `tmpfiles/sigsegv_re/`（不入仓）。

## 0.0 复核记录（2026-10-22 12:05–12:25 CST · **先读这节**）

> 本轮只做一件事：把全文结论逐条拿回证据上重算。三路并行——
> ① 用 `tmpfiles/` 的 core、反汇编、归档日志重算指针与数字；
> ② 用设备**只读**命令核对设备侧断言（`ap_auto_logging`/`log_size`/aee 台账/
> `/data/p0x/harvest.log`/cores 目录）；
> ③ 交叉检查文档内部一致性（同一数字在不同节的差异、旧结论是否已标废止）。
> 本轮**没有写设备、没有重跑崩溃实验**；新增产物只有本节与文末证据索引。
>
> **结论：§16/§17 的主机制经受住复核**——外部主控把 16/32B 记录写进被回收
> 复用进用户进程的物理页。三条 logread core 的崩溃点/寄存器、pageharvest 的
> 活捉原文、内核 stop 路径的顺序，都复算一致。**但支撑它的若干具体论据有错**：
> 其中 §2.4 的"帧失步现场"是**读错栈偏移造成的假现场**，必须撤回；§14 的普查
> 把 3 条非崩溃和 1 条自测计进了总数，速率偏高。下文被改动的段落都带 `⟦复核⟧`。

### 0.0.1 复核后仍然成立的结论（已复算）

| 结论 | 复核方式 | 结果 |
|---|---|---|
| 三份 logread core 同签名：pc=libc+0x51ffc、`ldr x0,[x3]`、si_addr=0x2475b/0x25746/0x14f1b、x5=0x0ccccccc、x7=-10 | `core_an.py` 重跑 | 全部一致 |
| 两个爆发点格式串：logread+0x3d0e `"%s %s%s.%s%s %s\n"`、libc+0x7a068 `"%.3s %.3s%3d %.2d:%.2d:%.2d %d\n"` | 文件内字符串偏移 + core 的 x26 反推 libc base | 一致 |
| 32B 坏块 = `{small,0,const,0}`，同页可多块 | 三份 core 栈扫描 | 一致（core_3053 的 `0x1365fe9b0000062d` 在 sp+0x188/sp+0x310；core_27987 的 `0xa4e8817b00000631` 同样两处） |
| pageharvest 活捉外部写入 | `/data/p0x/harvest.log` 原文 | 一致（cyc=72 `HIT addr=…fc0`、`{0x9d9d,0}`×4、netdelta=70459；后续 0x36d1b/0x20849/0x29d9d） |
| 外部写入者向用户持有的页写 16B 记录 | §19 自写探针（injwatch/injwatch3） | **独立复现**（16 次页尾 0xfc0 命中；0xAA 被覆盖；memset 后立即对照也命中） |
| dpmaif stop 先归还页、不写 PIT 基址寄存器、有界轮询 0x186a0/0x180000 | `kern_an.py` 反汇编 | 一致；并补出：归还页之后还有一个**无超时**的 medmcu ack `msleep` 循环 |
| `ap_auto_logging=0`、`log_size=10240` | 设备只读 | 一致 |
| 固定地址金丝雀/memtruth 0 命中 | `/data/p0x/*.log` 原文 | 一致（ro/stk/mix_ro/mix_stk/mm/alias/bss 全部 `hits=0`） |
| 写入者 = 蜂窝 MD/DPMAIF 环 | §21 环描述符 + 内容形状 | **已坐实**（命中页 PA 在 dpmaif 16B/32B 环；内容是环记录，非以太网帧） |

### 0.0.2 修正清单（按严重度）

**A. 事实错误（会改变读者对机制的理解）**

| # | 位置 | 原文（错） | 复核结果（对） | 证据 |
|---|---|---|---|---|
| C1 | §2.1/§2.4 | "无外层 wrapper"；"tb[0..2] 指向缓冲外 50KB+，tb[3]=0x6ad527e0 裸整数"；"blobmsg_parse 游走越界" | 记录**有** 4B wrapper（id=0，len）；属性序是 `msg,id,priority,source,time`；core_3053 的真实 tb 五项**全部有效且在缓冲内**：`0x7facbe84bc(msg)/850c(id)/851c(priority)/8530(source)/8544(time)`。原文五个值读自 **sp+0x50**（保存的 x25 + 未初始化槽），正确位置是 **sp+0x70**，整体错位 0x20。另外 `0x6ad527e0` = **2026-10-19 04:11:12**，正是该记录 time 的秒值（print_log 的局部变量 x25），不是"伪属性" | `logread.c` 的 `log_notify`；`logread.bin` 0x403390 反汇编（`add x2,sp,#0x70` + 5 次 `cbz`）；core_3053 内存 0x7facbe84bc 起的属性头 |
| C2 | §2.3 | "5 槽位仅查非空，无类型/范围校验" | 反汇编 0x4033f4–0x403418 对 tb[1..4]、tb[0] **逐个判空**；`blobmsg_parse` 按 policy 的 type 过滤。真实缺陷只剩"长度字段无上界、无跨属性一致性校验"（read_cb 仅比较 `blob_len+4` 与 avail），且在这三份 core 里**未被触发** | 同上 |
| C3 | §2.3 | `pid = blobmsg_get_u32(tb[3]) # id` | tb[3] 是 **source**；id 是 tb[1]，FILE 路径只判空、不读取 | `logread.c` 的 enum 顺序 + 反汇编 |
| C4 | §1 | "`__gr_offs=0 __vr_offs=0` 幸存 → 证明污染发生在 printf 处理过程中" | 32B 块是**整条注入记录** `{small,0,const,0}`，offs=0 是记录的第 4 个字段，不是"已弹 5 个"的幸存证据。时间窗只能由 **si_addr=__stack** 推出（前 5 弹若用 gr_top=0 会在 -40 处崩，而不是 0x2475b）。块位于 **sp+0x178**（三份 core 一致），不是 sp+0x58 | 三份 core 的栈内存 + pop_arg 反汇编 |
| C5 | §10.3 | "ap2 … `__gr_offs=-40`，尚未弹过变参" | `crash.72.log` 原文是 **-32**；故障地址 -40 与"弹出宽度参数（`*`）时"一致。gdb 打印的 ap2 与实际使用的副本可能不是同一份（§13.1 的 `&ap` 物化问题），应注明 | `_local/archive/.../events/crash.72.log:71` |
| C6 | §13.2 #6 | "第一个变坏的检查点是 after_va_copy → **坏源在调用方**" | 只能证明"到 after_va_copy 时已坏"，不能证明"进 vfprintf 时已坏"。`crash.72.log` 反证：调用方 `snprintf` 的 ap 健康（stack/gr_top 都是栈地址、gr_offs=-40），坏的只是 vfprintf 里的 ap2 | `crash.72.log:71/85` |
| C7 | §13.2 #9 | 污染率 7.5e-8 / 7.3e-8（单点） | `ab.log` 三组：15/2e8=7.5e-8、**101/2e8=5.1e-7**、**60/2e8=3.0e-7**；`rec.log` 22/3e8=7.3e-8。速率随剧集变化约 7 倍，应给区间 **0.7–5e-7** | `p0devices/ab.log` |
| C8 | §13.3 | 硬化补丁"彻底消除崩溃"、"代价是 1e-8 量级的错误数字" | guard 的 `__gr_offs<0 && __vr_offs<0` 对"已用尽 8 个通用寄存器"的**合法** va_list（gr_offs=0）会误判 → 第 9 个及以后的参数被写成 0。pop_arg 反汇编（0x51e8c–0x51ec8）证明 gr_offs=0 走 `__stack` 是正常路径。它是**拦截**不是消除，代价是"长参数列表的后续参数全变 0"，不是 1e-8 的错误数字 | `libc.so` 0x51e8c 反汇编；`layerchk_h_vfprintf.c:30-33` |

**B. 口径与表述（数字/结论强度）**

| # | 位置 | 原文（错/过强） | 复核结果（对） | 证据 |
|---|---|---|---|---|
| C9 | §14 | 窗口 69 次 = 46.9/d；awk 修复后 28.5/d | 69 行 = **3 条非崩溃（`?`）+ 1 条自测（`busybox sh -c kill -SEGV $$`）+ 65 次产品崩溃**。速率 **65/35.3h=44.2/d**；awk 修复后 **38/35.3h=25.8/d**。aee 同窗只有 63 条 = TSV − 5（3 条 `?` + 15:20 的 awk + 18:09 的 pidof）→ **aee 漏了 2 条真实产品崩溃**，它不是超集，也不能替代 TSV | `ne_events_full.tsv` + 设备 `db_history`（按分钟对齐） |
| C10 | §11.1 | "75 次"，表列 11 行 | 表列合计 **73**，正文 75；差额是 2 条 busybox（1 条自测 + 1 条 `led_mgr.sh`）。75 的口径已排除 21:04–21:15 的 **13 条 awk 复现崩溃**（aee 把它们记在 busybox 名下，计数 13） | TSV + aee 的 module count 表 |
| C11 | §14/§16.4 | "A 类覆盖 ≈40/47"；"logread 45% 占比" | 旧 A 类口径已并入主机制，40/47 不再有意义；按组件口径 awk 27/65、ip 17/65、logread **1/65=1.5%**。45% 无出处（早期 dmesg 15 条里 logread 13 条=87%，是另一种口径），不能用来支持"printf 选集" | §14 重算 + §15.1 |
| C12 | §16.2 E1/E4 | "注入源的**准静态 64 位值**"（低 16 位缓慢变化） | 同一 64 位值 `0x1c28416e00000680` 确实在 6 处出现（core_15875、crash.72、sh.core、sh2 的 …1180、p6.log、layer.txt），但**高 32 位在现场间变化**：0x1365fe9b（core_3053）、0xa4e8817b（core_27987）、0x0998010a（rec.log）。不变量是 **16B 块形状 + 低 32 位的 0x6xx/0x1180 族**，不是"同一个 64 位常量" | 三份 core + `rec.log`/`p6.log`/`layer.txt` |
| C13 | §16.2 E7 | "产品崩溃率 ~6/h，为日内基线 ~2/h 的 3 倍" | ⟦复核⟧ "~6/h"**成立**（23:31–00:16 的产品段是 sed/awk/wc/grep 4 条 ≈5.3/h；23:31 起的其余 aee 事件是 P0 探针，须扣除）。但"基线 ~2/h、3 倍"只是某个窗口的值：10-20 白天约 **3/h**、10-21 凌晨–傍晚约 **0.6/h** → 倍数 **2–9×**，应写区间 | 设备 `db_history` + TSV 按分钟对齐 |
| C14 | §16.2 E8 | "logc v1.3 每次 spawn ~3.5% 崩溃率" | 与 §10.2 的 1/220–1/600（0.17–0.45%）矛盾；按 109 次/43h、log_keeper 30s 轮次折算约 2%，与单次率不是同一口径。改为"**单次全环读取 0.2–0.5%（实测），轮次口径 ~2%**" | §10.2 + 设备 `logc_crash/`=133 |
| C15 | §17.2 #2 | "坏值低 16 位 0x680 **正是** BAT 环计数" | 0x680/0x780 确是 `dpmaif_bat_init` 的两个 count；但受害者低 32 位是 0x62d/0x631/0x680/0x1180，**后三者在内核文本里只出现在 ext4/Si3217x/无关驱动，dpmaif 不用** → 0x680 是**单样本巧合**，该字段更像长度/序号（1500–1700B 的典型段长）。定罪仍成立（stop 路径 + 回收页 + 活捉），但不靠这个常数 | `kern_an.py` 全文 movz 扫描 |
| C16 | §17.2 #6 | "数据段 0xffffffc0090e93f0 表还原 {start,pre_stop,stop,syssuspend,sysresume}" | 0x…93f0 是 **dpmaif netdev_ops**（give_more/write_room/start_queue/stop_queue/dump_status）。ccci ops 表在 **0xffffffc0090e9440**：[+0]=dpmaif_start、[+8]=dpmaif_pre_stop、[+0x10]=dpmaif_stop、[+0x18]=dpmaif_debug、[+0x70]=dpmaif_syssuspend、[+0x78]=dpmaif_sysresume | `kdata.bin` 指针表 + kallsyms |
| C17 | §17.2 #4 | 拆卸顺序到 stop_rx_sw 为止 | 补全：…→ stop_rx_sw（**归还页**）→ del_timer → notify → **然后**才 `msleep(1)` 等 `[dev+0x404]==1` 的 medmcu ack，且该循环**无超时上限**。即"页已归还、ack 还没等到"——这正是 leak-on-timeout 的落点 | `dpmaif_stop` 反汇编 0x38a4/0x390c |
| C18 | §17.1 | 熵 7.965；数据段 3.6MB | 熵 **7.973**；`Kernel data 0xfe6d0000–0xfea4ffff` = **3.5MiB** | `kernel_payload.bin` 直算 + `iomem.txt` |
| C19 | §5.1 | "aee 为追加式（171 行无回卷），首条 10-05 20:28 … 官方时代零 NE" | 现 **296 条**；首条 10-05 12:28:14 **UTC**=20:28 CST ✓。但第 43–44 行有两条 **Sep 9** 记录，夹在 10-17/10-18 之间，对应槽位当前内容是 10-22 的崩溃 → 更像**槽位复用/陈旧报告**，不是官方时代真实崩溃。改为"未发现可信的官方时代 NE；两条 Sep 9 记录待查" | 设备 `db_history` + `db.06.NE/ZZ_INTERNAL` |
| C20 | §7/§9/§16.7 | "静态链接 = 本条崩溃路径物理消失"；§9.1 版本表 | 已被 §16.7 推翻（静态件同样中招）。§9.1 是 10-19 快照，现行版本已前进（watchdog 1.30、rc.extend 2.6、core_trap 1.2、selftest 2.58、deploy 2.26）。`logc.c` 头注释与 VERSIONS.tsv 的部分描述仍写着旧的"帧失步/musl 缺陷"叙事，以本文 §16/§17 为准 | `tools/VERSIONS.tsv` |
| C21 | §9.2 | "清环后 logread 的 1% 崩溃率对 logc 不再适用（无 ctime/asctime_r 调用）" | 只在当时那 240 次成立：logc v1.0–v1.3 仍走 printf，随后崩了 **109 次**（§10.1），v1.4 去 printf 才归零。**不要引用"logc 不受影响"** | §10.1 + 设备 `logc_crash/`=133 |

### 0.0.3 复核后的数字速查（替代 §14 的派生口径）

| 口径 | 旧值 | 复核值 |
|---|---|---|
| 干净窗口 | 10-20 08:16 → 10-21 19:34（35.3h） | 同窗口按 **19:35** 取整（含 19:34:53 的 pidof），35.3h |
| 事件行 | 69 | 69 行 = **65 次产品崩溃** + 3 条 `?`（非崩溃）+ 1 条自测 |
| 总速率 | 46.9/d | **44.2/d** |
| awk 修复后基线 | 28.5/d | **25.8/d**（38 次/35.3h） |
| aee 同窗 | 未列 | **63 条**（= TSV − 5；漏了 2 条真实产品崩溃） |
| 同值现场 | "≥6 个独立崩溃现场" | **6 处出现 / 4 个独立进程-构建**（vendor musl logread、GCC busybox sh ×2、zig logc、zig probe） |
| 剧集倍数 | 3× | **2–9×**（取决于基线窗口：0.6–3/h） |

### 0.0.4 本轮**未**复核 / 仅设备侧、未归档的断言

- §10.1 的"132 份面包屑 = 109 次崩溃"、§9 的"selftest 87 pass"、§11.5 的逐字节等价样本
  （484783 B / 498854 B）、§17.3 的 `kpagecount>1` 验证——本地无对应产物，本轮只核对了
  设备上的计数（`logc_crash/`=133）与 harvest 原文，**不重新背书**其细节。
  ⟦复核⟧ 注入事实本身已在 §19 用独立仪器复现；未复现的是"写入者身份"（PFN/kpagecount）。
- §16.2 E7 的 `[ccci1/chr]write error done on ttyCMIPC11, l=16` 只见于正文，本地
  归档里没有该 dmesg 行；本轮未在设备上重抓。§21 已用环描述符/内容证据坐实 dpmaif，
  该 dmesg 行不再是必要条件。
- §5 的"官方时代约 4 周零 NE"依赖 C19 的台账解读，仍需一次官方镜像对照才能定案。

### 0.0.5 复核方法与可复现命令（PC 侧，全部只读）

```sh
python tmpfiles/sigsegv_re/core_an.py tmpfiles/core_27987.bin tmpfiles/core_3053.bin tmpfiles/core_15875.bin
python tmpfiles/p0x/kern/kern_an.py dpmaif_bat_init.constprop.0 dpmaif_stop dpmaif_stop_hw dpmaif_stop_rx_sw
# 反汇编 print_log / read_cb / pop_arg：见本节 C1/C2/C8 的偏移
# 普查重算：按 exe 前缀与 args 过滤 /tmp/pf_*、/tmp/v_*、/data/p0/*、"busybox awk"、"kill -SEGV"
```

设备侧只读命令：`date/uptime`、`uci get system.@system[0].ap_auto_logging|log_size`、
`wc -l /data/log/aee_exp/db_history`、`tail /data/p0x/harvest.log`、`cat /data/gw/logs/cores/meta/*`、
`ls /data/gw/logs/logc_crash`。**未执行任何写操作、未重启设备。**

## 0. 摘要（2026-10-19 现场推理链 · **历史摘要**）

> 本节是 2026-10-19 当天的推理链，保留以记录过程。其中**三处**已被后续实验/复核推翻：
> ① "破坏需要垃圾数据/年份溢出作为前提" —— 最小复现器在**没有任何垃圾数据**时
> 也 2 秒必崩（§12.4）；② "va_list 三个字段被垃圾小整数覆盖"的机制细节已由 §13
> 的 16 字节零块实测取代；③ **"帧失步 → 伪属性"整条链已被 §2.4 复核撤回**
> （tb 读错栈偏移 0x20；`0x6ad527e0` 其实是该记录 time 的秒值，来自局部变量 x25）。
> **现行结论以 §0.5 与 §16/§17 为准**，本节仅作历史。

```
[实锤] logread 对 logd 记录流的"帧同步"仅凭属性长度字段自查（read_cb），
        无任何兜底校验
   → [实锤] 一旦错位，blobmsg_parse 的属性游走越出 16KB 输入缓冲，
        在相邻库映射里按名字"匹配"出伪属性（tb[] 里出现 libc/libubox 指针
        和裸整数 0x6ad527e0 —— 一个 2026-10-17 的 Unix 秒级时间戳）
   → [实锤] tb[TIME] 槽位拿到 msg 属性 → blobmsg_get_u64 把消息正文字节
        （"thermal_"）按 BE64 读出 → t = 巨大但在 musl localtime 接受范围内
   → [实锤] ctime(t) → asctime_r 的 snprintf(buf, 26, "%.3s %.3s%3d
        %.2d:%.2d:%.2d %d\n", ...) 年份溢出 26 字节（输出 30+ 字节）
   → [实锤] 厂商 musl 的受限输出 vfprintf 路径在此条件下破坏自身栈帧：
        活动 va_list 的 __stack/__gr_top/__vr_top 三个字段被垃圾小整数覆盖
        （gr_offs/vr_offs 幸存 = 前 5 个寄存器变参已正确弹出）
   → [实锤] 第 6 个变参从 va_list.__stack 弹出 → 解引用 0x2475b 级别的
        小整数野指针 → SIGSEGV（libc+0x51ffc，pop_arg 序列）
```

> ⟦复核⟧ 上面这段"一句话"**整段作废**：没有"记录帧同步缺陷产出垃圾数据"，
> 也没有"libc 破坏自己的栈"（§2.4、§16）。现行表述是：**外部主控把 16/32B
> 记录写进被回收复用进用户进程的物理页；printf 只是最高频的解引用路径。**
> watchdog 拉起仍然只是止痛；根治在页回收链（§16.6/§17.5），"换采集器 +
> 静态工具"是缓解（§16.7）。

## 0.5 速查：机制总表与引用规则（**唯一事实源**）

> **文档定位（2026-10-22 收关确立，复核轮补充）**
> 1. 本文件是"崩溃/SIGSEGV 机制"的**唯一事实源**：机制、判据、速率、证据锚点只在这里写。
> 2. 其他文档（事故留档、稳定性分析、方案可行性、FINDINGS、ARCHITECTURE 版本表）
>    只写"发生了什么/做了什么/为什么有这个版本"，机制一律**引用本文**，不再复述。
> 3. 历史文档里旧的机制描述已在本轮删除；**git 历史中的旧结论不是现行结论**
>    （见本节"已更正的旧结论"）。改动机制时只改本文件。
> 4. **阅读顺序**：§0.0（2026-10-22 复核记录，含修正清单）→ 本节（机制总表/判据）
>    → §16/§17/§21（机制、定罪、写入者定位）→ 其余按需。§1–§15 是历史现场，已标废止处不要引用。
> 5. **修复处置**（保留/冻结/退役/主线）只看 §22；别再问"哪条修复是根因"——
>    本轮 gw 侧没有根因修复，主线在内核（§23）。

### 机制总表（一页版，2026-10-22 收官轮改写）

> **2026-10-22 反转**：此前归为"A 类 = musl printf/stdio va_list 缺陷"的定性已被推翻
> （§16）：musl 与全部被替换组件都是**无辜受害者**。全家族（含原 B/C/D 类）的
> 共同根因是**外部主控把 16/32 字节记录写进被回收复用进用户进程的物理页**；
> printf 家族只是"最高频解引用被污染内存的路径"，因而成为最常见的爆发点。

| 类 | 机制（一句话） | 状态 | 速率/量级 | 锚点 |
|---|---|---|---|---|
| **主机制（合并原 A/B/C）** | 外部主控（蜂窝 MD/ccci-dpmaif 环，含 medmcu）经失效环形缓冲指针，把 16/32B `{计数器,0[,0x680族,0]}` 环记录写进**被回收复用进用户进程的物理页**；受害者按被击中数据的形状表现出 va_list 崩溃 / NULL 解引用 / .bss 指针损坏等不同签名 | **机制级定罪 + 活体捕获 + 描述符级定位（§21）**：命中页 PA 在 dpmaif 16B BAT/PIT 环与 32B 影子数组里（DONE=0、PLEN0=4096），内容是环记录 | 剧集期：pfcanary ≤2s 必崩；平静期：0；产品面 **44→26 次/天**（core_meta 口径，§14 复核） | §16、§17、§21 |
| ↳ 原 A（logread/logc/sh/grep/pidof/ls/ping/wc/sed…） | 同主机制；musl `pop_arg` 是最高频的污染内存解引用点 → 选集效应让它"看起来"是 libc 缺陷 | 机制已反转；热路径缓解（logc v1.4/logcut/procmatch 去 printf 化）有效保留 | 旧口径 ≈40/天（**已作废**；按组件口径见 §14） | §16.4 |
| ↳ 原 B（awk） | 同主机制（NULL 块击中节点指针即可解释）；"busybox awk 数组退出缺陷"**不再必要**且未被独立证明 | 并入主机制；logcut 缓解有效 | 修前 18.4/天 → 0 | §11、§16.3 |
| ↳ 原 C（ip `filter.label`） | 同主机制：`.bss` 一页内 5 个 16B 块以 16 字节节距喷射（flags/label/flushb/slave_kind…），label 恰好被解引用 | **已闭环并入主机制**（core_ip.core 整页实测） | 11.6/天 | §11.7、§16.3 |
| **D. hostapd/logd/thermal_core（厂商件）** | 同主机制的长期受害者（剧集期新分配页被注入）；不可重编，只能靠根修（§16.6 选项 B/C 才能覆盖它们） | 归并；根修前靠恢复 | 1.4/天 + 零星 | §16.6 |
| **E. `?` 组** | **不是崩溃**：core_meta 的手工/测试调用 | 排除 | — | §12.1 |
| 背景率 | 与程序无关的随机崩溃**未观测到**；固定地址观测在平静期恒为 0 | 已排除（30 万金丝雀 + §16.1 memtruth 电池；⟦复核⟧ 0 命中只给上界，不是"全时段不存在"的证明） | — | §12.2、§16.1 |
| 普查口径 | 家族计数会被取证自身污染（探针/复现也算） | 判读时须扣除 | — | §13.6、§14 |

### 判据（照抄使用，别自己发明）

- va_list **是否健康**看结构：三个指针字段落在用户态可访问范围，`__gr_offs`/`__vr_offs`
  在 **va_start 之后、尚未取完 8 个通用/浮点寄存器之前** 为负。
  ⟦复核⟧ **`*_offs == 0` 不是坏值**：第 9 个及以后的变参正常走 `__stack`，此时 offs 就是 0
  （`libc.so` pop_arg 0x51e8c 起：`gr_offs>=0` → `ldr x3,[x2]` 走 `__stack`）。旧判据把
  "两个 offs 都为负"当健康条件，会把合法的长参数列表误判成污染。
- **禁止用"magic 值指纹"**：`0x1c28416e00000680` 之类不能当指纹——它的高 32 位在现场间
  会变（0x1365fe9b / 0xa4e8817b / 0x0998010a 都见过），只在部分现场重复。可用的形态判据
  见 §16.3（16B `{small,0}` / 32B `{small,0,const,0}` + 同页多块 + 低 32 位 0x6xx/0x1180 族）。
- 崩溃速率必须**同时**给出分子分母（命中/调用或 次/天 + 窗口），并注明**台账**
  （core_meta TSV 还是 aee `db_history`——两者互不包含，见 §14 复核注）。

### 已更正的旧结论（勿再引用）

| 旧结论 | 出处 | 现状 |
|---|---|---|
| **崩溃家族 = musl printf/stdio 的 va_list 缺陷**（本轮最大反转） | §0 旧摘要、§12.5/§12.6、L31/L33 | **被 §16 推翻**：坏值由外部主控注入回收页，musl 只是最高频的受害解引用路径；"改 musl / 重编工具链治崩溃"路线作废 |
| logread 崩溃根因 = 厂商 syslog 管线在**开机期记录流**上的缓冲区边界缺陷 | INCIDENT_2026-10-19 §2.4（2026-10-19 现场研判） | **被取代**：主机制注入（§16）；回放 10/10 不复现、清环只改变调用频率的旧证据与此一致 |
| busybox awk "数组退出清理 NULL 缺陷"是独立根因 | §11.3–§11.5 | **降级为未证实且不再必要**：主机制的 {0,0} 块击中节点指针同样解释 core 现场；受控复现是在污染剧集期内做的，无法区分两种解释 |
| `__vr_top = 0x1c28416e00000680` 是循环计数器形态、非指纹 | §13.2 第 10 条 | ⟦复核⟧ 语义再修正：**不是**"准静态 64 位值"——高 32 位在现场间会变（core_3053=0x1365fe9b、core_27987=0xa4e8817b、rec.log=0x0998010a）。该 64 位值在 6 处**重复出现**是强证据（跨进程/跨编译器），但不能写成"恒定常量"；判据用 §16.3 的形态学 |
| 改 `vfprintf.c` 的**逻辑**即可修 | §12.7（10 次尝试） | 仍成立（坏值进入 vfprintf 前已在），但"修谁"变了：要修的是页回收链（§16.6），不是任何 printf 代码 |
| logc 崩溃与 logread 无关可分开处理 | 早期分析 | 同一主机制；logc v1.4 去 Printf 化作为缓解有效保留 |
| logread 记录帧失步 → `blobmsg_parse` 越界匹配伪属性（§2.1–§2.4 的整条链） | §2.1–§2.4 | ⟦复核⟧ **撤回（假现场）**：tb 读数错位 0x20；core_3053 的真实 tb 五项全部有效且在 16KB 缓冲内，记录解析没有失步。见 §0.0.2-C1 |
| 硬化 vfprintf 补丁"彻底消除崩溃"、代价 1e-8 的错误数字 | §13.3 | ⟦复核⟧ **修正**：是**拦截**不是消除；guard 的 `offs<0` 对 `gr_offs=0` 的合法 va_list 会误伤第 9+ 个参数。见 §0.0.2-C8 |
| 本轮 P1–P4 是"根治方案"、静态化/去 printf/换 awk 是"根因修复" | §7、§9、§10、§11 | **被 §16/§21 推翻**：全是缓解/工具化，对崩溃速率无数量级影响（§22.1）。现行定性见 §22.3，冻结规则见 §22.4 |


## 1. 三份 core 的统一签名

> ⟦复核⟧ **本节是 2026-10-19 的现场记录，机制解释已被 §16/§17 取代**。表格里的
> 寄存器与偏移已复算无误（§0.0.1），但"记录帧失步导致垃圾数据"的因果链已在
> §2.4 复核中撤回。阅读顺序：本节只看"崩在哪、坏块长什么样"，不要据此推因果。

| 项 | core_27987 | core_3053 | core_15875 |
|---|---|---|---|
| 崩溃点 | libc+0x51ffc `ldr x0,[x3]`（同） | 同 | 同 |
| si_addr = x3 | 0x2475b | 0x25746 | 0x14f1b |
| x0 | 0x24768 | 0x25750 | 0x14f28 |
| x5 / x7（printf 内部常量） | 0x0ccccccc / -10 | 同 | 同 |
| 活动格式串（x26/x4） | logread+0x3d0e `"%s %s%s.%s%s %s\n"` | libc+0x7a068 `"%.3s %.3s%3d %.2d:%.2d:%.2d %d\n"` | 同左 |
| 活动调用链 | print_log 自己的 6 变参 snprintf（0x40395c，第 6 变参=消息体，走栈传参） | print_log→ctime(0x403590)→asctime_r→snprintf（第 6 变参=秒，走栈传参） | 同左 |

同一主机制、两个爆发点；两者都在**弹出到第 6 个（第一个栈传递的）变参**时死亡
（3 个命名参数占 x0–x2，剩 5 个通用寄存器 → 第 6 个走 `__stack`）。

### va_list 污染（现场事实）

⟦复核⟧ 该 32 字节结构位于 **sp+0x178**（三份 core 一致）。旧文写的
"`stp q0,q1,[x20]`，x20=sp+0x58" 无法复核（故障现场 x20=0），且偏移与实测不符。
三份 core 中它统一为一条 **16 字节节距的注入记录**，不是"部分字段被覆盖"：

```
__stack  = 0x24768/0x25750/0x14f28   ← 记录字段 1：小整数（85KB~153KB，随记录变）
__gr_top = 0x0                        ← 记录字段 2
__vr_top = 0x????????_0000_06xx       ← 记录字段 3：低 32 位 0x62d/0x680 族，高 32 位随现场变
__gr_offs= 0    __vr_offs = 0         ← 记录字段 4（=0），**不是"幸存"**
```

**时间窗的正确推法**：只能由 si_addr 推——前 5 个变参若用 `__gr_top=0`，第一次弹
就会在 `0xffffffffffffffd8`（-40）处崩；实际 si_addr 是 `__stack`（0x2475b 等），
说明前 5 弹用的还是有效寄存器区，第 6 弹才取到被改写的 `__stack`。
⟦复核⟧ 旧文用"offs=0 幸存"来证明这一点不成立：offs=0 本来就是注入记录的第 4 个字段，
与"已弹 5 个"在数值上巧合。**写入者指令未定位**（见 §16.6/§17），但污染本身与
"第 6 弹死亡"的时序是实锤。

## 2. logread 侧缺陷（反汇编锚点）

> ⟦复核⟧ **本节结论已撤回**：复核发现 §2.4 的"错位现场"是读错栈偏移造成的
> **假现场**，三份 core 里 logread 的记录解析都是正确的。以下保留反汇编锚点
> （它们本身没错）与"帧层只信长度字段"这一真实弱点，但**不要再引用"帧失步
> 导致伪属性"的因果链**。详见 §0.0.2-C1/C2/C3。

二进制：`/sbin/logread`（md5 6e6b5a7d…，本地 tmpfiles/logread.bin）。

### 2.1 记录流格式（从 core 内存实测解码）

⟦复核⟧ logd→logread 的 ubus fd 流**有 4 字节外层 wrapper**（`blob_attr`，id=0，
len=负载长度）；`read_cb` 的帧长就是 `blob_len(a)+4`。wrapper 内是 5 个命名
blobmsg 属性，**顺序固定为 msg,id,priority,source,time**（不是 time 打头），
实测热记录（thermal_core）步进 0xa0：

```
[00 00 00 9c]                                  ← wrapper: id=0, len=0x9c
[83 00 00 4f | 0003 "msg\0"      | "thermal_core[8358]: interval=5 temp: …\0"]
[85 00 00 10 | 0002 "id\0"       | BE64 流水号（实测 0x156f=5487）]
[85 00 00 14 | 0008 "priority\0" | BE32（如 0x1e=daemon.info）]
[85 00 00 14 | 0006 "source\0"   | BE32]
[84 00 00 14 | 0004 "time\0"     | BE64 毫秒时间戳]
```

属性头 BE32 = (类型字节<<24) | 总长（含 4 字节头）；名字前是 BE16 的 namelen
（不含 NUL），数据按 4 字节对齐，**没有独立的 datalen 字段**（数据长度由属性总长
推出）。步进按 4 字节对齐。

### 2.2 read_cb（0x4039a0）——帧同步的全部逻辑

```
循环 { a, avail = ustream_get_read_buf(s)
       if (avail <= 3) 等数据
       w20 = (be32[a] & 0xffffff) - 4 + 4     # 0x40293c：纯信任长度字段
       if (avail < w20) 等数据
       print_log(a)                            # 0x403390
       ustream_consume(s, w20) }
```

**帧层没有任何跨属性一致性校验**：只比较 `blob_len+4` 与 `avail`，不核对 5 属性
齐全、不核对类型、不核对游走是否越界。长度字段一旦被污染，后续记录会整体漂移。
⟦复核⟧ 但**解析层不是零防御**：`print_log` 对 5 个槽位逐个判空，`blobmsg_parse`
按 policy 的 type 过滤（见 §2.3）；三份 core 的 tb 全部有效，说明这条链在
现场**没有**被触发（§2.4）。

### 2.3 print_log（0x403390）——有判空、无范围校验

```
blobmsg_parse(policy×5, tb@sp+0x70, a+4, len(a)-4)   # 0x401bb0 (libubox)
if (!tb[1]||!tb[2]||!tb[3]||!tb[4]||!tb[0]) return;  # 0x4033f4–0x403418，逐个 cbz
m    = blobmsg_get_string(tb[0])      # msg
p    = blobmsg_get_u32(tb[2])         # priority
src  = blobmsg_get_u32(tb[3])         # source（不是 id）
t    = blobmsg_get_u64(tb[4]) / 1000  # time
x24  = ctime(&t)；strlen(x24)；去尾换行
… snprintf(buf@sp+0x378, 0x480, "%s %s%s.%s%s %s\n", x24, …) (0x40395c)
```

⟦复核⟧ 旧文写"5 槽位仅查非空，无类型/范围校验"——判空是真的，类型由
`blobmsg_parse` 按 policy 过滤；`tb[3]` 是 **source**，id 是 `tb[1]`（FILE 路径
只判空、不读取）。真正缺的是**时间戳范围断言**（`ctime` 对任意 `t` 都会格式化），
但这不是本次崩溃的成因。

### 2.4 core 中的"错位现场"——复核为假现场（撤回）

⟦复核⟧ 原文给出的五个 tb 值（0x7facd21d8c / 0x7facc20a4c / 0x7facc7fc30 /
0x6ad527e0 / 0x7facbe84bc）读自 **print_log 帧的 sp+0x50**，那是保存的 x25 与
未初始化槽，不是 tb。tb 在 **sp+0x70**（反汇编 `add x2, sp, #0x70`），
core_3053 的真实内容是：

```
tb[0]=0x7facbe84bc  msg      (83 00 00 4f 0003 "msg")
tb[1]=0x7facbe850c  id       (85 00 00 10 0002 "id")
tb[2]=0x7facbe851c  priority (85 00 00 14 0008 "priority")
tb[3]=0x7facbe8530  source   (85 00 00 14 0006 "source")
tb[4]=0x7facbe8544  time     (84 00 00 14 0004 "time")
```

五项全部落在 16KB 输入缓冲（0x7facbe8000–0x7facbec000）内，名字/类型/顺序
全部正确——**这条记录没有失步，`blobmsg_parse` 没有越界**。原文的
"tb[0..2] 指向缓冲外 50KB+、tb[3] 是裸整数、get_u64 读出 thermal_" 全部是
错位读数的产物。实测该记录的 time = `0x1a150a3c67d` ms → **2026-10-19
04:11:12 CST**（合理时间），id=5487、priority=0x1e、source=1。

**保留的真实弱点**：帧层只信长度字段（§2.2），一旦长度字段被外部改写，
后续记录会整体漂移；但这不是 10-19 三份 core 的现场，也不是主机制。

## 3. 厂商 musl（/lib/libc.so, md5 见归档）侧事实

> ⟦复核⟧ 本节是"库侧长什么样"的静态事实，**不是缺陷认定**。旧文把
> "受限输出溢出 → va_list 被覆盖"写成已证缺陷，已被 §16 推翻。

- `ctime`(0x5d794)：`localtime(t) ? asctime_r(tm, 静态buf26) : NULL`。
- `asctime_r`(0x5d460)：标准 musl `snprintf(buf,26,"%.3s %.3s%3d %.2d:%.2d:%.2d %d\n", …)`。
  年份 6~9 位时输出 30+ 字节 > 26 → 进入受限输出的溢出处理路径。
- 崩溃点 `libc+0x51ffc` 位于 pop_arg 变参取出跳转表（0x51e80 派发，
  8 字节整数/指针条目）：`x3 = __gr_top+__gr_offs`（寄存器区耗尽后
  改用 `__stack + 对齐修正`）→ 解引用。
- `vsnprintf`(0x56004)：FILE 结构与 {p,n} cookie 都在栈帧内；
  write 回调 `0x55f3c` 的两段 memcpy 均有界，末尾 `*p=0` 并把
  wpos/wbase 重置回 f->buf。
- ⟦复核⟧ **旧文"已证缺陷：受限输出溢出时 va_list 被垃圾覆盖"作废**：受限输出与
  污染没有因果关系；同一形态的坏块也出现在完全不调用 `strftime/asctime` 的
  sh/grep/ip 现场（§11.7、§12.3）。此条保留仅为记录当年的推理。
- **同仓疑点**（未证与本次相关）：printf_core 的位置参数路径
  `0x53368/0x53374` 把下标直接存进 `nl_type`/`nl_arg`。⟦复核⟧ 在 zig 的
  musl 源码里 `argpos` 只取**一位数字**（`s[1]-'0'`，≤9=NL_ARGMAX），
  并非常见的"无界 `%N$`"；厂商 libc 是否同样受限未逐指令核对。
  本次格式串不含位置参数，非触发路径——**不要把它当成已知缺陷引用**。
- 对照实验（设备实测）：busybox `date -d @<极端时间戳>` 全部正常
  （±2^48 范围内格式化不崩）——busybox 走 strftime 自有路径，
  不经过 asctime 的 26 字节受限 snprintf。
  ⟦复核⟧ 当年由此得出"崩溃链特定于'受限 snprintf + 溢出输出'组合"，**该结论已作废**：
  大时间戳只是让 logread 更容易走到 `ctime`（多一次 printf），与污染无因果。

## 4. 家族现状（清环后仍未根除的部分）

> ⟦复核⟧ 本节是 10-19 当天的"家族成员清单"，**机制解释以 §16 为准**：
> 成员多不是"多个独立缺陷"，而是同一注入机制打在不同受害者上。
> 本节唯一仍有独立价值的是**监控缺口的观察**（aee 与 core_meta 两个台账互不包含，
> 见 §14 复核注）。

清环（17:32）后 logread 本体零复发（最后一条 logread NE=17:01），
但 aee `db_history` 持续出现新 NE，全部是**不同 busybox applet /
动态链接工具**：

| 时间 | 进程 | 说明 |
|---|---|---|
| 18:34:35 | grep | 读 4MB 日志（log_keeper 滤波路径） |
| 18:55:48 | awk | log_keeper 锚定抽取路径 |
| 19:07:28 | sh | 脚本本体 |
| 19:30:04 | ip | wan_agg 型管线的 `ip -o -4 addr` |

公共分母实测：`/bin/busybox`、`/usr/libexec/ip-full`、`/sbin/logd`、
`/sbin/logread` 的 ELF interpreter 全部是 `/lib/ld-musl-aarch64.so.1`
（同一厂商 musl）。二进制已拉回本地归档（md5 校验通过）。

- 崩溃时刻与蜂窝拨号风暴（mipc_cli 连发、ccmni 翻动）和 WiFi 搬道
  风暴（hostapd channel switch 连发）时段吻合——即 wan_agg 型管线
  高频 spawn ip/grep/awk 的时段。
- 受控复现（4 分钟、2990 轮 grep -cE/awk 锚定抽取/logread/sh -c true，
  合计 ~1.2 万次进程生成，core_pattern=/tmp/core.%p）：**零命中**。
  → 家族崩溃**不是**每次 exec 的均匀概率。⟦复核⟧ 当年写"条件触发（特定输入/
  时机）"，现在应改为"**剧集期触发**"：零命中是因为那 4 分钟落在平静期
  （§16.1 的 memtruth 电池给出同样解释）。
- 家族成员的内核 DABT 行已被 printk 限流吞掉（dmesg 镜像 18:14 后
  无新增 unhandled exception 行），拿不到故障 PC；core 未捕获。
- **监控缺口**：watchdog v1.20 的 fault 计数依赖内核 DABT 行，
  限流后 `/tmp/watchdog_faultcount=0` 而 aee 仍在记录 NE ——
  fault 计数存在低估，判据需要换 aee db_history 增量。
- aee 转储器自身会 spawn ps/df/ip/awk/logread（既有档案），存在
  放大回路；根治 logread 即掐断最大放大源。

## 5. 官方固件对比：缺陷在场，但官方几乎不发病

**问题**：崩溃全部发生在保留下来的官方组件里——纯官方固件也会崩吗？

**结论**：崩溃全部落在官方保留下来的组件上，但这些组件**没有缺陷**
（§16/§17：musl/logread/logd/busybox/ip-full 都是受害者）。官方出厂配置下
`logread` 的常驻路径不启动、家族成员的执行密度也低几个数量级，因此**新页
churn 少、曝光≈0**；官方的"稳定"是曝光≈0 的稳定，不是机制稳定。我们打破的
是页流转平衡，不是拆除了某种防御。

### 5.1 证据

1. **官方本来就不跑常驻 logread**：`/etc/init.d/log`（procd 服务）
   按 `ap_auto_logging` 决定是否启动 `logread -f -F <log_file>` 落盘
   守护；当前配置 `ap_auto_logging '0'` → 该实例从不启动。
   `/data/debuglog/`（官方落盘目录）自厂商镜像日期（09-09）起
   **从未被写入过** ——官方时代没有任何日志落盘行为。
2. **官方时代没有可信的崩溃记录**：aee `db_history` 首条为我方固件上线后
   第一小时（10-05 12:28 UTC = 20:28 CST，mipc_wan_cli）。
   ⟦复核⟧ 现文件已 296 条，且第 43–44 行有两条 **Sep 9** 记录夹在
   10-17/10-18 之间、对应槽位当前内容是 10-22 的崩溃——更像槽位复用/陈旧
   报告，而不是官方时代真实崩溃。结论改为"**未发现可信的官方时代 NE**"，
   这两条待查（§0.0.2-C19）。
3. **环配置是官方原配**：`log_size 10240`（KiB）→ `logd -S 10240`
   = 10MB RAM 环，非我方放大；官方无 cron、无任何环清理/轮转机制
   被我们移除（官方的"清理"就是无人读取、自然回卷）。

### 5.2 我们打破平衡的三个杠杆（⟦复核⟧ 按 §16 改写）

1. **进程/新页 churn（真正相关的杠杆）**：30s 级守护舰队让 ip/grep/awk/sh
   频繁 exec，每个新进程都要从 buddy 池拿新页——这正是"回收页被复用"的入口。
   官方没有这层 churn（§16.2-E6）。
2. **读环频率**：每次读环都要 spawn reader（logread/logc）与管道工具，增加
   新页获取次数；记录内容本身与崩溃无关（§16），"毒记录驻留"的旧解释作废。
3. **工具执行密度**：与 1 同源——spawn 越多、新页越多、命中的概率越大；
   这不是"条件触发的样本量"，而是"暴露面"。

### 5.3 推论

- 反向预测（⟦复核⟧ 收紧）：B 槽官方镜像下循环跑 `logread`，**在剧集期**
  同样会崩（同一注入机制），平静期可能 0 崩；官方正常使用下几乎不崩
  （新页 churn≈0）。
- **运营红线**：`ap_auto_logging` 不得置 1——那会点亮官方
  `logread -f` 常驻路径，立即成为崩溃源 + aee 放大器。P1 采集器
  上线后应成为全机唯一 reader，并将该开关纳入 manifest 护栏。
- 官方对比同时说明：只"恢复官方的平衡"不够（那只是减少 churn），
  真正的根修是页回收链（§16.6/§17.5）；P1/P2 是降低曝光的缓解。

## 6. 未闭环问题（诚实清单）

> ⟦复核⟧ 本节是 10-19 的清单，其中 1–3 已被后续轮次关闭或推翻：
> ① "写入者在 vfprintf 内部"已被 §16/§17 否定（写入者在 MD 侧）；
> ② 家族 core 已由 §11.2/§11.7 与 pageharvest 补上；
> ③ "帧同步错位"的前提已在 §2.4 复核中撤回（三份 core 都没有错位）。
> **现行清单以 §16.8 为准**（O1 活捉的 PFN/kpagecount 仍未拿到）。
> 第 4 条（logread text 段崩一次、无 core）仍然成立，且不影响定性。

1. ~~**libc 写入者指令未定位**~~ —— 已关闭：写入者不在 vfprintf，见 §16/§17。
2. ~~**家族成员的触发输入未捕获**~~ —— 已由 §11.2/§11.7 的受控 core 与
   §17.3 的 pageharvest 活捉补上。
3. ~~**帧同步最初如何错位**~~ —— 前提撤回：三份 core 的 tb 全部有效，
   没有"第一个坏长度"（§2.4 复核）。
4. logread 自身 text 段崩溃那一次（1/15）未拿到 core（仍然成立，不影响定性）。

## 7. 根治方案（分阶段）

> ⟦2026-10-22 收口 §22⟧ **本节标题里的"根治"已不成立**：P1–P4 的共同前提
> （崩溃面 = musl/awk 缺陷）被 §16 推翻。本节保留为历史决策记录；各项的现行定性
> 与处置见 §22.3，修复主线改到内核侧（§23）。

### P1 — 自建静态日志采集器（根治 logread 主链路 + 掐断 aee 放大源）

> **已落地**（`gw/src/logc.c` → `gw/bin/logc` v1.0，静态 95KB；log_keeper v1.8 /
> diag_dump v1.2 已切换）。执行与验证见 §9。
> ⟦复核⟧ 定位已改：P1 不是"根治崩溃"，而是**摘掉最高频的污染解引用点**
> （§16.4）；它另有独立价值（受控解析/stats/selftest）。

用 zig `aarch64-linux-musl` 静态构建（先例：mipc_cellular v12 静态版），
走同一 ubus fd 流，但：

- 帧解析带**全套校验**：长度字段上界（≤缓冲剩余）、属性类型白名单、
  5 属性齐全才输出、游走指针必须落在 `[buf, buf+len)` 闭区间；
  任何违规 → 丢弃当前帧 + **全量重同步**（丢弃至下一个可识别的
  `time` 属性头）+ 计数器告警（喂 watchdog）。
- 时间戳解码后做**范围断言**（epoch 合理区间），越界即丢帧计数。
- 输出格式与 logread 兼容（GUI 日志页/log_keeper 锚行无感切换）。
- ~~静态链接 = 与厂商 musl 零耦合 = 本条崩溃路径物理消失。~~
  ⟦复核⟧ **作废**：静态件同样中招（§16.7 的 P2 行）。静态化的收益是
  "工具链自主 + 无 printf 热路径"，不是"崩溃路径消失"。

### P2 — 守护脚本工具链静态化（根治家族的暴露面）

> **已落地**（`gw/bin/busybox` 1.36.1-r31 + `gw/bin/ip` 6.3.0 静态；
> `gw/toolchain_init.sh` 建 `/data/gw/sbin` 农场，rc.extend v2.3 前置 PATH；
> 已观测到全部常驻守护的 `/proc/<pid>/exe` = 静态 busybox）。执行与验证见 §9。
> ⟦复核⟧ **前提已推翻**：静态件同样崩（§16.7）。P2 保留为工具链自主与
> procmatch/logcut 的交付载体，**不再作为治崩溃手段**。

busybox（grep/awk/sh…）与 ip-full 全部动态链厂商 musl。构建静态
busybox（zig/自有 musl，defconfig+所需 applet）与静态 ip 子集，
放 `/data/gw/bin/` 并在守护脚本 PATH 前置。脚本零改动；
selftest 增加静态工具存在性与行为等价校验。分批灰度：
先 wan_agg/dial_keeper（崩溃热点），再 watchdog/log_keeper。

### P3 — 家族 core 捕获 trap（闭环 §5-2）

> **已落地**（`gw/core_trap.sh` v1.0，每日 03:20 起 600s；rc.extend 抬
> RLIMIT_CORE=unlimited；watchdog v1.24 自愈）。窗口机制已用静态 crashme
> 实测抓取并归档到 `/data/gw/logs/cores/20261019/core.8220`。见 §9。

低频窗口方案：每日一个 10 分钟窗口把 core_pattern 切到
`/tmp/core.%p`（ulimit 配套），窗口结束由 log_keeper 附带把
`/tmp/core.*` 搬 `/data/gw/logs/cores/` 并恢复 aee 管道；
拿到家族 core 后按本文件 §1 的方法提取 libc 偏移对齐验证同源性。

### P4 — 判据与监控修正

> **已落地**（watchdog v1.24：dmesg 行增量 + `aee db_history` 行增量双判据；
> 实测 20:47:01 / 20:53:48 两条 `WARN aee NE +1`，含进程名/信号/时间原文）。

- watchdog fault 判据从"dmesg 行增量"改为/加上"aee db_history
  行数增量"（用 stat mtime+行数，避免读内容）。
- 保留：开机清环（log_keeper v1.7）、watchdog 自愈、fault 计数。

### 部署纪律

P1/P2 均为 `gw/` 新资产：二进制入 `gw/bin/`、源码入 `gw/src/`，
VERSIONS.tsv 登记并 bump；设备推送走 deploy.py（push/put），
P2 的 PATH 切换经 manifest 灰度，上线后冷启动验证。

## 8. 取证资产索引（本地 tmpfiles/，不入仓）

- `core_27987/3053/15875.bin`：三份 logread core（本文 §1/§2 依据）；
- `libc.so`、`logread.bin`：反汇编正本；
- `sigsegv_re/core_an.py`：core 解析器（PRSTATUS/SIGINFO/NT_FILE/内存）；
- `sigsegv_re/disx.py`：capstone 反汇编器（PLT 符号+字符串标注）；
- `sigsegv_re/stress_family.py`：家族受控复现驱动（含 core_pattern
  备份恢复；注意首次运行失败会残留 /tmp/core.%p，需手动恢复 aee）;
- `sigsegv_re/busybox.bin / ip-full.bin / logd.bin / libubox.so`：
  家族二进制归档（md5 与设备一致，2026-10-19 拉取）。

## 9. 根治方案执行记录（2026-10-19 晚轮，P1–P4 全部落地）

> ⟦2026-10-22 收口 §22⟧ 执行记录本身属实（变更、验证、冷启动都在），但**"根治"是错的**：
> 这四项对主机制是缓解/工具化。定性见 §22.3，冻结规则见 §22.4。

> 本轮把 §7 的方案完整实施并做设备侧验证。全部变更在公开仓：
> `6bf5cfa`(P1–P4 主体) → `1fdaa33`(单实例锁加固) → `2ff1a41`(启动日志版本)
> → `49db88a`(watchdog spawn 自锁死循环) → `a81557c`/`8f7374e`/`0bbf81e`
> (TZ/启动宽限/PATH 幂等)。版本注册表与 ARCHITECTURE.md 已同步（113 个登记
> 文件 / MANIFEST 65 项，vercheck 全绿）。
>
> ⟦复核⟧ 下表是 **2026-10-19 的快照**，不是现行版本：watchdog 已到 1.30、
> rc.extend 2.6、core_trap 1.2、selftest 2.58、deploy 2.26（`tools/VERSIONS.tsv`）。
> 另外，`gw/src/logc.c` 的头注释与 VERSIONS.tsv 的部分描述仍写着旧的
> "帧失步/musl 缺陷"叙事——**以本文 §16/§17 为准**，改代码时顺手更正即可。

### 9.1 变更清单

| 阶段 | 资产 | 版本 | 设备路径 |
|---|---|---|---|
| P1 | `gw/src/logc.c` → `gw/bin/logc` | 1.0 | `/data/gw/bin/logc` |
| P1 | `gw/log_keeper.sh`（改用 logc） | 1.8 | `/data/gw/log_keeper.sh` |
| P1 | `gw/diag_dump.sh`（改用 logc） | 1.2 | `/data/gw/diag_dump.sh` |
| P2 | `gw/bin/busybox`（静态 1.36.1-r31） | 1.0 | `/data/gw/bin/busybox` |
| P2 | `gw/bin/ip`（静态 iproute2 6.3.0） | 1.0 | `/data/gw/bin/ip` |
| P2 | `gw/toolchain_init.sh`（符号链接农场） | 1.0 | `/data/gw/toolchain_init.sh` |
| P2/P3 | `gw/rc.extend.sh`（PATH/TZ/RLIMIT_CORE） | 2.5 | `/data/rc.extend.sh` |
| P3 | `gw/core_trap.sh`（每日 core 窗口） | 1.0 | `/data/gw/core_trap.sh` |
| P4 | `gw/watchdog.sh`（aee 增量+core_trap 自愈+启动宽限） | 1.25 | `/data/gw/watchdog.sh` |
| 构建 | `tools/build_logc.sh` / `tools/build_static_ip.sh` / `tools/fetch_static_busybox.sh` | 1.0 | PC 侧 |

P2 的 busybox 与厂商同为 **1.36.1**（Alpine `busybox-static-1.36.1-r31`，
SHA-256 钉死在拉取脚本里，305 个 applet）；ip 用 **iproute2 6.3.0**（与厂商
`ip -V` 同版本）以 zig cc/musl 重建，避免 busybox ip 的输出空格差异与
`link add ... type bridge` 缺失。两者均为 GPLv2（busybox）/GPLv2（iproute2），
源码/包 URL 与校验值在构建脚本内。

### 9.2 P1 验证（logc）

- **合成恶意流**：9 条合法记录 + 垃圾插段/越界长度/错误类型/1970 前垃圾/
  msg 内嵌 NUL 混合。输出恰为 9 条合法记录；坏帧计数与重同步计数逐项对上，
  进程零崩溃（`--stdin` 离线模式）。
- **真实环**：`logc --stats-file` 读全环 `frames=694 bad_frames=0 resyncs=0
  dropped=0 bad_time=0 bad_attrs=0`；与厂商 logread 同窗口 `-l 3` 输出
  **逐字节 diff 相同**。
- **稳定性**：220 次 `-l 200` + 20 次全环读取 0 失败；期间 aee `db_history`
  零新增。清环后 logread 的 1% 崩溃率对 logc 不再适用（无 ctime/asctime_r 调用）。
  ⟦复核⟧ 这句只在**当时那 240 次**成立：logc v1.0–v1.3 仍走 printf，随后自己
  崩了 109 次（§10.1），直到 v1.4 去 printf 才归零。**不要引用"logc 不受影响"**。
- **接线**：log_keeper/diag_dump 的厂商 logread 调用归零（selftest 断言
  `^LOGC=/data/gw/bin/logc` 且无 `logread ` 行）；logd 清环保留，理由仅为
  aee 转储器内置的厂商 logread 无法替换。

### 9.3 P2 验证（静态工具链）

- `/data/gw/sbin` 农场 305 个 applet；`sh/grep/awk/sed/ip/...` 均解析到静态件。
- 常驻守护 `watchdog / led_mgr / dial_keeper / log_keeper / core_trap /
  wan_agg / wan_eth` 的 `/proc/<pid>/exe` **全部** = `/data/gw/bin/busybox`；
  其 environ 为 `PATH=/data/gw/sbin:/data/gw/bin:...`、`TZ=CST-8`。
- `ip` 输出与厂商逐字节一致：`-o -4 addr` / `rule show` / `-6 rule show` /
  `route show default` / `-6 route show default` / `link show br-lan`；另实测
  `ip link add <x> type bridge` + `link del` 成功。
- 静态 busybox `sh -n` 语法检查全部 gw 脚本通过；awk/grep -Fqx/sed/tail/wc/
  date（带 TZ）抽样与厂商行为一致。
- 冷启动竞态修复：首个冷启动发现 watchdog 在 rc19 拉起 wan_agg 之前抢跑，
  产生两个 `sh wan_agg.sh`；v1.25 加 180s 宽限（只记 SKIP 不算失败），
  第三次冷启动实测 `wagg=1`。

### 9.4 P3 验证（core 窗口）

- 用 `CORETRAP_START=<now> CORETRAP_SECS=120` 模拟窗口：`core_pattern` 切为
  `/tmp/core.%p`；静态 crashme 触发 SIGSEGV，产生 `core.159744B`；
  窗口关闭后自动搬至 `/data/gw/logs/cores/20261019/core.8220`，`core_pattern`
  恢复 aee 管道，日志记录 `aee_lines=173->173`。
- 冷启动后 core_trap 常驻（watchdog 自愈），守护侧 `Max core file size =
  unlimited`；正常态 `core_pattern` 保持 aee。
- 真实家族 core 的捕获要等每日 03:20–03:30 窗口（首个窗口在本轮之后）。

### 9.5 P4 验证（aee 增量判据）

- 20:47:01 `WARN aee NE +1 (total 174): db.05.NE ... SIGSEGV,awk`；
  20:53:48 `WARN aee NE +1 (total 175): db.01.NE ... SIGSEGV,ip`。
  两条与 `db_history` 增量、`ZZ_INTERNAL` 进程名/信号/时间**一致**；同期
  dmesg 的 `unhandled exception` 行已被 printk 限流（0 行），证明单靠 dmesg
  确实会低估。
- 三次冷启动 aee 行数保持 175 不变（开机噪声不误报）。

### 9.6 冷启动验证（boot_id `5eabd07c-…`）

- `TRY_A=0f 00`（A 槽优先、TRY 已清零），`boot.done` 在位，slot=a。
- `toolchain_init` 农场在 21:27:44（**本地时区**）就绪；全部守护静态。
- 恰一个 `wan_agg`；`SKIP wan_agg recovery (boot in progress)` 为 v1.25
  宽限生效的直接证据。
- `logc.stats` 读取 694 帧零异常；`dmesg | grep -c 'unhandled exception'` = 0。
- **全量 selftest：87 pass / 0 fail**（system 23/23 含 4 个新护栏）。
- 冷启动后 21:33:55 新增一条 `netstat` NE，定位为**本机 selftest 经 SSH 执行的
  厂商 netstat**（selftest 的 `dev("netstat -tln ...")` 走 SSH 默认 PATH，不在
  守护树内）；随后 200 次静态 `netstat` + 100 次厂商 `netstat` 均无复发。
  守护树内 `netstat` 已解析为 `/data/gw/sbin/netstat` → 静态 busybox。

### 9.7 残余风险与运维约定

1. **aee 仍用厂商 logread**：logd 清环（uptime>=300s 一次）继续保留；ring
   含开机记录时 aee 转储仍有崩溃可能，但次数已从"每次读环"降到"崩溃转储时"。
2. **静态工具链只覆盖守护树**：手工 SSH 登录后默认仍是厂商 PATH/工具；需要
   静态工具时用 `PATH=/data/gw/sbin:/data/gw/bin:$PATH` 或直接绝对路径。
   若 busybox 缺失/损坏，`toolchain_init` 会移除农场并回退厂商工具（fail-open，
   不锁死设备）。冷启动验证中唯一一条新 NE（netstat）就是本机 selftest 经 SSH
   调用厂商工具产生的，印证了"守护树已隔离、PC/手工侧仍是旧暴露面"的边界。
3. **core 窗口**：每日 03:20 起 10 分钟；`/tmp` >80% 提前关闭；核心落
   `/data/gw/logs/cores/YYYYMMDD/`，每日目录只留最新 20 个；同时段
   `core_pattern` 从 aee 切走，属于已知取舍（窗口短、有 watchdog 恢复）。
4. **`ap_auto_logging` 必须保持 0**（§5.3 红线）：否则官方 `logread -f`
   常驻路径重新点亮，回到旧暴露面。
5. **P3 真实 core 回收**：需要下一个 03:20 窗口后按 §1 方法解析
   `/data/gw/logs/cores/`，确认家族 core 与 logread core 同源（libc+0x51ffc
   或其它触发点），再决定是否扩大窗口/频率。

## 10. 2026-10-21 回合：logc 崩溃根因定位 + v1.4（printf-free 记录路径）

> ⟦2026-10-22 收口 §22⟧ 标题的"根因"仅指 **logc 自身崩溃的最近原因**（printf 解引用被
> 污染内存），**不是**家族的根因；家族根因见 §21。v1.4 的收益是"摘掉最高频解引用点"。

> 本轮目标：把 `logc` 的持续 SIGSEGV（不是厂商组件，是我们自己的静态采集器）定位到
> 具体指令与调用链，并给出可验证的修复。证据在本地 `tmpfiles/round_logc/`
> （面包屑归档 `evidence/`、崩溃原始流 `crash.raw`、gdb 现场 `crash.72.log`）。

### 10.1 现场规模（先看数，不看猜）

- `/data/gw/logs/logc_crash/` 132 份面包屑 = **109 次不同崩溃**（其余为 log_keeper
  在 rc!=0 时重复复制同一份 `/tmp/logc.crash`，属取证噪声）；全部 `sig=11`，
  版本 v1.2×2 + v1.3×107，跨 2026-10-20 00:21 → 10-21 19:45。
- 崩溃点分布：`buf_len` 几乎恒在 **65536–66336**（一次 read 刚灌入的 ~64KB 块），
  `frame_off` 0x0d4–0xf8b8、`frame_len` 116–800，`frames_emitted` 54–37887。
  格式全部合法（同一批运行 `bad_frames=0 resyncs=0`）——**不是帧解析越界**。
- 同期 `ne_events.tsv`（core_meta 抓到 core 的进程）：static busybox（awk/pidof/
  sh/ping/grep）44、static ip 17、wpad 2、xtables 1、logread 1 —— 静态工具链也在崩，
  但 logc 是频率最高的一条（约 7 次/小时）。

### 10.2 取证方法（可复用的两条）

1. **gdb 在设备上直接抓现场**：设备自带 `/usr/bin/gdb 12.1`。构建**同源码同优化**
   的带符号静态件（`zig cc -O2 -g -static`，不 strip），用
   `gdb -batch -ex 'handle SIGSEGV stop print nopass' -ex run -ex 'bt full' ...`
   跑 one-shot 环读；崩溃时 gdb 在 logc 自己的 handler 之前截住信号，拿到
   PC/寄存器/va_list/各层栈帧。
2. **`--dump-raw` 留输入**：崩溃那轮的原始流落盘，可 `--stdin` 离线回放。
   本轮实测：回放**不复现**（10/10 rc=0）→ 触发依赖运行期状态而非单纯字节内容，
   这条结论本身排除了"某条坏记录"的假设。

复现率（同一二进制、同机、稳态环）：约 **1/220 ~ 1/600** 次 one-shot 全环读取；
开机环（含 dmesg 引导记录）明显更高（一次 72 轮即命中）。

### 10.3 崩溃现场（决定性证据）

`crash.72.log`（`frames_emitted=1816`，记录是普通内核引导行）：

```
Program received signal SIGSEGV
0x10254d0 in printf_core (f=..., fmt="%0*lld", ap=..., nl_arg=..., nl_type=...)
  at .../musl/src/stdio/vfprintf.c:485
#1 vfprintf      (fmt=0x10006e0 "%0*lld")
#2 vsnprintf
#3 snprintf      (s=..., n=...)
#4 __strftime_fmt_1 (f=83 'S')
#5 __strftime_l  ("S %Y" 剩余格式)
#6 emit_record   (logc.c: strftime(...))
```

故障指令（`printf_core+892`，即 `w = va_arg(*ap, int)` 的寄存器区取值路径）：

```
ldr  x9, [x12, #0x18]   ; x9 = ap->__gr_offs = -40
...
ldr  x11, [x12, #8]     ; x11 = ap->__gr_top  = 0        ← 坏值
add  x9, x11, x9        ; x9 = -40
ldr  w26, [x9]          ; SIGSEGV, si_addr = 0xffffffffffffffd8
```

崩溃时 vfprintf 帧内的 `ap2`（`va_copy` 的结果，`crash.72.log:71` 原文）：

```
__stack  = 0x1c28416e00000680   ← 注入记录字段 1
__gr_top = 0x0                  ← 注入记录字段 2
__vr_top = 0x7fe09feae0         ← 正常（未被改写）
__gr_offs = -32, __vr_offs = -128  ← 原文 -32；故障地址 -40 对应"弹出宽度参数"
```

⟦复核⟧ 旧文写 `__gr_offs=-40` 与日志不符（日志是 **-32**）。-40 是故障地址
（`si_addr=0xffffffffffffffd8`），与 `%0*lld` 的宽度参数（第一个变参）一致；
gdb 打印的 ap2 与实际指令使用的副本可能不是同一份（§13.1 的 `&ap` 物化问题），
这里以故障地址为准。**同一份日志还显示调用方 `snprintf` 的 ap 是健康的**
（`__stack/__gr_top` 都是栈地址、`__gr_offs=-40`）——这直接反驳了 §13.2 #6
"坏源在调用方"的说法。

**与厂商 musl 的旧签名同源**（§1：`__stack` 垃圾 + `__gr_top=0`）。
区别只是本次发生在 zig/Alpine 同源的 musl 1.2.x 上、且在弹出**第一个**变参时就死。

### 10.4 结论：缺陷不在 logc 的解析器

- 解析器所有游走都限定在 `[buf, buf+flen)`，且 `flen` 先与 `avail` 比对；
  13 轮设备侧 fuzz + 本轮 2000 轮 in-process fuzz 零命中。
- 崩溃发生在 **格式固定为 `"%0*lld"`** 的 musl 内部调用上，输入只有合法的
  `struct tm`；logc 侧唯一参与的是"调用 strftime"这个动作。
- 因此修复方向不是"更严格的帧校验"，而是**把 printf/va_list 从记录路径里彻底移除**。
  ⟦复核⟧ 这是**缓解**（摘掉最高频解引用点，§16.4），不是根修；根修见 §16.6/§17.5。

### 10.5 修复（logc v1.4）

| 变更 | 说明 |
|---|---|
| 手写 ctime 格式 | `localtime_r` + 星期/月名表 + 有界整数输出，产出 `Www Mmm dd HH:MM:SS YYYY`，与 `strftime("%a %b %e %H:%M:%S %Y")` **逐字节一致** |
| 手写整行拼装 | 时间 + 可选 `[sec.millis] ` + `fac.pri` + ` kernel:` + msg + `\n`，全部 `memcpy`/边界检查，无 `snprintf` |
| stats 也去 printf | `write_stats` 改 `stats_kv()` 手写；守护热路径上再无 printf 家族 |
| 超长消息不再中止整轮 | 旧版 `snprintf` 溢出返回 -1 → `consume_records` 返回 SIZE_MAX → 整轮 rc=1（stability_metrics 里的 `logc_rc=1 io=1` 即此）；v1.4 缓冲区按 `MAX_MSG+256` 配足，异常情况只丢该条并计数 |
| 静态反链断言 | 产物已不含 `strftime` 的 `"%0*lld"` 与 `"%a %b %e"`（`grep -a -F` 可验），selftest v2.55 固化 |

### 10.6 验证

- **输出等价**：同一份 `crash.raw` 分别喂 v1.3/v1.4，`--stdin` 与 `-t` 两种模式
  `cmp` **逐字节相同**（36439 B）。
- **A/B 实弹**（同环状态交替跑，2500 轮设计，实际 2407 轮）：
  **v1.3 rc=139 × 10（20:26:57–20:27:41），v1.4 rc=139 × 0**；两版 rc=1 各 7/6 次
  （logd 短暂不可用，环境性）。崩溃全部落在 v1.3 一侧且未影响 v1.4。
- `--selftest` / `--fuzz 2000` PASS；`vercheck` 全绿。

### 10.7 仍未闭环（诚实清单）

1. **va_list 前 16 字节的写入者未定位**：可以确定 `ap2` 是 vfprintf 里对调用方
   va_list 的 32 字节整拷贝（`ldp q1,q2,[x2]; stp q1,q2,[sp,#0x120]`），且
   `__vr_top/__gr_offs/__vr_offs` 三个字段被正确复制——只有 `__stack/__gr_top`
   被换成垃圾。候选是 vfprintf 帧内 `internal_buf[80]`/`nl_arg[10]`/`nl_type[10]`
   某条越界写（`nl_type[12..15]` 恰好落在 `ap2` 头上），但静态反汇编未能收敛到
   具体写指令；下一次可用硬件观察点（`watch *(long*)($ap+8) if ...==0`）收口。
2. **静态 busybox/ip 的同族崩溃仍在**（core_meta 有元数据、aee core 加密）：
   本轮只根治了我们自己代码里可控的那条链路；⟦复核⟧ 第三方静态件同样会中招
   （§16.7），风险不在"是否走 musl printf"，而在"是否拿到污染页"；
   需要单独取证（core 窗口 / gdb 抓 `ip`）。
3. **取证副作用（运维注意）**：持续高频 spawn（4 个 gdb 循环，或 2 进程/轮的 soak）
   会让 dropbear 进入"accept 后 EOF / 无 banner"的卡死态，SSH 不可恢复，
   只能 `sys_reboot`（GUI `/api/sys_reboot`，实测有效；reboot_sched 因当日
   `last` 去重不会触发）。取证脚本请限制并发、优先落 `/data`。

## 11. 2026-10-21 第二轮：剩余家族成员（awk 空数组 → busybox 退出路径 NULL）

> ⟦2026-10-22 收口 §22⟧ 本节结论（"awk 内部缺陷"）**降级为未证实且不再必要**（§16.3）：
> 受控复现是在污染剧集期内做的，无法区分"awk 缺陷"与"主机制注入"两种解释。
> `logcut` 保留的理由是少 spawn/无大数组，不是"修好了 awk"。

> logc v1.4 之后，`logc_crash/` 不再增长（133 份为历史存量），但 `ne_events.tsv`
> 里的**其他成员**仍在崩。本轮用受控 core 窗口抓到第一份非 logc 的 core，定位到
> 一条与我们脚本直接相关的 busybox awk 缺陷并修复。

### 11.1 家族普查（`ne_events.tsv`，75 次 core_meta 事件）

> ⟦复核⟧ 75 = 截至 10-21 21:30 的 88 行 **减去 21:04–21:15 的 13 条 awk 复现崩溃**
> （aee 把它们记在 busybox 名下，module count 表里就是 13）。下表补上原先漏列的
> 2 条 busybox，合计才等于 75；`?` 3 条按 §12.1 不是崩溃，普查时应剔除。

| comm | 次数 | 备注 |
|---|---|---|
| awk | 27 | log_keeper 的 `delta()` 锚行抽取（本轮修复对象） |
| ip | 17 | `ip -4 addr show` / `ip -o -4 addr show`（led_mgr/wan_agg） |
| sh | 5 | busybox sh 解释器本体 |
| grep | 4 | `grep -Fqx` 锚行预检、降噪过滤 |
| pidof | 4 | watchdog 的 `pidof v3httpd` |
| gdb | 3 | **取证工具自身**（我们跑 catcher 时） |
| logd | 2 | 厂商 syslog 守护 |
| hostapd | 2 | 厂商 wpad |
| busybox（其他） | 2 | 1 条自测 `sh -c kill -SEGV $$` + 1 条 `led_mgr.sh` |
| thermal_core / sleep / ls / ping / iptables / logread | 各 1 | 含 **`sleep 1`**（不做任何格式化） |
| ? | 3 | core_meta 读不到 exe/args（进程已不可见）——**不是崩溃** |

分布是**全天稳态**（不是只在取证时）：10-20 各小时 1–9 次；取证循环期间会叠加
（20:21–20:27 6 次，含 gdb 自身 3 次）。`sleep` 与 `?` 的存在说明这不是单一
"printf 用得多"能解释的。⟦复核⟧ 但它们**不是"多个独立缺陷"的证据**：同一注入
机制打在不同受害者上，签名只取决于哪个字段被击中（§16.4）；`sleep` 没有 printf
也会崩，恰恰说明问题不在 printf 用量。

### 11.2 受控 core 窗口（可复用方法）

```
SAVED=$(cat /proc/sys/kernel/core_pattern)
echo '/tmp/cores/core.%e.%p' > /proc/sys/kernel/core_pattern
ulimit -c 8192        # 核心很小(awk 200KB); NT_PRSTATUS 在最前, 截断也能取寄存器
... 复现/等待 ...
echo "$SAVED" > /proc/sys/kernel/core_pattern   # 任何退出路径都恢复
```

窗口开在 21:01，30 秒内 log_keeper 的 awk 自己崩了，得到
`core.awk.9766`（204800 B）。**注意**：窗口期间 aee 拿不到 core，属已知取舍；
core_trap 的每日窗口机制保持不变。

### 11.3 core 现场

```
signal=11 si_code=1(SEGV_MAPERR) si_addr=4
pc=0x491ab8  ldr w0,[x19,#4]      x19=0        ← NULL+4
lr=0x4932d4
调用点 0x4932d0: bl 0x491aa4      ← 上一个 bl 0x4919b8 的返回值直接传入, 未判空
0x4919b8 返回 [node+0x18]（可能为 NULL, 调用方不检查）
0x491aa4 遍历 node->items[i] 逐个 free, 最后把 node 清零
```

寄存器里是正在解析的日志文本（`x11..x17` 为 ASCII、`x8=0xfefefefefefefeff`
是 strlen 的零字节掩码），说明崩溃发生在 **awk 退出清理**阶段，不是读行阶段。

### 11.4 复现与对照（决定性）

用 log_keeper `delta()` 的**原样脚本**、同一份 4MB `/data/gw/logs/syslog.log`、
同一锚行（末行），在设备上循环：

| 变体（锚点=文件末行，数组始终为空） | 400 次运行 |
|---|---|
| 原版：`{ n=0; split("", B); hold=1; next }` | **4 次 SIGSEGV** |
| `{ n=0; delete B; hold=1; next }` | **4 次 SIGSEGV** |
| `{ n=0; hold=1; next }`（从不创建数组） | **0 次** |

**第二轮修正（关键）**：把锚点移到文件**中段**（真实生产形态：锚点后还有新行，
`B[++n]=$0` 会把 ~18000 行装进数组），仅去掉 `split` 的版本 **300 次仍崩 2 次**。
所以当年的结论不是"别清空数组"，而是 **这个 busybox awk 只要运行期存在数组，
退出清理就有约 1% 概率 NULL 解引用**——空数组和满数组都会踩到，崩溃率与堆布局
相关、与输入内容无关。数组无法"小心使用"，只能移出热路径。

> ⟦复核⟧ 这段因果已被 §16.7 降级为**未证实**：4/400 与 2/300 都是在剧集期做的，
> 无法区分"awk 数组缺陷"与"注入块击中 node 指针"；"约 1%"也不是稳定速率
> （同一二进制在不同剧集下 0–1%）。保留的只有**工程结论**：把 awk 数组移出
> 热路径（logcut）确实消除了这条受害者路径，且顺带少 spawn 一次。

### 11.5 修复

| 文件 | 版本 | 变更 |
|---|---|---|
| `gw/src/logcut.c` → `gw/bin/logcut` | 1.0 | **自建静态锚点截取器**：单遍扫描 + 一个可增长行缓冲，记录"最后一次精确匹配锚行"之后的光标，再把文件尾部拷到 stdout；无数组/无 printf/无 locale；`--check`/`--selftest` |
| `gw/log_keeper.sh` | 2.7 | `delta()` 改调 `logcut --after-last`（awk 彻底退出该路径）；`stream()` 去掉 `grep -Fqx` 预检，改看 logcut 退出码（每轮少一次 grep spawn） |
| `tools/selftest.py` | 2.57 | `t_batch4_awk_arrays`：logcut 在位 + `--selftest` PASS + log_keeper 不再含 awk delta + 全脚本无 `split(""` |
| `tools/deploy.py` | 2.25 | MANIFEST + `gw/bin/logcut` |

语义等价性：旧 awk 对新 logcut，同一 4MB syslog + **文件中段锚点**，输出
**逐字节相同**（484783 B / 498854 B 两次抽样）。logcut 还有一处更严格：锚点按
原始字节比较，而 `awk -v` 会解释反斜杠转义（日志里的 `\\` 不再被吃掉）。

### 11.6 仍未闭环

1. **ip（17 次）**：iproute2 静态件，与 busybox 不同源；需单独 core 窗口 + 循环
   `ip -4 addr show` 复现（预算 ~1e-3/次）。若同样落在退出清理，可考虑把
   led_mgr/wan_agg 的地址读取改成 /proc 解析或加"崩溃重试"。
2. **sh/grep/pidof/ping/ls/sleep**：单次或低频，尚无 core；`sleep` 的崩溃提示
   可能存在**启动期**缺陷（与 printf 无关），需要窗口期撞上才能定位。
3. **logd / thermal_core / wpad**：厂商二进制，只能缓解（降噪/减少 spawn），
   不能从源码根治。
4. **取证副作用**：gdb 自身也在家族里（3 次），且高频 spawn 会卡死 dropbear
   （见 AGENTS 陷阱表）。

### 11.7 ip 的第二份 core（本轮已取证，写入者未定位）

同一窗口机制循环 `ip -4 addr show`，**2703 次命中 1 次**（`core.ip.23057`，581632 B），
与 NE 普查里的 17 次同族：

```
signal=11 si_addr=0x157c0   pc=0x10a35c0  ldrb w8,[x0]   x0=0x157c0
lr=0x10a3818（fnmatch 内部递归）
```

- 调用链：`ip`（`ip/ipaddress.c:ifa_label_match_rta`）→ `fnmatch(filter.label, label, 0)`。
  崩溃指令在匹配器里读模式串首字节；**模式串指针 = `filter.label` = 0x157c0**。
- `filter` 在 `0x10f1000`（`adrp x26,#0x10f1000`），`filter.label` 位于 `+0xe28`
  （.bss，初始为 0）；源码里只有 `filter.label = *argv`（`-label` 参数）会写它，
  而本条命令没有 `-label`。**即：一个应为 NULL 的全局被写成了小整数 0x157c0**。
- 0x157c0 = 88000，形态更像长度/偏移而不是指针；与 awk 的 NULL 不同，这里更像
  **相邻全局被越界写**。写入者尚未定位（需要对该地址下硬件观察点复现一次）。

**对 `ip` 的处置建议**（本轮未改代码）：`ip` 的读路径（`show`）是幂等只读，
可加一层"崩溃即重试一次"的包装降低运维影响；根治要等写入者定位后重编
iproute2（我们已能从源码重建，build_static_ip.sh 在位）。

## 12. 2026-10-21 第四轮（历史定性，已被 §16 推翻）："机制未知"崩溃 = musl printf/stdio

> ⟦复核⟧ **本节定性已被 §16 推翻**（musl 不是缺陷方，是受害者）。保留它是
> 为了记录"最小复现器 + 分层二分"的方法，以及那些**仍然有效**的实验事实
> （`?` 组排除、30 万金丝雀、sh 的两份 core、2 秒复现器）。凡"musl 缺陷"的
> 措辞一律按 §16 读作"污染页被 printf 解引用"。

> 本轮只做取证，不改代码。目标：回答"到底还有没有一类我们没命名的崩溃"。
> ⟦复核⟧ 当年的结论句是"**有，但它不是环境/硬件，而是 musl printf/stdio 的
> 同一个缺陷类**"；现在应读作"**有，而且它仍是同一个主机制**（§16）"。
> 已做出 20 行、2 秒内必崩的最小复现器，并把它和 logc/sh 的旧 core 对齐——
> 复现器本身有效，是**剧集探测器**。

### 12.1 `?` 组：不是崩溃（排除）

3 个 `?` 事件（10-20 08:23/08:51/09:43）的 core_meta 文件**全部字段为空**：
无 btime、无 comm/exe/args/maps、fds=0、**连 `gid`（内核第 4 个参数）都缺失**。
交叉 aee 台账：这三个时刻**没有任何 NE 记录**（附近只有 08:07/08:16/09:30/09:54）。
→ 它们不是内核触发的 coredump，而是 core_meta.sh 的手工/测试调用（缺 `%g` 参数）。
**从崩溃普查中剔除。**

### 12.2 先排除"与程序无关的背景崩溃率"

金丝雀：一个只做 `return 0` 的静态 musl 程序（3944 B），在设备上循环 **30 万次**：

```
canary noop: 300000 次, 0 崩溃  -> 背景率 < 1e-5（95% CL）
```

所以"随便什么进程都会随机崩"的假设不成立；后面的崩溃都能归到具体代码路径。

### 12.3 `sh` 组：复现成功，两份 core 都指向 musl stdio/printf

- 复现器 A：`sh` 循环执行 `"$@" >/dev/null 2>&1` + 每 500 轮 `echo > file`，
  **34,500 轮时 shell 本体 SIGSEGV**；去掉 echo/算术、只留 fork/exec 也能复现
  （300k 轮内命中）；纯 shell 算术+echo、**不 fork 的 300 万轮 0 崩溃**。
- core #1（pid 4479）：`si_addr=0`、PC 在 `memcpy`，调用者 `__fwritex`：
  `f->wpos == NULL` 却仍走 `memcpy(f->wpos, ...)` —— 栈上 FILE 结构被写坏。
- core #2（pid 2404）：`si_addr = 0xffffffffffffffd8 = -40`，PC 在 `pop_arg` 的
  va_arg 取值路径，`ap->__gr_top = 0`、`__gr_offs = -40` —— **与 logc v1.3 的
  崩溃签名逐字段相同**（见 §1/§10）。

### 12.4 最小复现器（决定性）

```
c
char b[24];
for (unsigned long i = 0; i < 200000000UL; i++)
        snprintf(b, sizeof b, "%ld", (long)i);
```

- 静态编译，**2 秒内 SIGSEGV**（`arg.i = 1,566,894` -> 约 1/1.6e6 次调用）；
- `-O0` / `-O1` / `-O2` **全部崩溃**（0–1 秒）-> 不是优化/代码生成问题；
- 崩溃点：`pop_arg` 的 va_arg，`ap->__stack` 是小整数、`__gr_top=0`；
  整个 va_list（32 B）被写成 `{小整数, 0, 0x1c28416e00001180, 0}`。
- 该值的高 32 位 `0x1c28416e` 与 logc 旧 core 的 `__stack` 高 32 位**完全相同**
  （`0x1c28416e00000680`）-> 同一个缺陷、同一段数据形态。

gdb 观察点（设备自带 gdb）：
1. 在 `vfprintf` 的 `va_copy(ap2, ap)` 处命中：**复制进来的源 va_list 已经是坏的**
   （旧值 0x7ff5908bc0 = 栈指针，新值 0x22733 = 小整数）；
2. 帧布局：`nl_type` 在 `ap2` 下方 **0x30 字节**（12 个 int）处 ——
   `nl_type[12..15]` 恰好压在 `ap2.__stack/__gr_top` 上（与 §10 的候选一致）。

**尚未钉死**：具体是哪条写指令把 ap2 改坏的。⟦复核⟧ 当年列的候选
"`nl_type[12..15]` 压在 ap2 上"**不成立**：musl 的 `nl_type` 只有
`NL_ARGMAX+1=10` 个 int，且非位置参数格式（`%ld`/`%0*lld`）根本不会写
index>0 的槽位。**定性也已改**：不是 musl 缺陷，而是注入（§16）；
2 秒复现器是"最灵敏的剧集探测器"，不是"musl 有 bug"的证明。

### 12.5 家族重新归类

| 崩溃 | 机制 | 状态 |
|---|---|---|
| logc（已修） | musl `strftime->snprintf->vfprintf` va_list | v1.4 去 printf，已验证 |
| **sh** | **musl vfprintf/__fwritex（本轮实锤 + 最小复现器）** | 未修（busybox 内部无法绕过） |
| grep / pidof / ls / ping | 同上（都经 musl stdio 输出） | 高度同源（待各自 core 确认） |
| sleep（厂商 busybox） | 疑同上（未取到 core） | 待厂商 `sleep 0` 金丝雀确认 |
| awk | busybox 数组释放路径 NULL（独立） | v2.7 已移出热路径 |
| ip | `filter.label` 被写成小整数（独立，疑越界写） | 未修 |
| hostapd/logd/thermal_core/gdb | 厂商动态 musl；机制未逐个取证 | 不可替换/低优先 |
| `?` | 非崩溃（手工 core_meta 调用） | 已排除 |

### 12.6 对方案的含义（重要）

> ⟦复核⟧ **本小节整段作废**（"修 musl 的 printf/stdio"路线）。§16.7 已给出
> 再评价：去 printf 化只作为缓解，组件替换冻结，根修在页回收链（§16.6/§17.5）。

1. **修复优先级反转**：真正的大头不是"换组件"，而是 **修 musl 的 printf/stdio**。
   一个补丁可以同时消掉 logc 类、sh、grep、pidof、ls（约 40/47 次/天），
   而逐个替换 applet 只能覆盖其中一部分且成本高得多。
2. **最小复现器让 musl 补丁变得可行**：2 秒一次验证，可以快速迭代
   `vfprintf.c` 的候选修复；修好后用同一 musl 重编 busybox/ip/我们的工具，
   整个静态工具面一次性受益。
3. **厂商动态二进制（hostapd/logd/thermal_core）不受益**（它们链接厂商 libc），
   仍靠恢复/监督兜底；这部分维持原方案。
4. **替换方案降级为"第二优先级/兜底"**：netq、logd、小程序替换仍有价值
   （可控性、可维护性），但不再是"治崩溃"的主线；`sh` 替换在 musl 修好后
   也不再必要。

### 12.7 P0 实施记录（2026-10-21 深夜）：把复现器变成补丁的尝试

目标：用 2 秒复现器做"改一版、验一版"的迭代。方法：把 musl 的
`vfprintf.c` 单独编成对象（zig，aarch64-linux-musl），显式链接在 libc.a
之前覆盖同名符号。未打补丁的覆盖版仍然崩 → 覆盖链有效。

| 尝试 | 结果 |
|---|---|
| 诊断链：snprintf/vsnprintf/vfprintf 各加 va_list 校验 | 校验本身被编译器"取地址即拷贝"干扰；加强校验后报 `DIAG source-entry`：**va_list 进 vfprintf 时已坏** |
| 换**上游 master** 的 `vfprintf.c` | **10/10 仍崩** → 缺陷不在该文件的逻辑里（或 master 仍未修） |
| `vsnprintf` 里先 `va_copy` 到局部再转发 | **10/10 仍崩** → 不是调用边界的结构体拷贝单独造成的 |
| 变体：目标缓冲 4096 / `%d` / 固定值 | 各 **5/5 仍崩** → 与值、格式、目标缓冲大小无关 |

结论：污染发生在 **va_list 的传递/构造环节**（snprintf 的 `va_start`、
结构体按值传递、ABI 布局），而我们用"取 `&ap` 再校验"的方式观测不到——
取地址会让编译器物化副本，检查的是副本。下一步应：
1. 用 zig 从源码构建 musl（可控 CFLAGS），先对比 **libc 自身 -O0/-O1/-O2**
   （此前只换过程序的优化级别，libc 始终是 zig 预编译的 -O2）；
2. 或在 `snprintf` 内用**不取地址**的方式（memcpy 到局部再比较）校验，
   或对 va_list 内存下硬件观察点，钉死写入指令；
3. 拿到写入者后再决定补丁形态（musl 侧 vs 编译器侧）。

### 12.8 本轮结论汇总与证据索引（2026-10-21 收尾）

> ⟦复核⟧ **本小节的"最终分类"已过时**（把 sh/grep/pidof/ls 归为"musl stdio 输出面"、
> 把 ip 归为独立越界写）。现行分类见 §0.5 与 §16.3；本节只保留证据索引与
> P0 尝试记录（那些实验本身仍然有效）。

**一句话**：崩溃家族的主干已经定性为 **musl printf/stdio 的 va_list 缺陷**
（2 秒复现器），logc/awk 两条已闭环；sh/grep/pidof/ls 同源待补丁；
ip 是独立缺陷；"机制未知"里的 `?` 组根本不是崩溃。

#### 最终分类

| 崩溃 | 机制 | 状态 |
|---|---|---|
| logc | musl `strftime→snprintf→vfprintf` va_list | **已修**（v1.4 去 printf；零崩溃约 3h） |
| awk | busybox 数组释放路径 NULL | **已修**（logcut v1.0；A/B 10:0） |
| sh | musl vfprintf/__fwritex（两份 core、最小复现器） | **未修**（P0 进行中） |
| grep / pidof / ls / ping | 同上（musl stdio 输出面） | pidof/pgrep **已替换**（procmatch）；其余待 P0 |
| sleep（厂商 busybox） | 疑同源（未取到 core） | 待厂商 `sleep 0` 金丝雀确认 |
| ip | `filter.label` 被写成 0x157c0（独立，疑越界写） | 未修（P1 netq 计划中） |
| hostapd/logd/thermal_core/gdb | 厂商动态 musl；未逐个取证 | 不可替换/靠恢复 |
| `?` | **不是崩溃**：core_meta 手工/测试调用（全字段空、缺 gid、aee 无 NE） | 已排除 |
| 背景率 | 静态 `return 0` 金丝雀 30 万次 0 崩 | **不存在程序无关背景率** |

#### 证据索引（本地存档，不入仓）

`_local/archive/stability_2026-10-21/`
- `cores/`：crash_awk / core_ip / sh / sh2 / pf（5 份 core）
- `events/`：ne_events.tsv、meta.tar、evidence.tar、soak.tsv（v1.3 vs v1.4 A/B）、
  crash.72.log（logc gdb 现场）、crash.raw（回放 10/10 不复现）
- `repro/`：pfcanary 与诊断/候选修复源码
- `sessions/`：取证与 gdb 观察点脚本

**可复现资产（入公开仓，oneoff 不登记）**：
`tools/oneoff/printf_repro/`（pfcanary + 变体 + 覆盖 libc 的构建说明）。

#### P0 尝试记录（均仍崩）

| 尝试 | 结果 |
|---|---|
| 覆盖 libc 的 `vfprintf.c` | 未打补丁版仍崩 → 环有效 |
| 上游 master `vfprintf.c` | 10/10 崩 |
| `vsnprintf` 局部 `va_copy` 再转发 | 10/10 崩 |
| 4096 缓冲 / `%d` / 固定值 | 各 5/5 崩 |
| 诊断链 | 报 va_list 进 vfprintf 时已坏；`&ap` 会导致编译器物化副本，观测失真 |

**下一步**：从源码构建 musl，对比 **libc 自身** `-O0/-O1/-O2`；用不取地址的
字节比较或硬件观察点钉死写入指令；再决定补丁形态。

#### P1 进展（本轮已落地）

`gw/bin/procmatch` v1.0（静态、无 printf 的 pidof/pgrep）：
- pidof 10 个名字、pgrep -f 6 个模式、pgrep -x/默认 全部与 busybox 一致
  （多 PID 顺序不同，不影响调用）；
- `toolchain_init` v1.1 农场覆盖 pidof/pgrep；selftest v2.58；系统自检 **33/33**；
- 行为修正：busybox `pgrep -x` 漏存活进程，替换后 rc.extend 不再重复拉起
  dropbear、webs_revive 的 cfgmgr/iotagtd 守卫生效（已逐调用点评估）。

#### 收尾快照（设备，2026-10-21 23:15 CST）

```
up 2:44, load ~7.5
logc 1.4 / logcut 1.0 / procmatch 1.0
/data/gw/sbin/pidof -> /data/gw/bin/procmatch
/data/gw/sbin/pgrep -> /data/gw/bin/procmatch
logc_crash/ = 133（无新增）
ne_events  = 129（其中约 41 条是 P0 金丝雀实验，不是产品故障）
core_pattern = |/data/gw/core_meta.sh %p %s %u %g
```

#### 本轮提交

- 公开仓：`e3ba151`（第四轮定性）、`afcfad9`（procmatch + 农场）、
  `fa9dc54`（P0 记录 + P1 进展）、本次（结论汇总 + oneoff 复现包）。
- 私有仓：`35c5933`（L31）、`bc8a292`（L32）。

#### 仍未闭环

1. musl va_list 写入者（P0 主线）；
2. ip 的越界写写入者（P1 netq 兜底）；
3. `sleep` 同源性确认；
4. 厂商动态件（hostapd/logd/thermal_core）不可替换，靠恢复。


## 13. 2026-10-22 凌晨：P0 攻坚 —— 从复现器到"崩溃消除"的硬化补丁

本轮目标是把 §12 的"机制定性"推进到可交付形态。⟦复核⟧ 当年的结论要改两处：
① 崩溃可以用一个 musl 侧 guard **拦截**（对重新链接的二进制不再以 SIGSEGV 出现），
但不是"消除"——污染仍然发生，guard 只是不去解引用；
② "窗口已压到 `va_copy` 之前"不成立（§13.2 #6 复核：只能证明到 `after_va_copy`
时已坏）。写入者仍未钉死。

### 13.1 方法：先校准仪器，再谈结论

| 仪器 | 作用 | 位置 |
|---|---|---|
| `p0probe` | 10 个模式一次跑完：自有可变参数 / printf 各形态 / 控制组 | `tools/oneoff/printf_repro/` |
| `p0probe2..5` | 进程内 SIGSEGV dump（寄存器、PC、PC 处 32 字节、栈窗口、按寄存器指针取区） | 同上 |
| `p0cal` | **仪表校准**：用已知寄存器/栈炮制一次 fault，逐字段核对 dump | 同上 |
| `layerchk/` | 用本地副本覆盖 musl 的 `snprintf/vsnprintf/vfprintf`，在每层加 va_list 检查点 | 同上 |
| `pfscope` | 同一 guard 套在自有可变参数上，比较污染率 | 同上 |

校准中发现并修掉的**仪器自身缺陷**（否则后续结论全是假的）：

1. 行缓冲 `char b[96]` 装不下 173 字节的 32 字节行 → 处理器把 dump 写花；
   改 `b[256]` + 固定两位十六进制。
2. `mcontext` 字段名在 musl aarch64 上是 `regs[31]`/`sp`/`pc`/`fault_address`。
3. 取 `&ap` 对**参数位**的 va_list 会让编译器物化副本（实测 `&ap` 与被调方
   看到的对象相差 0x200）→ 只在"局部 va_list"或"本来就是指针参数"处校验。
4. 信号处理器的 `SA_ONSTACK` 在该设备上未生效（`sp_in_alt=0`），
   但数据段 altstack 已申请，后续以"不依赖 altstack"的方式取样。

校准结果（`/data/p0/cal.txt`）：`si_addr=0x3000`、`fault_address=0x3000`、
`x10/x11=0x1111…`、`x12=0x3000`、PC 处就是那条 `ldr x13,[x12]`、栈窗口里能读到
预置的 `0x33…`/`0x11…` 图案 —— 仪表可信。

### 13.2 决定性事实

| # | 事实 | 证据 |
|---|---|---|
| 1 | **自有可变参数不崩**：`vsum(1,i)`/`vsum(9,…)`/`vderef` 各 5e7 次 0 崩溃；`vsum` 3e8 次 + 同 guard 检查 **bad=0** | `result2.txt`、`p0devices/` |
| 2 | **printf 家族全崩**：`%ld`/`%s`/`%e`/`sprintf`/`snprintf(n=0)`/常量参数/静态缓冲 | `result2.txt` |
| 3 | **纯字面量不崩**：`snprintf(b,24,"abc")` 5e7 次通过 → 与"整数转换路径"强相关 | `result2.txt` |
| 4 | 崩溃点恒定 `pop_arg`（type=13=PA_LONG）`ldr x8,[x8]`，x8 = `__gr_top+__gr_offs` 或 `[ap]` | 四份 probe4 dump，PC 符号解析 |
| 5 | `ap == &ap2`（`delta=0`）：pop_arg 用的就是 vfprintf 自己那份 va_list，**不存在指针传错** | `rec.log` |
| 6 | ⟦复核⟧ **第一个变坏的检查点是 `after_va_copy`**——只能说明"到这一步已坏"，**不能**说明"进 vfprintf 时已坏"；`crash.72.log` 反证调用方 `snprintf` 的 ap 健康、只有 ap2 坏 | `cp.log`、`crash.72.log:71/85` |
| 7 | 健康基线：`{__stack=栈地址, __gr_top=栈地址, __vr_top=栈地址, __gr_offs=-48, __vr_offs=-128}` | `pfchk3` baseline |
| 8 | 坏块形态：**16 字节**被写成类 `{u32 计数, u32 0x680, 0, 0}` 的值，落在偏移 0..15 或 16..31 都见过 | `layer.txt`、`dump.*` |
| 9 | 污染率（guard 命中/调用）⟦复核⟧：15/2e8=**7.5e-8**、101/2e8=**5.1e-7**、60/2e8=**3.0e-7**、22/3e8=**7.3e-8** → 区间 **0.7–5e-7**，随剧集变化，不能写死单值 | `ab.log`、`rec.log` |
| 10 | SIMD/拷贝代码生成无关：`-mgeneral-regs-only` + 逐字节拷贝的"无副本链"3×1e8 通过（对照同样通过，样本不足以证明差异） | `n.log`/`g.log` |

**对 §12 的一处更正**：`__vr_top = 0x1c28416e00000680` 曾被当作"污染指纹"，
但本轮在各类坏块里看到同一个 64 位值的**高 32 位就是循环计数器**（如
`0x0998010a`、`0x1c28416e`），且它在 va_list 的不同偏移出现过。因此指纹
不成立，判据只能是结构性的：**四个字段是否都指向用户态可访问范围、两个偏移是否
都为负**。这同时解释了为什么 `sh`/`grep`/`pidof` 等"看起来不同"的崩溃其实是同一形态。

### 13.3 硬化补丁（本轮可交付物）

`layerchk/h_vfprintf.c`：musl `vfprintf.c` 原样 + `pop_arg` 入口 5 行 guard

```c
#define P0_VA_SANE(ap) ((unsigned long)(ap)->__stack >= 0x1000UL && \
    (unsigned long)(ap)->__gr_top >= 0x1000UL && \
    (unsigned long)(ap)->__vr_top >= 0x1000UL && \
    (ap)->__gr_offs < 0 && (ap)->__vr_offs < 0)
...
static void pop_arg(union arg *arg, int type, va_list *ap)
{
	if (!P0_VA_SANE(ap)) { __p0_va_guard_hits++; arg->i = 0; return; }
	...
```

- 阈值 0x1000 低于 `mmap_min_addr`，正常的栈/寄存器保存区不会被误判。
- ⟦复核⟧ **`__gr_offs<0 && __vr_offs<0` 这一半不成立**：合法 va_list 在取完
  8 个通用/浮点寄存器后 offs 就是 0（pop_arg 反汇编 0x51e8c–0x51ec8），
  guard 会把第 9 个及以后的参数当成污染、写成 0。所以它是"**拦截崩溃**"，
  代价是"长参数列表的后续参数全变 0"，不是 1e-8 的错误数字。
- 该补丁从未部署；§16.7 已把它归档为技术储备，不再有部署计划。
- **链接方式**（关键）：把该文件编成 `hardened_vfprintf.o` 放在 libc **之前**，
  `snprintf → vsnprintf → vfprintf` 整条链自动获得保护：

```sh
zig cc -target aarch64-linux-musl -O2 -D_GNU_SOURCE \
  -I<musl>/src/internal -I<musl>/src/include -I<musl>/include \
  -I<musl>/arch/aarch64 -I<musl>/arch/generic \
  -c hardened_vfprintf.c -o hardened_vfprintf.o
zig cc -target aarch64-linux-musl -O2 -static prog.c hardened_vfprintf.o -o prog
```

A/B（同一台设备、同一循环、2e8 次 `snprintf("%ld")`）：

| 构建 | 结果 |
|---|---|
| 硬化 | `survived calls=200000000 guard_hits=15`，rc=0（另两组 101/60 命中同样存活，见 `ab.log`；命中数随剧集变化） |
| 控制（stock libc） | `Segmentation fault (core dumped)`，rc=139 |

同一补丁也解释了本轮"为什么 §12.7 的十次尝试全部失败"：那些尝试都在改
`vfprintf.c` 的**逻辑**，而坏值在进入 `vfprintf` 之前就已经在 va_list 里了；
只有"先校验再解引用"才有效。

### 13.4 仍未闭环（诚实清单）

1. **写入者**：窗口已压到"调用方 va_start 之后、vfprintf va_copy 之前"，即
   32 字节 va_list 的**按值传递副本**；坏块是 16 字节、内容含循环变量形态。
   下一步是把检查点推进到 `vsnprintf` 入口/出口与调用方 outgoing 区，
   或对该 outgoing 区下硬件观察点（PTRACE `NT_ARM_HW_WATCH`）。
2. **是否与编译器有关**未定：本轮所有实验都用 zig/clang 构建；gcc 侧只有历史
   core 的间接证据（Alpine busybox 同签名）。
3. **busybox / iproute2 无法重新链接**，硬化补丁对它们无效 → P1（换组件）仍是
   这两块的唯一出路。

### 13.5 证据索引（本地，不入仓）

`_local/archive/stability_2026-10-21/p0devices/`：`rec.log`（ap==ap2 + 坏字）、
`cp.log`（首坏检查点 = after_va_copy）、`ab.log`（硬化 15 命中 0 崩溃 vs 控制组
段错误）、`pchk.log`（layer 检查点原始记录）、`n.log`/`g.log`（SIMD A/B）、
`cal.txt`（仪表校准）、`snapshot.txt`。
`_local/archive/stability_2026-10-21/p0dumps/`：probe4/probe5 的 9 份现场 dump。
工具源码：`lg6151m-public/tools/oneoff/printf_repro/`（`p0probe*.c`、`p0cal.c`、
`layerchk/`）。

### 13.6 普查注记：本轮探针自身在 ne_events.tsv 里留了 6 条（勿计入产品故障）

> ⟦复核⟧ 原表只列了 4 条（2 探针 + 2 产品），漏了同窗口的 4 条探针：
> `pfscope` 8702/11717、`pfctl` 11811（以及更早的 `/tmp/pf_*`、`/tmp/v_*`）。
> 00:03–00:11 的实际构成是 **6 条探针 + 2 条产品**。

收尾时 `ne_events.tsv` 尾部（设备本地时间 2026-10-22 00:0x–00:2x）：

| pid | comm | 归属 |
|---|---|---|
| 8702 / 11717 | `pfscope` | **本轮探针**（自有可变参数 guard 版） |
| 11811 / 21168 | `pfctl` | **本轮探针**（对照组成员，预期崩） |
| 22319 | `pfcp` | **本轮探针**（未加 guard 的检查点版本，预期崩） |
| 12033 | `wc` | 产品侧：busybox stdio 家族，`wc -l` |
| 18302 | `grep` | 产品侧：wan_agg 的默认路由检查 |

结论两点：① 探针崩溃已被 core_meta 记录，做普查时必须排除——**规则不止
`exe=/data/p0/*`**：更早的 P0 探针跑在 `/tmp/pf_*`、`/tmp/v_*`（§14 的排除规则）；
② 同一窗口内产品侧仍有 `wc`/`grep` 崩溃 —— 家族仍在活动，本轮补丁尚未部署到
那些二进制（它们没有重链接）。`cores/meta` 目录已达 120 文件上限（core_meta 的
保留策略），因此新崩溃不再新增文件，只有 TSV 行。

## 14. 崩溃普查与速率（唯一权威表，2026-10-22 收关自 REPLACEMENT_FEASIBILITY §1 迁入）

> ⟦复核⟧ 本节已按 2026-10-22 复核重算。**旧表的 69/46.9/d 把 3 条非崩溃和
> 1 条自测算了进去**；正确口径是 **65 次产品崩溃 / 35.3 h = 44.2/d**。
> 复核值与原值的差异逐项见 §0.0.2-C9/C10/C11。

干净窗口 2026-10-20 08:16 → 10-21 19:35（35.3 h；TSV 共 69 行）：

| 组件 | 归属 | 次数 | 速率 | 用户可见性 |
|---|---|---|---|---|
| awk | 自建 busybox | 27 | 18.4/d | 低（日志镜像缺口；**已修**，见 §11） |
| ip | 自建 iproute2 | 17 | 11.6/d | 低（守护单次读数失败，下一轮重试） |
| sh | 自建 busybox | 5 | 3.4/d | 中（守护整轮中断，watchdog ≤1 周期重启） |
| grep | 自建 busybox | 4 | 2.7/d | 低 |
| pidof | 自建 busybox | 4 | 2.7/d | 低 |
| hostapd(wpad) | 官方 | 2 | 1.4/d | **高**（WiFi 全断） |
| busybox（其他） | 自建 busybox | 1 | 0.7/d | 低（`sh led_mgr.sh`） |
| iptables | 官方(slot B xtables) | 1 | 0.7/d | 低 |
| logread | 官方 | 1 | 0.7/d | 低（仅 aee 转储时） |
| ping / ls / sleep | 自建/官方 busybox | 各 1 | 各 0.7/d | 低 |
| **产品崩溃合计** | | **65** | **44.2/d** | |
| （不计入）`?` | — | 3 | — | **不是崩溃**：core_meta 手工/测试调用（§12.1） |
| （不计入）自测 | — | 1 | — | `busybox sh -c kill -SEGV $$`，人为触发 |

派生口径（**引用速率时用下面几条，不要各自重算**）：

- awk 的 27 次全部发生在 `log_keeper` v2.7 之前 → 修复后**当前基线 ≈ 25.8 次/天**
  （38 次 / 35.3 h）。
- **不再有"A 类覆盖 40/47"这种说法**：旧 A 类已并入主机制（§16），按组件口径
  awk 27/65、ip 17/65 是最大的两块；"先修库、再换件"的量化依据作废（§16.7）。
- 探针/复现/自测造成的 core 与 aee 事件必须扣除，**排除规则**（缺一不可）：
  `exe` 前缀 `/tmp/pf_*`、`/tmp/v_*`、`/data/p0/*`、`/data/repro/*`（§19 的
  独立复现探针与受害者）；`args` 含 `busybox awk`
  （§11.4 的复现循环）或 `kill -SEGV`（自测）；`comm=?`（§12.1 非崩溃）。
- **台账口径必须注明**：core_meta TSV 与 aee `db_history` 不是同一个集合。
  同窗 aee 63 条 = TSV 69 − 5（3 条 `?` + 15:20 的 awk + 18:09 的 pidof）——
  **aee 漏了 2 条真实产品崩溃**，不能拿它当超集；反过来 TSV 也会漏掉没有 core
  的内核 NE（§4 的监控缺口）。引用速率时写"core_meta 口径"或"aee 口径"。

## 15. 历史取证细节（2026-10-22 收关自 INCIDENT_2026-10-19 §2.2/§2.3 迁入）

> 这些是 2026-10-19 现场的原始取证。⟦复核⟧ 机制解释**以 §16/§17 为准**；
> 本节只保留手法与判据（内核 fault 行怎么读、core 怎么抓、栈缓冲怎么定位）。

### 15.1 内核 fault 行的正确读法

arm64 打印格式是 `unhandled exception: DABT`，**不是** x86 的 `segfault at`：

```
[46869.933501] logread: logread[18115]: unhandled exception: DABT (lower EL),
  ESR 0x0000000092000006, level 2 translation fault in libc.so[7f9280d000+7b000]
```

- `[base+size]` 是**故障指令所在 VMA**，不是故障地址（常见误读）。
- 持久 dmesg 镜像里 15 条分类：logread 13 条（故障指令在 libc.so）+ 1 条（在自身 text）
  + logd 1 条（在 libubox.so）——**同一家族可以跨多个进程/库**。

### 15.2 未加密 core 的获取（受控窗口）

临时 `echo '/tmp/core.%p' > /proc/sys/kernel/core_pattern` + `ulimit -c unlimited`，
复现后立刻恢复 aee 管道。三份 core 签名一致：

| 项 | 值 |
|---|---|
| 信号 | SIGSEGV / `si_code=1`(SEGV_MAPERR) |
| PC | `/lib/libc.so +0x51ffc`（三次相同） |
| 故障指令 | `ldr x0, [x3]`（x3 野指针） |
| `si_addr` | 0x2475b / 0x25746 / 0x14f1b（三次不同，均为小整数） |
| 栈回溯 | `logread 0x403590 → ctime → asctime_r → snprintf → vfprintf` |

反汇编对上：`0x403590` 就是 `bl ctime`；每行输出的 `Mon Oct 19 …` 正是 ctime 格式。
（今天回看：这条回溯已经指到 A 类机制，只是当时按"记录内容"方向解释。）

### 15.3 两条"看现场"的经验

- **栈缓冲区内容定位"崩在哪一条记录之后"**：崩溃前最后一条已成功格式化的行在
  `fp+0x378` 的 0x480 缓冲区里（`Mon Oct 19 04:11:07 2026 daemon.info thermal_core…`），
  其后的 ` MRO-W00` 是下一条的片段 ⇒ 崩在它之后；输出文件只 flush 到那里是
  **stdio 缓冲假象**，不是"开机 3.4 s 就崩"。
- **16 KB 输入缓冲的边界截断**：core 里一块 16 KB 匿名映射是 syslog 行的滑动窗口，
  最后一行在边界被截断。当年据此推测"边界触发"，**该假设已被 §12 的金丝雀/回放证伪**
  （回放 10/10 不复现、清环只改变调用频次）——记录在此以防有人重走。

### 15.4 实验矩阵（当年实测，可与 §12/§13 对照）

| 实验 | 结果 | 当年结论 | 今天读法 |
|---|---|---|---|
| `TZ=UTC` 下 100 次 logread | 仍崩 1 次 | 与时区无关 | 成立（与 A 类的"频率"一致） |
| `dmesg -c` 清内核环后跑 | 仍崩 | 读的是 logd 的 syslog 环 | 成立 |
| 重启 logd 清环后 2500 次 | 0 崩 | 触发记录随开机日志驻留 | **只说明频次下降**，不是根因 |
| `logread -l 200` 2000 次 | 0 崩 | `-l` 跳过大部分格式化 | 成立（少一次 printf 就少一次机会） |
| `ip -o link` ×300 / `true` ×300 | 0 崩 | 不是"每次 exec 随机崩" | 成立 |
| 注入 2000 字符 logger 消息 | 行被截到 1040 B，未崩 | 超长行不触发 | 成立 |
| 静态 memtest 256 MB×3 遍 | 0 位翻转 | 不是 DRAM 损坏 | 成立（与 §12.2 金丝雀一致） |
| 同一 4 MB 文件 60 次 md5 | 哈希唯一 | 不是读路径数据损坏 | 成立 |
| 故意空指针（crashme） | 内核打印 DABT + core | 内核 fault 打印正常 | 成立 |

## 16. 2026-10-22 收官轮：机制反转 —— 全家族 = 外部主控经回收页注入

> 本轮把 §10–§13 的定性（"musl printf/stdio va_list 缺陷"）**推翻并重建**。
> 结论一句话：**没有任何一个被怀疑过的软件组件（musl、busybox、iproute2、
> 我们自己的代码）有错；全部崩溃是"外部主控把 16/32 字节记录写进被回收
> 复用进用户进程的物理页"这一个机制的不同表现。** printf 家族只是最高频
> 解引用被污染内存的路径，因而是最常见的爆发点（选集效应，§16.4）。
> 取证资产：本地 `tmpfiles/p0x/`（探针源码 + ne_events 快照）；设备侧
> `/data/p0x/`（memtruth/pageharvest/哨兵，oneoff 性质不入仓）。

### 16.1 反转的触发点：固定地址观测 = 0 命中

新探针 `memtruth`（静态、全 printf-free、纯 syscall 报告）对**同一组固定地址**
做高频写+读校验，共观测：

| 模式 | 规模 | 结果 |
|---|---|---|
| 栈/静态/mmap 金丝雀 ×3 | 各 2e8 次写读循环 | **0 命中** |
| 256KB 预填充纯读校验 | ~1e8 次读 | 0 |
| 同物理页双虚址（alias） | ~5e7 次读 | 0 |
| 4 CPU 分别绑核 | 各 5e7 | 0 |
| 双核并发（ro+stk） | 2e8 + 6.5e7 | 0 |
| mprotect 只读陷阱页（600s） | 4.1e8 轮读 | 0 命中、0 SIGSEGV |
| 深层闲置栈金丝雀（4KB–256KB 深，600s） | ~7e5 轮 | 0 真实命中 |

同时段对照：P0 会话（23:31–00:16）里同类 printf 循环 100% 在秒级崩。
**结论**：污染不是"按地址均匀分布的随机内存故障"（否掉 DRAM 单元坏 /
CPU 缓存路径坏 / 按访问率计费的读写故障），而是**有剧集时段（episode）、
且只落在特定物理页上**的现象。此前 §13 的 n.log/g.log 对照组"样本不足"
的疑点（3×1e8 全过）由此得到解释：那些运行恰逢平静期。

### 16.2 九条证据（E1–E9，机制闭环）

**E1 同一 64 位值跨进程/跨编译器重复出现（最强单一证据）。**
`0x1c28416e00000680`（及同族 `…00001180`）以**相同位形**出现在 6 处：
厂商 musl logread core（10-19，core_15875）、Alpine busybox sh core
（10-21，sh.core）、sh2.core（`…1180`）、zig logc v1.3 的 gdb 现场
（10-21，crash.72.log）、zig `p6.log` 的 ap2 检查点、`layer.txt` 的
own_va_list 现场。覆盖 3 种编译器产物。**该值不在任何被怀疑的二进制里**
（对 libc/busybox/ip/logread/logd/logc 全量字节搜索为 0）→ 只能是运行期
外部写入。
⟦复核⟧ 但不能说"注入值恒定"：同一批 core 里高 32 位是变的
（core_3053=0x1365fe9b、core_27987=0xa4e8817b、rec.log=0x0998010a）。
"同一 64 位值重复"是**个案**强证据；**恒定的是块形状**（E4），不是这个常量。
"≥2 次重启"未在本地证据中逐次核对，暂按设备侧记录引用。

**E2 同页多块、同值复现。** core_3053（logread）：同一 4KB 栈页内
`0x1365fe9b0000062d` 在 +0x188 与 +0x310 两处以 {0, X, 0, …} 形态重复；
sh2.core：`0x1c28416e00001180` 在 +0x148 与 +0x290 重复。外加各一处
{small,0} 半块。→ 写入是**同一页内多条 16/32B 记录**（环形槽位形态），
不是单次越界。

**E3 ip core 的 .bss 整页喷射（原 C 类闭环）。** 把 core_ip.core 的
0x10f1e00–0x10f1e60 映射到 `struct link_filter`（368B，label 在 +304）
字段上：`0x157c0` 以 **16 字节节距连打 5 发**（pfx 尾部、flags、label、
flushb、slave_kind），中间夹正常值（master=-1 合法）。fnmatch 恰好解引用
label 才崩。→ 与 va_list 坏块同族，victim 签名只取决于"哪个字段被击中"。

**E4 块形态学。** 全部坏块归纳为两种：16B `{小整数, 0}` 与 32B
`{小整数, 0, 0x????????_0000_06xx, 0}`；小整数非单调（相邻分钟内
112,712 → 52,764 递减出现），更像按槽位独立的计数值/序号或长度，不是全局计数器。
⟦复核⟧ `0x…0000_06xx` **不是"准静态 64 位值"**：低 32 位在
0x62d/0x631/0x680/0x1180 间变，高 32 位在现场间也变（见 E1）。
可用的不变量只有：块形状 + 低 32 位落在 0x6xx/0x1180 族 + 同页多块。

**E5 剧集性 + 按页命中。** §16.1 的 0 命中 vs P0 会话 100% 秒崩；崩溃
迭代数跨 2–3 个数量级（⟦复核⟧ 本地 dump 里是 0x493a27=4.80e5、0x65cc11=6.67e6、
0x9df62e=1.04e7、0x6227018=1.03e8；"3,806"只出现在设备侧记录，未归档）。
→ 污染页处于"流转"状态时每个新进程都可能拿到它；不流转时整系统平静。

**E6 受害者生态 = 新页获取率。** 全家族高频成员全是**短命、每次 exec 都拿
新页**的工具（grep/awk/ip/sh/pidof/wc/sed…，30s 守护舰队持续供给）；
长命厂商件（hostapd/logd/thermal_core）低频崩溃（剧集期新分配页中招后
"终身"受害）；固定地址长命探针 0 命中。
⟦复核⟧ "官方固件零记录 = 没有页 churn"是**推断**，不是证据：官方时代是否
真的零 NE 还取决于 C19 的两条 Sep 9 记录；且官方 GUI/守护也会 spawn 工具。
这条只保留"新页获取率决定受害者生态"这半句（它被 E5/§16.1 支持）。

**E7 注入源侧画像。** SoC=MTK（4×Cortex-A55，内核 5.15.134），21 个
ccmni 通道、ccmni2 承载数据（RX ~950MB）；dmesg 有 ccci 通道 **16 字节**
写入记录（`[ccci1/chr]write error done on ttyCMIPC11, l=16`，⟦复核⟧ 仅设备侧、
本地未归档）——与坏块粒度一致；崩溃剧集与蜂窝拨号/WiFi 搬道时段吻合。
⟦复核⟧ 剧集倍数改为区间：23:31–00:16 的产品段是 sed/awk/wc/grep **4 条
≈5.3/h**（其余 aee 事件是 23:31 起的 P0 探针，须扣除）；基线取 10-21
02:00–19:00 为 **0.6/h**、取 10-20 白天为 **~3/h** → 倍数 **2–9×**。
MD 保留内存区在 /proc/iomem 的 0x82000000–0x89f6ffff 等窗口（供活捉后比对 PFN）。
⟦复核⟧ 2026-10-22 的独立复现（§19）在 **ccmni3 ping 100% 丢包**期间仍抓到命中，
而 eth0 流量占主导——"与蜂窝流量同窗"这一条未获独立确认；注入事实本身不受影响。
§20.4 的 28 次命中/10 分钟里 ccmni3 仅 19KB、eth0 353MB，一度削弱该假设；
**§21 以描述符/内容证据坐实 dpmaif**：命中页 PA 在 dpmaif 环里、内容是环记录，
MD 写环记录与 PDP 数据流量无关——**流量相关性不是判据**。

**E8 交付链 = 回收页复用。** 主控的环形缓冲页被驱动释放后回到 buddy
池，被用户进程当新栈/新堆/新 .bss 页拿走，主控仍持旧物理指针继续写。
解释：memtest 通过（无页复用）、金丝雀通过（无新页）、logc v1.3 单次
全环读取 **0.2–0.5%** 崩溃率（§10.2 实测 1/220–1/600；按 30s 轮次折算
约 2%），每轮读环约万次 strftime 的高频解引用 × 污染页。

**E9 旧"反证"全部反转为佐证。** TZ 无关/记录内容无关/-l 200 更少崩/
字面量不崩/自有可变参数"不崩"（实为崩点少：pop_arg 是最高频的污染值
解引用点）/O0-O2 全崩/上游 master vfprintf 仍崩（libc 无辜当然无效）——
全部与主机制相容，与"libc 缺陷"反而处处别扭。

### 16.3 坏块与判据（替代 §0.5 旧判据的补充）

- **注入块签名**（识别新 core 用）：16B `{u64∈[0x2710, 0x40000]∪{0}, 0}`
  或 32B `{small, 0, 0x????????_0000_06xx, 0}`；同页可多块；同剧集内
  `0x…` 值恒定、跨天缓慢变化。
- **健康 va_list 判据**沿用 §0.5（结构判据，非指纹）。
- 崩溃速率口径沿用 §14（须分子分母 + 扣除探针）。

### 16.4 选集效应：为什么"看起来"是 musl printf 的缺陷

污染块落在进程内存的任意位置；**大多数落点无人解引用，无感**。printf
的 `pop_arg` 对 va_list 指针字段的解引用频率是全系统最高的（每次
printf 调用至少 1–N 次），因此污染页一旦命中活跃 printf 路径，几乎必然
以"musl 内 va_arg 崩溃"的形态爆发。这就是：全家桶"全是 printf 崩"、
`-l 200` 降幅、字面量不崩（无 pop_arg）、自有可变参数
"不崩"（解引用点少一个量级）的统一解释。
⟦复核⟧ 旧文列的"logread 45% 占比"**没有出处**：按 §14 组件口径 logread
只有 1/65（1.5%）；87% 是早期 dmesg 15 条里 logread 13 条的口径。占比
随口径变化，不能当"选集效应"的量化证据。**去 printf 化（logc v1.4/
logcut/procmatch）作为缓解依然正确有效**——它把最高频解引用点摘掉了。

### 16.5 注入源候选（按嫌疑排序）与判别途径

| 候选 | 支持 | 反对/待验 |
|---|---|---|
| **蜂窝 MD（ccci/ccmni 共享环）** | E1 跨重启存活（MD 独立电源域）；E7 16B 记录与 ccci 日志粒度一致；剧集与拨号/数据活动相关 | 待活捉页 PFN 落在 MD 相邻窗口 + 记录内容语义 |
| WiFi 固件（mt76 环） | 剧集与搬道相关（§4） | 固件随 AP 重启复位，与 E1 跨重启矛盾 → 至多次要共犯 |
| 其他常开协处理器（mcupm/SPM 域） | iomem 有 mcupm mbox；常开 | 记录形态与 ccci 16B 吻合度低 |
| AP 内核模块写错地址 | — | E1 跨重启常量要求内核静态常量（可能但牵强）；与 E7 粒度/相关性不如 MD |

判别途径：`/data/p0x/pageharvest`（活捉页 → pagemap PFN + kpagecount>1
判"驱动仍映射"）+ `/data/p0x/sentinel.sh`（pfcanary 每分钟探剧集，rc=139
即触发 harvest 抢收）。**两仪器已常驻设备，下一剧集自动取证。**

### 16.6 根修路径（确认方向，未实施）

按"覆盖面 × 成本"排序；**唯一能同时覆盖不可重编厂商件（hostapd/logd/
thermal_core/gdb…）的是 B/C 两类**：

1. **O1 活捉**（仪器已就位）→ 拿到被写页的 PFN、kpagecount、整页记录
   dump。判定：kpagecount>1 ⇒ 驱动仍持映射（内核侧 UAF 实锤）；
   PFN 落在哪个保留窗 ⇒ 主控归属。
2. **选项 A（内核/驱动侧，最外科）**：定位释放环页的驱动（ccci_hif/
   ccmni/mt76 teardown），补丁或自建模块**钉住环页**（teardown 只解绑
   不 free，reboot 才回收）。先例：本项目已有自建内核模块能力
   （healthdog.ko / v3_fix.ko）。
3. **选项 B（LK cmdline 预留，覆盖面最大之一）**：若 O1 显示主控写的是
   **跨重启稳定的物理地址**（环分配确定性高，大概率如此），用既有刷机
   管线的 `kcmdline append memmap=…` 把该物理范围从 buddy 池永久剔除
   ——主控写进的页永远不会再被任何进程拿到。**全系统（含厂商件）一次
   性免疫**，代价是几 MB 内存。
4. **选项 C（EMI MPU 硬件防火墙）**：SoC 有 emimpu@1021a000（MTK DRAM
   主控访问防火墙）。把 MD/相关主控的写窗口收紧到其 SMEM 区，越界写在
   硬件层被拦。最强但最厂商特定，需 MTK 工具链配合，列为 B 不可行时的
   后手。
5. **缓解层（可立即做，线性降低可见故障）**：降低热路径 spawn 频率
   （守护合并/批量）；对幂等只读工具（wan_agg 的 ip 读数等）加"崩溃即
   重试一次"包装。**不再是修复主线**，根修后可回撤。
6. **明确不是修复**：修/换 musl、更多 applet 替换、netq（见 §16.7）、
   "P0 下一步：从源码构建 musl / 硬件观察点抓写入者"（§12.8）——全部作废。

### 16.7 已落地修复的再评价（复杂性/性能 vs 实际必要）

| 修复 | 前提 | 实测效果 | 再评价 |
|---|---|---|---|
| **P2 静态工具链**（busybox/ip 农场 + PATH 前置 + fail-open + TZ 双机制 rc v2.4/2.5） | "崩溃面=厂商 musl 动态件" | **崩溃零改善**：静态 musl 同样中招；§10.1（静态件 61 次/35h）与 10-22 凌晨（grep/ip/sh/sed/awk/wc 全崩在 `exe=/data/gw/bin/busybox`）实证；切换前后各成员速率持平 | **前提已被推翻**。保留（工具链自主权 + procmatch/pgrep 交付载体 + 行为一致），但**冻结**：不再为治崩溃扩展任何替换。农场是全项目最大的一笔"为已证伪前提付出的复杂度"（305 符号链接 + 启动耦合 + selftest 面） |
| **P1 logc v1.4 去 printf**（手写 ctime/拼装/stats） | "musl printf 缺陷" | **有效**：v1.3 7 崩/h → v1.4 0 崩（至今） | 保留。机制上=摘掉最高频解引用点（§16.4）；logc 本身作为 logread 替代另有独立价值（受控解析/stats/selftest） |
| **logcut 替换 awk**（+ stream 去 grep 预检） | "busybox awk 数组缺陷" | **有效**：18.4/天 → 0 | 保留。但 §11 的"awk 内部缺陷"解释降级为未证实（§16.2-E3 注）；真实生效机理=少 spawn + 无崩溃解引用点 + 无大数组堆页 |
| **procmatch 替换 pidof/pgrep** | "同 printf 面" | **有效**：2.7/天 → 0；另修了 busybox pgrep -x 漏存活进程的真 bug | 保留（双重收益）。残留暴露：svc_lib 的 hostapd 检查仍用 busybox awk（23:49 崩过一次），可在根修前顺手收口，非必须 |
| **P3 core_trap 窗口 + core_meta 包装** | 取证缺口 | 本轮收官分析即建立在其 core 之上 | 保留（证据管线） |
| **P4 watchdog aee 增量判据** | dmesg 限流盲区 | 实测有效 | 保留 |
| **logd 开机清环**（log_keeper v1.7，uptime≥300s） | "毒记录驻留环" | 前提已被 §12/§16 双重证伪（记录内容无关） | **不再有崩溃学理由**；仅剩"开机环卫生（aee 转储体积）"边际价值。低价值项，留待 owner 决定去留（去留皆无害） |
| **hardened vfprintf（h_vfprintf.c）** | "libc 侧修" | 技术上有效（guard 拦截=崩溃消除）但从未部署 | 归档为**技术**（未来新写的 printf 热路径静态件可复用）；不再有部署计划 |
| **REPLACEMENT_FEASIBILITY 的 netq 路线**（/proc 解析替代 ip 读数） | "ip 有独立缺陷需净替换" | — | **作为治崩溃手段取消**（ip 崩溃=主机制）；若仅为少 spawn 有边际收益，成本/收益不成立。§12.8 的"P0 下一步（musl 源码构建、观察点抓写入者）"一并作废 |
| **ap_auto_logging=0 护栏** | 防 logread -f 常驻 | 仍然正确（少一个无谓常驻崩溃面） | 保留 |

### 16.8 未闭环清单（收敛后仅剩 4 项，全部有自动化仪器在位）

1. **O1 活捉被写页**：pageharvest 已**抓到写入**（§17.3，`/data/p0x/harvest.log`），
   但 `pagemap` 不给 PFN → **kpagecount>1 这一步仍未拿到**。要闭环 E-链最后一环，
   需要一个能读 PFN 的途径（自建模块/`kpageflags` 权限/或 kcore 比对）。
2. **O2 主控与释放驱动归属**：由 O1 数据 + /proc/iomem 保留窗 + 必要时
   自建模块记录 ccmni/cci 环物理地址比对。决定选 A 还是 B。
3. **O3 awk"内部缺陷"独立证实与否**：不再必要（主机制已覆盖解释）；
   仅当 O1 证明注入不存在时才需回头（概率极低）。
4. **O4 sleep/ls/ping 等零星成员**：同主机制推定（短命+偶发命中），
   无需单独取证；根修后自然消失。

> 运维注意：sentinel/pageharvest/memtruth 的崩溃与 core 会计入 ne_events
> （exe=/data/p0x|/data/p0 与 /tmp/*），普查时按 §13.6/§14 口径扣除。

## 17. 2026-10-22 终局轮：二进制定罪 + 活体捕获（"指控坐实"）

> 本轮按"逆向分析二进制坐实指控"执行。⟦复核⟧ 拿到的是两件不同强度的事：
> ①内核侧（ccci/dpmaif 驱动）的**环机制与 stop 路径**与"失效环指针继续写"
> 相容（常数吻合只是单样本旁证，见 C15）；
> ②pageharvest 在被持有期间**当场捕获外部写入**落笔——这一条是活体实证。
> 合起来足以支持 §16 的定性，但"二进制级定罪"应理解为"机制级"，不是
> "逐指令抓到写入者"。

### 17.1 逆向管线（可复现）

- boot 分区内核载荷熵 **7.973** bits/B = **加密**（MTK 安全启动），镜像路线不通；
- 但 `CONFIG_STRICT_DEVMEM` **未启用** + root + `/proc/iomem` 的 "Kernel code"
  物理范围（0xfd910000–0xfe52ffff）→ 经 `/dev/mem` 直读**运行中内核文本**，
  12MB 全量落盘；数据段（0xfe6d0000–0xfea4ffff，**3.5MiB**）同理；
- `/proc/kallsyms`（kptr_restrict=0）6.1 万符号 + capstone → 带符号反汇编
  （工具链存档 `tmpfiles/p0x/kern/kern_an.py` + ktext/kdata/kallsyms 快照）；
- `ccmni`/`ccci` 为**内置驱动**（/lib/modules 无对应 .ko）——只能走内核文本。

### 17.2 内核侧定罪链（反汇编锚点）

| # | 事实 | 反汇编锚点 |
|---|---|---|
| 1 | **BAT 环条目数 = 0x680/0x780，条目尺寸 = 0x18/0x20，环本体 dma_alloc_attrs(0x20000)** | `dpmaif_bat_init+0x20..0x30`（`csel w20,w20,#0x18`、`csel w0,w0,#0x680`）、`+0x60 bl dma_alloc_attrs` |
| 2 | ⟦复核⟧ 0x680/0x780 是 `dpmaif_bat_init` 的两个 count；但受害者低 32 位是 0x62d/0x631/0x680/0x1180，**后三者不在 dpmaif 里**（内核文本中只见于 ext4/Si3217x/无关驱动）→ 0x680 是单样本巧合，该字段更像长度/序号（1500–1700B 的典型段长），不是环计数。坏块尺寸只有 16B/32B（0x18=24 未观测到） | 全文 `movz #0x680/#0x780/#0x62d/#0x631/#0x1180` 扫描 |
| 3 | **RX 数据缓冲 = 伙伴系统普通页**（`__alloc_skb`/`page_frag_alloc_align`+`__build_skb`），dma_map 后 PA 经 BAT 交给 MD 侧 DMA 写入 | `dpmaif_alloc_med_rx_buf+0x194/+0x28c` |
| 4 | **拆卸顺序**：disable_irq → `dpmaif_stop_hw`（UL/DL idle 轮询**有界**：0x186a0/0x180000，超时仅 dump+printk **继续走**）→ `dpmaif_stop_rx_sw`：`dma_unmap_page_attrs` + `ccci_free_skb`/`put_page` + `__page_frag_cache_drain` **全部归还伙伴系统**，随后 `memset(环,0,条目数<<4)`（16B 步长）→ del_timer → notify → **最后**才 `msleep(1)` 等 `[dev+0x404]==1` 的 medmcu ack（⟦复核⟧ **无超时上限**） | `dpmaif_stop+0xf4`、`dpmaif_stop_hw+0x8c..0x2d4`、`dpmaif_stop_rx_sw+0x228..0x2d0`、`dpmaif_stop+0x15c` |
| 5 | 环 PA 编入 **HW 寄存器**（`drv_dpmaif_dl_set_pit_base_addr`：MMIO 写 + dsb）；停止路径**不清理基址寄存器** | `drv_dpmaif_dl_set_pit_base_addr+0x24..0x40` |
| 6 | 触发面 = ccci MD 状态机经 **ops 函数指针表**调 `{start, pre_stop, stop, syssuspend, sysresume}`；⟦复核⟧ 表在 **0xffffffc0090e9440**（0x…93f0 是 dpmaif netdev_ops：give_more/write_room/start_queue/stop_queue/dump_status） | `kdata.bin`：+0=dpmaif_start、+8=dpmaif_pre_stop、+0x10=dpmaif_stop、+0x18=dpmaif_debug、+0x70=dpmaif_syssuspend、+0x78=dpmaif_sysresume |
| 7 | RX 数据通路流量（dmesg `[ccci1/dpmaif]net txq…`）与 ccmni2/3 活跃一致（⟦复核⟧ **仅设备日志，本地未归档**） | 设备日志 |

**结论**：被污染值 = **dpmaif 环/描述符族**（长度/序号字段；0x680 只是其中一个
样本与 BAT count 相同，不能当常数证据）；写入者 = **MD 侧（MD 核/DPMAIF HW/
medmcu）经失效环指针继续 DMA**；受害页 = 驱动 stop/复位后**归还伙伴系统又被
用户进程拿走的 RX 缓冲页/环页**。最关键的新事实是**顺序**：页在 stop_rx_sw 里
就已归还，而 medmcu ack 的等待在之后（且无超时）。"X 高 32 位"语义未解出
（不影响定性）。

### 17.3 活体捕获（pageharvest，2026-10-22 01:22–01:35）

> ⟦复核⟧ 已用设备 `/data/p0x/harvest.log` 原文逐项核对（2026-10-22 12:1x），
> 下列数字与地址都对得上；同时补两条限制（见文末）。

- **同一虚拟偏移（页尾 0xfc0 起）**反复出现
  `{0x9d9d,0}{0x9d9d,0}…` / `{0x36d1b,0}…` / `{0x20849,0}…` / `{0x29d9d,0}…` 的
  **16 字节节距记录**——页面是我们刚清零的新匿名页，写入发生在持有期间；
  原文：`HIT cyc=72 scan=0 addr=0x…fc0`，上下文 `0x…fc0: 0x9d9d 0 0x9d9d 0`。
- 计数值 40,349 → 224,539 → 133,193 → 171,421：量级落在历史受害者值域
  （40K–160K）内、**非单调**（与受害者观测一致）。
- 首个命中周期的 **netdelta=70,459**（前后周期 55–600）——**写入与蜂窝数据
  突发同窗**。
- 同页邻接内容含 `0x10033d68c`（vmemmap/物理页指针形态）等内核侧结构残影，
  与"环页被回收复用"的页谱一致。
- ⟦复核⟧ 不是"3 个分配周期"：同一地址在 cyc=72/105/109/168/175/184/189/194/
  236/302/357… 反复命中；pageharvest 每个周期重新 mmap+清零，命中即说明
  **当前持有页**又被写了。
- 限制：`CONFIG_PROC_PAGE_MONITOR` 未启用 → `pfn=0`，`kpagecount` 不可读
  （该验证位缺失已记录；不影响"外部写入"这一事实，但 O1 的 PFN 归属仍未闭环）。

### 17.4 对 §16.5 候选表的更新

| 候选 | 判定 |
|---|---|
| 蜂窝 MD/ccci-dpmaif 环（含 medmcu 握手） | **已坐实（§21）**：命中页 PA 出现在 dpmaif 16B BAT/PIT 环与 32B 影子数组（`info` PLEN0=4096、DONE=0，`page_count=1`）；命中内容是 `{small,0}` 环记录。§20 的"流量近零"论证不适用（MD 写环记录与 PDP 数据无关） |
| eth0 / mt7530（有线 DMA） | **排除（§21.2）**：命中内容是环记录，不是以太网帧（无 MAC 头、不在偏移 0） |
| WiFi 固件（mt76/connac） | **排除（§21.2）**：无 RXWI/帧头；`buf` 是 vmemmap 页指针而非 page_frag VA |
| 硬件内部 stale 指针（任一 DMA 主控） | 归入 dpmaif：环条目 DONE=0 仍指向已释放页（§21.1） |
| AP 内核写错地址 | 仍可排除"AP 侧主动写用户页"（17.3 的页由用户进程持有、内容为 DMA 记录形态）；但不能排除内核释放/回收链的 bug |

md1img_a 固件**明文**（MTK 头 + md1rom，熵 6.16）——如需 MD 侧逐指令定罪
（谁写的 0x680 记录），素材在备份镜像 lba 376896 起 640MB。

### 17.5 根修路径细化（替代 §16.6 排序，仍不动手）

1. **首选（内核侧最小补丁）**：`dpmaif_stop_rx_sw`/`dpmaif_stop` 在
   **idle 等待超时/medmcu ack 异常路径上改为"泄漏不释放"**（leak-on-timeout）：
   环页与 RX 页不回伙伴系统，仅在 dpmaif 重新 start 成功后统一回收；
   同时 stop 时清 PIT/BAT 基址寄存器并要求硬件 ack 后才允许 free。
   一个 ~几十行的 out-of-tree 补丁模块即可钩住（项目已有 .ko 构建/加载先例）。
   ⟦复核⟧ 注意：`dpmaif_stop` 等 ack 的 `msleep(1)` 循环**没有超时上限**；
   leak-on-timeout 必须同时给这个循环加上限，否则"等不到 ack"会从**泄漏**
   变成**挂死**（更糟）。
2. **LK cmdline 预留**（§16.6-B）保留为兜底：环页是 dma_alloc 动态页，
   仅当证实失效 PA 跨重启稳定时才可行——优先级下调。
3. EMI MPU（§16.6-C）保留为最后手段。
4. 缓解层与监控维持 §16.6-5；`ap_auto_logging=0` 等不变。

## 18. 复核证据索引（2026-10-22 复核轮）

> 本节只列**本轮实际打开过**的证据，便于下一次复核直接复跑。
> 路径均为本地（`tmpfiles/` 与 `_local/archive/`，不入仓）。

### 18.1 本地证据（PC 侧）

| 证据 | 用途 | 复核结论 |
|---|---|---|
| `tmpfiles/core_27987.bin` / `core_3053.bin` / `core_15875.bin` | §1/§15.2 的寄存器与 si_addr | 全部对上（§0.0.1） |
| `tmpfiles/logread.bin` + `tmpfiles/logread.c` | §2 的记录格式/帧同步/print_log | 格式与 tb 已更正（C1–C3） |
| `tmpfiles/libc.so` | pop_arg 0x51e8c、asctime 0x7a068 | guard 的 offs 判据不成立（C8） |
| `_local/archive/stability_2026-10-21/cores/{sh,sh2,core_ip,crash_awk,pf}.core` | §12.3/§11.7/§16.2 | sh/sh2 签名对上；ip 的 5×16B 喷射对上 |
| `_local/archive/.../events/crash.72.log` | §10.3 | ap2=-32、调用方 ap 健康（C5/C6） |
| `_local/archive/.../p0devices/{ab,cp,rec,p6,layer}.log` | §13.2 | 污染率区间、ap==ap2、常量重复（C7/C12） |
| `_local/archive/.../p0dumps/p4.*.txt` | §16.2-E5 | 迭代数 0.48M–103M |
| `tmpfiles/p0x/ne_events_full.tsv` | §11.1/§14 | 69 行 → 65 次产品崩溃（C9/C10） |
| `tmpfiles/p0x/kern/{ktext,kdata,kallsyms}` | §17.2 | ops 表地址、count 常数、stop 顺序（C15–C17） |
| `tmpfiles/p0x/kernel_payload.bin` / `iomem.txt` | §17.1 | 熵 7.973；code/data 范围（C18） |

### 18.2 设备侧只读快照（本轮拉回，存 `tmpfiles/`，不入仓）

| 文件 | 内容 |
|---|---|
| `tmpfiles/db_history.txt` | aee 台账 296 条（含 Sep 9 两条异常记录） |
| `tmpfiles/p0x_logs.txt` | `/data/p0x/{ro,stk,mix_ro,mix_stk,mm,alias,bss}.log` 尾部，全部 `hits=0` |
| `tmpfiles/aee_dirs.txt` | `db.06.NE/ZZ_INTERNAL`：`SIGSEGV,ip,Thu Oct 22 03:38:11` |
| `tmpfiles/kcfg.txt` | `kptr_restrict=0`、kallsyms 61689 行、iomem 头 |
| `tmpfiles/meta.txt` | core_meta 的 `ping`（wan_agg）现场 |

### 18.3 本轮**没有**做的事

- 没有写设备、没有重启、没有重跑崩溃实验（避免污染剧集与台账）。
- 没有重新验证 §10.1/§11.5/§9 的设备侧计数细节（见 §0.0.4）。
- 没有把 `logc.c` 头注释/VERSIONS.tsv 的旧叙事改掉（只在本节标注以本文为准）。

## 19. 2026-10-22 独立复现（复核轮，设备侧）

> 本节是对 §16/§17 核心指控的**独立运行时复现**：不复用 pageharvest，
> 自写探针与对照；设备侧只用 `/data/repro/` 暂存、经 `deploy.py put`
> （md5 双校验）推送，未写 flash、未改配置。结论：
> **"外部写入者把 16 字节记录写进用户进程持有的页"这一事实成立**；
> **写入者身份（蜂窝 MD/dpmaif）仍未独立坐实**。

### 19.1 仪器与对照

| 仪器 | 设计 | 目的 |
|---|---|---|
| `injwatch` | 2MB mmap + 512KB heap + 512KB .bss，清零或 0xAA，每轮重映射、持有 1s，逐词扫描 | 主探针；每轮先做"清零后立即扫描"的对照 |
| `injwatch2` | 2048 个独立 4KB mmap + 4MB 连续映射，清零一次、持有 20s | 模拟"新进程栈页"的逐页分配路径 |
| `injwatch3` | 2MB，按页汇总，持有 20s | 排除"逐词 1s 重读"对日志的干扰，测写入范围 |
| `victim` | `snprintf("%ld")` 循环 + SIGSEGV handler（打印 i/si/pc） | 受害者侧签名与剧集状态 |

关键对照：① 清零后**立即**扫描（暴露窗口 ~毫秒级），若命中则写入不是我们自己的
memset；② 0xAA 填充（写入者若只写零页则不会命中）；③ 逐页/小页分配（阴性对照）。

### 19.2 结果（2026-10-22 12:32–12:52 CST）

**剧集状态**：实验开始时 3/3 次 `victim` 在 1–2 秒内 SIGSEGV（i=6.0M/7.3M/17.6M），
实验期间 33/40、5/6 次崩溃——**设备处于强剧集期**。

**主探针（zero 模式，600s，9972 次扫描）**：

- **16 次命中 / 4 个批次**，全部落在 **page_off=0x1ff000（2MB 映射的最后一页）、
  word 504/506/508/510（页尾 0xfc0 起，16 字节节距）**；
- 四个批次的值为 `0xd036`、`0x2e000`、`0x36474`、`0x1e7a6`（每批 4 条，同批同值）；
- 上下文是 `{小整数,0}` ×4，与 §16.2-E4 的 16B 块形态一致；
- 命中页紧邻 `[vvar]`（0x…497000），所以"邻接内核指针"是 vDSO 时间数据，不是注入内容
  ——这条排除了"读串页"的误判；
- **立即对照两次命中 `IMMEDIATE-HIT n=4`**：写入发生在我们 memset 之后的毫秒级窗口内，
  探针自身从不写非零值 → **外部写入**；
- 同一页的 5 次重读值稳定（写入是一次性的，不是我们自己的写循环）。

**0xAA 模式（300s）**：

- **159 次命中**：page_off=0xea000 157 条、0xe9000 2 条；值 `0x1c971`/`0`
  交替填满整页——**写入者会覆盖非零内容**，不是"只写零页"的假象；
- 立即扫描时已累计 `IMMEDIATE-HIT n=198684` 个 word（≈1.59MB）非 0xAA——写入范围
  可以很大（也可能部分发生在扫描窗口内），不只是 16 字节尾部记录。

**阴性对照**：

- `injwatch2`（2048 个独立 4KB 页 + 4MB，23 轮）：**0 命中**；
- `injwatch3`（2MB，6 轮 × 20s，aa）：**0 脏页**。
  → 命中依赖分配布局/时序，不是"任何新页都会中"；与报告"按页命中、剧集性"一致。

**受害者签名**（38 次崩溃）：

| si_addr | 次数 | 备注 |
|---|---|---|
| `0x28416e00000680` | 3 | 报告 E1 常数族（`…0680`） |
| `0x66e4a30000062a` | 3 | `…062a` 族 |
| `0x65fe9b0000062d` | 2 | `…062d` 族（与 §1 的 `0x1365fe9b0000062d` 同低 7 字节） |
| 其余小整数（0xb82d…0x314aa） | 30 | 与 §1/§15.2 同形态 |

崩溃点全部 `pc=0x101506c`（victim 的 pop_arg 路径），与报告 §12/§13 一致。

**内核侧独立复核**（自写脚本，读同一份 ktext/kallsyms）：

- `dpmaif_stop` 调用顺序：`disable_irq → stop_hw → stop_tx_sw → stop_rx_sw →
  del_timer → notify → msleep`（ack 等待在**归还页之后**）；
- `dpmaif_stop_hw`：**0 次 iowrite、4 次 ioread32**（不清理 PIT/BAT 基址寄存器）；
- `dpmaif_stop_rx_sw`：`dma_unmap_page_attrs` + `ccci_free_skb`/`put_page` +
  `__page_frag_cache_drain`，`memset` 用 `lsl #4`（16B 步长），skb 环条目 0x18。

### 19.3 判定

| 断言 | 判定 |
|---|---|
| 存在外部写入者，把 16 字节记录写进用户进程**刚清零/持有**的页 | **独立复现成立** |
| 写入者会覆盖非零（0xAA）内容 | **成立**（159 次命中、整页 `{0x1c971,0}`） |
| 写入不是探针自身所为 | **成立**（立即对照在 memset 后毫秒级命中；探针不写非零） |
| 受害者崩溃与注入同源（si 落在注入常数族） | **成立**（8/38 次为常数族，其余同形态） |
| 内核 stop 路径"先归还页、后等 ack"、不清基址寄存器 | **成立**（独立反汇编） |
| 写入者 = 蜂窝 MD/dpmaif 环 | **已坐实（§21）**：命中页 PA 在 dpmaif 环/影子数组，内容为环记录；§19/§20 的流量论证不适用 |
| "与蜂窝流量同窗" | **未独立确认**（见 §16.2-E7 的复核注） |

### 19.4 对报告的影响

- §16/§17 的**注入事实**从"证据链"升级为"独立复现"；§17.3 的 pageharvest
  结果（页尾 0xfc0、16B 节距、同页多块）被另一套仪器复现。
- **写入者身份**仍是 O1 的缺口：要坐实"蜂窝 MD"，需要 PFN/kpagecount
  或对 dpmaif 环下硬件观察点；本次未能提供。
- §16.2-E7 的"蜂窝流量同窗"降级为未确认；这不影响注入定性，但影响
  "选 A 还是 B"的根修决策依据。
- §14 的排除规则新增 `/data/repro/*`（本次受害者/探针崩溃，38 条；另有 3 条实验前金丝雀）。

### 19.5 产物（设备侧，oneoff，不入仓）

- `/data/repro/{injwatch,injwatch2,injwatch3,victim}`（静态，md5 见 deploy 记录）；
- `/data/repro/run_zero.log`（16 命中）、`run_aa.log`（159 命中）、
  `run2.log`/`run3_aa.log`（阴性对照）、`run_victim*.log`（38 次崩溃）；
- 本地副本：`tmpfiles/repro/`（源码 + 拉回的日志）。
- 实验结束后已 kill 全部探针/流量进程，设备未重启、未改配置。

## 20. 2026-10-22 写入者身份轮（PFN/内存取证）

> 目标：坐实"写入者是谁"。方法：自写 `pfnprobe.ko`（当前 mm 的 VA→PFN/page_ptr/flags）、
> `pascan`（保留窗扫 PA）、`sysscan_h`（全 System RAM 扫 PA，**只存哈希不存原值**，
> 避免扫描器自匹配/历史残留污染）、`memread/hexdump`（结构 dump）。
> 结论：**身份仍未坐实，且蜂窝 MD 假设被本轮运行时证据削弱**。

### 20.1 命中页的 PFN/PA（7 页）

| PA | count（GUP 后） | mapcount | 类型 |
|---|---|---|---|
| 0xa65b4000 / 0xa2186000 / 0xa4b84000 / 0xa494a000 / 0xa4b62000 / 0xa4b55000 / 0xa4a1e000 | 2（基线 1） | 1 | anon / page-cache / free 混合 |

- `count=2` 是"我们的 GUP +1"；基线 1 = **没有额外的 page 引用**（驱动没有 `get_page`）。
- 7 页都在 0xa2–0xa6（System RAM），不是保留区。

### 20.2 三个否定结果

1. **保留窗（20 个窗口，~300MB）扫 PA：0 命中**（`pascan`）。
2. **全 System RAM（~1.5GB）扫精确 PA：0 命中**（`sysscan_h`，哈希比较，排除扫描器自身/历史残留）。
   → 命中页的 PA 在 AP 内存里**没有活引用**：描述符要么已被消费/覆盖，要么只在硬件内部。
3. **无 SMMU/IOMMU**（dmesg 无 smmu/iommu，`/sys/class/iommu` 空）→ PCIe 设备（eth/WiFi）
   也用 PA，所以"PA 找不到"不能用 IOVA 解释。

### 20.3 注入常数在内存里的分布（9 处）

`0x1c28416e00000680`（32B `{small,0,const,0}`）出现在：
0x80165d60、0x81988960、0x8f019560、0xa0862160、0xa0899560、0xada8a160；
`0x1c28416e00021e9d` 出现在 0xa4c3f068、0xad1427e8、0xad6a7328。
- 低地址两处（0x8016/0x8198）的结构含 `__switch_to+0xe0` 返回地址、`0x50c3`、`0x20`——
  是**任务上下文/内核栈**，即"受害者保存的寄存器/栈里带着注入值"。
- 中地址几处在页指针数组/缓冲里，同样更像**受害者数据**，不是写入者的描述符环。
→ 内存取证只能看到"注入数据在受害者里"，看不到"写入者的指针"。

### 20.4 流量相关性（28 次命中 / 10 分钟）

| 接口 | 期间增量 |
|---|---|
| ccmni3（蜂窝） | **19,198 B**（≈19KB） |
| eth0（有线 WAN） | **353,291,190 B**（≈353MB） |
| rai0（5G WiFi） | 311,937 TX 包 / 151,092 RX 包 |
| DPMAIF_AP 中断 | 788 → 1044（≈0.4–0.7/s，基本空闲） |

→ 命中发生在**蜂窝几乎空闲**、**eth0/WiFi 繁忙**的窗口。§16.2-E7 的"与蜂窝流量同窗"
在本轮**不成立**；"写入者=蜂窝 MD"从"首要嫌疑"降为"**未被支持**"。

### 20.5 判定与下一步

| 候选 | 本轮判定 |
|---|---|
| 蜂窝 MD/ccci-dpmaif | **已坐实（§21）**：环条目/影子数组指向命中页；内容为 dpmaif 环记录；流量论证作废 |
| eth0 / mt7530（有线 DMA） | **排除（§21.2）**：内容形状不是包数据 |
| WiFi / mt76（page_pool） | **排除（§21.2）**：无 RXWI/帧头 |
| 硬件内部 stale 指针（任一 DMA 主控） | 归入 dpmaif（DONE=0 的环条目，§21.1） |

**决定性下一步**：§21 已用描述符/内容证据坐实 dpmaif；ABAB 只作为因果复核（非定性必要条件）。

### 20.6 副作用披露

- 本轮 `pfnprobe.ko` 初版缺 `.proc_lseek`，`pftest` 的 `lseek` 触发内核 NULL 跳转
  （`pc=0x0, lr=proc_reg_llseek`），设备于 13:03 重启一次；加 `proc_lseek` 后正常。
  重启由 boot gate 自动恢复，未改配置。
- 设备侧探针已全部 kill，`pfnprobe` 已 rmmod；`/data/repro/` 保留日志。

### 20.7 挑拨与开关实验（14:01–14:14，PC 已切 WiFi 优先）

| 实验 | 操作 | 结果 | 判定 |
|---|---|---|---|
| P1 拨号挑拨 | 平静期（3/3 存活）→ `ccmni_up.sh cbnet`（deact 14:01:51 / act 14:02:03，落 **ccmni2**） | 300s 内 **8 命中 / 3/12 受害者崩溃**；崩溃在拨号窗口，命中在拨号后 ~95s | 时间相关，但… |
| P2 重复拨号 | 平静期（3/3 存活）→ 再拨（deact/act 14:08:33–34，落 **ccmni3**） | 150s 内 **0 命中 / 0/8 崩溃** | **不复现** → 拨号触发不成立 |
| B WiFi 关 | `ifconfig ra0/rai0 down` | watchdog 13:56:40 `hostapd recovered` 把 WiFi 拉回；同期剧集已平息（3/3 存活） | **无效窗口**（WiFi 只关了 ~1 分钟） |

- P1 的 8 次命中与 A 基线的 8 次同量级；P2 为 0，说明 P1 更像**自然剧集波动**。
- B 的 0 命中不能归因于 WiFi：窗口内 WiFi 被 watchdog 恢复，且剧集本身已停。
- `ifconfig rai0 down` 还把 `hostapd -B` 卡进 D 状态；watchdog 14:12:28 走"进程缺失→立即修复"
  恢复（bss=2）。**这是本轮的操作副作用，已恢复**。

**结论**：拨号/WiFi 开关都**没有**给出可复现的因果证据；但 §21 的描述符/内容证据
把写入者坐实为 **dpmaif**（因果层的 ABAB 仍可作为后续复核，不再是定性的必要条件）。

## 21. 2026-10-22 写入者定位：DPMAIF 环（描述符+内容双重证据）

> 目标：把"外部写入者"落到具体设备的环上。方法：PFN 模块 + 全 RAM 变体扫描
> （32 位地址/PFN/PA|flags，哈希去自匹配）+ 环结构 dump + 内容形状判别。
> 结论：**写入者 = 蜂窝 MD/DPMAIF 环**；§17 的二进制定罪成立。eth0/mt76
> 被内容形状排除。

### 21.1 命中页 PA 在 dpmaif 环里（直接证据）

命中页 PA（如 0xa494a000、0xa4b55000）出现在三处 **live 环结构**：

| 地址 | 结构 | 内容 |
|---|---|---|
| 0x84c78800 | 16B 环条目 `{info, ptr}` | `info=0x10000021`：**PLEN0=4096**（bits 16–29）、DONE=0（DMA 仍持有）；`ptr=命中页 PA` |
| 0x84cdd000 | 32B 影子数组 `{page_ptr, flags, pa, len}` | `page_ptr=0xfffffffe…`、`pa=命中页 PA`、`len=0x1000` |
| 0x8341f600 | 32 位地址+有效位环 | `0xa4b55001`（PA 置位 1） |

- 环基址 0x84c57000 / 0x84c70000，持有者结构在 0x8157f000，含
  `devm_kmalloc_release`/`dmam_release`（devres 分配）。
- 影子数组 **count×entry = 0x780×0x20 = 0xf000**，持有者里的 `0xf800`
  与 dpmaif BAT/RX 环的 0x780 条目族一致（§17.2 #1）。
- `info=0x10000021` 的 PLEN0=4096、DONE=0：**DMA 仍拥有该缓冲**，而该页
  已被释放/复用给用户进程（`page_count=1`、anon）——典型的 **RX 环 UAF**。

### 21.2 内容形状：环记录，不是网络帧（排除 eth/mt76）

命中页的写入内容是 **16B `{small,0}` ×4**（页尾 0xfc0）或 32B
`{small,0,const,0}`，例如 `0xd036 0 0xd036 0`、`0x12c15 0 …`。
- **以太网帧**（eth0/mt7530）会以目的 MAC 开头（本机 MAC 为
  FC:5C:EE…/D8:F6:07…），不会是 `{small,0}`；且帧在缓冲 **偏移 0**，
  不会只写页尾 64B。
- **mt76 RXWI + 帧**同样以 RXWI/帧头开头，不是 `{small,0}`。
- dpmaif 的 BAT/PIT/环条目正是 `{计数器,0}` / `{small,0,const,0}` 的
  16/24/32B 记录 —— **形状完全对上**。
→ 写入者是**写环记录**的 DMA（dpmaif），不是**写包数据**的 eth/WiFi。

### 21.3 与 §17 静态证据的闭环

§17.2 已证明：dpmaif stop 路径在 **medmcu ack 之前**就把 RX 页归还伙伴系统，
且不清理 PIT/BAT 基址寄存器；MD 侧仍持旧 PA 继续 DMA。本轮找到的
**live 环条目仍指向已释放页**（DONE=0、page_count=1）正是这条路径的现场。

### 21.4 因果测试的状态（诚实）

- 拨号挑拨 P1（deact/act，落 ccmni2）：8 命中/3 崩溃；P2 重复：0/0——
  **不复现**，因为环页回收是随机事件，拨号只改变窗口。
- eth0 阻断 ABAB：捕获到一次"受害者崩溃"（14:38:21），但 240s injwatch
  **0 命中**——那次只是单次注入，不是持续剧集，**因果窗口无效**。
- 因此**因果层的确认仍未完成**；但 §21.1/§21.2 是**直接内存证据**
  （环条目指向命中页 + 内容为环记录），足以把写入者定为 dpmaif。

### 21.5 对报告的影响

- §17.4：蜂窝 MD/ccci-dpmaif **确认**（不再是"未坐实"）；eth0/mt76 **排除**。
- §20.4 的"蜂窝流量近零 → 不支持"**作废**：MD 写环记录与 PDP 数据流量无关。
- §20.5/§20.7 的"未被支持/未坐实"改为"**已坐实（§21）**"。
- 根修方向（§17.5）不变：dpmaif stop 的 leak-on-timeout + 清基址寄存器；
  另需补 **环页回收前清条目/DONE 位** 的检查。

## 22. 2026-10-22 收口：本轮修复的定性、冻结规则与修复主线

> 本节回答一个管理问题，不是技术问题：**本轮做了一堆修复，现在该保留、该回退，还是
> 该重来？** 结论是三者都不是——**给它们定性、冻结扩张、把主线换到内核侧**。

### 22.1 结论先行

1. 本轮（`317d0c3..`）`gw/` 侧 **36 文件 / +4,711 行**的改动里，**没有一条是根因修复**。
   根因是内核 dpmaif 环页释放（§21）。
2. 这些改动对崩溃速率**没有数量级影响**：§16.7 的"崩溃零改善"在本轮收口时再次复现——
   近 24h 产品崩溃 **42 次**（已扣除探针/自测），其中 **27 次的受害者是我们自己的
   静态 `/data/gw/bin/busybox`**。静态化换掉的只是"谁先中枪"，不是"中不中枪"。
3. 因此处置 = **定性 + 冻结**，不是回退、也不是重来：
   - 把 C 类（§22.3）从"修复"降格为"缓解/工具化"；
   - 冻结其继续扩张（§22.4）；
   - 唯一修复主线交给内核模块（§23）。

### 22.2 为什么不回退到 `317d0c3`

| 理由 | 事实 |
|---|---|
| 会连带删掉**真修复** | 该区间混着与崩溃无关的 B 类：单实例锁/stale-pid、watchdog 自锁死循环、TZ 时序、hostapd 活性判据、boot_gate/svc_lib/netlock（`1fdaa33` `49db88a` `a81557c` `8f7374e` `0bbf81e` `e5213fc` `9ea5d8c` `235418b` `74b3dd9`…`1bfe77d`）。这些是真 bug，不是假前提 |
| 代码是耦合的 | `rc.extend.sh:47`→`toolchain_init.sh`；`log_keeper.sh:86`→`bin/logcut`；`svc_lib.sh:243`→`core_trap.sh`；`selftest` 有 logcut/procmatch 在位断言。摘 C 类必须连 B 类一起改回 |
| 回退是**大版本动作** | 全量重部署 + 冷启动验收（4 次冷启动 / 95 项 selftest 基线重做），而设备正跑这套 |
| 回退**不治病** | 真修复在内核侧 `.ko` + 指令补丁，与 `gw/` 谁替了谁无关；回退买不到任何东西 |
| 会毁掉测量基线 | 现在这套系统有干净的前置对照（42/d 含挑拨、25.8/d 平静期）。根修验收要拿它做 A/B；回退后基线不可比 |

### 22.3 逐件处置表（C 类与相关件）

| 件 | 原定性（本轮早期） | 现定性 | 处置 |
|---|---|---|---|
| 静态工具链农场（`6bf5cfa` + `toolchain_init` v1.1，305 applet + 静态 ip） | "P2 根治家族暴露面" | 工具链自主权载体；**对崩溃零改善**（静态件自己也在崩，§22.1） | **保留 + 冻结**；退役单独立项、暂缓（§22.6） |
| `procmatch` v1.0（`afcfad9`） | "同 printf 崩溃面" | 崩溃面收益来自主机制缓解；**独立价值 = 修了 busybox `pgrep -x` 漏判活进程的真 bug** | 保留 + 冻结 |
| `logc` v1.4 去 printf（`439806c`） | "SIGSEGV 根因" | **摘掉最高频的污染解引用点**（§16.4 选集效应），非根因 | 保留 + 冻结 |
| `logcut` v1.0 + `log_keeper` v2.6/v2.7（`30fb050` `ab815db`） | "busybox awk 缺陷" | awk 缺陷说**未证实且不再必要**（§16.3）；实际收益 = 少 spawn、无大数组堆页 | 保留 + 冻结 |
| `core_trap` + `core_meta`（`6bf5cfa`） | 取证缺口 | 证据管线（§16/§17/§21 的 core 全部出自它） | 保留（长期价值） |
| watchdog aee 增量判据（P4） | dmesg 限流盲区 | 实测有效 | 保留 |
| `logd` 开机清环（`log_keeper` v1.7） | "毒记录驻留环" | 前提被 §12/§16 双重证伪 | 无崩溃学理由；仅剩环卫生边际价值，**不动**（owner 可另行决定） |
| hardened `vfprintf`（`h_vfprintf.c`，oneoff） | "libc 侧修" | 技术有效但从未部署，且 guard 对 `gr_offs=0` 误伤（C8） | 归档为技术，**不部署** |
| P0 printf 复现器/分层二分（`0f1ddde`，oneoff） | "崩溃消除补丁" | 前提作废；分层二分方法本身可复用 | 归档，不部署 |
| `ap_auto_logging=0` 护栏 | 防 `logread -f` 常驻 | 仍正确（少一个无谓常驻崩溃面） | 保留 |

### 22.4 冻结规则（写入项目约定，后续轮次照此执行）

- **F1** 不再为"治崩溃"新增任何用户态替换（applet / 二进制 / 组件）。
- **F2** 新增或替换组件，必须能写出**与崩溃机制无关的独立价值**，否则拒绝。
- **F3** 文档与版本注册表**不得**再把 musl / awk / pidof 写成缺陷根因；机制表述一律
  指向 §21（外部 DMA 经回收页注入）。
- **F4** `gw/` 侧不再有崩溃修复主线；主线 = §23 的内核模块。

### 22.5 版本与注释的处置：为什么**不**回改产物注释

`logc` v1.4 与 `log_keeper` v2.7 是**证据锚点**（§10/§11 的 A/B 数据以版本号为锚：
"v1.3 7 崩/h → v1.4 0 崩"）。注释级改动会强制 bump 版本 + 重新部署 + 重启守护，
既打断证据链，又扰动根修要用的测量基线。

因此本轮更正**只落在两处**：本报告（§16.7/§22）与 `tools/VERSIONS.tsv` 的描述列
（`⟦收口 §22⟧` 标记）。产物文件头部的历史 changelog 保留原样，下一次**功能性**改动
时顺带修正——历史 changelog 本身是审计材料，不该被事后改写。

### 22.6 农场退役：立项、暂缓、验收后 A/B

退役**不是**因为农场有害，而是因为它是一笔"为已证伪前提付出的复杂度"（305 符号链接 +
启动耦合 + selftest 面）。但它现在是**唯一验证过的用户态基线**，在根修验收前动它，
会把"修好了没有"变成两个变量的问题。

- 触发条件：§23 根修上线并验收通过后。
- 设计：同一固件两臂（`fix + farm` / `fix − farm`），各 7 天，比较 crash/d、selftest、
  启动到 stable 的时间。**两臂都零崩溃**才允许退役（否则无法区分是修好了还是换了个
  受害者）。
- 在此之前：不删、不改、不扩。

### 22.7 修复主线与验收口径

- **主线**：§23 内核模块（leak-on-timeout + ack 循环上限 + 环页/DONE 位检查）。
- **前置基线**：近 24h 42 次（含本轮挑拨）/ 平静期 25.8/d。
- **验收的真相**：以 26/d 计，7 天期望 182 次，观测 ≤2 次的 p 值小到没有判别力——
  **统计判据不敏感**。真正的验收是"根修确实生效"：模块在位、补丁点命中计数、
  环记录命中归零（injwatch/sysscan 仪器已在位）。崩溃率只作旁证。

## 23. 2026-10-22 根修方案验证（第一阶：补丁原语 + 补丁点）

> 目标不是修好，而是回答"这条路能不能走"：**能不能在这台设备上安全地改内核指令？
> 要改的那 4 个字节，是不是反汇编说的那 4 个字节？** 全部只读 + 一次可回滚演练。
> 仪器：`tmpfiles/repro/dpxprobe.c` → `/data/repro/dpxprobe.ko`（不在仓内，oneoff）。

### 23.1 为什么先验这两件事

§17.5 的首选方案是"out-of-tree 模块钩住 dpmaif stop 路径"，但当时是**推断**。三个未知：
①设备上没有 kprobe（`register_kprobe` 不在 kallsyms），只剩运行期指令补丁一条路，能不能用？
②内核 5.15.134 的指令布局是离线反汇编（`ktext.bin`）得出的，现场是否逐字一致？
③补丁点选错 = 把 stop 路径变成随机崩溃。这三条不落实，写补丁就是赌博。

### 23.2 结果一：补丁原语可用（三态验证）

`aarch64_insn_patch_text`（`0xffffffc008122394`，kallsyms 有、模块里**按地址调用**，
不依赖导出符号）现场三态实测：

| 态 | 动作 | rc | 读回 | 设备 |
|---|---|---|---|---|
| 演练 | 把 `stoprx+0x2b0` 写成**同一个字** `0x97ffeab6` | 0 | `0x97ffeab6` | 正常 |
| 实改 | 写成 `nop`（`0xd503201f`） | 0 | `0xd503201f` | 正常 |
| 回滚 | `rmmod` → 写回 `0x97ffeab6` | 0 | `0x97ffeab6` | 正常（uptime 连续 2h+，无 oops） |

结论：**内核文本可写、可回滚、不掉核**。补丁机制这一层不再是风险点。

### 23.3 结果二：8 个补丁点与离线反汇编逐字一致

现场读回的指令字与 `ktext.bin` 反汇编**逐字节相同**，分支目标全部落到预期符号：

| 站点 | 现场指令 | 目标 | 判读 |
|---|---|---|---|
| `dpmaif_stop+0xe4` | `0x97fffc6a` bl | `dpmaif_stop_hw` | OK |
| `dpmaif_stop+0xec` | `0x97fffddc` bl | `dpmaif_stop_tx_sw` | OK |
| `dpmaif_stop+0xf4` | `0x97fffd2a` bl | `dpmaif_stop_rx_sw` | **RX 页在 ack 之前被释放** |
| `dpmaif_stop+0x164` | `0x54000080` b.eq | `stop+0x174` | ack==1 才离开循环 |
| `dpmaif_stop+0x16c` | `0x97f0f19c` bl | `msleep` | 每轮睡 1ms |
| `dpmaif_stop+0x170` | `0x17fffffb` b | `stop+0x15c` | **回跳，无计数器/无上限** |
| `dpmaif_stop_rx_sw+0x264` | `0x97ffa3d9` bl | `ccci_free_skb` | TX skb 释放 |
| `dpmaif_stop_rx_sw+0x2b0` | `0x97ffeab6` bl | `put_page` | **RX 页释放点（候选补丁点）** |

现场调用顺序（与 §17.2 一致，这次是现场读回而非静态推断）：

```
disable_irq → stop_hw → stop_tx_sw → stop_rx_sw(put_page!) → notify
            → 等 medmcu ack（msleep 1ms 无上限死循环）
            → hw_reset
```

即：**页在"通知对端"之前就已经回到伙伴系统**，ack 只用于后续的硬件复位。

### 23.4 结果三：RX 影子数组的布局与生命周期

从 `dpmaif_stop_rx_sw` 的取址链反推，现场验证通过：

```
ctrl = *(0xffffffc0092223f8)          ; 现场值 0xffffff8001780000
md   = ctrl + 0x488                   ; 每 MD/队列块
rx_shadow = *(md + 0x4098)            ; 0x780 项 × 32B = 0xf000
entry     = { page(struct page*), dma_addr, ?, len=0x1000 }
```

释放循环对每项：`dma_unmap_page_attrs` → `put_page` → `*entry = 0`（清项）。

**新事实（本轮最重要的一条）**：`rx_shadow` 指针**不是常驻**。15:08:59 读到
`0xffffff800fb80000`（数组在），15:09:31 同一字段已为 0（数组没了）——**队列在
一分钟内被建立又拆掉**。也就是说 teardown 不是"一天几次"，而是**跟着数据面状态走**。

### 23.5 这条新事实直接改写了修复设计

| 原设想（§17.5） | 本轮实测后的修正 |
|---|---|
| "leak-on-timeout：超时才不释放" | 仍成立，但**不能做成"每次释放都不释放"**：队列一分钟建拆一次，每次泄漏整个环 = 分钟级 MB 泄漏，必然 OOM |
| 给 ack 循环加上限 | 仍必须做（否则"等不到 ack"从泄漏变挂死）；但它是**第二个补丁**，不是第一 |
| 用 ctrl 索引定位活动队列 | **不成立**：`*(ctrlptr+8*i)` 只有 `i=0` 是活动 MD 的 ctrl，ccmni3(MD1) 的队列无法这样取到；定位必须回到 §21 的**签名扫描**（32B 步距 + len==0x1000 + vmemmap 页指针） |

补充观察：在 `put_page` 被 nop 的那次拨号里，MemFree 变化 −1.8MB，与正常拨号扰动
（±30kB 基线 + 进程/缓冲抖动）无法区分——**单次拨号不足以测泄漏**，泄漏量必须靠
"数组在场时逐项计数"或多次统计。这否定了"用一次拨号验证泄漏"的捷径。

### 23.6 未完成（诚实清单）

1. **活动队列的数组没抓到**：ccmni3(MD1) 正在跑 3/3 通的 ping，但通过
   `ctrl[0..3].md+0x4098` 读到的全是 0 → MD1 的 ctrl 不在我读的那组指针里。
   下一阶要用签名扫描（模块内扫 linear map）把**活动数组**找出来。
2. **三个候选释放点未判别**（全 driver 只有三处会还页）：
   `stop_rx_sw+0x2b0`（put_page）、`alloc_med_rx_frag`（put_page，错误路径）、
   `alloc_med_rx_buf`（page_frag_free）。§21 抓到的是"数组仍指向已释放页"，
   而 stop 路径**释放后会清项**——两者不吻合，所以**不能默认补丁点就是 stop**。
3. **refcount 审计仪器写好了但没跑出数据**：`dpxprobe audit=<秒>` 会每秒扫数组、
   统计 `struct page._refcount==0`（= 已回伙伴系统但环里还指着）的项数——这正是
   "活体 UAF"的直接读数。它需要数组在场才有输出，卡在第 1 条上。

### 23.7 下一阶（已定型，不再发散）

1. 模块内**签名扫描**定位活动 RX 数组（§21 的方法自动化），落到 `audit` 里；
2. 用 `_refcount==0` 计数**直接量出**"环里挂着已释放页"的条数（不改任何东西）；
3. 再按 23.5 的约束设计补丁：**只在异常路径泄漏**，并给 ack 循环加上限；
4. 补丁上线后验收看 `audit` 的 `freed-but-referenced` 归零，而不是先看崩溃率。

### 23.8 产物与现场状态

- 仪器：`tmpfiles/repro/dpxprobe.c`（只读探测 + 可选补丁演练 + refcount 审计）；
  设备侧 `/data/repro/dpxprobe.ko`（已 rmmod，**当前内核文本未被修改**，
  `stoprx+0x2b0` 读回 `0x97ffeab6` 原始指令，MemFree 1,232,040 kB）。
- 本轮副作用：两次拨号（15:07 落 ccmni2、15:11 落 ccmni3，均成功）；一次
  `put_page` 被 nop 约 29 秒后回滚（期间无 stop 发生，无泄漏）。

### 23.9 第二阶（15:29–15:40）：签名扫描与"活动队列"——**负结果**

第一阶留下了 23.6-1（活动队列取不到）。第二阶想用签名扫描绕开结构体：在 linear map
里按记录形状找环。**结论是这条路没走通，而且否掉了我原来的字段模型。**

**做了什么**：给 `dpxprobe` 加两件仪器——①签名扫描（扫 `0xffffff8000000000` 起
1.625GB，64KB 块，要求 8 条连续记录满足 `{page∈vmemmap, dma∈RAM 且 4K 对齐, ?, len=0x1000}`）；
②1 Hz 审计（逐项读 `struct page._refcount`，统计 `==0` 的项数，即"已回伙伴系统但环里
还指着"）。

**结果**：

1. **扫描器本身是好的**：`ok_chunks=24982 / bad_chunks=1642`，确实读满 1.56GB
   （1.5 秒级，`cond_resched` 分块），不是"静默跳过"。
2. **按模型签名（`{page, dma, ?, len}` × 32B）在 1.6GB 线性映射里一条都没有。**
3. 唯一命中的"32B 步距 + len=0x1000"结构，实际是 **16B `{page, 0x1000}` 表**：
   按 32B 看就是 `{page, 0x1000, page2, 0x1000}`，两个页指针相隔 14 页。不同地址
   各有实例（`0x121c000` 202 项、`0x1268080` 941 项），内容随时间小幅变化。
4. **`ctrl[i].md+0x4098` 解析到的正是这类 16B 表**（`0x121c000`），不是
   `{page, dma}` 环 —— 即 23.4 的字段模型（`md+0x4098` = RX 影子数组）**是错的**，
   至少不是 `stop_rx_sw` 用的那个数组。
5. 顺带读数：那批 16B 表里约 941 项中有 13 项页 `_refcount==0`。**未定性**——
   可能是 page_frag/page_pool 缓存的正常状态，**不作为证据**（这正是"看着像证据"
   的陷阱）。

**影响（重要）**：

- 23.3 表里 `stoprx+0x2b0` 只是"那里确实有一条 `bl put_page`"，**不等于**
  "那条 `put_page` 释放的就是后来被复用的页"。**补丁点仍未验证，不能据此落地。**
- §21 的描述符证据**不受影响**：它是"命中页 PA 出现在环条目里"的 PA 级匹配，
  不依赖本文的字段模型。
- 本轮**没有**产生任何"修复有效/无效"的结论，也没有改动设备行为。

**下一阶改走两条更硬的路**（不再猜结构体）：

1. **读硬件寄存器**：模块 `ioremap` dpmaif 寄存器块，直接读 BAT/PIT 基址寄存器，
   按 PA 到线性映射核对记录格式（§21 的 `0x84cdd000` 可作锚点）。这是"环在哪"
   的第一手答案，不依赖任何字段偏移猜测。
2. **行为法测站点命中**：补丁原语已验证，可以对候选站点做"nop + 长窗口统计"
   （MemFree 阶梯 + 该数组 `_refcount` 变化），用**是否被命中**来反推该站点是否
   在数据面上，而不是先理解结构。

> 自我约束：这一阶是负结果，且是我第二次在"结构体偏移"上猜错（第一次是 15:04 的
> `md+0x48/0x4098`）。**后续不再用字段猜测推进**，只用寄存器或行为读数。

### 23.10 第三阶（15:39–15:47）：寄存器路线——环找到了，但不是我以为的那个格式

**仪器**：`dpreg.ko`（`ioremap` + `readl` + `copy_from_kernel_nofault`，全程只读）。

**DTS 实证的寄存器布局**（`/proc/device-tree/*/reg` 原始字节）：

| 节点 | 区间 |
|---|---|
| `dpmaif@0x10011000` | 0x1022d000 / 0x1022c000 / 0x1022e000 / 0x15b14000 / 0x15b38000 / 0x15b13000（各 4KB） |
| `dpmaif_ao@10011000` | 0x10011000 |
| `infra_dpmaif@1022c000` | 0x1022c000 |

**环基址寄存器（0x1022d000 的转储）**：

```
+0x180: 8f980000 8f98a000 0000a00d 40003fff
+0x1e0: 8fb20000 8fb3fff8 0000a00f 40003fff
```

`0x8f980000` / `0x8fb20000` 都落在 System RAM 内、4K 对齐 —— 这是 BAT/PIT 基址寄存器。
（顺带纠正 §23.9：`is_ram_pa` 当时上限写成 0x68000000，把这两个值直接滤掉了。）

#### 关键修正：线性映射不是 `VA = PAGE_OFFSET + PA`

三点现场实证：

- `VA 0xffffff8001780000` 读到 ctrl（值本身也是这个地址）；
- `VA 0xffffff8080000000`（= PA 0x80000000 的朴素映射）**读取 FAIL**；
- `/proc/iomem`：System RAM 从 **0x80000000** 起（MemTotal 1.7GB）。

⇒ **`VA = PAGE_OFFSET + (PA − 0x80000000)`**，即 `memstart_addr = 0x80000000`。

推论：ctrl 的真实 PA 是 **0x81780000**（不是 0x1780000）；§21 的
`0x84cdd000` 对应 `VA 0xffffff8004cdd000`。**§23.9 那次"全 1.6GB 扫描无命中"，
有一部分是扫描窗口偏了 0x80000000。**

按修正映射重扫 PA `0x80000000..0xa0000000`（6981 个 64KB 块全部读到，
`bad_chunks=1211` 是空洞）：**仍然没有** `{page, dma∈RAM, 4K 对齐, ?, len=0x1000}`
这种 64 位记录。

#### 环的真实格式（直接读 PA `0x8f980000`）

```
+0x00: 00000000a0897840 00000000a0897040
+0x10: 00000000a0896840 00000000a0896040
+0x20: 00000000a0895840 00000000a0895040
...
```

- **32 位描述符**：每项 = 2KB 粒度的 PA + 低位置位（`0x840` / `0x40`）；
- 相邻项 PA 递减 `0x800`，即**一对描述符覆盖一个 4KB 页**；
- 表长 `0x780` 项（1920），与 §21/§23.4 记的 0x780 一致；
- 第二张同形状表在 PA `0x8fb20000`。

⇒ **这个状态下驱动用的是 32 位 PA 描述符环，不是 64 位 `{page, dma}` 影子数组。**
§23.4 与 §23.9 的模型错在这里（第三次在结构上猜错）。

#### 未完成：refcount 判据没跑通

想用"环里描述符 PA → `struct page` → `_refcount==0`"直接数"环里挂着已释放页"的
条数，**960 项全部 unreadable**。原因是 vmemmap 基址 / `struct page` 尺寸的假设不对：
观察到的页指针都挤在 `0xfffffffe008xxxxx`（对应 PFN ≈ 0x2xxxx），与 PA `0x8fxxxxxx`
不自洽。

#### 下一阶（先解 vmemmap，再谈补丁）

1. **定 vmemmap 基址与 `struct page` 尺寸**：取一个已知页做反解——用两种候选映射
   读 refcount，只有 `==1`（被驱动持有）的那个是对的。
2. **换判据**（不依赖 struct page）：把活环里的 960 个 PA 与"用户进程页"求交
   ——即 §21 的 PA 匹配法，只是这次 PA 来源是**活环**而不是扫描命中页。
3. **补丁点仍未定**：现在知道环是 32 位 PA 描述符 + 2KB 粒度，而 `stop_rx_sw`
   里 `put_page` 处理的是 64 位 `{page, …}` 数组，**两者不是同一个结构**。那条
   `put_page` 很可能属于另一条（TX 或备用）路径。**在 vmemmap/判据问题解决前，
   不动补丁。**

> 本阶段三个模块（dpxprobe / dpreg）全部只读，未改设备行为；设备已 rmmod 清理。

## 24. 2026-10-22 16:00–16:15：从寄存器走到补丁候选（含两次自伤重启）

> 本节记录一次**没走通到底**的攻关，以及两个候选补丁。诚实结论在 §24.5。

### 24.1 寄存器路线拿到的硬事实

| 事实 | 证据 |
|---|---|
| BAT 基址在 `reg+0x180`、PIT 基址在 `reg+0x1e0`（`reg=0x1022d000`） | `dpreg` 现场读 |
| 两张表都是 **32 位 PA 描述符**（2KB 粒度 + 低位置位），各 0x780 项、960 项在用 | 直接读表 + `ringaudit` |
| **基址会移动**：16:0x `bat=0x8fb00000` → 16:11 `bat=0x8fb60000` | `dpbatfix` 每秒读 |
| 基址页在采样瞬间都是"owned"（`count>0`，非 anon/buddy/slab） | `ringaudit` 1 Hz 轮询 30 分钟（含一次拨号）**从未**出现 anon/buddy |

### 24.2 一个被我自己否掉的"铁证"

16:11 我用 `pfnprobe` 查 `0x8fb00000`，得到 `count=0 buddy=1`——看起来是"基址寄存器指向已释放页"的铁证。
**但那是陈旧值**：同一时刻 `dpbatfix` 读到的寄存器已经是 `0x8fb60000`。`0x8fb00000`
只是上一轮窗口被回收后的普通空闲页。**该"铁证"作废，不作引用。**（教训：读寄存器与判读
页状态必须同一次采样内完成。）

### 24.3 停路径补丁：dial 实测**不泄漏** ⇒ 该站点在拨号路径上未被命中

`dpxfix.ko` 把 `dpmaif_stop_rx_sw+0x2b0` 的 `bl put_page` 改成 `nop`（RX 页永不归还），
然后做了一次拨号并 2 秒粒度采样 MemFree：**没有任何 2–8MB 台阶**（波动 ±0.5MB）。
⇒ 至少"拨号（deact+act）"这条路径上，那个 `put_page` 没有执行（或表为空）。
§17.5 的 stop 路径假设因此**被削弱**（不是被推翻：真正的 dpmaif stop 可能在 MD 复位时才发生，
本轮没有去触发）。

### 24.4 候选补丁：描述符窗口页保护

思路：不猜"谁 free"，而是让**驱动已经交出去的页**不会被 buddy 分给用户进程。

`dpbatfix.ko`（运行中，低风险版）：
- 每秒读 BAT/PIT 基址，把 `[base, end)` 覆盖的页 `get_page()` 住；
- 页离开窗口后**再压 300 秒**才 `put_page`（覆盖 MD 的在途写）；
- 持有上限 1024 页，`rmmod` 全量释放。
- 只 pin **描述符窗口本身**那一页，不 pin 整个 0x60000 窗口——后者会把驱动的缓冲池饿死。

当前状态：已加载，持有 2 页（`0x8fb60000` / `0x90800000`），MemFree 1,281,200 kB 稳定。

### 24.5 诚实结论

1. **没有拿到"实战通过"的补丁。** 手里是一个机制上对得上、风险受控、但**尚未被证伪也未被证实**的缓解模块。
2. 无法在本轮内验证的原因：**崩溃是剧集式的**。`ne_events.tsv` 与 `cores/meta` 的最后一条都是 **13:27**，
   到 16:15 已 **2h48m 零崩溃记录**（期间有两次重启）。没有剧集，就没有判据。
3. 下一轮的唯一有效动作：**等/造一个剧集**（拨号风暴或 MD 复位），在剧集里比较
   "有 dpbatfix / 无 dpbatfix" 的注入命中数（injwatch），而不是等崩溃。

### 24.6 本轮自伤（必须记录）

| 时间 | 事件 | 原因 | 恢复 |
|---|---|---|---|
| 15:55 | 设备重启 | `ringaudit` 的 1 Hz 定时器里调 `ioremap()`（会睡眠）→ atomic context BUG | 约 50s 自行起回 |
| 16:02 | 设备重启 | `scantbl` 把扫描命中的任意 64 位值当 `struct page *` 解引用 → 坏指针 oops | 约 20s 自行起回 |

两次都由设备自身恢复，未造成持久损坏；但这说明**在 timer 上下文里不能 ioremap、扫描结果必须先做指针合法性校验**。

## 25. 2026-10-22 16:20–17:30：注入速率 A/B 与"页地址"仪器（候选缓解被否）

### 25.1 有了可量化的注入速率

`injwatch3`（每轮 mmap 128MB 新页、写 0、15–20 秒内每 100ms 扫描）在**剧集期**能稳定报出
被外部写入的页数。本轮实测：

| 时段 | 速率 |
|---|---|
| 16:21–16:33（平缓） | 0–3 页 / 90–100 秒 |
| 17:16–17:24（剧集） | 2 → 4 → 5 页 / 90 秒（递增） |

同期 `ne_events.tsv`：17:12:56 `mipc_wan_cli` SIGSEGV、17:13:03 `ip` SIGSEGV，
16:53–17:13 共 20 条。**剧集是真的，且可用注入速率量化。**

### 25.2 两个候选缓解都被否掉

| 方案 | 做法 | 结果 |
|---|---|---|
| `dpbatfix`（pin 描述符窗口） | 每秒 pin `[BAT_base, +0x60000)` 的页，离开后隔离 300s | off 1.0 页/轮 vs win 0.8 页/轮（ab5：off 2,2,0,2,0,0；win 1,0,1,0,2）→ **无效果** |
| `pinq`（pin 表内所有页） | 每秒扫 BAT/PIT 全部 1920 项，pin 其引用页（实测只有 117 个唯一页） | off 2,4,5 vs pinq 1,5 → **无效果** |

两者都不影响数据面（ccmni ping 3/3、`rx_drop=(0,0)`、MemFree 稳定），但都不减少注入。

### 25.3 为什么无效：注入页根本不在被 pin 的范围内

新仪器 `injwatch4`（在 `injwatch3` 基础上用 `/proc/pfnprobe` 解析被污染页的**物理地址**）
在剧集期抓到：

```
PAGE pa=0xbd28f000 off=0x7fff000 word=504 val=0x23d90
```

再用 `findpa.ko` 在 RAM 里搜这个 PA，命中两处**描述符**：

```
PA 0x9073b280: bd28f000 80000000 40000000 0000000c
PA 0xad7a75c0: bd28f000 80000000 40000000 0000000c
```

即 **16 字节描述符 `{pa, 0x80000000, 0x40000000, 0xc}`**，而这两处地址
**都远在 `[0x8fb00000, 0x8fb60000)` 之外**（0x9073b280 在 PIT 基址 0x90800000 之前，
0xad7a75c0 更是另一个 464MB 之外的副本）。所以 §25.2 的 pin 范围选错了——
这不是"缓解无效"，是**没 pin 到该 pin 的地方**。

### 25.4 下一轮（已经明确）

1. 用 `findpa` 的命中地址反推描述符环的**起点与长度**（16B 步距、`{pa, 0x80000000, 0x40000000, 0xc}` 形状）；
2. 把 `pinq` 的目标从"BAT/PIT 表内页"改成"**这些 16B 描述符环引用的页**"，或直接 pin 环本身覆盖的页；
3. 重跑 `injwatch4` 的 A/B（现在有 PA 可看，判据从"页数"升级到"PA 是否还在环里"）。

### 25.5 状态

- 设备：`findpa`/`pinq`/`pfnprobe`/`dpbatfix` 全部已 rmmod，MemFree 1,277,948 kB，uptime 1:25。
- 本轮**没有**产生可实战的补丁；但把"注入页的物理地址 + 指向它的描述符地址"这条链打通了，
  下一轮的 pin 范围不再是猜的。

