# SKEPTIC_ARMED_WINDOW · 布防事实核对与 0 点复核预注册（task-6）

> 角色：skeptic。本文分两段：**§1 = 现在已完成的布防只读核对（E3）**；**§3 = 0 点复核的预注册口径**（先写死，不得事后放宽）。
> 设备访问全程只读（lgssh.py；无 push/put/devop/dd/chmod/touch/rm/kill/reboot/挂载/重定向/tee；不轮询）。
> 我的读取时刻：**2026-11-03 19:58:03 与 19:58:40 +0800**（本文件 §1 的全部设备读数）；命令原文见 `tmpfiles/review/skeptic/DEVICE_READ_AUDIT.md`（待补本轮两行）。
> 证据等级：E0 无证据 · E1 弱 · E2 强推断 · E3 直接观测 · E4 因果闭环。不引用已撤回结论（88/112、自然 NE 0/4、C-138、C-145、C-016..019）。

---

## 1. 布防事实核对（E3，2026-11-03 19:58 +0800 实测）

**结论：布防动作真实生效、当前无副作用、无覆盖空洞。**

| # | 核对项 | 判据 | 实测 | 判 |
|---|---|---|---|---|
| 1 | 模式切换 | 日志出现 `MODE dry=0 by=SIGUSR2`，且 STAT 由 dry→armed | `1793706921 = 2026-11-03T19:55:21 MODE dry=0 by=SIGUSR2`；STAT 19:55:00 `mode=dry` → **19:56:00 / 19:57:00 / 19:58:00 连续 3 拍 `mode=armed`** | **PASS** |
| 2 | dry 标记已除 | `/data/gw/nerepair.dry` 不存在 | **ABSENT** | **PASS** |
| 3 | XREP 未布防 | `/data/gw/nerepair.xrep` 不存在 **且** STAT `xrep=0 xw=0 xr=0` | ABSENT；STAT 三值全 0 | **PASS** |
| 4 | slotguard 未布防 / slotdrop 关 | `slotguard.arm`、`/tmp/nerepair.slotdrop` 不存在且 `sd=0/0/0/0` | 两标记 ABSENT；STAT `sd=0/0/0/0` | **PASS** |
| 5 | 无覆盖空洞 | nerepair pid 不变（SIGUSR2 是进程内切换，非重启） | **pid=11617 未变**；`/proc/11617/stat` `starttime=2758` jiffies（= boot+27.58 s，与布防前一致） | **PASS** |
| 6 | 覆盖率（三定律合规） | 全量集合 + 字段精确 + 排除自身 | 用户进程 **60**（`/proc/<pid>/exe` 可解析）；`TracerPid=11617` 者 **59**；**排除自身后"未跟踪的用户进程" = 0**（全量 /proc/[0-9]*/status 逐条、精确字段、排除 pid 11617）⇒ **59/59 = 100%**。其余 ~200 个 TracerPid=0 的任务其 `exe` 不可解析 = 内核线程，非用户进程 | **PASS** |
| 7 | 心跳新鲜 | hb 与 uptime 差 < 180 s | `/tmp/nerepair.hb = 7947` @ uptime **7950.51** ⇒ age ≈ **3.5 s** | **PASS** |
| 8 | 布防注记在位 | `/data/gw/logs/arm_2026-11-03.txt` 存在且记录基线 | 在位（153 B，mtime 19:55）：`ARM uptime=7789.03 26137.11 load=7.70 7.75 7.72 3/302 25067 baseline_segv=3 baseline_passed=3 baseline_repaired=0 note=dry_marker_removed_SIGUSR2_toggle` | **PASS** |
| 9 | 无 REPAIR 风暴 | REPAIR 行数、`loop`、repair-loop 计数 | **REPAIR 行 = 0 条**（整份日志）；STAT `loop=0`；`repair-loop` 计数 **395（未增，与布防前同）** | **PASS（无风暴）** |
| 10 | 系统无异常 | loadavg / ctxt / processes 速率 | load `7.26 7.55 7.64`；ctxt 64,718,810 @7950.51 ⇒ **8,141/s**；processes 2,625,562 ⇒ **330/s**（布防前 8,062/s、327.6/s，同量级）；attached=45 未变 | **PASS** |

**基线锚（0 点对账用）**：布防时刻 = **epoch 1793706921 / uptime 7789.03**；注记基线 = **segv 3 / passed 3 / repaired 0**（与 STAT 实例计数一致）。

## 2. 窗口事件盘点（截至 19:58:40，与 §1 同一批次）

