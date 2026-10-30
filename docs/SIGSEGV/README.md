# SIGSEGV 调查 · 入口与文档规则

> 本目录是 **2026-10-30 之后的唯一当前事实源**。
> 旧的 `docs/SIGSEGV_*.md` 保留为历史记录，**不再代表当前结论**；阅读前先看 [ARCHIVE_MAP.md](ARCHIVE_MAP.md)。

## 1. 阅读顺序

| 顺序 | 文件 | 作用 |
|---|---|---|
| 1 | [00_STATE.md](00_STATE.md) | 一页纸当前状态：已确立、已撤回、未决、下一步 |
| 2 | [01_CLAIMS.tsv](01_CLAIMS.tsv) | 结论台账：每条结论的证据、硬度、日期、状态 |
| 3 | [02_METHOD.md](02_METHOD.md) | 调查方法论：证据分级、预注册、正对照、统计、样本来源、变更控制 |
| 4 | [03_PROBES.md](03_PROBES.md) | 仪器登记：每个探针测什么、覆盖什么、正对照、已知缺陷、修复状态 |
| 5 | [04_FAMILIES.md](04_FAMILIES.md) | 记录家族 A/B/C/D：签名、样本、因果状态、传输状态 |
| 6 | [05_LOG/](05_LOG/) | 实验日志：每轮先预注册，再结果，再判决 |
| 7 | [06_INSTRUMENT_FIXES.md](06_INSTRUMENT_FIXES.md) | 仪器修复批次：修了什么、怎么验证、还差什么 |

模板：[TEMPLATE_EXPERIMENT.md](TEMPLATE_EXPERIMENT.md)、[TEMPLATE_PROBE.md](TEMPLATE_PROBE.md)。

## 2. 硬规则

1. **当前结论只认 `00_STATE.md` + `01_CLAIMS.tsv`。** 旧文档、轮次记录、聊天结论都不算当前事实。
2. **每条结论必须有 ID、证据、硬度、日期、状态。** 没有进 `01_CLAIMS.tsv` 的结论，不得在报告/部署/决策中引用。
3. **每个实验必须先预注册。** 预注册写清：问题、假设、预测、判据、样本量/功效、混杂、停止规则、分析计划。实验后只改“结果/判决”，不改预注册。
4. **每个“0”必须写成 `0 / N` + 检出下限（LOD）。** 没有 LOD 的阴性只能标 E1，不能当排除证据。
5. **每个探针必须有正对照。** 没有正对照的探针，其阴性不得进入 `01_CLAIMS.tsv` 的 E2 以上。
6. **家族不得混算。** A（dpmaif context）、B（network flow）、C（其它小值）、D（非记录自然崩溃）分开统计；任何“总崩溃率”必须注明混合比例。
7. **一轮只改一个变量。** 设备侧改动必须有回滚/自动回滚；改动前后必须记录 manifest（构建哈希、模块、参数、起止 uptime、boot id）。
8. **旧文档只归档，不删除、不静默改。** 撤回的结论在 `01_CLAIMS.tsv` 里留 tombstone，并在旧文档顶部加“历史/已撤回”头。

## 3. 目录职责

```
docs/SIGSEGV/
  README.md                 本文件
  00_STATE.md               当前状态（唯一叙事）
  01_CLAIMS.tsv             结论台账（唯一结论表）
  02_METHOD.md              方法论（唯一方法源）
  03_PROBES.md              仪器登记（唯一仪器表）
  04_FAMILIES.md            家族定义（唯一分族源）
  05_LOG/                   实验日志（按日期）
  TEMPLATE_EXPERIMENT.md    实验预注册模板
  TEMPLATE_PROBE.md         探针登记模板
  ARCHIVE_MAP.md            旧文档映射与状态
  06_INSTRUMENT_FIXES.md    仪器修复批次（2026-10-30）
```

## 4. 与旧文档的关系

- `SIGSEGV_ANALYSIS.md`：机制笔记与历史轮次，**不是当前状态**；其中 §13.3/§21/§22/§24 互相冲突，按 `01_CLAIMS.tsv` 的 tombstone 处理。
- `SIGSEGV_REPORT_2026-10-30.md`：闭环报告 v1，**过度概括**“所有崩溃 = 32 字节记录”；保留为历史，当前状态见 `00_STATE.md`。
- `CRASH_ATTRIBUTION_2026-10-30.md`：67%/32% 分类**已撤回**（槽位 0x780 取错）。
- `SIGSEGV_PATTERN_OFFLINE_2026-10-30.md`：“两条记录/ΔA=8”解释**已撤回**（是 va_list 副本 + `va_arg` 自增）。
- `SIGSEGV_ROUND2..10`：按时间顺序的日志，保留原样；引用前先看 `ARCHIVE_MAP.md` 的状态。
- `tmpfiles/sigsegv_audit/REPORT.md`：2026-10-26 的独立复核，**仍然有效**（基线 92→27、core_trap 盲窗等），是本目录方法论的先行实践。

## 5. 变更流程

1. 新实验 → 复制 `TEMPLATE_EXPERIMENT.md` 到 `05_LOG/YYYY-MM-DD-NN.md`，先写预注册。
2. 实验后 → 在同一文件写结果/判决；新增/修改 `01_CLAIMS.tsv` 行；更新 `00_STATE.md` 的“下一步”。
3. 探针变更 → 更新 `03_PROBES.md` 的状态/缺陷/正对照；设备侧改动必须记录部署哈希。
4. 撤回结论 → 在 `01_CLAIMS.tsv` 把状态改 `retracted`，填 `supersedes`/原因；不删除行。