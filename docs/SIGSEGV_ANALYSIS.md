# logread SIGSEGV 家族：取证+逆向结论（2026-10-19 深夜轮）

> 本文是 [INCIDENT_2026-10-19.md](INCIDENT_2026-10-19.md) §2 的续篇与深度闭环：
> 对三份 logread core、libc.so、logread.bin 的完整逆向，加上设备侧补充取证。
> 取证脚本与产物在本地 `tmpfiles/sigsegv_re/`（不入仓）。

## 0. 摘要（因果链，按证据强度标注）

```
[实锤] logread 对 logd 记录流的"帧同步"仅凭属性长度字段自查（read_cb），
        无任何兜底校验
   → [实锤] 一旦错位，blobmsg_parse 的属性游走越出 16KB 输入缓冲，
        在相邻库映射里按名字"匹配"出伪属性（tb[] 里出现 libc/libubox 指针
        和裸整数 0x6ad527e0 —— 一个 2026-10-17 的 Unix 秒级时间戳）
   → [实锤] tb[TIME] 槽位拿到 msg 属性 → blobmsg_get_u64 把消息正文字节
        （"thermal_"）按 BE64 读出 → t = 巨大但在 musl localtime 接受范围内
   → [实锤] ctime(t) → asctime_r 的 snprintf(buf, 26, "%.3s %.3s%3d
        %.2d:%.2d:%.2d %d\n", ...) 年份溢出 26 字节（输出 30+ 字节）
   → [实锤] 厂商 musl 的受限输出 vfprintf 路径在此条件下破坏自身栈帧：
        活动 va_list 的 __stack/__gr_top/__vr_top 三个字段被垃圾小整数覆盖
        （gr_offs/vr_offs 幸存 = 前 5 个寄存器变参已正确弹出）
   → [实锤] 第 6 个变参从 va_list.__stack 弹出 → 解引用 0x2475b 级别的
        小整数野指针 → SIGSEGV（libc+0x51ffc，pop_arg 序列）
```

一句话：**logread 的记录帧同步缺陷产出垃圾数据，厂商 musl libc 的
printf 受限输出路径吞下垃圾后破坏自己的栈，任何走到这条 libc 路径的
进程都会随机崩。** watchdog 拉起只是止痛；根治必须同时消除
"数据生产端缺陷"（换采集器）与"libc 暴露面"（自建静态工具）。

## 1. 三份 core 的统一签名

| 项 | core_27987 | core_3053 | core_15875 |
|---|---|---|---|
| 崩溃点 | libc+0x51ffc `ldr x0,[x3]`（同） | 同 | 同 |
| si_addr = x3 | 0x2475b | 0x25746 | 0x14f1b |
| x0 | 0x24768 | 0x25750 | 0x14f28 |
| x5 / x7（printf 内部常量） | 0x0ccccccc / -10 | 同 | 同 |
| 活动格式串（x26/x4） | logread+0x3d0e `"%s %s%s.%s%s %s\n"` | libc+0x7a068 `"%.3s %.3s%3d %.2d:%.2d:%.2d %d\n"` | 同左 |
| 活动调用链 | print_log 自己的 6 变参 snprintf（0x40395c，第 6 变参=消息体，走栈传参） | print_log→ctime(0x403590)→asctime_r→snprintf（第 6 变参=秒，走栈传参） | 同左 |

同一根因、两个爆发点；两者都在**弹出到第 6 个（第一个栈传递的）变参**时死亡。

### va_list 污染（决定性证据）

vfprintf 序言把 va_list 拷到自身帧（`stp q0,q1,[x20]`，x20=sp+0x58）。
三份 core 中该 32 字节结构统一为：

```
__stack = 0x24768/0x25750/0x14f28   ← 垃圾小整数（≈85KB~153KB，每次不同=数据相关）
__gr_top = 0x0                       ← 正常应为栈地址！
__vr_top = {u32≈0x62d, 随机32位}
__gr_offs = 0    __vr_offs = 0       ← 幸存（与"已弹 5 个寄存器变参"一致）
```

