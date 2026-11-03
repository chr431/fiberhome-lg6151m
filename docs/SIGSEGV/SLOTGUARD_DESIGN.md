# SLOTGUARD · 兜底加固设计（v1.0，2026-11-03，离线完成、未上机）

> 目标：即使家族记录的生产者**永远找不到 / 不可修改**，也要有一条不依赖生产者的可靠兜底。
> 本轮交付 = **nerepair v2.2（覆盖普查 + 三条受门控的扩展修复）** + **slotguard v1.0（热槽主动消毒）**。
> 两者都**只做后果层**：不停止外部写入（FIX.md R-11 仍然成立）。

---

## §0 交付摘要（5 行）

1. **缺口是量化出来的，不是猜的**：150 条实录语料 **114 A0B2 / 36 B0A2**；path 2 的 16 MiB 门把 **B0A2 全部 36 条（24%）结构性排除**。
2. **v2.0 自身还有一处判据错位**：deref 的 q0 分支用 `len_band(lo0)` 校验 **A 值**（长度带），实测自然 NE **7 条里 6 条** A>0x20000 会被拒。v2.2 以 `shape_ok` 硬门修正，**默认只记录**。
3. **slotguard 用「槽」把修复提前到消费之前**：3 s 周期读白名单槽，strict 记录判据命中且 **11 道危险面门全过**才写；写回值是**槽自身地址**（不是全零 —— 全零会把下一次 pop 变成 NULL 崩溃）。
4. **双钥匙布防**：出厂 config 全部 `observe`；写需要 `mode=sanitize` **且** `/data/gw/slotguard.arm` 存在。任何不确定性只记录、不写。
5. **离线验证**：nerepair 扩展判据 host **22/22 PASSED**；slotguard 内建 selftest **23/23 PASSED**；两产物静态 aarch64 构建 md5 见 §8。**未部署、未上机**。

---

## §1 语料与缺口普查（可复现）

### 1.1 自然 NE 语料（4 份 `.stack`，7 条记录）

```
python -I _local/work/crash-root/fix/natne_scan.py
→ FILES=4 RECORDS=7，全部 A0B2
  w0 = 0x20090 0x20085 0x23648 0x1c949 0x21d50 0x21d43 0x22aaf
  q2 = 0x04D08ADE0000062F（len=1583, ip=222.138.208.4）
  位置 top-va = 0x7158 0x7010 0x1438 0x77c0 0x6e98 0x6d50 0x1390（深度各异）
```
**结论**：7 条里 **6 条 A > 0x20000**。这正是 v2.0 `len_band(lo0)` 会拒绝的区间 —— 见 §2.3。

### 1.2 150 条实录语料（canary 转储）

```
python -I - <<'EOF'
lines=[l.strip() for l in open('_local/evidence/crash-root/h4_rec150.txt') if l.strip()]
...（脚本见本轮 REPORT 附录；统计 w0/w1/w2/w3 两行一条）
EOF
→ records 150; A0B2 114; B0A2 36
  A0B2 w0 ∈ [0xd968, 0x20282]（仅 2/114 > 0x20000）
  B0A2 w0 恒为 0x0109a8c000000649（≈ 2^56，全部 ≥ 16 MiB）
  len ∈ [1601, 1664]
```
**结论**：B0A2 的**故障地址就是 {len,ip} 复合字**，永远 ≥16 MiB ⇒ `DEREF_SMALL_MAX` 门把它们全部排除。

### 1.3 稳定槽（sampler2 日志，2026-11-01）

```
grep HIT _local/evidence/crash-root/sampler2.log | ... top_minus_rec=...
→ nerepair 0x3b0 (3065) / 0x12d0 (3197)；dnsmasq 0x1b40 (3197)
  dnsmasq 槽内容恒定（陈旧记录）；nerepair 0x3b0 的 q0 有多种取值（热槽）
```
**判读注意（测量工具缺陷，记录在案）**：`sampler2.c` 把 `/proc/pid/syscall` 的
`arg5/sp` 误读成 `sp/pc`，日志里的 `sp=` 实际是 arg5、`pc=` 才是真 sp。按 `pc=` 复算，
**槽位于 sp 之下**（nerepair 槽比 sp 低 0xe0；dnsmasq 槽比 sp 低约 0x1890）——
这是 §4 危险面「只写 sp 之下」的实测依据。

### 1.4 缺口清单（本轮要覆盖的形态）

