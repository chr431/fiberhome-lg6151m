# nerepair armed 窗口报告（2026-11-03 19:55:21 起）

> 生成器： `lg6151m-public/tools/oneoff/review/nerepair_window_report.py`（host 侧只读输入，不接触设备）。
> 输入： `tmpfiles/review/arm/{arm_log_merged.txt, watch.tsv, latest.json, ne_joined_latest.txt}`。
> 结论纪律：本窗**无对照臂、无 canary 在跑** ⇒ 不得据此宣称崩溃减少；只能给 REPAIR 事件、被修进程存活/再死亡结果、按背景率给出的功效（§E/§F）。
> **数据来源的必要性（task-8 审计项①）**：nerepair 在役 ⇒ kmsg 的 unhandled-fault 行**结构性缺席**（docs/SIGSEGV/03_PROBES.md:164-166：arm64 unhandled_signal() 要求 !tsk->ptrace，实测全 pid TracerPid=nerepair），而 armed 后被修的崩溃也不进 NE 台账 ⇒ **双重不可见**；因此布防后被修崩溃的**唯一记录**就是 nerepair.log 的 REPAIR/DREPAIR/XREPAIR 行，本报告的数据链（合并档案 + survival.tsv + triage.tsv）正是为覆盖它而设（详见 §E6/E7）。

## A. 窗口定义与在役状态

| 项 | 值 | 来源 |
|---|---|---|
| 观察窗起点（boot 9129c459…） | epoch 1793699132 = 2026-11-03T17:45:32+08:00 | 设备 pull1.txt @@ANCHOR / boot_id |
| **布防时刻** | epoch 1793706921 = 2026-11-03T19:55:21+08:00（`MODE dry=0 by=SIGUSR2`） | merged L2099 |
| 首个 armed STAT | 2026-11-03T19:56:00+08:00 `mode=armed attached=45 segv=3 repaired=0 passed=3 suppressed` | merged L2100 |
| 读数时刻（asof） | epoch 1793719855 = 2026-11-03T23:30:55+08:00 | 合并日志末行 merged L2558 |
| 布防→读数时长 | 3.59 h (12934 s) | 合并日志 epoch 计算 |
| 布防方式 | 运行期 SIGUSR2（无重启/无覆盖空洞） | `MODE dry=0 by=SIGUSR2`；watch npid 全程不变即为证 |

| 项 | 值 | 来源 |
|---|---|---|
| nerepair pid（watch 列） | 取值集合=[('11617', 11), ('11740', 15)]（26 个采样行） | watch.tsv 第 5 列 |
| 心跳年龄 | min 1.2 s / max 58.0 s（阈值 180 s） | watch.tsv 第 3 列 hb vs 第 2 列 uptime |
| 钥匙状态 | /data/gw/nerepair.dry,no_xrep,no_arm | latest.json.markers（设备 ls -d 探测） |
| 采集器命令原文 | `latest.json.devcmd`（**每轮**原文，观测者污染/归属审计，见 §E1） | latest.json |
| 采集器存活统计 | survival_total=8（per-pid 行；最近 10 条见 latest.json.survival） | latest.json.survival_total |
| **回滚到 dry 时刻** | epoch 1793719729 = 2026-11-03T23:28:49+08:00（MODE dry=1 by=SIGUSR2） | merged L2555（合并档案内含回滚行） |
| **armed 实际时长** | 3.56 h（12808 s） | 回滚时刻 − 布防时刻 |
| **nerepair 实例切换/重启检测** | 1 次：21:11:34 pid 11617→11740 uptime 11760.39→243.9 | watch.tsv 的 npid 变化与 dev_uptime 单调性（采集器每 600 s 一轮） |
| 重启后 STAT 计数器回退（同实例口径依据） | 检测到回退 | 逐个 armed STAT 的 segv 是否回退 |

## B. 后果层计数（SEGV / REPAIR / PASS / 熔断 / 普查）

**事件直方（全量合并日志，非抽样；事件=第 5 字段整值）**：

| 事件 | 观察窗内布防前 | **armed 段** | 回滚后 | 全日志（含更早 boot 段） |
|---|---|---|---|---|
| ATTACH | 0 | 2 | 0 | 173 |
| BIN | 3 | 44 | 0 | 85 |
| DREPAIR | 0 | 22 | 0 | 22 |
| MODE | 0 | 2 | 0 | 6 |
| NEAR | 0 | 12 | 0 | 56 |
| PASS | 3 | 47 | 0 | 581 |
| REPAIR | 0 | 1 | 0 | 1 |
| SCAN | 0 | 0 | 0 | 4 |
| SEGV | 3 | 60 | 0 | 776 |
| START | 0 | 0 | 0 | 5 |
| STAT | 128 | 210 | 3 | 692 |
| WOULD_DREPAIR | 1 | 0 | 0 | 6 |
| WOULD_REPAIR | 0 | 0 | 0 | 141 |
| WOULD_XREP | 0 | 9 | 0 | 9 |
| XFORM | 0 | 1 | 0 | 1 |

> armed 段 = epoch [1793706921, 1793719729]，共 410 行、3.56 h；回滚后 3 行（仅设备直读可见，合并档案止于 asof）。

**布防后逐条非 STAT 事件**：

