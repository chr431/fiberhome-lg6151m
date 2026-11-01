# 可靠性验收报告 (M4 自持性 + 汇总口径)

> 生成时刻: 2026-11-01 11:42:39 (UTC+8)  生成器: `tools/acceptance/report.py`
> 合同: `docs/RELIABILITY_SPEC.md` v1.0  证据: 设备 `/data/gw/logs/*`(可复核) + 本机归档
> 原则: 每个判定都指向一个设备侧文件与时间窗; 数据缺失记 **unknown**, 不记 0。

## 0. 结论摘要

| 需求 | 判定 | 一句话依据 |
|---|---|---|
| R4.1 守护覆盖审计 | FAIL | 覆盖表 + 62 条注入实测, 见 §2/§6 |
| R4.2 资源不泄漏 | PASS | 每日 checkpoint 趋势 + 轮转上界, 见 §3 |
| R4.3 30d soak 装置 | PASS | 装置在位并已产生 4 条样本, 见 §4 |
| R4.4 故障注入 >=30 | FAIL | 有效 61 条: 57 条自愈(93%), 4 条失败, 1 条中止/跳过, 见 §6 |
| R4.5 无人干预声明 | PASS | 人工动作清单已列全并逐条处置, 见 §7 |

**本报告不宣称 30 天已跑完**: 30d 不可在一个会话内等待, 交付物是「装置 + 已运行样本 + 外推论证 + 每日自动日报」; 装置在无人值守下继续累积。

## 1. 时间窗与证据清单

- 重启台账覆盖: 2026-09-09 09:42:08 .. 2026-11-01 04:13:29 (pstore 可回溯范围)
- 设备侧证据: `/data/gw/logs/{soak_daily,soak_boots,soak_alerts,fault_inject,drills,reboots.log,ne_events}`
- PC 侧归档: `_local/evidence/soak/<UTC>/` (`tools/acceptance/soak.py pull`)
- 重启归因原始证据: `/data/gw/logs/pstore/console-ramoops.*` + `/data/gw/healthdog.armlog`

## 2. R4.1 守护覆盖审计

静态覆盖表见 [docs/SELF_HEALING_AUDIT.md](SELF_HEALING_AUDIT.md) §2(逐进程/逐功能面)。
本节机器可复核的部分是**注入实测**: 覆盖表说"有监督"不算数, 杀掉后能自己回来才算。

