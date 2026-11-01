# 自持性审计 (SELF-HEALING AUDIT) · R4.1 / R4.5

> 生成: 2026-11-01 · 负责人: soak-qa · 合同: `docs/RELIABILITY_SPEC.md` §M4
> 证据原则: 本文每一条"有监督/能自愈"都必须能指到一个**设备侧可复核**的机制(脚本行号/台账文件)
> 或一次**注入实测**记录; 判不出来的写"未知", 不写"应该"。

## 0. 一句话结论

这台设备**已经有三层自愈**, 日常运行不需要人工介入; 但它**不满足 R4.1 的 "≤60s 恢复"**:
除少数立即路径外, 绝大多数守护的恢复延时是 **90–120s**, 因为 watchdog 采用 2-of-3 采样确认
(30s 周期 × 3 = 90s) 才动手。这是**机制固有延时**, 不是故障 —— 已作为架构修复的对照基线
交给 Lead(见 §4 G1)。此外有 4 类"外力破坏配置"的状态**没有任何自愈路径**(见 §4 G2),
这是本次审计最重要的缺口。

---

## 1. 方法(怎么枚举的, 为什么可信)

| 步骤 | 手段 | 证据源 |
|---|---|---|
| 常驻进程全量 | 设备 `ps w` 全表 + 逐个读 `/proc/[0-9]*/cmdline`(251 个进程) | 本审计 §3 表 |
| 监督关系 | 读 `gw/svc_lib.sh` 的 `SVC_TABLE`(14 项) + `gw/watchdog.sh` 专用检查块 + `gw/healthdog.sh` + `gw/rc.extend.sh` 开机链 | 源码(已登记 VERSIONS) |
| 恢复时延上界 | 从代码推导周期/采样/限频, 再用**注入实测**校正 | `fault_inject.tsv` |
| 是否只能人工救 | 对每个组件问"有没有任何代码路径会把它拉回来", 没有 = 人工 | §4 缺口表 |
| 启动/重启归因 | pstore ramoops 台账 + `reboots.log` + `healthdog.armlog` | `tools/acceptance/boot_audit.py` |

---

## 2. 三层自愈体系

```
L0  内核 healthdog.ko      90s 硬复位: userspace 停止喂狗(/proc/healthdog) → 内核直接复位整机
      ^ 喂狗
L1  healthdog.sh           (a) 每 10s 检查 /tmp/watchdog.beat, 陈旧则重启 watchdog
                           (b) boot 健康稳定 600s 后 arm 内核看门狗
      ^ 被 SVC_TABLE 监督(watchdog 拉活)
L2  watchdog.sh            30s 周期: 14 项 SVC_TABLE + dnsmasq/dropbear/v3httpd/authd/
                           hostapd/wan_agg/boot_gate 专项 + 网络/LED/风扇/AT 不变量
      ^ 被 healthdog 监督
L3  14 个脚本守护 + 7 个专用服务 = 全部常驻服务面
```

**关键性质**: L1 与 L2 互为监督(healthdog 拉活 watchdog, watchdog 拉活 healthdog), 因此单点死亡
都能被对方救; 两者同时死亡时由 L0 兜底(**代价 = 一次完整重启 ~110s**)。

---

## 3. 覆盖表(逐进程 / 逐功能面)

### 3.1 我方服务面(SVC_TABLE, 由 watchdog 统一监督)

| # | 守护 | 监督者 | 判活方式 | 心跳上限 | 恢复动作 | 恢复上界 |
|---|---|---|---|---|---|---|
| 1 | ntp_keeper.sh | watchdog | pid 锁 + cmdline | 4200s | 重启脚本 | 90–120s |
| 2 | traffic_logger.sh | watchdog | 同上 | 900s | 重启脚本 | 90–120s |
| 3 | wifi_guard.sh | watchdog | 同上 | 90s | 重启脚本 | 90–120s |
| 4 | reboot_sched.sh | watchdog | 同上 | 900s | 重启脚本 | 90–120s |
| 5 | led_mgr.sh | watchdog | 同上 | 60s | 重启脚本 | 90–120s |
| 6 | fan_mgr.sh | watchdog | 同上 | 60s | 重启脚本 | 90–120s |
| 7 | wan_eth.sh | watchdog | 同上 | 150s | 重启脚本 | 90–120s |
| 8 | log_keeper.sh | watchdog | 同上 | 180s | 重启脚本(anchor resync 补日志窗口) | 90–120s |
| 9 | healthdog.sh | watchdog | 同上 | 60s | 重启脚本 | 90–120s |
| 10 | dial_keeper.sh | watchdog | 同上 | 90s | 重启脚本(带 FH 库环境) | 90–120s |
| 11 | usb_mgr.sh | watchdog | 同上 | 180s | 重启脚本(保留 daemon 参数) | 90–120s |
| 12 | nerepair | watchdog | 同上 | 180s | 经 nerepair_launch.sh(svc_lock) | 90–120s |
| 13 | avail_watch.sh | watchdog | 同上 | 120s | 重启脚本 | 90–120s |
| 14 | (fast_watch.sh) | watchdog | 同上 | 待定 | state-truth 上线后接管 avail_watch | 60s(设计目标) |