| # | 时刻 | comm | 归属 | 形态 | nerepair 判定 |
|---|---|---|---|---|---|
| ① | 18:58:11 | slotguard | 自然（组件） | `insn=0xb9800108`（LDRSW x8,[x8]）far=−0x28；完整 64 KB `.stack` 扫 **0** 条家族记录 | PASS `shape-fail`（**硬门正确放行**） |
| ② | 19:29:05 | od | **观测者注入** | 规范 A0B2 记录 `q0=0x1ee27 / len=1601 / ip=192.168.9.1`；来源 = 我的只读取证命令 | PASS（rt≠rn）+ `WOULD_DREPAIR path=p2`（**dry 下未修，进程死亡**） |
| ③ | 19:51:16 | ip | 自然（our-tree；**布防前**） | `args=ip -o -4 addr show`；far=0x17dde（<16 MiB 小值）；`insn=0x39400008`（rt=8 rn=0 ⇒ rt≠rn），x2=0xffffffffffffffff | PASS（`[sp,sp+16K)` 无记录证据） |

- 窗口 NE = **3 条**（自然 2：slotguard/ip；观测者注入 1：od）；实例 STAT `segv=3 passed=3 repaired=0` 与 arm 注记基线一致。
- **现场校准（0 点报告须设「现场校准」节，Lead 补充 1）**：③ 是本窗第一条**自然小地址 load 崩溃**——far=0x17dde **落在长度带 [0x400,0x20000] 内**、指令为 load 且 rt≠rn，却**没有任何记录证据**（mode 0 弱门未命中）。含义两条：
  1. **自然 SEGV 里相当一部分不是家族**：本窗 2 起自然崩溃（slotguard、ip）**0 起**被判据命中，与 pre-arm 语料 **4/20 = 20%** 同方向同量级 ⇒ 不得把"自然崩溃数"当"家族崩溃数"，也不得反推"家族覆盖率≈100%"。
  2. **S1 的现场依据**：armed 后**同类事件仍会走 PASS 并照死**（dry→armed 只改变"判据命中后是否改寄存器"，不改变判据本身）⇒ **"NE 条数是否下降"不能作为效力判据**——能下降的只有"判据命中的家族崩溃"那一部分，判据未命中的自然崩溃照常进 NE 台账。0 点报告必须先按 `PASS reason`（shape-fail / rt-ne-rn / not-load / repair-loop）分层，再对 NE 条数作任何解释。
- 布防后（19:55:21→19:58:40）至今 **无新增 SEGV、无 REPAIR**。

## 3. 观测者污染审计（本窗最大的口径陷阱）

1. **采集器** `tools/oneoff/review/arm_watch.py`：每 10 min 一次纯读会话，设备侧命令 = `echo / cat / ls / pidof / wc / tail`（**不含 od/awk 长管道**），命令原文写入 `tmpfiles/review/arm/latest.json:devcmd`（含轮次/cnt，可逐轮对齐）；**我复核的当前状态（19:59）**：`watch.tsv` 2 轮（19:56:47、19:57:01）、`latest.json.alerts=[]`、`n_repairs=0/alive=0/dead=0`、`stat.mode=armed`、`log_lines 2100→2101`、`ne_lines=1725`（Lead 告知下一轮约 20:07）。⇒ 每次约 10–15 次 fork、每 10 min 一轮，**fork 代价可忽略**（<0.05 %），但**每次会话都会新建被跟踪进程**。
2. **布防后的新形态（本窗特有）**：dry 期间观测者注入的家族崩溃会**落 NE 台账**（如 ②）；**armed 后同类崩溃会被 REPAIR**，于是`ne_events` 里**看不到**它 ⇒ **不能再用"NE 台账里有没有观测者行"来剔除观测者污染**。0 点复核必须改从 **REPAIR 行的 comm/pc/时间戳** 识别观测者自产修复（见 §4 S2）。
3. **我的读取**：19:58:03 / 19:58:40 两次（本轮），加上 19:21–19:36 的 12 次（见 DEVICE_READ_AUDIT.md）。这些会话自身产生的 ATTACH/PASS/REPAIR 行不得计入自然事件率。

## 4. 预注册复核口径（0 点用；0 点前写死，不得放宽）

**采纳 task-5 的 F 判据（原文）**：修复生效 = 至少 1 起家族型 REPAIR 且该进程存活 ≥30 min 且未再以家族形态死亡；反向 = REPAIR>0 但被修进程反复死亡 / 或 REPAIR 风暴（loop 激增）。

