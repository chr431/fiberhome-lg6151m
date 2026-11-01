# FIX v2 · LG6151M 32B 记录 SIGSEGV 家族（2026-11-01 重写版）

> **写给谁**：接手这个案子、但没参与前几轮的人。读完这一页你应该知道：现在有哪些防线、边界在哪、
> 什么还没修、下一步做什么、怎么验证、怎么回滚。
>
> **不可引用已撤回结论**：88/112、自然 NE 0/4、「Transport = PA/DMA（E2）已定」。当前口径见
> [00_STATE.md](00_STATE.md) 与 [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)（**对外表述以记分卡为准**）。
>
> 级别：**E1** 弱/单点 · **E2** 强推断 · **E3** 直接观测 · **E4** 因果闭环。每条结论后附「复核」＝自己验一遍的方法。

---

---

## 交付摘要（给用户看的 5 行）

1. **覆盖两类崩溃**：pop 型（v1.7 起；行为级正/负对照 E3：自注入记录 SURVIVED rc=0、`kill -11` 仍 rc=139）＋ deref 型（v2.0 新增；判据函数 17 项 host 断言全过，E2）。
2. **不停止写入**：写入者未点名，nerepair 只在「后果层」生效（C-149，E3）—— 崩溃少了，内存破坏面不变。
3. **只覆盖这两类形态**：其余形态不修，仅记 `NEAR reason=insn` 计数（v1.9.2 起），规模由 G2b 门禁强制上报。
4. **slotdrop 是诊断模式（默认关）**：给 faultwatch 造一个已被证明会被写的目标；抓到栈就删标记（§9.8）。
5. **部署/回滚/LK 救砖**：见 §9（逐条命令，含 `killall nerepair` 回滚与串口救砖）。

## §0 一页纸（诚实版）

### 0.1 现在有什么

| 防线 | 状态 | 一句话 |
|---|---|---|
| **nerepair**（ptrace 监督者） | **v2.1 已交付、待 lab 部署**（`gw/bin/nerepair` 79,840 B，md5 `9ae78c4a52f108ecccc6fd69b5ea3394`）；设备**现役仍是 v1.7**，`rc.extend v3.3` + `nerepair_launch.sh` 拉起 | 两条判据路径：**pop 型**（故障指令 `ldr Xt,[Xt]` 且 `si_addr==Xt` 且 x2 处是本家族记录）与 **deref 型**（记录值被当指针继续用）。**其余形态一律放行**（进程照死） |
| **本轮新增** | v2.0 / v2.1 | **deref 型覆盖**（记录证据是硬门槛，判据函数 17 项 host 断言全过）+ **slotdrop 诊断模式**（默认关，见 §9.7/§9.8） |
| **观测：core_meta v1.9 + .stack** | 已部署 | 每次真死进程落 `.stack`（65,592 B = 48 B 头 + 位图 + 16 页）+ `ne_events.tsv` 台账 |
| **观测：NEAR 计量器** | **已构建、未部署**（v1.9.2） | 记录在 x2 但指令形态不在射程内时记 `NEAR reason=insn` —— 把「已知不覆盖」量化的唯一手段 |
| **补偿控制：pageguard** | **已构建、未上机** | 「RX 环缓冲页永不给用户匿名页」。**其前提（按 PA 写）正在被重审**（§2/§3） |
| **验收指标：槽重写速率** | **已有工具**（lab 的 sampler2） | 对 daemon 栈上的固定 32 B 槽测「单位时间内容变化次数」＝**写入活性**；不依赖崩溃，是 §4 的**主判据**（E1 待复核） |

### 0.2 nerepair 的覆盖边界（必须逐字理解）

**v2.0 起有两条判据路径**（v1.7 只有路径 1）：

```
路径 1（pop 型，v1.0–v1.7 已有）
repair ⇔ insn ∈ {LDR/LDUR/LDRB/H/SW 的自指形式}  ← A
       ∧ rt == rn                                ← B
       ∧ si_addr == regs[rt]                     ← C
       ∧ shape_ok(x2 处 32B, si_addr)            ← D
       → regs[rt] = sp; pc += 4; 信号吞掉

路径 2（deref 型，v2.0 新增）
repair ⇔ insn 是 load（任意形式，非 store、非 FP）      ← A2
       ∧ 0 < si_addr < 16 MiB（不可信小值）             ← B2
       ∧ rn != 31（基址不是 sp）                        ← C2
       ∧ [sp, sp+16KB) 内存在 32B 记录：q0 或 low32(q2)
         == si_addr（或 ±8），且 w1==w3==0、len 在带内  ← D2（硬门槛）
       → regs[rn] = sp; pc += 4; 信号吞掉
```
- **路径 1 优先尝试**，失败才走路径 2（避免 deref 判据"抢走"已被证明有效的 pop 修复）。
- **D2 是硬门槛**：没有记录证据就绝不修 —— 这是"不掩盖真实 NULL/bug"的唯一保证。
- **只修 load，绝不修 store**：把 store 的基址改到 sp 会往栈上乱写。

**两条参数取值的证据（不是拍脑袋，Lead 已批准偏离原始规格）**

| 参数 | 取值 | 证据 | 若按原规格会怎样 |
|---|---|---|---|
| **si_addr 上界** | **16 MiB**（原始规格 0x10000） | 家族实录 `w0`（=故障地址）分布：**0–597004，中位数 102011，1733 个不同取值**（`_local/evidence/crash-root/h4_rec150.txt`，150/150 的 w0 全 < 2²⁴；09_CONDITIONAL 结果 5）；`len` 侧 1601–72085 | 用 0x10000 会把**中位数以上（>65,536）的全部样本**排除 —— 按实录估计漏掉 **>95%** 的真实命中 |
| **栈内扫描步长** | **8 B**（原始规格 16 B） | 4 份自然 NE `.stack` 的记录**页内偏移**：`0x8ea8 / 0x8ff0 / 0xebc8 / 0x8840 / 0x9168 / 0x92b0 / 0xec70`（`natne_scan.py` 实测）。对 16 取模：`0x8ea8%16=8`、`0xebc8%16=8`、`0x9168%16=8` ⇒ **7 个样本里 3 个不是 16 对齐** | 16 B 步长会**漏掉 3/7 的真实自然 NE 样本**；8 B 步长多出的开销只是每页 512 次比较（微秒级） |

> 复核：`python _local/work/crash-root/fix/natne_scan.py` 直接打印每个记录的页内偏移；
> `awk '{print $2}' h4_rec150.txt | sort -u | tail` 可看 w0 的量级。
- **已知不覆盖（结构性，非 bug）**：被污染 va_list 产生的**解引用型**崩溃
  （`%s` → `strlen` 里的 `ldrb w2,[x0]`，`rt≠rn`）、非 load 指令、`si_addr≠Xt`、记录不在 x2。
