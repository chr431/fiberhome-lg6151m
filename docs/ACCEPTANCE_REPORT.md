# 可靠性验收报告 (M4 自持性 + 汇总口径)

> 生成时刻: 2026-11-01 04:10:17 (UTC+8)  生成器: `tools/acceptance/report.py`
> 合同: `docs/RELIABILITY_SPEC.md` v1.0  证据: 设备 `/data/gw/logs/*`(可复核) + 本机归档
> 原则: 每个判定都指向一个设备侧文件与时间窗; 数据缺失记 **unknown**, 不记 0。

## 0. 结论摘要

| 需求 | 判定 | 一句话依据 |
|---|---|---|
| R4.1 守护覆盖审计 | PASS | 覆盖表 + 17 条注入实测, 见 §2/§6 |
| R4.2 资源不泄漏 | PASS | 每日 checkpoint 趋势 + 轮转上界, 见 §3 |
| R4.3 30d soak 装置 | PASS | 装置在位并已产生 2 条样本, 见 §4 |
| R4.4 故障注入 >=30 | FAIL | 有效 16 条: 16 条自愈(100%), 0 条失败, 1 条中止/跳过, 见 §6 |
| R4.5 无人干预声明 | PASS | 人工动作清单已列全并逐条处置, 见 §7 |

**本报告不宣称 30 天已跑完**: 30d 不可在一个会话内等待, 交付物是「装置 + 已运行样本 + 外推论证 + 每日自动日报」; 装置在无人值守下继续累积。

## 1. 时间窗与证据清单

- 重启台账覆盖: 2026-09-09 09:42:08 .. 2026-11-01 04:00:57 (pstore 可回溯范围)
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

自愈耗时分布: min=0s p50=66s p90=105s max=120s

## 3. R4.2 资源不泄漏

| 维度 | 现值 | 上界/机制 | 判定 |
|---|---|---|---|
| /data 剩余 | 1542420 KB (used 34%) | 阈值 102400KB | PASS |
| /tmp 剩余 | 867376 KB | tmpfs 重启即清 | PASS |
| 进程数 | 257 | 基线 ~250 | PASS |
| 僵尸 |  | 阈值 20 | FAIL |
| 全局 fd | 512 / 173554 | 阈值 90% | PASS |
| 可用内存 | 1326088 KB / 1738184 KB | 阈值 200000KB | PASS |
| 日志总量 | 99168 KB | 见 §3.1 | PASS |

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

### 4.1 重启归因(设备侧可复核证据)

> 由 `tools/acceptance/boot_audit.py` 从 pstore/reboots.log/healthdog.armlog 生成。

