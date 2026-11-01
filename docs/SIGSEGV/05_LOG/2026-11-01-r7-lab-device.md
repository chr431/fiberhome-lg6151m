# 05_LOG · 第 7 轮 lab 设备 lane 记录（2026-11-01 17:32–18:34）

> 作者：lab（设备唯一操作通道）。本文只记录**设备侧执行、读数、证据路径与判据**；
> 结论分级与台账由 skeptic 维护，机制判决由 Lead 定稿。
> 本轮**未新增任何内核模块事故**（0 次重启），所有仪器均在 `boot_id 51e7025c-dab0-41be-803c-f91e87f9dfc7` 内运行。

## 0 · 本轮设备状态基线

| 项 | 值 |
|---|---|
| boot_id | `51e7025c-dab0-41be-803c-f91e87f9dfc7`（本轮全程未变） |
| uptime（收尾） | 17,054 s |
| 内核模块 | 0 个（faultwatch/patrace/uprot/uwhook/pte_redirect 均已卸载，/proc 节点不存在） |
| nerepair | pid 2850，v2.1，**mode=dry**，心跳 /tmp/nerepair.hb 新鲜 |
| /data 余量 | 1.3 G（43% 已用） |
| /data/gw/nerepair.dry | 在位（安全默认态，按 Lead 指令保留） |

## 1 · 本轮三次重启的归属（第 6 轮遗留，证据补齐）

| # | 触发 | 机制 | 证据（主机副本） |
|---|---|---|---|
| 1 | `insmod uwhook.ko` | kernel IABT @ `0xffffffffc008b684`（shim 返回地址拼错） | `_local/evidence/crash-root/pstore/console-ramoops-0`（md5 `1629a33d87c8231a75607a9890015f45`） |
| 2 | `pte_redirect` `echo zero` | Bad page state `pfn:acdcb` → panic_on_taint | `pstore2/console-ramoops-0`（md5 `cadf1fc77a74a2fd6977009a784bc2b7`） |
| 3 | `uprot` `ro`（打 ptrace 监督者活栈页） | **healthdog `heartbeat stale >90s → EMERGENCY RESTART`**（watchdog 型，非 panic） | `pstore3/console-ramoops-0`（md5 `30cf05f28e5bbc4af5200391078b9f43`） |

第 3 次的 A/B 机制未分（E1）：形状支持「nerepair 被 RO → tracee 集体停 ptrace-stop → 用户态心跳消失」（E2），但缺 `ro` 返回值现场。

## 2 · userfaultfd：证伪（E3）

- 设备实测（arm64 syscall 282，静态二进制 `probe_uffd`）：`syscall282(userfaultfd_arm64) -> -1 errno=38 (ENOSYS)`
- `/proc/sys/vm/unprivileged_userfaultfd` **不存在**（同结论）。
- 与 kdev/skeptic 的符号类型（`__arm64_sys_userfaultfd` 为 W 弱桩）与反汇编一致。
- **教训**：我先用 syscall 323 测（x86_64 编号）也得到 ENOSYS，属"跨架构抄号"假象；以 282 复测为准。

## 3 · process_madvise 语义（设备实测）

| advice | 结果 |
|---|---|
| `MADV_DONTNEED`(4) | **`rc=-1 errno=22 (EINVAL)`** —— 5.15.134 的 `process_madvise_behavior_valid()` 白名单不含它 |
| `MADV_COLD`(20) | `rc=4096`（成功，但不改页内容，不能用于"丢页"判据） |
| `MADV_PAGEOUT`(21) | `rc=4096`（成功；swap=/dev/zram0 733 MB 可用） |

⇒ 「外部丢弃目标进程页」只能走 **PAGEOUT**（本日志 §6 用它）。

## 4 · dropwatch（纯用户态 VA/PA 判别，kdev 仪器）

**身份**：设备 md5 `aebadf7d9af16edaab37dfc39771ebce`（34,408 B，v2 区域修正版；旧的 1696f62f 因自伤 bug 作废）。

**装置验证（必跑，全过）**：
1. `--self-test` → **DW SELFTEST PASS**（注入记录 `11223344,0,109a8c000000641,0` 下一轮即检出）。
2. **外部 fault 正对照**（skeptic 要求）：另一进程 `process_vm_writev` 往带内写 32B 记录形状 →
   `VMWRITE rc=32`，dropwatch 立即 `DW_HIT … poff=0x800 w=1234,0,109a8c000000641,0` + `resident_events=1 hits=1`。
   ⇒ 「resident ⇒ 外部经页表写」这条链被实证。
   ⚠️ 注意：`process_vm_writev` 走 **GUP**，不经 `do_page_fault`，所以它只能当 dropwatch 的正对照，**不能**当 faultwatch 的正对照。

