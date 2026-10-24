# 模块可用性评定系统设计（GitHub-status 式）v1，2026-10-25

> 目标：对固件各功能模块做持续可用性评定——持久化留存、GUI 可视化
> （90 天状态条 + 事件时间线），形态对标 GitHub Status。
> 本文是设计稿（未实施）；判据全部复用现有监督面，**不发明第二套判据**
> （L28"观察者必须同源"原则的制度化落地）。

## 0. 现有判据资产盘点（全部已实测核实）

| 资产 | 形状 | 语义（已核实） | 角色 |
|---|---|---|---|
| `/tmp/watchdog_state` | ~30 个 `key=0/1` 键值 | **0=正常 1=故障**（set_state rc 惯例）；只在**迁移时**改写=最近判决快照 | 当前状态横幅的原始源 |
| `/tmp/watchdog.log` FAIL/OK 行 | `MM-DD HH:MM:SS FAIL/OK <label>` | 每次判决迁移一行（boot 即失） | 细粒度事件因果 |
| `syslog.log`（watchdog tag） | WARN/EVT 行持久镜像 | EVT restart / NE +1 census / channel drift | 事件持久层 |
| `SVC_TABLE`（svc_lib v1.2） | 12 个脚本守护：名字\|进程模式\|重启 recipe\|心跳文件\|心跳上限 | 单实例锁+心跳+2-of-3 确认+重启预算 3/h | 守护级判据 |
| `ne_events.tsv` | ts/pid/comm/sig/exe/args（core_meta 链） | NE 台账；args 含脚本名可归属、pcomm 在 meta 文件 | 组件降级信号 |
| `boot 台账`（boot_gate）/ reboots.log | boot.healthy / 定时重启行 | 启动链判决 + 计划内重启标记 | 维护窗口标记 |
| `stability_metrics.tsv` | 5min：logc/crash/repairs/load/memavail/+fix-stack 列 | 长期指标同表 | 交叉验证 |
| `/proc/dpclamp` v2 | deep/burst/trig/whits/环形台账 | 修复栈健康（v1.3） | 内核组件判据 |
| `netcfg_repairs.tsv` | REPAIR 台账 | 规则被外力蒸发的修复率 | NAT/路由降级信号 |
| pstore / aee db_history | KE/致命记录 | 内核级故障 | 内核组件判据 |
| dial_keeper / wan_agg TICK | has_ip/cell_alive/wan_alive/探活原文 | 结果面判据（拨号/上行真实可用） | 数据面判据 |

**结论：数据源全部现成，缺的只是"采样-聚合-呈现"三件。**

## 1. 状态模型

### 1.1 级别（对齐 GitHub Status 语义）

| 级别 | 含义 | 典型来源 |
|---|---|---|
| `operational` | 判决全过 | watchdog_state 键=0 |
| `degraded` | 在服务但有病灶 | 窗口内发生 EVT restart / 可归属 NE / REPAIR 速率超阈 / 心跳陈旧但进程在 / WiFi 换道被采纳 |
| `down` | 判决失败（经 2-of-3 确认，非单次探针抖动） | watchdog_state 键=1 持续 ≥2 个采样窗 / 重启预算耗尽 |
| `nodata` | 本采样窗无判决（boot 早期、监督者自身挂） | watchdog_state 文件龄 > 3×CYCLE |
| `maintenance` | 计划内（04:00 定时重启窗） | reboots.log + boot 台账时刻 |

### 1.2 可用性口径（先立后算）

- 采样窗 10min（每小时 6 窗）；组件小时直方图 = 各级计数；
- **日可用率 = (operational + degraded×0.5) / (总窗 − maintenance − nodata)**；
  degraded 半权是立场：病灶要扣分但不同于不可用（WiFi 守护 30s 自愈 ≠ 断网）。
- **nodata 不进分母但单列**：观测覆盖=实际采样窗/应收窗，呈现为页面上独立的
  "数据覆盖"组件（监督者/采样器自己病了要可见——对应 GitHub 页的 instrumentation）；
- 分母排除 maintenance：04:00 计划重启（约 2-3 分钟）不算故障，但状态条上
  **渲染为灰色维护条**（诚实呈现，不算绿）。

## 2. 组件清单与判据表（核心交付物）

> 判据列的第一来源都是 watchdog_state 键（复用监督判决）；"降级信号"是叠加项。
> 键名后注 (补) = 现无该键，实施时在 watchdog 增补（各一行 set_state，零新机制）。