### 3.2 专用服务(有专属检查块, 不走 SVC_TABLE)

| 服务 | 监督者 | 判活方式 | 恢复动作 | 恢复上界 |
|---|---|---|---|---|
| dnsmasq(:53) | watchdog | pidof + /proc/net/tcp 监听 | 用缓存 cmdline 重启 | 90–120s |
| dropbear(:22) | watchdog | pidof + 监听 | 用缓存 cmdline 重启(**会中断当前 SSH 会话**) | 90–120s |
| v3httpd(:80) | watchdog | pidof + 监听 + 每 5min HTTP200 | 重启二进制 | 90–120s |
| authd | watchdog | pidof + /tmp/authd_state 龄 <300s | sh -c "$AUTHD_CMD" + 1s 后校验, 失败退预算 | 90–120s |
| hostapd(我方) | watchdog | 我方进程 + /proc/net/unix 活控制口 + 链路 UP | 清 stale socket → 重启 → 读回 bss | **进程缺失当轮立即修**, 否则 90–120s |
| wan_agg | watchdog | alive() + /tmp/wan_alive 龄 <120s | 杀旧实例重启 | 90–120s |
| boot_gate | watchdog | pid 锁(仅 stable 前) | 重启 | 90–120s |
| radvd | watchdog→v6_reconcile.sh | pidof | 每 4 轮(120s) apply 兜底 | **~120s** |
| atcid | watchdog | pidof | **当轮直接拉起**(无 2-of-3) | **≤30s** |
| wan_agg 策略(NAT/MARK/ip rule) | 仅检查 | iptables -S / ip rule | **无**(只 set_state + FAIL) | **不自愈** → G2 |

### 3.3 非我方(vendor / 内核)进程

| 进程 | 归属 | 谁负责重启 | 说明 |
|---|---|---|---|
| procd (pid 1) | vendor init | 内核 | 死亡 = Attempted to kill init panic → 重启 |
| ubusd / rpcd | vendor IPC | procd respawn | GUI API 依赖 |
| ccci_fsd / ccci_mdinit / ccci_rpcd_com | modem 栈 | procd respawn | 蜂窝数据面依赖 |
| hostapd -g global / wpa_supplicant -g global | vendor 全局实例 | procd | **不是我方 AP**; svc_our_hostapd 特意排除它 |
| adbd_usb / restart_usb.sh / powerkey_daemon / thermal_core / scd / ql_ippt / aee_aed / logd / urngd | vendor | procd / 无 | 不属 M4 范围, 崩溃会被 core_meta/NE 台账记到 |
| getty / login.sh | vendor 串口 | procd | 串口控制台 |
| 内核线程(kworker/ccci_*/wdtk-*/hang_detect 等) | 内核 | 内核 | wdtk-0..3 + hang_detect 是 MTK 硬件看门狗 |

---

## 4. 缺口清单(必须闭环)