**skeptic 追加判据（本窗专用，先写死）**
- **S1**：**不得用"NE 计数下降"证明效力**——修复使家族崩溃不再进 NE 台账 = 同义反复。效力证据只能是 ① REPAIR 事件 ② 被修进程存活（R-11 表）③ 同一站点不再以家族形态死亡。
- **S2（细化·arm 版，Lead 补充 2）**：**观测者自产 REPAIR 的归属规则**，对每条 REPAIR 行按 (a)(b)(c) 判：
  - **(a) 父链（首要判据）**：取该 REPAIR 的 pid，在同一时刻的 /proc 快照内沿 `/proc/<pid>/stat` **字段 4（ppid）** 逐级上溯（每级都重新读该时刻的 stat，pid 复用会使纯历史链失效），若链上出现 PC 侧 dropbear 会话的派生进程（典型链：`dropbear → sh/ash → 命令`）⇒ 记 **origin=observer-ssh**。上溯必须用 **ppid 数值**，**不得用 pgrep / comm 子串**（判据三定律之二）。链路要记进报告。
  - **(b) 时间窗**：REPAIR 时间戳是否落在采集器轮询窗口内——窗口 = `tmpfiles/review/arm/latest.json` 的 `stamp` ± 该轮 `devcmd` 执行区间（**含轮次/cnt**，原文即 latest.json 的 devcmd 字段，可与 watch.tsv 的 `local_ts` 逐轮对齐）；或落在人工复核会话 ±60 s 内（会话时刻见 DEVICE_READ_AUDIT.md）。
  - **(c) 形态辅助（仅辅证，不单独定罪）**：comm 为一次性 applet（od/ip/date/awk/grep/cat/tail/wc/ls/sh）且 pc 落在对应 busybox 文本段（如 0x4e****/0x10a****）；或记录载荷规范（q0/len/ip 三要素齐）。
  - **判定**：(a) 成立 ⇒ **observer-injected**（单列，不计入"自然修复"）；(a) 不可判（pid 已退出/父链断）但 (b)+(c) 成立 ⇒ **observer-suspected**（单列并注明不确定）；(a)(b)(c) 全不成立 ⇒ 计自然修复。**任何情况下不得仅凭 comm 子串判入或判出。**
- **S3**：**记录命中 ≠ 崩溃命中**——150/150 是判据接受率；崩溃层只能由 REPAIR/NEW 死亡计数给出。
- **S4**：**自然率由背景率承载**（0.5–1.5 /h；4 h 窗期望 2–6 起，P(0)=e^-2…e^-6），**不得**用窗内 0/1 计数反推"已减少"；本窗**无对照臂、无 canary**（`? 待核实 vsurv4/vsurv5 是否在跑，列入 0 点首查`）⇒ 任何"已减少崩溃"的表述一律判**不成立**。
- **S5**：分母必须同时标注：时间基准（epoch 1793706921 起）、实例边界（pid 11617 / starttime 2758）、是否含观测者注入；报告里的每个率都要能追到 `arm_log_merged.txt` 行号。
- **S6**：R-11 存活判据用 `/proc/<pid>/stat` 的 `starttime+comm` 精确匹配（**不用 pgrep/pidof 子串**）；"存活"必须给采样时刻与间隔。
- **S7**：**弱门误修检查**：若 REPAIR 的 fault ∈ [0x400, 0x20000] 且命中来自 `which=q2` 或窗口无 IP 载荷（见 SKEPTIC_REVIEW 附录 HIGH-1 / §1.3g），须标"可能弱门误修"，不得算作"家族修复生效"。
- **S8**：REPAIR 风暴阈值（0 点前定死）：**`loop` 增量 > 3 或 repair-loop 增量 > 20/小时 或同一 (pid,pc) REPAIR > 8 次** ⇒ 立即上报 Lead 并暂停判读。

## 5. 0 点复核计划（task-6 第 2 步）

1. 回到**原始证据**逐条重算 task-5 的 `ARMED_WINDOW_2026-11-03.md`：`arm_log_merged.txt`（行级）、`watch.tsv`（10 min 序列）、`ne_events`（多行记录解析，断言 fetched == records）、`.stack` 清单。
2. 独立重取一次设备侧 `ne_events.tsv` 与 `repo log` 的尾部（只读、单快照），用于校验 task-5 的数字与"读数时刻"。
3. 对每一条报告结论给 **成立/部分/不成立/无法判定** + 反证或更正；汇总"必须回改"清单。
4. 异常按 §4 S8 阈值即时上报（不等 0 点）。

---

## 6. 结尾三栏

