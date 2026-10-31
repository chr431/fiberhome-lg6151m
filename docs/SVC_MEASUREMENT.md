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

（结果在演练执行后回填本节。）