- **行为级正/负对照（E3）**：正控 `rectest`（自注入记录）**SURVIVED rc=0**；负控 `sh -c 'kill -11 $$'` **rc=139**（不修）。
  复核：`grep -E "REPAIR|PASS" /data/gw/logs/nerepair.log`。

### 0.3 没修的是什么

1. **写入者仍未点名**；transport **未定**：H1a（固定 PA 陈旧描述符）与 H4（硬件描述符写回）已**证伪**（E2）；
   活的竞争假设是 **H2（内核 uaccess）/ H5（GUP-pin + 按 VA 取偏移）/ H6（内核用保存的用户 sp + 固定偏移）**（均为「未被排除」，E2）。
2. **记录家族仍在产生**：canary **82/112 = 73.2%**（Wilson 95% CI 64.3–80.5%）。
3. **自然 NE 也有同族**：本批 **4/4** 份自然 `.stack` 含同族记录（`q2=0x04D08ADE0000062F`，len 1583，ip 222.138.208.4），
   位置在 `start_stack−0x1390…−0x7970` 的**不同深度**。**n=4、只覆盖栈尾 16 页，不可外推**。
4. **nerepair 只覆盖一种形态**（§0.2），其余形态**必然漏**，规模待 G2b 测量。
5. **pageguard 未上机、未验证**，且前提与 H1a 证伪冲突，可能整条作废。
6. **SMMU/IOMMU 不可行**（E3，§7.3）；**关 WED offload 不可用**（`rmmod mtk_wed` 1/1 Oops，§7.4）。
7. **根修复可达性取决于 writer 点名精度**：点到函数级 → 可能只需改一处调用点（§7.1）；点不到 → 只能补偿控制。

---

## §1 已部署 / 已具备的防线

### 1.1 nerepair（现状 v1.7 在跑）

| 项 | 值 | 复核 |
|---|---|---|
| 二进制 | `/data/gw/bin/nerepair`（约 46 KB，aarch64 静态） | `ls -l /data/gw/bin/nerepair` |
| 源码/构建 | `gw/src/nerepair.c`（v1.7）+ `tools/build_nerepair.sh`（zig cc） | 读源码头注释 |
| 启动 | `rc.extend.sh v3.3`（v3.6 起经 `nerepair_launch.sh` 走 `svc_lock` 单实例） | `grep -n nerepair gw/rc.extend.sh` |
| 日志 | `/data/gw/logs/nerepair.log`（TSV；1 MB 轮转 1 代） | `tail -20` |
| 心跳 | `/tmp/nerepair.hb`（uptime 秒），watchdog `svc_supervise` 消费 | `cat /tmp/nerepair.hb` |

**覆盖面（E2）**：启动 attach PID 1 + 全 `/proc` 扫描；`PTRACE_O_TRACEFORK|VFORK|CLONE|EXEC` 跟随；`vsurv4` canary 豁免。

**判据**（`shape_ok`）：`w1==0` ∧ `w0∈{fault, fault+8}` ∧（A0B2：小 fault + 大 w2 ｜ B0A2：大 fault + 小 w2）。
v1.7 **不查 `w3`、不查长度带**（加固见 §1.3）。

**已知缺口（代码级确认，E3）**：
- **V1** `scan_proc()` **只在 `ECHILD` 时调用** ⇒ 有 tracee 存活就永不再扫；启动后**非 tracee 后代**的新进程永不 attach。
- **V2** `attach_pid` 3 s 超时即放弃、**无重试** ⇒ 开机繁忙期失败的进程及其子树永久裸奔。
- **V3** 判据只覆盖 pop 型 ⇒ 解引用型崩溃必然 PASS（§0.2）。**规模未测**。
- **V4** v1.7 无 repair 循环熔断（循环内 `ldr` 会无限修复 → CPU 空转）。
- 复核：读 `gw/src/nerepair.c` 的 `main` 循环、`attach_pid`、`is_ldr_same`。

### 1.2 观测层

| 组件 | 内容 | 复核 |
|---|---|---|
| `core_meta v1.9` | 真死进程落 `<bt>-<pid>-<ts>.stack`（65,592 B）+ `ne_events.tsv` | 头 48 B：magic / pid@12 / stack_lo@16 / stack_hi@24 / npages@32 / ts@40；解析脚本 `_local/work/crash-root/fix/natne_scan.py` |
| `.stack` 验证（E3） | 真实死亡进程上通过：65,592 B、`readable=16` | 取任一 `.stack` 跑 `natne_scan.py` |
| **NEAR 计量器** | v1.9.2 新增：三个 PASS 分支里照样读 x2 做形状检查，命中记 `NEAR reason=insn rt= rn= insn= addr=` | 源码 `_local/work/crash-root/fix/nerepair_v192.c`；解析 `ne_sites.py` |

> **陷阱**：arm64 fault 行是 `pr_info` 级，console-ramoops 与持久 syslog **都不收**；权威 = `/data/gw/logs/ne_events.tsv` + `aee_exp` 目录 mtime。

### 1.3 已构建、未部署的 nerepair 版本（均在 `_local/work/crash-root/fix/`，**不在 gw/**）

| 版本 | 增量 | 产物 | 状态 |
|---|---|---|---|
| **v1.8** | 判据加固：`w3==0` + 长度带 `0x400..0x20000` + tag 掩码 | `nerepair_v18.c/.patch` | host 验证通过，未部署 |
| **v1.9 / v1.9.1** | **dry-run**（不修、不吞信号）+ PID1 重试 + (pid,site) 熔断 + inode canary 豁免 + **BIN 行** + NEAR pc | `nerepair_v191.c/.patch`（二进制 48,512 B） | **Lead 已批准做 24 h dry-run** |
| **v1.9.2** | 再加 `NEAR reason=insn`（量 V3 盲区规模） | `nerepair_v192.c/.patch`（49,376 B） | 与 dry-run 同批上 |
| **v2.0（本轮成品）** | **新增路径 2：deref 型**（记录证据硬门槛）+ 按指令形态分类的 NEAR + `DREPAIR/WOULD_DREPAIR` 事件 + STAT `rep2/would2/dfhit` | `gw/src/nerepair.c` + `gw/bin/nerepair`（**52,216 B**，md5 `75e2942489d8c81c14d64691f0d12983`）+ diff `_local/work/crash-root/fix/nerepair_v2_vs_v17.diff`（569 行） | **本轮交付** |