`__gr_offs=0` 证明前 5 个变参弹出时 va_list 仍然健康 → 污染发生在
printf 处理过程中（第 5 弹与第 6 弹之间的输出窗口，即 asctime 格式里
`%.2d` 分钟 + `":"` 的输出期间）。**写入者指令未最终定位**（见 §5），
但污染本身、时间窗口、数据相关性均已实锤。

## 2. logread 侧缺陷（反汇编锚点）

二进制：`/sbin/logread`（md5 6e6b5a7d…，本地 tmpfiles/logread.bin）。

### 2.1 记录流格式（从 core 内存实测解码）

logd→logread 的 ubus fd 流是**平铺的命名 blobmsg 属性序列**，无外层
wrapper；每条记录 5 个属性，实测热记录（thermal_core）步进 0xa0：

```
[84 00 00 14 | 0004 "time" | BE64 毫秒时间戳]
[83 00 00 4f | 0003 "msg"  | "thermal_core[8358]: interval=5 temp: …\0"]
[85 00 00 10 | 0002 "id"   | BE64 流水号]
[85 00 00 14 | 0008 "priority" | BE32 (如 0x1e=daemon.info)]
[85 00 00 14 | 0006 "source"   | BE64]
```

属性头 BE32 = (标记/类型字节<<24) | 总长（含 4 字节头），步进按
`(len+1)&~1` 对齐。

### 2.2 read_cb（0x4039a0）——帧同步的全部逻辑

```
循环 { a, avail = ustream_get_read_buf(s)
       if (avail <= 3) 等数据
       w20 = (be32[a] & 0xffffff) - 4 + 4     # 0x40293c：纯信任长度字段
       if (avail < w20) 等数据
       print_log(a)                            # 0x403390
       ustream_consume(s, w20) }
```

**没有任何跨属性一致性校验**：不核对 5 属性齐全、不核对类型、不核对
游走是否越界。长度字段一旦被错位数据污染（边界截断/半包恰好凑满
`avail`），后续所有记录的帧同步整体漂移。

### 2.3 print_log（0x403390）——零防御的消费者

```
blobmsg_parse(policy×5, tb@sp+0x70, a+4, len(a)-4)   # 0x401bb0 (libubox)
5 槽位仅查非空，无类型/范围校验
w22 = blobmsg_get_u32(tb[2])        # priority
pid  = blobmsg_get_u32(tb[3])       # id
t    = blobmsg_get_u64(tb[4]) / 1000 # time  ← 错位时把消息正文当时间戳
x24  = ctime(&t)；strlen(x24)；去尾换行
… snprintf(buf@sp+0x378, 0x480, "%s %s%s.%s%s %s\n", x24, …) (0x40395c)
```

### 2.4 core 中的错位现场（core_3053 实测）

```
tb[0]=0x7facd21d8c (libc 代码区)     tb[3]=0x6ad527e0 (未映射裸整数!)
tb[1]=0x7facc20a4c (库间区域)        tb[4]=0x7facbe84bc (记录缓冲内 msg 属性头)
tb[2]=0x7facc7fc30 (libubox 区)
```

16KB 输入缓冲位于 0x7facbe8000；tb[0..2] 指向**缓冲末尾之外 50KB+**
的相邻映射——blobmsg_parse 的游走已越出输入窗口，在别人的内存里
按名字匹配。`get_u32(tb[2])` 恰好落在已映射页所以没有立即崩；
`get_u64(tb[4])` 读出 "thermal_" 字节序 → t=8.36e15 → 崩溃链启动。

## 3. 厂商 musl（/lib/libc.so, md5 见归档）侧事实

- `ctime`(0x5d794)：`localtime(t) ? asctime_r(tm, 静态buf26) : NULL`。
- `asctime_r`(0x5d460)：标准 musl `snprintf(buf,26,"%.3s %.3s%3d %.2d:%.2d:%.2d %d\n", …)`。
  年份 6~9 位时输出 30+ 字节 > 26 → 进入受限输出的溢出处理路径。
- 崩溃点 `libc+0x51ffc` 位于 pop_arg 变参取出跳转表（0x51e80 派发，
  8 字节整数/指针条目）：`x3 = __gr_top+__gr_offs`（寄存器区耗尽后
  改用 `__stack + 对齐修正`）→ 解引用。