### [A] 已核实（E3，19:58 +0800）
1. 布防生效：`MODE dry=0 by=SIGUSR2`（epoch 1793706921 = 19:55:21）+ 连续 3 拍 `mode=armed`。
2. 三钥匙全缺：dry 已删、xrep 无、slotguard.arm 无、slotdrop 无；STAT `xrep=0 sd=0/0/0/0`。
3. **无覆盖空洞**：pid 11617 未变、starttime 未变（进程内 SIGUSR2 切换）。
4. **覆盖率 59/59 = 100%**（全量 /proc、字段精确、排除自身；"未跟踪用户进程 = 0"）。
5. 心跳 age ≈3.5 s；load/ctxt/processes 与布防前同量级；**REPAIR 行 0 条、loop=0、repair-loop 未增**（无风暴）。
6. arm 注记在位且含基线（segv 3 / passed 3 / repaired 0）。
7. 窗口 NE = 3（自然 2 + 观测者注入 1），其中 19:51:16 `ip` 为自然小地址 load 崩溃、无记录证据（校准样本）。

### [B] 未核实（原因）
1. 布防后是否发生 **REPAIR**（截至 19:58:40 = 0 条；0 点前持续无 ⇒ 属"窗内无自然家族命中"而非"修复无效"）。
2. vsurv4/vsurv5 canary 当前是否在跑（未在本次命令内查；0 点首查）。
3. 19:51:16 `ip` 崩溃的调用者（哪个脚本调用 `ip -o -4 addr show`）——需脚本级追踪。
4. 19:29:05 观测者注入事件在 armed 下的"如果"（不可回溯；只能作为口径警示）。

### [C] 必须上设备/等数据才能确认
1. 0 点：REPAIR/DREPAIR 是否存在、被修进程存活（R-11 表）与 §4 S2/S7 判读。
2. 0 点：`slotguard` 18:58 与 `ip` 19:51 两条自然崩溃是否复发（同 comm 是否再死）。
3. 更长窗（≥24 h）与对照臂：唯一能把「修复生效」升级为「崩溃减少」的证据（4 h 无对照窗做不到）。

---

## 7. 布防窗口复核（19:55:21 布防 → 23:28:49 回滚；task-6 第 2 步）

> 我的只读核对：**2026-11-03 23:31:06 / 23:32:34 +0800** 两次快照（命令见 `tmpfiles/review/skeptic/DEVICE_READ_AUDIT.md`）。本地复算脚本：`tmpfiles/review/skeptic/{analyze_arm_window,triage_independent,stat_instance_split,storm_timeline}.py`；输入 = 采集器 `arm_log_merged.txt`（**该文件随时间增长**，本文数字以 23:31 时点为准）。

### 7.1 三句结论
1. **回滚已生效且持久**：`MODE dry=1 by=SIGUSR2` = epoch 1793719729（23:28:49）；STAT **23:28:55 / 23:29:55 / 23:30:55 连续 3 拍 `mode=dry`**；`nerepair.dry` 在位，xrep/arm/slotdrop 三钥匙仍缺；pid 11740（starttime 2519 jiffies = 21:07 重启后实例）未被 USR2 重启 ⇒ 无新覆盖空洞。
2. **Lead 的窗口数字我逐项复现，且算术闭合**（§7.3）：SEGV 60 / PASS 47 / DREPAIR 22 / REPAIR 1 / NEAR 12 / WOULD_XREP 9 / XFORM 1 全一致；**修复分型 14/22 = 63.6% 弱门假修复**（Lead 报 64%，一致）。
3. **R-11 风险实质化（1 起闭环）**：唯一 1 次 path-1 REPAIR（slotguard 31797 @20:22:23）在 **41 min 21 s 后于同一 pc 0x101e7e8 再次 SEGV 并死亡** ⇒ 按预注册 F 判据「未再以家族形态死亡」**不成立**；但**不得据此宣称与布防有因果**（重启/风暴原因未定，见 §7.6）。

### 7.2 与 Lead 值的逐项对照（均为我的独立读数/复算）

