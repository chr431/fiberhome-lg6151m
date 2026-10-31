# 服务中断测量规范（SVC MEASUREMENT）v1.0 · 2026-11-01

> 本文是 RELIABILITY_SPEC **M3（R3.1–R3.7）** 的定义落地文档：把"服务中断 <5s 的次数
> <5 次/天"这类听起来没法测的指标，变成**可测量、可归因、可复核**的量。
> 判据优先级沿用验收合同：**实测证据 > 设计文档 > 口头结论**。
> 任何与本文件不符的统计口径，一律以本文件为准；改口径必须同时改本文件与采样器实现。

---

## 1. 定义（R3.1）

**服务中断（service outage）**：对某条接入路径上的某个**服务探针**，
连续 **≥2 次采样失败**即为一次中断；**时长 = 首次失败采样时刻 → 首次成功采样时刻**。

- 采样节拍：主探针 **1s**（icmp / dns / tcp80）。连续 2 次失败 ⇒ **最小可判中断 ≈2s**。
- 去抖理由：单次丢包/单次 RST 是常态噪声（WiFi 重传、ARP 老化、conntrack 抖动），
  2 连败才代表"客户端确实用不了"。1 连败只进原始样本，不进台账。
- 时长语义是"**首败到首成**"，因此台账时长天然包含 1 个采样周期的量化误差
  （真实中断 d 秒，测得值落在 [d, d+1) 内）。这个误差写在台账里，不隐藏。

### 1.1 探针与判据

| 探针 | 客户端实现 | 设备侧实现（fast_facts probe_id） | 证明什么 |
|---|---|---|---|
| `icmp` | raw ICMP echo → 网关（绑定 LAN 源地址） | `net.brlan` / `wan.icmp` | **路径可达性**（L2/L3 通不通） |
| `dns`  | UDP DNS 查询 192.168.9.1:53，**任何应答**（含 NXDOMAIN/SERVFAIL）算成功 | `gw.dns` | 网关解析器（dnsmasq）是否在服务 |
| `tcp80`| TCP connect 192.168.9.1:80 | `gw.tcp80` | GUI（v3httpd）是否受理连接 |
| `tcp22`| TCP connect + 读 SSH banner | `gw.tcp22`（监听位） | 管理面（dropbear）是否可登录 |

**"任何应答算成功"是刻意的**：DNS 探针测的是 *dnsmasq 活着*，不是 *上游通*。
上游断网时 dnsmasq 仍会回 SERVFAIL/NXDOMAIN，此时 LAN 服务没坏，不该记成固件中断
（见 §5 上游排除）。

### 1.2 为什么 tcp22 是 60s 而不是 1s（诚实的例外）

1s 一次的 SSH 连接会在设备上**每秒 fork 一个 dropbear 子进程并写两条 authpriv 日志**
（`Child connection from …` / `Exit …`）。按设备 syslog 4MB≈2 天 的预算，这会让探针
自己变成一次日志洪水，并且污染 M1 事故台账的输入源。因此：

- `tcp22` 节拍 **60s**，**最小可判中断 = 2×60s = 120s**，在台账里照样记录，
  但它**不参与 R3 验收三档计数**（只作诊断与归因）。这一点写在台账 `flags` 列
  （`cadence=60`）与报告里，不允许悄悄按 1s 口径统计。
- 主探针 `icmp/dns/tcp80` 全部 1s，参与验收计数。

### 1.3 一条中断 = 一条记录；一个"事件"= 合并

- **台账行**：以 `(path, probe)` 为单位，一次中断一行。
- **验收计数单位**：同一路径上**重叠或间隔 <2s** 的多探针中断合并为**一个事件**
  （`probe` 列写成 `icmp,dns,tcp80` 这样的集合）。理由：整机失联时三个探针会同时失败，
  不合并会把一次事故数成三次，把指标做成"必然超标"的假红。

### 1.4 三档与分级（与 RELIABILITY_SPEC R1.2 对齐）

| 档位 | 时长 | severity | 合同阈值 |
|---|---|---|---|
| `lt5` | < 5s | SEV3 | **< 5 次/天** |
| `5to20` | 5s ≤ d ≤ 20s | SEV2 | **< 1 次/天** |
| `gt20` | > 20s | SEV1 | **< 1 次/7天** |

边界取闭区间向左：正好 5s 记 `5to20`，正好 20s 记 `5to20`，>20s 才是 SEV1。

---