| merged 行 | epoch | 时刻 | pid | comm | 事件 | detail |
|---|---|---|---|---|---|---|
| L2099 | 1793706921 | 2026-11-03T19:55:21+08:00 | 0 | ? | MODE | `dry=0 by=SIGUSR2` |
| L2117 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2118 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | SEGV | `pc=0x4e7080 addr=0xa206 code=1 x2=0x7ffdb1eea8 x8=0x7fffffff insn=0xf9400060` |
| L2119 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | PASS | `reason=rt-ne-rn rt=0 rn=3` |
| L2120 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | DREPAIR | `pc=0x4e7080 addr=0xa206 rn=3 rec=0x7ffdb1efe0 which=q2 q0=0x4a9e8c q2=0xa206` |
| L2121 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | SEGV | `pc=0x400688 addr=0xa210 code=1 x2=0x7fffffff x8=0x7fffffff insn=0x39400060` |
| L2122 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | PASS | `reason=rt-ne-rn rt=0 rn=3` |
| L2123 | 1793707968 | 2026-11-03T20:12:48+08:00 | 14873 | sh | DREPAIR | `pc=0x400688 addr=0xa210 rn=3 rec=0x7ffdb1edf0 which=q2 q0=0x7f86c38f7a q2=0xa210` |
| L2133 | 1793708509 | 2026-11-03T20:21:49+08:00 | 6018 | ip | BIN | `path=/data/gw/bin/ip dev=66318 ino=8804` |
| L2134 | 1793708509 | 2026-11-03T20:21:49+08:00 | 6018 | ip | SEGV | `pc=0x10a64d8 addr=0x23ad0 code=1 x2=0xffffffffffffffff x8=0x23ad0 insn=0x39400008` |
| L2135 | 1793708509 | 2026-11-03T20:21:49+08:00 | 6018 | ip | PASS | `reason=rt-ne-rn rt=8 rn=0` |
| L2136 | 1793708512 | 2026-11-03T20:21:52+08:00 | 7240 | logread | BIN | `path=/sbin/logread dev=45850 ino=1703` |
| L2137 | 1793708512 | 2026-11-03T20:21:52+08:00 | 7240 | logread | SEGV | `pc=0x7f9cf73ffc addr=0x2bcd0 code=1 x2=0x7fc37134f8 x8=0x3a insn=0xf9400060` |
| L2138 | 1793708512 | 2026-11-03T20:21:52+08:00 | 7240 | logread | NEAR | `reason=insn shape=ldr rt=0 rn=3 insn=0xf9400060 addr=0x2bcd0` |
| L2139 | 1793708512 | 2026-11-03T20:21:52+08:00 | 7240 | logread | WOULD_XREP | `path=x3 pc=0x7f9cf73ffc addr=0x2bcd0 rn=3 rec=0x7fc37134f8 which=q0 q0=0x2bcd8 q2=0x7db3c47800000633` |
| L2140 | 1793708514 | 2026-11-03T20:21:54+08:00 | 7858 | sh | BIN | `path=/bin/busybox dev=45850 ino=4` |
| L2141 | 1793708514 | 2026-11-03T20:21:54+08:00 | 7858 | sh | SEGV | `pc=0x7fa5663590 addr=0x187a6 code=1 x2=0 x8=0xfe24270 insn=0x38626803` |
| L2142 | 1793708514 | 2026-11-03T20:21:54+08:00 | 7858 | sh | PASS | `reason=not-load` |
| L2143 | 1793708514 | 2026-11-03T20:21:54+08:00 | 7858 | sh | XFORM | `form=regload sig=stack rt=3 rn=0 insn=0x38626803 addr=0x187a6 rec=0x7ffc33f450 q0=0x187a6 q2=0x187a6` |
| L2145 | 1793708543 | 2026-11-03T20:22:23+08:00 | 31797 | slotguard | BIN | `path=/data/gw/bin/slotguard dev=66318 ino=14334` |
| L2146 | 1793708543 | 2026-11-03T20:22:23+08:00 | 31797 | slotguard | SEGV | `pc=0x101e7e8 addr=0x272a5 code=1 x2=0x7fea127d80 x8=0x272a5 insn=0xb9800108` |
| L2147 | 1793708543 | 2026-11-03T20:22:23+08:00 | 31797 | slotguard | REPAIR | `pc=0x101e7e8 fault=0x272a5 rt=8 code=1` |
| L2153 | 1793708834 | 2026-11-03T20:27:14+08:00 | 21478 | sh | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2154 | 1793708834 | 2026-11-03T20:27:14+08:00 | 21478 | sh | SEGV | `pc=0x4d5474 addr=0 code=1 x2=0x4ae374 x8=0xc0e3bf8 insn=0x3900001f` |
| L2155 | 1793708834 | 2026-11-03T20:27:14+08:00 | 21478 | sh | PASS | `reason=not-load` |
| L2169 | 1793709648 | 2026-11-03T20:40:48+08:00 | 21058 | awk | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2170 | 1793709648 | 2026-11-03T20:40:48+08:00 | 21058 | awk | SEGV | `pc=0x4e7080 addr=0x241dc code=1 x2=0x7fed78b3b8 x8=0x7fffffff insn=0xf9400060` |
| L2171 | 1793709648 | 2026-11-03T20:40:48+08:00 | 21058 | awk | PASS | `reason=rt-ne-rn rt=0 rn=3` |
| L2183 | 1793710298 | 2026-11-03T20:51:38+08:00 | 12765 | ql_entry_auto_q | BIN | `path=/usr/bin/ql_entry_auto_qos dev=45850 ino=1928` |
| L2184 | 1793710298 | 2026-11-03T20:51:38+08:00 | 12765 | ql_entry_auto_q | SEGV | `pc=0x7f877b9ea0 addr=0x16cd5 code=1 x2=0x7fc312a6f8 x8=0x3a insn=0xb9800060` |
| L2185 | 1793710298 | 2026-11-03T20:51:38+08:00 | 12765 | ql_entry_auto_q | PASS | `reason=rt-ne-rn rt=0 rn=3` |
| L2186 | 1793710298 | 2026-11-03T20:51:38+08:00 | 12765 | ql_entry_auto_q | DREPAIR | `pc=0x7f877b9ea0 addr=0x16cd5 rn=3 rec=0x7fc312a880 which=q0 q0=0x16cd5 q2=0x1c28416e00000680` |
| L2196 | 1793710828 | 2026-11-03T21:00:28+08:00 | 19738 | awk | BIN | `path=/bin/busybox dev=45850 ino=4` |
| L2197 | 1793710828 | 2026-11-03T21:00:28+08:00 | 19738 | awk | SEGV | `pc=0x7f8bdf5590 addr=0x28824 code=1 x2=0 x8=0x29fe270 insn=0x38626803` |
| L2198 | 1793710828 | 2026-11-03T21:00:28+08:00 | 19738 | awk | PASS | `reason=not-load` |
| L2199 | 1793710835 | 2026-11-03T21:00:35+08:00 | 24387 | busybox | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2200 | 1793710835 | 2026-11-03T21:00:35+08:00 | 24387 | busybox | SEGV | `pc=0x4b31cc addr=0x4 code=1 x2=0x2 x8=0 insn=0xb9400660` |
| L2201 | 1793710835 | 2026-11-03T21:00:35+08:00 | 24387 | busybox | PASS | `reason=rt-ne-rn rt=0 rn=19` |
| L2202 | 1793710842 | 2026-11-03T21:00:42+08:00 | 25449 | awk | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2203 | 1793710842 | 2026-11-03T21:00:42+08:00 | 25449 | awk | SEGV | `pc=0x4b31cc addr=0x4 code=1 x2=0x40 x8=0xf926270 insn=0xb9400660` |
| L2204 | 1793710842 | 2026-11-03T21:00:42+08:00 | 25449 | awk | PASS | `reason=rt-ne-rn rt=0 rn=19` |
| L2206 | 1793710863 | 2026-11-03T21:01:03+08:00 | 836 | sh | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2207 | 1793710863 | 2026-11-03T21:01:03+08:00 | 836 | sh | SEGV | `pc=0x4e7080 addr=0x21ae9 code=1 x2=0x7fc7d5aee8 x8=0x7fffffff insn=0xf9400060` |
| L2208 | 1793710863 | 2026-11-03T21:01:03+08:00 | 836 | sh | PASS | `reason=rt-ne-rn rt=0 rn=3` |
| L2209 | 1793710863 | 2026-11-03T21:01:03+08:00 | 836 | sh | WOULD_XREP | `path=x3 pc=0x4e7080 addr=0x21ae9 rn=3 rec=0x7fc7d5b030 which=q0 q0=0x21ae9 q2=0x1365fe9b0000062d` |
| L2210 | 1793710904 | 2026-11-03T21:01:44+08:00 | 16186 | awk | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2211 | 1793710904 | 2026-11-03T21:01:44+08:00 | 16186 | awk | SEGV | `pc=0x4b31cc addr=0x4 code=1 x2=0x5 x8=0x4 insn=0xb9400660` |
| L2212 | 1793710904 | 2026-11-03T21:01:44+08:00 | 16186 | awk | PASS | `reason=rt-ne-rn rt=0 rn=19` |
| L2213 | 1793710913 | 2026-11-03T21:01:53+08:00 | 19687 | grep | BIN | `path=/bin/busybox dev=45850 ino=4` |
| L2214 | 1793710913 | 2026-11-03T21:01:53+08:00 | 19687 | grep | SEGV | `pc=0x7f95195590 addr=0x25ba0 code=1 x2=0 x8=0x28bdb270 insn=0x38626803` |
| L2215 | 1793710913 | 2026-11-03T21:01:53+08:00 | 19687 | grep | PASS | `reason=not-load` |
| L2216 | 1793710915 | 2026-11-03T21:01:55+08:00 | 21066 | ps | BIN | `path=/bin/busybox dev=45850 ino=4` |
| L2217 | 1793710915 | 2026-11-03T21:01:55+08:00 | 21066 | ps | SEGV | `pc=0x7fb75c1ee4 addr=0x20566 code=1 x2=0x7fc8c45d28 x8=0x3a insn=0xb9400060` |
| L2218 | 1793710915 | 2026-11-03T21:01:55+08:00 | 21066 | ps | PASS | `reason=rt-ne-rn rt=0 rn=3` |
| L2219 | 1793710915 | 2026-11-03T21:01:55+08:00 | 21066 | ps | WOULD_XREP | `path=x3 pc=0x7fb75c1ee4 addr=0x20566 rn=3 rec=0x7fc8c45eb0 which=q0 q0=0x20566 q2=0x1365fe9b0000062d` |
| L2221 | 1793710940 | 2026-11-03T21:02:20+08:00 | 29539 | sh | BIN | `path=/data/gw/bin/busybox dev=66318 ino=8860` |
| L2222 | 1793710940 | 2026-11-03T21:02:20+08:00 | 29539 | sh | SEGV | `pc=0x4d5474 addr=0 code=1 x2=0x7fe1ca3c10 x8=0xaf insn=0x3900001f` |
| L2223 | 1793710940 | 2026-11-03T21:02:20+08:00 | 29539 | sh | PASS | `reason=not-load` |
| L2225 | 1793711024 | 2026-11-03T21:03:44+08:00 | 31797 | slotguard | SEGV | `pc=0x101e7e8 addr=0xffffffffffffffd8 code=1 x2=0x7fea127d80 x8=0xffffffffffffffd8 insn=0xb9800108` |
| L2226 | 1793711024 | 2026-11-03T21:03:44+08:00 | 31797 | slotguard | PASS | `reason=shape-fail w=0x1365fe9b0000062d,0,0x7fea127e60,0xffffff80ffffffe0` |