| # | 项目 | Lead 值 | 我的独立值 | 判 |
|---|---|---|---|---|
| 1 | 回滚时刻与模式 | MODE dry=1 23:28:49；STAT 23:28:55 mode=dry | 同（epoch 1793719729）；19:56→23:27 连续 armed，23:28:55/23:29:55/23:30:55 三拍 dry | **成立** |
| 2 | 三钥匙 | dry 在位、其余缺 | dry **PRESENT**；xrep/slotguard.arm/slotdrop **ABSENT**；STAT `xrep=0 xw=2 xr=0` | **成立** |
| 3 | 窗口计数 | SEGV 60 / PASS 47 / DREPAIR 22 / REPAIR 1 / NEAR 12 / WOULD_XREP 9 / XFORM 1 | **完全相同**（epoch≥1793706921）；另：WOULD_REPAIR 141、WOULD_DREPAIR 6 **全为布防前**，窗口内新增 0 ⇒ armed 后不再产 WOULD_* 的机制自证 | **成立** |
| 4 | 重启 | ≈21:07:30；reboots.log 无记录；pstore 无新 ramoops | `btime=1793711250` ⇒ **21:07:30**（同秒）；reboots.log 末条 11-03 04:00:01；`/sys/fs/pstore/` 仅 03:57 的 `console-ramoops-0` | **成立** |
| 5 | NE 台账 | 窗内 40；21h 19 / 22h 6 / 23h 10 | **完全一致**（20h=5、21h=19、22h=6、23h=10）；21h 全落在 **21:00:28–21:06:00**（5.5 min ≈3.5/min） | **成立** |
| 6 | triage | 14/22 = 64% | **14/22 = 63.6%** 弱门假修复；family 8 = 36.4%（判据见 §7.4） | **成立** |
| 7 | 修复清单 | 23 条 | **REPAIR 1 + DREPAIR 22 = 23**，时刻/comm 逐一吻合；busybox 实为**同一秒 3 站 ×2 轮 = 6 行**，hostapd 7 行同一 pc 逐 8B 递进 | **成立（补细节）** |
| 8 | AP/服务健康 | 全活、ra0/rai0 up、有 station | ra0/rai0 **UP+LOWER_UP**（master br-lan）；`iw dev rai0 station dump` **2 台关联**（−75 / −56 dBm）；dnsmasq 1 / dropbear 2 / hostapd 2 / nerepair 1 / slotguard 1 / v3httpd 1；load 7.33 | **成立** |

### 7.3 窗口算术闭合（本次最有价值的一条：计数器 ↔ 日志行）

| 量 | 前段实例（pid 11617，末次 STAT 21:06:00） | 后段（pid 11740，23:26:55） | 合计 | 日志行 | 闭合 |
|---|---|---|---|---|---|
| segv | 35（含布防前基线 3） | 28 | 63−3 = **60** | **60** | ✓ |
| repaired（仅 path 1） | 1 | 0 | **1** | REPAIR **1** | ✓ |
| rep2（path 2） | 10 | 12 | **22** | DREPAIR **22** | ✓ |
| nearinsn | 4 | 8 | **12** | NEAR **12** | ✓ |
| xw | 7 | 2 | **9** | WOULD_XREP **9** | ✓ |
| xform | 1（第 3 槽） | 0 | **1** | XFORM **1** | ✓ |
| passed | 34 | 28 | **62** | PASS **47** + NEAR **12** = 59 | **差 3（≈5%）** |

**⇒ 三条要点**：① `STAT.repaired` **只统计 path-1 修复**；path-2 走 `rep2`、XREP 走 `xr` ⇒ **「REPAIR 行数 ↔ STAT.repaired 增量」必须拆成三条断言**（REPAIR↔Δrepaired、DREPAIR↔Δrep2、XREPAIR↔Δxr），否则会得到 23 vs 1 的**假不一致**（建议同步给 efficacy-reviewer 的 §E）。② PASS 类行约 5%（3/62）无法与计数器对齐，疑为合并日志缺行/边界 ⇒ **引用以 STAT 计数器为准**。③ 全窗 `suppressed=0`、`loop=0`、`abuse=0` ⇒ 限流未丢行；**熔断未被触发**——尽管 hostapd 1 秒 7 次，因为熔断键是 (pid,pc) 连续计数，**跨站点不累计**。

### 7.4 我的独立修复分型（与 Lead 的 64% 对齐）

判据（只读日志字段）：DREPAIR 记为「家族可信」当且仅当 **q2（或 q0）是完整 `{len∈[0x400,0x20000], ip 四段∈1..254}` 复合字**且被匹配字与 addr 差 ≤8；否则记 **弱门假修复**。

