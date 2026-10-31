# 事故台账与分级留存（M1 / R1.1–R1.6）v1.0 · 2026-11-01

> 验收合同见 docs/RELIABILITY_SPEC.md §M1。本文是**运维与复核手册**：
> 台账怎么来的、每一列什么意思、留存怎么被证明、出问题怎么查。
> 一句话结论：**"任何可靠性事故都有持久化日志、严重事故 >7d、一般 >1d" 现在是
> 一条命令能反复验证的事实，不是承诺** —— 设备侧 sh /data/gw/retention_audit.sh，
> PC 侧 python tools/incident_audit.py（独立重算 + 落 _local/evidence/）。

## 1. 文件与角色

| 路径 | 角色 | 写入方 |
|---|---|---|
| /data/gw/logs/incidents.tsv | **事故台账**（append-only，8 列） | incident_ledger.sh |
| /data/gw/logs/incidents.seal | **留存证明**（每次追加/裁剪一行） | incident_ledger.sh |
| /data/gw/logs/incident_ledger.status | 最近一轮摄取状态（key=value） | incident_ledger.sh |
| /data/gw/logs/retention_audit.txt | 最近一次审计报告（人读） | retention_audit.sh |
| /data/gw/logs/retention_audit_history.tsv | 审计趋势（每次一行） | retention_audit.sh |
| /data/gw/logs/.inc/ | 每源游标（锚行 + 行序号） | incident_ledger.sh |
| /data/gw/logs/.inc_open | 未配对的降级开链（FAIL 等 OK） | incident_ledger.sh |
| /data/gw/logs/.inc_pending | pre-sync 缓冲（不写假日期） | incident_ledger.sh |
| /data/gw/logs/drills.tsv | 演练窗口标记（Lead v1.2 契约，soak-qa 写） | soak-qa |
| /tmp/incident_ledger.hb | 心跳（uptime 秒），审计判"台账是否还在跑" | incident_ledger.sh |

驱动：**没有新守护**。log_keeper.sh v2.12 的 5min 块 fork 一次 incident_ledger.sh
（与 avail_sampler 同款）。脚本带 svc_lock 单实例锁，手工审计与 tick 并发不会双写。

## 2. 台账数据模型（R1.1）

    ts <TAB> severity <TAB> category <TAB> component <TAB> duration <TAB> evidence_ref <TAB> detail <TAB> seq

| 列 | 语义 | 约定 |
|---|---|---|
| ts | 事件发生时刻 epoch（秒） | pre-sync 脏时钟行不写假日期，见 §5 |
| severity | SEV1 / SEV2 / SEV3 | 由 sev_of() 单点判定（§3） |
| category | 事故类别（固定词表） | ne / ke_panic / oom / boot_fail / svc_fail / svc_outage / svc_restart / netcfg_repair / netcfg_storm / degraded / reboot_planned / reboot_unplanned / clock / ledger_gap / disk_guard / retention |
| component | 归一组件名 | 小写+下划线+点；无法归属记 -（宁可少归属，不可错归属） |
| duration | 时长（秒） | - 表示未知（未配对/瞬时事件） |
| evidence_ref | 源内指针 <源>:<行序号> | 行序号随游标单调增长，可在源文件里定位 |
| detail | 细节（无 TAB/换行，≤300 字节） | 结构化键值 + 原始行摘要 |
| seq | **单调行身份** 1..N | 只增不减；裁剪会留缺口，缺口必须能在 seal 里对账（§4） |

前 7 列即合同字段，seq 是尾部扩展列（沿用本项目"新列只许加在行尾"的惯例）。

## 3. 分级：sev_of() 单点实现（R1.2）

合同口径：

| 级别 | 判据 |
|---|---|
| SEV1 | KE/panic、NE(SIGSEGV)、启动失败、服务中断 >20s、内核 OOM 杀进程 |
| SEV2 | 守护重启、中断 5–20s、网络修复风暴(>10 次/轮)、非计划重启、证据链断口 |
| SEV3 | degraded 迁移、一般事件、计划重启、单次网络修复、时钟跳变 |

实现是 shell 里一个 case 表（gw/incident_ledger.sh 的 sev_of），**唯一实现**，
--classify 可单独调用，--selftest 27 例表驱动断言（设备侧可直接跑）。

### 3.1 两套时长口径（必须分清，否则 SEV1 会被噪声淹没）

| 来源 | 时长分辨率 | 阈值 |
|---|---|---|
| svc_outage（avail_edges，2s 边缘侦测） | 2s | 合同字面：>20s=SEV1，5–20s=SEV2，<5s=SEV3 |
| svc_fail（watchdog FAIL/OK 配对） | **30s**（监督周期） | 按分辨率标定：>300s=SEV1，61–300s=SEV2，≤60s=SEV3 |

