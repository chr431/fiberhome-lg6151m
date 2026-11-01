# 05_LOG · 2026-11-01 · fixer：修复方案（nerepair 加固 / 危险页隔离 / SMMU 可行性 / 验收判据）

> 本文只写 fixer lane 的交付。**不改变 00_STATE 的判决**，只把"能做什么修复、做到什么程度"写实。
> 证据分级沿用项目口径 E1..E4；每条结论带反证/撤回条件。
> 所有 host 产物在本轮工作区 `_local/work/crash-root/fix/`（未部署、未 commit，等 Lead 审定）。

---

## 0. 三句话

1. **nerepair 的判据确实会掩盖非本家族的 bug**：host 复现显示 v1.7 在 8 条合成阴性样本里**误接受 3 条**；
   已给出 v1.8 加固（150/150 真记录仍全收，8/8 阴性全拒），二进制已构建、源码已 diff，**等上机验证后才可部署**。
2. **"危险页隔离"改了一个关键设计**：不在"匿名页分配时比对近期释放的网络缓冲 PA"，而是**把 RX 环缓冲曾经占用的物理页
   永久排除在用户匿名页分配之外**——只钩 **1 个冷路径调用点 + 2 个热分配调用点**，O(1)、有界、可关、可卸。
   模块已用 zig 编译通过（`pageguard.ko`，196,664 B），**尚未上机**。
3. **SMMU/IOMMU：本内核不可行（E3）**——`.config` 里 `# CONFIG_IOMMU_SUPPORT is not set`，
   vmlinux 全字符串 **0 处 "smmu"**，kallsyms 里只有通用 `iommu_*` 核心、**没有任何 `arm_smmu_*`/`mtk_iommu`** 驱动符号。
   要 SMMU = 重编内核 + 改 DT + 刷机，且**只是把越界写变成 IOMMU fault，不是修 bug**。

---

## 1. nerepair 现状评估（FIX.md §2 的现实核对）

源码：`gw/src/nerepair.c` v1.7（326 行），启动：`rc.extend.sh v3.3` → `nerepair_launch.sh`（svc_lock 单实例），
心跳 `/tmp/nerepair.hb` 由 watchdog `svc_supervise` 消费。二进制约 46 KB（v1.8 构建产物 46,416 B）。

### 1.1 判据是否会掩盖非本家族的 bug —— **会，且已量化**

判据链是五个 AND：`is_ldr_same(insn)` → `rt==rn` → `si_addr==Xt` → `shape_ok(x2 处 32B)` → `Xt=sp; pc+=4`。
`shape_ok`（v1.7）只查三件事：`w1==0`、`w0==fault 或 fault+8`、A0B2/B0A2 形态。**它不查 `w3`、不查长度带、不查 tag**。

host 判据测试（`nerepair_mask_test.c`，zig cc，阳性语料 = 设备 h4 实录 150 条 32B 记录）：

| 语料 | v1.7 判定 | v1.8 判定 |
|---|---|---|
| **阳性：150 条真实记录**（`_local/evidence/crash-root/h4_rec150.txt`） | **150/150 接受** | **150/150 接受** |
| 阴性 D 类：awk poison / NULL / NULL+垃圾栈 / 负偏移 | 4/4 拒绝 | 4/4 拒绝 |
| **阴性 X 类（合成、可构造）** | **3/3 误接受** | **3/3 拒绝** |
| 阴性 X 类：记录在场但 fault≠w0（"记录不是本次原因"） | 1/1 拒绝 | 1/1 拒绝 |

v1.7 误接受的三条，含义分别是：
1. `w3` 非零的 32B 结构（任何别的内核结构只要 w1==0 且 w0==fault 就会被当成"本家族"）；
2. A0B2 形态但"长度"字段是垃圾（0xDEADBEEF）——`shape_ok` 从不看长度合理性；
3. B0A2 形态但低 32 位不是长度样。

**性质说明（必须写清）**：X 类是**合成**样本，不是自然 core 实录（本轮工作区没有自然 core 的 x2 原始 32B）。
它证明的是**判据的集合比目标集合大**（能构造出满足 v1.7 但不属于本家族的输入），不是"自然 NE 中确有 3 条被误修"。
**反证条件**：若在真实自然 core 里找到反例（v1.7 修过但 w3≠0），则该条从"可构造"升级为"已发生"。

**后果分级**：误修 = 进程带着"垃圾参数"继续跑（`Xt=sp`），既掩盖真实缺陷，又可能让本该自杀的进程
继续写状态（例如写 flash / 写 netcfg 锁 / 写日志游标）。对**监听父进程**（v3httpd、dropbear、dnsmasq）
这是"用一个假值续命"，比崩溃更难排查。

### 1.2 pid 1 / fork 跟随 / ptrace 开销 / watchdog 交互

| 项 | 现状（v1.7） | 风险评级 | 说明 |
|---|---|---|---|
| **PID 1** | 启动时 attach 一次；`scan_proc` 里写成 `p > 1` → **首次 attach 失败（3s 超时）后永不重试** | **高** | 源码注释已记：attach 有 3s 上限，超时 PTRACE_DETACH 放弃。PID 1 是设备命门，覆盖缺口静默且长期 |
| **fork/clone 跟随** | `PTRACE_O_TRACEFORK\|VFORK\|CLONE\|EXEC` 挂在**所有** tracee 上 | 中 | 全系统每次 fork/exec 都多两次 stop+continue 往返；单线程 supervisor 是**同步**的，事件风暴下 fork 延迟被串行化 |
| **watchdog 交互** | 60s 心跳 + `/tmp/nerepair.hb`；watchdog 会重启 | 中 | 源码头部记录实弹：**5 次 284–651 s 心跳断流，两次 230/242 s 触发看门狗重启**（v1.5/v1.7 已缓解）。重启窗口 = 零覆盖；且旧实例若未死透，`traced()` 会因 `TracerPid≠0` 让新实例**永久跳过**这些 pid |
| **ptrace 开销** | 只在信号/停止点处理 | 低-中 | 但 `handle_segv` 每次都要 `process_vm_readv`×2 + `/proc/<pid>/comm` 读；canary 2 次/s 的崩溃会持续占用 |
| **supervisor 自身** | 未设 `PTRACE_O_EXITKILL` | 低（设计如此） | supervisor 死 → tracee 自动 detach 继续跑，设备不会僵；代价是无人看守 |
| **repair 循环** | **无熔断** | **高** | 若故障 `ldr` 在循环里，`pc+=4` 跳过本次、下一轮同址再崩 → **无限修复循环**（CPU 空转 + 日志风暴），进程永远不退出 |

### 1.3 加固清单（按优先级，v1.8 已实现前 5 项）

| # | 优先级 | 项 | v1.8 状态 |
|---|---|---|---|
| H1 | **P0** | `shape_ok` 加 `w3==0` + 长度带 `0x400..0x20000` + tag 掩码 | ✅ 已实现（host 150/150 阳性保持、3 条误接受归零） |
| H2 | **P0** | 每 pid 修复熔断（10 s 内 >8 次 → 不再修，记 `reason=repair-loop`） | ✅ 已实现 |
| H3 | **P1** | `scan_proc` 允许重试 PID 1（`p != self_pid`） | ✅ 已实现 |
| H4 | **P1** | REPAIR 行独立限速预算（v1.7 与 PASS 共用 20 行/s，风暴时会把"修了什么"整段吞掉） | ✅ 已实现 |
| H5 | **P1** | canary 判定改**精确 comm**（v1.7 用 `strstr("vsurv4")`，改个进程名即可豁免修复） | ✅ 已实现 |
| H6 | P1 | 日志补 `si_code`、`abuse` 计数 | ✅ 已实现 |
| H7 | **P1** | **dry-run 模式**（只记 `WOULD_REPAIR`，不写寄存器）：先在设备上跑 24 h，拿"本会修多少条"，再决定是否开真修 | ⬜ 未实现（建议下一轮） |
| H8 | P2 | `traced()` 区分"被外部 tracer（gdb）占用"与"上次残留"，前者记 `SKIP_FOREIGN` 一次 | ⬜ |
| H9 | P2 | `is_ldr_same` 补齐 LDUR/寄存器偏移的 LDRB/LDRH/LDRSW 变体，并把"pre-index 回写"记入日志 | ⬜ |
| H10 | P2 | 修复选择 `Xt=sp` 改为 `Xt=<每进程一致的零页 VA>`（减少"往自己栈上写"的次生风险） | ⬜ 需设计（用户态无恒定零页） |
| H11 | P3 | 覆盖缺口自查：把"attach 失败/放弃"计入 STAT，watchdog 页面可见 | ⬜ |