| 组 | 行数 | family | weak | 特征 |
|---|---|---|---|---|
| sh 14873 @20:12:48 | 2 | 0 | 2 | q2=0xa206/0xa210 = addr 本身，无复合 |
| ql_entry_auto_q 12765 @20:51:38 | 1 | 1 | 0 | q0=addr、q2=**0x1c28416e00000680**（len 1664 / ip **110.65.xx.28**，规范载荷同型） |
| basename 1404 @21:04:00 | 1 | 1 | 0 | q2=0x1365fe9b0000062d（len 1581 / ip **155.254.101.19**） |
| busybox 15949 @21:05:58 | 6（3 站×2 轮） | 2 | 4 | 0x4e7080 站命中规范载荷；0x4e82c8/0x4e7010 的 q2=0 ⇒ 弱；**同一秒 6 次 = 修复循环** |
| sh 28211 @23:00:33 | 1 | 0 | 1 | q2=0x11a4f=addr |
| ip 9250 @23:14:21 | 4 | 2 | 2 | addr 逐 +8（0x172f6→0x17310）；q2=0xd773247200000669（len 1641 / 114.36.115.215） |
| **hostapd 24917 @23:16:47** | 7 | 1 | **6** | **同一 pc 0x7fb6ad2ee4、addr 0x1422b→0x14258 逐 +8**；6 条 q0=**0xffffff80**（负数，非 A 字）、q2=自指下一地址 |
| **合计** | **22** | **8 (36.4%)** | **14 (63.6%)** | 与 Lead 的 14/22=64% 一致 |

> **IP 解码口径**：按**内存字节序 = 网络序**（与 C-167 更正后的口径一致）；本表早期草稿有两处把四段顺序写反，已按内存序修正（修正不影响 family/weak 分类——两种顺序都通过「四段 1..254」判据）。

**判读（只记事实）**：弱门（path 2 mode 0）在真实崩溃上接受的是「零包围小整数」而非规范记录 —— 这正是 SKEPTIC_REVIEW 附录 HIGH-1 的预言，**现已兑现 14 次**；hostapd/ip 两组呈「同一 pc + 地址逐 8B 前进 + q0 为负」＝遍历损坏结构，**不是家族记录**。

### 7.5 修后命运（R-11）：只保留能说明问题的样本

| pid / comm | 修复 | 之后 | 判读 |
|---|---|---|---|
| **31797 slotguard** | **REPAIR**（path1，20:22:23，fault=0x272a5，pc=0x101e7e8） | **21:03:44 同一 pc 再 SEGV**（addr=−0x28，`shape-fail` 后死亡）；存活 **41 min 21 s** | **R-11 实质化**：只推迟死亡、未修 bug；该 pc 在 18:58:11（pid 11618）亦曾以非家族形态崩过 ⇒ slotguard 自身缺陷 |
| 12765 ql_entry_auto_q | DREPAIR（20:51:38） | **同一 epoch 出现在 NE 台账**（sig=11） | **异常未解释**：同秒既记修复又记死亡；全窗 `suppressed=0` ⇒ 不能用限流丢行解释。弄清前**不得把「DREPAIR ⇒ 救活」当前提** |
| 24917 hostapd | DREPAIR ×7（23:16:47） | 23:21:52 仍 alive（1 拍）；23:32 见 hostapd 2 实例、AP 2 台关联 | 功能面未断，但**1 秒 7 次=循环式反复触发**；「救活」与「本来就活」不可分离 |
| sh/ip/awk/basename/busybox（一次性） | 14 | survival 多标 `gone_before_first_poll`/`died_later` | **不得当 R-11 证据**：这些工具天生活不过数秒，`died_later` 多为正常退出（解读必须分层） |

### 7.6 重启证据链（只列事实，不归因）

- `btime=1793711250` ⇒ **21:07:30 复位**；`reboots.log` 无该条（末条 04:00 计划）⇒ **非计划**。
- `/sys/fs/pstore/` 仅 **03:57** 的 `console-ramoops-0` ⇒ **无新 ramoops ⇒ 非 panic 路径**（与 C-175/C-183 的「无 Oops 的看门狗复位」同型）。
- **新发现（E3）**：NE 台账 **`1793711160 11617 nerepair sig=11`** —— 复位前 90 s **监督者自身崩溃**；此后到复位前**再无 SEGV/REPAIR 行**（检索为空），与「监督者已死、观测中断」一致 ⇒ **21:06:00–21:07:30 为盲区**。
- 风暴时序（21:00:28–21:07:28，NE 19 条）：awk/grep/ps/basename/ip/sh/busybox/slotguard + **`thermal_core` 21:07:16、`modprobe` 21:07:13、`logread`×2、`ps`×2**，且 `nerepair 11617` 21:06:00 崩 ⇒ **系统级不稳，非单一工具现象**。
- **时间轴陷阱（新）**：后段实例 `START pid=11740 ver=2.2 **dry=0**` 记在 **epoch 1793649436 = 假钟 03:57:16**（重启后 NTP 未同步）⇒ 按 epoch 过滤会**漏掉该实例边界**；分段必须用文件顺序（与 efficacy §2.4 同结论）。

### 7.7 NE 小时分布与混杂

