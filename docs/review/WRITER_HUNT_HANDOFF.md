# 写入者点名：Phase-1 收束 + Phase-2 交接

> 日期：2026-11-04 10:25（+0800）｜Lead: lead
> 前置文档：[U-A1_ROPTE_2026-11-04.md](U-A1_ROPTE_2026-11-04.md)（方法、四探针、H 层判决）、
> [WRITER_HUNT_PHASE1_REVIEW.md](WRITER_HUNT_PHASE1_REVIEW.md)（§6.11–6.15 判读表/裁定/终判 + §7 收束）、
> perf 夜档 `tmpfiles/review/perf/NIGHT_2026-11-04.md`（150 行：作废清单 W1–W6、可复现命令、md5、[A]/[B]/[C]）。

## 一、Phase-1 终判

**未获得 CPU/非 CPU 判决**。"停放 + RO" 设计被混杂证伪（停放 ⇒ 写者停写，P≈e^-100）。

但机制画像大幅推进，**三条经验约束**（E2，双窗一致）：

| # | 约束 | 实验 | 依据 |
|---|---|---|---|
| 1 | 写者**要求受害者线程在用户态执行** | 停放 RW 对照 600 s：**0 命中**；解除后 3.9 s 起 ≈10/min | 停放态写者率 = 0 |
| 2 | **不需要内核进入** | D14 预注册 A/B/A：busy 自旋 1.065/s vs sleep 0.463/s（R=0.43） | 不进内核反而更高 |
| 3 | 写者**不绑定每轮 va_list 调用** | 全速 8.55 M 轮/s × 8 s：**0 命中**（每轮概率 <3.5e-7） | 与"每轮一次"不兼容 |

**H 层判决**：H1a/H1b（陈旧 PA DMA）、H3（直映射）、H4（HW 描述符写回）、H6（内核保存 sp）、H7（缓存固定 VA）**削弱或否证**；H2（uaccess）**是唯一未被削弱的内核侧类别**（但 D14 表明不在 syscall 路径）。

时间相关性臂（R1+R2 pooled）：**219 事件，48.9% 在调用窗内**（vs 占空 25.5%，p≈1e-15）；窗外 217/219 条与"写在调用窗内（滞后 ≤5 ms）"相容（记录驻留 ~5 ms）⇒ **无空闲期写证据**。

## 二、Phase-2 交接：脉冲式 RO + 缺页归因

### 2.1 为什么要做

上表 3 条约束说明：**"受害者运行 + 该页 RO 长窗"物理上不可能**（受害者每步都在写该槽），"停放 + RO 长窗"**无法回答 PTE 问题**。唯一出路是 **脉冲式 RO**：短 RO 脉冲（0.5–1 ms，受害者保持运行）＋ 缺页归因。

### 2.2 两层判据

| 脉冲窗内观察到 | 判 | 等级 |
|---|---|---|
| 家族形状记录（页内容变化，排除受害者自身写） | **写穿只读页 ⇒ 非 CPU（DMA）** | **E4** |
| fxhook（缺页钩子）捕获**非 victim 线程**的写缺页（esr=write, addr∈守护页） | **CPU 写，当场点名（PC/comm）** | **E3/E4** |
| 两者皆无 | 暴露不足/未判定 | ≤E1 |

### 2.3 装置需求（待构建）

| 件 | 内容 | 状态 | 风险 |
|---|---|---|---|
| **脉冲模式** | scanary_ro 新模式 `--pulse ON_MS OFF_MS`：受害者在活帧保持期间，helper 定期 mprotect RO/RW 交替；受害者 SIGSEGV handler + siglongjmp 恢复（自身故障计数排除） | **未构建**（v1.18 无此模式） | 中：siglongjmp 在 vsnprintf 中间不安全，需评估 checkpoint 策略 |
| **fxhook 模块** | 内核模块钩 do_page_fault 路径（bl-站点 patch，参考 dphook/dmahook 手法），仅记录 addr ∈ 守护页范围的缺页（esr write / pc / comm / ts），ring buffer + /proc | **未构建** | **高**：hook 自身缺陷 = panic；需 LK 救砖兜底 |
| 单实例断言 | v1.13+ 已有（INSTANCES count>0 ⇒ exit 2） | ✅ 已实现 | — |

### 2.4 分级执行建议

1. **Phase-2a：脉冲模式单独跑**（零内核风险）——能判 **DMA vs 非 CPU（E4）**，不需要 fxhook。
   - 暴露核算：RW 臂 λ ≈ 6.5 runs/min（1295 B / 65 runs / 600 s）；脉冲占空 50% ⇒ 1200 s 窗期望 ≈ 39 runs ⇒ **功效充足**。
   - 受害者 handler 恢复：每个 fault 估 ~10 µs（mprotect + siglongjmp），50% 占空下 1200 s 内 ~600 K 次 fault（每次 10 µs = 6 s 开销，可接受）。但如果 fault 导致 vsnprintf 输出截断，需确认数据完整性不受影响（仅实验）。
2. **Phase-2b：fxhook 模块**（仅在 Phase-2a 判出"非 DMA"后装载，用于点名 CPU 写者上下文）。
   - 装载前：先"观察 10 min 零实验"验证模块无副作用；装载用 devop 持锁；LK 救砖路径写在预注册文档。
   - 风险最高：hook 自身缺陷 = panic。skeptic 必须签字放行。

### 2.5 暴露核算模板（预注册必含）

| 参数 | 来源 |
|---|---|
| RW λ | 同状态（运行态）RW 臂：页内 runs/min（昨晚 6.5/min，如 WiFi 客户端活跃可更高） |
| 脉冲占空 | ON_MS / (ON_MS + OFF_MS) |
| 窗总长 | 每臂秒数 |
| **期望变更数** | λ × 窗总长 × 占空 |
| **最低门槛** | 期望 ≥ 3 才开窗；否则 INVALID-by-confound（同款规则） |

### 2.6 前置条件

1. nerepair 保持 **dry**（冻结，不布防）——kmsg 依赖无关（本实验不读 kmsg）。
2. 单实例断言（v1.13+ 内置）。
3. 有 WiFi 客户端流量时段跑（λ 可高 1–2 个数量级，功效更好）。
4. LK 救砖路径确认可用（tools/lk_flash_v4.py）。

## 三、本轮（U-A2）为何中止

- 两个构建子代理在完成前挂掉（未能产出脉冲模式或 fxhook 模块），Lead 决定中止本轮。
- 设备零污染：无新增文件、无新进程、nerepair dry 状态未动。
- 仓库状态：仅 docs/review/ 与 tools/oneoff/ 新增（均 untracked），无 tracked 文件改动。

## 四、给下一位操作者的建议

1. 先读 U-A1_ROPTE_2026-11-04.md 全文（理解为什么"停放+RO"不行、"脉冲+活跃"才能行）。
2. 从 v1.18（sha256 `de57e952…`，77,064 B）开始加 `--pulse` 模式：在 `ro_victim_window()` 中去掉 futex 阻塞，改为 helper 定期切换 RO/RW、受害者 handler 捕获自身 fault。
3. fxhook 模块参考 `tmpfiles/repro/kmod/` 和 `tools/oneoff/sigsegv/` 下的既有 hook 手法（dphook/dmahook/tuphook）。
4. 跑之前先测**同状态 RW λ**：λ<10/600s ⇒ 不开 RO 臂。
5. 有 WiFi 客户端流量时跑（C-204：写者率可高 1–2 个数量级）。