**构建注意（2026-11-01 17:39 定位，影响所有 .ko）**：本树同时暴露 `include/uapi/asm/stat.h`（guard `__ASM_GENERIC_STAT_H`）
与 `arch/arm64/include/asm/stat.h`（guard `__ASM_STAT_H`），两者都在 `-I` 路径上时**任何模块编译**都会
`redefinition of 'stat64'`。修法：编译命令加 **`-D__ASM_GENERIC_STAT_H`**（已写进
`_local/work/crash-root/fix/{hookguard,pageguard}/build_*.sh`）。此前 pageguard"能编"只是 zig 缓存命中，
**从新文件重编会失败** —— 复核方式：`cp pageguard.c /tmp/x.c && echo '//' >> /tmp/x.c` 再编译。

**v2.0 的 host 证据（E2）**：`deref_test.c` 直接 `#include` 由 `sed` 从 `nerepair_v2.c` 抽出的判据函数（非拷贝），
**17 项断言全通过**：指令分类 10 项（ldr/ldrb/ldrh/ldur 判 load；str/strb/add/FP 判非 load）、
真实自然 NE 栈里按 q2 命中并定位到准确 VA、伪造地址/零地址/脏 w1/长度越界 4 项全拒。
复核：`zig cc -O2 deref_test.c -o t && ./t <natne/1793477586-17847-1793509363.stack>`。

**判据加固的 host 证据（E2）**：`nerepair_mask_test.c` 以设备实录 150 条记录为阳性语料 ——
v1.7 接受 **150/150**、v1.8 同样 **150/150**（加固未丢覆盖）；8 条合成阴性样本：v1.7 **误接受 3/8**、v1.8 **0/8**。
复核：`zig cc -O2 nerepair_mask_test.c -o t && ./t <h4_rec150.txt>`。

**dry-run 门禁（预注册）**：G0 ≥24 h 且心跳 <180 s；G1 `WOULD_REPAIR>0`；G2 NEAR 逐条研判非真家族；
**G2b `NEAR reason=insn` 规模必报**；G3 repair-loop=0；G4 PID1 100% 覆盖；G5 无观测者污染；G6 家族 NE 单列。
报表模板 `05_LOG/TEMPLATE-nerepair-dryrun.md`；生成器 `_local/work/crash-root/fix/dryrun_report.py`。

---

## §2 未部署但已就绪的补偿控制：pageguard

> **它是补偿控制，不是根修复**：不点名写入者、不停 DMA，只保证「RX 环缓冲曾占用的物理页」永不被分给用户匿名页。

### 2.1 站点（全部来自 `analysis/kern/vmlinux.elf` 反汇编，带 guard word）

| 角色 | 站点 VA | 原指令 | guard |
|---|---|---|---|
| 生产 | `mtk_rx_alloc_edma` `0xffffffc008596174`、`fe_edma_open` `0xffffffc008589ba0`（`bl __netdev_alloc_frag_align`） | 冷路径 | `0x94086128` / `0x9408929d` |
| 消费 | `alloc_zeroed_user_highpage_movable` `0xffffffc00812724c`、`wp_page_copy` `0xffffffc0082494a4` | `bl __alloc_pages` / `bl alloc_zeroed…` | `0x9404eae9` / `0x97fb7762` |

推导工具：`_local/work/crash-root/fix/{find_callsites.py,site_dump.py}`（离线扫全部 `b/bl`）。**复核**：重跑两脚本即得同表。

### 2.2 代价与安全

- **O(1)**：生产在环装填（冷路径）；消费每次匿名缺页一次哈希查找（2 MiB 表 / 探测 8 步）。
- **有界**：哈希 2 MiB + quarantine ≤1024 页（4 MiB）⇒ ≤6 MiB。
- **可关 / 可卸**：`armed=0` 是 dry-run（只计数不拒绝）；`echo off|on > /proc/pageguard`；`rmmod` 还原全部指令字并归还扣留页。
- **失败退化**：guard 不匹配 → 跳过该站点（不盲打）；quarantine 满 → fail-open 交回页；**绝不把成功分配变成 NULL**。
- **依赖**：本内核无 kprobe/ftrace/perf（`.config` 实证）⇒ 只能调用点 `bl` 打补丁（该手法由 `tmpfiles/repro/dphook.c` 在本设备验证过）。

### 2.3 前提状态：**待判，且当前不利**

要求「受害页曾是 RX 环缓冲页」⇒ 依赖按 PA 写（H1a/H1b）。
但 **H1a 已被几何证伪（E2）**：固定 PA 应导致**页内偏移固定**，实测 **53 种页内偏移**；恒定的反而是 `top−x2=0x390`（VA 相对）。
⇒ pageguard **暂不上机**（Lead 2026-11-01）。**不要把 §2 当成已生效的防线。**

**前提验证的更好做法（Lead 2026-11-01）**：不要只看 `black_hits>0` —— 那只证明机制在转。
用**槽监视器**（§4.0/§5.4）：若 pageguard 真起作用，**槽重写速率应下降**；
但注意它**应当下降而不是停**（写者按 PA 打，PA 被隔离后会改打别的页），所以"降到 0"必须额外解释。
判据组合：**槽速率下降** ∧ `black_hits>0` ∧ **该槽页 PA 被标记** —— 三者同时成立才算前提坐实。

---

## §3 决策树：按 transport 判决决定上什么

| 判决 | 该上什么 | **不该**上什么 | 理由 |
|---|---|---|---|
| **H1b / H3（按 PA 写）** | pageguard 变体 A（生产者 = RX 环装填，原样上机）+ §4.2 的 ABAB 与正对照 | 不要动 nerepair 判据（正交） | 受害页 = 曾经的网络缓冲页 ⇒ 隔离有效 |
| **H5（GUP-pin + 按 VA 取偏移）** | pageguard 变体 B1：**换生产者**为 `unpin_user_page*` 调用点（≈换一张站点表），消费半边复用 | 不要用「RX 环页」当危险集合 | 危险页是「被 pin 过的用户页」 |
| **H2 / H6（uaccess / 按保存 sp 定位）** | **pageguard 作废**；唯一方向 = 给写者那一处调用点加边界检查（§7.1），前提是点名到函数级 | 不要给整个 uaccess 打补丁（数百调用点，成本不可接受） | 无 kprobe/ftrace，只能调用点打点 |
| **未定** | 只做观测：nerepair dry-run（v1.9.2）+ `.stack`/`ne_events` 普查 | 不要上新的补偿控制；不要用 canary 率替代 transport 判决 | 停止规则：没有功效计算的 A/B 不做 |

---

## §4 验收判据：什么算「修好了」

### 4.0 验收分两层（skeptic C-178，**不要混**）

