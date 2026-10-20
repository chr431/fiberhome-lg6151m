# 固件稳定性弱点分析（2026-10-19 深夜轮，只读分析）

> 采样窗口：2026-10-19 21:27 冷启动后约 2.5 小时（截至 23:57）。方法：设备侧只读巡检
> + 受控诊断（静态工具压测、fuzz、计时），未修改任何固件/脚本/配置；诊断临时文件已清理。
> 本文是 [SIGSEGV_ANALYSIS.md](SIGSEGV_ANALYSIS.md) §9 之后的新输入：**P1 的静态采集器
> logc 在 23:57:15 自己崩了一次**，说明"静态化≠无崩溃"，残余风险需要重新评估。

## 0. 本轮新增的硬证据

| 时间 | 事件 | 证据 |
|---|---|---|
| 21:33:55 | `netstat` SIGSEGV | aee NE；watchdog 同时刻 `FAIL detail port80 rc=1 out=Segmentation fault`。PATH 已静态化，调用的是 `/data/gw/sbin/netstat`（Alpine busybox）。 |
| 22:51:57 | `ip` SIGSEGV | aee NE；watchdog TICK 22:51:54，wan_eth 22:52:00 `REPAIR main backup default metric200 (missing -> added rc=2)`。调用者未证实（aee dump 加密）。 |
| 23:57:15 | **`/data/gw/bin/logc` SIGSEGV** | aee NE #178；log_keeper `WARN logc ... err=Segmentation fault (core dumped)`，随后 `syslog ring resync`。正常读环时发生，下一轮自动恢复。 |
| 历史 | `hostapd_cli` 2 次 rc=139 | 旧 boot 12:36/14:13 watchdog `FAIL detail hostapd rc=139`；工具崩溃在自愈决策路径里。 |

## 1. 当前基线（实测）

- 负载 7.3 但 CPU idle 88%，`procs_blocked=0`：**幻影负载**（ccci_poll/hang_detect/wdtk/wed_task 常驻 D 态）。
- 内存 MemFree 1.29GB / MemAvailable 1.34GB；上一 boot 17h 内 MemAvailable 仅 −7MB，无明显泄漏。
- `/data` 2.0GB free、ext4 无 I/O error；`/tmp` 847MB free；conntrack 266/65536。
- 守护树全部 `exe=/data/gw/bin/busybox`；`/bin/busybox` 仅 console/SSH 进程。
- WiFi：hostapd ENABLED，5G 2 客户端，ch2/ch36；蜂窝拨号 OK；eth0 IP+default。
- 温度 54.8°C，PWM 60；无 kernel OOPS/panic。
- dmesg 可回溯窗口仅 **~22 分钟**：FORENSIC D 7,887 行 + 厂商 wdtk 11,981 行，占持久 dmesg 镜像 26,576 行的 75%。
- 本 boot aee NE 3 条：netstat、ip、logc。

## 2. 弱点清单与方案

### P0-1 自愈链单点 + 检查无超时 + D 态卡死不可恢复

**证据**
- `healthdog.ko` `armed=0`、`heartbeats=0`；`/data/gw/healthdog.armed` 不存在；`healthdog.sh` 在 v3 无 marker 时 `exit 0` → **无内核级 wedge 复位**。
- watchdog 无 procd/二级监督；`check()` 用 `eval` 直接跑命令，无 timeout。
- `mto()` spawn→`sleep 1` 轮询→`kill -9`→无条件 `wait`；若子进程 D 态，`wait` 可永久阻塞 → watchdog 停摆。
- TICK 实测 65–67s（设计 60s），每轮多 ~2.5–3.5s；AT 探针代码上每次 ≥1s（2 次/轮），另有 `iw` 49ms、`tc` 128ms、`dmesg` 21ms 等。

**方案**
1. 所有外部检查经静态 `timeout`（`/data/gw/bin/busybox timeout` 已在设备）分档限时；超时/rc=139 判定为"工具故障"，重试 2–3 次，不直接等价于服务故障。
2. `mto` 改非阻塞有界等待：0.1s 轮询（静态 busybox `sleep 0.1` 可用）、超时杀进程组、最多再等 1–2s，绝不无限 `wait`；AT 探针降频。
3. 二级监督：watchdog 写 `/tmp/watchdog.beat`；healthdog.sh 校验该心跳；`boot.healthy` 后稳定 5–10 分钟才 arm；/data 记录连续异常启动，防 reboot 循环。或给 watchdog 加 procd respawn。