| 注入目标 | 类别 | 自愈耗时 | 判定 |
|---|---|---|---|
| `led_mgr.sh` | kill_daemon | 120s | **PASS** |
| `fan_mgr.sh` | kill_daemon | 105s | **PASS** |
| `ntp_keeper.sh` | kill_daemon | 0s | **ABORTED_HARNESS** |
| `ntp_keeper.sh` | kill_daemon | 42s | **PASS** |
| `traffic_logger.sh` | kill_daemon | 96s | **PASS** |
| `authd` | kill_daemon | 0s | **PASS** |
| `hostapd` | kill_daemon | 19s | **PASS** |
| `v3httpd` | kill_daemon | 61s | **PASS** |
| `dnsmasq` | kill_daemon | 61s | **PASS** |
| `wan_agg.sh` | kill_daemon | 42s | **PASS** |
| `wifi_guard.sh` | kill_daemon | 81s | **PASS** |
| `nerepair` | kill_daemon | 81s | **PASS** |
| `reboot_sched.sh` | kill_daemon | 81s | **PASS** |
| `atcid` | kill_daemon | 39s | **PASS** |
| `wan_eth.sh` | kill_daemon | 63s | **PASS** |
| `log_keeper.sh` | kill_daemon | 67s | **PASS** |
| `usb_mgr.sh` | kill_daemon | 66s | **PASS** |
| `traffic_logger.sh` | kill_daemon | 22s | **PASS** |
| `fan_mgr.sh` | kill_daemon | 22s | **PASS** |
| `led_mgr.sh` | kill_daemon | 22s | **PASS** |
| `ntp_keeper.sh` | kill_daemon | 22s | **PASS** |
| `reboot_sched.sh` | kill_daemon | 22s | **PASS** |
| `log_keeper.sh` | kill_daemon | 22s | **PASS** |
| `ntp_keeper.sh` | kill_daemon | 44s | **PASS** |
| `traffic_logger.sh` | kill_daemon | 44s | **PASS** |
| `reboot_sched.sh` | kill_daemon | 44s | **PASS** |
| `led_mgr.sh` | kill_daemon | 46s | **PASS** |
| `fan_mgr.sh` | kill_daemon | 46s | **PASS** |
| `log_keeper.sh` | kill_daemon | 46s | **PASS** |
| `led_mgr.sh` | kill_daemon | 6s | **PASS** |
| `fan_mgr.sh` | kill_daemon | 6s | **PASS** |
| `reboot_sched.sh` | kill_daemon | 6s | **PASS** |
| `traffic_logger.sh` | kill_daemon | 6s | **PASS** |
| `log_keeper.sh` | kill_daemon | 6s | **PASS** |
| `ntp_keeper.sh` | kill_daemon | 6s | **PASS** |
| `SIGSEGV throwaway sh` | ne | 2s | **PASS** |
| `SIGSEGV /data/gw/bin/ip (our-tree)` | ne | 121s | **FAIL** |
| `300MB tmpfs 压力后清理` | memory | 21s | **PASS** |
| `200 个 sleep 子进程后清理` | memory | 27s | **PASS** |
| `40 路 ICMP 洪泛 10s` | storm | 12s | **PASS** |
| `200 路 TCP 连 :80` | storm | 10s | **PASS** |
| `SIGSEGV our-tree busybox` | ne | 2s | **PASS** |
| `fill to ~120MB free then clean` | disk | 189s | **PASS** |
| `fill below 100MB threshold then clean` | disk | 127s | **PASS** |
| `clock +30min (NTP synced)` | clock | 10s | **PASS** |
| `clock -45min + drop ntp marker (unsynced)` | clock | 10s | **PASS** |
| `2026-11-01 11:36:19` | clock | 1812s | **FAIL** |
| `2026-11-01 10:12:57` | clock | -2688s | **PASS** |
| `fast fill to 100MB floor (guard vs 60s fill)` | disk | 115s | **PASS** |
| `2026-11-01 10:35:33` | clock | 103s | **PASS** |
| `ra0 down 20s then up` | link | 28s | **PASS** |
| `rai0 down 20s then up` | link | 30s | **PASS** |
| `br-lan delif ra0 20s then addif` | link | 26s | **PASS** |
| `eth0 down 15s then up` | link | 41s | **PASS** |
| `ra0 link down` | link | 72s | **PASS** |
| `rai0 link down` | link | 96s | **PASS** |
| `br-lan ra0 membership` | link | 301s | **FAIL** |
| `NAT masquerade rule` | config | 0s | **PASS** |
| `fwmark policy rule` | config | 0s | **PASS** |
| `mangle WANAGG marks` | config | 9s | **PASS** |
| `2026-11-01 10:51:35` | clock | 181s | **FAIL** |
| `br-lan ra0 membership` | link | 12s | **PASS** |

自愈耗时分布: min=0s p50=30s p90=103s max=189s

## 3. R4.2 资源不泄漏

| 维度 | 现值 | 上界/机制 | 判定 |
|---|---|---|---|
| /data 剩余 | 1516992 KB (used 35%) | 阈值 102400KB | PASS |
| /tmp 剩余 | 867480 KB | tmpfs 重启即清 | PASS |
| 进程数 | 259 | 基线 ~250 | PASS |
| 僵尸 | 0 | 阈值 20 | PASS |
| 全局 fd | 512 / 173554 | 阈值 90% | PASS |
| 可用内存 | 1334492 KB / 1738184 KB | 阈值 200000KB | PASS |
| 日志总量 | 103652 KB | 见 §3.1 | PASS |

### 3.1 日志轮转上界(静态核对 gw/log_keeper.sh)

