# NEREPAIR 效力审查（离线读 + 设备只读，2026-11-03）

> 审查对象：gw/src/nerepair.c **v2.2**（设备在役 md5 811b3e195132224296fc97fa60495760，83,800 B，与仓库 gw/bin/nerepair 逐字节同源）。
> 审查问题：nerepair 到底有没有、以及在多大程度上减少 SIGSEGV 崩溃。
> 方法边界：**全程零写**。离线只读仓库与本地证据；设备侧仅 tools/lgssh.py 只读命令（无 push/put/devop/dd/chmod/touch/rm/kill/reboot/挂载/重定向/tee，无轮询循环）。
> 证据等级：**E0** 无证据 · **E1** 弱 · **E2** 强推断 · **E3** 直接观测 · **E4** 因果闭环。
> 不可引用（项目内已撤回）：88/112、自然 NE 0/4、C-138、C-145（Transport=PA/DMA 已定）、C-016/017/018/019。本文一律未引用。
> 设备时间锚：date = 2026-11-03 19:23:15 CST，/proc/uptime = 5863.52 s（⇒ boot = 17:45:32，与观察窗起点一致）；最新 STAT epoch 1793704980 = 19:23:00。**本文所有设备 epoch 按此锚换算**（nerepair.log 的 iso 字段在时钟校正前后有偏差，见 §2.4）。

---

## 0. 判决（三句话）

1. **行为级成立（限"判据命中且 armed"的前提下）**：修复动作链在代码上完整、可复核，唯一允许改寄存器的三处 PTRACE_SETREGSET（gw/src/nerepair.c:758,926,965）**中，path 1（L883→L965）、X1（L910 record_at→L926）、X3/mode 2（mode 2 内 shape_ok→L758）都过 shape_ok 硬门；但 deref 默认路径 path 2 / mode 0（→L758）不调用 shape_ok，其门弱于 shape_ok**（只做 w1==w3==0 + low32(q0) 或 low32(q2) ≈ addr±8 + len_band(该字)，见 §1.1 硬门行与 §1.3g）；设备侧有自注入正对照的聚合证据（tmpfiles/an4/overnight_report.md:21-22：SEGV 4 / REPAIR 3，全部 comm=rectest）。**但这是"我们自注入的崩溃被救活"，不是自然崩溃被救活**（E2/E3，见 §3.1）。
2. **家族层面预期救活比例**：**记录层** 150/150 被判据接受（100%，可复跑），但**崩溃层**在设备上只能测得 **4/20 = 20.0%（Wilson 95% CI 8.1–41.6%）** 的自然 SEGV 命中可修判据——且这 4 起**全在 deref 路径（v2.0 path 2，不受 XREP 门控）**，**pop 路径自然命中 0/20**（E3，实测；口径为 dry-run、跨 1 次 boot、含实验密集期，不可当稳定速率）。前提：判据不放宽、进程死在判据覆盖的形态上。
3. **设备上目前"减少崩溃"＝尚未发生，不是"已证明"**：设备当前 **dry-run（零修复）**——/data/gw/nerepair.dry 在位、START ver=2.2 dry=1 xrep=0、447 条 STAT 全 mode=dry、REPAIR/DREPAIR/XREPAIR/WOULD_XREP/XFORM 精确计数全 **0**（E3，我实测）。观察窗 17:45:32 起至 19:40 共 **2 起** NE：① 18:58:11 slotguard（far=0xffffffffffffffd8，**非家族**，其 .stack 经 8B 步进扫描 **0** 条家族记录）；② 19:29:05 od（/data/gw/bin/busybox applet，**观测者注入**——由只读取证命令 /data/gw/sbin/od 派生，规范 A0B2 记录 q0=0x1ee27/len=1601/ip=192.168.9.1，nerepair 判为 deref 可修 WOULD_DREPAIR path=p2 which=q0）。⇒ **窗内"无家族活动"的说法必须撤回**（取证读取本身会注入事件，§6.6）；24 h 窗在现有 dry 配置下**产不出"下降"证据**，只能产出命中率的分子/分母（§6.5）。

---

## 1. 机制边界：代码 vs 文档逐条核对

### 1.1 判据一致性（FIX.md §0.2 ↔ nerepair.c）

| # | 文档条款（出处） | 代码实现（gw/src/nerepair.c） | 判定 |
|---|---|---|---|
| A | 路径 1：pop 型自指形式 LDR/LDUR/LDRB/H/SW（FIX.md:43） | is_ldr_same() L281-291，9 个掩码：LDR(64/32) imm、LDUR(64/32)、LDUR reg-offset(64/32)、LDRB、LDRH、LDRSW | **一致**（未含 pre/post-index LDR、LDP、LDRSB/SH —— 文档未声称） |
| B | rt == rn（FIX.md:44） | L853 | 一致 |
| C | si_addr == regs[rt]（FIX.md:45） | L865 | 一致 |
| D | shape_ok(x2 处 32B, si_addr)（FIX.md:46） | L877-883 → shape_ok() L306-322（w1==0 ∧ w3==0 ∧ w0∈{f,f+8}(tag 掩码) ∧ 长度带 0x400..0x20000） | 一致 |
| A2 | 路径 2：load、非 store、非 FP（FIX.md:50） | is_load_insn() L542-553（显式排除 store 与 V=1/FP） | 一致 |
| B2 | 0 < si_addr < 16 MiB（FIX.md:51） | L710（addr==0 即返回）+ L714（< DEREF_SMALL_MAX=1<<24） | 一致 |
| C2 | rn != 31（FIX.md:52） | L712 | 一致 |
| D2 | [sp,sp+16KB) 内记录、q0 或 low32(q2) == si_addr(±8)、硬门（FIX.md:53-54） | find_record_near_stack() L627-689（DEREF_SCAN_BYTES=16K L535、stride 8 L649、len_band L678-682）；record_probe L393-400 | 一致（**注意 L658-663，见 §1.3a**） |
| 顺序 | "路径 1 优先，失败才走路径 2"（FIX.md:57） | 三条失败分支内才调 deref_attempt（L850/862/874/880/940） | 一致 |
| 吞信号 | → regs[rt]=sp; pc+=4; 信号吞掉（FIX.md:47/55） | 改寄存器 L962-965；返回 1 → main L1146-1149 PTRACE_CONT(pid,0,0)（sig=0＝吞掉） | 一致（**E3，代码级**） |
| 硬门 | "没有记录证据就绝不修"（FIX.md:58） | **分强度**：path 1（L883 shape_ok→L965）、X1（L910 record_at→L926）、X3/mode 2（mode 2 内 shape_ok，L715-725→L758）**过 shape_ok**；**path 2 默认（ext=0，mode 0，→L758）不调用 shape_ok**，其门是 L656-683 的 w1==w3==0 ∧ (low32(q0) 或 low32(q2) ≈ addr±8，±8 见 L672/678) ∧ len_band(该字) | **部分不一致**：文档把 D2 与 path 1 并列为"硬门槛"，实现上 mode 0 是**弱门**；"没有记录证据就绝不修"仍成立（仍需某种记录证据），但**"证据 = shape_ok"只对 path 1/X1/X3 成立**（§1.3g） |
| 只修 load | "绝不修 store"（FIX.md:59） | deref_attempt 先 is_load_insn（L708）；X1 走已验证的自指 load | 一致 |

### 1.2 dry-run 不变量（"不修、不吞信号"）

g_dry 分支位于**任何寄存器写之前**（L951-961，g_would++ 后 return 0），三条修复点的 PTRACE_SETREGSET 分别在其后（L965）或受 g_xrep 双钥匙门控（L915 X1、L737 deref）。
复核命令：grep -n 'PTRACE_SETREGSET|g_dry|g_xrep' gw/src/nerepair.c。**E3，代码级**，与 05_LOG/2026-11-01-fix-design.md:98 的静态断言一致。

### 1.3 发现的代码/文档不符与代码级缺陷（全部 E3，代码级）