### P0-2 boot.done 是定时器不是健康判据；TRY_A 提前清零 → 无有效回滚

**证据**
- rc19 `( sleep 120; touch /tmp/boot.done ) &`：marker 与步骤成功无关。
- 本 boot：boot.done ~21:29:54，WAN 拨号成功 21:30:03；selftest/watchdog/babysit 均以该文件为准。
- rc.extend 启动早期即清 TRY_A（`0f 00…`）；若 rc19 在 marker 后失败/卡死，LK 的 4 次回退永不累积。
- babysit T1=180s/T2=360s；本 boot marker 130s，余量 50s；T1 杀 rcS，T2 翻 B 槽+硬复位。

**方案**
1. 真实 `boot.healthy` 门禁：procd/ubus、dropbear:22、dnsmasq:53、v3httpd HTTP 200、br-lan/LAN IP、2+ BSS、eth0 IP+default、agg 规则、authd 状态、拨号状态；全过才写 `/data/gw/boot.healthy`。
2. 启动后 5–10 分钟观察窗；watchdog 校验 healthy 仍成立。
3. A/B：只有上次 boot.healthy 存在（按 boot 序号匹配）才清 TRY_A；否则保留 LK 计数，4 次坏启动回 B；持久化启动尝试/失败计数与快速重启检测。
4. babysit 进展式：监控 rc19 PID/日志推进；T1 只在无进展时杀特定子进程；T2 放宽到 600s；分阶段升级；决策写 /data。

### P0-3 关键服务无自愈

**证据**：procd 无 `dnsmasq`/`dropbear`；watchdog 对它们只有 check、无 spawn；`v3httpd` 只有端口检查无重启；`authd` 无检查；`ntp_keeper`/`traffic_logger`/`wifi_guard`/`reboot_sched` 无检查/自愈。

**方案**：统一服务监督表（存活+进度+重启配方+限频）；dropbear/dnsmasq/v3httpd/authd 重建；功能性探针（静态 wget、nslookup、状态文件新鲜度）；2-of-3 失败才动作。

### P1-1 进程在≠守护活

**证据**：仅 dial_keeper 有 hb+stale 判据；wan_agg 的 `/tmp/wan_alive` 未被 watchdog 消费；wan_eth/log_keeper/led_mgr/fan_mgr/wifi_guard 无心跳。

**方案**：统一 `/tmp/<daemon>.hb`；watchdog 按 2–3 周期 stale 重启；wan_alive/logc.stats 复用；fan_mgr 加 PWM/温度反馈交叉校验；selftest 加新鲜度断言。

### P1-2 残余崩溃：静态工具仍会崩

**证据**：见 §0。

**方案**：
1. 常驻 core_pattern 元数据 wrapper：先记录 `/proc/<pid>/{exe,cmdline,status,maps}`、父进程、PATH、dmesg 尾部，再 `exec` aee forwarder，保持 aee 行为。
2. logc 崩溃专项：ASAN/fuzz + `--dump-raw` 原始流；用 core wrapper 归因。
3. 安全检查命令统一 wrapper：记录 cmd/rc/139/timeout/pid 到持久日志；工具故障重试，不直接判服务死。
4. 安全判据迁移到最小静态读取（/proc/net/tcp*、/proc/net/route、sysfs），或构建静态 iw/hostapd_cli。

### P1-3 hostapd 自愈误判

**证据**：依赖 `hostapd_cli`（历史 2 次 rc=139）；恢复动作 kill hostapd + ifconfig down/up + brctl；352 次 FAIL 集中在真实 outage。

**方案**：2-of-3（间隔 30–60s）才恢复；rc=139 视为工具故障先重试；恢复前独立确认进程/控制 socket；记录原因与影响客户端数；限频。

### P1-4 WiFi stall 守护逻辑缺陷

**证据**：`v3_steth` 判据（rx 前进 ≥3 且 tx 冻结 10s）空闲可误报；`wifi_guard` 仅按 episode 增量加 strike：单次持续 stall 永远到不了 3 strikes（不恢复），3 次起落则 45s 内 bounce。上一 boot 520 episodes / 11 bounces（~每 1.5h 一次，每次客户端断连）。wifi_guard 无心跳/监督。

**方案**：按"连续 N 次采样 stall=1"恢复；加 traffic/queue/站点/ wed_task 前置；小时级限频、客户端影响记录；监督心跳；v3_steth 增加 tx backlog。