> 逐条表已截断：armed 段非 STAT 事件共 **200** 行，此处仅列前 60 行；全量计数见上表（直方为全量，非抽样）。

**REPAIR/DREPAIR/XREPAIR 分层（布防后，按 comm）**：

| 事件 | comm | 次数 |
|---|---|---|
| DREPAIR | basename | 1 |
| DREPAIR | busybox | 6 |
| DREPAIR | hostapd | 7 |
| DREPAIR | ip | 4 |
| DREPAIR | ql_entry_auto_q | 1 |
| DREPAIR | sh | 3 |
| REPAIR | slotguard | 1 |

**布防后 PASS 按 reason**：rt-ne-rn=37, not-load=9, shape-fail=1

**最近 STAT（epoch 1793719855 = 2026-11-03T23:30:55+08:00）**：mode=dry attached=46 segv=28 repaired=0 passed=28 suppressed=0 loop=0 would=0 would2=2 dfhit=14 near=0 nearinsn=8 rep2=12 xrep=0 xw=2 xr=0 xform=0/0/0/0/0/0/0/0

> xform 八类顺序 = popcopy/bigderef/regload/ldp/store/fp/null/other（nerepair.c L1096-1104）。

**与布防前 dry 段同口径对比（分母必须同时报）**：

| 事件 | dry 段全量（pre/nerepair_log_pre.txt，2097 行） | 本窗布防前 | 布防后 |
|---|---|---|---|
| ATTACH | 127 | 0 | 2 |
| BIN | 41 | 3 | 44 |
| DREPAIR | 0 | 0 | 22 |
| MODE | 4 | 0 | 2 |
| NEAR | 44 | 0 | 12 |
| PASS | 534 | 3 | 47 |
| REPAIR | 0 | 0 | 1 |
| SCAN | 3 | 0 | 0 |
| SEGV | 716 | 3 | 60 |
| START | 4 | 0 | 0 |
| STAT | 477 | 128 | 213 |
| WOULD_DREPAIR | 6 | 1 | 0 |
| WOULD_REPAIR | 141 | 0 | 0 |
| WOULD_XREP | 0 | 0 | 9 |
| XFORM | 0 | 0 | 1 |

> dry 段全量 = 2097 行（含 11-03 10:36 起的 canary 风暴段）；本窗布防前 = 2.16 h；布防后 = 3.59 h。

## C. 死亡侧（NE 台账；多行记录已拼接，断言 fetched==records）

| 断言 | 值 |
|---|---|
| 设备侧报记录数 | 1522 |
| 本地拼接后记录数 | 1522 |
| fetched == records | PASS |

窗口内（>= 2026-11-03T17:45:32+08:00）记录 **43** 条；其中布防后 **40** 条。