| # | 发现 | 出处 | 影响 |
|---|---|---|---|
| a | **X2 的地址匹配比 shape_ok 更严（无 ±8 容差）**：mode 1 要求 q0 == si_addr 精确（tag 掩码），只有 mode 2 才接受 q0 == addr+8 | 代码 L661-663 vs shape_ok L318 | 若按 C-005 口径（"转储 word0 是 va_arg 自增后、故障地址是自增前"）则 B0A2 记录的 w0 = 故障地址+8 ⇒ **X2 会漏**。两种口径必有一与实现不符 → §8 待对账；host 22 项断言亦未构造 addr+8 用例（nerepair_v22_test.c:98-100 只测精确命中与"差 1"拒绝） |
| b | **NEAR 的"近失"判断未做 tag 掩码**：w[0] == fa 或 w[0] == fa+8（未掩 tag），而 shape_ok 两侧都掩 | L891 vs L308-318 | B 型（顶层字节 = IP 段）故障的 NEAR 可能漏计 ⇒ NEAR 计数是**下界** |
| c | **deref 路径的熔断不累加 g_loop**：deref_attempt 的 breaker 分支只打 PASS reason=repair-loop，无 g_loop++（对照 main L946、X1 L934） | L748-751 | STAT loop= 会漏计 deref 路径熔断。**设备上未见证**（v2.1 STAT 的 loop 在涨、上机 v2.2 的 98 条 STAT 全 0，两组都无 deref-repair-loop 证据） |
| d | **g_abuse 是死字段**：声明（L119）并打印（L1096-1098），全文件无自增点 | grep 复核 | STAT abuse= 恒 0（设备 447 条 STAT 全 0，印证）——该字段不可作判据 |
| e | **FIX.md §0.2 主体未随 v2.2 更新**：主体只有 v2.0 两条路径；X1/X2/X3 只出现在 FIX.md:123-126 增补段与 SLOTGUARD_DESIGN §2.2 | FIX.md:39-59 vs 代码 L14-25/L908-938/L726-732 | 文档落后于代码；不是实现缺陷，但"逐字理解 §0.2"会漏掉三条默认关的扩展路径 |
| f | **熔断在 dry-run 之前被消费**（同一站点修满 8 次后转 repair-loop PASS，不再记 WOULD_REPAIR） | 代码 L943-950 在 L951（if (g_dry)）之前 | **dry-run 的 WOULD_REPAIR 是"被熔断截尾"的计数**，不能当"若 armed 会救活"的无偏估计（设备证据：395 条 repair-loop vs 141 条 WOULD_REPAIR，同一探针，§3.3） |
| **g** | **path 2 默认路径（mode 0）的判据弱于 shape_ok，且回归测试未覆盖其假阳性面**：mode 0 只查 w1==w3==0 + 地址近似 + `len_band(该字)`；"把 A 值当长度带"（L678-682）意味着**任何落在 0x400..0x20000 的 A 值都会被接受**，无需完整记录形状 | 代码 L656-683；mask_test 只验 shape_ok（0/8 阴性） | **这是"真实 NULL/小指针被吞"的残余风险面**：设备上已见 mode 0 接受的样本（§3.3 的 vsurv5 `which=q0`；§6.6 的 `od` 观测者注入事件 `which=q0`）；0/8 的阴性结论**不能外推**到 mode 0 ⇒ 下一轮应补 mode 0 的阴性用例 |

---

## 2. 设备现状：armed 还是 dry-run（本节全部为 2026-11-03 只读实测，E3）

### 2.1 只读审计台账（观测者污染审计用）

| 主机时刻 | 设备 uptime | 命令（要点） | 结果 |
|---|---|---|---|
| 19:23:16 | 5863.52 s | ls -l /data/gw/nerepair.dry /data/gw/nerepair.xrep /data/gw/slotguard.arm；wc -l -c nerepair.log；grep -E "START\|MODE"；grep STAT；cat /tmp/nerepair.hb；cat /proc/uptime | dry 在位 / xrep 无 / arm 无；2059 行 253,625 B；hb=5847（age 16.5 s） |
| 19:23:50 | 5896.69 s | awk 事件分类计数 + comm 直方 + 非 canary 家族事件 + PASS 原因 | 见 §3.3 |
| 19:24:25 | — | cat /data/gw/logs/nerepair.log（全量取回，本机 2061 行） | 与设备端 awk 聚合交叉一致（§3.3） |
| 19:25:23 | — | wc -l -c ne_events.tsv；ls -l cores/meta/*.stack；覆盖普查（readlink /proc/*/exe + TracerPid） | 1723 行/186,821 B；96 个 .stack；用户进程 57 / 被追随 56 |
| 19:25:51 | — | 窗口后 NE 过滤；slotguard .stack 头解析；分块取回 | 见 §2.5/§3.4 |
| 19:26:58 | — | 家族记录扫描器（先在主机已知阳性件验证，再扫设备） | slotguard .stack = **0 条** |
| 19:27:42 | 6128.88 s | 4 条自然预测修复 vs NE 死亡台账交叉；.stack 普查；锚点复读 | **4/4 都在 NE 台账**（§3.4） |
| 19:40:07 | 6875.27 s | （复核 skeptic 报的 19:29 事件）取 epoch≥1793705220 的全部 nerepair 事件 + STAT tail + ne_events 窗口计数与新增行 | 19:29:05 `od` **观测者注入**事件（BIN/SEGV/PASS/WOULD_DREPAIR 四行）；窗口 NE = **2** |

零写声明：本次共 **9 次**只读 SSH 快照，无任何写命令。分块取回 ne_events.tsv 只成功 1125/1723 行（65.3%），601–1200 行区间用 sed 与 tail+head 各试一次均失败 ⇒ **该文件的本地逐行解析不完整；本文凡涉 ne_events 的结论一律以设备端聚合与"窗口后全量记录"为准**（按纪律不拿抽样冒充全量）。
**观测者注入（自我披露）**：19:25:51 与 19:26:58 我的两次快照在设备上执行了 `/data/gw/sbin/od`（读 .stack）；19:29:05 一起 busybox applet `od` 的**规范 A0B2 崩溃**（NE 台账 args 含 `/data/gw/sbin/od -An -v -tx1 …`）被记为 NE 死亡、并被 nerepair 判为 `WOULD_DREPAIR path=p2 which=q0` ⇒ **该事件归因观测者（取证读取），不计入自然分母**（§6.6）。

### 2.2 结论：**dry-run（零修复）**

| 证据 | 值 | 出处 |
|---|---|---|
| dry 标记 | /data/gw/nerepair.dry 在位，0 B，mtime Nov 1 18:01 | 设备 ls -l（19:23:16 实测） |
| XREP 第二钥匙 | /data/gw/nerepair.xrep **不存在** | 同上；亦见 _local/evidence/f1-deploy/step9-window-snapshot.txt:7 |
| 进程自述 | 最新 START：pid=4426 ver=2.2 dry=1 xrep=0 canary=/data/repro/vsurv4 resolved=1；MODE dry=1 source=marker | 设备 grep |
| 运行态 | 447 条 STAT **全部** mode=dry；最新 1793705220 … mode=dry attached=45 segv=1 repaired=0 passed=1 would=0 would2=0 near=0 nearinsn=0 xform=0/0/0/0/0/0/0/0 xrep=0 xw=0 xr=0 | 设备 grep STAT（19:27:42 实测） |
| 事件侧 | 全日志精确计数：REPAIR=0 DREPAIR=0 XREPAIR=0 WOULD_XREP=0 XFORM=0 | §3.3（我独立复核） |

⇒ 与 FIX.md:29「v2.2 已上机在役…X1/X2/X3 默认关」、VERDICT.md:156「/data/gw/nerepair.xrep 未建」一致；与 05_LOG/2026-11-01-r7-lab-device.md:14/16 的 v2.1 dry-run 同源延续。
**"观察模式"在 11-03 文档里指 XREP/slotguard 未布防，不必然等于 dry；但设备实测直接给出 mode=dry（且 launcher 不注入 NEREPAIR_DRY，见 gw/nerepair_launch.sh:9-11，故 dry 只能来自 marker 文件）⇒ 当前是 dry-run，无歧义。**

