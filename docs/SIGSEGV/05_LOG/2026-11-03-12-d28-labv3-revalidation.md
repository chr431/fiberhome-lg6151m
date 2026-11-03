# 12 · D28 预注册 · lab v3 极简环境写入者判决复跑（2026-11-03 白天，设备独占）

> **预注册文档：开窗前写定并 commit；执行后只追加 §10–11（结果/判决），不改 §1–9。**
> 编号说明：任务书指定 `-11-`，但该号已被同日 `2026-11-03-11-t1-ring-target.md` 占用；
> 为免覆盖改用 `-12-`（内容与任务书一致，仅编号顺延）。
> 上游依据：`C-208`（FN-audit：C-187 信道缺陷裁决）、
> `_local/.../phase-AB/FN-audit.md`、`labkernel-v2-build.md`、`labkernel-v3-asset-build.md`、
> `C2-session-report.md`、`B4L-runbook.md`、`bench-b4lab-session.md`。
> 本文档中性命名：不含目标网络名与个人凭证。

## 1. 问题与背景

C-187（lab v2 两窗 0/3600 s）已被 **C-208 撤回**：其"console 信道"实为 `/init` 在
t=3 s 执行的一次 `head -8` 快照；scanary 的 `emit()` 只写 `--log` 文件；全部可见
事件时间戳 ≤39.8 ms；日志随 initramfs RAM 丢失；窗级暴露未证实。因此
"极简环境上是否存在 32B 记录写入者"这一判决**仍然未决**。

本轮（D28）用 **lab v3**（含 v2 两修复 F1 `/dev/console`、F2 窗后交互 shell）重做
该判决，并把观测信道从"console 快照"改为 **窗后交互 shell 直接读 scanary 日志文件
全文**，同时挂 p46 把日志持久化到 `/data`——**从机制上杜绝 C-187 的信道缺陷**。

## 2. 假设（先写死）

- **H（厂商环境必要条件）**：lab v3 两窗（各 1800 s）`inj=0` 真命中 **= 0**。
  判读：写入者的产生/触发**需要厂商内核态环境**（厂商内建/厂商 .ko/CCCI-MD/其驱动
  供给的目标与载体）。厂商固件侧修补有理论依据。
- **H'（写入者与厂商软件栈无关）**：任一有效窗出现 **≥1** 条 `inj=0` 真命中。
  判读：生产者不在厂商软件栈（硬件/MD 自治或通用机制）⇒ 厂商固件上修补无效，
  兜底只能靠隔离/加固（终态）。
- 二分支之外不设"部分成立"；窗无效（§5 形式要件不满足）则不计入，需补窗。

## 3. 仪器与调用（与厂商基线臂逐字节同源）

- 镜像：`boot-lab3-signed.img`，md5 **217ccd57c64cfe46e03e57d7a1a15c9f**（33,554,432 B；
  公开仓 `_drill_backup/labkernel/` 与 `_local/work/lab-kernel/artifacts/` 双份同 md5）。
- 内核：lab 6.18.44 initramfs-only，**零厂商内核态代码、无厂商 .ko、无 WiFi、无 CCI、
  无客户端**；`/dev/console` 已入 cpio（v2 F1），窗后 `setsid cttyhack sh` 交互 shell（v2 F2）。
- canary：`scanary` md5 **17376b743d1df55240b77f8f0be0fdae**（与 B4/基线臂同一二进制）。
- 预注册调用（`/init` 内逐字）：
  `/scanary --victim main --duration 1800 --epoch-sec 0 --probe-sec 120 --hold-us 10000
   --period-us 5000 --stride 16 --writeback safe --log /data/repro/scanary_c2_w1.log`
- 窗2（窗1 结束后 shell 内手动起，参数逐字同上，仅 `--log` 改 w2）：
  `/scanary --victim main --duration 1800 ... --log /data/repro/scanary_c2_w2.log`
- 判据：`inj=0` 且属记录族（scanary 自身 `HIT_*` 行，`inj=1` 为自检注入，不计）。

## 4. 观测信道（本轮核心改进，替代 C-187 的 `head -8`）

1. **同 boot 交互 shell 读日志**：窗1 结束 `/init` 交 console 后，立即
   `cat /data/repro/scanary_c2_w1.log`（全文落串口原始流）+ `busybox md5sum` 记 md5；
   窗2 同理读 `scanary_c2_w2.log`。
