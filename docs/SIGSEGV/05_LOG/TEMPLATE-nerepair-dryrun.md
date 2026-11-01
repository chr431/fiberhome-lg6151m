# dry-run 报表 · nerepair v1.9.1（24 h）· <YYYY-MM-DD>

> **填写规则**：只填 `<>` 和表格空行；**不要改判据文字**。判据出处：[2026-11-01-fix-design.md](2026-11-01-fix-design.md) §1.5（读数口径）/ §1.6（G0–G6）。
> 数值部分可先用 `python _local/work/crash-root/fix/dryrun_report.py <nerepair.log> > 报表草稿.md` 预填，再人工复核与补齐判断列。
> 报告落地文件名遵循 [README](README.md)：`YYYY-MM-DD-NN-nerepair-dryrun.md`。

---

## 0. 元数据

| 项 | 值 |
|---|---|
| 设备 boot id / uptime（起、止） | <boot_id> / <uptime_start> → <uptime_end> |
| 固件 / 内核 | <fw> / <uname -a> |
| nerepair 版本行（START） | `<粘贴 START 一整行>` |
| nerepair 二进制 md5 | <md5> |
| 部署时刻（epoch / 本地时间） | <epoch> / <iso> |
| 观测窗（epoch / 本地时间） | <start> → <end> |
| drill id / 窗口类型 | <drill-id> |
| 执行人 / devop ACQUIRED–RELEASED | <name> / <粘贴配对行> |

### 0.1 部署前后核对（交接单，缺一项本窗作废）

| 项 | 部署前 | 部署后 | 通过 |
|---|---|---|---|
| `ps` nerepair pid | <pid> | <pid> | <Y/N> |
| `ls -l /proc/<pid>/exe` inode | <ino> | <ino> | <Y/N> |
| 日志末行 epoch / 内容 | <epoch> `<行>` | <epoch> `<行>` | <Y/N> |
| START 行 `ver=` / `dry=` | — | <ver>/<dry> | 必须 `1.9.1`/`1` |
| 部署后 60 s 内一条 STAT `mode=` | — | <mode> | 必须 `dry` |
| STAT `attached=` 是否 ≥ 部署前 | <n> | <n> | <Y/N> |

---

## 1. 观测窗与数据完整性

| 项 | 值 | 判据 |
|---|---|---|
| 窗口时长 | <h> h（<start_human> → <end_human>） | ≥24 h（G0） |
| 日志行数：设备 `wc -l` / 主机实取 | <dev> / <fetched> | **必须相等**（不等即重取） |
| 轮转文件数（.log + .log.1） | <n> | 记录 |
| STAT 心跳间隔最大值 | <s> s | <180 s（G0） |
| `>180 s` 的心跳缺口 | <k> 个：<逐条列 epoch 与时长> | 有缺口必须解释 |
| `suppressed`（被限速丢弃的行数） | <n> | 记录；REPAIR/WOULD 已独立预算 |
| 非计划重启 / 掉电 | <n> 次 | 有则本窗分段统计 |

---

## 2. attached 进程数曲线（每小时）

| 小时（epoch 段） | attached | segv | passed | WOULD_REPAIR | NEAR | repair-loop |
|---|---|---|---|---|---|---|
| <h0> | <n> | <n> | <n> | <n> | <n> | <n> |
| … | | | | | | |

判读：<是否单调/是否掉线/掉线时段与心跳缺口是否重合>

---

## 3. WOULD_REPAIR 聚合（"如果 armed 会被修"的分布）

### 3.1 by site（`ne_sites.py` 主表原样粘贴）

| # | site pc | n | 去重 pid | top comm | 符号 | +off | 出现小时数 |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

### 3.2 by comm

| comm | 事件数 | 去重 pid | 角色（子进程级/监听父进程级） |
|---|---|---|---|
| | | | |

### 3.3 by hour

| 小时 | WOULD_REPAIR | 同期 RX 包数（可选） | 备注 |
|---|---|---|---|
| | | | |

峰值小时 <h>，峰谷比 <x>；<是否与流量/时段相关（仅本窗内比较，跨会话不可比）>。

---