### 2.3 心跳与覆盖

- 心跳：/tmp/nerepair.hb = 5847 @ uptime 5863.52 ⇒ age **16.5 s**，远小于 60 s 周期与 watchdog 的 180 s 上限（gw/svc_lib.sh:340 的 SVC_TABLE nerepair 行 max-hb-age 180）。
- 覆盖（我实测，E3）：用户进程 **57**（readlink /proc/<pid>/exe 非空）、TracerPid≠0 者 **56**，且**唯一的 TracerPid 值是 11617**（= nerepair 自身）。⇒ 排除自身后覆盖 = 56/56 = **100%**；不排除自身 = 98.2%。**覆盖不是瓶颈。**
- ⚠️ **读法纠正**：STAT 的 attached=45 **不是**活覆盖数，而是"累计 attach 事件数"（g_attached++ 仅在 attach_pid 成功处，L1011），fork 后代由 PTRACE_O_TRACEFORK|… 直接跟随、不记账 ⇒ 它系统性**低于**实时被追随数（本次 45 vs 56）。FIX.md:254 用 attached 判"覆盖 ≥99%"属**口径错误**，应改用 TracerPid 全量扫描（本次方法）。

### 2.4 时间轴口径（避免误读日志）

- 文件顺序 = 追加顺序，但 **epoch 非单调**：11-03 17:45:27 healthdog 复位；复位后新 boot 的时钟仍是"假钟"（日志 iso 记为 00:35:21，epoch 1793637321），NTP 校正后才回到真钟。因此**分段必须按文件顺序 / START-STAT 计数，不能按 epoch 排序**（我按 epoch 排序试过一次，得到"负跨度"，已废弃）。
- 锚：最新 STAT epoch 1793704980 = 19:23:00，date = 19:23:15，uptime = 5863.52 ⇒ boot = 17:45:32（= 观察窗起点）。据此 WOULD_REPAIR 首末 1793673800–1793682010 = **10:43:20–12:59:59**。
- 文件顺序地标：L1566/1567 START pid=11978 ver=2.1；L1632/1633 START pid=12079 ver=2.1；L1910/1911 START pid=4426 ver=2.2（=17:44:01，复位前 90 s）；L1912/1913 START pid=11617 ver=2.2（复位后）。**全日志 EXIT=0** ⇒ 4 个实例都不是被 SIGTERM 正常收尾的（要么 kill -9、要么随复位消失）。

### 2.5 观察窗（17:45:32 起）实测

- NE 台账新增：**2 条**（19:27:42 实测 = 1；19:40:07 复核实测 = 2）：
  ① 1793703491 11618 slotguard sig=11 exe=/data/gw/bin/slotguard origin=vendor-tree far=0xffffffffffffffd8 pc=0x101e7e8（18:58:11）；
  ② **1793705345 29866 od** sig=11 exe=/data/gw/bin/busybox（applet `od`）origin=unknown args 含 `/data/gw/sbin/od -An -v -tx1` far=0x1ee27 pc=0x4e6f68（19:29:05）——**观测者注入**：该进程就是取证读取命令自身（§6.6），不计入自然分母。
- nerepair 侧同窗 2 起 SEGV，与 NE 台账一一对应：① `insn=0xb9800108`（LDRSW x8,[x8]，x8=si_addr=0xffffffffffffffd8）→ `PASS reason=shape-fail`（未修）；② `insn=0xb9400060`（LDR w0,[x3]）→ `PASS reason=rt-ne-rn` → **`WOULD_DREPAIR path=p2 which=q0 q0=0x1ee27 q2=0x109a8c000000641`**（dry-run 未修，STAT `would2=1 dfhit=1`）。
- .stack：/data/gw/logs/cores/meta/1793699132-11618-1793703491.stack（65,592 B；头解析：magic SDMPv1、pid=11618、stack=[0x7fe6566000,0x7fe6576000)、npages=16、bitmap=0xffff、ts=1793703491 ✓ 自洽）。
- **家族记录扫描 = 0 条**（8 B 步进、w1==0 ∧ w3==0 ∧ (A0B2 或 B0A2)；扫描器先在主机已知阳性件 _local/evidence/crash-root/natne/1793477586-17847-1793509363.stack 上验证能命中 2 条记录，再扫设备 ⇒ **有检出能力的阴性**）。⇒ 该崩溃与本家族无关，按"另类崩溃，未归因"记录（far 为负偏移 −0x28，形态同 04_FAMILIES 的 D 族负偏移）。

---

## 3. 效力证据分级

### 3.1 (a) 行为级正/负对照

| 项 | 内容 | 等级 | 判读 |
|---|---|---|---|
| 正对照（产物） | tmpfiles/an4/rectest.c（+ 二进制 tmpfiles/an4/rectest，1.0 MB）——自注入 32B 记录进自己的 va_list，成功则打印 SURVIVED n=…；公开仓同源件 tools/oneoff/sigsegv/rectest.c | E3（代码存在） | 装置本体可复核 |
| 正对照（设备读数） | tmpfiles/an4/overnight_report.md:21-22：events {'START':2,'ATTACH':134,'SCAN':2,'SEGV':4,'REPAIR':3,'PASS':10}；REPAIR by comm {'rectest': 3}；PASS reasons {'not-load':1,'canary':9} | **E3（设备侧聚合）** | **唯一一条真实设备 REPAIR 计数**：3 次，全部是我们的注入探针。报告窗仅 46 s（epoch 1788942873→1788942919），"overnight"名不符实 |
| 负对照 | sh -c 'kill -11 $$' → rc=139：多份本地控制台记录 tmpfiles/an4/{t2_log.txt,ulimit_log.txt,batch_log.txt,batch2_log.txt,aee0_log.txt}（"rc=139；.stack/.stackerr 仍空；ne_events 无新行"） | E2 | 只能证明"nerepair 不是无差别吞信号"，**不能**证明判据正确性（D 族崩溃本就不该修） |
| 原始日志 | **本地工作区没有 /data/gw/logs/nerepair.log 的历史副本**（fix-design.md:563-564 早已记载此缺口；本次在役日志已由我全量取回并留档 tmpfiles/review/efficacy/nerepair_log.txt） | — | ⇒ 上述 3 条 REPAIR 的 pc/fault 无法逐行复核 |

**判定**：行为级正对照**成立但其对象是自注入探针**（E2/E3）。**没有**任何一次"自然进程被修好"的设备直证。

### 3.2 (b) 判据回归：可复跑（我本次独立复跑，E2 host）

| 断言 | 命令 | 我的结果 | 与文档 |
|---|---|---|---|
| mask_test | _local/work/crash-root/fix/nerepair_mask_test.exe _local/evidence/crash-root/h4_rec150.txt | records 150；v1.7 **150/150**、v1.8 **150/150**；8 条合成阴性 v1.7 误接 **3/8**、v1.8 **0/8**；v1.8 漏拒 **0/150** | 与 FIX.md:148-150 一致 ✓ |
| deref_test | _local/work/crash-root/fix/deref_test.exe …/natne/1793477586-17847-1793509363.stack | **17 条断言全 ok**（T1 10 + T2 7），PASSED (0 failures) | 与 FIX.md:143-146 一致 ✓ |
| v2.2 判据 | _local/work/slotguard/nerepair_v22_test.exe | V22 TEST PASSED (0 failures)；我数 ck() 调用点 = **22** | 与 SLOTGUARD_DESIGN §0/§2.2 一致 ✓ |
| 判据"非拷贝" | python -I _local/work/slotguard/mk_nerepair_v22_inc.py lg6151m-public/gw/src/nerepair.c <tmp>.inc + diff | **逐字节相同**（8 函数 / 9 宏块） | ✓ 被测代码 = 生产源 |
| 语料复算 | _local/work/slotguard/corpus_stats.py、_local/work/crash-root/fix/natne_scan.py | 150 = 114 A0B2 + 36 B0A2；A0B2 w0∈[0xd968,0x20282]，A>0x20000 = **2/114**；B0A2 w0 恒 0x0109a8c000000649（36/36，全 ≥16 MiB）；len∈[1601,1664]；自然 NE 4 文件 **7 条**记录（全 A0B2，6/7 的 A>0x20000） | 与 SLOTGUARD_DESIGN §1.1/§1.2 一致 ✓ |