**部署门禁（建议写成硬规则）**：v1.8 上机前必须先跑 H7 dry-run ≥24 h，且 dry-run 期间的
`WOULD_REPAIR` 条数与 `REPAIR`（若仍用 v1.7 并行不可能）——即**用自然 NE 的判据通过率**验证加固没有把真实家族挡在门外。

产物：
- `_local/work/crash-root/fix/nerepair_v18.c`（源码，v1.8）
- `_local/work/crash-root/fix/nerepair_v18.patch`（对 `gw/src/nerepair.c` 的 unified diff，158 行）
- `_local/work/crash-root/fix/nerepair_v18`（aarch64 静态二进制，zig cc，46,416 B，**未部署**）
- `_local/work/crash-root/fix/nerepair_mask_test.c` + `nerepair_mask_test.exe`（host 判据测试）

### 1.4 v1.9 = v1.8 + dry-run（Lead 2026-11-01 决定：先 dry-run 24 h，且不加吞信号）

产物：`_local/work/crash-root/fix/nerepair_v19.c` + `nerepair_v19.patch`（对 v1.7 的 295 行 diff）
+ 已编译 `nerepair_v19`（aarch64 静态，**47,912 B**）。

| 项 | 实现 | host 验证 |
|---|---|---|
| **dry-run 开关** | 三路：env `NEREPAIR_DRY=1` > 标记文件 `/data/gw/nerepair.dry` > 运行期 `SIGUSR1` 切换（记 `MODE` 行） | 源码级 |
| **不吞信号** | `if (g_dry) { g_would++; logev("WOULD_REPAIR",...); return 0; }` 位于**任何寄存器写之前**；调用方收到 0 → `PTRACE_CONT(pid, 0, sig)`，信号原样投递，进程照旧死亡 | 静态断言：`g_dry` 分支在第 343 行、`r.regs[rt]=r.sp` 在第 354 行、唯一一处 `PTRACE_SETREGSET` 在第 357 行（`grep -n` 可复核） |
| **① PID 1 重试** | 60 s tick 里 `if (!traced(1)) attach_pid(1)` 并记 `PID1RETRY`；另每 10 tick（10 min）全量 `scan_proc()` | 代码级 |
| **② repair 循环熔断** | 键 = **(tracee pid, 故障 site pc)**，**连续**计数；同一 pid 换 site 即重置；>8 次置 `dead`，此后该 (pid,pc) 永久只记录不修复（`PASS reason=repair-loop pc=.. n=..`） | **单元测试通过**：`breaker_test.c` 直接 `#include` 由 `sed` 从源码抽出的函数体（不是拷贝），T1 允许 1–8 次/第 9 次起拒绝、T2 dead 粘滞、T3 换 site 重置、T4/T5 跨 pid 独立（40 pid 无别名）→ **PASSED 0 failures** |
| **③ canary 精确豁免** | 启动时从 `NEREPAIR_CANARY`（默认 `/data/repro/vsurv4`）`stat` 取 **dev/ino**；判定 = `readlink(/proc/pid/exe)` 整串精确匹配（允许内核追加的 `" (deleted)"`）+ dev/ino 复核。**只用 inode 与整串路径，不用 comm/子串**（定律二/三） | 代码级；解析失败即"无人豁免"（fail-closed） |
| **近失计数** | `NEAR` 行：`w1==0 && w0∈{fault,fault+8}` 但被 v1.8 加固条款（`w3`/长度带）拒绝 | 代码级（这就是"加固是否误伤真家族"的探测器） |

**v1.9.2（Lead 2026-11-01 批准）= v1.9.1 + 纯观测分支**：
在 `not-load` / `rt-ne-rn` / `addr-ne-xt` 三个 PASS 分支里，**照样读一次 `x2` 处的 32 B 做形状检查**，
命中则记 `NEAR reason=insn rt=… rn=… insn=… addr=…`（**仍然 PASS、仍然不修**）。成本 = 一次 `process_vm_readv(32)`，
且只发生在已通过几何检查但被拒的故障上。STAT 增 `nearinsn=` 字段。
产物：`nerepair_v192.c` / `nerepair_v192.patch`（394 行 diff）/ `nerepair_v192`（**49,376 B**）。
**这条数决定 armed 的收益上限**：若 `NEAR reason=insn` 与 `WOULD_REPAIR` 同量级，
就证明"家族里一半以上根本不在 nerepair 射程内"（见 §7.4 的 V3）。

### 1.5 dry-run 读数口径（lab 照此出报表）

日志 `/data/gw/logs/nerepair.log`（TSV：`epoch  iso  pid  comm  event  detail`）。dry-run 期间只读四类行：

| 行 | 含义 | 怎么用 |
|---|---|---|
| `WOULD_REPAIR` | 命中加固后判据、**本应修复**（实际未动寄存器） | **分子**：这是"如果开 armed 会被修的次数" |
| `NEAR` | 形状近失（w1==0、w0==fault 但 w3≠0 或长度越界） | **关键分母**：>0 说明 v1.8 加固可能挡掉了真家族 → 必须逐条看 |
| `NEAR reason=insn` | **v1.9.2**：记录在 `x2`，但故障指令形态不在射程内（V3 盲区） | **G2b**：与 `WOULD_REPAIR` 的比值 = armed 的收益上限 |
| `PASS reason=repair-loop` | 连续同 site 超过 8 次 → 熔断 | >0 说明开 armed 会 livelock，**不得上线** |
| `STAT`（60 s） | `mode=dry would= near= loop= attached= segv= passed=` | 时间序列，做每小时聚合 |

**部署前置确认（Lead 2026-11-01，必须写进 drill 记录）**：
> dry-run **不修复** ⇒ 记录家族的**自然 NE 会真的把进程打死**，设备可服务性与 armed 时不同。
> lab 部署前必须确认「当前没有其它实验依赖这些进程活着」（列出当时在跑的实验与台账），
> 并在模板 §7 记录 dry-run 期间的死亡事件、服务中断（SSH/LAN/GUI/上行）与是否触发 watchdog 重启。
> 这一条不满足，dry-run 期间产生的任何"NE 计数"都不能用于裁决。

**部署交接单（lab 执行，Lead 指定）** —— 前后各抓一次，缺任何一项该窗口作废：

| 时点 | 抓什么 | 判据 |
|---|---|---|
| 部署前 | `ps | grep -w nerepair` 全文；`ls -l /proc/<旧pid>/exe`；`tail -3 /data/gw/logs/nerepair.log`；`wc -l` 留档 | 记下旧 pid、旧 exe inode、日志末尾 epoch |
| 部署 | `deploy.py put nerepair_v191 /data/gw/bin/nerepair` → `chmod 755` → `touch /data/gw/nerepair.dry` → 重启 launcher（`killall nerepair` 后由 rc.extend/watchdog 拉起，或直接跑 launcher） | 走 devop + drill 窗口 |
| 部署后 | 同上四项 | **旧 pid 必须已消失、新 pid 的 exe inode 必须变**；日志出现 `START … ver=1.9.1 dry=1` 与 `MODE dry=1` 两行 |
| 部署后 60s | `tail` 一条 `STAT` | 必须 `mode=dry`；`attached` ≥ 部署前的 `attached`（否则覆盖退化） |