## 4. NEAR 全量（加固是否误伤真家族 —— **必须逐条，不得抽样**）

| # | epoch | site pc | comm | w0 | w1 | w2 | w3 | 判读：是否真家族（是/否）+ 理由 |
|---|---|---|---|---|---|---|---|---|
| 1 | | | | | | | | |

- 合计 <n> 条；判定"是真家族"的 <m> 条。
- 若 m>0：**G2 不通过**，需放宽 `w3`/长度带后重跑，本窗作废。

---

## 5. repair-loop 熔断

| site pc | 次数 | 最长连续 n | 该 pid 后续是否死亡 | 是否真家族 |
|---|---|---|---|---|
| （无则写 0 / 24 h） | | | | |

---

## 6. G6 名单：已知会死、dry-run 故意不救

| # | comm | pid | site pc | 首次时间 | 次数 | 该进程角色 / 是否影响服务 |
|---|---|---|---|---|---|---|
| 1 | | | | | | |

> 这是交厂商的证据清单，也是 armed 后的预期修复量。**必须全量**。

---

## 7. 设备可服务性记录（Lead 追加口径）

> dry-run 不修复 ⇒ **自然 NE 会真的死**，设备可服务性与 armed 时不同。本段必须写实。

| 项 | 值 |
|---|---|
| 部署前已确认"无其它实验依赖这些进程存活" | <是/否>，依据：<列出当时在跑的实验/台账> |
| dry-run 期间自然 NE 死亡事件数 | <n> 起 |
| 涉及进程与角色 | <列表> |
| 服务中断记录（SSH / LAN / GUI / 上行） | <有/无；有则时长与恢复方式> |
| 是否触发 watchdog 重启 | <是/否>，次数 <n> |
| drill 记录链接 | <path/url> |

---

## 8. G0–G6 裁决（每格必须 PASS / FAIL，**不许留空**）

| 门 | 判据 | 实测 | 裁决 |
|---|---|---|---|
| G0 | 窗口 ≥24 h 且心跳最大间隔 <180 s | <实测> | <PASS/FAIL> |
| G1 | `WOULD_REPAIR > 0`（或明确写"0/24h，检出下限 1，功率不足"） | <n> | <PASS/FAIL/无功效> |
| G2 | NEAR 逐条研判，结论"均非真家族" | <n> 条，其中真家族 <m> | <PASS/FAIL> |
| G2b | `NEAR reason=insn` 规模必报（与 WOULD_REPAIR 的比值） | <n> 次，比值 <x> | <PASS/FAIL> |
| G3 | `reason=repair-loop` = 0（或有且逐条确认非家族） | <n> | <PASS/FAIL> |
| G4 | PID 1 在 TracerPid 全量扫描中 100% 覆盖 | <覆盖率> | <PASS/FAIL> |
| G5 | `WOULD_REPAIR` 的 comm 里无 nerepair / watchdog（观测者污染） | <列表> | <PASS/FAIL> |
| G6 | 自然 NE 落在记录家族的，已全部单列（§6） | <n> 条 | <PASS/FAIL> |

---

## 9. 裁决句（照抄其一，**不得自造措辞**）

- 全部通过时写：
  > **G0–G6 全部通过，结论：可 armed。**
- 任一门未通过时写：
  > **G<x> 未通过（实测 <值>，判据 <值>），G0–G6 未全部通过，结论：不得 armed。**
- 无论哪种都必须附：
  > 本次 dry-run `WOULD_REPAIR` 合计 **<n>** 次 / **<h>** h，涉及 **<k>** 个进程、**<m>** 个 site；
  > 若 armed，预计修复 **<n'>** 次/24h。

---

## 10. 附件清单（缺一项即视为报告不完整）

- [ ] `nerepair.log` + `nerepair.log.1`（原样，主机副本）
- [ ] `ne_sites.tsv`（`ne_sites.py --out`）
- [ ] 部署前后 `ps` / `ls -l /proc/<pid>/exe` / 日志首尾输出
- [ ] STAT 时序 csv（由 §2 表导出）
- [ ] drill 记录 + devop ACQUIRED/RELEASED 配对