- `vsnprintf`(0x56004)：FILE 结构与 {p,n} cookie 都在栈帧内；
  write 回调 `0x55f3c` 的两段 memcpy 均有界，末尾 `*p=0` 并把
  wpos/wbase 重置回 f->buf。
- **已证缺陷**：受限输出溢出时（本例 asctime 26 字节限幅 + 30 字节
  输出），vfprintf 活动帧内的 va_list 被垃圾覆盖（§1）。
- **同仓疑点**（未证与本次相关，但同属无界索引）：printf_core 的
  位置参数路径 `0x53368/0x53374` 对 `%N$` 的 N 无 NL_ARGMAX 上限检查
  （上游 musl 1.1.24 修复过同类 OOB）。本次格式串不含位置参数，
  非触发路径。
- 对照实验（设备实测）：busybox `date -d @<极端时间戳>` 全部正常
  （±2^48 范围内格式化不崩）——busybox 走 strftime 自有路径，
  不经过 asctime 的 26 字节受限 snprintf。**崩溃链特定于
  "受限 snprintf + 溢出输出"组合**，不是"任意大时间戳皆崩"。

## 4. 家族现状（清环后仍未根除的部分）

清环（17:32）后 logread 本体零复发（最后一条 logread NE=17:01），
但 aee `db_history` 持续出现新 NE，全部是**不同 busybox applet /
动态链接工具**：

| 时间 | 进程 | 说明 |
|---|---|---|
| 18:34:35 | grep | 读 4MB 日志（log_keeper 滤波路径） |
| 18:55:48 | awk | log_keeper 锚定抽取路径 |
| 19:07:28 | sh | 脚本本体 |
| 19:30:04 | ip | wan_agg 型管线的 `ip -o -4 addr` |

公共分母实测：`/bin/busybox`、`/usr/libexec/ip-full`、`/sbin/logd`、
`/sbin/logread` 的 ELF interpreter 全部是 `/lib/ld-musl-aarch64.so.1`
（同一厂商 musl）。二进制已拉回本地归档（md5 校验通过）。

- 崩溃时刻与蜂窝拨号风暴（mipc_cli 连发、ccmni 翻动）和 WiFi 搬道
  风暴（hostapd channel switch 连发）时段吻合——即 wan_agg 型管线
  高频 spawn ip/grep/awk 的时段。
- 受控复现（4 分钟、2990 轮 grep -cE/awk 锚定抽取/logread/sh -c true，
  合计 ~1.2 万次进程生成，core_pattern=/tmp/core.%p）：**零命中**。
  → 家族崩溃是**条件触发**（特定输入/时机），不是每次 exec 的均匀概率。
- 家族成员的内核 DABT 行已被 printk 限流吞掉（dmesg 镜像 18:14 后
  无新增 unhandled exception 行），拿不到故障 PC；core 未捕获。
- **监控缺口**：watchdog v1.20 的 fault 计数依赖内核 DABT 行，
  限流后 `/tmp/watchdog_faultcount=0` 而 aee 仍在记录 NE ——
  fault 计数存在低估，判据需要换 aee db_history 增量。
- aee 转储器自身会 spawn ps/df/ip/awk/logread（既有档案），存在
  放大回路；根治 logread 即掐断最大放大源。

## 5. 官方固件对比：缺陷在场，但官方几乎不发病

**问题**：崩溃全部发生在保留下来的官方组件里——纯官方固件也会崩吗？

**结论**：缺陷集合 100% 在官方（musl/logread/logd/busybox/ip-full 均为
未改动过的厂商二进制），但**官方出厂配置下 logread 的触发路径基本
不存在**，家族成员的执行密度也低几个数量级。官方的"稳定"是曝光率
≈0 的稳定，不是机制稳定；我们打破的是曝光平衡，不是拆除了某种防御。

### 5.1 证据

1. **官方本来就不跑常驻 logread**：`/etc/init.d/log`（procd 服务）
   按 `ap_auto_logging` 决定是否启动 `logread -f -F <log_file>` 落盘
   守护；当前配置 `ap_auto_logging '0'` → 该实例从不启动。
   `/data/debuglog/`（官方落盘目录）自厂商镜像日期（09-09）起
   **从未被写入过** ——官方时代没有任何日志落盘行为。