**正式窗口**（band `[0x7fe6ec7000,0x7fe6ecb000)`，600 s，dropwatch pid 15732）：
- `resident_events=0 / hits=0`（70 轮）。
- 同窗活性对照：2×vsurv4 命中 h4 **+4 / 10 min**（冷态，功效弱但非零）。
- 口径：**0 事件 + 活性对照非零但弱** ⇒ 只能写「PA/DMA **或** 原子上下文 uaccess 失败」，且**功效不足**，不能当强阴性。

## 5 · faultwatch（内核栈抓取，kdev 仪器）——本轮最重要的一枪

**身份**：`49ac3333fe5f6f6164e412847d163d5d`（186,592 B；kdev 后另发新版 `0e14ceb6…` 与 `faultwatch_fp.ko 88148c4c…`，本轮用的是已上机验证的这一版）。

**装载**：`insmod faultwatch.ko lo=<page> hi=<page+0x1000>` → `rc=0` + dmesg `GO/NO-GO ok hits=1` + `/proc/faultwatch` 首行 `go=1 armed=0` → `echo 1` 武装。
**卸载**：`rmmod` 每次都回读 `restored 0xffffffc008126be0 to a9ba7bfd (readback a9ba7bfd ok=1)`。

### 5.1 窗口 1：nerepair `top−0x3b0` 热槽页 `[0x7fc41bc000,0x7fc41bd000)`

- 外部 `pageloop` 每 100 ms `process_madvise(MADV_PAGEOUT)`，约 9 min。
- `calls=19,539,113`；`hit=33,959`；事件环多次抽样 **40/40 全部 `pid=9696 comm=nerepair`**；**非 SELF = 0**。
- 典型事件：`far=0x7fc41bc5d4 pc=kernel_wait4+0x100 lr=kernel_wait4+0xfc pid=9696`，
  `tr = do_translation_fault+0x40 → do_mem_abort+0x44 → el1_abort+0x40 → el1h_64_sync_handler+0x80 → el1h_64_sync+0x78 → kernel_wait4+0x100 → __do_sys_wait4+0x28 → __arm64_sys_wait4+0x20 → invoke_syscall+0x6c → …`
  ⇒ **nerepair 自己的 wait4 把 status 写回用户栈**造成的缺页，不是外部写入者。
- 活性对照：同进程另一槽 `top−0x12d0` 60 s 内有 1 次内容变化（`efb601…`→`fbda01…`，len=1601/ip=192.168.9.1）。

### 5.2 窗口 2：`top−0x12d0` 页 `[0x7fc41bb000,0x7fc41bc000)`

- 同样 pageloop 100 ms；`hit=5`（1 条 go/no-go + 4 条 SELF），**非 SELF = 0**。

### 5.3 方法学（本轮确立，务必沿用到下一轮）

1. **SELF 判据**：`pid == 受害进程` 且 `tr` 含 `el0_svc → __arm64_sys_*` ⇒ 受害者自己的 syscall 输出，**必须 SKIP**；
   只有 `pid != 受害进程`（或内核工作线程上下文）才是外部写入者。
2. **tr 解析不需要减 0x100000**：kallsyms 与运行期地址一致（`do_page_fault=0xffffffc008126bdc` 精确命中）；减偏移会全错。
3. **仪器灵敏度已被证明**：连 `kernel_wait4` 写 4 字节 status 的缺页都能抓到 ⇒ 「0 非 SELF」是有检出能力的阴性，前提是缺页占空比足够。

## 6 · PA 分支（读旧 PA）——本轮 INVALID

- `patrace.ko` 取 `top−0x12d0` 槽 VA `0x7fc41bb5c0` → **PA `0xa286f5c0`**（page `0xa286f000`）。
- `pageloop` 每 100 ms PAGEOUT 该页 + `pawatch` 每 200 ms 读旧 PA，共 900 采样：
  **61 次整页变化 / `new_records=0`**。
- 判读：旧 PA 被**立即复用**（整页内容频繁变、无 strict 记录）⇒ 按预注册「被复用则该轮作废」，
  **该轮 INVALID，不能当 PA 写的阴性**。

## 7 · nerepair v2.1 部署与 dry-run

**交付**：
- 本地/设备 md5 `9ae78c4a52f108ecccc6fd69b5ea3394`（79,840 B，`-rwxr-xr-x`）。
- `deploy.py push gw/bin/nerepair` → `/data/gw/bin/nerepair`。
- 重启后 pid 2850，`/tmp/nerepair.hb` 每轮新鲜，`mode=dry` 生效。

**dry-run STAT 时间序列（18:03→18:33，30 min）**：

```
18:05:09  STAT mode=dry attached=48 segv=0 repaired=0 passed=19 suppressed=0 abuse=0 loop=0 would=0 near=0 nearinsn=0 rep2=0 would2=0 dfhit=0 sd=0/0/0/0
18:17:09  STAT mode=dry attached=48 segv=0 repaired=0 passed=73 suppressed=0 abuse=0 loop=0 would=0 near=0 nearinsn=0 rep2=0 would2=0 dfhit=0 sd=0/0/0/0
18:33:09  STAT mode=dry attached=48 segv=0 repaired=0 passed=91 suppressed=0 abuse=0 loop=0 would=0 near=0 nearinsn=0 rep2=0 would2=0 dfhit=0 sd=0/0/0/0
```