必须产出的四张表（按 `WOULD_REPAIR` 聚合）：
1. **按进程**（comm）：谁会被修（预期：busybox 系 / ip / awk 等 printf 使用者占多数；若出现 dropbear/init 需单列）；
2. **按 site**（故障 pc）：同一 pc 反复出现 = 同一代码路径（这是"家族身份"的免费线索，交给 analyst 做静态点名）；
3. **按时间**：每小时计数，看是否与流量/时段相关（跨会话不可比，只在本窗内看形状）；
4. **重复率**：(pid,pc) 的重复次数分布 —— 决定熔断阈值 8 是否合适。

### 1.5.1 报表模板与生成器（交付物，lab 只填空）

| 文件 | 作用 |
|---|---|
| [TEMPLATE-nerepair-dryrun.md](TEMPLATE-nerepair-dryrun.md) | **go-live 报表模板**：10 节固定格式（元数据/部署交接/观测窗与心跳缺口/attached 曲线/WOULD 三段聚合/NEAR 全量/repair-loop/G6 名单/**设备可服务性**/G0–G6 裁决表/裁决句照抄） |
| `_local/work/crash-root/fix/dryrun_report.py` | 从日志**预填**所有可计算项（窗口、心跳最大间隔与 >180 s 缺口清单、每小时 attached 曲线、WOULD 按 comm/site/hour、NEAR 全量、repair-loop、G6 名单、G 门实测值），**裁决列一律留空** |

用法：`python dryrun_report.py /path/nerepair.log --out 草稿.md` → 把草稿的 A 段贴进模板的 §1–§8，人只填判断与 §9 裁决句。
两条防呆：①日志里若出现 comm 含 `vsurv4` 的 WOULD_REPAIR，脚本会打 **WARN**（canary 本应被 BIN 精确豁免，出现即豁免失效）；②解析不到符号时写 `(unresolved)`，不瞎给。

### 1.6 上线判据（dry-run → armed 的门禁，预注册）

| # | 条件 | 不满足时 |
|---|---|---|
| G0 | dry-run 连续 **≥24 h**，且 `STAT` 心跳最大间隔 <180 s | 重跑；先查 watchdog 交互 |
| G1 | `WOULD_REPAIR > 0`（探测下限 = 24 h 内 1 次；若为 0，写"0/24h，检出下限 1，功率不足"） | 若 0，说明本窗没有家族事件，**不能**用"0"证明安全 → 延长窗口或等自然事件 |
| G2 | `NEAR` 的逐条研判结论 = "均**不是**真家族"（若有一条是真家族 → 放宽 w3/长度带后重跑） | 回 v1.8 判据调整，重新 dry-run |
| G3 | `reason=repair-loop` 计数 = 0（或有 ≥2 条且逐条确认是"非家族"） | 不得上线，先调 `NR_LOOP_MAX` |
| G4 | PID 1 在 `TracerPid` 全量扫描里 100% 覆盖（`PID1RETRY` 出现后必须成功） | 修 attach 路径 |
| G5 | `WOULD_REPAIR` 的 comm 集合里不出现 nerepair 自己或 watchdog（观测者污染，定律三） | 排除后重算 |
| **G6**（Lead 追加） | **dry-run 期间若有自然 NE 落在记录家族，必须单独列出其 comm/pid/site** —— 这是"我们已知会死但故意不救"的名单，也是交给厂商的证据 | 由 `ne_sites.py` 的 G6 段自动产出（见 §6）；缺这条则 dry-run 报告的"影响面"不完整 |
| **G2b**（Lead 追加，v1.9.2） | **`NEAR reason=insn` 的规模必报**，并给出与 `WOULD_REPAIR` 的比值 | 比值 ≈1 或更大 ⇒ 家族"过半不在 nerepair 射程内"，armed 的收益上限就此确定；该数不进报表则 armed 决策没有依据 |

armed 上线后追加判据：`repaired>0` 且 `NEAR` 不增（加固未被绕过）；连续 24 h 无 `repair-loop`；
若 armed 后 24 h 内 `repaired=0` 而 dry-run 有 `WOULD_REPAIR`，说明 armed 路径有 bug，立即回滚。

**推广到 gw/ 的步骤（需 Lead 批准，我不 commit）**：
1. 用 patch 更新 `gw/src/nerepair.c` → `tools/build_nerepair.sh` 重建 → `tools/VERSIONS.tsv` bump nerepair；
2. `vercheck check` 全绿 → `deploy.py push` → 设备 `chmod 755` → `nerepair_launch.sh` 重启；
3. 回滚：保留 v1.7 二进制副本，`killall nerepair` 后换回即可（tracee 自动 detach）。

---

## 2. 危险页隔离（补偿控制）—— pageguard

### 2.1 先说清楚定位

**这是补偿控制，不是根修复。** 它不点名写入者、不停止 DMA、不修厂商驱动；
它只保证一件事：**一个曾经作为有线 RX 环缓冲的物理页，永远不会被分配给用户匿名页**。
于是"stale 描述符按 PA 打"即使继续发生，也打不到用户栈/堆。

**它能成立的前提**（= 反证条件）：受害页在成为用户页之前/期间，确实是某个 RX 环缓冲页。
若实验显示"被排除的页与受害页不重叠"，本设计无效，必须回退。

> **2026-11-01 状态更新（Lead 转达 analyst 结论）：该前提正在被重审。**
> analyst 用三条独立判据否证了"记录 = EDMA RX 描述符"，且几何证据
> （写目标 = `startstack − K`、53 种不同页内偏移）与"固定 PA 的 DMA 写"冲突。
> 因此 pageguard **暂停上机**（Lead 决定）。本文 §2.6 给出两种 transport 判决下的变体，
> 其中**消费半边（拒绝+扣留+重试+fail-open）与判决无关、可复用**，这是本轮唯一确定可保留的资产。
> 另：若最终判为 VA 解析型写入，§2.3 的站点表**全部作废**，只有代码骨架保留。

### 2.2 为什么不是原方案（"近期释放的网络缓冲 PA 环形表"）

任务书原设计是：维护"近期释放的网络缓冲 PA"环形表，在 `do_anonymous_page` 命中即换页。
**本轮把它改成"RX 环缓冲页标记 + 匿名页分配拒绝"**，理由是三条实测事实：

1. **释放点太散、而且不是真释放**：`page_frag_free()` 只做 `put_page(virt_to_head_page(addr))`，
   页带着 `pagecnt_bias`（本内核 `PAGE_FRAG_CACHE_MAX_SIZE=32768`，`nc->pagecnt_bias=32769`）
   要等 `__page_frag_cache_drain` 才真正回 buddy。**钩"释放"得到的是"引用减一"，不是"页将可复用"**，
   窗口与真实危险窗口错位。
2. **"近期释放"窗口不可定**：命中率在 `~1/min` 与 `~127/min` 间漂 19 倍（08/09 测量边界），
   复用延迟从 µs 到小时都可能，任何 TTL 都只能覆盖其中一段。
3. **标记"分配进环"是单调且廉价的**：RX 环装填是冷路径（`mtk_rx_alloc_edma`），
   一次环装填只有几百次调用；而"曾经是环缓冲"这个性质一旦成立就终身成立，不需要 TTL 猜测。

### 2.3 具体设计（调用点全部来自 vmlinux 反汇编，不是猜）

用 `_local/work/crash-root/fix/find_callsites.py`（离线扫 `analysis/kern/vmlinux.elf` 的全部 `b/bl`）
得到并逐条核对过的站点表：