限制（写清）：22 项断言只覆盖**判据函数**（shape_ok/record_at/is_load_insn/xf_class/xf_name/len_band/find_record_near_stack/addr_family_plausible），**不覆盖** handle_segv/deref_attempt 的调用顺序、dry/xrep 门控与熔断；**X1 的正例（第二副本 x2-0x240）未构造**（nerepair_v22_test.c:107-110 只测"正常 VA 通过"与"该页无副本时不通过"）。

### 3.3 (c) 真实设备上的 REPAIR / WOULD_REPAIR 计数（我实测，E3）

全日志（设备 wc -l = 2059；我取回 2061 行含 2 条新增 STAT；**设备端 awk 聚合与本地解析交叉一致**）：

| 事件 | 条数 | canary(vsurv5) | 自然进程 |
|---|---|---|---|
| SEGV | **714** | 694 | **20** |
| PASS | 532 | 513 | 19 |
| STAT | 447 | — | — |
| ATTACH | 127 | — | — |
| NEAR | **44** | 43 | **1**（ql_entry_auto_q） |
| BIN | 39 | — | — |
| WOULD_REPAIR | **141** | **141** | **0** |
| WOULD_DREPAIR | **5** | 1 | **4** |
| START / MODE / SCAN | 4 / 4 / 3 | — | — |
| **REPAIR / DREPAIR / XREPAIR / WOULD_XREP / XFORM / EXIT** | **0 / 0 / 0 / 0 / 0 / 0** | — | — |
| 合计 | 2060 行（= 本地解析行数 ✓） | | |

> **对账**：Lead 转达的"REPAIR 命中 146" = grep -c 'REPAIR' 的**子串**结果（146 = 141 条 WOULD_REPAIR + 5 条 WOULD_DREPAIR）。按第 5 字段精确计数：**REPAIR = 0**（我复核 grep-substring=146 / exact REPAIR=0）。这是仪器口径差，不是数据差。

**WOULD_REPAIR = 141 全为探针 vsurv5**，时间集中在 **10:43:20–12:59:59**（2 h 17 min；其中 135 条挤在同一个 3600 s 桶）。不可计入自然修复量（E3）。
附带测量污染：代码的 canary 豁免是**单 inode**（L341-383；NEREPAIR_CANARY 默认 /data/repro/vsurv4，START 记 resolved=1），**vsurv5 不在豁免内** ⇒ 694/714 = **97.2%** 的 SEGV 停来自一个未被豁免的探针，日志/STAT 被它主导，并触发 395 条 reason=repair-loop PASS（L947 熔断）——这正是 §1.3f 的截尾来源。

> **时效补记（19:40:07 复核，LOW-12）**：19:24 副本之后设备新增 1 起 SEGV（19:29:05 `od`，观测者注入）与 1 条 `WOULD_DREPAIR path=p2`；至 19:40 STAT 累计 `segv=2 would2=1 dfhit=1`（仍 `repaired=0`）。**设备现值**：SEGV **715** = 694 探针 + 20 自然 + 1 观测者注入；WOULD_DREPAIR 6 = 1 探针 + 4 自然 + 1 观测者注入。
> perf 侧报的 "95/h（SEGV 715 行 / ≈7.5 h）" 是**含 canary 与观测者注入**的口径；本文的 **2.85/h 是自然-only**（排除 694 探针与 1 观测者注入）⇒ 两者不矛盾但**必须标注口径**（§8 第 11 项）。

### 3.4 (c) 自然进程的 predicted repair = 4 条（全部 deref 路径，不受 XREP 门控；其中 3 条经 .stack 后验确认真家族）

| epoch / 时刻 | pid | comm（角色） | pc | addr | 记录命中 | 是否在 NE 死亡台账 |
|---|---|---|---|---|---|---|
| 1793678237 / 11:57:17 | 20223 | iptables（**一次性**：iptables -t nat -S） | 0x7fb8444ffc | 0x18935 | which=q0 rec=0x7fe57472f0 q2=0x333a84650000062d | **是**（far=0x18935、pc 一致） |
| 1793694248 / 16:24:08 | 32380 | busybox（**一次性**：awk 状态采集脚本） | 0x4e6f28 | 0xe205 | which=q0 q2=0x1c28416e00000640 | **是**（far=0xe205） |
| 1793695765 / 16:49:25 | 11272 | date（**一次性**：date +%s） | 0x4e82c8 | 0x16fb1 | which=q0 q2=0x1c28416e00000640 | **是**（far=0x16fb1） |
| 1793696172 / 16:56:12 | 12736 | ql_entry_auto_q（厂商 QoS 短命工具；新实例 12765 仍在跑，pid 会变） | 0x7f8119fea0 | 0x1d338 | which=q2（**弱命中**：命中来自 lo2==addr+8 的长度带分支，非完整记录对齐） | **是**（far=0x1d338） |

- 时间跨度 **4 h 59 min → 0.80 起/h**；**口径警告**：这 5 h 处于实验密集期（canary 风暴刚过、lab 工具在跑）且跨 1 次 boot，**不是背景速率**。
- 4 起全部进了 NE 死亡台账（dry-run 下确实把进程打死了）⇒ "若 armed 会救活"的对象是**这 4 起**，每起都是"一次脚本调用/一次请求"，无一为监听父进程或守护。
- **skeptic 的 .stack 后验（双信道）**：4 条中 **3 条**（iptables / busybox / date）经 .stack 复核确认为**真家族记录且与 si_addr 精确对齐**；**ql_entry_auto_q（which=q2）因记录落在 dump 窗口之下，无法判定**（其原命中点本就是 mode 0 的弱分支，见 §1.3g）⇒ 后验口径应写作 **3 确认 / 1 未判定**（该后验来自 skeptic，我未独立复跑，原因见 [B]9/[B]10）。
- **pop 路径的自然命中 = 0**（141 条 WOULD_REPAIR 全是探针）。
- 同刻 ql_entry_auto_q 还有一条 NEAR reason=insn（shape=ldr rt=0 rn=3 insn=0xb9800060 = LDRSW x0,[x3]）⇒ pop 判据因 rt≠rn 未接住、deref 判据接住了，是"两路径分工"的活样本。

### 3.5 `_demo_dryrun.log` 的定性：**合成 demo，不是设备数据**（E3）

- 生成器 _local/work/crash-root/fix/_mk_demo.py 直接把合成行写进 _demo_dryrun.log（第 22 行 open(...,'_demo_dryrun.log','w').write(...)）。
- 我核对产物：**1572 行**，与生成器结构逐一吻合（START+MODE、26 h × 每分钟 1 条 STAT、6×(BIN+WOULD_REPAIR) 的 vsurv4 pid 4242、busybox 的 WOULD_REPAIR/NEAR、ip 的 reason=repair-loop、一处故意的心跳缺口）；所有行的 iso 字段**恒为** 2026-11-01T00:00:00（真日志不会如此）；pc=0x1014728 fault=0x2204e 抄自 pf.core 历史值。
- 结论：**它是 dryrun_report.py 的测试输入，不得作为效力证据引用**。同理 _demo_ne.log（897 B）也是合成件。
- 真数据只存在于设备；我已把当前设备日志（2060 行）留档 tmpfiles/review/efficacy/nerepair_log.txt。

---

## 4. 覆盖率算术（三个口径必须分开；★ = 我本次独立复算）

### 4.1 记录命中率（"记录被判据接受"）

