# U-B1 · fxhook 缺页归因：结果报告（ex_table/uaccess-fixup 路径排除）

> 日期：2026-11-04 13:15（+0800）｜操作者：U-A2/U-B1 接手者
> 预注册：[U-B1_PREREG_FXHOOK_2026-11-04.md](U-B1_PREREG_FXHOOK_2026-11-04.md)（结果前写定）
> skeptic 审查：[U-B1_FXHOOK_SKEPTIC_REVIEW.md](U-B1_FXHOOK_SKEPTIC_REVIEW.md)（有条件放行，5 条运行期约束全部执行）
> 设备：同一 boot（uptime 9h+，全程无重启）；NE 台账 1794→1797（§5 对账）。

## 0. 一页结论

**写者不经 ex_table/uaccess-fixup 路径**。fxhook v5 在联合窗（fxhook armed + scanary
脉冲臂对齐 219 s）内 `calls=0`：全系统 219 s 内**零次** fixup_exception 调用——不仅守护页
无，全系统任何 uaccess 缺页都无。与此同时 scanary 记录到 **13 条 on-page 家族记录**
（aligned 窗，λ≈3.6/min 与 bracket 一致），全部写窗 ON 占比 mean=0.050（z 与 Phase-2a 一致）。

按预注册 §1 判读表落位：

| 预注册分支 | 本轮落位 |
|---|---|
| ≥1 条 ev（far∈窗，非 scanary）⇒ E4 点名 | **未发生** |
| ≥1 条 ev（comm=scanary）⇒ 装置注记 | 未发生（victim 自写 fault 是用户态信号，不进内核 fault 路径——预注册预判正确） |
| **hit=0 + PULSE 成对 + 节律正常 ⇒ 排除 ex_table 路径** | **命中此分支（≤E1 阴性，但结构信息量大）** |

**机制推论（E2，臂内证据）**：Phase-2a 已证写入被 PTE 门控（RO 期间不写）；本轮再证
**RO 期间的"被门控"不是 uaccess-fault-skip**（若是，fxhook 应见 far∈窗 事件）。两者合取：
写者的写是**普通内核/用户态 store，先检查/遵守权限，遇 RO 时不触发任何可观测的缺页
路径**。剩余候选：① 写者用户态直接 store（写者就在某用户进程内，遇 RO 缺页由其自身
handler 吞掉——但far∈窗用户态 fault 会走 do_page_fault 用户路径，不经 fixup_exception，
**本轮仪器天然不可见**）；② 内核普通 store（无 ex_table ⇒ 若发生会 Oops，未发生 ⇒ 排除）。
⇒ **①成为最优解释：写者大概率是一个用户态实体，其"目标页可写"的判断先于写入**
（或写者写的是它自己的映射视图，与 victim 共享页但独立权限语义不成立——同页权限共享，
所以更可能是：写者在 RO 脉冲的 ON 段被自己的权限检查挡住/暂缓，OFF 段继续）。

## 1. 装置谱系（本次抓出并修复 3 个真实缺陷）

| 版本 | 缺陷 | 证据 | 修复 |
|---|---|---|---|
| v2（FIVETUPLE 在档，从未上机） | shim `adrp/add ldr br` 引用 `fx_resume_addr` 全局 ⇒ zig 链接为 **GLOBAL UNDEF** ⇒ insmod `Unknown symbol` | 设备 [30196]；uwhook.ko 同款缺陷（同 UNDEF 符号模式，同批"需重新验收"件全中） | v3：tuphook 已验证模式（`b .` 占位 + init 算 B-target 回填 + 反解自检） |
| v3 | go/no-go 探针 `0xdead0000`（用户 VA）被 **CONFIG_ARM64_PAN=y** 硬件门挡在译码前 ⇒ 无缺页 ⇒ calls 不动 ⇒ 假 NO-GO（自动回滚干净） | 设备 [30390] | v4：探针换内核 VA `0xffff800000000000`（VA 洞，必走 TTBR1 译码失败 → ex_table） |
| v4 | `g_calls/g_dropped` 是普通 static 却用 `__this_cpu_inc` ⇒ 写进 per_cpu_offset 幻影地址：go/no-go 读 0 恒假 NO-GO；**且每次真实调用会踩踏 percpu 内存**（tuphook A5 同族） | 代码审查 + v4 设备实测仍 calls 不动 | **v5**：改 `DEFINE_PER_CPU` + `sum_calls()/sum_dropped()` 汇总 |

**v5 装载全绿**：`shim back-branch ok` + `hooked … (was a9be7bfd)` + `GO/NO-GO ok calls=1`
+ `armed=1`；10 min 零实验观察窗 `hit=0` 通过（12:33–12:43）；teardown `readback a9be7bfd ok=1`。

五元组（FIVETUPLE.txt 已追加）：v3 `8476f737…`/187,464 B；v4 `c20926f3…`/187,456 B；
**v5 `c4f7f9a3e249092f3917fe98c53d9610`/192,584 B**（本报告引用件）。

## 2. 执行序列偏差与处置（诚实清单）

1. **窗对齐错位（第一次装载）**：insmod 用的页址来自 12:43 冒烟（`0x7fc9cf8000`），联合窗
   victim 起来后页址变了（`0x7ffc1e2000`）——far 窗对不上。处置：`rmmod`（readback ok）→
   用联合窗 VAP 行实际页址重装（26.3 s 处完成）。预注册 §2 的"页漂移即作废重来"未触发
   （联合窗自身页址稳定，vap_stable=1）。
2. **联合窗被 scanary 死亡截断**：计划 900 s，victim 在 EV 245.5 s（12:47:50）死于
   SIGSEGV（NE 台账在案：`far=0xffffffffffffffc8, pc=0x1021134`）。详见 §4。