## 2. 双端测量与验收口径（R3.2）

| | 客户端侧（PC） | 设备侧 |
|---|---|---|
| 实现 | `tools/svc_probe.py` | `gw/svc_outage.sh`（消费 `fast_facts.tsv`） |
| 节拍 | 1s（tcp22 60s） | 由 state-truth 的 `gw/fast_watch.sh` 1s 产生 |
| 证据 | `_local/evidence/svc_probe/`（不入公开仓） | `/data/gw/logs/svc_outages.tsv` |
| 路径维度 | **有**（eth / wifi / rndis，按源地址区分） | **无**（同桥，见下） |
| 角色 | **验收口径** | **归因证据** |

**设备侧为什么没有路径维度**（state-truth 实测）：`br-lan` 的成员是 `eth1 ra0 rai0 rndis0`，
三条接入路径在设备内部就是**同一个网桥**，设备对"网关自己"的探测不存在路径差异。
所以按路径的验收数字只能来自客户端侧——这正是合同把客户端定为验收口径的原因。

**双端一致性的用法**：客户端报"中断 5s"，设备侧同时刻 `gw.tcp80` 也为 0 ⇒ 归因到
v3httpd；设备侧全绿而客户端红 ⇒ 问题在路径/客户端侧，不是网关服务（这条规则能抓
"设备自评健康但客户端不可用"的假绿，是 M3 存在的意义）。

---

## 3. 台账格式（R3.3）

### 3.1 中断台账 `svc_outages.tsv`（设备侧 `/data/gw/logs/`，客户端侧 `_local/evidence/svc_probe/`）

TAB 分隔，首行 `#` 注释头，append-only：

| # | 列 | 说明 |
|---|---|---|
| 1 | `start` | 首败 epoch（秒） |
| 2 | `end` | 首成 epoch（秒） |
| 3 | `dur` | 时长（秒，= end - start） |
| 4 | `path` | 客户端 `eth`/`wifi`/`rndis`；设备侧恒 `gw` |
| 5 | `probe` | `icmp`/`dns`/`tcp80`/`tcp22`，合并事件用逗号连接 |
| 6 | `severity` | SEV1/SEV2/SEV3（§1.4） |
| 7 | `attrib` | 归因组件（§6）；未知就是 `unknown` |
| 8 | `excluded` | 1=不计入验收 |
| 9 | `excl_reason` | `drill` / `planned_reboot` / `upstream` |
| 10 | `evidence` | 证据链引用（`ne:行@ts` / `edges:id@ts` / `drills:…` / `probe:tcp80`） |
| 11 | `side` | `client` / `dev` |
| 12 | `flags` | `preliminary=1`（数据源是 2s 边缘而非 1s 事实流）/ `gap=1`（采样缺口收尾）/ `cadence=60` |

### 3.2 日聚合 `svc_daily.tsv`

`date path lt5 n5_20 n20 total excluded preliminary`
—— **excluded 单列**，`lt5+n5_20+n20` 只统计未排除项。

### 3.3 客户端原始样本 `samples-YYYYMMDD.tsv`

`epoch_ms path src icmp_ok icmp_ms dns_ok dns_ms tcp80_ok tcp80_ms tcp22_ok tcp22_ms note`
`-1` = 该拍未采（例如 tcp22 非采样拍），**不等于失败**，派生时跳过。

---

## 4. 诚实性规则（比数字重要）

1. **缺口不是"没有中断"**：`run.tsv` 记录 `start/stop/gap`，报告输出 `coverage` 百分比。
   覆盖率低时，三档计数只代表"测到的时段"，报告必须同时给出覆盖率，禁止用 0 次冒充绿。
2. **preliminary 必须标注**：`fast_facts.tsv` 上线前，设备侧只能从 2s 边缘
   （`avail_edges.tsv`，4s 磁滞）派生，这类行一律 `preliminary=1`，**不进验收计数**。
3. **演练必须可排除且可审计**：`/data/gw/logs/drills.tsv` 是唯一权威标记文件
   （Lead 裁决 v1.2）。落在演练窗内的一律 `excluded=1/excl_reason=drill`，
   报告单列"已排除的演练窗口"，让甲方看到排除不是黑箱。
4. **观测点自检**：探测器启动前必须过 `selftest`（代理/TUN 污染、LAN 源地址、四探针
   各做一次真实往返）。自检不过就**拒绝测量**——被污染的探针会自信地报假数。