| 语料 | 结果 | 等级 | 出处/复算 |
|---|---|---|---|
| 150 条实录 32B 记录（canary 转储） | **150/150 = 100%** 被 shape_ok 接受（v1.7 与 v1.8 同） | E2 host | nerepair_mask_test 复跑 ✓ |
| 自然 NE 4 份 .stack | **7/7** 条记录（全 A0B2） | E2 host | natne_scan.py 复跑 ✓ |
| 8 条合成阴性 | v1.8 **0/8** 误接（v1.7 3/8） | E2 host | 同上 |

**★ 明确：150/150 只是"记录形状符合判据"，绝不等于"崩溃会被修复"。** 下面两节才是崩溃层。

### 4.2 崩溃命中率（设备实测，唯一可测口径）

| 口径 | 分子/分母 | 点估计 | Wilson 95% CI | 等级 |
|---|---|---|---|---|
| 自然 SEGV 命中**任一可修路径**（dry-run 的 WOULD_*） | 4 / 20 | **20.0%** | **8.1% – 41.6%** | E3（我实测） |
| 其中 pop 路径（WOULD_REPAIR） | 0 / 20 | **0%**（上界 16.1%） | — | E3 |
| 其中 deref 路径（WOULD_DREPAIR） | 4 / 20 | 20.0% | 8.1% – 41.6% | E3 |
| 速率侧：自然 SEGV | 20 起 / 7.01 h | **2.85 起/h** | — | E3（实验密集期，非背景率） |
| 速率侧：自然 WOULD_* | 4 起 / 4.98 h | **0.80 起/h** | — | E3（同上） |

**★ 分母分段（MED-6；按文件顺序的 START 边界切分，因跨复位 epoch 非单调）：**

| 段（文件顺序） | 行数 | STAT | 自然 SEGV | 自然 WOULD_* | canary SEGV | 段内 epoch 范围 |
|---|---|---|---|---|---|---|
| ① pre-START（START 在已轮转的 .1，实例不明） | 1565 | 144 | 3 | 1 | 694 | 1793673409..1793682018 |
| ② START pid=11978 v2.1 | 66 | 22 | 0 | 0 | 0 | 1793682134..1793683455 |
| ③ START pid=12079 v2.1 | 278 | 183 | 16 | 3 | 0 | 1793626206..1793699025 |
| ④ START pid=4426 v2.2（17:44:01，复位前 90 s） | 2 | 0 | 0 | 0 | 0 | 1793699041 |
| ⑤ START pid=11617 v2.2（复位后，=观察窗实例） | 149 | 98 | 1 | 0 | 0 | 1793637321..1793705040 |
| 合计（19:24 副本） | 2060 | 447 | **20** | **4** | **694** | — |

- 分段表可复跑：`python tmpfiles/review/efficacy/segment_table.py`（按 START 行切分；断言合计 20 / 4 / 694）。
- 分母的 **7.01 h = 自然 SEGV 的 epoch 极差**（1793678237→1793703491），**不是**单一实例在役时长（跨 3 个实例 + 1 次复位）；引用时必须写"跨实例 epoch 极差"。

前提与污染（必须随数字一起引用）：① 全部来自 dry-run（进程照死，NE 台账可比）；② 混合 v2.1/v2.2 实例（deref 路径两版相同）；③ 跨 1 次 boot（17:45 复位）；④ 处于实验密集期；⑤ 分母是"nerepair 看到的 SEGV/SIGBUS 停"，不等于"死亡进程数"（被信号处理器接住的 SEGV 也算）；⑥ v2.2 的 XREP 未布防 ⇒ X2/X3 的潜在命中不在分子里（**这是下界**）；⑦ **观测者注入事件已排除**：19:29:05 `od`（§6.6）既不进分子也不进分母；若并入则为 5/21 = 23.8%（不作为本文口径）。

### 4.3 形态覆盖（记录层 → 崩溃层的结构性上界）

★ 复算（_local/evidence/crash-root/h4_rec150.txt，150 条）：**114 A0B2 / 36 B0A2**；A0B2 的 w0 值域 0xd968–0x20282（113 个不同值），其中 **2/114 的 A > 0x20000**。

| 路径 | 覆盖的结构性上界 | 依据 |
|---|---|---|
| path 1（pop） | 语料记录 **150/150** 通过 shape_ok（若崩溃确为 pop 型） | §4.1 |
| path 2（v2.0 deref） | **112/150 = 74.7%**：B0A2 全 36 条被 16 MiB 门结构性排除；A0B2 中 2 条被 len_band(lo0)（把 A 当长度带）拒 | 代码 L672-682 + 我的语料复算；SLOTGUARD_DESIGN §1.2 同 |
| X2（B0A2，≥16 MiB） | +36 | 代码 L726-732，需 /data/gw/nerepair.xrep |
| X3（q0 分支改 shape_ok） | +2 | 代码 L721-725 |
| X1（第二副本 x2-0x240） | pop 型的补充；语料侧 66/82 canary 样本见 00_STATE C-161（**我未复核该数**，E1） | 代码 L908-938 |
| 自然 NE 语料 | path 2 只覆盖 **1/7 = 14%**（6/7 的 A>0x20000 被结构性拒）；X3 补到 7/7 | natne_scan.py 复跑 |

### 4.4 死亡进程占比（"救活的是什么角色"）

- 观察窗内 2 起 NE：① slotguard（**守护类**，procd 拉起；非家族，判据正确放行）；② `od` applet（**观测者注入**，家族型但非自然，§6.6）。
- dry-run 窗口内 4 起预测可修：iptables / busybox(awk) / date / ql_entry_auto_q —— **4/4 都是一次性工具**，非监听父进程、非长驻守护（exe 路径、args、pid 每次都变均可佐证）。
- ⇒ 即使立刻 armed，**收益形态是"少丢一次脚本调用/一次请求"**，不是"服务路径不中断"；按 AGENTS「爆炸半径取决于死者角色」的推论，这与"减少 SIGSEGV 崩溃数"是两件事。

---

## 5. 会修错的代价与现有防线

| 风险 | 代码/设备依据 | 现有防线 | 残余 |
|---|---|---|---|
| **si_addr < 16 MiB 是启发式** | L714 / DEREF_SMALL_MAX L536 | 16 MiB 门本身不提供保护；保护来自"记录证据"，但**强度分层**：path 1/X1/X3 用 shape_ok，**path 2 默认（mode 0）只用弱门**（§1.1 硬门行、§1.3g） | 家族 A 值域实测 0xd968–0x20282；**普通小值 bug（本次实测的 0x18935/0xe205/0x16fb1/0x1d338）同样落在 16 MiB 内** ⇒ 该门不提供"真 bug 保护"，全靠 D2 |
| **D2 只是"栈里有记录"，不等于"记录致死"** | 00_STATE §15.1 的选择效应；健康进程栈 2/12 也含记录（C-173，E2） | 要求记录在**故障线程**栈内 + w1==w3==0 + 长度带 + tag 掩码 | 记录是**普遍**的 ⇒ "现场有记录"对因果的判别力有限（E2） |
| **只修 load 不修 store** | is_load_insn L542-553；X2/X3 只改 regs[rn] | 代码级排除 store/FP/LDP/寄存器偏移 load（SLOTGUARD_DESIGN §2.3） | 修好的 load 之后，同一条指令链上的 store 仍可能用被污染的指针（未测量） |
| **真实 NULL/负偏移会不会被吞？** | 代码：addr==0 直接返回（L710）；si_addr==0 且记录 q0==0 只记 XFORM form=null、**永不修**（L896-902） | **设备实证（我实测）**：观察窗内唯一崩溃 slotguard 的 LDRSW x8,[x8]、si_addr==x8==0xffffffffffffffd8 **通过了 A/B/C**，但 shape_ok 因 w3≠0 拒（PASS reason=shape-fail w=0xf473c9b700000630,0,0x7fe65744d0,0xffffff80ffffffe0）⇒ **硬门在真实设备上挡住了本该崩死的坏进程**（E3） | 这是**唯一**一次"真实非家族崩溃被正确放行"的实测；样本 1，且**不能外推**：本例地址为负偏移（`addr_family_plausible` L693-698 直接拒），而**小地址**（<16 MiB）的同类崩溃在 pop 判据失败后会落到 **mode 0 弱门**（§1.3g）——那才是"真 NULL/小指针被吞"的残余面 |
| **R-11：救回的进程带污染栈继续跑** | FIX.md:398（R-11）、C-149 | **没有任何 post-repair 行为校验**：修完立即 PTRACE_CONT（L1146-1149），不检查后续行为、不落盘、不标记 | **无防线**。"救活一个本该崩死的坏进程"在这个设计里**没有任何机制阻止**——只有三重负向约束：①记录硬门 ②8 次/站点熔断（L146-172）③dry-run/XREP 双钥匙。**注意熔断的方向**：它防的是"修不完的循环"，不是"修错" |