- **would/near/nearinsn/dfhit/sd 全 0 ⇒ 本窗未遇到可修事件**。
- 检出下限：历史 NE ≈0.5/h ⇒ 30 min 期望 ≈0.25 次，**0 是预期内**，不能当「修好了」。
- **裁决（与 Lead 预注册一致）**：30 min 只能当**部署健康检查**；armed 门禁仍需 **G0–G6 的 24h dry-run**。

## 8 · 干净态 deploy selftest

0 模块、无遗留进程下重跑：**TOTAL 104 pass / 1 fail**
- 唯一 FAIL：`avail: 可用性采样器/数据文件/API 域在位 (P1) [hb_gap=69 roster=26 …]`
  —— `hb_gap=69s` 与本次 nerepair 重启（killall→拉起）的心跳缺口吻合，**属部署动作副作用，非 v2.1 缺陷**。
- 分域：wifi 9/9、gui 10/10、agg 11/11、net 5/5、cellular 22/22、security 8/8、system 39/40。

## 9 · 本轮仪器清单（主机源码 + 设备二进制）

| 工具 | 用途 | 主机源码 |
|---|---|---|
| sampler2 / sampler3 | 系统级栈记录扫描（全量 / 只记变化+STAT） | `tmpfiles/repro/sampler{2,3}.c` |
| rovictim2b | 纯用户态自扫描 + 自 mprotect（ro/mon 两模式） | `tmpfiles/repro/rovictim2b.c` |
| watch2 | 任意 32B 槽的逐次变化（含 0↔记录） | `tmpfiles/repro/watch2.c` |
| pageout / pageloop | process_madvise(PAGEOUT) 单次 / 循环 | `tmpfiles/repro/{pageout,pageloop}.c` |
| pawatch | /dev/mem 读旧 PA + 差分 + strict 记录扫描 | `tmpfiles/repro/pawatch.c` |
| zapslot / p1test | process_madvise 试探 / 哨兵+PAGEOUT 判据原型 | `tmpfiles/repro/{zapslot,p1test}.c` |
| vmwrite32 | process_vm_writev 外部写（dropwatch 正对照） | `tmpfiles/repro/vmwrite32.c` |
| probe_uffd / uffdtest | uffd 可用性探针（282 / 323） | `tmpfiles/repro/{probe_uffd,uffdtest}.c` |

设备侧脚本：`lab_expctl.sh`（自治跑批器）、`lab_rec.sh`（h4 记录提取）、`lab_sarm2.sh`（S 臂，含 skeptic 5 道门）、`lab_uwhook_{ctl,run}.sh`、`lab_wan.sh`、`lab_natctl.sh`。

## 10 · 证据索引（主机副本，均带断言）

| 文件 | 说明 |
|---|---|
| `_local/evidence/crash-root/pstore{,2,3}/console-ramoops-0` | 三次重启现场（md5 见 §1） |
| `_local/evidence/crash-root/scanary/scanary_A.log` | 深度臂 1604 行（md5 `5f4d30411850a7be7a455e0eaec837a5`） |
| `_local/evidence/crash-root/sampler2.log` | 11,430 行（25 进程 / 43 槽） |
| `_local/evidence/crash-root/exp/s12/recs.txt` | S1/S2 记录 2400 行（断言 2400==2400） |
| `_local/evidence/crash-root/dump_dma_hot_1793509192.txt` | 5656 行（断言 OK） |
| `_local/evidence/crash-root/natne/`、`natctl/` | 自然 NE 4 份 .stack + meta；健康进程 12 份 .stack |
| `_local/evidence/crash-root/ne_events_2026-11-01.tsv` | 1634 行（断言 OK） |
| `_local/evidence/crash-root/exp_r2/` | pa_hist / restart_test / reset_test / h4_meta（设备侧 2 行截断） |
| `docs/SIGSEGV/05_LOG/2026-11-01-natural-ne-record.md` | 自然 NE 记录观测（4/4 精确 Q2） |
| `_local/evidence/crash-root/INDEX.md` | **本轮全部证据的自动索引**（57 个文件，逐个给字节数/行数/md5） |

## 11 · 本轮未解决（留给下一轮）

1. **transport（VA vs PA）仍未判死**：VA 侧两窗只有 SELF 缺页、无外部写；PA 侧因页复用 INVALID。
2. 若要继续：优先**提高缺页占空比**（nerepair v2.1 的 slotdrop 内建丢页）或换一个**不被受害者自己 syscall 触碰**的槽页；
   PA 侧需要"能冻结旧 PA 不被复用"的手段（否则永远 INVALID）。
3. **不再用页表类内核模块**（pte_redirect/uprot 各崩一次）；文本钩 faultwatch 目前是唯一验证过的内核侧仪器（每次装载/卸载都回读校验）。