| epoch | 时刻 | pid | comm | sig | far | pc | stack | 家族判定 | 判定来源 |
|---|---|---|---|---|---|---|---|---|---|
| 1793703491 | 2026-11-03T18:58:11+08:00 | 11618 | slotguard | sig=11 | 0xffffffffffffffd8 | 0x101e7e8 | `1793699132-11618-1793703491.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793705345 | 2026-11-03T19:29:05+08:00 | 29866 | od | sig=11 | 0x1ee27 | 0x4e6f68 | `1793699132-29866-1793705345.stack` | 家族（nerepair 日志判据命中 WOULD_*） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS,WOULD_DREPAIR |
| 1793706676 | 2026-11-03T19:51:16+08:00 | 5314 | ip | sig=11 | 0x17dde | 0x10a64d8 | `1793699132-5314-1793706676.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793708509 | 2026-11-03T20:21:49+08:00 | 6018 | ip | sig=11 | 0x23ad0 | 0x10a64d8 | `1793699132-6018-1793708509.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793708512 | 2026-11-03T20:21:52+08:00 | 7240 | logread | sig=11 | 0x2bcd0 | 0x7f9cf73ffc | `1793699132-7240-1793708512.stack` | 无本地栈/未扫 | 未提供 --stacks-dir 或无同名文件 |
| 1793708514 | 2026-11-03T20:21:54+08:00 | 7858 | sh | sig=11 | 0x187a6 | 0x7fa5663590 | `1793699132-7858-1793708514.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793708834 | 2026-11-03T20:27:14+08:00 | 21478 | sh | sig=11 | 0x0 | 0x4d5474 | `1793699132-21478-1793708834.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793709648 | 2026-11-03T20:40:48+08:00 | 21058 | awk | sig=11 | 0x241dc | 0x4e7080 | `1793699132-21058-1793709648.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710828 | 2026-11-03T21:00:28+08:00 | 19738 | awk | sig=11 | 0x28824 | 0x7f8bdf5590 | `1793699132-19738-1793710828.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710835 | 2026-11-03T21:00:35+08:00 | 24387 | busybox | sig=11 | 0x4 | 0x4b31cc | `1793699132-24387-1793710835.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710842 | 2026-11-03T21:00:42+08:00 | 25449 | awk | sig=11 | 0x4 | 0x4b31cc | `1793699132-25449-1793710842.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710863 | 2026-11-03T21:01:03+08:00 | 836 | sh | sig=11 | 0x21ae9 | 0x4e7080 | `1793699132-836-1793710863.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710904 | 2026-11-03T21:01:44+08:00 | 16186 | awk | sig=11 | 0x4 | 0x4b31cc | `1793699132-16186-1793710904.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710913 | 2026-11-03T21:01:53+08:00 | 19687 | grep | sig=11 | 0x25ba0 | 0x7f95195590 | `1793699132-19687-1793710913.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710915 | 2026-11-03T21:01:55+08:00 | 21066 | ps | sig=11 | 0x20566 | 0x7fb75c1ee4 | `1793699132-21066-1793710915.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793710940 | 2026-11-03T21:02:20+08:00 | 29539 | sh | sig=11 | 0x0 | 0x4d5474 | `1793699132-29539-1793710940.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711024 | 2026-11-03T21:03:44+08:00 | 31797 | slotguard | sig=11 | 0xffffffffffffffd8 | 0x101e7e8 | `1793699132-31797-1793711024.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711038 | 2026-11-03T21:03:58+08:00 | 854 | ip | sig=11 | 0x25fd7 | 0x10a64d8 | `1793699132-854-1793711038.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711081 | 2026-11-03T21:04:41+08:00 | 16653 | busybox | sig=11 | 0x22826 | 0x4e6f28 | `1793699132-16653-1793711081.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711090 | 2026-11-03T21:04:50+08:00 | 18828 | busybox | sig=11 | 0x4 | 0x4b31cc | `1793699132-18828-1793711090.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711096 | 2026-11-03T21:04:56+08:00 | 8236 | thermal_core | sig=11 | 0x1bd55 | 0x7f87cd5ea0 | `1793699132-8236-1793711096.stack` | 无本地栈/未扫 | 未提供 --stacks-dir 或无同名文件 |
| 1793711109 | 2026-11-03T21:05:09+08:00 | 27695 | sh | sig=11 | 0x21875 | 0x7fb9fc02f8 | `1793699132-27695-1793711109.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711113 | 2026-11-03T21:05:13+08:00 | 28477 | modprobe | sig=11 | 0x1de40 | 0x7f9e9ae9f0 | `1793699132-28477-1793711113.stack` | 无本地栈/未扫 | 未提供 --stacks-dir 或无同名文件 |
| 1793711115 | 2026-11-03T21:05:15+08:00 | 30664 | logread | sig=11 | 0x27f20 | 0x7fbc9fdffc | `1793699132-30664-1793711115.stack` | 无本地栈/未扫 | 未提供 --stacks-dir 或无同名文件 |
| 1793711118 | 2026-11-03T21:05:18+08:00 | 31852 | ps | sig=11 | 0x23222 | 0x7f80bd4ee4 | `1793699132-31852-1793711118.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711148 | 2026-11-03T21:05:48+08:00 | 11226 | awk | sig=11 | 0x4 | 0x4b31cc | `1793699132-11226-1793711148.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793711160 | 2026-11-03T21:06:00+08:00 | 11617 | nerepair | sig=11 | 0x28f80 | 0x101f59c | `1793699132-11617-1793711160.stack` | 无本地栈/未扫 | 未提供 --stacks-dir 或无同名文件 |
| 1793715278 | 2026-11-03T22:14:38+08:00 | 28169 | busybox | sig=11 | 0x4 | 0x4b31cc | `1793711250-28169-1793715278.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793716433 | 2026-11-03T22:33:53+08:00 | 28361 | ip | sig=11 | 0x8f26 | 0x10a64d8 | `1793711250-28361-1793716433.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793716857 | 2026-11-03T22:40:57+08:00 | 16619 | sh | sig=11 | 0x0 | 0x4d5474 | `1793711250-16619-1793716857.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793717810 | 2026-11-03T22:56:50+08:00 | 22221 | busybox | sig=11 | 0x4 | 0x4b31cc | `1793711250-22221-1793717810.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793717863 | 2026-11-03T22:57:43+08:00 | 21478 | sh | sig=11 | 0x0 | 0x4d5474 | `1793711250-21478-1793717863.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793717996 | 2026-11-03T22:59:56+08:00 | 20772 | awk | sig=11 | 0x20f3c | 0x7fad722590 | `1793711250-20772-1793717996.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718038 | 2026-11-03T23:00:38+08:00 | 3324 | sh | sig=11 | 0x21417 | 0x428948 | `1793711250-3324-1793718038.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718237 | 2026-11-03T23:03:57+08:00 | 10750 | cut | sig=11 | 0x0 | 0x4d5474 | `1793711250-10750-1793718237.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718429 | 2026-11-03T23:07:09+08:00 | 13891 | awk | sig=11 | 0x4 | 0x4b31cc | `1793711250-13891-1793718429.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718492 | 2026-11-03T23:08:12+08:00 | 4108 | awk | sig=11 | 0x4 | 0x4b31cc | `1793711250-4108-1793718492.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718646 | 2026-11-03T23:10:46+08:00 | 27983 | ip | sig=11 | 0x231f1 | 0x10a64d8 | `1793711250-27983-1793718646.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718815 | 2026-11-03T23:13:35+08:00 | 25071 | ip | sig=11 | 0x2923a | 0x10432b8 | `1793711250-25071-1793718815.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718890 | 2026-11-03T23:14:50+08:00 | 18729 | sh | sig=11 | 0x20779 | 0x4e7080 | `1793711250-18729-1793718890.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718903 | 2026-11-03T23:15:03+08:00 | 24181 | ip | sig=11 | 0x111a8 | 0x10a64d8 | `1793711250-24181-1793718903.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793718915 | 2026-11-03T23:15:15+08:00 | 28313 | brctl | sig=11 | 0x13fce | 0x4e7080 | `1793711250-28313-1793718915.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |
| 1793719073 | 2026-11-03T23:17:53+08:00 | 23906 | sh | sig=11 | 0x27281 | 0x4e7080 | `1793711250-23906-1793719073.stack` | 非可修形态（同刻无 WOULD_*；仅证 16KB 判据窗口内无记录，栈内其余部分未扫） | 未提供 --stacks-dir 或无同名文件；nerepair 同刻日志: PASS |