5. **时钟对齐**：客户端每 5min 记一条 `anchors.tsv`（本地 epoch + 设备 epoch + RTT），
   跨机时间轴关联只允许用锚点换算，禁止心算 epoch。

---

## 5. 排除规则（R3.4）

| 规则 | 判据 | 结果 |
|---|---|---|
| **演练** | 与 `drills.tsv` 的 `[start_epoch, end_epoch]` 重叠（`end_epoch=0` 视为仍在进行，右端按"现在"处理） | `excluded=1 / drill` |
| **计划重启** | 落在 boot 窗（本 boot 起点 ±300s）且 `reboots.log` 当日有 `REBOOT` 行 | `excluded=1 / planned_reboot` |
| **非计划重启** | 落在 boot 窗但当日无计划行 | `excluded=0`，`attrib=reboot`（**要计数**：这是固件/硬件缺陷） |
| **上游供应商断网** | 仅 dns 失败且设备侧 WAN 同时不可用（`wan.alive`/`wan.icmp`） | `excluded=1 / upstream` |

注意：客户端 `icmp→网关` 探针**天然免疫**上游断网（网关就是设备本身），所以上游规则
只可能作用在 `dns` 这类"转发型"探针上。

---

## 6. 归因（R3.5）

每条 **>5s** 的中断必须落到一个组件；**未知也要写 `unknown`**，不许留空。

| 探针 | 首要组件 | 旁证来源（按优先级） |
|---|---|---|
| `tcp80` | `sys.gui/v3httpd` | `ne_events.tsv` 中 v3httpd 的 NE 行 → `avail_edges` 的 `gui edge_down` → 否则 `probe:tcp80` |
| `dns` | `lan.bridge/dnsmasq` | NE(dnsmasq) → `avail_edges` `dns.pids` |
| `tcp22` | `sys.ssh/dropbear` | NE(dropbear) → `avail_edges` `ssh.banner` |
| `icmp` | `lan.path`（br-lan/成员口） | `avail_edges` `br.up`；全探针同时红 ⇒ 整机/内核/重启 |

证据列写成 `ne:行号@ts` / `edges:id@ts` / `probe:tcp80`，任何人都能回到原始文件复核。
无旁证但探针本身足以证明服务未受理时（TCP:80 拒连），记 `probe:<name>`——这是**探针级证据**，
不是猜测；真正的 `unknown` 只留给"探针红了但看不出是谁的锅"。

---

## 7. 验收计数与判定（R3.7）

`python tools/svc_probe.py report --days N --json`（T4 报告聚合调用此接口）：

- 输入：客户端样本（验收口径）+ 设备侧证据（排除/归因）+ `drills.tsv`。
- 输出：三档 `count`、按天速率 `rate = count / (N / per_days)`、`PASS/FAIL`、
  覆盖率、逐条 incident（含 excluded 与证据链）、`drills.windows`（可审计的排除清单）。
- 判定：`rate < limit` 为 PASS（严格小于；等于阈值算 FAIL）。
- 退出码：全绿 0，否则 1（可进 CI/soak 告警）。

---

## 8. 复现命令

```sh
# 客户端（PC，验收口径）
cd lg6151m-public
python tools/svc_probe.py selftest                  # 观测点自检（必过）
python tools/svc_probe.py run                        # 1s 长跑（无人值守）
python tools/svc_probe.py derive                     # 由样本重建 outages.tsv
python tools/svc_probe.py report --days 7 --pull     # 拉设备证据 + 出验收报告
python tools/svc_probe.py report --days 7 --json     # 机器可读（给 T4）

# 设备侧（消费 fast_facts，不采样）
sh /data/gw/svc_outage.sh tick      # 增量（由 fast_watch 每 N 拍调用）
sh /data/gw/svc_outage.sh derive    # 全量重建
sh /data/gw/svc_outage.sh daily     # 日聚合
sh /data/gw/svc_outage.sh status    # 自检：源/游标/行数/最近一条
```

**自测**（D2：工具必须能自证）：
`SVC_LOG_DIR=<tmp>/logs SVC_RUN_DIR=<tmp>/run sh gw/svc_outage.sh derive`
喂一份人造 `fast_facts.tsv`（含 5s 中断、25s 中断、缺口、演练窗）即可离线验证
去抖/分档/排除/归因四条逻辑，无需碰设备。

---

## 9. 已知限制（写清楚，别装作没有）