2. **持久化**：`mkdir -p /data/repro/d28`；`mknod /dev/mmcblk0p46 b 259 14`；
   `mount -t ext4 /dev/mmcblk0p46 /mnt`；`cp` 两窗日志 + `md5sum > MD5SUMS`；
   `sync`；`umount`。跨重启可查，摆脱 initramfs RAM 丢失。
3. **形式要件（窗有效性，四选四必须全满足）**：
   - `START` 行参数与 §3 逐字一致；
   - `EXIT reason=duration`；
   - `selftest_ok=1` 且 `probe_bad=0`（或 `probe_bad` 有值且有 `PROBE ok=` 正例）；
   - `passes>0` 且 `STAT` 行存在（扫描线程真实运行到窗末）。
   另记录 `/proc/uptime`（开窗/窗末）与 `boot_id`。
4. **正对照（必须出现在日志中）**：`SELFTEST_OK t1_decoy/t2_stack` 与至少一条
   `HIT_* inj=1`（自检注入被 matcher 捕获）。缺失 ⇒ 仪器无效，该窗不计。
5. **信道证据**：串口原始流全量落盘（daemon 不截断）；日志 md5 双端对账
   （设备侧 `busybox md5sum` vs PC 侧对持久化拷贝 `md5sum`）。

## 5. 判决阈值与统计

- **H 成立**：两窗均有效且 `inj=0` 计数 = 0（合计暴露 3600 s）。
  - rule-of-three：0/3600 s ⇒ 95% 上界 **3/3600 s = 0.05/min**（注意：不是旧文档的
    "3/120 min"；且只有在"已证实暴露=3600 s"成立时才可用，本轮由 §4-3 保证）。
  - 与厂商背景对比：C-199 无客户端 0.60/min、C-196 遮罩残余 0.167–0.20/min；
    对 1800 s 期望 11–18 条（0.36–0.60/min 取中），P(0)=e^-11…e^-18 ⇒ 若 lab 条件
    承载该背景，零结果**不是假阴性**（除非 §9 的共线混杂生效）。
- **H' 成立**：任一有效窗 `inj=0` ≥ 1（无需速率推断；存在性判据）。
- 速率跨 boot 不可比（项目既定纪律），本轮只判存在/消失二分。

## 6. 停止规则 / 崩溃预算 / 红线

- 最多 **2 窗**（各 1800 s）；窗1 为 `/init` 自动窗，窗2 为 shell 手动窗。
- lab 启动/窗内 **panic 次数预算 = 2**；第 3 次即中止并回滚（不恋战）。
- 串口连续 >5 min 无任何输出（daemon `ALARM_NO_ECHO`/status 判死）⇒ 中止；
  热保护 `THERMAL_ALARM/SHUTDOWN` ⇒ 立即按 §8 回滚。
- 窗内 scanary 提前退出（`scanary_exited_early` 或 `EXIT` 非 duration）⇒ 该窗无效；
  两窗都提前退出 ⇒ 判 INVALID，报告仪器缺陷，不判 H/H'。
- 设备动作（含回滚）**16:30 前收完**；每步记 `/proc/uptime`；单次设备操作 ≤8 min 红线
  （长窗除外——窗口期间只轮询心跳，不发命令）。
- **不写 p26/p38/p39**；p25 仅按 §7 门禁写；misc 除 §8 的 TRY_A 清零外只读。

## 7. 刷写门禁（lab v3 → p25，A 槽 boot 分区）

1. LK 裸壳（`kcmdline append init=/bin/sh` + `repeat 2000 heap alloc 65536`）后，
   **第一动作 misc 实读** `bio dump mmc0p1 0x800 0x22`：须为 `0f 0X 01 00 00 0e 00 01`
   （A 优先，TRY_A 记下实测值）；非此形 ⇒ 停，先复位。
2. 环境重建（tmpfs /dev + null/zero/urandom + proc；`dmesg -n 1`；eth1 192.168.8.252）。
3. depot 取件：`curl` 拉 `boot-lab3-signed.img` → **md5 必须 == 217ccd57c64cfe46e03e57d7a1a15c9f**
   （不符即止，不写）。
4. `dd if=/tmp/boot-lab3-signed.img of=/dev/mmcblk0p25 bs=1M` → 读回
   `dd if=/dev/mmcblk0p25 bs=1M | md5sum` == 217ccd57… 字节级断言。