| # | 形态 | v2.1 行为 | 证据 | v2.2 处理 |
|---|---|---|---|---|
| G1 | deref 型、故障地址 = B0A2 复合字（≥16 MiB） | 直接 PASS（结构性） | 36/150 | **X2**（默认观察） |
| G2 | deref 型、故障地址 = q0 且 A>0x20000 | `len_band(lo0)` 拒绝 | 自然 NE 6/7 | **X3**（默认观察） |
| G3 | pop 型、记录在第二副本 `x2-0x240` | 只查 x2 | 66/82 canary | **X1**（默认观察） |
| G4 | store / 寄存器偏移 load / LDP / FP 承载记录 | 只记 `NEAR reason=insn` | 无量化 | **XFORM 普查**（不修） |
| G5 | `si_addr==0` 且记录 q0==0 | 与真 NULL 不可区分 | 语料无 | **XFORM form=null**（永不修） |

---

## §2 nerepair v2.2（判据扩展）

### 2.1 新增观察（默认行为，不修）

- `XFORM form=popcopy|bigderef|regload|ldp|store|fp|null|other sig=x2|stack`：
  记录存在但指令形态/地址形态在射程外时的**逐类计数**。
- STAT 行新增：`xrep=<0|1> xw=<WOULD_XREP> xr=<XREPAIR> xform=<popcopy>/<bigderef>/<regload>/<ldp>/<store>/<fp>/<null>/<other>`。
- 成本上限：观测扫描只对「地址可能来自记录」的故障触发（小地址或复合字低 32 位在长度带），
  且整机 `xform_budget()` 限 **50 次/s**（崩溃风暴下不会退化成扫描器）。

### 2.2 三条扩展修复（**默认关**）

布防：`/data/gw/nerepair.xrep` 存在，或 `NEREPAIR_XREP=1`；未布防时只打 `WOULD_XREP path=x1|x2|x3`，
寄存器不动、信号不吞、进程照死 —— **自然 NE 普查口径因此保持可比**。

| 路径 | 条件（全部必须） | 动作 |
|---|---|---|
| **X1** | pop 型（rt==rn、si_addr==Xt）+ `record_at(x2-0x240, si_addr)` 通过 | `regs[rt]=sp; pc+=4` |
| **X2** | load + 地址 ≥16 MiB 且低 32 位在长度带 + `[sp,sp+16K)` 内 `q0==si_addr`（tag 掩码）+ `shape_ok` | `regs[rn]=sp; pc+=4` |
| **X3** | load + 小地址 + v2.0 全拒后，`q0==si_addr(±8)` + `shape_ok` | `regs[rn]=sp; pc+=4` |

**为什么 X3 是修正而不是放宽**：`shape_ok` 才是全项目统一的硬门（它检查的是记录里真正的长度字），
`len_band(lo0)` 把 A 值当长度带属于判据错位。X3 仍然要求**记录在故障线程栈内**且 `shape_ok` 通过。

### 2.3 明确不修

store（把基址改到 sp 会往栈上写）、LDP（一次改两个寄存器）、寄存器偏移 load（地址是 rn+rm，
改 rn 不保证落回栈内）、FP、`si_addr==0`。它们只计数，供 G2b/下一轮决策。

---

## §3 slotguard 判据（内容匹配）

记录形态（strict，两个方向都认）：

```
w1 == 0 ∧ w3 == 0
A0B2: 0 < w0 < 2^24 ∧ w2 = {len, ip} ∧ 0x400 ≤ len ≤ 0x20000 ∧ ip 四段 ∈ [1,254]
B0A2: 0 < w2 < 2^24 ∧ w0 = {len, ip} ∧ 同上
```
比已验过的 strict 形态（0/458752 误报，C-163）**更严**：多一道 IPv4 合理性。
另外要求**同一槽连续 2 次采样命中**（≈6 s）才进入决策。

> **不用全零**：家族判据里 **w0 恒等于被消费的故障地址**（`shape_ok` 的硬约束）。写 0 会让下一次
> pop 得到 NULL → nerepair 明确不修 NULL → 进程照死。写 `{槽地址,0,0,0}` 等价于把
> nerepair 的「指向栈」修复**提前施加**：该页已映射、首字是地址自身，任意次解引用都成功，
> `%s` 读到地址字节里的 NUL 即停；w2 清零使 memcpy 长度=0（no-op）。

---

## §4 危险面控制（11 道门，缺一不写）