| 层 | 适用对象 | 指标 | 判据 |
|---|---|---|---|
| **层 I · 写入活性** | **只适用于能影响写入的缓解**：pageguard / SMMU / 靶向隔离 | 热槽 distinct-content 重写率（ABAB） | **RR ≤ 0.5 且 95% CI 上界 < 1.0**；**反向保护**：A 两臂之间 RR 必须落在 **[0.7,1.4]**，否则整轮 **INVALID** |
| **层 II · 后果** | **所有缓解；nerepair 只能看这一层** | ① nerepair `REPAIR` 事件率 ② 家族死亡数 ③ 自然 NE | 见 §4.1 / §4.3 |

> ⚠️ **关键（C-149）**：**nerepair 只修崩溃、不停止写入** ⇒ **写入活性预期不变**。
> 若上 nerepair 后看到槽重写速率下降，**先怀疑"进程死了 / 写入者换目标"，不要当成功**。
> 反过来：**上 pageguard 才应该看层 I**（它真的阻断写入落点）。

**功效（skeptic 给的，别再自己算）**：热槽 0.62 次/s ⇒ 10 min 臂约 **372 事件**；
**50% 降幅 1.3 min/臂、20% 降幅 9.5 min/臂**（理想泊松）。
**自然 NE 别当主判据**：0.5/h 基线 ⇒ 50% 降幅需 **94 h/臂**、70% 需 41.6 h、90% 需 21.3 h。

**验收前 8 条假象检查（逐条打勾，缺一条本轮作废）**：
① 进程重启换栈（记 target pid + `[stack]` 边界）② 写入者换目标（同窗监控 ≥3 槽 + 系统级扫描）
③ 观测者污染（停扫描对照臂）④ boot 代次（一轮之内不许跨 boot 比较）⑤ 判据漂移（q0 允 0 / len 区间 / IP 单播 / stride 8–16）
⑥ 幸存者偏差（分母用**臂开始时**的集合）⑦ 均值回归（A 两臂一致性保护，见层 I）⑧ 缓解自身副作用（内存配额/分配失败率；nerepair 类：**无崩溃 ≠ 无写入**）。

### 4.0b 三条指标必须同时报（缺一条不算通过）

| # | 指标 | 工具 | 依赖什么 | 功效 | 级别 |
|---|---|---|---|---|---|
| **①** | **槽重写速率** | **sampler2**（lab 现成二进制） | 不依赖崩溃、不依赖热态 | **最高、最便宜** | **E1（待复核）** |
| ② | canary 命中率 | vsurv4 / h4 转储 | 依赖"热页"状态；跨会话不可比 | 中 | E2 |
| ③ | 自然 NE | `core_meta` + `ne_events.tsv` | 依赖真死进程；基线 ~0.5–4/h | 低（需 ≥24 h） | E2 |

**为什么 ① 是主判据**：②③ 都是**后果**（稀有事件：一次写入恰好落在活指针上才崩），
①直接测**写入活性**（同一地址被反复重写），不经过"崩溃"这一层，因此样本量高 2–3 个数量级。

**但 ① 是代理指标，必须与 ② 在同一窗口内做一致性检查**（同时报，方向须一致；不一致必须解释）。
单独一个 ① 下降不足以宣称修好 —— 写入者可能只是**换了目标**（见 §5.4 的三种假象）。

> **槽（slot）是什么**：lab 的 sampler2 发现，自然 daemon 的栈上存在**位置稳定、内容会被反复重写**的
> 32 B 记录槽：`dnsmasq` 在 `start_stack−0x1b40`、`nerepair` 在 `start_stack−0x3b0`。
> 判据用「单位时间内该槽内容变化的次数」＝**槽重写速率**。
> **「槽存在」与「槽有速率」是两件事（务必分清）**：Lead 转达的两个槽里，
> `dnsmasq`（−0x1b40）在 **113 次采样中内容恒定**（重写速率 ≈0），`nerepair`（−0x3b0）**60 s 内出现 8 种 q0 值**（速率高）。
> ⇒ 恒定内容的槽**不能用于 A/B 判据**（无功效），只能用来确认"这个地址上确实是个记录槽"；
> **判据要的是速率**，必须先用 §4.2 的准入门槛（A 臂 ≥20 次/10 min）筛一遍。
>
> **状态**：lab 新发现，来源为 Lead 转达；**本工作区未复核**（无 sampler2 源码/原始数据）⇒ 记 **E1**。
> 升 E3 需要：①给出采样原始件与行数断言；②同一槽在无流量/有流量两臂的速率差（正对照）；③跨 boot 复现。

### 4.1 止崩层（nerepair）

| 指标 | 判据 | 最小样本 |
|---|---|---|
| 覆盖 | `TracerPid` == nerepair 的用户进程占比 ≥99%（排除 canary/内核线程） | 一次全量扫描 |
| 不误修 | `PASS reason=shape-fail` 中 `w1==0 ∧ w0∈{fault,fault+8}` 的「近失」= 0 | ≥72 h |
| 不死锁 | `reason=repair-loop` < 3 次/天 | 24 h |
| 心跳 | `/tmp/nerepair.hb` 最大间隔 <180 s | 24 h |

### 4.2 止写层（**仅 pageguard / 靶向隔离**）—— 层 I，主判据 = 槽重写速率

**预注册（改动前先写死，事后不许改）**：

| 项 | 规定 |
|---|---|
| 槽的**准入门槛** | 只有「A 臂 10 min 内重写 **≥20 次**」的槽可用于判据；否则该槽**功率不足，不得用于判决**（写"无功效"，不写"阴性"） |
| 槽数量 | **≥3 个槽**同时报（不同进程/不同偏移，避免单点） |
| 窗口 | **同会话、同槽、同一 boot**；每臂 **10–15 min**；ABAB |
| **主判据** | **RR ≤ 0.5 且 95% CI 上界 < 1.0**（skeptic C-178 口径） |
| **反向保护** | **A 两臂之间 RR ∈ [0.7, 1.4]**，否则整轮 **INVALID**（均值回归/漂移保护） |
| 统计 | 泊松率比；必须给 95% CI |
| 代价上限 | 吞吐 ↓≤3%；`softirq NET_RX`/s ↑≤5%；pageguard 的 quarantine 不触上限；**并报分配失败率**（pageguard 引入的新风险面） |

> **注意适用对象**：这一节**不适用于 nerepair** —— nerepair 不停写入，层 I 对它预期"无变化"（§4.0）。

**分阶段**：
1. **单槽定标**（10 min）：确认该槽在你的窗口里真能跑到 ≥20 次重写；跑不到就换槽（这是**功效检查**，不是失败）。
2. **A/B 对照**（2×10 min）：先 `armed=0` 再 `armed=1`，同会话。
3. **合并判读**：两轮都同向才算（单轮差异不算效应 —— 项目停止规则）。