---

## 6. 测量污染与"要证明效力必须怎么做"

1. **同义反复**：修复一旦生效，家族崩溃**不再落 core/.stack、不再进 ne_events** ⇒ 用"NE 计数下降"证明效力 = 用机制自身的后果当证据（FIX.md:212、C-178、C-149 均有此记载）。**必须**改用下列之一：
   - **WOULD_REPAIR / WOULD_DREPAIR 率**（dry-run 下可测，且天然排除"因为修好所以看不见"的回路）：实测 **0.80/h（自然、全为 deref）**、pop 自然 **0/h**；
   - **停修复对照臂**（armed vs dry，同 boot、同会话、ABAB）；
   - **受控崩溃源**（rectest 式注入）——本类事件的修复效果近乎确定性，功效远高于自然 NE。
2. **层 I（槽重写速率）对 nerepair 不适用**：nerepair 不停写入（gw/src/nerepair.c 全文无写入者干预），FIX.md §4.0 / C-178 规定"nerepair 只看层 II（后果）"。本次审查未做任何槽速率实验（无臂、无仪器），故**不对"写入活性是否变化"下结论**（E0）。
3. **熔断截尾**（§1.3f）：dry-run 的 WOULD_REPAIR 在熔断后转 repair-loop（同一站点 >8 次）⇒ **分子偏小**；设备证据 395 vs 141（同源探针）。任何"若 armed 会救活 N 起"的估计必须声明这是**下界**。
4. **功效（我独立计算 + 与文档对账）**：

| 目标 | 最小样本（双侧 α=0.05、80% 功效） | 折算时长 | 与文档对账 |
|---|---|---|---|
| 单臂命中率 ±10 pp | ~100 起自然 SEGV | 2.85/h ≈ 35 h；0.5–1.5/h ≈ 67–200 h | 与 §4.2 的 CI 一致 |
| 死亡数下降 50% | ~49 事件/臂 | λ=0.5/h ⇒ **≈98 h/臂** | FIX.md:218 的 **94 h/臂** ✓（同量级；文档用单侧口径） |
| 下降 70% | ~22 事件/臂 | ≈44 h/臂 | FIX.md:218 的 **41.6 h** ✓ |
| 下降 90% | ~10 事件/臂 | ≈21 h/臂 | FIX.md:218 的 **21.3 h** ✓ |

5. **24 h 观察窗（dry-run）能产出什么**：**窗内自然 NE = 0**（n=1 的 slotguard 非家族；另 1 起观测者注入已从分子分母剔除）⇒ **窗内 n=0 不提供速率信息**；本文任何 24 h 期望值**一律由背景率（0.5–1.5/h）给出，不由窗内计数投影**：24 h 期望 **12–36 起**自然 SEGV，P(0)=e^-12 至 e^-36（≈6.1e-6 甚至更小）⇒ 窗口**必然见到崩溃**。但按 20%（CI 8–42%）的可修比例，预测 WOULD_* 只有 **2.4–7.2 起** ⇒ 由此得到的命中率 CI 仍在 ±20 pp 以上。**结论：24 h 窗能给出"命中率分子/分母"与九类 XFORM 的规模，但不能证明"崩溃减少"**——后者需要 armed 臂或受控注入臂。
6. **取证读取本身会注入事件（本次实证，HIGH-2）**：19:29:05 的 `od` 崩溃就是取证命令 `/data/gw/sbin/od …` 自身；其记录是**规范 A0B2**（q0=0x1ee27 / len=1601 / ip=192.168.9.1），并被 nerepair 判为 deref 可修（`WOULD_DREPAIR path=p2 which=q0`）⇒ ① 任何"窗口内零家族活动"的表述必须先排除**本会话执行的设备命令**（含 lgssh 派生的 applet）；② 观察窗纪律应追加"**取证命令也要记账**"，由它产生的事件单列、不计入自然分母；③ 本文由此撤回 §0/§2.5 早先的"窗内只有 1 起且非家族"读法。

---

## 7. 判决（逐条对应任务问题 7）

(i) **行为级可否成立**：**成立（限 armed 且判据命中）**。三处改寄存器中 **path 1/X1/X3 过 shape_ok 硬门，path 2 默认（mode 0）只过弱门**（§1.1 硬门行 / §1.3g），因此"不误修"的强度**不一致**——小地址 + load 形态走的是弱门；设备侧自注入正对照 3 次 REPAIR（E3）、负对照 rc=139（E2）。**但适用范围只有判据覆盖的两类形态**，其余一律放行。

(ii) **家族层面预期救活比例**：**记录层 100%（150/150 判据接受）**；**崩溃层实测 20.0%（4/20，95% CI 8.1–41.6%）**，其中 pop 路径自然命中 0、4 起全部来自 deref；前提 = ①判据不放宽 ②进程死在判据覆盖形态 ③不布防 XREP 时的结构上界 = 112/150（74.7% 记录层）。**任何"救活 150/150"的表述都是把记录命中率当崩溃命中率，必须禁止。**

(iii) **设备上是否已证明减少崩溃**：**否，而且当前是"零修复"（dry-run）**。缺的下一步：① 24 h dry-run 的 WOULD_* 分层计数（含 WOULD_XREP）与"分子/分母"报告；② 过 G0–G6/G2b 门禁后**布防 XREP**（X1/X2/X3）；③ **armed 臂 + 对照臂**（或受控注入臂）才能声称"减少"。就现有 24 h 窗（17:45:32 起）：**能产出命中率与规模，不能产出"减少"**；且按 §6.5 的功效（**该期望值由背景率 0.5–1.5/h 承载；窗内自然 NE = 0，不提供速率信息**），24 h 的可修事件只有 2.4–7.2 起，仅够定性（"判据确实抓到了自然崩溃"），不够定量。

---

## 8. 待对账（**不自行调和**，两侧出处并列）