| 角色 | 站点 VA（`bl` 指令地址） | 原 callee | 所在函数 | guard word |
|---|---|---|---|---|
| 生产 | `0xffffffc008596174` | `__netdev_alloc_frag_align` | `mtk_rx_alloc_edma` | `0x94086128` |
| 生产 | `0xffffffc008589ba0` | `__netdev_alloc_frag_align` | `fe_edma_open` | `0x9408929d` |
| 消费 | `0xffffffc00812724c` | `__alloc_pages` | `alloc_zeroed_user_highpage_movable` | `0x9404eae9` |
| 消费 | `0xffffffc0082494a4` | `alloc_zeroed_user_highpage_movable` | `wp_page_copy`（COW） | `0x97fb7762` |
| 消费（可选） | `0xffffffc008234534` | `__alloc_pages` | `shmem_alloc_page`（tmpfs） | `0x9400b62f` |

**机制**（`pageguard.c`，已编译）：
- 生产 shim 在 `__netdev_alloc_frag_align` 返回后，把该 fragment 覆盖的每个 4K 页的 PFN
  插进**直接映射哈希表**（2 MiB / 262144 槽，探测 8 步，冲突即覆盖）。
- 消费 shim 在 `__alloc_pages`/`alloc_zeroed_user_highpage_movable` 返回后查表；
  命中则把该页**扣下**（quarantine，`page_count==1` 的非 compound 页）并**重试分配**（最多 4 次）。
  扣下的页在 `ttl_s`（默认 600 s）后由定时器 `__free_pages(page,0)` 归还；队列满（1024 页）则 fail-open。

**为什么必须"扣下"而不是立刻 `__free_pages` 再重试**：pcp 是 LIFO，立刻释放下一轮必然拿回同一页 → 死循环。

**边界**：
| 项 | 值 |
|---|---|
| 内存上界 | 哈希 262144×8 B = **2 MiB**；quarantine 1024 页 = **4 MiB**；合计 ≤6 MiB（512 MB 设备的 1.2%） |
| 时间复杂度 | 生产 = 插入 ≤2 个 PFN（128 B 的 fragment 也可能跨页，按 `fragsz` 逐页算）；消费 = 1 次哈希 + ≤8 次比较 |
| 上下文 | 全部 irq/softirq 安全：无 kmalloc、无 mutex、无睡眠；只有一把 `spin_lock_irqsave` 保护 quarantine 数组 |
| 开关 | 模块参数 `armed=`；运行期 `echo on/off > /proc/pageguard`；`armed=0` 是 dry-run（只计数不拒绝） |
| 卸载 | `pageguard_exit`：先 `proc_remove` → 停定时器 → **逐站点还原原始指令字** → 归还全部 quarantine 页 → 释放表 |
| 失败退化 | 站点 guard 不匹配 → 跳过该站点（不盲打）；shim 超出 `bl` ±128 MiB → 跳过；quarantine 满 → fail-open 把页交回；任何情况都不把成功分配变成 NULL |

**误伤面（诚实列出）**：
1. **`__netdev_alloc_frag_align` 是公共入口**：TX 侧、`tun`、`ppp` 也会用到同一个 per-CPU `netdev_alloc_cache`。
   我们只标记**返回地址所在的那 1–2 个 4K 页**，不标记整个 32 KB page_frag 块，因此误伤被限制在"确切被 RX 环拿走的页"。
   代价是同一块里相邻页不保护（**若实验显示受害页是块内的非首片，需要改成整块标记** —— 这是可调开关，见 §5 判据）。
2. **CMA**：`# CONFIG_CMA is not set` → 无交互。
3. **大页/THP**：`# CONFIG_TRANSPARENT_HUGEPAGE is not set`、`CONFIG_ARM64_PAGE_SHIFT=12` → 只有 4K 页，不用考虑拆分。
4. **ZONE_DMA/ZONE_DMA32**：`CONFIG_ZONE_DMA=y`/`ZONE_DMA32=y` 存在，但 RX 缓冲与用户匿名页都在 Normal 区；
   检查只看 PFN 不看 zone，跨区不会误判（`pfn_valid` 把关）。
5. **NUMA**：`# CONFIG_NUMA is not set` → 单节点，无跨节点正确性问题。
6. **长期占用**：若某个被标记页长期挂在 quarantine（ttl 600 s），最坏 4 MiB 不可用；在 512 MB 上无感。

**已知未覆盖路径（必须写进结论）**：
- `do_swap_page`（换入）、`copy_page_range`（fork 复制）、`migrate`（迁移目标）都可能把页给用户，
  本轮只覆盖 `do_anonymous_page` 与 `wp_page_copy` 两条主路径（本设备无 swap 场景，`/proc/swaps` 为空 —— **待 lab 确认**）。
- 若受害页来自 `skb` 的 **kmalloc 头**（slab）而不是 page_frag 页，本设计完全不覆盖（需要另加 `kmalloc` 侧标记）。

### 2.4 为什么用"调用点 `bl` 打补丁"而不是 kprobe/ftrace

| 手段 | 本内核可用性 | 证据 |
|---|---|---|
| kprobe | **不可用** | `.config`: `# CONFIG_KPROBES is not set` |
| ftrace | **不可用** | `# CONFIG_FUNCTION_TRACER is not set`（只有 `CONFIG_HAVE_*`） |
| perf events | **不可用** | `# CONFIG_PERF_EVENTS is not set` |
| BPF tracing | **不可用** | 无 kprobe/tracefs；`CONFIG_BPF_SYSCALL=y` 但 tracer 侧全空 |
| **`aarch64_insn_patch_text` 打 `bl`** | **可用且本机验证过** | `tmpfiles/repro/dphook.c` 用同一手法打过 3 个 `bl` 站点；kallsyms 有 `aarch64_insn_patch_text`（`0xffffffc008122394`） |

调用点打补丁**不需要搬运被钩函数的序言**（这是 arm64 上最危险的部分）：shim 保持 callee 的精确原型，
自己再通过函数指针调用原 callee。dphook 已验证该内核接受这种补丁。

**残余风险（按严重度）**：
1. **`bl` ±128 MiB 可达性**：模块区在 kimage 之下，首载模块通常贴近 kimage（dphook 实测 ~5.6 MB）。
   但**不能保证**：若模块加载偏移到 `0xffffffc000000000` 附近，到 `0xffffffc008596174` 会超过 128 MB。
   → 模块在 init 里**逐站点做可达性检查并打印 SKIP**（已实现），加载日志必须核对 `patched=N/5`。
2. **补丁期间的一致性**：用 `aarch64_insn_patch_text(addrs[], insns[], cnt)`（内部 stop_machine），
   不用 `_nosync` 版本；**不要**在 `/proc` 写路径做批量补丁。
3. **风险自负的热路径**：消费 shim 在每一次匿名缺页上都跑。必须保持 O(1) 且无分配（已实现）；
   参考项目教训：`dpquar v1.3` 在锁内做 O(n) → panic_on_rcu_stall 重启。
4. **顺序**：先 `armed=0`（dry-run）跑 24 h，看 `black_hits/consumer_calls` 比例是否合理（预期 <1%），
   再开 `armed=1`。**不要在第一次上机就 armed=1**。

产物：`_local/work/crash-root/fix/pageguard/{pageguard.c,pageguard.ko,build_pageguard.sh}`
（zig cc aarch64-freestanding，196,664 B，29 个未定义符号全是内核导出符号，`.gnu.linkonce.this_module` 已就位）。

### 2.4.1 KASLR 实测：**本设备上内核地址是确定的**（E3，本轮新增）

`CONFIG_RANDOMIZE_BASE=y` 只表示"可随机化"，不表示"已随机化"（arm64 需要 bootloader 经
`/chosen/kaslr-seed` 给种子）。实测：`analysis/kern/kallsyms.txt`（设备 `/proc/kallsyms` 转储）
与 `analysis/kern/vmlinux.elf` 的链接地址**逐符号相同**：