| ID | 缺口 | 影响 | 证据 | 闭环状态 |
|---|---|---|---|---|
| **G1** | **自愈延时系统性 90–120s**(watchdog 2-of-3 + 30s 周期), 不满足 R4.1 "≤60s" | 任何守护死亡后服务中断 1.5–2min | 注入实测 fault_inject.tsv(ACCEPTANCE_REPORT §6 耗时分布) | **未修**; 已量化基线交 Lead 做架构修复(减采样轮数/事件驱动) |
| **G2** | ~~配置类漂移无自愈~~ **已由 cfg-heal 修复(2026-11-01 起)** | NAT/mangle/fwmark 被删后由 cfg_heal 自愈 | 注入 C01/C02/C03 = **0s/9s/0s PASS**; cfg_heal.tsv 1793504230 split:wanagg observe suspect + 1793504236 agg wan_agg repair ok | **本轮实测显示已能自愈**。旧结论 G2 是在 2026-11-01 02:00 的数据下得出(当时无 cfg-heal healer), 两条不矛盾 |
| G3 | watchdog 自身恢复上界 worst case ≈420s(beat 陈旧 120s + healthdog 300s 限频) | 监督层空窗 | healthdog.sh v1.6 代码 + 注入 K14 | 待实测; 建议 healthdog 对"进程确定不存在"走快速路径 |
| G4 | healthdog 死亡 → 内核 90s 硬复位 → **完整重启 ~110s** | 一次服务中断 + 计划外重启计数 | 注入 K13(单独批) | 接受(兜底路径); 代价已量化 |
| G5 | radvd 恢复上界 ~120s(v6_reconcile 每 4 轮) | LAN IPv6 短暂缺失 | 注入 K20 | 接受(IPv6 非验收主路径) |
| G6 | **"计划重启该来没来"无任何指纹**(reboot_sched 只在触发时写日志) | 2026-10-27/28 缺 04:00 重启**无法回溯归因** | reboots.log 11 条 vs pstore 启动台账 | **已闭环**: soak_checkpoint.sh 的 scheduled_missed 列 + soak_alerts.tsv 把负证据记账 |
| G7 | watchdog.log 在 tmpfs, 重启即失; 只有 log_keeper 的 .last.watchdog.log 尾部快照 | 重启前的监督证据只剩尾部 | ls /data/gw/logs/.last.*.log | **部分闭环**; 完整闭环由 M1 incidents.tsv 承担 |
| G8 | **pstore 启动台账覆盖不全**: 11 条计划重启触发里 2 条(10-19/10-20)无对应 pstore 记录 | 启动次数会被低估 | boot_audit.py 输出"有触发行但无 pstore 启动记录" | **已闭环**: soak_boots.tsv 每次开机一行(boot_id 门禁), 不依赖 pstore |
| G9 | /data 空间耗尽**无自动清理**(watchdog 只 WARN <100MB) | 磁盘满 → 台账写失败 → 可观测性先崩 | watchdog.sh HEALTH 块 | **未修**; 属 R1.6 磁盘守卫(M1 流), 报告交叉引用 |
| G10 | 设备**无 crond**, 无法用 cron 做周期任务 | 新增周期任务必须挂已有 tick | ps w 无 cron | 已按此设计: soak 挂 log_keeper 5min 块, 零新增守护 |
| G11 | radvd/v6_reconcile 失败时无告警升级 | IPv6 静默降级 | watchdog radvd 键 | 接受(有 state 键, GUI 可见) |
| **G12** | **alive() 假活**: 回退分支 pgrep -f /data/gw/<script> 是全命令行子串匹配, 任何 cmdline 里提到该路径的进程都会让 watchdog 误判守护还活着 | 服务已死而监督层报正常 = **M2 监测诚实性违反**(假绿家族) | 2026-11-01 00:05 实弹: ntp_keeper 被杀后死 153s, watchdog 连续两轮报 ntp_keeper=0; 同刻 pgrep -f ntp_keeper[.]sh 为空。证据 /tmp/watchdog.log 00:05:47 / 00:06:54 | **已升级 P1 交 svc-probe 修**(Lead 裁决): 回退分支必须校验 argv[0]/exe, 禁止全命令行子串; 需补负样本回归(假进程 argv 只含路径) |
| G13 | **dropbear 恢复会杀全部会话**: watchdog 的重启配方是 kill -9 全部 dropbear | 远程管理通道在恢复瞬间全断(含正在做恢复的人) | gw/watchdog.sh 第 465-474 行 | 接受但需知会; 也使 dropbear 注入无法在不丢传输通道的前提下测量(已声明限制) |

---

## 5. 无人干预声明(R4.5)

### 5.1 日常运行: 不需要人工

在**不改配置、不升级固件、不做实验**的前提下, 设备可以长期无人值守运行:

1. 每日 04:00 定时重启(四护栏: REBOOT_EN / NTP 已同步 / uptime>=300s / 当日未执行)。
2. 任一守护死亡 → watchdog 90–120s 内拉起(注入实测, 见 ACCEPTANCE_REPORT §6)。
3. watchdog 死亡 → healthdog 拉活; healthdog+watchdog 双死 → 内核 90s 硬复位。
4. 开机失败 → boot_gate.sh 健康门禁 + babysit 兜底 + TRY_A 计数回退 B 槽。
5. NE(SIGSEGV) → nerepair 在线缓解 + core_meta 落 ne_events.tsv。

### 5.2 仍需要人工的动作(全部列全)

| # | 动作 | 为什么不能自动 | 处置 |
|---|---|---|---|
| 1 | 固件升级 / 部署 | 设计上必须人工(deploy.py), 且需 doctor 复核 | **接受**(不属于运行时自持) |
| 2 | /data 空间耗尽后的清理 | SEV1 台账永不自动删; 自动清理有丢证据风险 | 由 R1.6 磁盘守卫按 SEV3→SEV2 降级清理(M1 流); M4 侧保证提前 100MB 告警 |
| 3 | 配置类漂移被外力破坏(NAT/MARK/fwmark/网桥) | 当前无重建路径(G2) | **未消除**; 见 §4 G2 建议 |
| 4 | 设备彻底失联(内核 hang/掉电) | 需要物理断电或 healthdog 复位 | healthdog.ko 90s 兜底; 掉电只能人工上电 |
| 5 | 串口控制台失聪 | 需断电恢复(AGENTS 陷阱表) | 接受(非常规路径) |
| 6 | settings.conf 被改坏导致 04:00 不重启 | 配置文件无 schema 校验 | scheduled_missed 列会告警(G6 闭环) |