| # | 门 | 失败时 |
|---|---|---|
| 1 | 槽在 config 且 `mode=sanitize`（comm 精确 token） | 只记 `WOULD_SANITIZE` |
| 2 | `/data/gw/slotguard.arm` 存在（第二把钥匙） | 同上 |
| 3 | 内容 strict 命中（§3） | 计数/重置 consec |
| 4 | 同槽连续 ≥2 次命中 | 等待 |
| 5 | 进程状态 `S`（sleeping） | `SKIP reason=state` |
| 6 | `/proc/pid/syscall` 给出 sp，且 `va+32+128 ≤ sp`（槽严格在未使用栈区） | `SKIP reason=above-sp` |
| 7 | `va` 在 `[stack]` VMA 内、8 对齐、不落保护页 | `SKIP reason=range/align` |
| 8 | 写前**重读**内容 + 状态 + sp，任一变化即中止 | `SKIP reason=state-changed/content-changed` |
| 9 | 每槽每小时预算（默认 120）+ 风暴退火（60 s 内 5 次 → 冷却 600 s） | `BUDGET` / `STORM` |
| 10 | 从未出现 `/proc/pid/mem` 权限失败 | `PERM` → **本进程终身只观察** |
| 11 | 写后回读必须等于 `{va,0,0,0}` | `WRITE_MISMATCH` → 该槽**本会话永久锁定** |

**为什么门 6 是硬的**：aarch64 栈向下生长；`sp` 之下是未使用区（信号帧也只会更低），
写它不可能覆盖任何活帧。实测槽在 sp 之下 0xe0..0x1890（§1.3）。
**门 8 防的是竞态**：读 sp 与写之间目标可能醒来/换栈；重读不一致就放弃这一轮。

**白名单**：`gw/slotguard.conf`（出厂三槽全 `observe`）。自学习只写 `CANDIDATE` 行
（同 comm+offset 在 ≥3 个采样里命中），**永不自动提权** —— 提权 = 一次 config 编辑。
**进程集合**：`/proc` 全量扫描 + comm 精确比较 + 排除自身/祖先（定律三）；多实例全部纳入（定律一）。

---

## §5 遥测（台账 / 心跳 / 速率告警）

| 产物 | 字段/语义 |
|---|---|
| `/data/gw/logs/slotguard.log` | TSV：`epoch iso pid comm event detail`；1 MB 轮转 1 代；40 行/s 限流 |
| `SANITIZE` 行 | `off va form pre=w0,w1,w2,w3 post=va,0,0,0 sp state writes_1h` —— 台账四要素：时间/pid/家族/槽/动作 |
| `/tmp/slotguard.hb` | uptime 秒（watchdog `svc_supervise`，max-hb-age 180） |
| `/tmp/slotguard.stats` | `sweeps/match/would/wrote/live/state/perm/other/cand/alert/total` |
| `/tmp/slotguard.alert` | 仅在高速率期间存在：`ts rate total slot`；**watchdog 2 s 快路径**只报跨档（进入一条、恢复一条） |

告警阈值：**30 次/分**。含义 = 写入者以不低于我们的节奏回填（在跟写者打架，收益为零且有风险），
或槽判据假阳性。两种都该立刻人工看，而不是继续写。

---

## §6 回滚与故障路径

| 现象 | 处理 |
|---|---|
| 任何异常/存疑 | `rm -f /data/gw/slotguard.arm` → 立刻只剩观察（无需重启，下一轮生效） |
| 要彻底停 | `killall slotguard`；改 `gw/slotguard.conf` 全 `observe`；从 `svc_lib` SVC_TABLE 摘 `slotguard` 行并重启 watchdog |
| `WRITE_MISMATCH` / `WRITE_FAIL` | 该槽已自动锁定；查 log 里的 `pre=` 与 `sp`，确认是否竞态 |
| `STORM` | 该槽 600 s 冷却；把 config 里该槽改回 `observe` 并记录 |
| `ALERT` | 先看 `SANITIZE` 行的 `pre=` 是否同一内容反复出现（跟写者打架）→ 改回 observe |
| nerepair 扩展路径异常 | `rm -f /data/gw/nerepair.xrep` + `killall nerepair`（launcher/watchdog 拉起即回默认只观察） |
| `/proc/pid/mem` 权限不足 | 自动终身只观察，log 有 `PERM`；不影响任何既有功能 |

---

## §7 部署前置清单（**本轮不部署**）