| 符号 | vmlinux.elf | 设备 kallsyms |
|---|---|---|
| `aarch64_insn_patch_text` | `0xffffffc008122394` | `0xffffffc008122394` |
| `alloc_zeroed_user_highpage_movable` | `0xffffffc00812722c` | `0xffffffc00812722c` |
| `page_frag_free` | `0xffffffc00825fb24` | `0xffffffc00825fb24` |
| `__alloc_pages` | `0xffffffc008261df0` | `0xffffffc008261df0` |

→ 站点常量在**当前固件启动下有效**；但**不要依赖它**：模块仍逐站点校验 guard word，
KASLR 若哪天生效，5 个站点会全部 mismatch → 模块只打印 SKIP、**一个补丁都不打**（这是设计好的 fail-safe，
同时也是"KASLR 被启用了"的告警）。**lab 上机时必须核对 `dmesg` 的 `patched=N/5`。**

### 2.5 lab 上机协议（预注册判据）

**第 0 步（必做，5 min）**：解析符号 + 试加载
```sh
# 设备侧（devop.py 持锁）
for s in aarch64_insn_patch_text __netdev_alloc_frag_align __alloc_pages alloc_zeroed_user_highpage_movable; do
  grep -m1 " $s\$" /proc/kallsyms; done
insmod /data/repro/pageguard.ko patchfn=0x.. fn_frag=0x.. fn_alloc=0x.. fn_auhm=0x.. armed=0
dmesg | tail -5 ; cat /proc/pageguard
```
**判据 0**：`patched=5/5`（任一 SKIP 必须查明原因；<5 则本轮实验作废，不是阴性）。
**正对照**：`echo reset > /proc/pageguard` 后灌 LAN 流 60 s，`producer.calls` 必须 >0 且 `pages_marked` 增长
（证明生产钩子真的在跑）；否则生产者链路无效，后续阴性一律作废。

**第 1 步（dry-run，24 h）**：`armed=0`，正常业务流量。
**判据 1**：`consumer.black_hits / consumer.calls` 与 `quarantine` 不增长（dry-run 不扣页），
且 `black_hits > 0`（若 0，说明被标记的页从未被分配成匿名页 → 本设计**与本缺陷无关**，必须回退重设计）。

**第 2 步（armed A/B，同会话）**：4×vsurv4 canary + LAN 2 MB/s 灌流（已验证可达 100+ 命中/min）。
- 设计：**ABABABAB**，每臂 5 min，共 8 臂 40 min；A = `armed=0`，B = `armed=1`；
  canary 全程不重启；每臂记录 h4 增量 + 设备侧 RX 计数。
- 统计：各臂命中数对总命中数做**条件二项检验**（等时长时 H0 下 B 臂占比 = 0.5）。
  300 s × 127/min ≈ **635 命中/臂**，H0 下 B 臂 ≈ 2540 ± 35.6；**降幅 10% 即可 8σ 检出**，功效远超需要。
  （依据：C-156 已证明同会话内命中近似泊松，故二项检验是合法零模型。）
- **判据 2**：B 臂合计/A 臂合计的比值 R，**95% CI 上界 < 0.2** 才算"有效阻断"；R>0.8 判"无效"；
  0.2–0.8 判"部分有效，需记录并分析黑名单覆盖面"。
- **每个会话只做一次，并且必须记录 `black_hits`**：若 R 很低但 `black_hits` 也低，
  说明起作用的不是我们的机制（混淆）—— 必须同时报告。

**第 3 步（自然 NE 窗口）**：见 §4。

**回滚条件（任一触发立即 `rmmod pageguard`）**：内核 Oops/panic 且栈里出现 `pg_shim_*`；
`consumer.gave_up` 快速增长；吞吐下降 >10%；`/proc/pageguard` 不可读。

### 2.6 两种 transport 判决下的 pageguard 变体（Lead 2026-11-01 要求）

pageguard 的**骨架是 transport 无关的**：`危险来源 → 黑名单 → 匿名页分配时拒绝+扣留`。
变的只有"危险来源"（生产者钩子）。所以两种判决下**消费半边（拒绝+扣留+重试）完全复用**，只需换生产者。

#### 变体 A —— 判决"PA/DMA（陈旧描述符打 PA）"：**现设计原样上机**
- 生产者 = RX 环装填（`mtk_rx_alloc_edma`/`fe_edma_open` 的 `__netdev_alloc_frag_align` 调用点）。
- 前提 = 受害页**曾经是 RX 环缓冲页**。这正是 §2.5 第 1 步 dry-run 要验的：`black_hits>0` 才能证明前提成立。
- 失效条件：A/B 的 R 不显著，或 `black_hits=0` → 前提假，本变体作废。

#### 变体 B —— 判决"uaccess / 内核直映射（VA 解析）"：**前提作废，需重设计**

先把 Lead 的担心落实成一句话：**若写者按 VA 写，则"危险"的不是物理页，而是"某个内核代码路径此刻持有一个指向用户 VMA 的 VA"**。
把 PA 拉黑对此**完全无效**——因为页本身没错，错的是"谁在什么时候写它"。

分三种子情形（对应任务板 B1/B2/B3 的判决实验出口）：

| 子情形 | 写者形态 | pageguard 是否可复用 | 可行补偿控制 |
|---|---|---|---|
| **B1 GUP/pin 迟写**（use-after-unpin） | 驱动 `pin_user_pages` 拿到 kaddr，unpin 后仍写 | **可复用骨架**：把生产者换成 `unpin_user_page*` 的调用点（call site 少，好打），把被 unpin 的页拉黑 | 与变体 A 完全同构，**改动量 ≈ 换 1 个站点表**。这是 B 情形里性价比最高的一条 |
| **B2 uaccess 型**（stale 用户指针 + `copy_to_user` 类） | 内核在 uaccess 窗口里按 VA 写目标 | **不可复用**（用户 VA 与页身份无关） | 见下"B2 可行性" |
| **B3 内核直映射写**（`__va(pa)` 的内核 store） | CPU store，绕过 MMU 权限 | 不可复用 | 只有 `set_memory_ro(__va(pa))`（一次性判决实验，不能常驻：原子上下文 fault → panic）。**不建议做常驻控制** |

**B2 可行性（Lead 提的"写回路径校验目标 VA 是否落在用户栈 VMA 内"）—— 结论：可行但代价高，且必须等点名**：
1. **没有任何"每个 uaccess store 之前"的通用钩子**：kprobe/ftrace/perf 全不可用（§2.4），
   只能靠 `bl` 调用点打补丁；而 `copy_to_user`/`__arch_copy_to_user` 的调用点在全内核有数百个，
   **不可能全打**（每个站点 16 B 补丁 + 每次调用一次 VMA 查找 = 整体 uaccess 成本翻倍，设备撑不住）。
2. **可做的形态只有一个**：analyst 把写者点到一个**具体函数**（例如某驱动的 `skb_copy_to_linear_data` 或
   `memcpy` 到 `kaddr` 的那一处），然后**只给那一处打补丁**，在 shim 里做
   `find_vma(current->mm, dst) && (vma->vm_flags & VM_STACK) → 拒绝并记日志`。
   成本 = 每次该调用一次 rbtree 查找（~`find_vma` 100–200 ns），对单个驱动可接受；对通用 uaccess 不可接受。
3. **实现顺序建议**：先做 `armed=0` 的"检测版"（只记"目标 VA 落在用户栈 VMA 内"的事件计数，不拒绝），
   跑 24 h 看计数是否为 0 —— 若为 0，说明这条假设本身不成立，及时止损。
4. **反证条件**：若点名后的单点 shim 在 24 h 内记录到 ≥1 次"写入目标落在用户栈 VMA"，则 B2 被实证，可升级为拒绝。

