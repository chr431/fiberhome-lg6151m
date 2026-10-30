# 旧文档映射与状态

> 旧文档保留原样，只在顶部加“历史/已撤回”头；当前结论见 [00_STATE.md](00_STATE.md) 与 [01_CLAIMS.tsv](01_CLAIMS.tsv)。

| 旧文档 | 状态 | 说明 |
|---|---|---|
| `docs/SIGSEGV_ANALYSIS.md` | **历史/部分撤回** | 机制笔记与轮次；§13.3 PIT、§21 dpmaif、§22 日志文本、§24 aee 侧写互相冲突；按 01 的 tombstone 处理 |
| `docs/SIGSEGV_REPORT_2026-10-30.md` | **历史/过度概括** | “所有崩溃 = 32B 记录”不成立；保留为 v1 报告 |
| `docs/CRASH_ATTRIBUTION_2026-10-30.md` | **已撤回** | 67%/32% 基于 0x780 槽位；按 fault-time x2 重算 103/106 |
| `docs/SIGSEGV_PATTERN_OFFLINE_2026-10-30.md` | **已撤回** | “两条记录/ΔA=8”是 va_list 副本 + `va_arg` 自增 |
| `docs/SIGSEGV_ROUND2..10` | **历史日志** | 按时间顺序；引用前看 01 的状态；Round 4/6/10 的 uaccess/RE 结论仍重要 |
| `docs/STRATEGY_EVALUATION_2026-10-30.md` | **历史/前提已变** | 策略评估基于“单一写入者”；当前先分类/传输判定 |
| `tmpfiles/sigsegv_audit/REPORT.md` | **有效（独立复核）** | 基线 92→27、core_trap 盲窗、logc 抑制 core；方法论先行实践 |
| `docs/STABILITY_ANALYSIS_2026-10-19.md` | **历史** | 早期稳定性分析；与当前家族分类不直接可比 |
| `docs/INCIDENT_2026-10-19.md` | **历史** | 早期事件记录 |

## 已加头部

对 `docs/SIGSEGV_*.md` 统一加：

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

对 `CRASH_ATTRIBUTION`/`PATTERN_OFFLINE` 加“**已撤回**”说明。