分类口径：① nerepair 同刻日志出现 WOULD_*/REPAIR/DREPAIR ⇒ 家族级（其判据已含 w1==w3==0 + 记录存在）；② 否则用本地 .stack 跑 natne_scan 同判据（stride 8、A0B2/B0A2）⇒ 家族/非家族；③ 无本地栈则记未扫，**不得**据 far/pc 单独判定。

> **补充（人工确认，非本脚本产出）**：① 18:58:11 slotguard 的 .stack 已于 19:26:58 在设备侧用**同一 8B-stride strict 判据**扫描 → **0 条**记录（见 docs/review/NEREPAIR_EFFICACY.md §2.5），与本表「非可修形态」一致；② 19:29:05 od 的 .stack 未做本地扫描（避免再执行设备端 od 造成二次注入，同一原因见 NEREPAIR_EFFICACY §6.6）；③ 19:51:16 ip 的 .stack 亦未扫 ⇒ 该行的「非可修形态」仅指 nerepair 判据窗口内无记录。

## D. R-11 存活表（被修进程的存活/再死亡；消费 survival.tsv）

| 断言 | 值 |
|---|---|
| survival.tsv 格式 | 9 列（first_alive + last_alive 均落盘） |
| survival.tsv 行数 | 8 |
| 合并日志布防后 REPAIR/DREPAIR/XREPAIR 条数 | 23 |
| 断言 survival 覆盖全部 REPAIR | FAIL（survival=8 vs log=23） |

| pid | comm | 事件 | 修复时刻 | status | 首活确认延迟 (first_alive 减 修复) | **存活下界 (last_alive 减 修复)** | last_check 参考 | 同刻死亡(修复未救活) | 之后再死亡(NE) |
|---|---|---|---|---|---|---|---|---|---|
| 14873 | sh | DREPAIR | 2026-11-03T20:12:48+08:00 | **gone_before_first_poll** | — | **无**（该状态不构成健康存活证据） | 199.1 min | 否 | 否 |
| 31797 | slotguard | REPAIR | 2026-11-03T20:22:23+08:00 | **died_later** | 9.1 min | 39.2 min（died_later：末次确认存活即为下界） | 189.5 min | 否 | 是: 2026-11-03T21:03:44+08:00 |
| 12765 | ql_entry_auto_q | DREPAIR | 2026-11-03T20:51:38+08:00 | **died_later** | 9.9 min | 9.9 min（died_later：末次确认存活即为下界） | 160.2 min | 否 | 否 |
| 1404 | basename | DREPAIR | 2026-11-03T21:04:00+08:00 | **gone_before_first_poll** | — | **无**（该状态不构成健康存活证据） | 147.9 min | 否 | 否 |
| 15949 | busybox | DREPAIR | 2026-11-03T21:05:58+08:00 | **gone_before_first_poll** | — | **无**（该状态不构成健康存活证据） | 145.9 min | 否 | 否 |
| 28211 | sh | DREPAIR | 2026-11-03T23:00:33+08:00 | **alive** | 1.3 min | 31.3 min（status=alive：末轮仍活） | 31.3 min | 否 | 否 |
| 9250 | ip | DREPAIR | 2026-11-03T23:14:21+08:00 | **gone_before_first_poll** | — | **无**（该状态不构成健康存活证据） | 17.5 min | 否 | 否 |
| 24917 | hostapd | DREPAIR | 2026-11-03T23:16:47+08:00 | **alive** | 5.1 min | 15.1 min（status=alive：末轮仍活） | 15.1 min | 否 | 否 |

> **存活判据与实现语义（已核对采集器 arm_watch.py L126-158，2026-11-03 20:0x 版）**：① 9 列格式下 first_alive = 首次确认存活、last_alive **每次仍活都刷新** = 末次确认存活 ⇒ **存活下界 = last_alive 减 修复时刻**（status=alive 用末轮确认值；died_later 用末次确认存活值），这是 F1 的判据量；② 「首活确认延迟 = first_alive 减 修复时刻」并列给出，用于对照（观察者轮询间隔量级）；③ 8 列兼容格式（旧文件）下 last_alive 仅首次写入 ⇒ 该行标出退化并改用 last_check（**F1 在 8 列口径下会在判定里标注**）；④ gone_before_first_poll = 首轮前已消失（**不算健康存活**）；pid_reused = 同 pid 换了 comm；not_seen = 尚无有效观测；⑤ 「同刻死亡 / 之后再死亡」按 §C 的 NE 全量台账核。

### D2. mode0 弱门分诊（triage.tsv；采集器每轮对**窗口内** DREPAIR 行离线跑；弱门口径见 NEREPAIR_EFFICACY 1.3g）

| 断言 | 值 |
|---|---|
| triage.tsv 轮数 | 23 |
| 最近一轮（2026-11-03T23:31:53+08:00） | n(deref repairs)=22 ok=8 review=14 |
| REVIEW 峰值 / 累计 deref repairs / 每轮 n 峰值 | 14 / 187 / 22 |
| 护栏阈值（REVIEW>=2 且占比>=30 pct）是否已达 | 是（见 ALERTS.txt） |
| derepair_window.log 行数 | 22 |
| ALERTS.txt | 有告警（原文见下） |

```
2026-11-03T20:21:27+08:00 DREPAIR_REVIEW_RATIO 2/2
2026-11-03T20:31:29+08:00 DREPAIR_REVIEW_RATIO 2/2
2026-11-03T20:41:30+08:00 DREPAIR_REVIEW_RATIO 2/2
2026-11-03T20:51:31+08:00 DREPAIR_REVIEW_RATIO 2/2
2026-11-03T21:01:33+08:00 DREPAIR_REVIEW_RATIO 2/3
2026-11-03T21:11:34+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T21:21:36+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T21:31:37+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T21:41:39+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T21:51:40+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T22:01:42+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T22:11:43+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T22:21:44+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T22:31:46+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T22:41:47+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T22:51:48+08:00 DREPAIR_REVIEW_RATIO 6/10
2026-11-03T23:01:50+08:00 DREPAIR_REVIEW_RATIO 7/11
2026-11-03T23:11:51+08:00 DREPAIR_REVIEW_RATIO 7/11
2026-11-03T23:21:52+08:00 DREPAIR_REVIEW_RATIO 14/22
2026-11-03T23:31:53+08:00 MODE_NOT_ARMED mode=dry;DREPAIR_REVIEW_RATIO 14/22
```

> 分诊口径（tools/oneoff/sigsegv/mode0_repair_triage.py）：对每条窗口内 DREPAIR/XREPAIR 行用与判据同源的 shape_ok 复算记录形状；ok = 形状一致；REVIEW = **弱门（mode 0）可能假阳性的候选**（advisory only，不是误修判定）。本表只引用采集器落盘结果，不重跑分诊。