| 小时 | 我的计数 | 当日早前基线（Lead） | 判读 |
|---|---|---|---|
| 20:00 | 5 | — | 布防后 25 min 内 5 起 |
| **21:00** | **19** | 15h=6 / 16h=8 / 17h=1 / 18h=1 / 19h=2 | **≈3.5/min，为基线 1–8/h 的 30–100 倍**；但与重启/风暴同期，**不可分离** |
| 22:00 | 6 | — | 回落，仍高于 17–19h 基线 |
| 23:00 | 10 | — | **二次抬升**，与 hostapd/ip 修复群（23:14–23:16）同期 |

**混杂（必须与数字同读）**：① 23:32 实测 **rai0 有 2 台 station 关联** ⇒ 后段是 C-204 的**客户端热态**（13.9–20.3/min），不是「无客户端 0.60/min」——**写者率本身被流量抬高**；② 全窗 **无对照臂、无 canary、无预注册**；③ 观测者自产事件（采集器每 10 min + 我的 2 次快照）未逐条剔除；④ 修复使部分家族崩溃不入 NE 台账 ⇒ **NE 计数既不是写者活动、也不是崩溃总量**。⇒ **「布防导致 NE 升高/降低」的任何表述都不成立**（与 S1 一致）。

### 7.8 若再布防，必须先做什么（预注册）

**A. 形状门 v2.3（先改代码）**
1. **path 2（ext=0）必须调用 `shape_ok`**：14/22 假修复全部来自 mode 0 的「零包围小整数」门；等价改法=要求 `{len,ip}` 复合 + 四段单播 + `w3==0`。
2. **(pid,pc) 熔断加时间窗**：同一 pc 60 s 内 ≥2 次即拒（本次 busybox 1 s 6 次、hostapd 1 s 7 次、ip 1 s 4 次；现有熔断按「连续计数」，**跨站点不累计** ⇒ `loop=0` 是假阴性）。
3. **递增地址哨兵**：连续修复的 addr 以 +8 递进 ⇒ 判「遍历损坏结构」，拒绝并记 `REVIEW`。
4. **长驻进程二次确认**：hostapd/dnsmasq/dropbear/v3httpd 的修复需满足「200 ms 内同 (pid,pc) 不再触发」，否则撤回（改 PASS 让其死）。
5. **修复后置校验**：记录 (pid, starttime, pc, addr)，200 ms 后复查该 pid；不活 ⇒ 记 `REPAIR_INEFFECTIVE`。

**B. 回滚条件（若预注册，本应在 23:16 触发）**：任一 (pid,pc) 60 s 内 ≥3 次；或同一长驻进程 ≥2 次；或自动 triage 的 `REVIEW/repairs > 10%`（分母 ≥10）；或 NE 率 > 基线 3 倍并持续 30 min；或心跳断流/非计划重启；或**监督者自身进 NE 台账**。⇒ 实际值：REVIEW 63.6%、hostapd 7 次、监督者自崩 1 次 —— **三条同时命中**，回滚正确但**触发过晚（21:06 就该停）**。

**C. 观测前置（缺一不布防）**：① 窗口前记录客户端关联数（本次 2 台 ⇒ hot）、loadavg、内存/页池、boot_id、TRY_A；② 三条闭合断言分开写（§7.3①），PASS 缺行 ≤5% 必须报；③ **自动 triage 每 30 min 跑一次**（判据=§7.4），weak 比例超阈值即报警；④ 观测者剔除按 §4 S2 父链规则逐条执行，窗口内不用 busybox applet 长管道取证；⑤ **不要指望 kmsg 提供 writer PC**（ptrace 在场时 `unhandled fault` 结构性缺席，`03_PROBES.md:164-166`）；⑥ **把「监督者自身也是受害者」写成设计前置**（§7.10，E4）：本窗监督者在风暴中**先于所有被监护者死亡**（21:06:00，栈上有 3 条规范记录、其中 w0 恰为 far），且**无人修它** ⇒ 再布防前必须：由独立 watchdog 在 30 s 内重启并**把「监督者进 NE 台账」当最高优先级事件**（不是普通回滚条件）；窗口内实时监控 `comm=nerepair` 是否进 NE 台账；把「监督者死亡期间的观测盲区」写进暴露口径（本次 ≈90 s）。。

### 7.9 本节新增的三栏

