# U-A2 · Phase-2a 脉冲式 RO：判决报告（非 DMA / PTE 门控写入）

> 日期：2026-11-04 11:45（+0800）｜操作者：U-A2 接手者（按 WRITER_HUNT_HANDOFF.md）
> 预注册：[U-A2_PREREG_PULSE_2026-11-04.md](U-A2_PREREG_PULSE_2026-11-04.md)（结果前写定，本文不放宽任何条款）
> 仪器：`scanary_ro v1.21`（v1.20 + `--pulse`；源码 `tools/oneoff/sigsegv/scanary_ro.c`，未入库 oneoff 件）
> 设备代次：uptime 6:29 起的同一 boot（btime 1793711250），全程无重启。

## 0. 一页结论

**写者不是 MMU-blind（非 DMA/总线主写）。写者的写被 PTE 权限位门控——目标页只读期间写入
不发生（≥93% 抑制，保守口径 p<1e-20），且可见记录的写入时刻锁相在可写窗口（z=−6.2）。**

这把 H 层判决从 Phase-1 的「H2 是唯一未被削弱的类别（相关）」推进为
**「DMA 类（H1a/H1b/H3/H4）被干预实验正面拒绝；写入走 CPU/MMU 介导路径（H2 族）——E3」**。
写者身份（具体代码点）仍未点名 ⇒ **Phase-2b（fxhook 缺页归因模块）的装载前提已满足**
（HANDOFF §2.4 触发条件 = Phase-2a 判出非 DMA）。

| 层 | 结论 | 等级 | 依据 |
|---|---|---|---|
| 写者是否绕过 MMU（DMA） | **否**：RO 脉冲期间写入被抑制（50/1200 s on-page vs DMA 期望 ≥172–962） | **E3**（干预实验，双指标互证） | §3.1 速率 + §3.2 相位 |
| 写入是否遵守 PTE 权限位 | **是**：写入锁相可写（OFF）窗口，first_seen 48/50 在 OFF 态 | **E2/E3** | §3.2 |
| 写者身份 | 未点名（需 fxhook 抓缺页 PC/comm） | — | §6 下一步 |

## 1. 装置（v1.21 新增 `--pulse`，其余全继承 v1.20）

- **victim**：`--victim main --depth-list 0x1000`，printf 循环全程运行；`ro_victim_window()`
  在 pulse 模式发布 `&ap` 后立即返回（不停放——Phase-1 约束 1：写者只写运行态受害者）。
- **helper**：独立 256 KiB 栈；`mprotect(RO) 1ms → mprotect(RW) 1ms` 振荡至 duration；
  每 10 个脉冲记 1 条 `PULSE_ON/PULSE_OFF` 锚（n+ev，插值误差 <1 周期）。
- **自写 fault**：va_arg/frame 写 RO 页 ⇒ SIGSEGV ⇒ 既有 altstack handler + victim-only
  `siglongjmp` 恢复（v1.6/v1.14/v1.15 教训全部继承）；计数 `PULSE_VFAULT`，日志采样 1/10000。
- **守卫全保留**：PAGE_IS_TLS（`tpidr_el0`）、单实例（启动 + 每 60 s 重算）、`vap_drift`、
  helper 活栈区间、SIGTERM 窗内恢复 + `_exit(3)`、duration 兜底恢复（`PULSE_EARLY_OFF`）。
- **件身份（S-4 五元组）**：`scanary_ro_v21` / 83,000 B / md5 `1d30cd41ef5559dbee476abacae52c8a`
  / sha256 `2386d8e8470ef80fe52d98bbb55484c6d4c6c023ea75e8c9be3f127a904e098c` /
  zig cc aarch64-linux-musl -O2 -static（2026-11-04 10:43）。设备路径 `/data/repro/scanary_ro_v21`。

**验收**（10 s 冒烟 ×2）：RC=0；4547/4547 PULSE_ON/OFF 成对；8329 次自写 fault 全恢复
（victim 存活、iters 正常推进）；selftest 4/4；TLS/drift/单实例全绿。

## 2. 执行序列（预注册 §5 逐条）