> 旧判据「canary 命中率 B/A <0.2（8 臂 ×5 min）」**降为 ②**，不再单独作为主判据；
> 它依赖热态且跨会话差过 19 倍，只在同会话内有效。

### 4.3 自然 NE 窗口

基线 ~0.5–4/h；**6 h 窗口无功效**（0.5/h 下 P(0)=5%）：24 h 期望 12、P(0)=6.1e-6，才可说「未再发生」；72 h 功效充分。
**口径前提**：测自然 NE 必须停 nerepair；且 dry-run 期间不修 ⇒ **自然 NE 会真的打死进程**，先确认「无其它实验依赖这些进程活着」并写进 drill 记录。

### 4.5 G6 名单规范：「已知会死、dry-run 故意不救」

> 用途：dry-run 不修 ⇒ 家族进程**真的会死**。这份名单是①给厂商的证据 ②armed 后**预期修复量**的基准 ③上线后**回归核对表**。

**采集口径（必须全量，不许抽样）**

| 来源 | 采集方法 | 备注 |
|---|---|---|
| 本会修但没修 | dry-run 下的 `WOULD_REPAIR`（pop 型）与 `WOULD_DREPAIR`（deref 型）行 | 由 `ne_sites.py` / `dryrun_report.py` 的 A7 段自动聚合 |
| 本会修但判据没接住 | `NEAR`（`reason=insn` / `w3` / 长度带） | 这是"射程外"的名单，单独列，**不计入**预期修复量 |
| 真死了的家族 NE | `.stack` 含记录 ∧ fault 地址与记录对齐的自然 NE | 由 `natne_scan.py` + `ne_events.tsv` 交叉 |

**必备字段（缺一列即报告不完整）**

```
comm | pid | site(pc 或 指令形态) | 记录证据(q0/q2/记录 VA) | 首次/末次 epoch | 次数
     | 进程角色(监听父进程 / 一次性子进程 / 守护) | 该角色死亡是否影响服务 | procd/watchdog 是否会重启它
```

**与 armed 的关系（写清楚，别混）**

1. **G6 名单 = armed 后的「预期修复量上界」**：armed 后这些进程**不再死**，所以"自然 NE 计数"应下降 —— 但下降的**上限就是 G6 的条数**，不能宣称超过它。
2. **armed 后必须拿 G6 逐条回归**：名单里的 (comm, site) 若仍出现死亡 ⇒ 修复失败或该例不属于可修形态 ⇒ **立即回滚并复查**。
3. **G6 不是"受害面"**：写入面比死亡面大 2–3 个数量级（08 的算术：约 580 次写机会才 1 次死亡）。**不得用 G6 条数描述问题规模**，只能描述"我们会救活多少"。
4. **服务进程优先**：G6 里"监听父进程/守护"的条目单独标出 —— 它们的收益是服务不中断，比一次性子进程值钱得多。

### 4.4 dry-run → armed 门禁

G0–G6 + **G2b**（§1.3）。任一门不过 = **不得 armed**；裁决句在模板 §9 二选一照抄，不许自造。

---

## §5 回滚与事故处置

### 5.1 nerepair

```sh
killall nerepair                 # tracee 自动 detach，设备不会僵
cp /data/gw/bin/nerepair.v17 /data/gw/bin/nerepair && chmod 755 /data/gw/bin/nerepair   # 回旧版
rm -f /data/gw/nerepair.dry      # 关 dry-run 标记
# 彻底停用：注释 rc.extend.sh 的 v3.3 块
```
- 心跳停更 / watchdog 反复重启 → 看 `/data/gw/logs/nerepair.out`，先 `killall` 再决定降级。
- 某进程被「修」后行为异常 → 查 `REPAIR` 行，确认是否真家族（`w3`/长度带/v1.8 判据）。
- repair-loop 告警 → v1.9 起熔断生效；v1.7 无熔断，只能 `killall`。

### 5.2 pageguard（若已上机）

```sh
echo off > /proc/pageguard      # 立即停用，保留观测
echo unpatch > /proc/pageguard  # 还原全部指令字
rmmod pageguard                 # 归还扣留页 + 释放表
dmesg | tail -40                # 保留现场
```
立即回滚触发：栈里出现 `pg_shim_*`；`consumer.gave_up` >100/min；吞吐 ↓>10%。

### 5.3 事故取证顺序

1. `/sys/fs/pstore/console-ramoops-0`（先落盘，重启即清）；
2. `/data/gw/logs/ne_events.tsv` + `aee_exp` 目录；
3. `/data/gw/logs/nerepair.log`（含 `.1`）按 pid 检索 —— **先 `wc -l` 再分页，断言 fetched == wc -l**；
4. 对应 `.stack` 用 `natne_scan.py` 解析。

### 5.4 如何用槽监视器判断修复是否生效（可复用验收流程）

> 工具：**sampler2**（lab 的现成二进制；源码在 lab 侧，本文不复制）。
> 它做一件事：对若干进程的栈上固定偏移，周期性取 32 B，记录**内容变化次数**＝槽重写速率。

**流程（一次只改一个变量）**
1. **选槽**：枚举候选槽（comm + `start_stack−k` 偏移 + 当前内容 + 变化次数）。
   **只保留在 A 臂 10 min 内重写 ≥20 次的槽**；跑不到的槽写"无功效"，不得当阴性用。
2. **基线 A 臂**（10 min，`armed=0` / 未上修复）：记每槽重写次数 **同时**记 canary 命中数。
3. **改一个变量**：上 pageguard 或切 nerepair `armed=1` —— **同一次只动一个**。
4. **B 臂**（10 min，同槽、同 boot、同会话）。
5. **判读**：B/A <0.20 且 A≥20 且 ②③同向 → **生效**；0.2–0.8 → 部分有效（记并分析）；>0.8 → **无效**。
6. **结论写法**（照抄格式）：`槽 X（comm=…, off=−0x…）: A 臂 n1 次 / B 臂 n2 次，比值 r（95% CI …）`。
   **不得只写"速率下降"** —— 没有槽标识、次数与 CI 的结论不可复核。

**三种"看起来生效、其实没有"的假象（必须逐条排除）**

| 假象 | 表现 | 辨别方法 |
|---|---|---|
| **a. 写入者改目标** | 槽速率降，但破坏面不变 | 查该槽页的 PA：`echo "<pid> <va>" > /proc/patrace`；看该 PA 是否被 pageguard 标记；并看**其它**进程的槽速率是否上升（此消彼长 = 转移，不是修复） |
| **b. 进程重启换栈** | 槽偏移失效/速率归零 | 每次采样重取 `start_stack` 与 pid；pid 变则**重新定标**，不得跨 pid 比较 |
| **c. 观测者污染（定律三）** | sampler2 或 nerepair 自己的栈被算进统计 | 槽的 comm 不得是 sampler2/nerepair/watchdog 自身；判据命令的 cmdline 也不得含被查字符串 |