**[A] 已核实**：回滚持久（3 拍 dry + marker 在位）；窗口计数与 Lead 全项一致且 STAT↔日志闭合；弱门假修复 14/22=63.6%；hostapd/ip/busybox 三组「同 pc 连发 + 地址递进」；slotguard 修复后 41 min 同 pc 死亡；重启 btime=21:07:30、无 ramoops、reboots.log 无记录 ⇒ 非 panic 非计划；监督者 21:06:00 自崩；AP/服务健康（2 station、6 类守护在）。
**[B] 未核实**：① 重启根因（只能排除 panic 与计划重启）；② 21:06–21:07:30 盲区事件（监督者已死）；③ ql 12765「同秒修复+死亡」机制；④ 21:00 尖峰与布防/修复的关系（无对照臂 ⇒ **不可归因**）；⑤ 客户端何时关联（决定 hot/cold 分段）。
**[C] 必须上设备/受控实验**：形状门 v2.3 回归（含 14 例负样本）；熔断时间窗与递增地址哨兵的 device 验证；下一次布防必须在**同 boot、同流量档、带自动 triage 与预注册回滚线**下进行——本次 4 h 窗缺这三样，**不能作为效力证据**。

---

### 7.10 监督者自身死亡：家族记录写进**守卫的栈**（Lead 补充 + 我的独立复核）

| 项 | 值 | 判/来源 |
|---|---|---|
| NE 行 | `1793711160 11617 nerepair sig=11 far=0x28f80 pc=0x101f59c stack=…/1793699132-11617-1793711160.stack` | 设备 ne_events（我 23:31 只读） |
| `.stack` 头（我自己解析） | magic `SDMPv1`、**pid=11617**、stack=[0x7ff0dbe000, 0x7ff0dce000)、npages=16、**ts=1793711160**、bitmap=0xffff | 与 NE 行**同 pid 同秒**、范围自洽 ⇒ E3 |
| **我的独立扫描**（strict V-A：len 0x100..0x10000 + 四段单播 + q0>0） | **3 条 A0B2**：VA 0x7ff0dcc060 w0=0x25c7a；**VA 0x7ff0dccb60 w0=0x28f80（== far）**；**VA 0x7ff0dccda0 w0=0x28f88（== far+8）**；三条 q2 均 =0x1365fe9b0000062d（len 1581 / ip 155.254.101.19） | 我自写 `tmpfiles/review/skeptic/verify_supervisor_stack.py`；与 Lead 的 hexdump 复原**一致** |
| V-B 宽松口径（q0 可 0、len 0x40..0x20000） | 另 +2 条（w0=0，VA 0x7ff0dccdf0 / 0x7ff0dccf60） | 用于口径敏感性说明，不改变结论 |
| **指令反解（零设备访问）** | `gw/bin/nerepair`（md5 811b3e19…）R+X 段 vaddr 0x10123c0；pc 0x101f59c → 文件偏移 **0xf59c** → 指令 **0xb9800108 = LDRSW x8,[x8,#imm]，rt=8 rn=8 ⇒ 自指 load**；`is_ldr_same` 判为 LDRSW；相邻 `[+1] 0x17ffff8a` 为回跳分支（循环内） | 我自写 `decode_supervisor_pc.py`；这一步**补上了设备日志缺的那条证据** |

**判级：E4（形态+现场）**——写者把规范 32B 记录写进**监督者自己的栈**，监督者以记录 w0 为地址做自指加载 ⇒ SIGSEGV ⇒ 死；且**无人能修它**（它不 trace 自己）。

**必须随结论引用的四点限制**：
1. 该崩溃的 `insn` **不在设备日志里**（监督者已死，`nerepair.log` 无该 SEGV 行）——「LDR 自指」是**用本地二进制反解 pc** 得到的（E3，但属离线反解，不是设备现场字段）；
2. 不能 100% 排除「另一指针值恰等于记录字」；但同一栈上同时存在 `w0=far` 与 `w0=far+8`（±8 正是 `shape_ok` 容差）两份记录，巧合概率极低；
3. 我手上的 `.stack` 副本 **65,584 B，比规范 65,592 B 少 8 B**（尾部缺失；命中都在 0xe060–0xef60，不受影响）——**存档件完整性需修**；
4. `0xb9800108` 与 slotguard 18:58:11 崩溃（pc=0x101e7e8）**同一指令编码**、且二者都是 musl 静态二进制 ⇒ 与「写入普遍、崩溃只看落点」（C-173）一致，**不**说明某个特定二进制特殊。

**制度性后果（不是归因）**：① 监督者先死 ⇒ 21:06:00–21:07:30 **无任何 SEGV/REPAIR 记录**（我的检索为空）= 观测盲区；② 现行设计里**没有「监督者自身也是受害者」这一条**——它在家族写入面前与被监护者同样脆弱，且**没有任何进程修它**；③ 再布防前必须把「监督者进 NE 台账」从**回滚条件**提升为**设计前置**（见 §7.8 第 6 条）。