1. **1s 采样有量化误差**：测得时长 ∈ [真实, 真实+1s)。2s 的去抖下限意味着
   **1s 级瞬断不可判**，这类问题归 avail_watch（2s 边缘）与 NE 台账，不归本指标。
2. **设备侧无路径维度**（同桥），路径维度只存在于客户端侧。
3. **tcp22 60s 节拍**：SSH 类中断的最小可判时长是 120s，不参与验收三档。
4. **客户端探测器是单点**：PC 睡眠/断网/代理变更都会造成测量缺口，缺口记在
   `run.tsv` 并在报告 `coverage` 里体现，**不得**当作"零中断"。
5. **`http200` 深度探针不在本指标内**：GUI 能连但返回 500 属于"降级"，由 watchdog 的
   30s `http200` 与 M2 状态总线负责；本指标只判"客户端能不能用上"。

---

## 10. 已修复根因（R3.6）

### 10.1 「重启预算耗尽 → 放弃重启」把秒级崩溃放大成分钟级中断

**症状**：服务被 NE（SIGSEGV）或人为 kill 打死一次，正常应 ≤2 个 watchdog 周期恢复；
实际观察到大段"服务已死但账面上没有事件"的窗口。

**证据**（设备 `/tmp/watchdog.log`，2026-10-31 当 boot，共 717 行）：

| 时刻 | 行内容 |
|---|---|
| 22:28:27 / 22:29:46 / 22:31:06 | `EVT restart authd` ×3（2m39s 内用光 3 次/1h 预算） |
| 22:32:26 → 22:46:18 | `WARN authd restart budget exhausted (3/h) — alert only` ×11（每 80s 一行） |
| 23:17:31 | `EVT restart authd (recipe=[/data/gw/authd eth0])` ← 直到预算窗滚过才恢复 |
| 23:11:43 / 23:13:02 | 同型再犯一次（~6 分钟后 23:17:31 恢复） |

即：**authd 实际中断 ≈14 分钟**，而根因只是三次瞬时崩溃。同一 boot 内
`budget exhausted` 共 16 行。

**机制**：`gw/svc_lib.sh` 的 `rl_ok()` 原实现 = 3 次/滚动 1h，用光后 `return 1`，
watchdog 的 `svc_supervise` 走 "alert only" 分支 —— **永久放弃，直到窗口滚过**。
`v3httpd` / `dnsmasq` / `hostapd` 走同一条代码路径，一旦命中就是
>20s 的 SEV1 客户端中断（直接违反 §1.4 的 gt20 档）。

**修复**（svc_lib v1.8，只改 `rl_ok()`，不动 SVC_TABLE）：
预算耗尽后**降级为慢重试**（`RL_SLOW` 默认 60s/次），

- 恢复上界有界（回到 R4.1 要求的 ≤60s 量级），不再是"等窗口滚过"；
- 仍防重启风暴：1 次/分钟 ≪ watchdog 30s 节拍；
- **永不静默停止**：连续慢重试 ≥10 次落一行 `WARN … slow-retry x10` 告警但继续重试
  （静默停止 = 账面上"无事件"的又一种假绿）；
- `.rec` 升级为 4 字段（n / 窗口起点 / 上次尝试 / 慢重试计数），**旧 2 字段文件自动兼容**。

**单测**（14 条，离线可跑，无需设备）：

```sh
cd lg6151m-public
log() { echo "[log] $*"; }; . ./gw/svc_lib.sh
rm -f /tmp/watchdog_svc_t.rec
RL_NOW=1000 rl_ok t; RL_NOW=1000 rl_ok t; RL_NOW=1000 rl_ok t   # 3 次快重启
RL_NOW=1000 rl_ok t; echo "4th=$?"        # 期望 1（限流）
RL_NOW=1060 rl_ok t; echo "slow1=$?"      # 期望 0（慢重试）
RL_NOW=1090 rl_ok t; echo "too_soon=$?"   # 期望 1
```

完整 14 条覆盖：快预算、慢重试限流、永不静默停止（第 11 次仍返回 0）、
小时窗滚动恢复、旧 2 字段 `.rec` 兼容、`rl_refund` 与新格式共存。

### 10.2 演练记录