**pageguard 专用：速率应当"下降"而不是"停"**
- pageguard 只保证「RX 环缓冲页不给用户匿名页」。写入者若按 **PA** 打，PA 被隔离后**那个 PA 现在指向别的物理页**，
  写入者**仍会往那个 PA 写** —— 所以它换了个受害者，而不是停止写入。
- 因此 **①降到 0 是可疑信号，不是好消息**：要么写入真被阻断（需 ②③同步归零作证），
  要么槽页本身被隔离、写者转打他处（此时应看到**别的进程**的槽速率上升）。
- 必须同时报 `black_hits`（pageguard 实际拒绝了多少次"把危险页分给用户"）与该槽页**是否被标记**：
  `black_hits>0` 只证明**机制在转**，不证明**保护到了这个槽**；两者都成立才叫前提被验证。

---

## §6 残余风险与「未修」清单

| # | 项 | 级别 | 影响 |
|---|---|---|---|
| R-1 | **写入者未点名**，transport 未定（H1a/H4 证伪；H2/H5/H6 竞争） | E2 | 无法根修复；所有防线都是补偿 |
| R-2 | **记录家族仍持续产生**（canary 82/112） | E2 | 内存破坏面比 NE 数大 2–3 个数量级 |
| R-3 | **自然 NE 4/4 同族**（n=4，栈尾 16 页窗口） | E2 | 不只是 canary 现象，但**不可外推** |
| R-4 | **nerepair 只覆盖 pop 型** | E3（代码级） | 解引用型必然漏；规模待 G2b |
| R-5 | nerepair V1/V2 覆盖缺口 | E3 | v1.9.1 部分缓解，未根治 |
| R-6 | **pageguard 未上机、未验证**；前提与 H1a 证伪冲突 | E0 | 可能整条作废 |
| R-7 | SMMU/IOMMU 不可行（§7.3）；关 WED 不可用（§7.4） | E3 | 两条路线关闭 |
| R-8 | kprobe/ftrace/perf/pagemap 全不可用 | E3 | 页级判决只能靠内核模块或重编内核 |
| R-9 | 自然 NE 口径受 nerepair 污染 | E2 | 停判定量必须先停 nerepair |
| R-10 | **槽监视器是代理指标且未复核**（E1）：槽速率 ≠ 内存破坏；写入者可能改目标 | E1 | 必须与 canary/自然 NE 同窗同向，并排除 §5.4 三种假象 |
| **R-11** | **nerepair 只在「后果层」生效：它把进程从崩溃里救回来，但写入本身仍在继续**（C-149） | **E3** | 内存破坏面不变；被救回的进程可能带着被污染的栈/数据继续运行；**不能把"NE 下降"当成"写入停止"** |
| **R-12** | **transport 仍未判定**：VA 分支的两次实验（dropwatch / faultwatch）因「跨会话 + 页级归因」判为**无效**（C-182），PA 分支待最后一次测试 | **E0（无效实验）** | **不得写成「VA 已否证」** —— 那是把「实验无效」误当「假设被拒」。当前正确表述：VA 分支未被有效检验，PA 分支未测完 |

---

## §7 根修复路径（拿到厂商驱动 / 内核可重编之后）

### 7.1 若判 H2/H6（uaccess / 内核按保存的 sp 定位）—— **可能只需改一处调用点**

**本轮最重要的认知更新：这类根修复不需要厂商源码，只需要点名到函数级。**

- 本内核无 kprobe/ftrace/perf ⇒ 无法全局钩 uaccess；唯一手段是调用点 `bl` 打补丁。
- 形态：analyst 把写者点到一个具体函数，在该调用点装 shim，shim 内 `find_vma(current->mm, dst)` + 判是否用户栈 VMA → 命中即拒绝并记日志。
- 成本：每次该调用一次 VMA 查找（~`find_vma` 100–200 ns）。**单点可接受，通用 uaccess 不可接受。**
- **先做检测版**（`armed=0` 只计数）：24 h 为 0 就止损；≥1 次命中 ⇒ H2 实证，可升级为拒绝。

### 7.2 R1 厂商驱动修复（若点名到驱动）

要求厂商：释放 RX/TX 缓冲前**停 DMA / 清描述符**，或 TXD 用 bounce buffer，或保留 WED 页不归还。
可行性 = 需厂商源码/NDA + 一次固件升级；**唯一"真正停写"的路径**。

### 7.3 R2 SMMU/IOMMU —— **本内核不可行（E3）**

`.config` 里 `# CONFIG_IOMMU_SUPPORT is not set`；vmlinux 全字符串 **0 处 "smmu"**；
kallsyms 只有通用 `iommu_*` 核心、**无 `arm_smmu_*`/`mtk_iommu` 驱动符号**。
要做 = 重编内核 + 改 DT（`iommus`/`stream ID`）+ 刷机，且**只把「写复用用户页」变成「IOMMU fault」**，不是修 bug。**不建议。**

### 7.4 R3 关 WED offload —— **不可用**

`rmmod mtk_wed` **1/1 触发内核 Oops + 自动重启**（pstore：故障地址 = 刚卸载模块基址 + 0x54，中断核心调用已卸载 handler）。
**禁止再试**；若要测只能「重启后不加载模块」。

---

## §8 交接检查单（新人第一天）

1. 读 [00_STATE.md](00_STATE.md) + [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)（**对外以此为准**）。
2. 确认 nerepair 活着：`ps | grep -w nerepair`、`tail /data/gw/logs/nerepair.log`、`cat /tmp/nerepair.hb`。
3. 确认观测链：`ls -l /data/gw/logs/ne_events.tsv`；取一份 `.stack` 跑 `natne_scan.py`。
4. 确认判据：host 跑 `nerepair_mask_test`，应为 150/150 阳性、0/8 阴性。
4b. 确认验收工具：要一份 sampler2 的采样原始件，按 §4.2 准入门槛筛槽（A 臂 ≥20 次/10 min）；筛不出槽就是**功效不足**，不能当阴性。
5. **不要做**：`rmmod mtk_wed`；无锁写设备；用 canary 率外推自然 NE；引用 88/112、0/4、「PA-DMA E2 已定」。

---

## 附录：口径待对账（**引用前必须解决**）

- 自然 NE 记录位置：记分卡 C-142 写 `start_stack−0x1390…−0x7970`；本地 `natne_scan.py` 复算的记录**字段起点**为 `top−0x1390…−0x77c0`。
  两者口径不同（扫描窗口 vs 字段起点），**引用具体数字前先与 skeptic 对账**（见记分卡 §12）。