| 步 | 命令要点 | 结果 |
|---|---|---|
| λ 前臂 | `--victim main --depth-list 0x1000 --writeback none --duration 600`（无 RO，运行态） | **481 条 inj=0 / 600 s = 48.1/min，全部落 ap 页** ≥10 门槛 ⇒ 开脉冲臂 |
| 脉冲臂 | `--pulse 1000,1000 --duration 1200` | 556,920 脉冲，duty 49.7% ON（596.996 s ON / 603 s OFF），`invalid=0`，`vap_stable=1`，iters 111,336（≈λ 臂节律 94%） |
| λ 后臂（bracket） | 同前臂 | **86 条 / 600 s = 8.6/min**（全部落 ap 页）——λ 35 min 内跌 5.6×（C-204 型波动） |

判读用最保守 λ（后臂 8.6/min）与名义 λ（前臂 48.1/min）双口径。

## 3. 判读（预注册 §3 表 + 双指标）

### 3.1 速率检验（预注册主判据）

| 口径 | DMA 期望（无抑制） | PTE-aware 期望（仅 OFF） | 观测 on-page |
|---|---|---|---|
| 名义 λ=48.1/min | 962 | 484 | **50** |
| 保守 λ=8.6/min | 172 | 86 | **50** |

- 拒绝 DMA（无抑制）：名义 z=−29.4（p≈e⁻⁴³²）；保守 z=−9.3（p<1e-20）。
- 观测 50 低于保守 PTE-aware 期望（86）——存在额外语义抑制（见 §4 混杂 3），但方向不变：
  **抑制本身就是 MMU-aware 的证据**（DMA 对权限位盲）。
- 关键功效前提已核：受害者调用节律保持 94%（111,336 vs 122,352 折算），调用窗未被打断
  ⇒ DMA 若为真，其触发机会仍在，抑制不能归因于触发消失。

### 3.2 相位检验（臂内自对照，不依赖跨臂 λ）

50 条 on-page 命中，每条取写窗 `(first_seen−5 ms, first_seen]`（驻留上界），用 55,691 个
锚点插值重建脉冲相位：

| 量 | 值 | 均匀/DMA 预期 |
|---|---|---|
| 写窗 ON 占比 | min 0.000 / p25 0.000 / **p50 0.000** / p75 0.180 / mean **0.058** / max 0.216 | mean ≈ 0.50（duty 50.4%） |
| first_seen 时页面态 | **OFF 48 / ON 2** | ~50/50 |
| z（mean vs 0.50） | **−6.2**（p≈3e-10） | — |

⇒ 可见记录的写入**压倒性地发生在页可写的窗口**：写者的写被 PTE 权限位实时门控。
臂内自比率：OFF 写入率 ≈ 50/603 s = 5.0/min，ON 写入率 ≤ 2/597 s ≤ 0.2/min，**比值 ≥25×**。

### 3.3 预注册表落位

预注册 §3 的 E4 正向出口（「≥1 条形状记录且整写窗仅含 ON」）**结构性不可达**（50% 占空
@ 2.14 ms 周期下 5 ms 写窗必含 OFF）——预注册注记已声明该限制；实际判读落在：

> 「0 条 ON-only 写窗命中 + λ≥10 功效达标 ⇒ 充分暴露下未观察到绕过 MMU 的写」
> ——本臂以双指标（速率 + 相位）强化为 **E3：写入被 PTE 门控（非 DMA）**。

## 4. 混杂与诚实清单（引用本文必须带）

1. **跨臂 λ 漂移**：前臂 48.1 → 后臂 8.6 /min。相位检验（臂内）免疫；速率检验用双口径
   （结论均成立）。会话间槽位选择亦有差异（每臂单槽 hammer：0x…fbc0 / 0x…f030 / 0x…f030）。
2. **逐条 E4 不可达**：50% 占空 + 驻留 5 ms > 周期 2.14 ms ⇒ 无法证明单条写入发生在 RO 中。
   更低占空（如 `--pulse 500,9500`，duty 5%）可逼近但以期望事件数换分辨率，未在本轮做。
3. **额外语义抑制**：观测 50 < 保守 PTE-aware 期望 86。候选解释：ON 段受害者 fault-loop
   改变调用窗微结构；或 λ 在臂内继续下降。不改变 DMA 拒绝的方向。