## E. 口径与限制

1. **观测者污染**：采集器 latest.json.devcmd 保留**每轮**快照命令原文（只读 cat/ls/pidof/wc/tail/echo 与 /proc/<pid>/stat，无 od），可用于把窗口内任何异常事件归属到具体命令（S2）；本报告另有只读拉取 tmpfiles/review/arm/pull1.txt（设备侧 awk 拼接）与更早的 .stack 取证命令；**由取证命令派生的崩溃必须单列**（先例：2026-11-03 19:29:05 od applet 崩溃，见 docs/review/NEREPAIR_EFFICACY.md §6.6）。
2. **无对照臂 / 无 canary**：本窗没有 dry 对照臂、没有探针在跑 ⇒ 崩溃减少不可由本窗得出；只有 REPAIR 事件数、被修进程存活结果与背景率功效可报。
3. **日志轮转（已由合并档案兜底）**：nerepair.log 单代 1 MB 轮转；实测增长 **0.82 MB/日**（Lead 20:04 复核）⇒ 4 h 窗内不轮转；且采集器每 10 min 全量拉取并合并进 arm_log_merged.txt（抗轮转）。本报告以该合并档案为准，并在文末给**合并行数断言**（merged_lines）与设备 wc -l 对照。
4. **更早 boot 段混入**：合并日志含 11-03 10:36 起的更早实例/更早 boot 段（epoch 非单调）⇒ 分段一律按 epoch 与 MODE/START 边界，不按文件顺序，跨 boot 不混算。
5. **NE 台账解析**：设备侧 awk 把续行拼成一行（`^[0-9]` 起头=新记录），断言 fetched == 设备记录数；按物理行解析会把 args 里的换行当新记录（历史坑）。

6. **双重不可见（armed 窗口的结构性盲区；task-8 审计项①）**：arm64 的 kmsg unhandled-fault 行要求 !tsk->ptrace（docs/SIGSEGV/03_PROBES.md:164-166：「unhandled ... fault (11) 行本身在 nerepair 在役时结构性缺席」；skeptic 审计 docs/review/WRITER_HUNT_GAP_AUDIT.md:52 条目①：「19:55 布防后该信道继续缺席，且被修的崩溃不再进 NE 台账 ⇒ 双重不可见」）。⇒ ① 布防后**被修复的崩溃**的**唯一记录 = nerepair.log 的 REPAIR/DREPAIR/XREPAIR 行**（含 comm/pc/addr/记录证据）——这正是本报告必须依赖「采集器合并档案 + survival.tsv + triage.tsv」的理由（kmsg 与 NE 台账在该路径上都为空）；② 反向推论：**不得因布防后 NE 台账归零就宣布崩溃停止**（被修的不进台账；未命中的仍会进）；③ 叠加 nerepair 的行限流（rate_ok 20 行/s、rate_ok_prio 200 行/s，nerepair.c L177-216）⇒ REPAIR 行在风暴下可能被丢弃，故加下面的一致性断言。
> 本断言按**实例内**口径：基线取 armed 段最后一个 STAT 计数器回退点（epoch 2026-11-03T21:09:55+08:00，merged L2325）；该段内 REPAIR 行数 12。

7. **限流/口径一致性断言（REPAIR 行数 vs STAT 增量；同实例，首个 armed STAT → 末行）**：

| 断言 | 值 | 判 |
|---|---|---|
| 路径 | 末实例段内**行数** | 末实例段内 **ΔSTAT** | 一致性断言（行数 >= Δ） |
|---|---|---|---|
| REPAIR | 0 | Δrepaired = 0 | PASS |
| DREPAIR | 12 | Δrep2 = 12 | PASS |
| XREPAIR | 0 | Δxr = 0 | PASS |
| 合计 | 12 | 12 | PASS |
| 旧实例（参考，末 STAT 2026-11-03T21:06:00+08:00） | REPAIR 1 / DREPAIR 10 / XREPAIR 0 | 1 / 10 / 0 | PASS |

> **口径**：跨实例相减无意义（STAT 计数器在新实例从 0 起）⇒ 按「末实例段内」与「旧实例」两段分别对齐；这样避免把全段 23 行去比末实例 Δ=12 的假不一致。三条路径各自独立断言（Lead 指定）。
| ΔSTAT suppressed（限流丢弃计数，含所有事件类型） | 0 | 0 = 本窗未发生限流丢弃 |

> 计数点：REPAIR 行 = g_repaired（nerepair.c L966）、DREPAIR 行 = g_rep2（L768）、XREPAIR 行 = g_xr（L762/L927）；三者自增**先于** rate_ok_prio 判定 ⇒ STAT 计数器是地面真值，行数少于它即说明丢行。STAT 计数器只在同一实例内可比（本窗 arm_stat 行数=211；实例 pids=[('11617', 11), ('11740', 15)]）。
8. **`loop=0` 不代表无级联**：熔断器按 **(pid, pc)** 计数（nerepair.c L146-172，NR_LOOP_MAX=8；站点一变就重置计数）⇒ STAT 的 `loop=` 只表示「没有任何单个 (pid,pc) 连续被修超过 8 次」，**不表示**没有跨站点的修复链。本窗 hostapd 同 pid 在 2 个 pc 上被修 6+1 次、busybox 同 pid 多 pc 连发，均未触发 loop，但仍是级联形态 ⇒ 判级联要看 §G 的 (pid,pc,addr) 递进，不能只看 loop。
9. **功效（按背景率，不用窗内计数投影）**：自然 NE 背景 0.5-1.5/h ⇒ 布防后 3.59 h 期望 1.80-5.39 起，P(0)=0.166-0.00457；窗内 n=0 不提供速率信息。

## F. 预注册判据（0 点前写定，不改）

| # | 判据 | 判定 |
|---|---|---|
| F1 | **修复生效（正）** = 布防后 >=1 起**家族型** REPAIR/DREPAIR（triage=ok，即形状一致；path1 REPAIR 以 x2 形状门为准）**且存活下界 >=30 min**（survival.tsv status=alive 的 last_alive 减 修复时刻）**且**该 pid 无修复后的 NE 死亡记录 | **未满足**（布防后修复 23 条；status=alive 且下界>=30min 的行=2，其中 triage=ok 的 **0** 条；triage REVIEW 形状不一致者不计为家族级） |
| F2 | **反向（负）** = 被修进程 died_later / gone_before_first_poll / pid_reused，或同 pid 反复出现 REPAIR，或 loop 熔断激增 | **命中**：14873(gone_before_first_poll),31797(died_later),12765(died_later),1404(gone_before_first_poll),15949(gone_before_first_poll),9250(gone_before_first_poll) |
| F3 | **中性** = 布防后 0 REPAIR ⇒ 本窗对是否减少崩溃**无判别力** | 不适用（REPAIR=23>0，改用 F1/F2/F5 判） |
| F4 | **禁止**：用本窗 NE 比 dry 少声称效力（修复后崩溃不进 NE = 同义反复，见 NEREPAIR_EFFICACY 6.1；且 kmsg unhandled-fault 信道在 nerepair 在役时结构缺席 = 双重不可见，见 §E6） | 遵守 |
| F5 | **Lead 预注册停止线**：triage（mode0 弱门分诊）REVIEW 占比 **>30 pct** ⇒ 触发回滚 | **命中**：REVIEW 14 / (ok 8 + REVIEW 14) = **63.6 pct** > 30 pct ⇒ 应回滚；实际已于 2026-11-03T23:28:49+08:00 回滚 |