- 本文所有 canary 数字取自 **82/112** 口径；若 00_STATE 再次修订，以 00_STATE 为准。

| 文档 | 关系 |
|---|---|
| [00_STATE.md](00_STATE.md) | 当前事实源（数字以它为准） |
| [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md) | transport 记分卡，**对外表述以此为准** |
| [05_LOG/2026-11-01-fix-design.md](05_LOG/2026-11-01-fix-design.md) | 本文设计依据（nerepair 加固 / pageguard / 判据 / 自然 NE 缺口 §7） |
| [05_LOG/TEMPLATE-nerepair-dryrun.md](05_LOG/TEMPLATE-nerepair-dryrun.md) | dry-run 报表模板 |
| [VERDICT.md](VERDICT.md) | **历史判决（PA/DMA E2）已作废**，仅存档，勿引用 |
---

## §9 部署与回滚手册（照着敲就能跑）

> 目标：把 **nerepair v2.0** 从仓库装到设备并验证；装不上或出问题能**原路退回**；最坏情况能**从串口救回来**。
> 所有设备写操作都必须带锁（`tools/devop.py`，输出必须有 `ACQUIRED`/`RELEASED` 配对）。

### 9.1 要动的文件（只有两个）

| 文件 | 类型 | 目标 | 本次版本 | md5 |
|---|---|---|---|---|
| `gw/bin/nerepair` | manifest（可执行） | `/data/gw/bin/nerepair` | **2.0**（52,216 B） | `75e2942489d8c81c14d64691f0d12983` |
| `gw/src/nerepair.c` | src（不部署，只登记） | — | **2.0** | — |

**不用动**：`rc.extend.sh`（v3.7 的 v3.3 块已按路径拉起 `/data/gw/bin/nerepair`，换二进制即可生效）、
`nerepair_launch.sh`、`svc_lib.sh`（watchdog 的 `nerepair` 判活条目不变）。

### 9.2 部署步骤（逐条执行，别跳）

```sh
# ── 0) 前置：版本注册表必须先改，否则 deploy.py 会拒绝一切操作
#     tools/VERSIONS.tsv 两行（Lead 统一提交时改）：
#       gw/bin/nerepair   1.7 → 2.0   （md5 列填 75e2942489d8c81c14d64691f0d12983）
#       gw/src/nerepair.c 1.7 → 2.0
cd lg6151m-public && python tools/vercheck.py check      # 必须全绿

# ── 1) 留证据：部署前的现状（照抄进 drill 记录）
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'ps | grep -w nerepair | grep -v grep; ls -l /proc/$(pidof nerepair)/exe; tail -2 /data/gw/logs/nerepair.log'

# ── 2) 停旧实例（持锁）
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "nerepair v2 部署：停旧实例" -- killall nerepair
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'sleep 2; pidof nerepair || echo STOPPED'

# ── 3) 推二进制（deploy.py push 带 #DEPLOY 溯源戳；put 不保留权限位，后面必须 chmod）
MSYS_NO_PATHCONV=1 python tools/deploy.py push gw/bin/nerepair
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "nerepair v2 部署：补执行位" -- chmod 755 /data/gw/bin/nerepair

# ── 4) 校验落盘 md5（必须与 9.1 一致）
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'md5sum /data/gw/bin/nerepair'

# ── 5) 先跑 dry-run（强烈建议：不修、只记 WOULD_REPAIR / WOULD_DREPAIR）
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "nerepair v2 dry-run 标记" -- touch /data/gw/nerepair.dry
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "nerepair v2 dry-run 启动" -- sh /data/gw/nerepair_launch.sh

# ── 6) 60 秒后核对（判据见 9.3）
sleep 60
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'grep -E "START|MODE" /data/gw/logs/nerepair.log | tail -3; tail -1 /data/gw/logs/nerepair.log'
```

**转 armed（24 h dry-run 通过 G0–G6/G2b 之后才做）**：

```sh
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "nerepair v2 转 armed" -- rm -f /data/gw/nerepair.dry
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "nerepair v2 重启生效" -- killall nerepair
# watchdog 会在下一轮拉起；或手工 sh /data/gw/nerepair_launch.sh
```

### 9.3 部署后判据（60 s 内必须全绿，任一红就回滚）

| # | 检查 | 命令 | 期望 |
|---|---|---|---|
| 1 | 进程在跑 | `pidof nerepair` | 一个 pid（不是两个） |
| 2 | 版本对 | `grep START /data/gw/logs/nerepair.log \| tail -1` | `ver=2.0` 且 `dry=1`（若在 dry-run） |
| 3 | 心跳新鲜 | `cat /tmp/nerepair.hb` | 数字在涨（60 s 一轮） |
| 4 | STAT 正常 | `grep STAT … \| tail -1` | `mode=dry`（或 armed）、`attached>0` |
| 5 | 覆盖没退化 | 同上 `attached=` | ≥ 部署前那一行 |
| 6 | 无 Oops | `dmesg \| tail -20` | 无 `Unable to handle`/`Oops` |

### 9.4 回滚（三种粒度，从轻到重）

```sh
# (a) 只关 dry-run 以外的修复 → 立刻"不修，让进程正常死"
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "回滚：停修复" -- killall nerepair
#    tracee 自动 detach，设备不会僵；watchdog 会按 SVC_TABLE 再拉起 —— 要彻底停需改 rc.extend（见 c）

# (b) 退回 v1.7 二进制
#     仓库里保留旧产物即可：git show <v1.7 提交>:gw/bin/nerepair > /tmp/nerepair.v17
MSYS_NO_PATHCONV=1 python tools/deploy.py put /tmp/nerepair.v17 /data/gw/bin/nerepair
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "回滚：恢复 v1.7 执行位" -- chmod 755 /data/gw/bin/nerepair
MSYS_NO_PATHCONV=1 python tools/devop.py --owner fixer --purpose "回滚：重启 v1.7" -- sh /data/gw/nerepair_launch.sh

# (c) 彻底停用（连 watchdog 也不再拉）
#     编辑 gw/rc.extend.sh 注释掉 v3.3 的 nerepair 块 → deploy.py push gw/rc.extend.sh → 重启
#     同时从 svc_lib.sh 的 SVC_TABLE 摘掉 nerepair 行（否则 watchdog 会重启一个不存在的服务）
```

**回滚触发条件**：9.3 任一红；出现 `reason=repair-loop` 风暴；被修复进程行为异常且确认非本家族；
内核 Oops/panic。

### 9.5 LK 救砖（设备起不来时的唯一入口）

> 前提：SSH 不通、串口能出字。**串口 COM6 @921600 8N1**。**不要**在没有串口日志的情况下反复断电。
> 救砖链路已在 `AGENTS.md`「刷机管线」里验证过，工具：`tools/lk_flash_v4.py`（主）、`tools/lk_eth1_resume.py`（续跑）。