### P1-5 取证链不足

**证据**：dmesg 仅 ~22min（75% 为 FORENSIC/wdtk 噪声）；aee db_history 无进程名、dump 加密、8 槽覆盖；P3 窗口仅 10min/日；log_keeper 每次启动都写 BOOT（今天 20:37 的 `up=59808s` 是假 BOOT）。

**方案**：core wrapper + `ZZ_INTERNAL` 进程名进 watchdog WARN 与持久 `ne_census.tsv`；healthdog forensic 按需（marker）与 log_keeper 降噪；开机收 `/sys/fs/pstore/console-ramoops-0`；BOOT 用 btime/boot_id 门禁；core 保留配额。

### P2-1 蜂窝 zombie-IP / ccmni churn

**证据**：上一 boot 29 次 zombie-IP；18:44–18:54 ccmni1 IP 变 5 次；本 boot 启动期 2 次；dial_keeper 重拨 1–2min 恢复；启动期 authd 晚于 wan_agg 造成 w2 抖动。

**方案**：连续 2 次失败才重拨；限频/退避；持久计数；authd 先于 wan_agg 或 60s 宽限。

### P2-2 NTP 首同步失败后等 1 小时

**证据**：21:28:54 失败，22:28:56 才成功；RTC 存在但失效时会错 1h。

**方案**：首同步前 30–60s 重试（≤10min）再小时级；持久 last-known time；监督 heartbeat。

### P2-3 日志量/写放大

**证据**：持久日志 ~1.2MB/h（~30MB/day），FORENSIC/wdtk 75%；dmesg 4MB 轮转约 3.8h。

**方案**：源头降噪 + 过滤；监控 TBW；保留轮转；不 fsync 可接受（≤30s 丢失）。

### P2-4 多写方路由/防火墙与配置持久性

**证据**：启动期 3 轮 REPAIR，22:52 一次；当前无重复规则；`gw_set` `mv` 无 fsync。

**方案**：flock 串行化路由/防火墙写；写后校验；REPAIR 速率指标；关键配置 sync。

### P3 次要

- `apcli0` 未连接 STA + wpa_supplicant；vendor global hostapd + 我们的 AP hostapd 并存。
- v3httpd CGI 用 vendor `/bin/sh` 执行 api.sh。
- log_keeper/wan_agg/wan_eth/fan_mgr/traffic/ntp/wifi_guard/reboot_sched 无单实例锁。
- log_keeper rc 记录 bug（`if !` 后 `$?` 为 0）；崩溃后 resync 重复 tail 400 行。
- traffic_logger 等无日志/监督。

## 3. 整改批次

| 批次 | 内容 |
|---|---|
| 第一批（小时级） | check 加 timeout；rc=139/超时重试；dnsmasq/dropbear/v3httpd/authd 重启；wan_agg/log_keeper 等进度判据；FORENSIC/wdtk 降噪；BOOT btime 门禁；log_keeper rc 修复；NTP 首同步重试；authd 启动顺序 |
| 第二批（天级） | boot.healthy 门禁 + babysit 进展式；TRY_A 延迟清零/回滚；healthdog 受控 arm + watchdog 心跳；core_pattern 元数据 wrapper；hostapd/wifi_guard 决策硬化 |
| 第三批（结构性） | 统一监督/心跳/锁框架；静态工具/最小解析器；多写方串行化；logc ASAN/fuzz 与长期指标 |

## 4. 未闭环

1. logc 23:57:15 SIGSEGV 根因（需 core wrapper/ASAN）。
2. ip 22:51:57 调用者未证实（静态 iproute2 vs vendor ip）。
3. netstat 21:33:55 触发输入未捕获。
4. WiFi 520 episodes / 11 bounces 中真实 stall 与空闲误报比例。
5. ccmni1 IP 频繁变化的责任方（模组/网络/多写方）。

## 5. 2026-10-20 00:00–00:32 补记（batch1 试验后已回滚）

- 00:05:54 `awk` SIGSEGV（aee NE），仍是守护树外的厂商动态工具。
- 00:24 第一批改动（watchdog v1.26 / logc v1.1 / log_keeper v1.9 等）部署并冷启动一次。
- **00:28:12 `logc v1.1` 再次 SIGSEGV**（aee NE，db.07.NE）——采集器自身缺陷仍在，aee dump 仍加密，未定位；这是明天继续查的第一优先。
- 00:32 按用户要求回滚：公开仓回到 `42aa736`（batch1 提交未推送），设备推送回 batch1 前版本并重启；batch1 补丁与本文分别归档在
  `_local/archive/stability_2026-10-20/batch1.patch` 与同目录的
  `STABILITY_ANALYSIS_2026-10-19.md`。