理由（实弹）：dp5g 一次丢包 = 一个 30–40s 的 FAIL 窗。若把 30s 分辨率直接套 20s 阈值，
单次探针抖动就是 SEV1 —— 而 SEV1 是要保留 90 天的最高档，会被噪声瞬间淹没。
合同 R1.2 的 20s 阈值建立在 M3 的 ≤1s 采样上（R3.1 定义"连续失败≥2 次"），
所以"真正的服务中断"由 svc_outage 按字面判 SEV1；watchdog 侧的降级窗用放大后的阈值，
且长窗（>5min）仍然升到 SEV1。

为什么不用 awk 打分表：busybox awk 的运行期数组在 1.36.1 上有约 1% SIGSEGV
（docs/SIGSEGV_ANALYSIS.md §11），分级器是热路径，不能踩这个坑。

## 4. 留存与"证明"（R1.3 / R1.4）

### 4.1 策略

| tier | TTL | 说明 |
|---|---|---|
| SEV3 | 7d | 合同下限 1d，本项目取 7d |
| SEV2 | 30d | 合同下限 1d |
| SEV1 | **永不自动删除** | 合同下限 7d；内部目标 90d，靠"永不删"自然满足 |

裁剪（prune）只按 TTL 进行，**每次裁剪都在 seal 里留一行**（op=prune + rm1/rm2/rm3）。
rm1 恒为 0 —— 审计把"SEV1 被裁剪过"当硬红线。

### 4.2 seal 行格式

    op=<append|prune> ts=<epoch> rows=<N> bytes=<B> md5=<台账整文件md5>
    first_seq=<n> last_seq=<n> sev1=<n> sev2=<n> sev3=<n>
    rm1=<n> rm2=<n> rm3=<n> oldest_sev1_ts=<ts> oldest_sev1_md5=<该行md5>
    reason=<tick|guard|retention_daily|manual...>

### 4.3 审计判什么（这就是"证明"）

1. **完整性**：台账当前 md5/行数/字节 == seal 末行 → 文件自上次记账以来没被改过。
2. **seq 连续性**：seq 必须 1..N 无重复无缺口；允许的缺口 = seal 里累计 rm1+rm2+rm3。
   等式 (first_seq-1 + 内部缺口) == 累计删除数 不成立即 FAIL —— **丢行必 FAIL，绝不静默通过**。
3. **SEV1 红线**：累计 rm1 必须为 0。
4. **留存龄**：各 tier 的 rows/bytes/oldest_age_days 对合同阈值判定：
   - PASS：最老记录龄 ≥ 合同下限
   - GROWING：未达龄，但台账自身也还不到合同龄（历史不够长，不是违规）
   - SHORT：台账够老而该级没有更老的行（无事件/被策略裁剪，**不算违规**）
   - NODATA：该级零行 —— 不能当 PASS
5. **最老 SEV1 行的连续性见证**：该行的 md5 必须能在 seal 历史里找到第一次被记录的时刻
   → 证明"你看到的那条 87 天前的 SEV1 就是当初记下的同一条"，不是后来补的。
6. 演练窗口单列（§6）、pre-sync 行数、回填行数、源侧脏行计数、心跳新鲜度。

总体判定：PROVEN（三级都 PASS 且完整性通过）/ PARTIAL（完整性通过但有 GROWING、
SHORT、NODATA）/ FAIL（完整性被破坏）。

### 4.4 诚实性边界（必须知道）

- seal 是**防篡改可发现**（tamper-evident），不是不可篡改：root 可以同时改写
  incidents.tsv 与 seal。真正的外部锚点是 **PC 侧 tools/incident_audit.py 每次运行
  写下的 _local/evidence/M1-retention-audit-<UTC>.md** —— 那份报告在设备之外，
  记录了当时的 md5/行数/seq 上界；设备事后被改写，旧报告仍然对得上旧事实。
- 因此**审计要定期在 PC 上跑**（建议每天一次，或纳入 soak 每日 checkpoint）。
- "历史不够长"（GROWING）不是通过，也不是失败：它如实说明"还没积累到合同要求的
  时长"。回填（§7）能把起点前移到源台账已有的历史。

## 5. 时间纪律（设备无 RTC）

开机时钟 = 固件构建日；ntp_keeper 首次对时成功才写 /tmp/ntp_synced。

- pre-sync 期间：新行只进 /data/gw/logs/.inc_pending（**不写任何带日期的行**）；
- 首次对时后：以 ts=<补记时刻> + detail 里 pre_sync=1 src_ts=<原始epoch> 补记 —— 不丢、不伪造；
- ne_events.tsv 里既有的 pre-sync 脏行（unsync=1 / epoch 过小）同样按 pre_sync 处理；
- ne_events.tsv 里 243 行"argv 内含换行"造成的断行残片（物理行不以"数字+TAB"开头）
  一律计数不入账，计数在 status 的 malformed_ne 与审计的 SOURCE_HEALTH 行可见。