#### 一句话给 Lead 的取舍
> 变体 A 与 B1 共用同一份代码（换站点表即可），B2 需要**先点名写者**才能把成本压到可接受，B3 不建议做常驻控制。
> 所以 transport 判决出来之前，**pageguard 唯一该做的事就是把消费半边（拒绝+扣留+重试+fail-open）做扎实**，
> 这部分在三种判决下都要用。

---

## 3. SMMU/IOMMU 可行性 —— **不可行（本内核），等于重编内核 + 改 DT（E3）**

三路独立查证：

| 路线 | 证据 | 结论 |
|---|---|---|
| **`.config`** | `CONFIG_IOMMU_API=y` 但 **`# CONFIG_IOMMU_SUPPORT is not set`**；`CONFIG_VFIO_IOMMU_TYPE1=y`（仅 VFIO 影子） | IOMMU 核心枚举 API 在，但 **`drivers/iommu/` 不编译** → 不可能有 SMMU 驱动 |
| **vmlinux 字符串** | `strings vmlinux.elf | grep -ic smmu` = **0**；`mmu-500`/`mediatek,*mmu` 也 0 | 没有 SMMU 驱动、没有相关 compatible 匹配表 |
| **kallsyms** | 152 个 `iommu*` 符号全是通用核心（`iommu_group_*`/`iommu_domain_*`/`iommu_map`…），**无 `arm_smmu_*`、无 `mtk_iommu_*`** | 无驱动实现 |

**结论**：R2（SMMU）在现有固件上**不可行**；要做得 ①重编内核开 `CONFIG_IOMMU_SUPPORT` + 对应 SMMU 驱动、
②改 DT 给 FE/WED 节点挂 `iommus = <&smmu ...>` + 保留内存/stream ID 映射、③刷机。
**而且即使做成，它也只是把"写复用用户页"变成"IOMMU fault"**——仍然没修 bug，只是换了个失败模式
（DMA fault 可能导致 RX 卡死/丢包，需要 fault handler 兜底）。**不建议作为本轮方向。**

**给 lab 的一条只读确认命令**（若还想确认 DT 侧）：
```sh
ls /proc/device-tree/ ; grep -ril smmu /proc/device-tree/ 2>/dev/null | head
```
若 DT 里也没有 smmu 节点，则连"厂商留了节点没编驱动"的可能也排除。

---

## 4. 验收判据：什么算"修好了"

分三层，**每层单独可判伪**。注意项目已有的功效教训：95% CI 含 1 = 无功效。

### 4.1 止崩层（nerepair，已部署）

| 指标 | 判据 | 最小样本 |
|---|---|---|
| 覆盖 | `/proc/*/status:TracerPid` == nerepair 的 pid 占**全部用户进程**（排除 vsurv4/内核线程）的比例 ≥ 99% | 一次全量扫描 |
| 不误修 | `PASS reason=shape-fail` 中 `w1==0 && w0∈{fault,fault+8}` 的"近失"条目数 = 0（近失 ≠ 0 说明加固把家族挡在门外） | ≥72 h |
| 不死锁 | `reason=repair-loop` < 3 次/天 | 24 h |
| 心跳 | `/tmp/nerepair.hb` 最大间隔 < 180 s（远低于 watchdog 阈值） | 24 h |

### 4.2 止写层（pageguard，试点）

| 指标 | 判据 | 功效 |
|---|---|---|
| 主判据 | **同会话 ABAB**，B/A 命中率比 R 的 95% CI 上界 **< 0.2** | 8 臂 × 5 min × ~635 命中/臂；10% 降幅即 8σ —— 本轮**功效充分** |
| 一致性 | `black_hits > 0` 且 R 低 | 否则判"起作用的是混杂物"，不算通过 |
| 复现 | 同一结论在**≥2 个独立会话**出现（跨会话数值不可比，只比方向/显著性） | 2 次 |
| 代价 | LAN 2 MB/s 灌流吞吐下降 ≤3%；`softirq NET_RX`/s 上升 ≤5%；`loadavg` 无系统性上升；匿名缺页延迟 p99 上升 ≤5% | 每臂 5 min ×3 |
| 内存 | quarantine ≤1024 页（4 MiB），`full` 计数 = 0 | 全程 |

### 4.3 自然 NE 窗口（唯一能"对外宣称修好"的一层）

**必须先承认功效**：自然 NE 基线 ~0.5–4/h（且 nerepair 已在修复，口径被污染）。

| 窗口 | 基线 0.5/h 下期望事件 | P(观测 0) | 能得出的结论 |
|---|---|---|---|
| 6 h | 3 | 5.0% | **只能写"6 h 未见"，上界 ≈0.5/h，不能写"修好"** |
| 24 h | 12 | 6.1e-6 | 可以写"下降 >X 倍"（需配合 X 由基线算出） |
| 72 h | 36 | 2.3e-16 | 有足够功效支撑"未再发生" |

→ **6 h 窗口不足以判定修好**（这正是 00_STATE §10 已记的教训："75 min 窗口对 0.5/h 基线无功效"）。
**建议**：自然 NE 层用 **≥24 h**，并同时记录 `canary 命中率`（作为过程量，避免"刚好没出事"的假阳性）。

**口径前提**：要测自然 NE，必须**停 nerepair + 停 canary 的 vsurv4 排除逻辑**（否则自然 NE 被修复、计数被清零），
而这又会把设备暴露回崩溃——所以自然 NE 层建议放在**独立 drill 窗口**里做，不做常驻。

### 4.4 回滚条件（汇总）

| 触发 | 动作 |
|---|---|
| 内核 Oops/panic 栈内出现 `pg_shim_*` 或 `pg_bl_word` | `rmmod pageguard`（先 `echo unpatch`），保留 pstore，冻结该版本 |
| 吞吐下降 >10% 或 `consumer.gave_up` >100/min | `echo off`（不卸载，保留观测）→ 复盘 |
| nerepair `reason=repair-loop` >10/天 | 回滚 nerepair 到 v1.7（不修，让进程正常死） |
| dry-run 24 h 后 `black_hits=0` | 本补偿控制无效，回退设计（改整块标记 / 改钩 `skb_free_head`） |

---

## 5. 若 §2 的 A/B 判"部分有效"——下一轮的两个可调变量

1. **标记粒度**：现在只标 fragment 覆盖的 1–2 个 4K 页；改成标整块（`compound_order` 2^3 页）会扩大保护面、
   也扩大误伤（同一 page_frag 块被 TX 侧共用）。A/B 部分有效 → 先试整块。
2. **生产钩子扩面**：现在只钩 `mtk_rx_alloc_edma`/`fe_edma_open`（环装填）。
   若受害页来自 `skb_free_head` 那一支（=先分配进 skb 再落到环），加钩 `skb_free_head`（`0xffffffc0087ac338`）
   与 `page_frag_free` 的 17 个站点中的 RX 三条（`mtk_poll_rx_edma0/1`、`mtk_rx_clean_edma`）。

---

---

## 6. 影响面清单：`ne_sites.py`（WOULD_REPAIR 按 site 聚合）

Lead 2026-11-01 要求：把 `WOULD_REPAIR` 按 site pc 聚合，并接到静态符号表上（pc → 函数名）。
产物：`_local/work/crash-root/fix/ne_sites.py`。

### 6.1 一个必须先说清的口径问题（否则整张表是错的）

**nerepair 记的 `pc` 是用户态 pc**（`PTRACE_GETREGSET` 取的是 tracee 的 NT_PRSTATUS 用户寄存器），
**不是内核地址**。所以"拿 vmlinux 符号表把 pc 翻成函数名"**不成立**——必须先知道这个 pid 跑的是**哪个二进制**。
而进程崩溃后 pid 就没了，事后无法再解析 `/proc/<pid>/exe`。