## 6. 2026-10-20 执行记录（batch2：P0 全部 + P1 全部）

> 实现原则：batch1 的方案保留为骨架，但把"单次失败就动射频/杀进程"全部改为
> **先取证、再确认、后动作**；所有超时/信号异常只进工具故障台账，不再等价于
> 服务死亡。版本登记见 `tools/VERSIONS.tsv`（本次 115 个登记文件 / MANIFEST 67 项）。

### 6.1 P0-1 自愈链：限时、有界、二级监督

| 项 | 落地 |
|---|---|
| 所有外部检查限时 | `watchdog v1.27` 的 `check()` 经 `/data/gw/bin/busybox timeout -s KILL 8`；124/137/139 视为工具故障，重试 3 次仍失败只记 `toolfaults` + `/data/gw/logs/toolfaults.log`（含 what/rc/pid/uptime/cmd），不触发任何破坏性动作 |
| `mto` 不再无限 wait | 优先静态 `timeout`；回退路径 0.1s 轮询 → `kill -9` → 最多再 reap 10s，D 态子进程不再阻塞看门狗 |
| 端口判据去 netstat | `port_listen()` 直接解析 `/proc/net/tcp{,6}` 的 `:0016/:0035/:0050` + state 0A；守护树不再 spawn netstat |
| 二级监督 | `watchdog` 每轮写 `/tmp/watchdog.beat`；`healthdog v1.3` 在校验 `boot.healthy(stable=1)` 后**主动 arm** 内核模块（wedge 时用户态无法自救，必须提前武装）；armed 期间以 `loopback UP + beat 新鲜` 为心跳判据（beat 在周期起点写，慢探针不误判；看门狗 pid 消失 120s、存活但慢 300s 才停心跳），主看门狗陈旧时先保留心跳做一次 45s 宽限重启，仍陈旧才停发心跳（90s 后内核复位） |
| 受控 arm | 仅在 `boot.healthy` 的 `boot_id` 与本 boot 相同且 `stable=1`（10 分钟观察窗）后 arm；最近 3 次启动无 healthy 或 10 分钟内刚 arm 过 → 拒绝 arm（防 reboot 环） |
| 快速重启台账 | `rc.extend` 每次启动追加 `/data/gw/boot_attempts.tsv`（btime/epoch/result/fast/boot_id，保留 30 行）；<180s 的快速重启标记 `fast=1` |

### 6.2 P0-2 boot.done 真门禁 + TRY_A 回滚

- **timer 退役**：`rc19 v2.34` 删除 `( sleep 120; touch /tmp/boot.done ) &`，改由
  `boot_gate.sh` 在**关键链实测通过**后才写 marker：
  `LAN IP(192.168.9.1) + lo UP + dropbear:22 + dnsmasq:53 + v3httpd:80 监听 +
  /tmp/rc19.done`。Uplink/WiFi/agg/authd 属服务级，由看门狗监督，**不进入 boot
  判据**——否则拔网线冷启动会被误判为坏启动并翻 B 槽（本分析 P0-2 方案里
  "eth0 IP+default"一项按此理由裁剪，见 6.6）。
- **boot.healthy**：判据分三层——`critical`（boot.done）、`healthy`（critical +
  2 BSS + ubus + agg 规则）、`environmental`（authd 新鲜 + 上行口有地址且有默认
  路由 + wan_alive 新鲜）。**只有 healthy 层决定 boot.healthy/TRY_A/stable**；
  environmental 只记录为 `degraded=1`（拔网线/ISP 故障不得被当成坏启动）。
  通过后原子写 `/data/gw/boot.healthy`（boot_id/btime/epoch/uptime/stable/
  degraded/reason/checks）并 `sync`。10 分钟时复检通过才把 `stable=1` 改写；
  healthdog 只认 `stable=1`。
