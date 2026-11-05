# U-B1 预注册 · fxhook 缺页归因（Phase-2b：点名写者）

> 日期：2026-11-04 12:20（+0800）｜结果前写定，不得事后放宽。
> 前置：[U-A2_PULSE_RESULT_2026-11-04.md](U-A2_PULSE_RESULT_2026-11-04.md)（非 DMA / PTE 门控，E3），
> [U-B1_FXHOOK_SKEPTIC_REVIEW.md](U-B1_FXHOOK_SKEPTIC_REVIEW.md)（有条件放行 + 5 条运行期约束）。

## 0. 问题

Phase-2a 已判：写者的写被 PTE 门控（CPU/MMU 介导）。剩余唯一问题 = **谁在写**（PC/comm）。
Phase-2a 相位检验给出精确预期：写入**锁相可写窗**；因此若 CPU 写者经由 uaccess 失败路径
（RO 期间 store → ex_table fixup），fxhook（钩 fixup_exception）在 RO 脉冲 ON 段应捕获
far ∈ 守护页的事件并给出 lr = 写入者调用点。

## 1. 判据（写死）

fxhook 记录 `ev cpu far pc lr pid comm`。窗内（scanary 脉冲臂运行中）出现：

| 观察到 | 判 | 等级 |
|---|---|---|
| ≥1 条 ev：far ∈ [lo,hi) ∧ comm ≠ scanary_ro_v21 | **CPU 内核态 uaccess 写者当场点名（lr = 调用点）** | **E4** |
| ≥1 条 ev：far ∈ [lo,hi) ∧ comm = scanary_ro_v21 | fxhook 抓到的是**实验装置自身**的缺页路径（记录并在判读中排除装置行；lr 应落在 scanary 恢复 handler/uaccess 附近）——不算写者也不算装置失效 | 装置注记 |
| ON 段成对 PULSE_ON/OFF 正常、victim 节律正常（≈94%）、**hit=0**（含 scanary 自身也 0） | 写者**不经 ex_table/uaccess-fixup 路径**：CPU 写走的是「普通内核 store 到用户 VA」分支（无 ex_table ⇒ 若真发生会 Oops——未发生 ⇒ 此分支排除）或**写者通过页缓存/其他 MMU 合法路径**（如页级写时复制、kmap 别名、或内核页表别名写）。点名失败，转入下一候选（内核页表别名写 = T-03 romap 路线） | ≤E1 |
| hit 风暴（>1000/s）或 drop 持续增长 | 立即 `echo 0 > /proc/fxhook` 降级；数据按 ratelimit 有效段判读 | — |

**判读前提**：只有「PULSE_ON 段内 victim 自写 fault（siglongjmp 恢复）」与「外部 CPU 写者
uaccess 失败」两类事件产生 far∈窗的 ex_table 缺页；victim 自身 fault 是**用户态**信号
（不进内核 fault 路径），**不会**出现在 fxhook ring——若出现 scanary comm 行，说明有
scanary 的内核侧 uaccess 触碰该页（如 PAGE_IS_TLS 检查、/proc 读取路径页缓存），按表处理。

## 2. 装载序列（skeptic §3 五条约束全嵌）

```
1. deploy.py put fxhook.ko → /data/repro/fxhook.ko（md5 双核）
2. devop 持锁：
   insmod fxhook.ko lo=0x<h page> hi=0x<h page+0x1000>
   判据：rc=0 ＋ dmesg GO/NO-GO ok ＋ cat /proc/fxhook 首行 go=1 patched=1
3. 10 min 零实验观察窗（预注册硬判据：hit 必须 0；设备 uptime/负载无异常）
4. 联合窗：scanary_ro_v21 --pulse 1000,1000 --duration 900（fxhook 全程 armed）
   窗中点 + 窗末各 cat /proc/fxhook 一次（只 cat）
5. 收尾：echo 0 > /proc/fxhook → rmmod fxhook
   硬判据：dmesg 出现 restored … readback a9be7bfd ok=1（skeptic 约束 1）
6. NE 台账前后对账（零新增）；nerepair 全程 dry
```

lo/hi 取联合窗 scanary 自报的守护页（--log 里 VAP 行 page= 字段）；装载前先跑 10 s
scanary 冒烟取页址——**页址会话间会变**（已实测 3 个会话 3 个地址），所以序列是：
先冒烟取页 → 立即 insmod（同页窗）→ 联合窗。若冒烟与联合窗之间页漂移（RO_INVALID
vap_drift），作废重来。

## 3. 作废条件

1. insmod rc≠0 或 GO/NO-GO failed（自动回滚）⇒ 本轮中止，报告失败模式；
2. 观察窗 hit≠0 ⇒ 卸载检查（谁在碰窗页？）——视为环境混杂，不进判读；
3. 联合窗 RO_INVALID/vap_drift/multi_instance/woke（scanary 侧既有判据全继承）；
4. rmmod readback 失败 ⇒ incident 流程；
5. 任何 kernel oops / RCU stall / panic 迹象 ⇒ 停止一切（不二次触发），LK 救砖待命
   （tools/lk_flash_v4.py；本 boot 刷机资产在 _drill_backup）。

## 4. 风险与兜底

- 模块缺陷 ⇒ panic：五元组 + skeptic 报告 + go/no-go 三重门；LK 串口救砖链实证可靠。
- far 窗错页（页漂移）：序列里页址取自当次冒烟，漂移即作废。
- fxhook ring 只保 16 条/CPU：脉冲 ON 段外 CPU 写者缺页若 >16 条/CPU 会滚掉——
  联合窗后**立即**读 ring（cat），不隔窗。