2. **官方时代零崩溃记录**：aee `db_history` 为追加式（171 行无回卷），
   首条为我方固件上线后第一小时（10-05 20:28，mipc_wan_cli）。
   官方时代约 4 周运行、零 NE 记录。
3. **环配置是官方原配**：`log_size 10240`（KiB）→ `logd -S 10240`
   = 10MB RAM 环，非我方放大；官方无 cron、无任何环清理/轮转机制
   被我们移除（官方的"清理"就是无人读取、自然回卷）。

### 5.2 我们打破平衡的三个杠杆（按贡献排序）

1. **读环频率**：官方的 reader 仅剩 GUI 日志页（手动、极少）与
   aee 转储器（崩溃时才跑）；我们的 log_keeper 每轮全量读环——
   毒记录驻留期间每次读取都是一次掷骰。
2. **工具执行密度**：30s 级守护舰队（wan_agg/dial_keeper/watchdog/
   log_keeper）让 ip/grep/awk/sh 的 spawn 频率比官方高几个数量级，
   给家族的条件触发提供了样本量。
3. **环内容构成**：我方守护的消息量（mipc_cli 拨号日志、守护自身
   输出）与开机记录序列与官方不同。错帧种子未定位（§6-3），不能
   断言种子是否我方独有——但官方即使有种子，也无人去读。

### 5.3 推论

- 反向预测可证伪：B 槽官方镜像下循环跑 `logread`，预期同样会崩
  （缺陷在场）；而官方正常使用下几乎不崩（曝光≈0）。
- **运营红线**：`ap_auto_logging` 不得置 1——那会点亮官方
  `logread -f` 常驻路径，立即成为崩溃源 + aee 放大器。P1 采集器
  上线后应成为全机唯一 reader，并将该开关纳入 manifest 护栏。
- 官方对比同时反证了根治方向的正确性：我们不需要"恢复官方的
  平衡"，而是要消除曝光（P1/P2），落成后稳定性优于官方。

## 6. 未闭环问题（诚实清单）

1. **libc 写入者指令未定位**：污染窗口已收窄到"第 5/第 6 变参弹出
   之间的输出路径"，sn_write 本身有界；剩余嫌疑在 vfprintf 内部
   缓冲/受限 FILE 的交互（及 pop_arg 的输出槽写入 `str x0,[x19]`）。
   需要一次带调试器的复现或更长的 trap 窗口。
2. **家族成员的触发输入未捕获**：需要家族 core（见 §7 P3）。
3. **帧同步最初如何错位**（哪个边界条件种下第一个坏长度）：环已清、
   输入缓冲现场只在 core 尾部 64KB 里有截断证据；受控重启+全环抓取
   +回放二分仍是定位"第一条坏记录"的路径（INCIDENT §2.6-1）。
4. logread 自身 text 段崩溃那一次（1/15）未拿到 core。

## 7. 根治方案（分阶段）

### P1 — 自建静态日志采集器（根治 logread 主链路 + 掐断 aee 放大源）

> **已落地**（`gw/src/logc.c` → `gw/bin/logc` v1.0，静态 95KB；log_keeper v1.8 /
> diag_dump v1.2 已切换）。执行与验证见 §9。

用 zig `aarch64-linux-musl` 静态构建（先例：mipc_cellular v12 静态版），
走同一 ubus fd 流，但：

- 帧解析带**全套校验**：长度字段上界（≤缓冲剩余）、属性类型白名单、
  5 属性齐全才输出、游走指针必须落在 `[buf, buf+len)` 闭区间；
  任何违规 → 丢弃当前帧 + **全量重同步**（丢弃至下一个可识别的
  `time` 属性头）+ 计数器告警（喂 watchdog）。
- 时间戳解码后做**范围断言**（epoch 合理区间），越界即丢帧计数。
- 输出格式与 logread 兼容（GUI 日志页/log_keeper 锚行无感切换）。
- 静态链接 = 与厂商 musl 零耦合 = 本条崩溃路径物理消失。

