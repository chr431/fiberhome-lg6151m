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