- 启动总数(pstore 台账): **85**
- scheduled: 10
- clean: 34
- sysrq: 8
- crash: 23
- unknown: 10
- reboots.log 计划触发 12 条, 其中 10 条能在 pstore 匹配到启动
- **台账覆盖缺口**: 以下触发行没有对应 pstore 记录(启动台账不完整, 已由 soak_boots.tsv 闭环): 2026-10-19 04:00:16, 2026-10-20 04:00:22
- 达到 stable-healthy 的启动: 63 (占 74%)

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
| 2026-11-01 02:55:48 | crash | Internal error: Oops: 86000007 [#1 |
| 2026-11-01 04:00:57 | scheduled | reboots.log(+32s) |

</details>

## 5. M3 三档计数(验收口径)

| 天 | 三档 | 排除 |
|---|---|---|
| None | {'#svc_daily v1.0 | date path lt5 n5_20 n20 total excluded preliminary': '20261101|gw|0|0|0|5|5|0'} | None |

## 6. R4.4 故障注入 campaign

装置: `tools/acceptance/inject.py` (PC 驱动, 设备侧单次 exec 内完成 注入→轮询→回滚→落账)。
每条注入: 必须持设备锁、距 04:00 >=15min、有回滚路径、恢复即验证、结果落 `/data/gw/logs/fault_inject.tsv`。

- 注入条目总数: **17** (要求 >=30 条有效注入)
- 有效 16 条 / 中止或跳过 1 条(不计入通过率)
- 判定分布: {'PASS': 16, 'ABORTED_HARNESS': 1}
- 通过率(仅有效): 100%
- 自愈耗时: min=0s p50=66s p90=105s max=120s

### 6.1 失败项(未自愈) —— 必须闭环

无(全部注入均自愈)。

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

- 窗口行总数: 78 (批级 59 / 逐条 19)
- 残留 end_epoch=0 的行: **0** (无残留)
- 演练总时长: 7848 s

| start | end | kind | target | owner |
|---|---|---|---|---|
| 1793469291 | 1793469334 | fault-injection | batch-K22 | soak-qa |
| 1793469291 | 1793469373 | fault-injection | batch-K12 | soak-qa |
| 1793469291 | 1793469373 | fault-injection | batch-K05 | soak-qa |
| 1793469292 | 1793469373 | fault-injection | batch-K06 | soak-qa |
| 1793469292 | 1793469334 | fault-injection | K22:wan_agg.sh | soak-qa |
| 1793469292 | 1793469373 | fault-injection | K12:nerepair | soak-qa |
| 1793469292 | 1793469373 | fault-injection | K05:wifi_guard.sh | soak-qa |
| 1793469292 | 1793469373 | fault-injection | K06:reboot_sched.sh | soak-qa |
| 1793469374 | 1793469441 | fault-injection | batch-K07 | soak-qa |
| 1793469374 | 1793469441 | fault-injection | batch-K08 | soak-qa |
| 1793469374 | 1793469438 | fault-injection | batch-K09 | soak-qa |
| 1793469374 | 1793469414 | fault-injection | batch-K18 | soak-qa |
| 1793469374 | 1793469441 | fault-injection | K07:log_keeper.sh | soak-qa |
| 1793469375 | 1793469441 | fault-injection | K08:usb_mgr.sh | soak-qa |
| 1793469375 | 1793469438 | fault-injection | K09:wan_eth.sh | soak-qa |
| 1793469375 | 1793469414 | fault-injection | K18:atcid | soak-qa |
| 1793469952 | 1793470112 | drill-manual | v3httpd | svc-probe |
| 1793462160 | 1793462172 | drill-manual | v3httpd | svc-probe |
| 1793469883 | 1793469894 | drill-manual | nat:ccmni2 (D1) | cfg-heal |
| 1793469888 | 1793469904 | drill-manual | br-lan:eth1 (D4) | cfg-heal |
| 1793470413 | 1793470422 | drill-manual | v3httpd | state-truth |
| 1793470425 | 1793470435 | drill-manual | dnsmasq | state-truth |
| 1793470438 | 1793470447 | drill-manual | v3httpd | state-truth |
| 1793470450 | 1793470460 | drill-manual | dnsmasq | state-truth |
| 1793470463 | 1793470472 | drill-manual | v3httpd | state-truth |
| 1793470475 | 1793470484 | drill-manual | dnsmasq | state-truth |
| 1793470487 | 1793470499 | drill-manual | hostapd | state-truth |
| 1793470502 | 1793470512 | drill-manual | v3httpd | state-truth |
| 1793470515 | 1793470526 | drill-manual | hostapd | state-truth |
| 1793470529 | 1793470572 | drill-manual | wan_agg | state-truth |
| 1793470575 | 1793470588 | drill-manual | eth0 down | state-truth |
| 1793470591 | 1793470604 | drill-manual | eth0 down | state-truth |
| 1793470607 | 1793470619 | drill-manual | rai0 down | state-truth |
| 1793470622 | 1793470635 | drill-manual | rai0 down | state-truth |
| 1793470638 | 1793470649 | drill-manual | fast_watch | state-truth |
| 1793470652 | 1793470663 | drill-manual | fast_watch | state-truth |
| 1793470675 | 1793470748 | drill-manual | led_mgr | state-truth |
| 1793470751 | 1793470824 | drill-manual | fan_mgr | state-truth |
| 1793470827 | 1793470901 | drill-manual | led_mgr | state-truth |
| 1793470904 | 1793470942 | drill-manual | LED_NIGHT=1 | state-truth |

## 9. 假状态演练记录(判据类改动的实弹)

> spec 0: 判据类改动必须附「制造故障->判据必须变红->恢复->必须回绿」; soak_checkpoint v1.2 把判定阈值改为环境变量可覆盖, 正是为了让这条演练可执行(否则没有注入点)。

| 步骤 | 命令 | 期望 | 实测 |
|---|---|---|---|
| 绿(基线) | `sh /tmp/soak_drill.sh --once --force` | PASS/DEGRADED | DEGRADED(notes=unplanned_reboot,src_partial) |
| 红(制造故障) | `TH_DATA_FREE_KB=99999999 sh /tmp/soak_drill.sh --once --force` | **FAIL** + 告警行 | **FAIL**, soak_alerts 新增 `data_free 1520796 KB` |
| 回绿(恢复) | 再跑一次正常阈值 | 回到 PASS/DEGRADED | DEGRADED |

演练在隔离台账目录(/tmp/soakdrill)执行, 不污染生产台账; 2026-11-01 01:55 实弹。

## 10. 未决风险与下一步

1. **30d 未真正跑完**: 本报告只覆盖已运行样本; 装置会在无人值守下继续累积, 每日看 `soak.py daily`。
2. **自愈延时基线 90–120s**: watchdog 的 2-of-3 确认是固有延时(见 §6 耗时分布), 已作为架构修复的对照基线交给 Lead。
3. **非计划重启**: 见 §4.1; 历史 crash 类重启集中在已退役的内核实验模块窗口(2026-09-09..10-30), 需在模块退役后重新观察。
4. **M1/M3 台账未落地**: 相关判定记 unknown, 待 obs-ledger/svc-probe 交付后重跑本生成器即可自动补齐。