### P2 — 守护脚本工具链静态化（根治家族的暴露面）

> **已落地**（`gw/bin/busybox` 1.36.1-r31 + `gw/bin/ip` 6.3.0 静态；
> `gw/toolchain_init.sh` 建 `/data/gw/sbin` 农场，rc.extend v2.3 前置 PATH；
> 已观测到全部常驻守护的 `/proc/<pid>/exe` = 静态 busybox）。执行与验证见 §9。

busybox（grep/awk/sh…）与 ip-full 全部动态链厂商 musl。构建静态
busybox（zig/自有 musl，defconfig+所需 applet）与静态 ip 子集，
放 `/data/gw/bin/` 并在守护脚本 PATH 前置。脚本零改动；
selftest 增加静态工具存在性与行为等价校验。分批灰度：
先 wan_agg/dial_keeper（崩溃热点），再 watchdog/log_keeper。

### P3 — 家族 core 捕获 trap（闭环 §5-2）

> **已落地**（`gw/core_trap.sh` v1.0，每日 03:20 起 600s；rc.extend 抬
> RLIMIT_CORE=unlimited；watchdog v1.24 自愈）。窗口机制已用静态 crashme
> 实测抓取并归档到 `/data/gw/logs/cores/20261019/core.8220`。见 §9。

低频窗口方案：每日一个 10 分钟窗口把 core_pattern 切到
`/tmp/core.%p`（ulimit 配套），窗口结束由 log_keeper 附带把
`/tmp/core.*` 搬 `/data/gw/logs/cores/` 并恢复 aee 管道；
拿到家族 core 后按本文件 §1 的方法提取 libc 偏移对齐验证同源性。

### P4 — 判据与监控修正

> **已落地**（watchdog v1.24：dmesg 行增量 + `aee db_history` 行增量双判据；
> 实测 20:47:01 / 20:53:48 两条 `WARN aee NE +1`，含进程名/信号/时间原文）。

- watchdog fault 判据从"dmesg 行增量"改为/加上"aee db_history
  行数增量"（用 stat mtime+行数，避免读内容）。
- 保留：开机清环（log_keeper v1.7）、watchdog 自愈、fault 计数。

### 部署纪律

P1/P2 均为 `gw/` 新资产：二进制入 `gw/bin/`、源码入 `gw/src/`，
VERSIONS.tsv 登记并 bump；设备推送走 deploy.py（push/put），
P2 的 PATH 切换经 manifest 灰度，上线后冷启动验证。

## 8. 取证资产索引（本地 tmpfiles/，不入仓）

- `core_27987/3053/15875.bin`：三份 logread core（本文 §1/§2 依据）；
- `libc.so`、`logread.bin`：反汇编正本；
- `sigsegv_re/core_an.py`：core 解析器（PRSTATUS/SIGINFO/NT_FILE/内存）；
- `sigsegv_re/disx.py`：capstone 反汇编器（PLT 符号+字符串标注）；
- `sigsegv_re/stress_family.py`：家族受控复现驱动（含 core_pattern
  备份恢复；注意首次运行失败会残留 /tmp/core.%p，需手动恢复 aee）;
- `sigsegv_re/busybox.bin / ip-full.bin / logd.bin / libubox.so`：
  家族二进制归档（md5 与设备一致，2026-10-19 拉取）。

## 9. 根治方案执行记录（2026-10-19 晚轮，P1–P4 全部落地）

> 本轮把 §7 的方案完整实施并做设备侧验证。全部变更在公开仓：
> `6bf5cfa`(P1–P4 主体) → `1fdaa33`(单实例锁加固) → `2ff1a41`(启动日志版本)
> → `49db88a`(watchdog spawn 自锁死循环) → `a81557c`/`8f7374e`/`0bbf81e`
> (TZ/启动宽限/PATH 幂等)。版本注册表与 ARCHITECTURE.md 已同步（113 个登记
> 文件 / MANIFEST 65 项，vercheck 全绿）。

### 9.1 变更清单