### A. 系统底座

| 组件 | 判据键/来源 | 降级信号 |
|---|---|---|
| 启动链 | bootgate + boot 台账 healthy | babysit 介入记录 |
| 内核/修复栈 | pstore 零 KE + `/proc/dpquar` patched=1 + `/proc/dpclamp` 在位 | fixstack.log SKIP 行、NE 滴漏率（全局） |
| 监督层自身 | watchdog_state 文件龄 <3×CYCLE + watchdog 心跳 (补:supervisor=) | EVT 日志停写 |
| 日志管线 | log_keeper(SVC) + logc frames 前进 | logc_rc≠0 |
| 网关 GUI | port80 + bootgate GUI 判据 | api.log 5xx 模式 |
| SSH 管理 | port22 | — |

### B. 局域网

| 组件 | 判据 | 降级信号 |
|---|---|---|
| LAN 桥/DHCP/DNS | dnsmasq + lan_ip + lo_up | dnsmasq EVT restart |
| WiFi AP（2.4G/5G 分列） | bss + hostapd（svc_lib 活套接字判据）分频键 (补:bss2g=/bss5g=) | hostapd NE、channel drift WARN、客户端驱逐 |
| 访客网络 | 访客 BSS 键 (补:bss_guest=)，未启用时显示为 off（灰，非绿） | — |
| IPv6 通告 | radvd 进程键 (补:radvd=) | — |

### C. 上行/WAN

| 组件 | 判据 | 降级信号 |
|---|---|---|
| 5G 蜂窝 | ccmni_up + dial_keeper(SVC) + TICK has_ip | 拨号退避、mipc_tool=1 |
| 以太 WAN | wan_eth(SVC) + carrier | — |
| 聚合引擎 | wan_agg + agg_rules + fwmark | 模式切换失败、承载口僵尸 |
| 上行认证 | authd 键（中性插座键，插件未装则 off） | 认证静默 WARN |
| NAT/防火墙 | nat | REPAIR/小时 > 基线 3σ |

### D. 功能面

| 组件 | 判据 | 降级信号 |
|---|---|---|
| 蜂窝控制面 (MIPC/AT) | mipc_tool | api_cell 动作失败 |
| 短信 | mipc_tool 同源（发送走 EMGS 同通道） | api_sms 发送失败行 |
| USB 设备模式 | usb_mgr(SVC)；未启用 off | UDC 解绑异常 |
| LED 指示 | led_mgr(SVC) | — |
| 温控/风扇 | fan_mgr(SVC) | 温度超阈记录 |
| NTP 守时 | ntp_keeper(SVC) | 最近同步龄 >2h |
| 定时重启 | reboot_sched(SVC) | 触发行迟到 >5min |

### E. 数据质量

| 组件 | 判据 |
|---|---|
| 观测覆盖 | 采样器自身心跳 + 覆盖率（§1.2） |

**总体状态** = 数据面(C 组)最差值优先；C 全绿时取其余组最差；`nodata` 于监督层
自身 = 整页降级横幅（观测不可信）。

### NE 归属策略（诚实性边界）

ne_events 的 comm 是短命工具（ip/grep/awk…），TSV 无父进程。归属规则：
1. args 含 `/data/gw/<daemon>.sh` → 直接归属该守护（led_mgr/dial_keeper 等）；
2. exe==守护本体（hostapd/dnsmasq）→ 归属；
3. 其余（纯工具族）**不归属**，计入全局"系统噪声"指标（修复栈组件的降级信号），
   不摊派到具体组件——宁可少归属，不可错归属。

## 3. 数据流与存储

```
watchdog(30s 循环, 现状不动, 仅补 4 个键)
   └─ /tmp/watchdog_state（迁移式快照）
sampler（新 gw/avail_sampler.sh，由 log_keeper 5min 块驱动、10min 节拍调用）
   ├─ 读 watchdog_state(龄守卫)+SVC 心跳+/proc/dpclamp+计数器 deltas
   ├─ 组件→级别 映射（§2 表驱动，映射表在 sampler 单点维护）
   ├─ 迁移检测(自存上一快照) → /data/gw/logs/avail_transitions.tsv
   │    列: ts comp from→to cause_hint(EVT/NE/REPAIR/KE/reboot/drift)
   └─ 小时直方图 → /data/gw/logs/avail_hourly.tsv
        列: hour comp ok deg down nod mai   （rotate 100 天 ≈ 2-3MB，/data 余 1.97G 无压力）
API（api_avail.sh，读 hourly+transitions 聚合，无写路径）
GUI（app.js PAGES.avail）
```

