# U-A2 · Phase-2a 预注册：脉冲式 RO + 缺页归因（DMA vs CPU 写判决）

> 日期：2026-11-04 10:35（+0800）｜操作者：接手 WRITER_HUNT_HANDOFF.md 的下一位
> 前置：[U-A1_ROPTE_2026-11-04.md](U-A1_ROPTE_2026-11-04.md)（Phase-1 终判 INVALID-by-confound + 三条经验约束）、
> [WRITER_HUNT_PHASE1_REVIEW.md](WRITER_HUNT_PHASE1_REVIEW.md)（§6.11–6.15 判读规则、§7 收束）、
> perf 夜档（150 行，W1–W6 作废清单）。
> **本预注册在结果产生前写定，不得事后放宽。**

## 0. 问题与唯一出路（Phase-1 已证死的路）

Phase-1 三条经验约束（E2，双窗一致）：

1. 写者**要求受害者线程在用户态执行**（停放 600 s ⇒ 0 命中，P≈e^-100）；
2. **不需要内核进入**（D14：busy 自旋 1.065/s > sleep 0.463/s）；
3. **不绑定每轮 va_list 调用**（8.55 M 轮 × 8 s ⇒ 0，每轮概率 <3.5e-7）。

⇒ 「受害者运行 + 该页 RO 长窗」物理上不可能（受害者 va_list 消费每步都写该页）；
「RO 长窗 + 停放」被证伪为混杂（写者率 = 停放态 = 0）。**唯一出路 = 短 RO 脉冲 + 受害者保持运行**。

## 1. 装置（scanary_ro v1.21，新 `--pulse` 模式）

### 1.1 机制

- **受害者线程**：正常 printf 循环（`--victim main --depth-list 0x1000`，与历史所有 RO/RW 臂同构）。
  `ro_victim_window()` 在 pulse 模式下**直接返回**——不停放，va_list 照常被 `vsnprintf` 消费。
- **helper 线程**（独立 256 KiB mmap 栈，v1.11 架构不变）：收到 victim 发布的 `&ap` 后，
  进入脉冲振荡循环：`mprotect(RO) ON → sleep ON_MS → mprotect(RW) → sleep OFF_MS →` 重复，
  直到 `--pulse-loops` 次或 victim `--duration` 到期。每次转换打 `PULSE_ON/PULSE_OFF` 行
  （EV 时间戳 + page + poff）。
- **受害者自写缺页**：va_arg 消费写 RO 页 ⇒ SIGSEGV；现有 `segv()` handler（SA_ONSTACK，
  victim 线程 64 KiB altstack）已实现 siglongjmp 恢复（v1.6 缺陷修复后即此形态）。
  自身 fault 计入 `PULSE_VFAULT`，**排除出判决**（§3 判读表）。
- **外部写检测**：现有 scanner 线程（独立线程、5 ms 周期、扫全栈 + decoy）不变。
  RO 脉冲窗内出现家族形状记录（inj=0、guard band、页归属过滤）= 写穿只读页。

### 1.2 与 v1.20 的关系（最小改动面）