| 文件 | 轮转/上界 |
|---|---|
| syslog.log | 4MB 触发轮转, 仅留一代 .1 → 上界 ~8MB |
| dmesg.log | 同上 → 上界 ~8MB |
| /data/gw/logs/tmp/*.log | 单文件 1MB 触发轮转(STREAM_CAP) |
| nerepair.log | 1MB 轮转 + 20 行/秒限流 |
| toolfaults.log | 256KB 触发截断到 400 行 |
| pstore/console-ramoops.* | 每次开机 1 份 262KB, 目录级上限见 log_keeper |

## 4. R4.3 30d soak 装置与已运行样本

- 设备侧: `gw/soak_checkpoint.sh` (v1.0), 由 **log_keeper 5min 块 fork 驱动** `--tick`, 自身节流到每 24h 一条;
  不新增常驻守护、不新增高频探针(Lead 裁决 v1.1)。
- PC 侧: `tools/acceptance/soak.py pull|trend|alert|daily`。
- 台账: `soak_daily.tsv`(每日资源/重启/NE/中断三档/判定)、`soak_boots.tsv`(每次开机一行+原因+证据源)、`soak_alerts.tsv`(漂移告警)。

| day | up_s | /data free | fd | zombies | NE 24h | boots 24h(计划/非计划) | 计划该来没来 | verdict |
|---|---|---|---|---|---|---|---|---|
| 2026-10-31 | 18893 | 1554668 KB | 512 | 0 | 12 | 1 (0/1) | 0 | **DEGRADED** |
| 2026-11-01 | 20504 | 1542420 KB | 512 |  | 12 | 1 (0/1) | 0 | **DEGRADED** |
| 2026-11-01 | 402 | 1517896 KB | 512 | 0 | 16 | 4 (0/4) | 0 | **FAIL** |
| 2026-11-01 | 1111 | 1516992 KB | 512 | 0 | 16 | 4 (0/4) | 0 | **DEGRADED** |

### 4.1 重启归因(设备侧可复核证据)

> 由 `tools/acceptance/boot_audit.py` 从 pstore/reboots.log/healthdog.armlog 生成。

- 启动总数(pstore 台账): **86**
- scheduled: 10
- clean: 35
- sysrq: 8
- crash: 23
- unknown: 10
- reboots.log 计划触发 12 条, 其中 10 条能在 pstore 匹配到启动
- **台账覆盖缺口**: 以下触发行没有对应 pstore 记录(启动台账不完整, 已由 soak_boots.tsv 闭环): 2026-10-19 04:00:16, 2026-10-20 04:00:22
- 达到 stable-healthy 的启动: 65 (占 76%)

<details><summary>逐次启动归因表(点开)</summary>

| 启动时刻 | 类别 | 证据 |
|---|---|---|
| 2026-09-09 09:42:08 | sysrq | sysrq-b |
| 2026-09-09 09:58:10 | crash | Internal error: Oops: 96000006 [#1 |
| 2026-09-09 10:03:47 | crash | Internal error: Oops: 96000006 [#1 |
| 2026-09-09 10:53:30 | crash | Internal error: Oops: 96000006 [#1 |
| 2026-09-09 11:33:12 | crash | Internal error: Oops: 96000046 [#1 |
| 2026-09-09 11:36:01 | crash | Internal error: Oops: 96000046 [#1 |
| 2026-09-09 12:00:06 | unknown | [ 1401.628673] ccci_fsm1: rcu: 	1-....: (1560 tick |
| 2026-09-09 12:40:17 | crash | Internal error: Oops: 96000005 [#1 |
| 2026-09-09 12:41:44 | crash | Internal error: Oops: 9600004f [#1 |
| 2026-09-09 12:45:49 | unknown | [  322.896632] aee_aed:  show DAL failed: Invalid  |
| 2026-09-09 12:52:38 | sysrq | sysrq-b |
| 2026-09-09 12:58:16 | clean | procd/reboot |
| 2026-09-09 13:03:03 | clean | procd/reboot |
| 2026-09-09 13:19:50 | crash | Unable to handle kernel paging request at virtual  |
| 2026-09-09 16:36:02 | clean | procd/reboot |
| 2026-09-09 17:06:00 | sysrq | sysrq-b |
| 2026-09-09 17:15:38 | clean | procd/reboot |
| 2026-09-09 17:25:37 | crash | Internal error: Oops: 96000005 [#1 |
| 2026-09-09 17:34:45 | unknown | [  537.841340] HwCtrlTask_0: 7992@ERROR.HIF,ra0,hw |
| 2026-09-09 17:38:41 | unknown | [  226.309570] aee_aed:  show DAL failed: Invalid  |
| 2026-10-20 08:17:24 | clean | procd/reboot |
| 2026-10-20 08:23:31 | clean | procd/reboot |
| 2026-10-20 08:37:20 | clean | procd/reboot |
| 2026-10-20 08:40:34 | clean | procd/reboot |
| 2026-10-20 08:52:01 | clean | procd/reboot |
| 2026-10-20 08:53:45 | clean | procd/reboot |
| 2026-10-20 09:03:40 | clean | procd/reboot |
| 2026-10-20 09:43:37 | clean | procd/reboot |
| 2026-10-20 10:28:33 | clean | procd/reboot |
| 2026-10-21 04:01:00 | scheduled | reboots.log(+32s) |
| 2026-10-21 20:13:26 | clean | procd/reboot |
| 2026-10-21 20:31:44 | sysrq | sysrq-b |
| 2026-10-22 04:00:58 | scheduled | reboots.log(+31s) |
| 2026-10-22 13:02:53 | crash | Internal error: Oops: 86000006 [#1 |
| 2026-10-22 15:55:58 | crash | Internal error: Oops: 96000006 [#1 |
| 2026-10-22 16:02:14 | crash | Internal error: Oops: 96000004 [#1 |
| 2026-10-22 20:45:57 | unknown | [17017.211918] ccci_fsm1: PHYS_OFFSET: 0x80000000 |
| 2026-10-22 21:33:25 | crash | Internal error: Oops: 9600004e [#1 |
| 2026-10-23 00:48:51 | unknown | [11719.307687] ksoftirqd/3: mrdump: add MD:0xfffff |
| 2026-10-23 04:00:35 | scheduled | reboots.log(+33s) |
| 2026-10-23 07:51:55 | clean | procd/reboot |
| 2026-10-24 04:00:56 | scheduled | reboots.log(+33s) |
| 2026-10-24 17:12:29 | clean | procd/reboot |
| 2026-10-24 23:12:26 | clean | procd/reboot |
| 2026-10-25 04:01:03 | scheduled | reboots.log(+56s) |
| 2026-10-25 15:18:25 | clean | procd/reboot |
| 2026-10-25 17:15:46 | unknown | [ 7032.475713] ccci_fsm1: PHYS_OFFSET: 0x80000000 |
| 2026-10-25 17:35:41 | clean | procd/reboot |
| 2026-10-26 04:01:00 | scheduled | reboots.log(+31s) |
| 2026-10-26 23:14:23 | sysrq | sysrq-b |
| 2026-10-27 07:13:26 | clean | procd/reboot |
| 2026-10-27 19:50:39 | crash | Internal error: synchronous external abort: 960000 |
| 2026-10-27 19:56:54 | crash | Internal error: synchronous external abort: 960000 |
| 2026-10-27 22:19:21 | crash | Internal error: Oops: 96000047 [#1 |
| 2026-10-27 22:54:18 | clean | procd/reboot |
| 2026-10-27 23:41:20 | sysrq | sysrq-b |
| 2026-10-28 00:08:58 | clean | procd/reboot |
| 2026-10-28 00:20:28 | sysrq | sysrq-b |
| 2026-10-28 00:42:14 | clean | procd/reboot |
| 2026-10-28 01:21:20 | clean | procd/reboot |
| 2026-10-28 02:03:27 | unknown | [ 2516.653262] aee_aed:  show DAL failed: Invalid  |
| 2026-10-28 02:48:33 | sysrq | sysrq-b |
| 2026-10-29 04:00:50 | scheduled | reboots.log(+33s) |
| 2026-10-30 00:22:07 | clean | procd/reboot |
| 2026-10-30 02:13:52 | crash | Internal error: Oops: 96000006 [#1 |
| 2026-10-30 04:00:33 | scheduled | reboots.log(+33s) |
| 2026-10-30 07:27:48 | crash | Internal error: Oops: 96000007 [#1 |
| 2026-10-30 09:08:55 | unknown | [ 6059.879082] aee_aed:  show DAL failed: Invalid  |
| 2026-10-30 09:59:06 | crash | Internal error: Oops - BUG: 0 [#1 |
| 2026-10-30 10:04:08 | crash | Internal error: Oops: 96000007 [#1 |
| 2026-10-30 10:17:58 | clean | procd/reboot |
| 2026-10-30 10:43:37 | clean | procd/reboot |
| 2026-10-30 11:00:13 | clean | procd/reboot |
| 2026-10-30 11:29:04 | crash | Internal error: Oops: 86000007 [#1 |
| 2026-10-30 11:50:59 | crash | Internal error: Oops: 96000006 [#1 |
| 2026-10-30 14:11:56 | unknown | [ 8451.813721] procd: mrdump: add MD:0xffffff80010 |
| 2026-10-31 03:03:22 | clean | procd/reboot |
| 2026-10-31 03:11:39 | clean | procd/reboot |
| 2026-10-31 04:00:47 | scheduled | reboots.log(+31s) |
| 2026-10-31 08:10:43 | clean | procd/reboot |
| 2026-10-31 12:16:37 | clean | procd/reboot |
| 2026-10-31 18:11:33 | clean | procd/reboot |
| 2026-10-31 18:44:31 | clean | procd/reboot |
| 2026-11-01 02:55:48 | experiment-kernel-oops | attrib=crash-root rmmod mtk_wed: fault @ mtk_wed base+0x54, lr=__handl |
| 2026-11-01 04:00:57 | scheduled | reboots.log(+32s) |
| 2026-11-01 04:13:29 | clean | procd/reboot |

</details>

## 5. M3 三档计数(验收口径)

| 天 | 三档 | 排除 |
|---|---|---|
| None | {'#svc_daily v1.0 | date path lt5 n5_20 n20 total excluded preliminary': '20261101|gw|0|0|0|5|5|0'} | None |

## 6. R4.4 故障注入 campaign

装置: `tools/acceptance/inject.py` (PC 驱动, 设备侧单次 exec 内完成 注入→轮询→回滚→落账)。
每条注入: 必须持设备锁、距 04:00 >=15min、有回滚路径、恢复即验证、结果落 `/data/gw/logs/fault_inject.tsv`。

- 注入条目总数: **62** (要求 >=30 条有效注入)
- 有效 61 条 / 中止或跳过 1 条(不计入通过率)
- 判定分布: {'PASS': 57, 'ABORTED_HARNESS': 1, 'FAIL': 4}
- 通过率(仅有效): 93%
- 自愈耗时: min=0s p50=30s p90=103s max=189s

### 6.1 失败项(未自愈) —— 必须闭环

| id | 目标 | 类别 | 耗时 | 证据 |
|---|---|---|---|---|
| B-NE-2 | SIGSEGV /data/gw/bin/ip (our-tree) | ne | 121s |  |
| B-CLK-1r | 2026-11-01 11:36:19 | clock | 1812s | target=2026-11-01 11:36:19 after=1793504179  |
| L01 | br-lan ra0 membership | link | 301s | rb=ran_ok act= |
| B-CLK-2r | 2026-11-01 10:51:35 | clock | 181s | awk: cmd. line:1: Unexpected token routes=  |

### 6.2 前后对照: R4.1 快路径(tier-A)上线前后

| 窗口 | 路径 | 样本 | 恢复耗时 | median | max |
|---|---|---|---|---|---|
| 01:52-02:02 | watchdog 2-of-3 确认(旧) | 同组 6 守护 x1 | 120/105/42/96/81/67 s | **88.5s** | 120s |
| 10:01-10:03 | tier-A 确定死亡即刻重启(新) | 同组 6 守护 x3 轮 = 18 | 6s x6 / 22s x6 / 44-46s x6 | **22s** | 46s |

- **median 88.5s -> 22s(-75%), max 120s -> 46s(-62%)**。
- 机制解释: 旧路径要 3 个采样周期(90s)才动手; 新路径对「进程确定不存在」当轮即重启,
  恢复时间退化为「距下一个 30s watchdog 周期的相位」—— 实测 6/22/44s 正是三档相位。
- 设备侧证据: /tmp/watchdog.log 出现 EVT <svc> definitive death (process absent) -> tier-A immediate restart
  (首次 04:05:05); 设备 /data/gw/watchdog.sh mtime 09:43 且含 tier-A 分支。
- 口径注意(不粉饰): before 是**单样本 + 4 路并发**, after 是 **6 路并发 x3 轮**;
  并发度不同、before 样本量小, 因此 median 的绝对差值仅供参考,
  但「max 从 120s 降到 46s」与机制解释一致, 方向可信。

## 7. R4.5 无人干预声明

详见 [docs/SELF_HEALING_AUDIT.md](SELF_HEALING_AUDIT.md) §5。结论:

- **日常运行不需要人工**: 每日 04:00 计划重启 + 三层自愈(内核看门狗 → healthdog → watchdog)覆盖全部常驻服务。
- **仍需人工的动作**(已消除/自动化/或明确接受):
  1. 固件升级/部署 —— 设计上必须人工(`deploy.py`), 不属于运行时自持范畴。
  2. /data 空间耗尽 —— 仅告警不自动清理(SEV1 台账不可删); 由 R1.6 磁盘守卫在 M1 流闭环。
  3. 配置类漂移(NAT/MARK/网桥成员)被外力破坏 —— 见 §6 注入结果; 无自愈路径的列为已知缺口。
  4. 设备彻底失联(内核 hang) —— 靠 healthdog.ko 90s 硬复位兜底, 代价是一次完整重启(~110s)。

## 8. 已排除的演练窗口(可审计)

> 契约: `drills.tsv`(Lead v1.2) 是唯一演练标记文件; 消费方(svc-probe/state-truth/obs-ledger)按窗口打 excluded。

- 窗口行总数: 90 (批级 65 / 逐条 24)
- 残留 end_epoch=0 的行: **0** (无残留)
- 演练总时长: 17189 s

| start | end | kind | target | owner |
|---|---|---|---|---|
| 1793470904 | 1793470942 | drill-manual | LED_NIGHT=1 | state-truth |
| 1793477575 | 1793478475 | maintenance-reboot | lead-approved-validation | state-truth |
| 1793497026 | 1793499516 | drill-manual | v3httpd+dnsmasq | state-truth |
| 1793497336 | 1793497343 | drill-manual | v3httpd+dnsmasq | state-truth |
| 1793497351 | 1793497359 | drill-manual | v3httpd+dnsmasq | state-truth |
| 1793497369 | 1793497425 | drill-manual | wan_mode+mangle-MARK (D7 positive leg) | cfg-heal |
| 1793497464 | 1793497532 | drill-manual | v3httpd+dnsmasq | state-truth |
| 1793498048 | 1793498053 | fault-injection | R2C-guard-attempt1 | soak-qa |
| 1793498123 | 1793498430 | drill-manual | v3httpd+dnsmasq | state-truth |
| 1793498155 | 1793498220 | drill-manual | dnsmasq | state-truth |
| 1793498450 | 1793498479 | fault-injection | K06:reboot_sched.sh | soak-qa |
| 1793498453 | 1793498526 | fault-injection | R2C-rounds1-2 | soak-qa |
| 1793498474 | 1793498525 | fault-injection | K06:reboot_sched.sh | soak-qa |
| 1793498475 | 1793498528 | fault-injection | K07:log_keeper.sh | soak-qa |
| 1793498608 | 1793498621 | fault-injection | K06:reboot_sched.sh | soak-qa |
| 1793498609 | 1793498622 | fault-injection | K07:log_keeper.sh | soak-qa |
| 1793498611 | 1793498620 | fault-injection | R2C-round3 | soak-qa |
| 1793498613 | 1793498619 | fault-injection | K04:traffic_logger.sh | soak-qa |
| 1793498613 | 1793498619 | fault-injection | K07:log_keeper.sh | soak-qa |
| 1793499181 | 1793499224 | drill-manual | dnsmasq | state-truth |
| 1793499228 | 1793499253 | drill-manual | dnsmasq | state-truth |
| 1793499351 | 1793499419 | drill-manual | v3httpd | state-truth |
| 1793499425 | 1793499463 | drill-manual | v3httpd | state-truth |
| 1793501594 | 1793501813 | fault-injection | batchB-g1-NE-MEM-STM | soak-qa |
| 1793501923 | 1793502284 | drill-manual | batchB-g2-nonet | soak-qa |
| 1793502378 | 1793503194 | drill-manual | 全链路 | soak-qa |
| 1793502470 | 1793502571 | drill-manual | 全链路 | soak-qa |
| 1793502592 | 1793502687 | drill-manual | 全链路 | soak-qa |
| 1793502777 | 1793503194 | drill-manual | 全链路 | soak-qa |
| 1793502845 | 1793502936 | drill-manual | 全链路 | soak-qa |
| 1793503062 | 1793503085 | drill-manual | ntp_keeper | obs-ledger |
| 1793503087 | 1793503194 | drill-manual | 全链路 | soak-qa |
| 1793503232 | 1793503341 | drill-manual | 全链路 | soak-qa |
| 1793501730 | 1793503341 | clock-skew | 全链路 | soak-qa |
| 1793503601 | 1793504083 | drill-manual | wifi | soak-qa |
| 1793504095 | 1793504095 | drill-manual | wan | soak-qa |
| 1793504227 | 1793504237 | drill-manual | wan | soak-qa |
| 1793504312 | 1793504317 | drill-manual | br-lan:ra0 | cfg-heal |
| 1793504338 | 1793504349 | drill-manual | br-lan:ra0 | cfg-heal |
| 1793504455 | 1793504469 | drill-manual | wifi | soak-qa |

## 9. 假状态演练记录(判据类改动的实弹)

> spec 0: 判据类改动必须附「制造故障->判据必须变红->恢复->必须回绿」; soak_checkpoint v1.2 把判定阈值改为环境变量可覆盖, 正是为了让这条演练可执行(否则没有注入点)。

| 步骤 | 命令 | 期望 | 实测 |
|---|---|---|---|
| 绿(基线) | `sh /tmp/soak_drill.sh --once --force` | PASS/DEGRADED | DEGRADED(notes=unplanned_reboot,src_partial) |
| 红(制造故障) | `TH_DATA_FREE_KB=99999999 sh /tmp/soak_drill.sh --once --force` | **FAIL** + 告警行 | **FAIL**, soak_alerts 新增 `data_free 1520796 KB` |
| 回绿(恢复) | 再跑一次正常阈值 | 回到 PASS/DEGRADED | DEGRADED |

演练在隔离台账目录(/tmp/soakdrill)执行, 不污染生产台账; 2026-11-01 01:55 实弹。

## 10. NE 台账消费侧审计 + 隔夜归因

> 消费侧校验(tools/acceptance/ne_audit.py): 只查字段数一致性/脏行定位/历史判别/M1 覆盖度;
> 写入方根因由 obs-ledger 负责。

- 台账行数 1619; 字段数分布 {'1': 230, '2': 13, '6': 285, '7': 1058, '8': 29, '9': 4}
- **碎片行(NF<5) 243 条**, 行号 [14, 923], 上下文 epoch 1792472046 .. 1793270536
- 判据: 6/7/8 列是 schema 演进(正常); <5 列是 args 含换行被拆成多行(历史脏行, 写入方 core_meta 自 v1.11 起对 ARGS/PARGS 做换行/制表压平)
- args 含 TAB 导致的 9 列行: 4 条(同为历史)
- M1 覆盖: incidents.tsv 中 category=ne 共 1376 行

### 10.1 隔夜 NE 逐条归因(2026-11-01 04:33-09:30)

| epoch | 时刻 | comm | origin | 归因 |
|---|---|---|---|---|
| 1793477579 | 04:52:59 | ? | unknown | core_meta 未取到进程身份(comm/exe/args 全为 ?), 无法归因 |
| 1793480339 | 05:38:59 | sh | vendor-tree | sh /data/gw/fast_watch.sh 崩溃(1s 状态总线循环); 有 stack 窗口 |
| 1793489957 | 08:19:17 | v3httpd | our-tree | GUI httpd 崩溃; 有 stack 窗口; watchdog 会重启 |
| 1793494587 | 08:56:27 | awk | unknown | 一条 awk 单行程序崩溃; 有 stack 窗口 |

全部 4 条均已进 incidents.tsv(category=ne, SEV1) —— M1 覆盖 4/4。

> **口径更正**: 任务卡里的隔夜 21 条 NE 是**误计** —— 把 243 行历史碎片(NF<5)中
> 首列是 hold/END 等字符串的行, 按字符串比较当成 epoch 命中。按首列必须是纯数字过滤后,
> 04:33-09:30 实际 **4 条**。这正是台账脏行污染统计的实例。

### 10.2 隔夜重启情况(正面证据)

- reboots.log 自 2026-11-01 起只有 **1 条计划重启**(04:00:25), **零非计划重启**。
- soak_boots 台账 4 条: 10-31 23:59 clean / 11-01 02:55 crash(已归因 crash-root 内核实验)
  / 04:02 **scheduled** / 04:13 clean(state-truth 经 Lead 批准的验证性重启, drills 已标 maintenance-reboot)。
- 当前 uptime 连续 5h+ 且期间无崩溃重启。

## 11. 未决风险与下一步

1. **30d 未真正跑完**: 本报告只覆盖已运行样本; 装置会在无人值守下继续累积, 每日看 `soak.py daily`。
2. **自愈延时基线 90–120s**: watchdog 的 2-of-3 确认是固有延时(见 §6 耗时分布), 已作为架构修复的对照基线交给 Lead。
3. **非计划重启**: 见 §4.1; 历史 crash 类重启集中在已退役的内核实验模块窗口(2026-09-09..10-30), 需在模块退役后重新观察。
4. **M1/M3 台账未落地**: 相关判定记 unknown, 待 obs-ledger/svc-probe 交付后重跑本生成器即可自动补齐。