→ **v1.9.1 的最小增量**（不改判据，只加可观测性）：
1. `BIN` 行：每个 tracee 首次进入故障处理时记一次
   `BIN  pid comm path=<exe> dev=<n> ino=<n>`（`readlink(/proc/pid/exe)`+`stat`，按 pid 缓存，热路径零成本）；
2. `NEAR` 行补 `pc=`（原来只有 fault/word，缺 site）。

→ 于是三路解析优先级：**内核 pc（≥0x8000000000）→ vmlinux.elf**；
**用户 pc → BIN 记录的 exe（本地有副本就符号化，`--bin-root` 重定位）→ `--bin comm=PATH` → `--symbols` 静态表**。

### 6.2 用法

```sh
# 1) 最常见：日志 + 设备二进制副本（lab 拉下来的 vsurv4/busybox）
python _local/work/crash-root/fix/ne_sites.py \
    _local/evidence/crash-root/nerepair.log \
    --bin-root _local/evidence/crash-root/bins \
    --out _local/evidence/crash-root/ne_sites.tsv

# 2) 只接 analyst 的静态符号表（kallsyms.txt 或 TSV: name<TAB>start<TAB>size）
python _local/work/crash-root/fix/ne_sites.py nerepair.log --symbols analysis/kern/kallsyms.txt

# 3) 二进制还没拉回来：先出 pc 排名，符号列留 (unresolved)
python _local/work/crash-root/fix/ne_sites.py nerepair.log
```

自动带上 `.log.1` 轮转文件；`--top` 控制表长。

### 6.3 输出五段（直接抄进交付报告"影响面"一节）

| 段 | 内容 | 用途 |
|---|---|---|
| **by site** | 排名表：site pc / 次数 / 去重 pid / top comm / 符号 / +偏移 / 出现小时数 | "自然 NE 在哪里死"的主表；同一 pc 高频 = 同一代码路径 = 免费的身份线索 |
| **by comm** | 进程维度计数与去重 pid | 爆炸半径：是子进程级（每请求）还是监听父进程级 |
| **G6 名单** | "已知会死但 dry-run 故意不救"的 comm+pid | 交厂商的证据；也是 armed 后的预期修复量 |
| **NEAR** | w1==0 且 w0==fault 但被 w3/长度带拒绝的 site | **加固是否误伤真家族**的唯一探测器；判读列直接写 `REVIEW: w3!=0` / `REVIEW: len out of band` |
| **repair-loop** | 熔断命中（site, 次数, 最长连续 n） | >0 即"armed 会降覆盖"，不得上线 |

### 6.4 验证（不是"跑通了"，是有断言的）

- `ne_sites.py --selftest`：11 项断言（事件计数/去重 site/NEAR 字段/loop n/BIN 解析/内核 pc 解析），**PASSED 0 failures**。
- 端到端 demo（合成日志 + 本地二进制）：`pc=0x1014728 → main +0x11ac`（comm 映射路径），
  未命中的 comm 显示 `(unresolved)` 而不是瞎猜 —— **宁可留空，不给假符号**（判据纪律）。
- 内核路径同样验证：`0xffffffc008595548 → mtk_poll_rx_edma0`。

### 6.5 与 analyst 的接口

analyst 只需要给两样中的任意一样，本脚本即可全自动：
1. **符号表文件**：`kallsyms.txt` 原样，或 `name<TAB>start_hex<TAB>size_hex` 的 TSV；
2. **设备侧二进制副本**（vsurv4 / 原厂 busybox / ip / awk），放到 `--bin-root` 下。
   注意原厂 busybox **很可能是 stripped**，那时 pc 只能到"页级/函数级近似"，需要 analyst 用其静态表反查。

---

## 7. 自然 NE 覆盖缺口实测（2026-11-01 13:04–13:06，4 起）

> 触发：lab 报 4 起自然 NE（`sh /data/gw/cfg_heal.sh --tick`×2、`tr`×1、`tail`×1），
> **nerepair v1.7 在跑，4 个进程全部死亡**。原始件 `_local/evidence/crash-root/natne/*.stack`（4 份，各 65,592 B）。
> 本节只写**能由现有证据判定**的部分；需要设备侧一次读取才能定案的部分明确标注。
>
> **定性边界（Lead 2026-11-01，必须遵守）**：本节只立"**判据形态覆盖面**"这件事，
> **不预设这 4 例属于本家族**。记录在栈上 ≠ 记录导致（04_FAMILIES §7）；4 份记录的位置
> （`top−0x1390 … top−0x77c0`）都不在 va_list 槽位（canary 不变量 `top−x2=0x390`），
> **很可能是 bystander**。fault-addr 对齐核查由 skeptic 进行，**结论出来前不得写成"判据漏真家族"**。

### 7.1 已证实（E3，本地解析）

`.stack` 格式（`gw/src/stackdump.c`）= 48 B 头 + 8 B 位图 + 16×4 KB。解析工具：
`_local/work/crash-root/fix/natne_scan.py`（只读，无设备访问）。

| pid | ts | stack 区间 | 记录数 | 记录相对栈顶 | 形态 | w0 | w2 |
|---|---|---|---|---|---|---|---|
| 17847 | 1793509363 | 0x7fcb6d1000–0x7fcb6e1000 | 2 | 0x7158 / 0x7010 | A0B2 | 0x20090 / 0x20085 | **0x4d08ade0000062f** |
| 3374 | 1793509503 | 0x7fd726e000–0x7fd727e000 | 1 | **0x1438** | A0B2 | 0x23648 | **0x4d08ade0000062f** |
| 4278 | 1793509504 | 0x7fe2c06000–0x7fe2c16000 | 3 | 0x77c0 / 0x6e98 / 0x6d50 | A0B2 | 0x1c949 / 0x21d50 / 0x21d43 | **0x4d08ade0000062f** |
| 4700 | 1793509569 | 0x7ffe684000–0x7ffe694000 | 1 | **0x1390** | A0B2 | 0x22aaf | **0x4d08ade0000062f** |

三条可引用的事实：
1. **4/4 的栈里都有本家族 A0B2 记录**（共 7 个窗口，去重后），`w1=w3=0`、`len=0x62f=1583` 落在记录家族的长度带内，
   `w2` 高 32 位 `0x04d08ade`（按内存序解读为 222.138.208.4，公网对端）——**与 canary 同族、同一条长度的记录**。
2. **但位置与 canary 不同**：canary 的固定不变量是 `top − x2 = 0x390`（111/112 份），
   这 4 份的记录在 `top − 0x1390 `… `top − 0x77c0`，**没有一个落在 0x390**。
   其中 3374（0x1438）与 4700（0x1390）几乎同位（差 0xA8），形似同一个调用路径位置。
2b. **加固不是元凶**：7/7 窗口的 `w3 = 0`、`len` 全在 `0x400..0x20000` 带内、`w0` 全 < 2²⁴
   → 若崩溃形式是 pop 型且记录恰在 `x2`，**v1.7 与 v1.9.1 的判据都会接受**。
   即：v1.9.1 新增的 `w3==0` + 长度带**没有**把这几例真记录挡在门外。
3. **"记录在场" ≠ "记录导致"**（04_FAMILIES §7 已立此规则；`sh.core` 就是 bystander 先例）。
   仅凭 .stack 无法判定这 4 次崩溃是否由记录引起 —— 需要 fault 地址与故障指令。

### 7.2 尚未定案（**卡在一次设备读取上**，不是分析能力不足）

要回答问题"nerepair 对这 4 个 pid 有没有动作"，必须拿到 `/data/gw/logs/nerepair.log`（含 `.1`）中这 4 个 pid 的全部行。
**本地工作区没有该日志副本**（已检索 `_local` 全树：4 个 pid 号零命中，无 nerepair 日志）。