| 件 | v1.20 | v1.21 脉冲模式改动 |
|---|---|---|
| `ro_victim_window()` | 发布 + futex 停放 + 等 done | 发布 + **立即 return**（va_list 继续消费） |
| `ro_do_window()` | parked 确认 → 整窗 RO → 恢复 | **跳过 parked 检查** → 振荡 N×(ON_MS RO / OFF_MS RW) |
| `ro_victim_blocked()` | 窗前强制 | **不调用**（victim 必须运行） |
| SIGSEGV handler | sel`fcrash 计数 | 不变 + PULSE_VFAULT 计数（fault addr ∈ 守护页 ⇒ pulse 态下计 vfault） |
| guard | TLS 页守卫、单实例、drift | **全部保留**（含 60 s INSTANCES 重算） |
| 硬上限 | sec+60 s | ON 段单次 ≤ 2 ms（`--pulse-on-us` 上限 2000），总时长仍 `--duration` 管 |

### 1.3 新 CLI

```
--pulse ON_MS OFF_MS     脉冲模式（如 --pulse 1 1 = 1 ms RO / 1 ms RW）
--pulse-loops N          脉冲循环数（默认：直到 --duration）
```

约束：`--pulse` 与 `--ro 0|1` 互斥（`--pulse` 即隐含 RO 臂）；ON_MS ∈ [0.5, 2] ms（长脉冲 =
自写 fault 风暴，短于 0.5 ms = 覆盖不足）。

## 2. 暴露核算（预注册必含，结果前写死）

| 参数 | 取值 | 来源 |
|---|---|---|
| 同状态 RW λ | **开窗前实测**（600 s，同 D=0x1000、victim=main、运行态） | 夜档 §3.2：运行态页内 ≈10.2–13.7/min（解除停放后） |
| 脉冲占空 | ON/(ON+OFF)；拟 50%（1 ms/1 ms） | 设计值 |
| 窗总长 | 1200 s | HANDOFF §2.4 |
| **期望变更数** | λ × 1200 s × 50% | λ=10/min ⇒ 期望 ≈ **100**；λ=6.5/min ⇒ 期望 ≈ 65 |
| **最低门槛** | **λ ≥ 10/600 s 才开 RO 臂**；λ < 10 ⇒ INVALID-by-confound（同款规则，不开窗） | U-A1 §0.0 设计级前置 |

**λ 预检判读（600 s RW 臂，运行态、同 D）**：页内 inj=0 命中数 ≥ 10 ⇒ 开脉冲臂；< 10 ⇒ 不开，
写 INVALID 并停。**预期**：当前时段（上午，若有 WiFi 客户端流量）λ 应落在 C-204 热态区间
（13.87–20.33/min）；若恰逢空闲 λ 可能低至 0.1/min ⇒ 按门槛停。

## 3. 判读表（结果前写死，事后不得放宽）

RO 脉冲 ON 段内（`PULSE_ON + 200 µs < EV < PULSE_OFF - 边界`，含 guard band 防驻留滞后）
观察到的**家族形状记录**（inj=0、`va ∈ [page, page+4096)`、非 victim 自身路径）：

| 观察到 | 判 | 等级 |
|---|---|---|
| ≥1 条形状记录落在 ON 段内（排除自身 fault、排除 carry-over：`first_seen` 在 OFF 段后仍见的记 carry，不计） | **写穿只读页 ⇒ 非 CPU（DMA/总线主写）** | **E4** |
| 0 条形状记录在 ON 段内，且** RW λ 臂 ≥10/600 s**（功效达标） | 「充分暴露下未观察到绕过 MMU 的写」 | ≤E1（上限 E2） |
| 0 条 + λ < 10 | **INVALID-by-confound**，不得写阴性 | E0 |
| victim SIGSEGV 风暴（PULSE_VFAULT > 50% 占空的实际执行时间）或 vsnprintf 输出数据完整性破坏（iters 停滞、selftest 线路异常） | 装置失效 ⇒ 本臂作废 | — |

**注（Phase-2a 边界）**：CPU 写缺页归因（fxhook 点名 PC/comm）**不在本臂**——Phase-2a 只判
DMA vs 非 CPU。若判出「非 DMA」（0 条 ON 段命中且功效达标），Phase-2b（fxhook 模块）才上场。
CPU 写在 RO 脉冲下的表现 = 缺页（被 PULSE_VFAULT 或内核 uaccess 静默吞掉）⇒ **不出形状记录** ⇒
自然落入「非 DMA」分支，与设计一致。

## 4. 作废条件（任一即整臂作废）

1. `SELFCRASH` 无法恢复（victim 死亡、无 EXIT 行）；
2. `multi_instance`（启动或 60 s 重算 >0，exit 2/4）；
3. `vap_drift`（&ap 换页）；
4. `PULSE_VFAULT` 占比 > 50%（自写风暴 = 数据完整性不可信）；
5. nerepair 非 dry（窗前 / 窗后各核一次 STAT 行 `mode=dry`）；
6. TLS 页判据 `d = poff + topminusap < 0x10d8`（TLS 未排除窗不计入）。

## 5. 执行序列

```
1. 推 v1.21 到设备（deploy.py put + md5 校验 + chmod 755）
2. 10 s 冒烟（--pulse 1 1 --duration 10）：RC=0、PULSE_ON/PULSE_OFF 成对、
   PULSE_VFAULT 有计数但 victim 存活、EXIT 行正常
3. RW λ 预检 600 s（--ro 0，运行态，同 D）→ λ ≥10 才继续
4. 脉冲臂 1200 s（--pulse 1 1）
5. （可选 bracket）再 600 s RW 后臂
6. 全程每 300 s 核 INSTANCES（外部 comm 枚举，3 次以上证据）
```

## 6. 前置条件核对（HANDOFF §2.6）

| 条件 | 状态（2026-11-04 10:30 实测） |
|---|---|
| nerepair dry | ✅ STAT 行 `mode=dry xrep=0`（10:28:43 / 10:29:43） |
| 单实例断言 | ✅ v1.13+ 内置（v1.21 保留） |
| WiFi 客户端流量时段 | ⚠️ 待 RW λ 预检实测（上午时段，未知；λ<10 即停） |
| LK 救砖 | ✅ tools/lk_flash_v4.py 在位（本臂零内核风险，纯用户态） |