| 阶段 | 资产 | 版本 | 设备路径 |
|---|---|---|---|
| P1 | `gw/src/logc.c` → `gw/bin/logc` | 1.0 | `/data/gw/bin/logc` |
| P1 | `gw/log_keeper.sh`（改用 logc） | 1.8 | `/data/gw/log_keeper.sh` |
| P1 | `gw/diag_dump.sh`（改用 logc） | 1.2 | `/data/gw/diag_dump.sh` |
| P2 | `gw/bin/busybox`（静态 1.36.1-r31） | 1.0 | `/data/gw/bin/busybox` |
| P2 | `gw/bin/ip`（静态 iproute2 6.3.0） | 1.0 | `/data/gw/bin/ip` |
| P2 | `gw/toolchain_init.sh`（符号链接农场） | 1.0 | `/data/gw/toolchain_init.sh` |
| P2/P3 | `gw/rc.extend.sh`（PATH/TZ/RLIMIT_CORE） | 2.5 | `/data/rc.extend.sh` |
| P3 | `gw/core_trap.sh`（每日 core 窗口） | 1.0 | `/data/gw/core_trap.sh` |
| P4 | `gw/watchdog.sh`（aee 增量+core_trap 自愈+启动宽限） | 1.25 | `/data/gw/watchdog.sh` |
| 构建 | `tools/build_logc.sh` / `tools/build_static_ip.sh` / `tools/fetch_static_busybox.sh` | 1.0 | PC 侧 |

P2 的 busybox 与厂商同为 **1.36.1**（Alpine `busybox-static-1.36.1-r31`，
SHA-256 钉死在拉取脚本里，305 个 applet）；ip 用 **iproute2 6.3.0**（与厂商
`ip -V` 同版本）以 zig cc/musl 重建，避免 busybox ip 的输出空格差异与
`link add ... type bridge` 缺失。两者均为 GPLv2（busybox）/GPLv2（iproute2），
源码/包 URL 与校验值在构建脚本内。

### 9.2 P1 验证（logc）

- **合成恶意流**：9 条合法记录 + 垃圾插段/越界长度/错误类型/1970 前垃圾/
  msg 内嵌 NUL 混合。输出恰为 9 条合法记录；坏帧计数与重同步计数逐项对上，
  进程零崩溃（`--stdin` 离线模式）。
- **真实环**：`logc --stats-file` 读全环 `frames=694 bad_frames=0 resyncs=0
  dropped=0 bad_time=0 bad_attrs=0`；与厂商 logread 同窗口 `-l 3` 输出
  **逐字节 diff 相同**。
- **稳定性**：220 次 `-l 200` + 20 次全环读取 0 失败；期间 aee `db_history`
  零新增。清环后 logread 的 1% 崩溃率对 logc 不再适用（无 ctime/asctime_r 调用）。
- **接线**：log_keeper/diag_dump 的厂商 logread 调用归零（selftest 断言
  `^LOGC=/data/gw/bin/logc` 且无 `logread ` 行）；logd 清环保留，理由仅为
  aee 转储器内置的厂商 logread 无法替换。

### 9.3 P2 验证（静态工具链）

- `/data/gw/sbin` 农场 305 个 applet；`sh/grep/awk/sed/ip/...` 均解析到静态件。
- 常驻守护 `watchdog / led_mgr / dial_keeper / log_keeper / core_trap /
  wan_agg / wan_eth` 的 `/proc/<pid>/exe` **全部** = `/data/gw/bin/busybox`；
  其 environ 为 `PATH=/data/gw/sbin:/data/gw/bin:...`、`TZ=CST-8`。
- `ip` 输出与厂商逐字节一致：`-o -4 addr` / `rule show` / `-6 rule show` /
  `route show default` / `-6 route show default` / `link show br-lan`；另实测
  `ip link add <x> type bridge` + `link del` 成功。
- 静态 busybox `sh -n` 语法检查全部 gw 脚本通过；awk/grep -Fqx/sed/tail/wc/
  date（带 TZ）抽样与厂商行为一致。
- 冷启动竞态修复：首个冷启动发现 watchdog 在 rc19 拉起 wan_agg 之前抢跑，
  产生两个 `sh wan_agg.sh`；v1.25 加 180s 宽限（只记 SKIP 不算失败），
  第三次冷启动实测 `wagg=1`。