| # | 数字/表述 | 出处 A | 出处 B | 差异性质 |
|---|---|---|---|---|
| 1 | "150/150 的 w0 全 < 2^24" | FIX.md:65 | 我的复算：**114/150** < 2^24，36 条为 B0A2 复合字（最大 7.5e16）；gw/src/nerepair.c:6-8 同（114/36）；FIX.md:124 亦写"36/150" | A 为**错**（同文档内自相矛盾） |
| 2 | 自然 NE 记录位置 | 00_STATE.md:73（C-142）start_stack−0x1390…−0x7970 | FIX.md 附录 + 我复跑 natne_scan.py：top−va = 0x7158/0x7010/0x1438/0x77c0/0x6e98/0x6d50/0x1390（**0x1390…0x77c0**） | 口径（扫描窗口 vs 字段起点）；FIX.md 附录已标注待对账 |
| 3 | A0B2 的 A 值域 | 04_FAMILIES.md:47 0x9d49..0x2a797（106 份 h3b） | 我复算 150 份 h4 语料：0xd968..0x20282 | **语料不同**（106 vs 150），不可混用 |
| 4 | 长度字 | 09_CONDITIONAL:79 "1601(0x641)×112" | SLOTGUARD_DESIGN:41 "B0A2 w0 恒为 0x0109a8c000000649"（lo32 = **1609**）；我复算：A0B2 的 lo32(w2)∈{1601×112, 1664×2}，B0A2 的 lo32(w0) 全 = 1609 | 两型长度字差 **8**；引用必须带"哪一型的哪个字" |
| 5 | REPAIR 条数 | Lead 转达 "REPAIR 命中 146" | 我按第 5 字段精确计数：**REPAIR=0**（146 = 141+5 的子串） | grep 子串 vs 字段精确 |
| 6 | WOULD_REPAIR 时间跨度 | Lead 转达 "10:43–12:28" | 我按锚换算：首末 epoch 1793673800…1793682010 = **10:43:20–12:59:59** | 末时刻差 ~32 min，待统一换算口径 |
| 7 | ne_events 记录数 | Lead 转达 "1723 行 / 19 行含续行" | 我实测：**1723 物理行、1480 记录**（awk 按记录头断言）、其中 epoch≥1793699132 = **1** | "19" 疑为不同过滤口径 |
| 8 | attached 的含义 | FIX.md:254 "TracerPid == nerepair 的占比 ≥99%"（判据）与 FIX.md:520 "attached ≥ 部署前" | 实测 attached=45 vs 实时被追随 56（唯一 TracerPid = 11617） | 判据应改用 TracerPid 全量扫描；attached 是累计 attach 事件数 |
| 9 | FIX.md §0.2 vs 在役 v2.2 | FIX.md:39-59 只写 v2.0 两路径 | 代码 L14-25/L726-732/L908-938 有三条受门控扩展路径；FIX.md:123-126 与 SLOTGUARD_DESIGN §2.2 有描述 | §0.2 主体未更新 |
| 10 | 判据敏感性 | Lead 转达 skeptic："把 len 带换 0x400..0x20000 → 46/112；q0 允许 0 → 164 命中" | 我未复跑该敏感性实验（**E1，外部引用**） | 结论：**引用覆盖率必须带判据原文**；本文所有覆盖率数字均标注了判据版本 |
| 11 | "SEGV 速率 = 95/h" | perf 侧：SEGV 715 行 / ≈7.5 h（**含 canary 与观测者注入**） | 我：自然-only 20 起 / 7.01 h = **2.85/h**（排除 694 探针与 1 观测者注入） | 同一日志**不同口径**；引用必须写"含/不含 canary"（LOW-12） |
| 12 | 观察窗 NE 条数 | Lead/skeptic 首报 1（19:27 前）→ 更新 2（19:29 观测者注入） | 我 19:27:42 实测 = 1、19:40:07 复核 = 2 | **时效差**，非矛盾：按读取时刻标注即可 |

---

## 9. 结论表（汇总，带等级/出处）

