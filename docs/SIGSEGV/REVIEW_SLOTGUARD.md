# REVIEW · 兜底加固（nerepair v2.2 / slotguard v1.0）— 自审与故障路径

> 状态：**离线完成，未上机**。本文是上机前必须逐条打勾的自审清单；
> 设计细节见 [SLOTGUARD_DESIGN.md](SLOTGUARD_DESIGN.md)。

---

## §1 自审：三条定律逐条对照

| 定律 | 本组件哪里可能踩 | 实现里的处理 | 复核方法 |
|---|---|---|---|
| **定律一：集合 vs 单点** | 同名 daemon 多实例（dnsmasq 双实例、dropbear 多会话）只处理一个 | 主循环遍历 `/proc` **全部** pid，每个 pid 独立算 `start_stack` 与 per-(pid,slot) 状态；不缓存"第一个 pid" | `ps` 造两个同名进程 → 应出现两行 `MATCH`（不同 pid） |
| **定律二：子串 vs 精确** | comm 用子串/正则匹配 → 提一句名字的进程被当成目标 | comm 取自 `/proc/pid/stat` 括号内**整 token** `strcmp`；不读 cmdline、不用 `pgrep -f` | 写一个 argv 含 `dnsmasq` 的 shell，不应出现在日志 |
| **定律三：观测者污染** | slotguard 自己/nerepair/祖先被扫描或写入 | 启动时沿 PPid 链取祖先集，主循环跳过 self 与祖先；目标 comm 必须等于白名单 | `slotguard --once` 的输出里不应出现 `slotguard` 自身 |

**额外一条（本项目踩过的 LLP64 坑）**：记录字宽必须固定。生产 `nerepair.c` 用 `unsigned long`
（aarch64 = 64 位）；host 测试通道是 LLP64，生成器把抽取出的函数**文本级加宽**为
`unsigned long long`，避免宿主截断 q 字导致"测试通过但判据是错的"。

---

## §2 离线验证证据

| 项 | 命令 | 结果 |
|---|---|---|
| nerepair 扩展判据 | `_local/work/slotguard/nerepair_v22_test.exe` | **22/22 PASSED**（v2.0 路径未回归、v2.0 缺口可复现、X1/X2/X3 生效、指令分类 7 项） |
| slotguard 判据+决策 | `slotguard_host.exe --selftest` | **23/23 PASSED**（7 条自然 NE 记录全接受、7 条负样本全拒、B0A2 接受、14 条决策矩阵） |
| 生产构建 | `sh tools/build_nerepair.sh` / `build_slotguard.sh` | 静态 aarch64，`-Wall -Wextra` 零告警 |
| 语料数字 | `corpus_stats.py` / `natne_scan.py` | 150=114+36；A>0x20000 2/114；B0A2 全 ≥16 MiB；自然 NE 7 条同族 |
| 版本门 | `python tools/vercheck.py check` | OK（209 登记文件 / MANIFEST 92 项） |
| 泄漏门 | `python tools/leak_check.py` | 工作树 0 命中（历史仍有旧提交命中，见 §6） |

---

## §3 故障路径矩阵（上机后逐条对照）

| 触发 | 预期日志 | 预期行为 | 若不符合 |
|---|---|---|---|
| 正常观察 | `MATCH off=… form=…`、`WOULD_SANITIZE reason=not-armed` | 0 次写 | 检查 config/arm |
| 槽在 sp 之上 | `SKIP reason=above-sp` | 不写 | **这是正确行为**，不是故障 |
| 进程在跑（R） | 无 `SANITIZE`（只累 `skip_state`） | 不写 | 同上 |
| `/proc/pid/mem` 不可写 | `PERM … observe-only for this session` | 终身只观察 | 记录内核 Yama 配置；**不得**绕过 |
| 写后回读不符 | `WRITE_MISMATCH … slot latched off` | 该槽本会话不再写 | 立即 `rm slotguard.arm`，取证 `pre=`/`sp` |
| 跟写者打架 | 60 s ≥5 次 → `STORM … 600s cooldown`；≥30/min → `ALERT` + watchdog WARN | 退火/告警 | 把该槽改回 `observe` |
| 目标重启/换栈 | `ss2 != start_stack` → consec 归零、重新学习 | 不写 | 检查是否有 `pid` 复用误判 |
| slotguard 自身死亡 | 心跳停 → watchdog `svc_supervise` 拉起 | 自动恢复 | 若反复拉起，先摘 SVC_TABLE 行 |
| nerepair 未布防 XREP | `WOULD_XREP path=x1|x2|x3` | 不修、信号照旧 | 这是**默认**；不要当成故障 |