5. misc 复查（`bio dump`；本次会话内 LK 自身簿记可能 +1，仅记录）。
6. `echo b > /proc/sys''rq-trigger`（PC 侧 daemon 对 `sysrq` 字面量有守卫，用引号拆分）。

**A3 禁用（重要）**：lab v3 `/init` 的 TRY_A 自清按 **裸设备** `/dev/mmcblk0` offset 2061
读写，而实测 A/B 控制块在 **p1 内 offset 2060**（p1 start=64 扇区；裸@2061 当前值 0x26，
属 GPT 分区表字节——该自清若执行会写坏 GPT 条目）。故本轮 LK 追加
`kcmdline append lab_trya=off` 禁用之；TRY_A 清零改在 §8 用**正确偏移**手动执行并验形。

## 8. 回滚（lab 内核 shell，无需第二次断电）

1. lab shell 内挂 p46（§4-2 同法），取原厂 p25 件
   `/data/gw/logs/p25.boot.c2.img`（md5 **209f481cf1bf489dc04ce1b12a9851f8**；
   PC 侧 `<private-repo>/_drill_backup/p25.boot.c2.img`（私有仓，不入公开仓） 同 md5 双备份）。
2. `md5sum` 门禁 → `dd of=/dev/mmcblk0p25 bs=1M` → 读回 md5 == 209f481c…
3. **TRY_A 清零（正确偏移）**：先读 `dd if=/dev/mmcblk0p1 bs=1 skip=2060 count=10 | hexdump`
   记形；`dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek=2061 count=1`；再读回
   `0f 00 01 00 00 0e 00 01`（A.pri/A.TRY=0/B.pri/B.TRY=0）。**不得**用裸设备偏移。
4. `sync` → `echo b > /proc/sys''rq-trigger` → 厂商 5.15.134 (p26 b4lab 中性) 回笼。
5. 终验：`lgssh` 取 `uname -r` / `boot_id` / `uptime` / `p25` 读回 md5 == 209f481c /
   misc 形 / 关键服务全集合扫描；台账记录 boot_id 与 TRY_A。
6. 备用路径（仅当 lab 内核无 eMMC 写能力）：请用户**断电#2**，走 LK 裸壳按 §7 同门禁
   写回 209f481c，再 `sysrq-b`。

## 9. 混杂与边界（必须与判决同读）

1. lab 移除了 WiFi/CCI/客户端/长驻厂商进程 ⇒ **H 只能证明"厂商环境是必要条件"，
   不能证明"写入者是厂商代码"**；H' 则是强结论（无厂商软件栈仍有写入）。
2. 目标页资格（FN-audit §2.3 #4/#6）：lab 的 initramfs 新页可能从未当过 RX 缓冲，
   若写入者是"stale PA/长驻页"机制，零结果也可能是**目标缺席**而非写入者缺席。
   本轮**无法消除**该共线混杂；H 的表述必须带此边界（与 C-187 同级，但信道已修）。
3. 版本差 6.18.44 vs 5.15.134（C-187 caveat ④ 保留）。
4. 480 MB 保守内存节点（保留）；不影响 scanary ~10 MB，但影响页历史。
5. 窗2 与窗1 同 boot：避开跨 boot 不可比，但两次窗口非独立（共享同一内核状态）；
   判决只取两窗合并暴露，不做速率推断。
6. 时间以设备 `/proc/uptime` 为准（lab 无 RTC，`date` 不可信）。


## 9b. 开窗前修订（2026-11-03 13:5x，设备动作之前）

**发现（离线静态 + 设备只读实测）**：lab v3 `/init` 的 A3 TRY_A 自清按**裸设备**
`/dev/mmcblk0` offset 2061 读写；实测 A/B 控制块在 **p1 内 offset 2060**
（设备只读：`p1@2060 = 0f 00 01 00 00 0e 00 01`，`raw@2060 = b7 26 99 c7 ...`
即 GPT 分区表条目字节）。若 v3 原样启动，会把 raw 2061（0x26，GPT entry 字节）
写成 0x00 并破坏 GPT entries CRC —— 属未授权闪存写 + 分区表完整性风险。