- **无新守护**（NE 暴露面零增加——本项目血泪前提）；sampler 是 log_keeper 的
  一次 fork 调用，采样器崩=NE 台账一行，不影响监督。
- 日粒度由 API 从 24 条小时行现算，不落第三份文件。
- 事件因果 enrichment：transitions 的 cause_hint 从 syslog（watchdog tag）
  FAIL/OK/EVT/WARN 行按窗内匹配。

## 4. API 与 GUI

### 4.1 端点（token 保护，GET only）

`/api/avail`：
```json
{ "overall": "operational",
  "coverage": 99.8,
  "components": [
    { "name":"5G 蜂窝", "group":"上行", "now":"operational",
      "days":[{"d":"2026-10-25","pct":100,"cls":"op"}, ...×90,
               {"d":"...","cls":"mai"}],
      "incidents":[{"ts":"...","what":"down 12min","cause":"EVT restart dial_keeper"}] } ] }
```
可选 `?comp=<名>&hours=168` 返回小时级明细（7 天 sparkline 用）。

### 4.2 GUI 页面（app.js 新 PAGES.avail，导航"可用性"）

```
┌ 总体横幅：● 所有系统正常 ｜ 数据覆盖 99.8% ｜ 近 90 天事件 N 起 ┐
│ [组: 系统] 启动链      ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮ (90 格) 100% │
│ [组: 局域网] WiFi 2.4G ▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮▮  99.2% ⚠2 │
│   ... 每组件一行：名称/今日状态点/90 天条(绿=op 黄=deg 红=down 灰=mai/无数据) │
│ 事件列表（近 30 天 transitions，倒序，cause_hint 可点开关联 syslog 时刻）│
└ 自检口径脚注：采样 10min/degraded 半权/维护窗排除/覆盖单列 ┘
```
- 90 格条 = 纯 CSS grid div，零依赖；小时明细 hover/点开（P2）。
- 版本配套：app.js v3.53、index.html v2.34（缓存 v68）、api.sh v2.79(+avail 域)、
  新 api_avail.sh v1.0、新 avail_sampler.sh v1.0、watchdog v1.31(+4 键)、
  log_keeper v2.9(驱动 sampler)——全部入注册表。

## 5. 实施分期

- **P1（一次会话）**：watchdog +4 键 → sampler（表驱动+双文件）→ api_avail →
  GUI 90 天条+事件列表 → selftest t_avail（文件在、端点形状、sampler 心跳新鲜、
  覆盖率>0）→ push。冷启动首日只有当日数据（状态条从左往右逐日生长——如实）。
- **P2（按需）**：小时 sparkline/组件详情页、WiFi 分频细化、事件→syslog 深链、
  night_report 纳入日摘要、脚本守护 NE 归属的 pcomm 增强（core_meta 已有数据，
  供 ne_events 增列后启用）。
- **不做**：任何"第二套探针"（判据永远以监督面为准）；外部拨测（单盒自观测
  是边界，页脚声明口径）。

## 6. 诚实性边界（写进页面脚注）

1. 自观测：设备死亡期间的"全绿"不存在——靠 boot 台账断口+覆盖率呈现
   （断电重启后该窗记 nodata，不是绿）。
2. 判决粒度=监督循环 30s+2-of-3：亚分钟闪断可能漏记（这本来就是监督面精度）。
3. degraded 半权、维护窗排除是**口径选择**，页脚必须声明，防止"99.9%"被误读。
4. NE 未归属桶不摊派（§2 归属策略）。

## 7. 风险与对策

| 风险 | 对策 |
|---|---|
| sampler 自身成 NE 受害者（工具族！） | 每 10min 一次 fork、单遍有界；崩溃由下一窗自愈+coverage 扣分可见 |
| /data 写放大 | 2 文件 append + 周界 rotate，<5KB/h |
| watchdog_state 迁移式快照被误读为"每窗判决" | sampler 以"文件龄+当前键值"为准，龄超限整体 nodata（不猜） |
| 判据键补丁改变 watchdog 行为 | 只加 set_state 行（零决策逻辑），走 selftest+push 门禁 |
| 维护窗误算故障（04:00 重启慢） | 窗宽取 reboots.log 触发时刻→boot.healthy 时刻实测+2min 余量 |