> 演练契约：Lead 裁决 v1.2 —— 演练必须在 `/data/gw/logs/drills.tsv` 留痕，
> 脚本 `_local/evidence/svc_probe/drill_rlok.sh`（两臂同一脚本、同一判定口径）。
> 方法：把 `/tmp/watchdog_svc_v3httpd.rec` 预置成"预算已耗尽"态（等价于 3 次快速
> 重启用光，但只需 1 次 kill，人为中断更少），然后 `kill -9 v3httpd`，每 10s 轮询恢复。

**补充证据（有机，非受控）**：§10.1 的 authd 时间线本身就是"修复前"的真实样本 ——
服务在 22:31:06 第三次重启后彻底停摆，直到 23:17:31 预算窗滚过才恢复（**14 分钟**），
期间 watchdog 每 80s 记一行 `budget exhausted — alert only` 但**没有任何重启动作**。
这条证据的强度低于受控对照（无法排除其它因素），但它是**真实发生的生产故障**，
不是构造出来的。

（受控前后对照结果在演练执行后回填下表。）

| 臂 | 设备 svc_lib | 判定口径 | 恢复时延 | 结论 |
|---|---|---|---|---|
| **before**（受控·单变量） | 只把 rl_ok 回退 v1.7（SVC_TABLE=fast_watch 与 alive() 新判据**保持不变**） | 同一脚本 drill_rlok.sh | **150s 内未恢复**（recovered=0）；watchdog 记 `v3httpd restart budget exhausted (3/h) — alert only` | 秒级崩溃 → 永久放弃 |
| **after**（受控） | v1.10 全量 | 同一脚本 drill_rlok.sh | **70s 恢复** | 恢复有界，慢重试每 60s |
| 有机旁证（生产） | v1.7 | — | authd 崩溃后 **14 分钟**无重启 | 真实故障，非构造 |

**执行记录**（2026-11-01 02:05–02:09，持锁，drills.tsv 留痕 `drill-manual v3httpd svc-probe rl_ok-before-arm`）：

1. 备份 `/data/gw/svc_lib.sh → .v110`；换成**单变量**文件（只把 rl_ok 换回 v1.7，
   SVC_TABLE 仍是 fast_watch、alive() 仍是 argv 精确匹配）；
2. **重启 watchdog** 使其生效（运行中的 watchdog 不重读 svc_lib —— 本项目架构事实）；
3. 跑**同一个** drill_rlok.sh：kill v3httpd → **150s 未恢复**；
   watchdog.log 02:08:25 出现 `WARN v3httpd unhealthy (pid=none :80=n)` 与
   `WARN v3httpd restart budget exhausted (3/h) — alert only` —— 机制复现；
4. 恢复 v1.10 + 重启 watchdog + 拉起 v3httpd，复核 `slowretry=1 / fastwatch=2 / alive_exact=1`
   且 v3httpd pid 在（15517）、watchdog healthy=y；
5. 客户端台账同时记到一条 **164s SEV1 tcp80** 中断（落在演练窗内，`excluded=drill`）。

**为什么这次要重做**：01:37 那次标着 "before" 的执行，实际测的是**修复后**行为 ——
运行中的 watchdog 已被 state-truth 重启并加载了新版 svc_lib（其 M2 部署需要重读 SVC_TABLE），
所以那 70s 是 after 数据。重做时把变量收敛到**只有 rl_ok**，对照才成立。

---

## 11. 验收计数快照（2026-11-01 02:12，24h 窗口）

命令：`python tools/svc_probe.py report --days 1 --pull`（客户端为验收口径）

| 项 | 值 |
|---|---|
| 窗口 | 24h（2026-10-31 02:12 → 2026-11-01 02:12） |
| 覆盖率 | **9.42%**（8139s / 86400s，探测器 2026-10-31 23:55 起跑） |
| lt5（<5s） | **0** → PASS（阈值 <5/天） |
| 5to20（5–20s） | **0** → PASS（阈值 <1/天） |
| gt20（>20s） | **0** → PASS（阈值 <1/7天） |
| 设备侧台账 | 8 条中断（与客户端交叉核对用） |

8 条客户端中断全部 `excluded=1`，逐条可追溯到 `drills.tsv` 的真实窗口：