**修订 = lab v3.1（同内核、同 scanary、仅 init 三处）**：
1. TRY_A 自清改 **p1 offset 2061**，写前/写后打印 10 字节形（正确偏移、可复核）；
2. **窗末把 scanary 日志全文 `cat` 到 console + `busybox md5sum` + 行数/字节数**
   （除交互 shell 信道外的第二信道，彻底规避 C-187 的 `head -8` 缺陷）；
3. `alive_check` 改读 `/proc/<pid>/stat` 的 comm（原 cmdline 读法有 NUL 缺陷）。
判据、窗长、调用参数、scanary 二进制（md5 17376b74…）与内核 config 全部不变。

- v3.1 镜像：`boot-lab31-signed.img`，**md5 `9934cca26d2dda425eae406ca97fb865`**，
  33,554,432 B，mt2737/sec_level_0/hsm 测试密钥签名，cert1 嵌入 @0x9818112（校验 PASS）。
- 原 v3（217ccd57…）**不实机飞行**，仅留档。
- 本修订在**任何设备动作之前**写定并 commit；§1–§9 其余条款不变，§3 的镜像 md5 以本节为准。

## 10. 结果（执行后追加，2026-11-03 14:50）

### 10.1 刷写与 boot 证据

| 项 | 实测 |
|---|---|
| LK misc 实读（刷写前） | `0f 00 01 00 00 0e 00 01 00 00`（A.pri 15 / TRY_A 0 / B.pri 14 / TRY_B 0） |
| 镜像取件 | `/fhrom/bin/curl` 拉 `boot-lab31-signed.img`，md5 `9934cca26d2dda425eae406ca97fb865`（33,554,432 B）✓ |
| dd p25 + 读回 | `32+0 records`，读回 md5 == `9934cca2…` ✓ |
| lab v3.1 boot | `Linux (none) 6.18.44 #7`；BUILD_ID `labkernel-v3.1 … v2-fixes + TRY_A p1-offset fix + window-end log channel` |
| boot card | console PRESENT；13 个热区；`/dev/watchdog` PRESENT（10s 喂狗）；netup eth0/eth1 carrier=1 |
| TRY_A 自清（实弹） | before `0f 01 01 00 00 0e 00 01`（TRY_A=1，raw-shell boot 后）→ `TRYA_CLEARED: p1[2061] 0x01 -> 0x00` after `0f 00 01 00 00 0e 00 01` ✓ |
| alive_check（修复后） | 每拍 `vsurv4=1 scanary=1`（旧 cmdline 判据的假 0 已消失） |
| 热 | tmax 53.3°C → 39.3°C（13 区，无告警/关机） |

### 10.2 两窗（窗长均为 1800 s；同一 boot；scanary md5 17376b74… 与厂商臂同源）

| 窗 | 起（uptime） | EXIT（µs） | passes | appear | **inj=0** | inj=1 | probe_ok/bad | selftest_ok | rewrite/overflow/selfcrash | 日志 |
|---|---|---|---|---|---|---|---|---|---|---|
| W1（/init 自动） | ~1 s | 1,800,022,750（1800.023 s） | 138,598 | 19 | **0** | 19 | 14 / 0 | 1 | 0/0/0 | 88 行 / 49,641 B / md5 `b1220cdbcdfc25cc98ff3965098934ed` |
| W2（shell 手动） | 1927.67 s | 1,800,018,975（1800.019 s） | 136,921 | 19 | **0** | 19 | 14 / 0 | 1 | 0/0/0 | 88 行 / 49,643 B / md5 `f4b284cfa721f4b78a319ff586754c56` |

- 形式要件（§4-3）全满足：START 参数逐字、`EXIT reason=duration`、`selftest_ok=1`、
  `probe_bad=0`、`passes>0`、29 条 STAT/窗。
- 正对照（§4-4）全满足：`SELFTEST_OK t1_decoy/t2_stack` + 3 条 `SELFTEST_SKIP` +
  `SELFTEST_PASS` + 19 次 `HIT_APPEAR … inj=1` + 14 次 `PROBE ok=1`，均在日志内。
- 信道（§4）：窗1 由 `/init` 窗末 `cat` 全文到 console（49,641 B，`D28_W1_LOG_END` 在场）；
  窗2 由交互 shell `cat`/`tail`/`grep` 读取；两窗日志均 `cp` 到 p46 `/data/repro/d28/`，
  设备侧与 PC 侧 md5 逐字节一致（PC 以 `cat` 原样拉回复核，88 行、inj=0 计数 0）。