### 9.4 P3 验证（core 窗口）

- 用 `CORETRAP_START=<now> CORETRAP_SECS=120` 模拟窗口：`core_pattern` 切为
  `/tmp/core.%p`；静态 crashme 触发 SIGSEGV，产生 `core.159744B`；
  窗口关闭后自动搬至 `/data/gw/logs/cores/20261019/core.8220`，`core_pattern`
  恢复 aee 管道，日志记录 `aee_lines=173->173`。
- 冷启动后 core_trap 常驻（watchdog 自愈），守护侧 `Max core file size =
  unlimited`；正常态 `core_pattern` 保持 aee。
- 真实家族 core 的捕获要等每日 03:20–03:30 窗口（首个窗口在本轮之后）。

### 9.5 P4 验证（aee 增量判据）

- 20:47:01 `WARN aee NE +1 (total 174): db.05.NE ... SIGSEGV,awk`；
  20:53:48 `WARN aee NE +1 (total 175): db.01.NE ... SIGSEGV,ip`。
  两条与 `db_history` 增量、`ZZ_INTERNAL` 进程名/信号/时间**一致**；同期
  dmesg 的 `unhandled exception` 行已被 printk 限流（0 行），证明单靠 dmesg
  确实会低估。
- 三次冷启动 aee 行数保持 175 不变（开机噪声不误报）。

### 9.6 冷启动验证（boot_id `5eabd07c-…`）

- `TRY_A=0f 00`（A 槽优先、TRY 已清零），`boot.done` 在位，slot=a。
- `toolchain_init` 农场在 21:27:44（**本地时区**）就绪；全部守护静态。
- 恰一个 `wan_agg`；`SKIP wan_agg recovery (boot in progress)` 为 v1.25
  宽限生效的直接证据。
- `logc.stats` 读取 694 帧零异常；`dmesg | grep -c 'unhandled exception'` = 0。
- **全量 selftest：87 pass / 0 fail**（system 23/23 含 4 个新护栏）。
- 冷启动后 21:33:55 新增一条 `netstat` NE，定位为**本机 selftest 经 SSH 执行的
  厂商 netstat**（selftest 的 `dev("netstat -tln ...")` 走 SSH 默认 PATH，不在
  守护树内）；随后 200 次静态 `netstat` + 100 次厂商 `netstat` 均无复发。
  守护树内 `netstat` 已解析为 `/data/gw/sbin/netstat` → 静态 busybox。

### 9.7 残余风险与运维约定

1. **aee 仍用厂商 logread**：logd 清环（uptime>=300s 一次）继续保留；ring
   含开机记录时 aee 转储仍有崩溃可能，但次数已从"每次读环"降到"崩溃转储时"。
2. **静态工具链只覆盖守护树**：手工 SSH 登录后默认仍是厂商 PATH/工具；需要
   静态工具时用 `PATH=/data/gw/sbin:/data/gw/bin:$PATH` 或直接绝对路径。
   若 busybox 缺失/损坏，`toolchain_init` 会移除农场并回退厂商工具（fail-open，
   不锁死设备）。冷启动验证中唯一一条新 NE（netstat）就是本机 selftest 经 SSH
   调用厂商工具产生的，印证了"守护树已隔离、PC/手工侧仍是旧暴露面"的边界。
3. **core 窗口**：每日 03:20 起 10 分钟；`/tmp` >80% 提前关闭；核心落
   `/data/gw/logs/cores/YYYYMMDD/`，每日目录只留最新 20 个；同时段
   `core_pattern` 从 aee 切走，属于已知取舍（窗口短、有 watchdog 恢复）。
4. **`ap_auto_logging` 必须保持 0**（§5.3 红线）：否则官方 `logread -f`
   常驻路径重新点亮，回到旧暴露面。
5. **P3 真实 core 回收**：需要下一个 03:20 窗口后按 §1 方法解析
   `/data/gw/logs/cores/`，确认家族 core 与 logread core 同源（libc+0x51ffc
   或其它触发点），再决定是否扩大窗口/频率。