> F5 分诊由本脚本在窗口切片上重跑（tools/oneoff/sigsegv/mode0_repair_triage.py；输入 = armed 段 DREPAIR/XREPAIR 行，切片落 tmpfiles/review/arm/triage_mine/derepair_window_armed.log），与采集器 triage.tsv 最后一轮互为交叉校验（§D2）。

> 预注册副本 = 本文件在 0 点前生成的版本（生成戳见文末）；此表由脚本模板固定，0 点后重跑不改表体，只填判定列。
## G. 修复清单（armed 段；逐条含记录证据 + 存活 + 分诊判定）

| # | 时刻 | comm | pid | 事件 | pc | addr | 记录证据 | 存活状态 | 存活下界 | triage |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 2026-11-03T20:12:48+08:00 | sh | 14873 | DREPAIR | 0x4e7080 | 0xa206 | q0=0x4a9e8c q2=0xa206 which=q2 | gone_before_first_poll | — | **REVIEW** |
| 2 | 2026-11-03T20:12:48+08:00 | sh | 14873 | DREPAIR | 0x400688 | 0xa210 | q0=0x7f86c38f7a q2=0xa210 which=q2 | gone_before_first_poll | — | **REVIEW** |
| 3 | 2026-11-03T20:22:23+08:00 | slotguard | 31797 | REPAIR | 0x101e7e8 | 0x272a5 | fault=0x272a5 rt=8（path1，x2 形状门） | died_later | 39.2 min | **—（path1 不在分诊口径内）** |
| 4 | 2026-11-03T20:51:38+08:00 | ql_entry_auto_q | 12765 | DREPAIR | 0x7f877b9ea0 | 0x16cd5 | q0=0x16cd5 q2=0x1c28416e00000680 which=q0 | died_later | 9.9 min | **REVIEW** |
| 5 | 2026-11-03T21:04:00+08:00 | basename | 1404 | DREPAIR | 0x4c8728 | 0x1f5d7 | q0=0x1f5d7 q2=0x1365fe9b0000062d which=q0 | gone_before_first_poll | — | **REVIEW** |
| 6 | 2026-11-03T21:05:58+08:00 | busybox | 15949 | DREPAIR | 0x4e7080 | 0x1dbce | q0=0x1dbce q2=0x1365fe9b0000062d which=q0 | gone_before_first_poll | — | **REVIEW** |
| 7 | 2026-11-03T21:05:58+08:00 | busybox | 15949 | DREPAIR | 0x4e82c8 | 0x1dbd8 | q0=0x1dbd8 q2=0 which=q0 | gone_before_first_poll | — | **REVIEW** |
| 8 | 2026-11-03T21:05:58+08:00 | busybox | 15949 | DREPAIR | 0x4e7010 | 0x1dbe0 | q0=0x1dbd8 q2=0 which=q0 | gone_before_first_poll | — | **REVIEW** |
| 9 | 2026-11-03T21:05:58+08:00 | busybox | 15949 | DREPAIR | 0x4e7080 | 0x1dbce | q0=0x1dbce q2=0x1365fe9b0000062d which=q0 | gone_before_first_poll | — | **REVIEW** |
| 10 | 2026-11-03T21:05:58+08:00 | busybox | 15949 | DREPAIR | 0x4e82c8 | 0x1dbd8 | q0=0x1dbd8 q2=0 which=q0 | gone_before_first_poll | — | **REVIEW** |
| 11 | 2026-11-03T21:05:58+08:00 | busybox | 15949 | DREPAIR | 0x4e7010 | 0x1dbe0 | q0=0x1dbd8 q2=0 which=q0 | gone_before_first_poll | — | **REVIEW** |
| 12 | 2026-11-03T23:00:33+08:00 | sh | 28211 | DREPAIR | 0x40b258 | 0x11a4f | q0=0x11a4f q2=0x11a4f which=q2 | alive | 31.3 min | **REVIEW** |
| 13 | 2026-11-03T23:14:21+08:00 | ip | 9250 | DREPAIR | 0x7f7ffbf2f8 | 0x172f6 | q0=0x7f7ffe62b4 q2=0x172f6 which=q2 | gone_before_first_poll | — | **REVIEW** |
| 14 | 2026-11-03T23:14:21+08:00 | ip | 9250 | DREPAIR | 0x7f7ffbdffc | 0x17300 | q0=0x17308 q2=0xd773247200000669 which=q0 | gone_before_first_poll | — | **REVIEW** |
| 15 | 2026-11-03T23:14:21+08:00 | ip | 9250 | DREPAIR | 0x7f7ffbdffc | 0x17308 | q0=0x17310 q2=0xd773247200000669 which=q0 | gone_before_first_poll | — | **REVIEW** |
| 16 | 2026-11-03T23:14:21+08:00 | ip | 9250 | DREPAIR | 0x7f7ff82968 | 0x17310 | q0=0x17310 q2=0xd773247200000669 which=q0 | gone_before_first_poll | — | **?** |
| 17 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ee4 | 0x1422b | q0=0x1422b q2=0x1a2746cb0000062b which=q0 | alive | 15.1 min | **?** |
| 18 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ee4 | 0x14230 | q0=0xffffff80 q2=0x14238 which=q2 | alive | 15.1 min | **?** |
| 19 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ee4 | 0x14238 | q0=0xffffff80 q2=0x14240 which=q2 | alive | 15.1 min | **?** |
| 20 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ee4 | 0x14240 | q0=0xffffff80 q2=0x14248 which=q2 | alive | 15.1 min | **?** |
| 21 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ee4 | 0x14248 | q0=0xffffff80 q2=0x14250 which=q2 | alive | 15.1 min | **?** |
| 22 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ee4 | 0x14250 | q0=0xffffff80 q2=0x14258 which=q2 | alive | 15.1 min | **?** |
| 23 | 2026-11-03T23:16:47+08:00 | hostapd | 24917 | DREPAIR | 0x7fb6ad2ea0 | 0x14258 | q0=0xffffff80 q2=0x14260 which=q2 | alive | 15.1 min | **?** |

> 分诊口径同 §D2（ok=形状一致；REVIEW=mode0 弱门可能假阳性的候选，advisory）。hostapd 组 q0=0xffffff80（负数，不是 A 字）、q2 为自指地址 ⇒ 按 natne_scan 同族 strict 判据不是家族记录。

## H. 死亡侧时间分布（NE 台账）与风暴段