| # | 结论 | 等级 | 出处 |
|---|---|---|---|
| 1 | 判据（pop/deref 两路径）代码与 FIX.md §0.2 主体一致；**path 1/X1/X3 过 shape_ok 硬门，path 2 默认（mode 0）不过 shape_ok（弱门）** | **E3**（代码级） | nerepair.c L281-291/306-322/542-553/627-689/656-683/758/926/965 |
| 2 | v2.2 的三条扩展路径（X1/X2/X3）默认关，只记 WOULD_XREP；§0.2 主体未覆盖它们 | E3 | nerepair.c L1057-1060/L915/L726-732；FIX.md:123-126 |
| 3 | 设备当前 **dry-run**（marker 在位 + dry=1 + 447 条 STAT mode=dry）；XREP/slotguard 钥匙均不存在 | **E3**（我实测） | 设备只读快照 19:23/19:27 |
| 4 | 设备上 **REPAIR=0 / DREPAIR=0 / XREPAIR=0 / WOULD_XREP=0 / XFORM=0**；WOULD_REPAIR=141（全探针 vsurv5）、WOULD_DREPAIR=5（4 自然 + 1 探针） | **E3** | 设备 awk 聚合 + 我本地复核（事件直方与 2060 行一致） |
| 5 | 自然进程 predicted repair = 4 起（deref 路径，11:57–16:56，0.80/h），4/4 均进 NE 死亡台账；pop 路径自然命中 0 | **E3** | nerepair.log 4 条 + ne_events 逐条交叉（19:27:42 实测） |
| 6 | 崩溃命中率 4/20 = 20.0%（Wilson 8.1–41.6%） | **E3**（口径见 §4.2） | 同上 |
| 7 | 记录命中率 150/150（≠ 崩溃修复率）；形态上界 112/150（不布防 XREP） | E2（host 可复跑） | mask_test / corpus_stats 复跑 |
| 8 | 观察窗内 **2 起** NE：① slotguard（非家族，.stack 0 条记录，`PASS reason=shape-fail` ⇒ 硬门挡住了非家族崩溃）；② `od`（**观测者注入**，规范 A0B2，`WOULD_DREPAIR path=p2`） | **E3**（我实测） | 19:25–19:40 只读快照 + 主机验证过的扫描器 |
| 9 | 覆盖 ≈100%（排除自身）：用户进程 57、被追随 56、唯一 TracerPid=11617；attached=45 不是覆盖判据 | **E3** | 同上 |
| 10 | 心跳新鲜（age 16.5 s）；boot 与观察窗起点一致（uptime 6128.88 → 17:45:32） | E3 | 同上 |
| 11 | _demo_dryrun.log / _demo_ne.log 是合成件，不得引用 | **E3** | _mk_demo.py L22 + 产物结构复核（1572 行、iso 恒定） |
| 12 | 行为级正对照（rectest 3 次 REPAIR）成立但其对象是自注入探针；负对照 rc=139 有多份本地记录 | E3/E2 | tmpfiles/an4/overnight_report.md:21-22；tmpfiles/an4/*_log.txt |
| 13 | 判据回归可复跑：mask 150/150 与 0/8；deref 17/17；v2.2 22/22（.inc 从生产源逐字节重生成） | E2（host） | 三条命令 + diff（§3.2） |
| 14 | 代码级缺陷 4 项 + 2 项口径问题（X2 无 ±8 容差、NEAR 未掩 tag、deref 熔断不记账、g_abuse 死字段、§0.2 未更新、熔断截尾 WOULD_REPAIR） | E3（代码级）；熔断截尾有设备旁证 | §1.3 |
| 15 | 效力证明路径：WOULD 率 / 停修复对照臂 / 受控注入臂；层 I 不适用 | E2 | FIX.md §4.0（C-178 口径）+ 我的功效计算 |
| 16 | 观测者污染：豁免只覆盖单 inode（vsurv4），未豁免探针 vsurv5 贡献 694/714 = 97.2% 的 SEGV 停与 395 条熔断 PASS | **E3** | 设备日志分层 + nerepair.c L341-383 |
| 17 | **path 2 默认路径（mode 0）判据弱于 shape_ok**：只用 w1==w3==0 + 地址近似 + len_band；mask_test 的 0/8 阴性只覆盖 shape_ok，**未覆盖 mode 0 的假阳性面** | **E3**（代码级） | nerepair.c L656-683；§1.3g |
| 18 | **取证读取会注入家族事件**：19:29:05 `od`（规范 A0B2）被判 `WOULD_DREPAIR` ⇒ 窗内"无家族活动"撤回 | **E3** | 设备 19:40:07 快照（BIN/SEGV/PASS/WOULD_DREPAIR 四行 + NE 台账新增 1 条） |

---

## [A] 已核实（可指到 path:line 或可复跑命令）

1. 设备 **dry-run、零修复**：dry marker 在位（0 B, Nov 1 18:01）＋START ver=2.2 dry=1 xrep=0＋447 条 STAT mode=dry＋REPAIR/DREPAIR/XREPAIR/WOULD_XREP/XFORM = 0/0/0/0/0（设备只读，2026-11-03 19:23–19:27，锚 uptime 5863.52→6128.88 s）。
2. 全日志精确事件计数（2060 行）：SEGV 714 / PASS 532 / STAT 447 / WOULD_REPAIR 141 / ATTACH 127 / NEAR 44 / BIN 39 / WOULD_DREPAIR 5 / START 4 / MODE 4 / SCAN 3 / EXIT 0（设备 awk 聚合 ↔ 我本地全量解析一致；REPAIR 子串 146 是假象）。
3. canary vs 自然分层：SEGV 694 vs 20；WOULD_REPAIR 141 vs **0**；WOULD_DREPAIR 1 vs **4**；NEAR 43 vs 1。
4. 4 起自然预测修复（iptables 20223/11:57:17、busybox 32380/16:24:08、date 11272/16:49:25、ql_entry_auto_q 12736/16:56:12）**逐条在 ne_events 死亡台账**（far/pc 一致）⇒ dry 下确实死亡、若 armed 会被救。
5. 崩溃命中率 4/20 = 20.0%（Wilson 8.1–41.6%）；pop 自然命中 0/20。
6. 观察窗（17:45:32 起）新增 NE = **2**：① slotguard（非家族，.stack 8B 步进扫描 0 条记录，扫描器在主机阳性件上已自证）；② `od`（**观测者注入**，规范 A0B2 q0=0x1ee27/len=1601/ip=192.168.9.1，nerepair 记 `WOULD_DREPAIR path=p2 which=q0`）。
7. 记录命中率 150/150（mask_test 复跑）、自然 NE 7/7（natne_scan 复跑）、语料 114+36、A>0x20000 = 2/114、B0A2 恒 0x…0649 且 ≥16 MiB（corpus_stats 复跑＋我另写脚本复算）。
8. v2.2 判据 22 项断言 + .inc 由生产源逐字节重生成；deref 17 项；负样本 0/8。
9. 覆盖（排除自身）≈100%：用户进程 57 / 被追随 56 / 唯一 TracerPid=11617；心跳 age 16.5 s。
10. _demo_dryrun.log 为合成件（_mk_demo.py:22 直接写出；1572 行；iso 恒为 00:00:00）。
11. 代码级：3 处 PTRACE_SETREGSET（758/926/965）中 **path 1/X1/X3 过 shape_ok，path 2 默认（mode 0）不过 shape_ok（弱门，L656-683）**；g_abuse 无自增点；deref 熔断不累加 g_loop；dry 分支（951）在任何寄存器写之前。
12. 设备零写：本次 **9 次**只读快照（命令与时刻见 §2.1）；**取证读取本身注入 1 起家族型崩溃**（19:29:05 `od`）——见 §6.6。
13. 分母分段表可复跑（segment_table.py：20 / 4 / 694 与 447 STAT、2060 行一致）。

## [B] 未核实（原因）

1. **历史 /data/gw/logs/nerepair.log（v1.7/v2.1 期）无本地副本** ⇒ 3 条 rectest REPAIR 的 pc/fault/w 无法逐行复核；只能引用 tmpfiles/an4/overnight_report.md 的聚合。原因：该日志只存在于设备，本次仅取回当前在役日志。
2. **ne_events.tsv 本地逐行解析不完整**：分块取回仅 1125/1723 行（601–1200 区间 sed 与 tail+head 各一次均失败）。原因：传输/工具限制；按纪律不以抽样冒充全量。
3. **判据敏感性（len 带→46/112、q0 允许 0→164 命中）未复跑**：仅为 Lead 转达的 skeptic 口径（E1 外部引用）。
4. **X1 的第二副本（x2-0x240）在自然 NE 上是否存在**：REVIEW_SLOTGUARD L-6 已列为未验证；语料侧只有 canary 66/82（00_STATE C-161，我未复核）。原因：本次范围外。
5. **X2 的 ±8 口径（§1.3a）孰是**：需要设备侧成对的 addr/q0 读数（B0A2 故障的 addr 与记录 q0 的相对关系）；现网未出现 B0A2 自然样本。
6. **"写入活性不变"未被测量**：不停写入是代码级事实（E3），但"槽速率不变"需要双臂仪器实验——本次未做（无臂）。
7. **attached 与实时覆盖的差额归因**：我给出"累计 attach 事件 vs fork 自动追随"的解释，但未有逐 pid 的 TracerPid 时间序列（仅一次快照）。
8. **ql_entry_auto_q 的角色/父进程**：只知 exe 路径与"新替身 12765 仍在跑"，未取 ppid/调用链。
9. **`od`（19:29:05）事件的 .stack 家族记录未由我扫描**：只从日志四行 + NE 台账确认其结构与判据路径，未扫 `/data/gw/logs/cores/meta/1793699132-29866-1793705345.stack` —— 避免再执行设备端 `od` 造成**二次注入**。
10. **4 条自然预测修复的"真家族 / 精确对齐"后验来自 skeptic（.stack 复核）**：3 条确认、1 条（ql_entry_auto_q）无法判定；我未独立复跑该后验（原因同 9）。

## [C] 必须上设备才能确认（不得由本次"只读"越界）

1. **armed 后是否真的减少崩溃**：需要 armed 臂（rm -f /data/gw/nerepair.dry）与对照臂（dry）在同一 boot、同一会话交替；或受控注入臂。**这是"效力"的唯一直接证据来源，本次被 dry-run 与只读权限双重限制**。
2. **布防 XREP（/data/gw/nerepair.xrep）后的 XREPAIR / WOULD_XREP 计数**（X1/X2/X3 的实际命中率）：需写操作建钥匙 → 本次不可。
3. **24 h（或更长）dry-run 报表**：WOULD_* 分层（comm/site/小时）、NEAR reason=insn 规模、repair-loop 归零（当前 395 条由探针造成，需先修豁免或先停探针）、XFORM 八类规模：需持续在役观测 + 设备端日志导出（本次只有 1.7 h 窗口）。
4. **被救回进程的行为正确性**（R-11 的实证）：需要在 armed 下对修复后的进程做后续行为/内存校验（现设计完全没有这一步）。
5. **B0A2 的自然样本与 X2 ±8 口径**：需要等一个 B0A2 形态的自然崩溃（或受控构造）后，从 nerepair.log 的 addr/q0 成对读数判决。
6. **判据敏感性的设备侧复核**（如 0/458752 误报率）：需要可复跑的仪器与更长语料。
7. **mode 0（path 2 默认）假阳性面的回归**：host 侧须补 mode 0 的阴性断言（现 mask_test 只覆盖 shape_ok 的 0/8）；设备侧需对"真 NULL / 小指针、无完整记录"的样本做对照观测 —— 这直接决定"小地址崩溃会不会被误吞"。
8. **取证命令的事件记账机制**：观察窗内所有设备命令的注入事件需单列（本次已实证 1 起），需要设备侧日志的时间对齐工具（本次为手工比对）。

---

### 附：本次复算脚本（留档 tmpfiles/review/efficacy/）

- rec150_analysis.py / rec150_forms.py：150 条语料分型与 w0 分布（114/36、A>0x20000=2、B0A2 恒 0x109a8c000000649）。
- parse_log.py / parse_log2.py / parse_log3.py / parse_log4.py：设备 nerepair.log 的事件直方、canary/自然分层、NEAR 形态拆分、Wilson CI。
- ne_events_stats.py / ne_natural_split.py：本地历史 _local/evidence/crash-root/ne_events_2026-11-01.tsv 的 canary/自然分层（511 条非 canary / 53.1 天、0.40/h）。
- natne_scan.py（复跑）、corpus_stats.py（复跑）、nerepair_mask_test.exe / deref_test.exe / nerepair_v22_test.exe（复跑）。
- scan_validate.sh：家族记录扫描器（先在主机阳性件验证，再扫设备 .stack）。
- segment_table.py：按文件顺序 START 边界切分自然 SEGV 分母（★ MED-6 分段表）。
- dev_read_2..8.sh：9 次设备只读快照的原始命令（观测者污染审计留档；dev_read_8 = 19:40:07 复核 19:29 观测者注入事件）。
- nerepair_log.txt：设备在役 /data/gw/logs/nerepair.log 全量副本（2061 行 @19:24）。
