# 验收口径与运行手册 (ACCEPTANCE) · M4 自持性

> 合同: `docs/RELIABILITY_SPEC.md` §M4 (R4.1–R4.5)
> 覆盖审计: `docs/SELF_HEALING_AUDIT.md`   汇总报告: `docs/ACCEPTANCE_REPORT.md`
> 负责人: soak-qa

本文回答三件事: **口径是什么 / 怎么复现 / 怎么让它自己继续跑 30 天**。

---

## 1. 口径

### 1.1 "自持"的定义

> 在**每天一次定时重启**的前提下, 设备能连续 **>30 天**不需要人工干预。

拆成可测量的四个量:

| 量 | 判据 | 数据源 |
|---|---|---|
| 无人干预 | 没有任何"只能人工救"的状态被触发 | `SELF_HEALING_AUDIT.md` §5 人工动作清单 |
| 自愈有效 | 注入的每一类故障都能在有限时间内自动恢复 | `fault_inject.tsv` |
| 资源有界 | /data、/tmp、fd、内存、日志在 30d 尺度不单调增长 | `soak_daily.tsv` 趋势 |
| 重启可解释 | 每次启动都有原因判定与证据源 | `soak_boots.tsv` + `boot_audit.py` |

### 1.2 判定阈值(集中定义, 改这里就够)

| 项 | 阈值 | 出处 |
|---|---|---|
| /data 剩余 | ≥102400 KB (100MB) | `gw/soak_checkpoint.sh` TH_DATA_FREE_KB |
| 全局 fd 使用率 | <90% | TH_FD_PCT |
| 僵尸进程 | ≤20 | TH_ZOMBIES |
| 当日 checkpoint 的 uptime | ≥600s(否则判 boot loop) | TH_UP_MIN |
| 24h crash 类重启 | 0(≥1 即 FAIL) | TH_CRASH |
| 注入通过率 | 100%(任何 FAIL 必须闭环) | spec R4.4 |
| 注入条数 | ≥30 | spec R4.4 |

### 1.3 排除规则(哪些不算故障)

- **计划重启**: `reboots.log` 触发行 ±600s 内的启动, 判 `cause=scheduled`, 不计入非计划重启。
- **演练注入**: `drills.tsv` 窗口内的中断, 由 svc-probe/state-truth/obs-ledger 打 excluded,
  不计入 M3 三档验收计数; 报告 §8 单列, 保证"排除可审计"。
- **上游供应商中断**: 属 M3 口径, 本流只消费。

---

## 2. 台账格式(全部 append-only, 首行是列名)

### 2.1 `/data/gw/logs/soak_daily.tsv` — 每日一行

| 列 | 含义 | 缺失时 |
|---|---|---|
| day | 本地日期 `YYYY-MM-DD` | — |
| epoch / up_s / boot_id / boot_epoch | 记录时刻 / 本次 uptime / 本次 boot_id / 内核 btime | — |
| boots_24h / boots_sched_24h / boots_unplanned_24h | 24h 内开机次数 / 其中计划 / 非计划 | -1 |
| **scheduled_missed** | 1 = 今日 04:00 已过但 `reboots.log` 无触发行(**负证据**) | 0/1 |
| data_used_kb / data_free_kb / data_used_pct | /data 用量 | -1 |
| tmp_free_kb / logs_kb | /tmp 剩余 / `/data/gw/logs` 总量 | -1 |
| procs / zombies | 进程数 / 僵尸数 | -1 |
| fd_used / fd_max | `/proc/sys/fs/file-nr` | -1 |
| mem_avail_kb / mem_total_kb / load1 | 内存与负载 | -1 |
| ne_24h / ne_total | 24h NE 行数 / 累计 NE 行数 | -1 |
| repairs_24h | 24h 网络修复行数 | -1 |
| svc_lt5_24h / svc_5_20_24h / svc_gt20_24h | M3 三档中断计数(来自 `svc_daily.tsv`) | -1 |
| incidents_24h / sev1_24h / sev2_24h / sev3_24h | M1 台账计数 | -1 |
| verdict | PASS / DEGRADED / FAIL | — |
| notes | 触发的判定项(逗号分隔) | ok |

> **诚实性纪律**: 任何数据源缺失写 `-1`(未知), **绝不写 0** —— 0 表示"确认没有发生"。

### 2.2 `/data/gw/logs/soak_boots.tsv` — 每次开机一行

| 列 | 含义 |
|---|---|
| epoch / iso | 记录时刻 |
| boot_id | `/proc/sys/kernel/random/boot_id` |
| btime | 内核 btime |
| up_at_record_s | 记录时 uptime |
| prev_boot_id | 上一次记录的 boot_id |
| **cause** | scheduled / clean / sysrq / crash / unknown |
| **cause_evidence** | 判定依据(具体文件 + 尾行特征) |

判定算法(见 `gw/soak_checkpoint.sh` `boot_cause()`):
1. 先查 `reboots.log` 是否有 ≤600s 前的触发行 → `scheduled`;
2. 否则读 `/data/gw/logs/pstore/console-ramoops.<当前boot_id>.txt` 的尾行
   (ramoops 在**本次**启动时保存**上一次** boot 的 console, 文件名带的是当前 boot_id → 精确对应);
3. 尾行含 `Kernel panic` / `Internal error` / `Unable to handle kernel` → `crash`;
   含 `procd: reboot` / `Restarting system` → `clean`;
   含 `SMP: stopping secondary CPUs` → `sysrq`;
4. 都没有 → `unknown`(不猜)。

### 2.3 `/data/gw/logs/soak_alerts.tsv` — 漂移告警

`epoch <TAB> day <TAB> rule <TAB> detail`; 每条规则每天最多一行(去重), 同时 `logger -t soak` 落 syslog。