| 小时 | NE 记录数（armed 段） | 同小时基线（17:45:32-19:55:21） |
|---|---|---|
| 2026-11-03T18 | 0 | 1 |
| 2026-11-03T19 | 0 | 2 |
| 2026-11-03T20 | 5 | 0 |
| 2026-11-03T21 | 19 | 0 |
| 2026-11-03T22 | 6 | 0 |
| 2026-11-03T23 | 10 | 0 |

> armed 段 NE 记录合计 **40** 条（在 §C 的 fetched==records 断言通过后按 epoch 筛选）。

**21:00-21:07 风暴段**（epoch 1793710800-1793711220）：NE 记录 19 条，comm=awk x4, busybox x3, sh x3, ps x2, grep x1, slotguard x1, ip x1, thermal_core x1, modprobe x1, logread x1, nerepair x1。
同段 nerepair 侧：SEGV 23 / DREPAIR 7 / REPAIR 0。

## I. 非计划重启（事实清单，不含因果）

| 事实 | 值/证据 | 来源 |
|---|---|---|
| watch 轮询的 npid/uptime 不连续 | 见 §A「实例切换/重启检测」行 | watch.tsv（600 s/轮） |
| **重启时刻推导（只读可复算）** | watch 首轮见到新实例：21:11:34（uptime=243.9 s）⇒ boot ≈ **2026-11-03T21:07:30+08:00** | watch.tsv（本机 local_ts 与设备 uptime 相减） |
| STAT 计数器回退（新实例从 0 起） | armed 段 STAT segv 峰值 35；回滚前末次 STAT segv=28 | armed 段 STAT 序列 |
| 设备侧重启记录 | reboots.log 无该次记录（仅 04:00 计划重启）；pstore 无新 ramoops；syslog 21:05:33 截断且无关机序列 | Lead 23:27-23:32 只读实测（本报告未独立复读这些设备文件） |
| boot 恢复 | boot_babysit 21:09:10 起 boot 正常、21:09:21 boot gate passed | 同上 |

> **不得因果化**：重启原因未定（看门狗复位/挂起待证）；本节只记事实与时序。

## I2. 监督者自身被家族写者打死（本轮新增，实机闭环）

| 事实 | 值 | 来源 |
|---|---|---|
| 监督者自身 NE | epoch **1793711160** = 21:06:00，pid **11617**，comm **nerepair**，sig=11，**far=0x28f80**，pc=0x101f59c | NE 台账（ne_joined_latest.txt 该行，经 fetched==records 断言） |
| 该进程栈 | 1793699132-11617-1793711160.stack（本地副本 tmpfiles/review/arm/nerepair_crash.stack；头解析 pid=11617、stack=[0x7ff0dbe000,0x7ff0dce000)、npages=16、bitmap=0xffff、ts=1793711160 与 NE 行一致） | 本报告独立复算（与 Lead 的 hexdump 复原互为独立通道） |
| **栈内家族记录** | **3 条 A0B2**：top-va 0x1fa0 q0=0x25c7a；top-va 0x14a0 **q0=0x28f80（== far）**；top-va 0x1260 **q0=0x28f88（== far+8）**；三条 q2 均 = 0x1365fe9b0000062d（len **0x62d=1581**，ip 19.101.254.155） | 本报告用 natne_scan 同判据（stride 8、A0B2）扫描本地 .stack；与 Lead 的命中位置/q0 一致 |
| 判级 | **形态 E4**（记录 q0 与 fault 精确对齐、且 far+8 亦在同一栈内 ⇒ 与家族语料同形的致命路径）+ **现场 E3**（NE 行 + .stack 命中 + 时序可复算） | 本报告 + Lead 独立取证 |
| 观测盲区 | nerepair.log 自 **21:06:00** 之后无任何事件，下一行是 **21:09:55**（STAT，新实例 attached=44、segv=0 计数器已归零）⇒ 盲区 **3 min 55 s**；期间 21:07:30 发生非计划重启（§I） | merged 事件序列（STAT 21:06:00 / 21:09:55 之间为空） |
| 本地副本完整性 | 65,584 B（设备 65,592 B 少 8 B，hexdump 复原边界差）；magic/头/bitmap 均自洽，3 条命中位置 (dataoff 0xe060/0xeb60/0xeda0) 均在可扫窗口内 ⇒ 不影响结论 | 本报告复算 |

> **含义（不含因果）**：① 写者把 32B 记录写进了**监督者自己的栈**，监督者按自指 LDR 解引用致死 ⇒ 「守卫自身也是受害者」，这是**守卫在风暴中先死**的实机证据（守护进程一死，其覆盖的用户进程全部失去修复能力，直到 watchdog 拉起/重启）；② 该死亡解释了 21:06:00-21:09:55 的观测盲区（日志与 STAT 同时消失）；③ **不推断**该死亡与 21:07:30 非计划重启的因果关系（时序相邻 ≠ 因果，重启原因仍未定，§I）；④ 本条**不改变** §E6 的双重不可见结论（其他被 ptrace 的进程其 unhandled-fault 行仍缺席），监督者自身未被 ptrace，其 kmsg 行是否存在本报告未复核。

## J. 结论（不含因果）

- armed 段（2026-11-03T19:55:21+08:00 → 2026-11-03T23:28:49+08:00，3.56 h）共 **23 次修复**：DREPAIR 22 + REPAIR 1（path1），逐条见 §G。
- **弱门假修复居多**：triage 重跑 REVIEW 14 / 22 = **63.6 pct**（ok 8）⇒ 越过 Lead 预注册停止线（>30 pct）；hostapd 组 q0=0xffffff80（负数）、q2 自指 ⇒ 非家族记录（§G/§D2 与 natne_scan 同判据）。
- **存活证据薄弱**：status=alive 2 行，存活下界最长 **31.3 min**；但达到 >=30 min 的那条其修复被 triage 判 **REVIEW（形状不一致）**，不构成家族级生效证据 ⇒ **F1 未满足**；died_later/gone_before_first_poll 6 行 ⇒ **F2 命中**（§D/§F/G）。
- **NE 台账**：armed 段新增 **40** 条；单小时最高 19 条（2026-11-03T21）。**NE 升高与布防的关系未定**，不得因果化。
- **监督者自身被家族写者打死（21:06:00，pid 11617）**：其 .stack 含 3 条 A0B2，其中 q0=0x28f80==far、q0=0x28f88==far+8（§I2）⇒ 「守卫在风暴中先死」实机闭环；随后 3 min 55 s 观测盲区、21:07:30 非计划重启（**因果未定**）。
- **已回滚**：2026-11-03T23:28:49+08:00 起 mode=dry（MODE dry=1 by=SIGUSR2；xrep/arm 仍缺），armed 段结束于 2026-11-03T23:28:49+08:00。
- **禁止**：本窗无对照臂 ⇒ 不得宣称崩溃减少（F4）；亦不得宣称重启或 NE 升高由布防引起（原因未定，§I）。


---

生成戳：2026-11-03T23:36:58+08:00（脚本 nerepair_window_report.py；数据 asof epoch 1793719855 = 2026-11-03T23:30:55+08:00；merged 2558 行，坏行 0）