```sh
# 1) 抓 LK 窗口：设备断电 → 上电，同时连续发 Ctrl-C（弹幕）打断到 LK 提示符（PINTEST）
#    脚本已封装：python tools/lk_flash_v4.py --port COM6 --baud 921600 --stage lk
# 2) 在 LK 里把 init 改成 shell
#      kcmdline append init=/bin/sh
#      repeat 2000 heap alloc 65536        # 清堆，避免 LK 分配失败
#      boot
# 3) 进 raw shell 后先重建最小环境（根只读、无 /dev/null，后台 & 会因 stdin 失败而中止）
#      mount -t tmpfs tmpfs /dev && mknod /dev/null c 1 3
#      mount -t proc proc /proc
# 4) 网络：eth0/eth1 任一，零配置 169.254/16（PHY 在 ifup 后 attach）
#      ifconfig eth1 up && udhcpc -i eth1 -q -n || true
# 5) 拉恢复脚本（md5 门禁）
#      export LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib
#      /fhrom/bin/curl -o /tmp/deploy2.sh http://169.254.x.x/deploy2.sh && md5sum /tmp/deploy2.sh
#      sh /tmp/deploy2.sh          # 后台自驱：tar+镜像 md5 门禁 → dd p26 → 挂载验证 → /data 还原 → bootctrl 翻 A → sysrq-b
```

**三条红线（违反会变砖或丢数据）**：
1. **不写 p39**（B 槽 = 官方回滚底线）；只写 p26（A 槽）。
2. **bootctrl 只在四重验证全过后翻**（rcS 锚点 / toor / S98 / S99zmtk 缺席）；翻完必须读回 `0f 03`。
3. **任何设备侧文件传输必须 md5 门禁**（历史事故：传输损坏导致刷机失败）。

**若只是 nerepair 部署失败、设备还能启动**：不要走 LK —— 用 9.4 的 (a)/(b) 即可。
LK 只用于「内核 panic 循环 / 根文件系统损坏 / bootctrl 掉槽」。

### 9.6 事故分级

| 现象 | 分级 | 动作 |
|---|---|---|
| nerepair 心跳停、watchdog 重启 | 中 | 看 `nerepair.out`；`killall` 后观察；必要时 9.4(b) |
| 被修复进程行为异常 | 中 | 查 `REPAIR`/`DREPAIR` 行，核对是否真家族；可疑则 9.4(a) |
| 内核 Oops/panic | 高 | 先落 `pstore` → 9.4(c) → 复盘；**不要**重复触发 |
| 起不来（无 SSH、串口有字） | 高 | 9.5 LK 救砖 |
| 起不来且串口无字 | 最高 | 断电 10 s 再上电；仍无字 → 硬件/供电问题，停止操作并上报 |
### 9.7 slotdrop 模式（v2.1，默认关闭）—— 给 faultwatch 造一个必被写的目标

> 为什么：faultwatch/dropwatch 跑在新起的受害进程上，而新进程 7 min 拿不到记录槽（第 6 轮证据）
> ⇒ 窗口注定阴性。nerepair 自己的栈上有一个已被证明会被写的热槽（start_stack−0x3b0，600 s 内 369 种内容 ≈0.62 次/s）。

**行为**：启动时看到 /tmp/nerepair.slotdrop（或收到 SIGUSR1）→ 独立线程扫描自己 [sp, start_stack)（8B 步进、strict 记录判据）
→ 找到后打印 SLOTDROP va=0x… page=0x… start_stack=0x… → 每 200 ms 对该页 madvise(MADV_DONTNEED)；找不到则每 30 s 重试并打印 SLOTDROP NOSLOT。
ptrace 主循环不受影响（独立线程）。

**安全阀**：只丢严格高于主线程当前 sp 的页（g_main_sp 每轮主循环刷新），否则计 SKIP_LIVE 不动手。
**信号重定义（v2.1 起）**：SIGUSR1 = 开 slotdrop；SIGUSR2 = 切换 dry-run（原 SIGUSR1 的语义已迁移）。

**开启 / 关闭**（全部走 devop 持锁）

```sh
# 开
python tools/devop.py --owner fixer --purpose 'slotdrop 开启' -- touch /tmp/nerepair.slotdrop
python tools/devop.py --owner fixer --purpose 'slotdrop 热开' -- kill -USR1 $(pidof nerepair)
# 关（删标记 + 重启；不重启则本进程仍继续丢页）
python tools/devop.py --owner fixer --purpose 'slotdrop 关闭' -- rm -f /tmp/nerepair.slotdrop
python tools/devop.py --owner fixer --purpose 'slotdrop 关闭重启' -- killall nerepair
# 确认
python tools/lgssh.py 'grep SLOTDROP /data/gw/logs/nerepair.log | tail -3; grep STAT /data/gw/logs/nerepair.log | tail -1'
```

**判据**：① SLOTDROP va=… 出现且 start_stack − va ≈ 0x3b0（历史值，不同构建可能差几百字节）；
② STAT 里 sd=1/… 计数在涨；③ 与 faultwatch 联跑：把 faultwatch 的 lo/hi 设成该页 → 若写入者按 VA 写，必然在 faultwatch 里留下内核栈。

**风险与回滚**：madvise 的是自己栈上 sp 之上的冷页；nerepair 若崩，launcher/watchdog 会拉起（覆盖暂时下降，属已知代价）。
回滚 = 删标记 + killall nerepair（见上）。
### 9.8 slotdrop 是**诊断模式**，不是常态配置

> **用完就删标记文件。** `/tmp/nerepair.slotdrop` 存在 = slotdrop 开着；它是为了**抓写入者**而临时把 nerepair 自己栈上的热槽反复置为 missing。长期开着没有收益，只有代价：

| 代价 | 说明 |
|---|---|
| 无谓的页抖动 | 每 200 ms 一次 `MADV_DONTNEED`，该页每次访问都要重新缺页（CPU 开销与 TLB 抖动） |
| 覆盖下降风险 | 若 nerepair 因此崩溃，launcher/watchdog 拉起期间**所有进程短暂失去修复覆盖** |
| 误读为「默认行为」 | 后来人看到 SLOTDROP 日志会以为这是产品特性 —— 它不是 |

**收尾清单（抓到栈之后）**：
1. `rm -f /tmp/nerepair.slotdrop`；
2. `killall nerepair`（launcher/watchdog 自动拉起，无标记即普通模式）；
3. 确认日志里不再出现新的 `SLOTDROP` 行，且 `STAT` 的 `sd=0/...`；
4. 把抓到的内核栈与 `SLOTDROP va=…` 一起写进当轮 05_LOG。