- **arm 跨守护重启**（现场实测）：内核 `armed` 标志不随 healthdog 进程消失而清零。
  重启后的新实例若从 `ARMED=0` 起步，会因"10 分钟内刚 arm 过"的保护栏拒绝 arm
  且**停发心跳** → 90s 后内核复位。`healthdog v1.4` 启动时读 `/proc/healthdog`，
  发现 `armed=1` 立即恢复心跳，再做其余判定。应急手法：
  `(while :; do echo hb > /proc/healthdog; sleep 10; done) &`。
- **内核 arm 与连通性解耦**：armed 心跳只看 `loopback UP + 看门狗 beat <180s`，
  外部 ping 仅记录不参与判据——否则一次断网就会让 armed 内核 90s 复位一次
  （这是旧 healthdog 设计里未被触发的隐藏环）。
- **TRY_A**：`rc.extend v2.6` 不再无条件清零；早期清零只允许"上次 attempt=healthy
  且非快速重启"，**终判清零在 boot_gate 全通过后**，写后 `dd` 读回
  `misc[2061]==0x00` 并记录 pre/post 字节。坏启动不再被掩盖，LK 计数可累积到回 B。
- **babysit v3.0**：`/tmp/boot.done` 在 preinit 无条件删除（旧标记必属上一 boot）；
  T1=240s 且**无进展 120s** 才 dump + 只杀 `rcS/mipc_wan_cli/dial_5g/ccmni_up`；
  T2=600s 且仍无进展才翻 B，进展持续则 60s 步进延到 900s 硬帽。
  **额外安全阀**：T2 若 dropbear :22 仍在监听则抑制翻槽并留痕（可手工修复的
  盒子不应被自动降级）。所有决策写 `/data/gw/logs/boot_babysit.log`。
- manifest 修正：babysit 的部署目标从 `/data/gw/babysit_v2.sh` 改为 preinit 实际
  执行的 `/data/rescue/babysit.sh` —— 旧目标从未被执行，历史上对 babysit 的修改
  根本无法经 deploy.py 生效。

### 6.3 P0-3 关键服务自愈 + P1-1 心跳

- 统一监督表（`SVC_TABLE`）覆盖 `ntp_keeper/traffic_logger/wifi_guard/
  reboot_sched/led_mgr/fan_mgr/wan_eth/log_keeper/core_trap/healthdog`，
  每项 = 存活 + 重启配方 + 心跳新鲜度 + 3 次/小时限频；`dnsmasq/dropbear/
  v3httpd/authd/wan_agg/dial_keeper/hostapd` 走专用块。
- 破坏性动作统一 **3 次连续确认**（90s）；单次失败只降级为告警。
- 心跳：`led_mgr 2s / fan_mgr 10s / wifi_guard 15s / wan_eth ~5s / log_keeper 30s /
  ntp_keeper 60s / traffic_logger 300s / reboot_sched 30s / core_trap 30s /
  healthdog 10s`；`wan_agg` 继续用 `/tmp/wan_alive` 的 `ts=`（已在看门狗消费）。
- 被监督脚本全部补**单实例锁**（cmdline 复核 + 非僵尸），避免"重启=双写方"：
  log_keeper/wan_eth/fan_mgr/ntp_keeper/traffic_logger/reboot_sched/wifi_guard。

### 6.4 P1-2/P1-5 残余崩溃取证链

- **core_pattern 元数据 wrapper**（`core_meta.sh v1.0`）：`rc.extend` 把
  `core_pattern` 从 aee 直连改为 `|/data/gw/core_meta.sh %p %s %u %g`；wrapper
  先落 `/proc/<pid>/{exe,cmdline,status,maps,environ-PATH,cwd,fd 数}`、父进程、
  持久 dmesg 尾与 aee 台账尾到 `/data/gw/logs/cores/meta/`，再 **exec 原
  `/sbin/aee_core_forwarder`（同 argv、stdin 不碰）**，aee 行为不变。
  另写 `/data/gw/logs/ne_events.tsv` 一行一条（watchdog 的 NE WARN 引用）。
- **logc v1.2**：SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGABRT 走独立栈 handler，写
  `/tmp/logc.crash`（sig/pid/frame_off/frame_len/buf_len/frames_emitted/uptime）后
  `_exit`；`log_keeper` 检测 rc≠0 时归档到 `logs/logc_crash/`；新增 `--dump-raw`
  （原始流，默认 8MiB 上限）与 `--selftest`（合法帧+垃圾段+截断尾，期望
  frames≥2/bad_frames>0/resyncs>0/dropped>0）；ubus 三个 64KB 栈缓冲合并为静态
  缓冲，构建加 `-fstack-protector-all`。