1. **同一批次、按顺序**：`gw/bin/slotguard`（二进制）→ `gw/slotguard_launch.sh` → `gw/slotguard.conf`
   → `gw/svc_lib.sh` → `gw/watchdog.sh` → `gw/rc.extend.sh` → `gw/bin/nerepair`（v2.2）。
   SVC_TABLE 行先于二进制落地会让 watchdog 反复拉起失败（launcher 明确 exit 1）。
2. 落盘 md5 必须等于 §8；`chmod 755` 两个二进制（`put` 不保留权限位）。
3. **先跑零副作用自检**：`/data/gw/bin/slotguard --selftest`（必须 23 项 PASSED）
   与 `/data/gw/bin/slotguard --once`（一次扫描、stdout、不写任何文件）。
4. 观察窗口 ≥24 h：`grep -c WOULD_SANITIZE`、`grep CANDIDATE`、`grep -E "SKIP|PERM|MISMATCH"`。
   **布防门禁**：CANDIDATE 逐条研判为真家族 ∧ `WRITE_MISMATCH=0` ∧ `PERM=0` ∧
   至少一个槽稳定命中（≥2 连续采样）∧ 该槽在 sp 之下。
5. 布防：把目标槽改为 `mode=sanitize` → `touch /data/gw/slotguard.arm` → 观察首条 `SANITIZE` 的
   `post=` 与 `state=S`。
6. nerepair XREP 单独评估：先看 24 h 的 `WOULD_XREP path=x1|x2|x3` 计数与逐条 `SEGV` 对照，
   再决定是否 `touch /data/gw/nerepair.xrep`（与 dry-run 互不影响，两者可叠加）。

---

## §8 产物

| 文件 | 大小 | md5 |
|---|---|---|
| `gw/bin/nerepair`（v2.2） | 83,800 B | `811b3e195132224296fc97fa60495760` |
| `gw/bin/slotguard`（v1.0） | 76,088 B | `eec51be427f3b03f9eba167228d57a4f` |

构建：`sh tools/build_nerepair.sh`、`sh tools/build_slotguard.sh`（zig cc aarch64-linux-musl，全静态）。
离线验证：`nerepair_v22_test`（22 项，从生产源抽取判据，非拷贝）、`slotguard --selftest`（23 项）。

---

## §9 残余风险

| # | 风险 | 级别 | 说明/对策 |
|---|---|---|---|
| S-1 | 写入者仍未被点名；**写入继续** | E3 | 本组件只是把「消费窗口」缩短，不停止写入 |
| S-2 | 槽判据假阳性 → 改写活数据 | 中 | 11 道门 + 连续 2 次 + sp 之下 + 白名单；仍非零 |
| S-3 | 目标进程在我们写之后立刻回到该深度并用该槽 | 中 | 槽位于 sp 之下 ⇒ 需要先「向下长栈」才会用到；写后回读只证明写入成功，不证明之后没被覆盖 |
| S-4 | `/proc/pid/mem` 权限模型未上机验证 | **待验** | Yama/权限失败 → 自动终身只观察（fail-closed） |
| S-5 | 槽偏移随构建/进程版本漂移 | 中 | 自学习 CANDIDATE + `start_stack` 每次重取；pid 变即重新计数 |
| S-6 | 与写者打架（回填速率高于我们） | 中 | 每小时预算 + 风暴退火 + 30/min 告警 |
| S-7 | nerepair X2/X3 修的是「同一记录的不同地址形态」这一假设 | E2 | 默认观察；`WOULD_XREP` 需与 `SEGV` 逐条对照后才布防 |
| S-8 | sampler2 日志字段错位（sp/pc）曾被当真 | — | 本轮已记录；引用槽位置时必须用 `pc=` 复算 |

---

## §10 复核命令

```sh
# 自然 NE 记录
python -I _local/work/crash-root/fix/natne_scan.py
# 150 条形态分布（A0B2/B0A2、A>0x20000 计数）
python -I _local/work/slotguard/corpus_stats.py
# 扩展判据 host 断言（22 项）
python -I _local/work/slotguard/mk_nerepair_v22_inc.py \
  lg6151m-public/gw/src/nerepair.c _local/work/slotguard/nerepair_v22_under_test.inc
_local/work/slotguard/nerepair_v22_test.exe
# slotguard 判据+决策（23 项）
_local/work/slotguard/slotguard_host.exe --selftest
```