| 时刻 | 时长 | 探针 | 排除理由 |
|---|---|---|---|
| 23:56:02 | 5.0s | tcp80 | svc-probe 自身探测器可信性演练（事后补标记） |
| 01:04:37 | 56s | dns,tcp80 | state-truth R2.7 演练 |
| 01:06:02 | 94s | dns,tcp80 | state-truth R2.7 演练 |
| 01:08:41 | 92s | tcp80 | state-truth R2.7 演练 |
| 01:37:17 | 72s | tcp80 | svc-probe rl_ok 修复后臂 |
| 01:53:51 | 60s | dns,tcp80 | soak-qa R4.4 注入（K16 v3httpd） |
| 02:04:57 | 7.2s | dns,icmp,tcp80 | cfg-heal D1/D4 演练（整路径瞬断） |
| 02:05:54 | 164s | tcp80 | svc-probe rl_ok 修复前臂 |

### 11.1 这个快照**不能**说明什么（必须先读）

1. **覆盖率 9.42%**：本窗口内只有约 2.3 小时被真正测量。三档 PASS 只描述"被测到的那段时间"，
   **不是** 7d/30d 验收结论。任何把这份快照当成"满足指标"的说法都是造假。
2. **只有 eth 一条路径**：PC 的 WLAN 接的是别的网络、无 RNDIS 连接，wifi/rndis 路径
   **未实测**（不是"代码支持所以应该没问题"）。
3. **本窗口内没有任何一条"固件自发的客户端中断"被观测到**——8 条全部是演练/注入造成的。
   这既说明演练排除规则在工作，也说明**样本量不足以证明固件稳定**：一个没抓到有机故障的窗口，
   不等于"没有有机故障"。
4. 设备侧与客户端数值不一致时以客户端为准（§5.2 的 eth0-down 伪影）。


---

## 12. 一次真实整路径中断的完整记录（2026-11-01 02:55，非计划重启）

这是 M3 装置交付以来**第一次捕获到真实的、非演练计划的整路径中断**，也是它存在意义的实证。

| 项 | 值 |
|---|---|
| 中断区间（客户端 1s 采样） | **02:55:15 → 02:56:55，dur = 99.4s** |
| 探针 | icmp + dns + tcp80 **同时失败**（= 整条 LAN 路径中断，不是单个服务） |
| severity / 档位 | SEV1 / gt20 |
| excluded | **0**（要计数 —— 这是真实中断） |
| attrib | **reboot(unplanned)** |
| 证据链 | `boot_attempts:btime=1793472921 epoch=1793472948 result=healthy` |
| 设备侧 | uptime 归零、bootslot=a、mtk_wed 由开机脚本重载；reboots.log **无** 02:55 记录（= 非计划） |

**成因**：这是**我们自己的实验**（crash-root 的 `rmmod mtk_wed`）把设备带崩后自动重启，不是固件自发故障。
在验收计数里两者必须分开呈现：本次 gt20 = 1 次，全部归因于实验致崩溃重启。

**客户端侧同时暴露的观测限制**：设备重启后 PC 的 DHCP 租约丢失，回落到 APIPA `169.254.162.221`，
此后 raw ICMP 绑定源地址失败（`WinError 10049`），探针从「设备不可达」退化为「本机无有效源地址」。
这类样本必须与「设备不可达」区分，否则会把客户端自身故障算成设备中断。

**这次事件同时暴露了一个设备侧依赖**：`/data/gw/fast_watch.sh` 在重启后因 busybox ash 把 `08`/`09`
当前导零八进制解析失败而周期性退出（`line 108: arithmetic syntax error`），导致
`svc_outage.sh tick` 的调用点（fast_watch 第 652 行）在大部分时间里没有执行 —— 设备侧台账在该时段
**没有被驱动**。这是「M3 设备侧数据依赖 M2 高频循环」的结构性风险；修法在 M2（state-truth），
M3 侧已确认脚本本身独立可用（同一命令手动执行 rc=0、游标正常推进、二次运行幂等）。

### 12.1 探测器自身的降级（同一次事件暴露）

设备崩溃重启后 PC 的 DHCP 租约丢失，raw ICMP socket 连续失败被回收；**旧实现把 socket 置空后再也不重建**，
导致 03:0x 起连续 **1635 拍（约 27 分钟）没有 icmp 采样**（`icmp=-1 / no_raw_socket`），
而 dns/tcp80 仍正常 —— 即「路径可达性」这一维在那段时间是盲的。

已修（svc_probe v1.5）：处于 None 态时每 10 拍重试重建 socket。教训写在这里：
**探测器必须有"自愈"路径，并且降级必须在样本里可见（`-1` 不是 0）** —— 把 `-1` 记成 0 会把
「我没测」伪装成「设备挂了」，把 `-1` 丢掉又会把「我没测」伪装成「一切正常」。