4. **边界竞态 fault**：836,272−729,025 = 107,247 次自写 fault 落在状态切换边界
   （`g_pulse_state` 与实际 PTE 生效的微秒窗），全部走同一恢复路径；无装置后果。
5. **调度拉伸**：81/55,691（0.15%）ON 段被拉长至 >3 ms（max 23.7 ms）——期间页面 RO，
   无命中归因于这些窗（保守方向）。
6. **写者会复制注入标记**（冒烟臂意外观察，E1 级）：selftest 注入 INJ 记录后 ~25 µs 内，
   写者把 `w0=INJ_W0` 的副本写到守护页 3 个新地址（EV 14786/14806/14825）+1 个 top 页地址
   ——写者读取并重写活帧区内容的直接行为学证据；正对照价值：证明写者在冒烟时段活跃且
   目标覆盖守护页。

## 5. 证据文件（md5 钉死）

| 文件 | 设备路径 | md5 | 内容 |
|---|---|---|---|
| ua2_lambda.log | /data/repro/ | `e0167aa43000f22bfd80b7fe8d19af6f` | λ 前臂 600 s（481 命中） |
| ua2_pulse.log | /data/repro/ | `51079c25c613a07f8bd04bf29270e8a8` | 脉冲臂 1200 s（556,920 脉冲 + 50 on-page） |
| ua2_bracket.log | /data/repro/ | （设备侧） | λ 后臂 600 s（86 命中） |
| ua2_smoke.log / ua2_smoke2.log | /data/repro/ | — | 冒烟 ×2（含 §4.6 注入复制观察） |

本地副本：`tmpfiles/review/ua2/`（pulse/lambda 已 md5 对账；bracket 未拉取）。
分析脚本：`tmpfiles/review/ua2/analyze_pulse.py`。
NE 台账：前后均 1794 行（零新增）；nerepair 全程 dry（STAT `repaired=0`，852,141 次 PASS）。

## 6. 下一步（Phase-2b 触发条件已满足）

1. **fxhook 模块**（缺页归因，点名 CPU 写者 PC/comm）：唯一剩余问题「谁在写」。
   按 HANDOFF §2.4 纪律执行：参考 `tmpfiles/repro/kmod/` + `tools/oneoff/sigsegv/` 既有 hook
   手法（dphook/dmahook/tuphook：PAC 序言 +4/+8、tpidr_el2、proc_lseek、回读门禁）；
   装载前 10 min 零实验观察 + **skeptic 签字放行** + LK 救砖路径预注册。
   本臂把 fxhook 的预期信号收窄为：**非 victim 线程的写缺页（esr=Wn, addr∈守护页, OFF 边界
   附近）或 uaccess fixup 吞掉的 EFAULT**——不必再全量挂 do_page_fault 前的路径。
2. 低占空复核臂（可选）：`--pulse 500,9500`（duty 5%）逼近逐条 E4 分辨率；当前双指标已足，
   优先级低于 fxhook。
3. λ 日变化（48→8.6/min/35 min）值得单独立档：写者率对 WiFi 客户端流量构成的依赖
   （C-157/C-204 延伸），做「λ vs 时段/流量构成」矩阵前不动结论。

## 7. 三栏

### [A] 已核实
- v1.21 装置：冒烟 ×2 全绿、脉冲臂 1200 s `invalid=0`、`vap_stable=1`、selftest 过、
  836K 自写 fault 全恢复、EXIT 干净。
- λ 前臂 481/600 s、脉冲臂 on-page 50、λ 后臂 86/600 s（均为 inj=0、ap 页、全量页归属核对）。
- 相位归因：50 条写窗 ON 占比 mean 0.058 vs 0.50（z=−6.2）；first_seen OFF 48/50。
- NE 零新增、nerepair dry、单实例全程、无残留进程。

### [B] 未核实
- 单条写入的 RO 内发生（结构性不可达，见 §4.2）。
- 臂内 OFF 写入率的精确值（受 §4.3 语义抑制混杂，只报下界比率 ≥25×）。
- 写者身份（fxhook 范畴）。
- 冒烟臂「注入复制」观察的重复性（单次，E1）。

### [C] 必须上设备/需新仪器才能确认
- fxhook 装载后的非 victim 写缺页点名（PC/comm/时间戳）。
- 更低占空脉冲下的逐条 E4 分辨率。