- **进程名台账**：`log_keeper v2.0` 从 syslog 新增行抽取 aee 的
  `pid: N, tid: N, >>> comm <<<` 写 `logs/ne_census.tsv`（epoch/pid/comm/原文），
  补上 `db_history` 无进程名的盲区；watchdog 的 `WARN aee NE +N` 直接附 census 末条。
- **降噪**：healthdog `forensic` 默认 0（`/data/gw/healthdog.forensic` marker 才
  开 FORENSIC D）；`log_keeper` 的 dmesg 镜像过滤 FORENSIC/wdtk/hang_detect/SPM；
  BOOT 行以 btime 门禁；`core_trap v1.1` 全局配额 60 个/200MB + `quota.tsv`。
- **pstore**：`healthdog` 每 boot 把 `/sys/fs/pstore/console-ramoops-0` 复制到
  `/data/gw/logs/pstore/console-ramoops.<btime>.txt`（硬复位后唯一现场）。
- **已知未闭环**：logc 两次 SIGSEGV 的根因仍未定位（aee dump 加密）。本轮把
  "下一次崩溃"变成可归因：帧偏移/长度 + 进程元数据 + 原始流回放。若面包屑出现，
  用 `logc --stdin --dump-raw` 语料离线复现即可把范围收敛到单帧。

### 6.5 P1-3 hostapd / P1-4 wifi_guard

- hostapd：3 次连续确认（90s）后才动射频；`hostapd_cli` 超时/139 只记工具故障并
  重试，进程仍在时**拒绝**把"工具崩了"当成"hostapd 死了"；恢复前独立确认控制
  socket（`/var/run/hostapd/ra0|rai0`）存在、记录在线客户端数；成功判据同样经
  限时 wrapper；限频 3 次/小时。
- wifi_guard v1.2：恢复判据从"episode 增量"改为**连续 4 次采样 stall=1（60s）**；
  前置 ≥1 个关联客户端、无 wifi_up/hostapd 恢复在进行；小时 2 次、每 boot 10 次
  限频；每次记录客户端数/qdisc backlog/`wed_task1` 计数；心跳 + 单实例锁。

### 6.6 实测发现：loopback 一直是 DOWN（本轮的额外硬证据）

`ip link show lo` = `state DOWN`，`ping 127.0.0.1` 失败；设备本机连接
`192.168.9.1:80/22/53` 全部超时（本地路由指向 lo），而 PC 侧正常。这解释了两件事：

1. 任何"设备本机 HTTP 探活"在旧固件上都不可能成功；boot_gate 因此改用
   `/proc/net/tcp` 监听判据（不依赖 lo）。
2. 旧 `healthdog.sh` 的 `ping 127.0.0.1` 健康判据**永远为假**；一旦按 P0-1 的
   方案 arm 内核模块，它会在 90s 后必然硬复位（90s 复位环）。故 `rc.extend v2.6`
   与 `healthdog v1.3` 都显式 `ip link set lo up`，并把 `lo UP` 纳入 boot 关键链。

### 6.7 验证方式（部署后执行）

- `logc --selftest`、`boot_gate.sh --check` 先做非破坏性判定；
- 冷启动后断言：`boot.healthy.boot_id == 当前 boot_id`、`stable=1`、
  `/tmp/boot.done` 在位、`misc[2061]==0x00`、`boot_attempts` 末行 `result=healthy`；
- `selftest.py` 全量（新增 7 条 stability P0/P1 断言：监督表单实例、心跳新鲜度、
  core wrapper/selftest/census、healthdog 判据、hostapd/wifi_guard 静态判据、
  降噪/pstore/BOOT 门禁）。

### 6.8 明确未做（诚实清单）

- logc 崩溃根因（见 6.4；本轮交付的是归因能力，不是结论）。
- P2/P3 项（蜂窝 zombie-IP、NTP 小时级策略、写放大、多写方 flock、静态 CGI 等）
  不在本轮 P0+P1 范围。
- `v3_steth` 内核侧未新增 tx backlog 字段（需重建内核模块，风险高于收益）：改用
  `tc -s qdisc show dev rai0` 的 backlog 作为同义用户态信号，随每次恢复决策留痕。
- hostapd/wifi_guard 的阈值（90s 确认、60s 连续 stall、2 次/小时）是**保守初值**，
  需用下一次真实 stall 的日志校准；本轮只保证"不再误伤"。