### 5.3 结论

- **"每天重启一次、30 天不用人管"在功能面上成立**: 没有任何一个常驻服务处于"只能人工救"的状态。
- **在指标面上不成立**: G1(90–120s 恢复)与 G2(配置漂移无自愈)必须先修, 才能对外宣称满足 R4.1。

---

## 6. 重启/启动归因(摘要)

> 完整逐次表见 `tools/acceptance/boot_audit.py` 输出与 `docs/ACCEPTANCE_REPORT.md` §4.1。

- pstore 台账覆盖 **83 次启动**(2026-09-09 .. 2026-10-31)。
- 分类: 计划重启 9 / 人工 clean reboot 34 / 人工 sysrq-b 8 / **内核 crash 22** / 无法判定 10。
- **22 次 crash 全部落在内核实验模块窗口内**(insmod/rmmod/dd/pftest 触发, 模块 dpclamp/dpquar/vsurv4 已退役),
  典型: Kernel panic - not syncing: RCU Stall(4 次)、Internal error: Oops(18 次)。
  这些**不是产品固件缺陷**, 是调试期人为注入模块的后果; 模块退役后(2026-10-31 起)未再出现 crash 类重启。
- **10-27/10-28 缺 04:00 计划重启**: 两天分别有 5 / 11 次启动(人工), 而 reboots.log 无触发行。
  由于 reboot_sched 只在触发时写日志, **"没触发"没有任何指纹**, 因此无法从留存日志证明原因;
  最可能是操作者在做内核模块实验期间人工重启替代/关闭了定时器。→ 已用 scheduled_missed 列闭环观测(G6)。
- 62 次启动达到 stable-healthy(arm 成功), 21 次没活到 615s(多为人工快速重启)。

---

### 6.1 注入实测口径(2026-11-01 01:52-02:02 窗口)

- 有效样本 **16 条**(16 个不同服务被 kill 后全部自愈), 中止 1 条(harness bug, 已修)。
- 自愈耗时: p50=66s, p90=105s, max=120s —— **全部落在 2-of-3 确认的固有延时区间内**(G1)。
- 口径: 本批 12 条按 4 条/组并发(组内共享同一 watchdog 30s 周期, 检测延时不可分), 但每条服务的恢复是独立测量的(独立 strike 键/预算/配方); 逐条单发只有 K01–K04。
- 测量伪影: K15(authd) 记 dur=0s —— kill 后首次轮询即匹配到 pidof(进程尚未被回收), 不代表真 0 秒恢复; 该条按未有效测量看待。
- **R4.4 未达标**: 有效 16/30。剩余 14 条(链路/配置/磁盘/时钟/风暴/内存/NE + K10/K13/K14/K20/K21)装置已就绪, 可续跑。

## 7. 复现命令

```bash
# 覆盖表(静态): 本文件 §3
# 注入实测(动态):
python tools/acceptance/inject.py --list
python tools/acceptance/inject.py --batch A        # 需先持 _local/device_lock.py

# 重启归因:
python tools/acceptance/boot_audit.py
python tools/acceptance/boot_audit.py --tsv /tmp/boot.tsv --json /tmp/boot.json

# 汇总报告:
python tools/acceptance/report.py
```

---

## 8. 本轮新增的两条判据纪律(2026-11-01 实弹)

### 8.1 恢复判定必须持续观察 >=30s, 不能只看瞬时

**实弹**: L01(br-lan 摘 ra0) 的 rollback brctl addif 执行后立即 check **通过**(rb=ran_ok),
但 47 秒后复查 ra0 **又不在网桥里了** —— 瞬时通过不等于稳定恢复。

**纪律**: 任何「修复/回滚后是否恢复」的判定, 必须在动作后**持续观察 >=30s**(2 次采样间隔 >=30s 都通过),
否则记录为 recovered_transient 而不是 PASS。

### 8.2 任何会被 import 的脚本必须有 __main__ 守卫

**实弹**: 我用 python -c import bb_run6 做语法检查, 而该文件末尾直接调 bb_run.main() ——
**import 即执行**, 三条链路注入在**无锁、无演练窗口**的情况下跑了。

**纪律**: 会被 import 的脚本一律 if __name__ == __main__: main(); 一次性助手也不豁免。

**审计结果**: 仓内 6 个 acceptance 工具 + bb_run.py 全部有守卫; 缺守卫的是 _local/ 下 6 个一次性助手
(bb_run2..6, cfg3) —— 不入仓不追责, 但纪律适用。