### 2.4 `/data/gw/logs/fault_inject.tsv` — 注入明细

`epoch iso id class target pre_ok recovered dur_s maxw_s rebooted verdict evidence`
- `pre_ok=0` → 注入前目标本来就不在 → `verdict=SKIP_NOPRE`(不算失败, 但也不计通过)。
- `verdict` ∈ PASS / PASS_REBOOT(靠重启恢复, 要单独看) / FAIL / SKIP_NOPRE。

### 2.5 `/data/gw/logs/drills.tsv` — 演练窗口(**跨流契约**, Lead v1.2)

`start_epoch <TAB> end_epoch <TAB> kind <TAB> target <TAB> owner <TAB> note`
- 写入方: **只有 soak-qa**(他人演练用 `kind=drill-manual` 并先报 Lead)。
- 规则: 注入前写 start(end_epoch=0), 恢复确认后**原子回填** end_epoch; 每批结束不得留 0。
- 消费方: svc-probe(中断打 excluded) / state-truth(迁移打 drill=1) / obs-ledger(incidents 打 [drill])。

---

## 3. 复现命令

```bash
# ---- 设备侧(只读, 不需要锁) ----
sh /data/gw/soak_checkpoint.sh --status      # 看最近台账
sh /data/gw/soak_checkpoint.sh --once        # 立刻补一条日行(幂等)
sh /data/gw/soak_checkpoint.sh --boot        # 立刻记一次开机(幂等)

# ---- PC 侧 ----
cd lg6151m-public
python tools/acceptance/soak.py pull         # 归档到 _local/evidence/soak/<UTC>/
python tools/acceptance/soak.py trend --days 30
python tools/acceptance/soak.py alert        # 退出码非 0 = 有漂移
python tools/acceptance/soak.py daily        # 人读日报

python tools/acceptance/boot_audit.py        # 重启归因(逐次)
python tools/acceptance/report.py            # 生成 docs/ACCEPTANCE_REPORT.md

# ---- 注入(必须持锁 + 避开 04:00±15min) ----
cd .. && python _local/device_lock.py acquire --owner soak-qa --purpose "R4.4 injection"
cd lg6151m-public && python tools/acceptance/inject.py --list
python tools/acceptance/inject.py --batch A          # 18 条 kill 常驻守护
python tools/acceptance/inject.py --batch B          # 链路/配置/磁盘/时钟/风暴/内存/NE
python tools/acceptance/inject.py --batch C          # watchdog + fast_watch(单独)
python tools/acceptance/inject.py --batch D          # healthdog(最后、单独、60s 内确认)
cd .. && python _local/device_lock.py release --owner soak-qa
```

---

## 4. 怎么让它自己继续跑 30 天(无人值守)

1. **设备侧**: `gw/soak_checkpoint.sh` 由 `gw/log_keeper.sh` 的 5min 块 fork 驱动:
   ```sh
   [ -x /data/gw/soak_checkpoint.sh ] && sh /data/gw/soak_checkpoint.sh --tick >/dev/null 2>&1 || true
   ```
   脚本自身节流到每 24h 一条日行; 每次调用都会做一次 boot_id 比较(约 20ms), 因此**每次开机都会被记到**。
   不新增常驻守护、不新增高频探针(Lead 裁决 v1.1)。
2. **PC 侧(可选, 但建议)**: 每天一次
   ```bash
   python tools/acceptance/soak.py pull && python tools/acceptance/soak.py alert
   ```
   失败(退出码非 0)即漂移告警。PC 不在场也不影响设备侧累积 —— 台账在 `/data` 上, 重启不丢。
3. **看进度**: `python tools/acceptance/report.py` 随时重新生成验收报告。

---

## 5. 30 天怎么外推(为什么现在就能给结论)

30 天无法在一个会话里等完, 所以交付物是 **装置 + 已运行样本 + 外推论证**:

| 论点 | 依据 |
|---|---|
| 资源不会单调涨 | 每类日志都有**硬上界**(syslog/dmesg 4MB×2、/tmp 镜像 1MB/文件、nerepair 1MB、toolfaults 256KB、pstore 每 boot 262KB); 上界之和 << /data 余量 1.5GB |
| 不会因为"跑久了"而失效 | 所有守护用 **uptime 时基**的预算窗(免疫 NTP 跳变), 预算每小时复位; 无进程内累计计数器依赖长运行 |
| 每次重启都能解释 | `soak_boots.tsv` 每 boot 一行 + 证据源; 计划重启漏触发会被 `scheduled_missed` 抓到 |
| 故障会自己好 | 37 类注入实测(§ACCEPTANCE_REPORT §6), 失败项必须闭环后才算通过 |
| 不会假绿 | 数据源缺失写 -1; 判定分 PASS/DEGRADED/FAIL 三级; 负证据(该来没来)也记账 |

**已知不能外推的部分**(必须在报告里显式列出):
- 未覆盖的故障类型(如真实掉电、Flash 坏块、内存硬件劣化)无法在实验室注入;
- 自愈延时 90–120s 的架构缺口(G1)与配置漂移无自愈(G2)是**实测结论**, 不是外推。

---

## 6. 已知限制

1. `soak_boots.tsv` 是**前向台账**(从 v1.0 部署起算), 历史启动用 `boot_audit.py` 从 pstore 回溯。
2. pstore 台账本身有覆盖缺口(11 条计划触发里 2 条无记录), 所以两套台账必须并存。
3. `--tick` 依赖 log_keeper 存活; log_keeper 死亡期间(90–120s)不开机也不会漏记(下次 tick 会补 boot_id 变化)。
4. 注入工具当前只覆盖 kill/链路/配置/磁盘/时钟/风暴/内存/NE 八类; 掉电与硬件故障不在其中。