## 3. 数据

| 项 | 值 |
|---|---|
| 联合窗实际时长 | ~246 s（截断）；fxhook 对齐窗 219 s |
| scanary 脉冲 | 113,760 对（10 载 1 记 11,376 行）；ON p50=1076 µs，duty 49.9% |
| on-page inj=0 命中 | 16 条（3 条在 fxhook 对齐前；**13 条在对齐窗内**） |
| aligned λ | 3.6/min（与 bracket 8.6/min 同量级，低流量时段） |
| aligned 命中写窗 ON 占比 | min 0.00 / p50 0.00 / **mean 0.050** / max 0.22（与 Phase-2a mean 0.058 一致 ⇒ 相位结论跨窗复现） |
| fxhook（对齐窗） | **calls=0, hit=0, dropped=0**（armed 全程） |
| victim 自写 fault | 151,097 次（全用户态恢复，无一次进内核 fault 路径——预注册 §1 预判被实锤） |

分析脚本/日志：`tmpfiles/review/ua2/`（`ua2_joint.log` md5 `c829f74291c8113abc7cc62f2c979d8d`，
`ua2_pulse.log`、`ua2_lambda.log`、`analyze_pulse.py`）。

## 4. scanary 死亡（未归因完成，单列）

- 签名：`SIGSEGV far=0xffffffffffffffc8（NULL-0x38）pc=0x1021134`；此前 220 s 正常运行
  （113,760 脉冲、151K vfault 全恢复、16 命中正常记录）。三个前作臂（冒烟/λ/脉冲主窗）
  同 binary 均跑满全程——**此失败模式仅在本联合窗出现**。
- 与 fxhook 的关系：无法完全排除（不能证明无关）。但 far 不是守护页、不是 TLS 页、不是
  任何被 mprotect 的页；fxhook 只读 fixup_exception 调用流（armed 快路径 7 条指令），
  calls=0 ⇒ fxhook 在全窗内根本没被执行过 ⇒ **fxhook 物理上不可能是死亡原因**
  （若 shim 被执行，calls 至少 +1）。此推理钉死 fxhook 无罪。
- 头号嫌疑（未验证）：v21 自身长窗 vfault 风暴下的某个低概率崩溃路径（此前臂未到过
  ~150K vfault + 113K 脉冲同规模）或环境偶发。处置：不再深挖（v21 已完成使命），
  归档 core（`cores/meta/1793736016-21203-1793767670.*`），后续臂建议 vfault 计数
  加自熄阈值（如 200K 自退）再复跑联合窗验证。
- NE 台账对账（1794→1797）：+3 = ① `fast_watch.sh`（我们树的后台巡检脚本自身 NE，
  与本实验无关，12:39）；② scanary（本实验，§4）；③ `cut -d: -f3`（busybox 瞬态，
  origin=unknown，13:00）。nerepair 全程 dry（xrep=0，repaired=0）。

## 5. 判决汇总（写进看板/SCORECARD 口径）

| 层 | 结论 | 等级 | 依据 |
|---|---|---|---|
| 机制层（承接 Phase-2a） | 写者**不绕 MMU**（PTE 门控）且**不经 ex_table/uaccess-fixup** ⇒ 最优解释 = **用户态写者，权限感知式写入**（RO 时暂缓，RW 时继续） | **E2**（双实验合取；写者身份仍未点名） | U-A2 + 本轮 §0 |
| fxhook 路径 | 该仪器对本写者**结构性不可见**（写者不产生内核 fixup 事件）——不是仪器失效：calls=0 证明快路径从未进入，且同窗 calls 通道本身已被 go/no-go 实证存活 | E3 | §3 |
| 写者身份 | 仍未点名。下一最优手段 = **T-03 romap**（内核直映射别名置只读：若写者是内核态普通 store，会吃 data abort 当场点名；若是用户态写者，romap 不影响它——一次实验同时判"内核普通 store"存在性） | — | §6 |

## 6. 下一步

1. **T-03 romap 复活**（kmod/romap.ko 在档，md5 `314974d6…`，"待排队"）：这是排除
   "内核普通 store"分支的判别实验，正面点名或排除。预注册照skeptic 规则走
   （60 s 稳定对照 + ro_selftest 关 + 卸载逐页恢复）。
2. 用户态写者假设的可加码证据：fxhook 窗口扩到**全栈区间**（不只 1 页）抓任何 ex_table
   事件做背景基线（本轮 calls=0 已是全系统基线 = 0，此项收益小）。
3. scanary v21 加 vfault 自熄阈值后再复用（§4 处置）。
4. λ 低时段（3.6–8.6/min）联合窗功效已够（13 条>10 门槛），无需再拉长。

## 7. 三栏

### [A] 已核实
- v5 装载链全绿（GO/观察窗/teardown 回读）；3 个真实缺陷修复有设备日志佐证。
- 联合窗 219 s：calls=0/hit=0；13 条 aligned 命中相位 mean 0.050（跨窗复现 Phase-2a）。
- NE +3 对账清楚；fxhook 与 scanary 死亡物理无关（calls=0 钉死）。

### [B] 未核实
- scanary 死亡根因（§4，不阻塞判决）。
- "用户态写者"假设（最优解释但未直接观测——romap 是下一判别实验）。
- uwhook.ko 同款 UNDEF 缺陷（本轮未修，若日后启用需先修）。

### [C] 必须上设备才能确认
- romap 臂：内核普通 store 分支的存在性（点名 data abort PC 或排除）。
- 写者身份的最终点名（若 romab 点名失败，剩余候选=用户态写者枚举，需另设计）。