---

## §4 危险面复核（为什么这些门不能删）

1. **门 6（槽在 sp 之下）是唯一"证明不会覆盖活帧"的依据**。删掉它，slotguard 就退化成
   "按偏移盲写别人栈"，与外部写者同类 —— 这是本设计最不可让步的一条。
2. **门 8（写前重读）防 TOCTOU**：`/proc/pid/syscall` 的 sp 与真正写入之间隔着若干 syscall，
   目标可能已换栈。实测槽在 sp 下方 0xe0..0x1890，余量 128 B 只是下限，不是安全证明。
3. **门 11（写后回读）防"以为写了其实没写"**：`/proc/pid/mem` 可能部分失败；
   回读不符即锁定该槽，避免每 3 s 重复一次无效写。
4. **双钥匙**防"改配置即生效"：config 是白名单，arm 文件是总开关。二者同时存在才可能写。
5. **不用全零**：见设计 §3。全零把家族崩溃换成 NULL 崩溃，nerepair 不修 NULL —— 等于没兜底。

---

## §5 已知限制（不要当成已解决）

| # | 限制 | 影响 |
|---|---|---|
| L-1 | **未上机**：`/proc/pid/mem` 对非 tracee 的写权限未实测 | 可能整条写路径永久 `PERM`（那就只剩观察价值） |
| L-2 | 槽偏移来自 sampler2 的一份 lab 日志（E1），跨构建可能漂移 | 自学习只发现、不提权；偏移错 = 永远不命中，不会误写 |
| L-3 | `start_stack` 在进程重启后变化；pid 复用会让旧状态短暂串台 | 每轮重取 + `ss2 != start_stack` 归零；最坏是漏一轮 |
| L-4 | 记录可能在被我们清零后又写回（写者未停） | 预算/退火/告警；**不要**把"速率不降"当失败，也不要"提速硬刚" |
| L-5 | X2/X3 的正确性依赖"同一记录的不同地址形态"这一证据（E2） | 默认观察；布防需 `WOULD_XREP` 与 `SEGV` 逐条对照 |
| L-6 | nerepair 的 `record_at(x2-0x240)` 假定副本偏移恒定 0x240 | canary 66/82 支持；自然 NE 未验证该副本 |
| L-7 | 遥测只覆盖"我们写了什么"，不覆盖"写后是否被再次污染" | 需与 sampler2/槽速率联读 |

---

## §6 仓库状态与遗留

- 本轮新增/修改的登记文件已 bump 并 `vercheck` 全绿；`docs/ARCHITECTURE.md` 由 `vercheck.py render` 重生成。
- `tools/leak_check.py` 工作树 0 命中；**历史扫描仍有旧提交命中**（`eed2b8b`/`9f8d0bf`/`c20b785` 等
  对 `docs/SIGSEGV/01_CLAIMS.tsv` 等旧文件）。历史重写不在本轮范围，需单独决策。
- 本轮顺手修正一处已提交文档里的私有仓名（`05_LOG/2026-11-03-12-…md` 第 110 行），改为
  `<private-repo>` 中性引用 —— 这是工作树门禁变绿的必要条件。
- 未提交任何 `tools/oneoff/`、`tmpfiles/` 内容（他轮工作产物）。

---

## §7 上机前最后三问（任一答不上就不布防）

1. 目标槽在**当前构建**上还能稳定命中吗？（`--once` + 24 h `MATCH` 计数）
2. 那个槽**确实在 sp 之下**吗？（日志里 `SANITIZE`/`SKIP` 的 `sp=` 与 `va=` 直接比）
3. 写失败/回读不符时，**谁**会去看？没有人看就不要布防 —— 告警不是给人看的装饰。