一次读取即可定案（lab，≤250 行分页 + 行数断言）：

```sh
# 设备侧：先取总行数与命中行数，再分页取
wc -l /data/gw/logs/nerepair.log /data/gw/logs/nerepair.log.1
for p in 17847 3374 4278 4700; do
  grep -c "\t$p\t" /data/gw/logs/nerepair.log /data/gw/logs/nerepair.log.1
done
# 再按 pid 逐页取（每页 ≤250 行），并要求 fetched == grep -c 的结果
```

### 7.3 判定树（拿到日志后按此一步分类，不需要再讨论）

| 日志证据 | 分类 | 含义 | 处置 |
|---|---|---|---|
| 该 pid **零行**（无 ATTACH、无 SEGV） | **A. 未覆盖** | attach 失败 / 扫描漏 / 父进程未 trace | 见 §7.4 的 4 个已知漏洞 |
| 有 `PTRACE`-前无 ATTACH 但有 SEGV | **B. 半覆盖** | 曾 attach 后 detach | 查 attach 超时（3 s 上限） |
| `SEGV` + `PASS reason=not-load` | **C. 指令形态不匹配** | 故障指令不是 `ldr Xt,[Xt]` | **判据盲区**，见 §7.5 |
| `SEGV` + `PASS reason=rt-ne-rn` | **C'** | 同上（基址≠目标寄存器） | **判据盲区** |
| `SEGV` + `PASS reason=addr-ne-xt` | **C''** | `si_addr ≠ Xt` | **判据盲区** |
| `SEGV` + `PASS reason=shape-fail w=…` | **D. 判据拒绝** | 记录不在 x2 / 形状不符 | 用日志里的 w0..w3 与 v1.8/v1.9.1 逐条对比 |
| `SEGV` + `REPAIR` 但进程仍死 | **E. 修复后二次崩溃** | 修复点之后又踩到同一污染 | 需 core 的第二次 fault |

### 7.4 代码级已确认的覆盖漏洞（**与本次事件无关也成立**，按严重度）

| # | 漏洞 | 证据（源码） | 后果 |
|---|---|---|---|
| **V1** | `scan_proc()` **只在 `ECHILD` 时调用** | v1.7 `main` 循环：`if (errno == ECHILD) { scan_proc(); continue; }`。只要有任一 tracee 存活，`waitpid` 永不给 ECHILD | 启动后**新出现的、不是 tracee 后代**的进程**永远不会被 attach**；唯一的初始扫描发生在开机早期 |
| **V2** | `attach_pid` 3 s 超时即放弃，**无重试** | v1.5 注释与代码 | 开机繁忙期 attach 失败的进程及其整个子树**永久裸奔** |
| **V3** | `is_ldr_same() + rt==rn` **只覆盖"pop 本身"** | `is_ldr_same` 白名单是 LDR/LDUR/LDRB/H/SW 的**寄存器自指**形式；`rt != rn` 直接放行 | **被污染 va_list 产生的"解引用型"崩溃**（`%s` → `strlen`/`memcpy` 里 `ldrb w2,[x0]`）**必然放行**。这类是同一家族后果，但指令形态不同 —— **本次 4 例的高优先候选解释** |
| V4 | 只修 `SIGSEGV/SIGBUS`；信号投递时机由内核决定 | — | 其他致命信号形态不修（设计内） |

> **V3 是本轮新发现，且是结构性的**：mask 的判据是"故障指令 = `ldr Xt,[Xt]` 且 `si_addr == Xt`"，
> 这刻画的是 **va_arg 取值那一条指令**。而记录污染 va_list 之后，进程更常见的死法是把那个垃圾值**当指针继续用**
> （`%s`/`%n`/`memcpy`），此时故障指令的 `rt ≠ rn`（如 `ldrb w2,[x0]`），**mask 一律 PASS**。
> 这解释了"记录在栈上、进程照死"却"日志里可能只有 PASS"的组合。

### 7.5 v1.9.2 够不够？—— **不够当唯一防线（Lead 已采纳此裁定，2026-11-01）**

> **定位修订（Lead 决定，写入最终交付"限制"章节）**：
> nerepair 的对外定位 = 「**对 pop 型（`ldr Xt,[Xt]`，rt==rn，si_addr==Xt）有效**」；
> 其余形态**明确列为已知不覆盖**，并必须在 watchdog / 健康页**显式呈现，不许沉默**。
> v1.9.2 的 `NEAR reason=insn` 就是这条"不许沉默"的计量器。

不论 §7.2 的日志最终落在 A/B/C/D/E 哪一类，v1.9.1 的**判据宽度**都不足：
- 若落 A/B → 覆盖漏洞 V1/V2 未修（v1.9.1 已补"每 60 s 重试 PID1 + 每 10 min 全量 rescan"，**部分缓解 V1/V2**，但 attach 仍无重试队列）。
- 若落 C → **V3 未修，V3 不在 v1.9.1 的任何改动里**。
- 若落 D → v1.9.1 反而**更严格**（加了 w3/长度带），可能把真家族拒得更多 —— 需要按这 4 例的具体 w 值核对。
- 若落 E → v1.9.1 无改善。

**因此本轮定性必须改**：**nerepair 不能作为唯一防线**（FIX.md §4.4 "单层防御"的表述需要 Lead 修订）。
在 V3 修好之前，nerepair 的定位应写成"**对 `ldr Xt,[Xt]` 型（pop 型）有效**"，
其余形态属于**已知不覆盖**，必须在告警面（watchdog/健康页）显式呈现，而不是沉默。

**立即可做的观测补丁（v1.9.2，不改行为、只加计数）**：
现在 `not-load` / `rt-ne-rn` / `addr-ne-xt` 三个分支**只记一行 PASS**，无法回答"这次是不是 V3"。
改为：这三个分支里**照样读一次 `x2` 的 32 B 并做形状检查**，命中就记
`NEAR reason=insn rt=%d rn=%d insn=%#x`（仍然 PASS、仍然不修）。
这样 dry-run 24 h 就能**直接量出 V3 的规模**——如果 `NEAR reason=insn` 与 `WOULD_REPAIR` 同量级，
就证明"记录家族里有一半以上根本不在 nerepair 的修复射程内"，这是对交付定性最关键的读数。

**V3 的修复方向（下一轮，需设计+正反对照，不在本轮实现）**：
把判据从"指令形态"改为"**故障基址寄存器 == si_addr 且该处 32 B 是家族记录**"：
`is_load(insn)` 只要求是 load 且 `regs[rn] == si_addr`，不再要求 `rt == rn`；
修复动作从 `pc += 4`（跳过）改为"**把基址寄存器改指向记录本身**"（记录里有零字节，`strlen` 会立即终止），
或"改指向每进程固定的零页"。两者都必须先在 host 上与正/负对照一起验证，**不得直接上机**。

## 8. 本轮明确"没做/不能做"的（措辞已按 Lead 修订：根修复可达性 = f(writer 点名精度)）

- **没有上机**：pageguard / nerepair v1.8 都只做了 host 构建与 host 判据测试；设备由 lab 独占。
- **没有自然 core 的 32B 原始数据**：mask 阴性的 X 类是合成的（已在 §1.1 标明）。
- **没有厂商驱动源码**：R1（厂商驱动修复）不可达。
  **但"根修复不可达"这个说法撤回**（Lead 2026-11-01）：若 transport 最终判为 uaccess，
  根修复可能就是**改调用点那一处**（一行边界检查），完全不需要厂商源码 ——
  正确表述是 **"根修复的可达性取决于 writer 的点名精度"**：点到函数级 → 我们可改/可包；
  只到"某路径" → 只能上补偿控制。
- **没有验证 `/proc/swaps` 为空**（影响 `do_swap_page` 是否要覆盖）——交给 lab 一条只读命令确认。