## 6. 演练标记（Lead v1.2 跨流契约）

/data/gw/logs/drills.tsv 列：start_epoch end_epoch kind target owner note（写入方=soak-qa）。
台账行若落在任一演练窗口内：**仍然落账**（可溯源性不豁免），但 detail 前置 [drill]
并带 drill=1 drill_kind=<k> drill_owner=<o>。审计的 DRILLS 段一键列出全部窗口
（含 end_epoch=0 的未闭合窗口告警）与被打标的行数 —— 排除是**可审计的**，不是黑箱。

## 7. 首次回填（backfill）

台账首次运行（该源无游标）时有界回填最近 150 行（IL_BACKFILL_N 可调），
行 detail 带 backfill=1 —— 明确区分"当时记的"与"后来从源台账补的"。
一次性全量回填：删 /data/gw/logs/.inc/<源> 后以 IL_BACKFILL_N=3000 手工跑一次
（脚本单轮最多消费 MAX_ROWS 行，必要时重复跑）。

## 8. 崩溃前证据与死亡原因（R1.5）

台账的 boot 类行（category=boot_fail / reboot_planned / reboot_unplanned）在 detail 里
给出 death_reason=planned|unplanned 判定：把 /data/gw/boot_attempts.tsv 的每次开机
与 /data/gw/logs/reboots.log 的计划窗（±900s）比对 —— 有匹配=计划重启，无匹配=非计划。

崩溃现场本身由既有链路保存，台账只做**索引**：ne_events.tsv（core_meta 链，含
stack=/data/gw/logs/cores/meta/*.stack）、/data/gw/logs/pstore/（console-ramoops，
重启后仍在）、/data/gw/logs/dmesg.log 与 syslog.log 的尾部。审计的 BOOT_EVIDENCE
段列出最近 5 条 boot 行，可直接回答"上一次是怎么死的"。

## 9. 磁盘守卫（R1.6）

/data 剩余低于阈值时按 SEV3 → SEV2 顺序降级裁剪，**SEV1 永不自动删除**，
每次动作记一条 category=disk_guard（tier>=2 记 SEV2）的自保事件。

| tier | 触发 | 动作 |
|---|---|---|
| 1 | <300MB | 裁过期 SEV3（TTL 7d） |
| 2 | <200MB | 再加裁过期 SEV2（TTL 30d） |
| 3 | <100MB | 强裁：SEV2/SEV3 只保 1d |

裁剪同样在 seal 里留 op=prune 行（rm1 恒 0）。

## 10. 运维速查

    # 设备侧：留存审计（人读）
    sh /data/gw/retention_audit.sh
    # 设备侧：机器可读
    sh /data/gw/retention_audit.sh --json
    # 设备侧：分级器单测 / 审计单测
    sh /data/gw/incident_ledger.sh --selftest
    sh /data/gw/retention_audit.sh --selftest
    # 设备侧：台账状态（各源游标、未配对开链、末 5 行）
    sh /data/gw/incident_ledger.sh --status
    # PC 侧：独立重算 + 落证据
    cd lg6151m-public && python tools/incident_audit.py

排障顺序：
1. 台账不涨 → 看 /tmp/incident_ledger.log（log_keeper 会镜像到 /data/gw/logs/tmp/）与
   /tmp/incident_ledger.hb 的年龄（>1800s = 5min tick 没跑起来）；
2. 审计 FAIL md5/rows → 有人手改了台账或写了未记账的行；
3. 审计 FAIL seq 缺口未记账 → 被轮转/删行（查 log_keeper 轮转、attic、磁盘满）；
4. gaps 计数涨 → 某源轮转两代都找不到锚行（断口已如实记账，不是静默丢失）。

## 11. 已知限制

1. watchdog FAIL/OK 只有 30s 分辨率：<30s 的闪断靠 avail_edges（2s）与 M3 的
   svc_outages 兜；台账只是把它们归一到同一张表。
2. 台账本身跑在 log_keeper 的 fork 里：log_keeper 死 → 台账停 → 审计的
   ledger_hb_age 会涨（审计不判 FAIL，但 SOURCE_HEALTH 与 QUALITY 行可见）。
3. seal 不能防 root 同时改账与改 seal（见 §4.4），外部锚点靠 PC 侧报告。
4. 演练窗口只能标注，不能事后纠正已写入的行（append-only 的代价）；因此
   drills.tsv 必须在注入**前**写行。