- **vsurv4 dump = 0**（/data/repro 仅 scanary 两日志，无 h5）；vsurv4 进程全程存活。
- 仪器旁证（诚实记录）：**busybox awk 在 lab 6.18 上任何调用都 SIGSEGV**（`awk "BEGIN{print 1}"`
  → RC=139；`awk /MemAvailable/ /proc/meminfo` → RC=139），故心跳 `MemAvail=` 恒空
  （与 v1/v2 已知"MemAvail 空"同源，v3.1 的 shell 把信号死亡行显示出来了）。这是**厂商
  busybox 与 6.18 的 userspace ABI 缺陷**，不是写入者活动：单进程、启动即崩、无外部输入；
  同一内核里静态 musl 的 scanary/vsurv4 全程正常。

### 10.3 回滚（软重启闭环，无第二次断电）

| 项 | 实测 |
|---|---|
| 原厂件 | p46 `/data/gw/logs/p25.boot.c2.img` md5 `209f481cf1bf489dc04ce1b12a9851f8`（PC 双备份同值） |
| dd p25 + 读回 | `32+0`，读回 md5 == `209f481c…` ✓ |
| TRY_A（p1 偏移） | before/after 均 `0f 00 01 00 00 0e 00 01 00 00`（已 0；写入为幂等） |
| p46 | `umount` RC=0（EXT4 clean unmount；此前 journal recovery 一次，属 `reboot -f` 未卸载所致） |
| 回笼 | `reboot -f` → 厂商 `5.15.134`，boot_id `b1ea64f3-ba10-448e-bca3-fd0baeaf2acc` |
| 终态 | p25 读回 `209f481c…`；misc `0f 00 … 0e 00 01`（TRY_A=0）；b4lab VARIANT=primary；dropbear×2/dnsmasq/hostapd×2/v3httpd/wan_agg/nerepair 全活；ra0+rai0 ESSID MyHome；br-lan 192.168.9.1/24；p26/p38/p39 未写 |
| 持久化 | `/data/repro/d28/scanary_c2_w{1,2}.log` + meta，md5 与设备/PC 三端一致 |

## 11. 判决（执行后追加）

**H 成立（厂商环境必要条件），H' 不成立。**

- 两窗合计 **3600.04 s** 有效暴露、`inj=0` 真命中 **0**；正对照/形式要件/信道三重齐备，
  C-187 的假阴性通道（`head -8` 快照、日志随 RAM 丢失、alive_check 假 0）已全部关闭：
  窗末全文上 console + 交互 shell 读文件 + p46 持久化 + 双端 md5。
- rule-of-three：0/3600 s ⇒ 95% 上界 **3/3600 s = 0.05/min**。厂商背景 0.36–0.60/min
  （C-199 0.60、C-196 0.167–0.20、C-204 热态更高）在 3600 s 内期望 22–36 条；
  若 lab 条件承载该背景，零结果的概率 e^-22…e^-36（≈3e-10…2e-16）⇒ **不是统计假阴性**。
- 结论口径：**32B 记录写入者的产生/触发需要厂商内核态环境**（厂商内建/厂商 .ko/CCCI-MD/
  其驱动供给的目标与载体）——厂商固件侧修补有理论依据；**不能**据此说"写入者是厂商代码"
  （§9-1/§9-2 共线混杂仍在：lab 无 WiFi/CCI/客户端/长驻厂商进程，目标页资格不可消除）。
- 若 H' 成立（lab 仍有写入）本应推翻厂商修补路线；实测未出现，故该兜底分支**不触发**。
- 级别：**E2**（有效窗 E3 级；归因受 §9 边界限制）。

**工程副产物（必须留档）**：
1. lab v3 的 A3 TRY_A 自清按裸设备 offset 2061 写，实测该字节是 GPT 条目字节（p1@2060 才是
   控制块）；原样飞行会破坏 GPT entries CRC。v3.1 改为 p1 偏移并实弹验证（0x01→0x00）。
2. v3.1 增加窗末日志全文上 console（C-187 信道修复的强制项）+ alive_check 改 `/proc/<pid>/stat` comm。
3. 仪器噪声：lab 6.18 上厂商 busybox awk 必崩（RC=139），心跳 MemAvail 空；判据未使用该字段。
