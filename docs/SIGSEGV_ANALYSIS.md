# logread SIGSEGV 家族：取证+逆向结论（2026-10-19 深夜轮）

> 本文是 [INCIDENT_2026-10-19.md](INCIDENT_2026-10-19.md) §2 的续篇与深度闭环：
> 对三份 logread core、libc.so、logread.bin 的完整逆向，加上设备侧补充取证。
> 取证脚本与产物在本地 `tmpfiles/sigsegv_re/`（不入仓）。

## 0. 摘要（2026-10-19 现场推理链 · **历史摘要**）

> 本节是 2026-10-19 当天的推理链，保留以记录过程。其中两处已被后续实验推翻：
> ① "破坏需要垃圾数据/年份溢出作为前提" —— 最小复现器在**没有任何垃圾数据**时
> 也 2 秒必崩（§12.4）；② "va_list 三个字段被垃圾小整数覆盖"的机制细节已由 §13
> 的 16 字节零块实测取代。**现行结论以 §0.5 总表为准**，本节仅作历史。

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

## 0.5 速查：机制总表与引用规则（**唯一事实源**）

> **文档定位（2026-10-22 收关确立）**
> 1. 本文件是"崩溃/SIGSEGV 机制"的**唯一事实源**：机制、判据、速率、证据锚点只在这里写。
> 2. 其他文档（事故留档、稳定性分析、方案可行性、FINDINGS、ARCHITECTURE 版本表）
>    只写"发生了什么/做了什么/为什么有这个版本"，机制一律**引用本文**，不再复述。
> 3. 历史文档里旧的机制描述已在本轮删除；**git 历史中的旧结论不是现行结论**
>    （见本节"已更正的旧结论"）。改动机制时只改本文件。

### 机制总表（一页版，2026-10-22 收官轮改写）

> **2026-10-22 反转**：此前归为"A 类 = musl printf/stdio va_list 缺陷"的定性已被推翻
> （§16）：musl 与全部被替换组件都是**无辜受害者**。全家族（含原 B/C/D 类）的
> 共同根因是**外部主控把 16/32 字节记录写进被回收复用进用户进程的物理页**；
> printf 家族只是"最高频解引用被污染内存的路径"，因而成为最常见的爆发点。

| 类 | 机制（一句话） | 状态 | 速率/量级 | 锚点 |
|---|---|---|---|---|
| **主机制（合并原 A/B/C）** | 外部主控（蜂窝 MD/ccci-dpmaif 环，含 medmcu）经失效环形缓冲指针，把 16/32B `{计数器,0[,0x680族,0]}` 环记录写进**被回收复用进用户进程的物理页**；受害者按被击中数据的形状表现出 va_list 崩溃 / NULL 解引用 / .bss 指针损坏等不同签名 | **二进制定罪 + 活体捕获完成**（§17：内核反汇编常数直接对上坏值构成 + pageharvest 当场捕获写入与流量突发同窗） | 剧集期：pfcanary ≤2s 必崩；平静期：0；产品面 47→28 次/天 | §16、§17 |
| ↳ 原 A（logread/logc/sh/grep/pidof/ls/ping/wc/sed…） | 同主机制；musl `pop_arg` 是最高频的污染内存解引用点 → 选集效应让它"看起来"是 libc 缺陷 | 机制已反转；热路径缓解（logc v1.4/logcut/procmatch 去 printf 化）有效保留 | ≈40 次/天（选集效应，非成因） | §16.4 |
| ↳ 原 B（awk） | 同主机制（NULL 块击中节点指针即可解释）；"busybox awk 数组退出缺陷"**不再必要**且未被独立证明 | 并入主机制；logcut 缓解有效 | 修前 18.4/天 → 0 | §11、§16.3 |
| ↳ 原 C（ip `filter.label`） | 同主机制：`.bss` 一页内 5 个 16B 块以 16 字节节距喷射（flags/label/flushb/slave_kind…），label 恰好被解引用 | **已闭环并入主机制**（core_ip.core 整页实测） | 11.6/天 | §11.7、§16.3 |
| **D. hostapd/logd/thermal_core（厂商件）** | 同主机制的长期受害者（剧集期新分配页被注入）；不可重编，只能靠根修（§16.6 选项 B/C 才能覆盖它们） | 归并；根修前靠恢复 | 1.4/天 + 零星 | §16.6 |
| **E. `?` 组** | **不是崩溃**：core_meta 的手工/测试调用 | 排除 | — | §12.1 |
| 背景率 | 与程序无关的随机崩溃**不存在**；固定地址观测在平静期恒为 0 | 已证伪（30 万金丝雀 + §16.1 memtruth 电池） | — | §12.2、§16.1 |
| 普查口径 | 家族计数会被取证自身污染（探针/复现也算） | 判读时须扣除 | — | §13.6、§14 |

### 判据（照抄使用，别自己发明）

- va_list **是否健康**看结构：四个字段都落在用户态可访问范围、两个 `*_offs` 为负。
- **禁止用"magic 值指纹"**：`__vr_top = 0x1c28416e00000680` 之类并非指纹
  （高 32 位是循环计数器形态的值，且会出现在任意偏移）。理由与数据见 §13.2 第 10 条。
- 崩溃速率必须**同时**给出分子分母（命中/调用或 次/天 + 窗口），否则不可比。

### 已更正的旧结论（勿再引用）

| 旧结论 | 出处 | 现状 |
|---|---|---|
| **崩溃家族 = musl printf/stdio 的 va_list 缺陷**（本轮最大反转） | §0 旧摘要、§12.5/§12.6、L31/L33 | **被 §16 推翻**：坏值由外部主控注入回收页，musl 只是最高频的受害解引用路径；"改 musl / 重编工具链治崩溃"路线作废 |
| logread 崩溃根因 = 厂商 syslog 管线在**开机期记录流**上的缓冲区边界缺陷 | INCIDENT_2026-10-19 §2.4（2026-10-19 现场研判） | **被取代**：主机制注入（§16）；回放 10/10 不复现、清环只改变调用频率的旧证据与此一致 |
| busybox awk "数组退出清理 NULL 缺陷"是独立根因 | §11.3–§11.5 | **降级为未证实且不再必要**：主机制的 {0,0} 块击中节点指针同样解释 core 现场；受控复现是在污染剧集期内做的，无法区分两种解释 |
| `__vr_top = 0x1c28416e00000680` 是循环计数器形态、非指纹 | §13.2 第 10 条 | 部分保留、语义更新：它是**注入源的准静态 64 位值**，跨进程/跨编译器/跨重启重复出现（§16.2-E1）——恰恰因此它是主机制的最强单一证据 |
| 改 `vfprintf.c` 的**逻辑**即可修 | §12.7（10 次尝试） | 仍成立（坏值进入 vfprintf 前已在），但"修谁"变了：要修的是页回收链（§16.6），不是任何 printf 代码 |
| logc 崩溃与 logread 无关可分开处理 | 早期分析 | 同一主机制；logc v1.4 去 Printf 化作为缓解有效保留 |


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

## 10. 2026-10-21 回合：logc 崩溃根因定位 + v1.4（printf-free 记录路径）

> 本轮目标：把 `logc` 的持续 SIGSEGV（不是厂商组件，是我们自己的静态采集器）定位到
> 具体指令与调用链，并给出可验证的修复。证据在本地 `tmpfiles/round_logc/`
> （面包屑归档 `evidence/`、崩溃原始流 `crash.raw`、gdb 现场 `crash.72.log`）。

### 10.1 现场规模（先看数，不看猜）

- `/data/gw/logs/logc_crash/` 132 份面包屑 = **109 次不同崩溃**（其余为 log_keeper
  在 rc!=0 时重复复制同一份 `/tmp/logc.crash`，属取证噪声）；全部 `sig=11`，
  版本 v1.2×2 + v1.3×107，跨 2026-10-20 00:21 → 10-21 19:45。
- 崩溃点分布：`buf_len` 几乎恒在 **65536–66336**（一次 read 刚灌入的 ~64KB 块），
  `frame_off` 0x0d4–0xf8b8、`frame_len` 116–800，`frames_emitted` 54–37887。
  格式全部合法（同一批运行 `bad_frames=0 resyncs=0`）——**不是帧解析越界**。
- 同期 `ne_events.tsv`（core_meta 抓到 core 的进程）：static busybox（awk/pidof/
  sh/ping/grep）44、static ip 17、wpad 2、xtables 1、logread 1 —— 静态工具链也在崩，
  但 logc 是频率最高的一条（约 7 次/小时）。

### 10.2 取证方法（可复用的两条）

1. **gdb 在设备上直接抓现场**：设备自带 `/usr/bin/gdb 12.1`。构建**同源码同优化**
   的带符号静态件（`zig cc -O2 -g -static`，不 strip），用
   `gdb -batch -ex 'handle SIGSEGV stop print nopass' -ex run -ex 'bt full' ...`
   跑 one-shot 环读；崩溃时 gdb 在 logc 自己的 handler 之前截住信号，拿到
   PC/寄存器/va_list/各层栈帧。
2. **`--dump-raw` 留输入**：崩溃那轮的原始流落盘，可 `--stdin` 离线回放。
   本轮实测：回放**不复现**（10/10 rc=0）→ 触发依赖运行期状态而非单纯字节内容，
   这条结论本身排除了"某条坏记录"的假设。

复现率（同一二进制、同机、稳态环）：约 **1/220 ~ 1/600** 次 one-shot 全环读取；
开机环（含 dmesg 引导记录）明显更高（一次 72 轮即命中）。

### 10.3 崩溃现场（决定性证据）

`crash.72.log`（`frames_emitted=1816`，记录是普通内核引导行）：

```
Program received signal SIGSEGV
0x10254d0 in printf_core (f=..., fmt="%0*lld", ap=..., nl_arg=..., nl_type=...)
  at .../musl/src/stdio/vfprintf.c:485
#1 vfprintf      (fmt=0x10006e0 "%0*lld")
#2 vsnprintf
#3 snprintf      (s=..., n=...)
#4 __strftime_fmt_1 (f=83 'S')
#5 __strftime_l  ("S %Y" 剩余格式)
#6 emit_record   (logc.c: strftime(...))
```

故障指令（`printf_core+892`，即 `w = va_arg(*ap, int)` 的寄存器区取值路径）：

```
ldr  x9, [x12, #0x18]   ; x9 = ap->__gr_offs = -40
...
ldr  x11, [x12, #8]     ; x11 = ap->__gr_top  = 0        ← 坏值
add  x9, x11, x9        ; x9 = -40
ldr  w26, [x9]          ; SIGSEGV, si_addr = 0xffffffffffffffd8
```

崩溃时 vfprintf 帧内的 `ap2`（`va_copy` 的结果）：

```
__stack  = 0x1c28416e00000680   ← 垃圾
__gr_top = 0x0                  ← 垃圾（应为调用方保存区地址）
__vr_top = 0x7fe09feae0         ← 正常
__gr_offs = -40, __vr_offs = -128  ← 正常（尚未弹过变参）
```

**与厂商 musl 的旧签名同源**（§1：`__stack` 垃圾 + `__gr_top=0`，偏移字段幸存）。
区别只是本次发生在 zig/Alpine 同源的 musl 1.2.x 上、且在弹出**第一个**变参时就死。

### 10.4 结论：缺陷不在 logc 的解析器

- 解析器所有游走都限定在 `[buf, buf+flen)`，且 `flen` 先与 `avail` 比对；
  13 轮设备侧 fuzz + 本轮 2000 轮 in-process fuzz 零命中。
- 崩溃发生在 **格式固定为 `"%0*lld"`** 的 musl 内部调用上，输入只有合法的
  `struct tm`；logc 侧唯一参与的是"调用 strftime"这个动作。
- 因此修复方向不是"更严格的帧校验"，而是**把 printf/va_list 从记录路径里彻底移除**。

### 10.5 修复（logc v1.4）

| 变更 | 说明 |
|---|---|
| 手写 ctime 格式 | `localtime_r` + 星期/月名表 + 有界整数输出，产出 `Www Mmm dd HH:MM:SS YYYY`，与 `strftime("%a %b %e %H:%M:%S %Y")` **逐字节一致** |
| 手写整行拼装 | 时间 + 可选 `[sec.millis] ` + `fac.pri` + ` kernel:` + msg + `\n`，全部 `memcpy`/边界检查，无 `snprintf` |
| stats 也去 printf | `write_stats` 改 `stats_kv()` 手写；守护热路径上再无 printf 家族 |
| 超长消息不再中止整轮 | 旧版 `snprintf` 溢出返回 -1 → `consume_records` 返回 SIZE_MAX → 整轮 rc=1（stability_metrics 里的 `logc_rc=1 io=1` 即此）；v1.4 缓冲区按 `MAX_MSG+256` 配足，异常情况只丢该条并计数 |
| 静态反链断言 | 产物已不含 `strftime` 的 `"%0*lld"` 与 `"%a %b %e"`（`grep -a -F` 可验），selftest v2.55 固化 |

### 10.6 验证

- **输出等价**：同一份 `crash.raw` 分别喂 v1.3/v1.4，`--stdin` 与 `-t` 两种模式
  `cmp` **逐字节相同**（36439 B）。
- **A/B 实弹**（同环状态交替跑，2500 轮设计，实际 2407 轮）：
  **v1.3 rc=139 × 10（20:26:57–20:27:41），v1.4 rc=139 × 0**；两版 rc=1 各 7/6 次
  （logd 短暂不可用，环境性）。崩溃全部落在 v1.3 一侧且未影响 v1.4。
- `--selftest` / `--fuzz 2000` PASS；`vercheck` 全绿。

### 10.7 仍未闭环（诚实清单）

1. **va_list 前 16 字节的写入者未定位**：可以确定 `ap2` 是 vfprintf 里对调用方
   va_list 的 32 字节整拷贝（`ldp q1,q2,[x2]; stp q1,q2,[sp,#0x120]`），且
   `__vr_top/__gr_offs/__vr_offs` 三个字段被正确复制——只有 `__stack/__gr_top`
   被换成垃圾。候选是 vfprintf 帧内 `internal_buf[80]`/`nl_arg[10]`/`nl_type[10]`
   某条越界写（`nl_type[12..15]` 恰好落在 `ap2` 头上），但静态反汇编未能收敛到
   具体写指令；下一次可用硬件观察点（`watch *(long*)($ap+8) if ...==0`）收口。
2. **静态 busybox/ip 的同族崩溃仍在**（core_meta 有元数据、aee core 加密）：
   本轮只根治了我们自己代码里可控的那条链路；第三方静态件若也走 musl printf，
   风险同源，需要单独取证（core 窗口 / gdb 抓 `ip`）。
3. **取证副作用（运维注意）**：持续高频 spawn（4 个 gdb 循环，或 2 进程/轮的 soak）
   会让 dropbear 进入"accept 后 EOF / 无 banner"的卡死态，SSH 不可恢复，
   只能 `sys_reboot`（GUI `/api/sys_reboot`，实测有效；reboot_sched 因当日
   `last` 去重不会触发）。取证脚本请限制并发、优先落 `/data`。

## 11. 2026-10-21 第二轮：剩余家族成员（awk 空数组 → busybox 退出路径 NULL）

> logc v1.4 之后，`logc_crash/` 不再增长（133 份为历史存量），但 `ne_events.tsv`
> 里的**其他成员**仍在崩。本轮用受控 core 窗口抓到第一份非 logc 的 core，定位到
> 一条与我们脚本直接相关的 busybox awk 缺陷并修复。

### 11.1 家族普查（`ne_events.tsv`，75 次 core_meta 事件）

| comm | 次数 | 备注 |
|---|---|---|
| awk | 27 | log_keeper 的 `delta()` 锚行抽取（本轮修复对象） |
| ip | 17 | `ip -4 addr show` / `ip -o -4 addr show`（led_mgr/wan_agg） |
| sh | 5 | busybox sh 解释器本体 |
| grep | 4 | `grep -Fqx` 锚行预检、降噪过滤 |
| pidof | 4 | watchdog 的 `pidof v3httpd` |
| gdb | 3 | **取证工具自身**（我们跑 catcher 时） |
| logd | 2 | 厂商 syslog 守护 |
| hostapd | 2 | 厂商 wpad |
| thermal_core / sleep / ls / ping / iptables / logread | 各 1 | 含 **`sleep 1`**（不做任何格式化） |
| ? | 3 | core_meta 读不到 exe/args（进程已不可见） |

分布是**全天稳态**（不是只在取证时）：10-20 各小时 1–9 次；取证循环期间会叠加
（20:21–20:27 6 次，含 gdb 自身 3 次）。`sleep` 与 `?` 的存在说明这不是单一
"printf 用得多"能解释的，家族**至少有两个以上独立缺陷**。

### 11.2 受控 core 窗口（可复用方法）

```
SAVED=$(cat /proc/sys/kernel/core_pattern)
echo '/tmp/cores/core.%e.%p' > /proc/sys/kernel/core_pattern
ulimit -c 8192        # 核心很小(awk 200KB); NT_PRSTATUS 在最前, 截断也能取寄存器
... 复现/等待 ...
echo "$SAVED" > /proc/sys/kernel/core_pattern   # 任何退出路径都恢复
```

窗口开在 21:01，30 秒内 log_keeper 的 awk 自己崩了，得到
`core.awk.9766`（204800 B）。**注意**：窗口期间 aee 拿不到 core，属已知取舍；
core_trap 的每日窗口机制保持不变。

### 11.3 core 现场

```
signal=11 si_code=1(SEGV_MAPERR) si_addr=4
pc=0x491ab8  ldr w0,[x19,#4]      x19=0        ← NULL+4
lr=0x4932d4
调用点 0x4932d0: bl 0x491aa4      ← 上一个 bl 0x4919b8 的返回值直接传入, 未判空
0x4919b8 返回 [node+0x18]（可能为 NULL, 调用方不检查）
0x491aa4 遍历 node->items[i] 逐个 free, 最后把 node 清零
```

寄存器里是正在解析的日志文本（`x11..x17` 为 ASCII、`x8=0xfefefefefefefeff`
是 strlen 的零字节掩码），说明崩溃发生在 **awk 退出清理**阶段，不是读行阶段。

### 11.4 复现与对照（决定性）

用 log_keeper `delta()` 的**原样脚本**、同一份 4MB `/data/gw/logs/syslog.log`、
同一锚行（末行），在设备上循环：

| 变体（锚点=文件末行，数组始终为空） | 400 次运行 |
|---|---|
| 原版：`{ n=0; split("", B); hold=1; next }` | **4 次 SIGSEGV** |
| `{ n=0; delete B; hold=1; next }` | **4 次 SIGSEGV** |
| `{ n=0; hold=1; next }`（从不创建数组） | **0 次** |

**第二轮修正（关键）**：把锚点移到文件**中段**（真实生产形态：锚点后还有新行，
`B[++n]=$0` 会把 ~18000 行装进数组），仅去掉 `split` 的版本 **300 次仍崩 2 次**。
所以结论不是"别清空数组"，而是 **这个 busybox awk 只要运行期存在数组，退出清理
就有约 1% 概率 NULL 解引用**——空数组和满数组都会踩到，崩溃率与堆布局相关、
与输入内容无关。数组无法"小心使用"，只能移出热路径。

### 11.5 修复

| 文件 | 版本 | 变更 |
|---|---|---|
| `gw/src/logcut.c` → `gw/bin/logcut` | 1.0 | **自建静态锚点截取器**：单遍扫描 + 一个可增长行缓冲，记录"最后一次精确匹配锚行"之后的光标，再把文件尾部拷到 stdout；无数组/无 printf/无 locale；`--check`/`--selftest` |
| `gw/log_keeper.sh` | 2.7 | `delta()` 改调 `logcut --after-last`（awk 彻底退出该路径）；`stream()` 去掉 `grep -Fqx` 预检，改看 logcut 退出码（每轮少一次 grep spawn） |
| `tools/selftest.py` | 2.57 | `t_batch4_awk_arrays`：logcut 在位 + `--selftest` PASS + log_keeper 不再含 awk delta + 全脚本无 `split(""` |
| `tools/deploy.py` | 2.25 | MANIFEST + `gw/bin/logcut` |

语义等价性：旧 awk 对新 logcut，同一 4MB syslog + **文件中段锚点**，输出
**逐字节相同**（484783 B / 498854 B 两次抽样）。logcut 还有一处更严格：锚点按
原始字节比较，而 `awk -v` 会解释反斜杠转义（日志里的 `\\` 不再被吃掉）。

### 11.6 仍未闭环

1. **ip（17 次）**：iproute2 静态件，与 busybox 不同源；需单独 core 窗口 + 循环
   `ip -4 addr show` 复现（预算 ~1e-3/次）。若同样落在退出清理，可考虑把
   led_mgr/wan_agg 的地址读取改成 /proc 解析或加"崩溃重试"。
2. **sh/grep/pidof/ping/ls/sleep**：单次或低频，尚无 core；`sleep` 的崩溃提示
   可能存在**启动期**缺陷（与 printf 无关），需要窗口期撞上才能定位。
3. **logd / thermal_core / wpad**：厂商二进制，只能缓解（降噪/减少 spawn），
   不能从源码根治。
4. **取证副作用**：gdb 自身也在家族里（3 次），且高频 spawn 会卡死 dropbear
   （见 AGENTS 陷阱表）。

### 11.7 ip 的第二份 core（本轮已取证，写入者未定位）

同一窗口机制循环 `ip -4 addr show`，**2703 次命中 1 次**（`core.ip.23057`，581632 B），
与 NE 普查里的 17 次同族：

```
signal=11 si_addr=0x157c0   pc=0x10a35c0  ldrb w8,[x0]   x0=0x157c0
lr=0x10a3818（fnmatch 内部递归）
```

- 调用链：`ip`（`ip/ipaddress.c:ifa_label_match_rta`）→ `fnmatch(filter.label, label, 0)`。
  崩溃指令在匹配器里读模式串首字节；**模式串指针 = `filter.label` = 0x157c0**。
- `filter` 在 `0x10f1000`（`adrp x26,#0x10f1000`），`filter.label` 位于 `+0xe28`
  （.bss，初始为 0）；源码里只有 `filter.label = *argv`（`-label` 参数）会写它，
  而本条命令没有 `-label`。**即：一个应为 NULL 的全局被写成了小整数 0x157c0**。
- 0x157c0 = 88000，形态更像长度/偏移而不是指针；与 awk 的 NULL 不同，这里更像
  **相邻全局被越界写**。写入者尚未定位（需要对该地址下硬件观察点复现一次）。

**对 `ip` 的处置建议**（本轮未改代码）：`ip` 的读路径（`show`）是幂等只读，
可加一层"崩溃即重试一次"的包装降低运维影响；根治要等写入者定位后重编
iproute2（我们已能从源码重建，build_static_ip.sh 在位）。

## 12. 2026-10-21 第四轮："机制未知"崩溃的定性 —— 就是 musl 的 printf/stdio

> 本轮只做取证，不改代码。目标：回答"到底还有没有一类我们没命名的崩溃"。
> 结论：**有，但它不是环境/硬件，而是 musl printf/stdio 的同一个缺陷类**；
> 已做出 20 行、2 秒内必崩的最小复现器，并把它和 logc/sh 的旧 core 对齐。

### 12.1 `?` 组：不是崩溃（排除）

3 个 `?` 事件（10-20 08:23/08:51/09:43）的 core_meta 文件**全部字段为空**：
无 btime、无 comm/exe/args/maps、fds=0、**连 `gid`（内核第 4 个参数）都缺失**。
交叉 aee 台账：这三个时刻**没有任何 NE 记录**（附近只有 08:07/08:16/09:30/09:54）。
→ 它们不是内核触发的 coredump，而是 core_meta.sh 的手工/测试调用（缺 `%g` 参数）。
**从崩溃普查中剔除。**

### 12.2 先排除"与程序无关的背景崩溃率"

金丝雀：一个只做 `return 0` 的静态 musl 程序（3944 B），在设备上循环 **30 万次**：

```
canary noop: 300000 次, 0 崩溃  -> 背景率 < 1e-5（95% CL）
```

所以"随便什么进程都会随机崩"的假设不成立；后面的崩溃都能归到具体代码路径。

### 12.3 `sh` 组：复现成功，两份 core 都指向 musl stdio/printf

- 复现器 A：`sh` 循环执行 `"$@" >/dev/null 2>&1` + 每 500 轮 `echo > file`，
  **34,500 轮时 shell 本体 SIGSEGV**；去掉 echo/算术、只留 fork/exec 也能复现
  （300k 轮内命中）；纯 shell 算术+echo、**不 fork 的 300 万轮 0 崩溃**。
- core #1（pid 4479）：`si_addr=0`、PC 在 `memcpy`，调用者 `__fwritex`：
  `f->wpos == NULL` 却仍走 `memcpy(f->wpos, ...)` —— 栈上 FILE 结构被写坏。
- core #2（pid 2404）：`si_addr = 0xffffffffffffffd8 = -40`，PC 在 `pop_arg` 的
  va_arg 取值路径，`ap->__gr_top = 0`、`__gr_offs = -40` —— **与 logc v1.3 的
  崩溃签名逐字段相同**（见 §1/§10）。

### 12.4 最小复现器（决定性）

```
c
char b[24];
for (unsigned long i = 0; i < 200000000UL; i++)
        snprintf(b, sizeof b, "%ld", (long)i);
```

- 静态编译，**2 秒内 SIGSEGV**（`arg.i = 1,566,894` -> 约 1/1.6e6 次调用）；
- `-O0` / `-O1` / `-O2` **全部崩溃**（0–1 秒）-> 不是优化/代码生成问题；
- 崩溃点：`pop_arg` 的 va_arg，`ap->__stack` 是小整数、`__gr_top=0`；
  整个 va_list（32 B）被写成 `{小整数, 0, 0x1c28416e00001180, 0}`。
- 该值的高 32 位 `0x1c28416e` 与 logc 旧 core 的 `__stack` 高 32 位**完全相同**
  （`0x1c28416e00000680`）-> 同一个缺陷、同一段数据形态。

gdb 观察点（设备自带 gdb）：
1. 在 `vfprintf` 的 `va_copy(ap2, ap)` 处命中：**复制进来的源 va_list 已经是坏的**
   （旧值 0x7ff5908bc0 = 栈指针，新值 0x22733 = 小整数）；
2. 帧布局：`nl_type` 在 `ap2` 下方 **0x30 字节**（12 个 int）处 ——
   `nl_type[12..15]` 恰好压在 `ap2.__stack/__gr_top` 上（与 §10 的候选一致）。

**尚未钉死**：具体是哪条写指令/哪个越界索引把 ap2 改坏的（下一步用"对 caller 的
va_list 全程下条件观察点"或与上游 musl 修复对比）。但这不影响定性：
**故障类 = musl printf/stdio 在 va_list 处理上的缺陷**，不是日志数据、不是硬件、
不是环境噪声。

### 12.5 家族重新归类

| 崩溃 | 机制 | 状态 |
|---|---|---|
| logc（已修） | musl `strftime->snprintf->vfprintf` va_list | v1.4 去 printf，已验证 |
| **sh** | **musl vfprintf/__fwritex（本轮实锤 + 最小复现器）** | 未修（busybox 内部无法绕过） |
| grep / pidof / ls / ping | 同上（都经 musl stdio 输出） | 高度同源（待各自 core 确认） |
| sleep（厂商 busybox） | 疑同上（未取到 core） | 待厂商 `sleep 0` 金丝雀确认 |
| awk | busybox 数组释放路径 NULL（独立） | v2.7 已移出热路径 |
| ip | `filter.label` 被写成小整数（独立，疑越界写） | 未修 |
| hostapd/logd/thermal_core/gdb | 厂商动态 musl；机制未逐个取证 | 不可替换/低优先 |
| `?` | 非崩溃（手工 core_meta 调用） | 已排除 |

### 12.6 对方案的含义（重要）

1. **修复优先级反转**：真正的大头不是"换组件"，而是 **修 musl 的 printf/stdio**。
   一个补丁可以同时消掉 logc 类、sh、grep、pidof、ls（约 40/47 次/天），
   而逐个替换 applet 只能覆盖其中一部分且成本高得多。
2. **最小复现器让 musl 补丁变得可行**：2 秒一次验证，可以快速迭代
   `vfprintf.c` 的候选修复；修好后用同一 musl 重编 busybox/ip/我们的工具，
   整个静态工具面一次性受益。
3. **厂商动态二进制（hostapd/logd/thermal_core）不受益**（它们链接厂商 libc），
   仍靠恢复/监督兜底；这部分维持原方案。
4. **替换方案降级为"第二优先级/兜底"**：netq、logd、小程序替换仍有价值
   （可控性、可维护性），但不再是"治崩溃"的主线；`sh` 替换在 musl 修好后
   也不再必要。

### 12.7 P0 实施记录（2026-10-21 深夜）：把复现器变成补丁的尝试

目标：用 2 秒复现器做"改一版、验一版"的迭代。方法：把 musl 的
`vfprintf.c` 单独编成对象（zig，aarch64-linux-musl），显式链接在 libc.a
之前覆盖同名符号。未打补丁的覆盖版仍然崩 → 覆盖链有效。

| 尝试 | 结果 |
|---|---|
| 诊断链：snprintf/vsnprintf/vfprintf 各加 va_list 校验 | 校验本身被编译器"取地址即拷贝"干扰；加强校验后报 `DIAG source-entry`：**va_list 进 vfprintf 时已坏** |
| 换**上游 master** 的 `vfprintf.c` | **10/10 仍崩** → 缺陷不在该文件的逻辑里（或 master 仍未修） |
| `vsnprintf` 里先 `va_copy` 到局部再转发 | **10/10 仍崩** → 不是调用边界的结构体拷贝单独造成的 |
| 变体：目标缓冲 4096 / `%d` / 固定值 | 各 **5/5 仍崩** → 与值、格式、目标缓冲大小无关 |

结论：污染发生在 **va_list 的传递/构造环节**（snprintf 的 `va_start`、
结构体按值传递、ABI 布局），而我们用"取 `&ap` 再校验"的方式观测不到——
取地址会让编译器物化副本，检查的是副本。下一步应：
1. 用 zig 从源码构建 musl（可控 CFLAGS），先对比 **libc 自身 -O0/-O1/-O2**
   （此前只换过程序的优化级别，libc 始终是 zig 预编译的 -O2）；
2. 或在 `snprintf` 内用**不取地址**的方式（memcpy 到局部再比较）校验，
   或对 va_list 内存下硬件观察点，钉死写入指令；
3. 拿到写入者后再决定补丁形态（musl 侧 vs 编译器侧）。

### 12.8 本轮结论汇总与证据索引（2026-10-21 收尾）

**一句话**：崩溃家族的主干已经定性为 **musl printf/stdio 的 va_list 缺陷**
（2 秒复现器），logc/awk 两条已闭环；sh/grep/pidof/ls 同源待补丁；
ip 是独立缺陷；"机制未知"里的 `?` 组根本不是崩溃。

#### 最终分类

| 崩溃 | 机制 | 状态 |
|---|---|---|
| logc | musl `strftime→snprintf→vfprintf` va_list | **已修**（v1.4 去 printf；零崩溃约 3h） |
| awk | busybox 数组释放路径 NULL | **已修**（logcut v1.0；A/B 10:0） |
| sh | musl vfprintf/__fwritex（两份 core、最小复现器） | **未修**（P0 进行中） |
| grep / pidof / ls / ping | 同上（musl stdio 输出面） | pidof/pgrep **已替换**（procmatch）；其余待 P0 |
| sleep（厂商 busybox） | 疑同源（未取到 core） | 待厂商 `sleep 0` 金丝雀确认 |
| ip | `filter.label` 被写成 0x157c0（独立，疑越界写） | 未修（P1 netq 计划中） |
| hostapd/logd/thermal_core/gdb | 厂商动态 musl；未逐个取证 | 不可替换/靠恢复 |
| `?` | **不是崩溃**：core_meta 手工/测试调用（全字段空、缺 gid、aee 无 NE） | 已排除 |
| 背景率 | 静态 `return 0` 金丝雀 30 万次 0 崩 | **不存在程序无关背景率** |

#### 证据索引（本地存档，不入仓）

`_local/archive/stability_2026-10-21/`
- `cores/`：crash_awk / core_ip / sh / sh2 / pf（5 份 core）
- `events/`：ne_events.tsv、meta.tar、evidence.tar、soak.tsv（v1.3 vs v1.4 A/B）、
  crash.72.log（logc gdb 现场）、crash.raw（回放 10/10 不复现）
- `repro/`：pfcanary 与诊断/候选修复源码
- `sessions/`：取证与 gdb 观察点脚本

**可复现资产（入公开仓，oneoff 不登记）**：
`tools/oneoff/printf_repro/`（pfcanary + 变体 + 覆盖 libc 的构建说明）。

#### P0 尝试记录（均仍崩）

| 尝试 | 结果 |
|---|---|
| 覆盖 libc 的 `vfprintf.c` | 未打补丁版仍崩 → 环有效 |
| 上游 master `vfprintf.c` | 10/10 崩 |
| `vsnprintf` 局部 `va_copy` 再转发 | 10/10 崩 |
| 4096 缓冲 / `%d` / 固定值 | 各 5/5 崩 |
| 诊断链 | 报 va_list 进 vfprintf 时已坏；`&ap` 会导致编译器物化副本，观测失真 |

**下一步**：从源码构建 musl，对比 **libc 自身** `-O0/-O1/-O2`；用不取地址的
字节比较或硬件观察点钉死写入指令；再决定补丁形态。

#### P1 进展（本轮已落地）

`gw/bin/procmatch` v1.0（静态、无 printf 的 pidof/pgrep）：
- pidof 10 个名字、pgrep -f 6 个模式、pgrep -x/默认 全部与 busybox 一致
  （多 PID 顺序不同，不影响调用）；
- `toolchain_init` v1.1 农场覆盖 pidof/pgrep；selftest v2.58；系统自检 **33/33**；
- 行为修正：busybox `pgrep -x` 漏存活进程，替换后 rc.extend 不再重复拉起
  dropbear、webs_revive 的 cfgmgr/iotagtd 守卫生效（已逐调用点评估）。

#### 收尾快照（设备，2026-10-21 23:15 CST）

```
up 2:44, load ~7.5
logc 1.4 / logcut 1.0 / procmatch 1.0
/data/gw/sbin/pidof -> /data/gw/bin/procmatch
/data/gw/sbin/pgrep -> /data/gw/bin/procmatch
logc_crash/ = 133（无新增）
ne_events  = 129（其中约 41 条是 P0 金丝雀实验，不是产品故障）
core_pattern = |/data/gw/core_meta.sh %p %s %u %g
```

#### 本轮提交

- 公开仓：`e3ba151`（第四轮定性）、`afcfad9`（procmatch + 农场）、
  `fa9dc54`（P0 记录 + P1 进展）、本次（结论汇总 + oneoff 复现包）。
- 私有仓：`35c5933`（L31）、`bc8a292`（L32）。

#### 仍未闭环

1. musl va_list 写入者（P0 主线）；
2. ip 的越界写写入者（P1 netq 兜底）；
3. `sleep` 同源性确认；
4. 厂商动态件（hostapd/logd/thermal_core）不可替换，靠恢复。


## 13. 2026-10-22 凌晨：P0 攻坚 —— 从复现器到"崩溃消除"的硬化补丁

本轮目标是把 §12 的"机制定性"推进到可交付形态。结论先说：**崩溃已经可以用一个
musl 侧补丁彻底消除（对重新链接的二进制），但写入者仍未钉死**；窗口已被压到
`snprintf` 的 `va_start` 之后、`vfprintf` 的 `va_copy` 之前，也就是
**va_list 的按值传递副本**这一段。

### 13.1 方法：先校准仪器，再谈结论

| 仪器 | 作用 | 位置 |
|---|---|---|
| `p0probe` | 10 个模式一次跑完：自有可变参数 / printf 各形态 / 控制组 | `tools/oneoff/printf_repro/` |
| `p0probe2..5` | 进程内 SIGSEGV dump（寄存器、PC、PC 处 32 字节、栈窗口、按寄存器指针取区） | 同上 |
| `p0cal` | **仪表校准**：用已知寄存器/栈炮制一次 fault，逐字段核对 dump | 同上 |
| `layerchk/` | 用本地副本覆盖 musl 的 `snprintf/vsnprintf/vfprintf`，在每层加 va_list 检查点 | 同上 |
| `pfscope` | 同一 guard 套在自有可变参数上，比较污染率 | 同上 |

校准中发现并修掉的**仪器自身缺陷**（否则后续结论全是假的）：

1. 行缓冲 `char b[96]` 装不下 173 字节的 32 字节行 → 处理器把 dump 写花；
   改 `b[256]` + 固定两位十六进制。
2. `mcontext` 字段名在 musl aarch64 上是 `regs[31]`/`sp`/`pc`/`fault_address`。
3. 取 `&ap` 对**参数位**的 va_list 会让编译器物化副本（实测 `&ap` 与被调方
   看到的对象相差 0x200）→ 只在"局部 va_list"或"本来就是指针参数"处校验。
4. 信号处理器的 `SA_ONSTACK` 在该设备上未生效（`sp_in_alt=0`），
   但数据段 altstack 已申请，后续以"不依赖 altstack"的方式取样。

校准结果（`/data/p0/cal.txt`）：`si_addr=0x3000`、`fault_address=0x3000`、
`x10/x11=0x1111…`、`x12=0x3000`、PC 处就是那条 `ldr x13,[x12]`、栈窗口里能读到
预置的 `0x33…`/`0x11…` 图案 —— 仪表可信。

### 13.2 决定性事实

| # | 事实 | 证据 |
|---|---|---|
| 1 | **自有可变参数不崩**：`vsum(1,i)`/`vsum(9,…)`/`vderef` 各 5e7 次 0 崩溃；`vsum` 3e8 次 + 同 guard 检查 **bad=0** | `result2.txt`、`p0devices/` |
| 2 | **printf 家族全崩**：`%ld`/`%s`/`%e`/`sprintf`/`snprintf(n=0)`/常量参数/静态缓冲 | `result2.txt` |
| 3 | **纯字面量不崩**：`snprintf(b,24,"abc")` 5e7 次通过 → 与"整数转换路径"强相关 | `result2.txt` |
| 4 | 崩溃点恒定 `pop_arg`（type=13=PA_LONG）`ldr x8,[x8]`，x8 = `__gr_top+__gr_offs` 或 `[ap]` | 四份 probe4 dump，PC 符号解析 |
| 5 | `ap == &ap2`（`delta=0`）：pop_arg 用的就是 vfprintf 自己那份 va_list，**不存在指针传错** | `rec.log` |
| 6 | **第一个变坏的检查点是 `after_va_copy`** → 坏源在调用方（`snprintf` 的 va_list），不是 printf_core 内部 | `cp.log` |
| 7 | 健康基线：`{__stack=栈地址, __gr_top=栈地址, __vr_top=栈地址, __gr_offs=-48, __vr_offs=-128}` | `pfchk3` baseline |
| 8 | 坏块形态：**16 字节**被写成类 `{i<<32|0x680, 0}` 的值，落在偏移 0..15 或 16..31 都见过 | `layer.txt`、`dump.*` |
| 9 | 污染率（guard 命中/调用）：15/2e8 = **7.5e-8**；22/3e8 = **7.3e-8** | `ab.log`、`rec.log` |
| 10 | SIMD/拷贝代码生成无关：`-mgeneral-regs-only` + 逐字节拷贝的"无副本链"3×1e8 通过（对照同样通过，样本不足以证明差异） | `n.log`/`g.log` |

**对 §12 的一处更正**：`__vr_top = 0x1c28416e00000680` 曾被当作"污染指纹"，
但本轮在各类坏块里看到同一个 64 位值的**高 32 位就是循环计数器**（如
`0x0998010a`、`0x1c28416e`），且它在 va_list 的不同偏移出现过。因此指纹
不成立，判据只能是结构性的：**四个字段是否都指向用户态可访问范围、两个偏移是否
都为负**。这同时解释了为什么 `sh`/`grep`/`pidof` 等"看起来不同"的崩溃其实是同一形态。

### 13.3 硬化补丁（本轮可交付物）

`layerchk/h_vfprintf.c`：musl `vfprintf.c` 原样 + `pop_arg` 入口 5 行 guard

```c
#define P0_VA_SANE(ap) ((unsigned long)(ap)->__stack >= 0x1000UL && \
    (unsigned long)(ap)->__gr_top >= 0x1000UL && \
    (unsigned long)(ap)->__vr_top >= 0x1000UL && \
    (ap)->__gr_offs < 0 && (ap)->__vr_offs < 0)
...
static void pop_arg(union arg *arg, int type, va_list *ap)
{
	if (!P0_VA_SANE(ap)) { __p0_va_guard_hits++; arg->i = 0; return; }
	...
```

- 阈值 0x1000 低于 `mmap_min_addr`，正常的栈/寄存器保存区永远不会被误判。
- 命中时输出 0 而不是解引用野指针 —— 代价是 1e-8 量级的错误数字，远小于一次 SIGSEGV。
- **链接方式**（关键）：把该文件编成 `hardened_vfprintf.o` 放在 libc **之前**，
  `snprintf → vsnprintf → vfprintf` 整条链自动获得保护：

```sh
zig cc -target aarch64-linux-musl -O2 -D_GNU_SOURCE \
  -I<musl>/src/internal -I<musl>/src/include -I<musl>/include \
  -I<musl>/arch/aarch64 -I<musl>/arch/generic \
  -c hardened_vfprintf.c -o hardened_vfprintf.o
zig cc -target aarch64-linux-musl -O2 -static prog.c hardened_vfprintf.o -o prog
```

A/B（同一台设备、同一循环、2e8 次 `snprintf("%ld")`）：

| 构建 | 结果 |
|---|---|
| 硬化 | `survived calls=200000000 guard_hits=15`，rc=0 |
| 控制（stock libc） | `Segmentation fault (core dumped)`，rc=139 |

同一补丁也解释了本轮"为什么 §12.7 的十次尝试全部失败"：那些尝试都在改
`vfprintf.c` 的**逻辑**，而坏值在进入 `vfprintf` 之前就已经在 va_list 里了；
只有"先校验再解引用"才有效。

### 13.4 仍未闭环（诚实清单）

1. **写入者**：窗口已压到"调用方 va_start 之后、vfprintf va_copy 之前"，即
   32 字节 va_list 的**按值传递副本**；坏块是 16 字节、内容含循环变量形态。
   下一步是把检查点推进到 `vsnprintf` 入口/出口与调用方 outgoing 区，
   或对该 outgoing 区下硬件观察点（PTRACE `NT_ARM_HW_WATCH`）。
2. **是否与编译器有关**未定：本轮所有实验都用 zig/clang 构建；gcc 侧只有历史
   core 的间接证据（Alpine busybox 同签名）。
3. **busybox / iproute2 无法重新链接**，硬化补丁对它们无效 → P1（换组件）仍是
   这两块的唯一出路。

### 13.5 证据索引（本地，不入仓）

`_local/archive/stability_2026-10-21/p0devices/`：`rec.log`（ap==ap2 + 坏字）、
`cp.log`（首坏检查点 = after_va_copy）、`ab.log`（硬化 15 命中 0 崩溃 vs 控制组
段错误）、`pchk.log`（layer 检查点原始记录）、`n.log`/`g.log`（SIMD A/B）、
`cal.txt`（仪表校准）、`snapshot.txt`。
`_local/archive/stability_2026-10-21/p0dumps/`：probe4/probe5 的 9 份现场 dump。
工具源码：`lg6151m-public/tools/oneoff/printf_repro/`（`p0probe*.c`、`p0cal.c`、
`layerchk/`）。

### 13.6 普查注记：本轮探针自身在 ne_events.tsv 里留了 4 条（勿计入产品故障）

收尾时 \`ne_events.tsv\` 尾部（设备本地时间 2026-10-22 00:0x–00:2x）：

| pid | comm | 归属 |
|---|---|---|
| 21168 | \`pfctl\` | **本轮探针**（对照组成员，预期崩） |
| 22319 | \`pfcp\` | **本轮探针**（未加 guard 的检查点版本，预期崩） |
| 12033 | \`wc\` | 产品侧：busybox stdio 家族，\`wc -l\` |
| 18302 | \`grep\` | 产品侧：\`grep -q ^default via <WAN_GW> dev eth0\`（wan_agg） |

结论两点：① 探针崩溃已被 core_meta 记录，做普查时必须按 \`exe=/data/p0/*\` 排除；
② 同一窗口内产品侧仍有 \`wc\`/\`grep\` 崩溃 —— 家族仍在活动，本轮补丁尚未部署到
那些二进制（它们没有重链接）。\`cores/meta\` 目录已达 120 文件上限（core_meta 的
保留策略），因此新崩溃不再新增文件，只有 TSV 行。

## 14. 崩溃普查与速率（唯一权威表，2026-10-22 收关自 REPLACEMENT_FEASIBILITY §1 迁入）

干净窗口 2026-10-20 08:16 → 10-21 19:34（35.3 h，69 次 core 事件）：

| 组件 | 归属 | 次数 | 速率 | 用户可见性 |
|---|---|---|---|---|
| awk | 自建 busybox | 27 | 18.4/d | 低（日志镜像缺口；**已修**，见 §11） |
| ip | 自建 iproute2 | 17 | 11.6/d | 低（守护单次读数失败，下一轮重试） |
| sh + busybox(sh) | 自建 busybox | 7 | 4.8/d | 中（守护整轮中断，watchdog ≤1 周期重启） |
| grep | 自建 busybox | 4 | 2.7/d | 低 |
| pidof | 自建 busybox | 4 | 2.7/d | 低 |
| `?` | 未知 | 3 | 2.0/d | **不是崩溃**（§12.1），已从判据里剔除 |
| hostapd(wpad) | 官方 | 2 | 1.4/d | **高**（WiFi 全断） |
| iptables | 官方(slot B xtables) | 1 | 0.7/d | 低 |
| logread | 官方 | 1 | 0.7/d | 低（仅 aee 转储时） |
| ping / ls / sleep | 自建/官方 busybox | 各 1 | 各 0.7/d | 低 |
| **合计** | | **69** | **46.9/d** | |

派生口径（**引用速率时用这三条，不要各自重算**）：

- awk 的 27 次全部发生在 `log_keeper` v2.7 之前 → 修复后**当前基线 ≈ 28.5 次/天**。
- A 类（musl printf）覆盖 ≈40/47 次/天；组件替换只覆盖 ≈17/47 —— 这是"先修库、再换件"
  的量化依据（曾写在 REPLACEMENT_FEASIBILITY §0.5.2，现以本表为准）。
- 探针/复现造成的 core 与 aee 事件必须按 `exe` 扣除（§13.6 示例）。

## 15. 历史取证细节（2026-10-22 收关自 INCIDENT_2026-10-19 §2.2/§2.3 迁入）

> 这些是 2026-10-19 现场的原始取证，机制解释以 §1–§3、§10–§13 为准。
> 保留它是为了"下一次换个进程崩"时能复用同样的手法与判据。

### 15.1 内核 fault 行的正确读法

arm64 打印格式是 `unhandled exception: DABT`，**不是** x86 的 `segfault at`：

```
[46869.933501] logread: logread[18115]: unhandled exception: DABT (lower EL),
  ESR 0x0000000092000006, level 2 translation fault in libc.so[7f9280d000+7b000]
```

- `[base+size]` 是**故障指令所在 VMA**，不是故障地址（常见误读）。
- 持久 dmesg 镜像里 15 条分类：logread 13 条（故障指令在 libc.so）+ 1 条（在自身 text）
  + logd 1 条（在 libubox.so）——**同一家族可以跨多个进程/库**。

### 15.2 未加密 core 的获取（受控窗口）

临时 `echo '/tmp/core.%p' > /proc/sys/kernel/core_pattern` + `ulimit -c unlimited`，
复现后立刻恢复 aee 管道。三份 core 签名一致：

| 项 | 值 |
|---|---|
| 信号 | SIGSEGV / `si_code=1`(SEGV_MAPERR) |
| PC | `/lib/libc.so +0x51ffc`（三次相同） |
| 故障指令 | `ldr x0, [x3]`（x3 野指针） |
| `si_addr` | 0x2475b / 0x25746 / 0x14f1b（三次不同，均为小整数） |
| 栈回溯 | `logread 0x403590 → ctime → asctime_r → snprintf → vfprintf` |

反汇编对上：`0x403590` 就是 `bl ctime`；每行输出的 `Mon Oct 19 …` 正是 ctime 格式。
（今天回看：这条回溯已经指到 A 类机制，只是当时按"记录内容"方向解释。）

### 15.3 两条"看现场"的经验

- **栈缓冲区内容定位"崩在哪一条记录之后"**：崩溃前最后一条已成功格式化的行在
  `fp+0x378` 的 0x480 缓冲区里（`Mon Oct 19 04:11:07 2026 daemon.info thermal_core…`），
  其后的 ` MRO-W00` 是下一条的片段 ⇒ 崩在它之后；输出文件只 flush 到那里是
  **stdio 缓冲假象**，不是"开机 3.4 s 就崩"。
- **16 KB 输入缓冲的边界截断**：core 里一块 16 KB 匿名映射是 syslog 行的滑动窗口，
  最后一行在边界被截断。当年据此推测"边界触发"，**该假设已被 §12 的金丝雀/回放证伪**
  （回放 10/10 不复现、清环只改变调用频次）——记录在此以防有人重走。

### 15.4 实验矩阵（当年实测，可与 §12/§13 对照）

| 实验 | 结果 | 当年结论 | 今天读法 |
|---|---|---|---|
| `TZ=UTC` 下 100 次 logread | 仍崩 1 次 | 与时区无关 | 成立（与 A 类的"频率"一致） |
| `dmesg -c` 清内核环后跑 | 仍崩 | 读的是 logd 的 syslog 环 | 成立 |
| 重启 logd 清环后 2500 次 | 0 崩 | 触发记录随开机日志驻留 | **只说明频次下降**，不是根因 |
| `logread -l 200` 2000 次 | 0 崩 | `-l` 跳过大部分格式化 | 成立（少一次 printf 就少一次机会） |
| `ip -o link` ×300 / `true` ×300 | 0 崩 | 不是"每次 exec 随机崩" | 成立 |
| 注入 2000 字符 logger 消息 | 行被截到 1040 B，未崩 | 超长行不触发 | 成立 |
| 静态 memtest 256 MB×3 遍 | 0 位翻转 | 不是 DRAM 损坏 | 成立（与 §12.2 金丝雀一致） |
| 同一 4 MB 文件 60 次 md5 | 哈希唯一 | 不是读路径数据损坏 | 成立 |
| 故意空指针（crashme） | 内核打印 DABT + core | 内核 fault 打印正常 | 成立 |

## 16. 2026-10-22 收官轮：机制反转 —— 全家族 = 外部主控经回收页注入

> 本轮把 §10–§13 的定性（"musl printf/stdio va_list 缺陷"）**推翻并重建**。
> 结论一句话：**没有任何一个被怀疑过的软件组件（musl、busybox、iproute2、
> 我们自己的代码）有错；全部崩溃是"外部主控把 16/32 字节记录写进被回收
> 复用进用户进程的物理页"这一个机制的不同表现。** printf 家族只是最高频
> 解引用被污染内存的路径，因而是最常见的爆发点（选集效应，§16.4）。
> 取证资产：本地 `tmpfiles/p0x/`（探针源码 + ne_events 快照）；设备侧
> `/data/p0x/`（memtruth/pageharvest/哨兵，oneoff 性质不入仓）。

### 16.1 反转的触发点：固定地址观测 = 0 命中

新探针 `memtruth`（静态、全 printf-free、纯 syscall 报告）对**同一组固定地址**
做高频写+读校验，共观测：

| 模式 | 规模 | 结果 |
|---|---|---|
| 栈/静态/mmap 金丝雀 ×3 | 各 2e8 次写读循环 | **0 命中** |
| 256KB 预填充纯读校验 | ~1e8 次读 | 0 |
| 同物理页双虚址（alias） | ~5e7 次读 | 0 |
| 4 CPU 分别绑核 | 各 5e7 | 0 |
| 双核并发（ro+stk） | 2e8 + 6.5e7 | 0 |
| mprotect 只读陷阱页（600s） | 4.1e8 轮读 | 0 命中、0 SIGSEGV |
| 深层闲置栈金丝雀（4KB–256KB 深，600s） | ~7e5 轮 | 0 真实命中 |

同时段对照：P0 会话（23:31–00:16）里同类 printf 循环 100% 在秒级崩。
**结论**：污染不是"按地址均匀分布的随机内存故障"（否掉 DRAM 单元坏 /
CPU 缓存路径坏 / 按访问率计费的读写故障），而是**有剧集时段（episode）、
且只落在特定物理页上**的现象。此前 §13 的 n.log/g.log 对照组"样本不足"
的疑点（3×1e8 全过）由此得到解释：那些运行恰逢平静期。

### 16.2 九条证据（E1–E9，机制闭环）

**E1 跨进程/跨编译器/跨重启的同一注入常量（最强单一证据）。**
64 位值 `0x1c28416e00000680`（及同族 `…00001180`）以**完全相同的位形**
出现在至少 6 个独立崩溃现场：厂商 musl logread core（10-19）、Alpine
busybox sh core ×2（10-21 20:2x，GCC 构建）、zig 构建 logc v1.3（10-21）、
zig pfchk3 自有可变参数快照（10-22）、zig pfcp ap2（10-22）。覆盖 3 种
编译器产物、≥2 次设备重启、3 天时间跨度。进程内软件不可能跨重启跨
编译器写出同一常量 → 注入源在 AP CPU 之外且跨重启存活（蜂窝 MD 的
电源域行为；WiFi 固件随 AP 重启会复位，故 MD 为首要嫌疑）。

**E2 同页多块、同值复现。** core_3053（logread）：同一 4KB 栈页内
`0x1365fe9b0000062d` 在 +0x188 与 +0x310 两处以 {0, X, 0, …} 形态重复；
sh2.core：`0x1c28416e00001180` 在 +0x148 与 +0x290 重复。外加各一处
{small,0} 半块。→ 写入是**同一页内多条 16/32B 记录**（环形槽位形态），
不是单次越界。

**E3 ip core 的 .bss 整页喷射（原 C 类闭环）。** 把 core_ip.core 的
0x10f1e00–0x10f1e60 映射到 `struct link_filter`（368B，label 在 +304）
字段上：`0x157c0` 以 **16 字节节距连打 5 发**（pfx 尾部、flags、label、
flushb、slave_kind），中间夹正常值（master=-1 合法）。fnmatch 恰好解引用
label 才崩。→ 与 va_list 坏块同族，victim 签名只取决于"哪个字段被击中"。

**E4 块形态学。** 全部坏块归纳为两种：16B `{小整数, 0}` 与 32B
`{小整数, 0, 0x????????_0000_06xx, 0}`；小整数非单调（相邻分钟内
112,712 → 52,764 递减出现），是按槽位独立的计数值/序号，不是全局计数器；
`0x…0000_06xx` 是注入源的准静态 64 位值（低 16 位在 0x62d/0x680/0x1180
间缓慢变化）。

**E5 剧集性 + 按页命中。** §16.1 的 0 命中 vs P0 会话 100% 秒崩；崩溃
迭代数跨 3 个数量级（3,806 / 1.57e6 / 6.67e6）。→ 污染页处于"流转"状态时
每个新进程都可能拿到它；不流转时整系统平静。

**E6 受害者生态 = 新页获取率。** 全家族高频成员全是**短命、每次 exec 都拿
新页**的工具（grep/awk/ip/sh/pidof/wc/sed…，30s 守护舰队持续供给）；
长命厂商件（hostapd/logd/thermal_core）低频崩溃（剧集期新分配页中招后
"终身"受害）；固定地址长命探针 0 命中；官方固件 4 周零记录（无人供给
新页 churn，§5 的"官方不发病"由此彻底解释——不是官方有防御，是官方
没有页流转）。

**E7 注入源侧画像。** SoC=MTK（4×Cortex-A55，内核 5.15.134），21 个
ccmni 通道、ccmni2 承载数据（RX ~950MB）；dmesg 有 ccci 通道 **16 字节**
写入记录（`[ccci1/chr]write error done on ttyCMIPC11, l=16`）——与坏块
粒度一致；崩溃剧集与蜂窝拨号/WiFi 搬道时段吻合（§4 与 23:31–00:16 窗口
实测：产品崩溃率 ~6/h，为日内基线 ~2/h 的 3 倍）；MD 保留内存区在
/proc/iomem 的 0x82000000–0x89f6ffff 等窗口（供活捉后比对 PFN）。

**E8 交付链 = 回收页复用。** 主控的环形缓冲页被驱动释放后回到 buddy
池，被用户进程当新栈/新堆/新 .bss 页拿走，主控仍持旧物理指针继续写。
解释：memtest 通过（无页复用）、金丝雀通过（无新页）、logc v1.3 每次
spawn ~3.5% 崩溃率（每轮读环 ~万次 strftime 的高频解引用 × 污染页）。

**E9 旧"反证"全部反转为佐证。** TZ 无关/记录内容无关/-l 200 更少崩/
字面量不崩/自有可变参数"不崩"（实为崩点少：pop_arg 是最高频的污染值
解引用点）/O0-O2 全崩/上游 master vfprintf 仍崩（libc 无辜当然无效）——
全部与主机制相容，与"libc 缺陷"反而处处别扭。

### 16.3 坏块与判据（替代 §0.5 旧判据的补充）

- **注入块签名**（识别新 core 用）：16B `{u64∈[0x2710, 0x40000]∪{0}, 0}`
  或 32B `{small, 0, 0x????????_0000_06xx, 0}`；同页可多块；同剧集内
  `0x…` 值恒定、跨天缓慢变化。
- **健康 va_list 判据**沿用 §0.5（结构判据，非指纹）。
- 崩溃速率口径沿用 §14（须分子分母 + 扣除探针）。

### 16.4 选集效应：为什么"看起来"是 musl printf 的缺陷

污染块落在进程内存的任意位置；**大多数落点无人解引用，无感**。printf
的 `pop_arg` 对 va_list 指针字段的解引用频率是全系统最高的（每次
printf 调用至少 1–N 次），因此污染页一旦命中活跃 printf 路径，几乎必然
以"musl 内 va_arg 崩溃"的形态爆发。这就是：全家桶"全是 printf 崩"、
logread 45% 占比、`-l 200` 降幅、字面量不崩（无 pop_arg）、自有可变参数
"不崩"（解引用点少一个量级）的统一解释。**去 printf 化（logc v1.4/
logcut/procmatch）作为缓解依然正确有效**——它把最高频解引用点摘掉了。

### 16.5 注入源候选（按嫌疑排序）与判别途径

| 候选 | 支持 | 反对/待验 |
|---|---|---|
| **蜂窝 MD（ccci/ccmni 共享环）** | E1 跨重启存活（MD 独立电源域）；E7 16B 记录与 ccci 日志粒度一致；剧集与拨号/数据活动相关 | 待活捉页 PFN 落在 MD 相邻窗口 + 记录内容语义 |
| WiFi 固件（mt76 环） | 剧集与搬道相关（§4） | 固件随 AP 重启复位，与 E1 跨重启矛盾 → 至多次要共犯 |
| 其他常开协处理器（mcupm/SPM 域） | iomem 有 mcupm mbox；常开 | 记录形态与 ccci 16B 吻合度低 |
| AP 内核模块写错地址 | — | E1 跨重启常量要求内核静态常量（可能但牵强）；与 E7 粒度/相关性不如 MD |

判别途径：`/data/p0x/pageharvest`（活捉页 → pagemap PFN + kpagecount>1
判"驱动仍映射"）+ `/data/p0x/sentinel.sh`（pfcanary 每分钟探剧集，rc=139
即触发 harvest 抢收）。**两仪器已常驻设备，下一剧集自动取证。**

### 16.6 根修路径（确认方向，未实施）

按"覆盖面 × 成本"排序；**唯一能同时覆盖不可重编厂商件（hostapd/logd/
thermal_core/gdb…）的是 B/C 两类**：

1. **O1 活捉**（仪器已就位）→ 拿到被写页的 PFN、kpagecount、整页记录
   dump。判定：kpagecount>1 ⇒ 驱动仍持映射（内核侧 UAF 实锤）；
   PFN 落在哪个保留窗 ⇒ 主控归属。
2. **选项 A（内核/驱动侧，最外科）**：定位释放环页的驱动（ccci_hif/
   ccmni/mt76 teardown），补丁或自建模块**钉住环页**（teardown 只解绑
   不 free，reboot 才回收）。先例：本项目已有自建内核模块能力
   （healthdog.ko / v3_fix.ko）。
3. **选项 B（LK cmdline 预留，覆盖面最大之一）**：若 O1 显示主控写的是
   **跨重启稳定的物理地址**（环分配确定性高，大概率如此），用既有刷机
   管线的 `kcmdline append memmap=…` 把该物理范围从 buddy 池永久剔除
   ——主控写进的页永远不会再被任何进程拿到。**全系统（含厂商件）一次
   性免疫**，代价是几 MB 内存。
4. **选项 C（EMI MPU 硬件防火墙）**：SoC 有 emimpu@1021a000（MTK DRAM
   主控访问防火墙）。把 MD/相关主控的写窗口收紧到其 SMEM 区，越界写在
   硬件层被拦。最强但最厂商特定，需 MTK 工具链配合，列为 B 不可行时的
   后手。
5. **缓解层（可立即做，线性降低可见故障）**：降低热路径 spawn 频率
   （守护合并/批量）；对幂等只读工具（wan_agg 的 ip 读数等）加"崩溃即
   重试一次"包装。**不再是修复主线**，根修后可回撤。
6. **明确不是修复**：修/换 musl、更多 applet 替换、netq（见 §16.7）、
   "P0 下一步：从源码构建 musl / 硬件观察点抓写入者"（§12.8）——全部作废。

### 16.7 已落地修复的再评价（复杂性/性能 vs 实际必要）

| 修复 | 前提 | 实测效果 | 再评价 |
|---|---|---|---|
| **P2 静态工具链**（busybox/ip 农场 + PATH 前置 + fail-open + TZ 双机制 rc v2.4/2.5） | "崩溃面=厂商 musl 动态件" | **崩溃零改善**：静态 musl 同样中招；§10.1（静态件 61 次/35h）与 10-22 凌晨（grep/ip/sh/sed/awk/wc 全崩在 `exe=/data/gw/bin/busybox`）实证；切换前后各成员速率持平 | **前提已被推翻**。保留（工具链自主权 + procmatch/pgrep 交付载体 + 行为一致），但**冻结**：不再为治崩溃扩展任何替换。农场是全项目最大的一笔"为已证伪前提付出的复杂度"（305 符号链接 + 启动耦合 + selftest 面） |
| **P1 logc v1.4 去 printf**（手写 ctime/拼装/stats） | "musl printf 缺陷" | **有效**：v1.3 7 崩/h → v1.4 0 崩（至今） | 保留。机制上=摘掉最高频解引用点（§16.4）；logc 本身作为 logread 替代另有独立价值（受控解析/stats/selftest） |
| **logcut 替换 awk**（+ stream 去 grep 预检） | "busybox awk 数组缺陷" | **有效**：18.4/天 → 0 | 保留。但 §11 的"awk 内部缺陷"解释降级为未证实（§16.2-E3 注）；真实生效机理=少 spawn + 无崩溃解引用点 + 无大数组堆页 |
| **procmatch 替换 pidof/pgrep** | "同 printf 面" | **有效**：2.7/天 → 0；另修了 busybox pgrep -x 漏存活进程的真 bug | 保留（双重收益）。残留暴露：svc_lib 的 hostapd 检查仍用 busybox awk（23:49 崩过一次），可在根修前顺手收口，非必须 |
| **P3 core_trap 窗口 + core_meta 包装** | 取证缺口 | 本轮收官分析即建立在其 core 之上 | 保留（证据管线） |
| **P4 watchdog aee 增量判据** | dmesg 限流盲区 | 实测有效 | 保留 |
| **logd 开机清环**（log_keeper v1.7，uptime≥300s） | "毒记录驻留环" | 前提已被 §12/§16 双重证伪（记录内容无关） | **不再有崩溃学理由**；仅剩"开机环卫生（aee 转储体积）"边际价值。低价值项，留待 owner 决定去留（去留皆无害） |
| **hardened vfprintf（h_vfprintf.c）** | "libc 侧修" | 技术上有效（guard 拦截=崩溃消除）但从未部署 | 归档为**技术**（未来新写的 printf 热路径静态件可复用）；不再有部署计划 |
| **REPLACEMENT_FEASIBILITY 的 netq 路线**（/proc 解析替代 ip 读数） | "ip 有独立缺陷需净替换" | — | **作为治崩溃手段取消**（ip 崩溃=主机制）；若仅为少 spawn 有边际收益，成本/收益不成立。§12.8 的"P0 下一步（musl 源码构建、观察点抓写入者）"一并作废 |
| **ap_auto_logging=0 护栏** | 防 logread -f 常驻 | 仍然正确（少一个无谓常驻崩溃面） | 保留 |

### 16.8 未闭环清单（收敛后仅剩 4 项，全部有自动化仪器在位）

1. **O1 活捉被写页**：pageharvest（12h 滚动）+ sentinel（分钟级剧集探测，
   命中自动触发 burst）已常驻 `/data/p0x/`。拿到即闭环 E-链最后一环
   （PFN/kpagecount/整页记录原文）。
2. **O2 主控与释放驱动归属**：由 O1 数据 + /proc/iomem 保留窗 + 必要时
   自建模块记录 ccmni/cci 环物理地址比对。决定选 A 还是 B。
3. **O3 awk"内部缺陷"独立证实与否**：不再必要（主机制已覆盖解释）；
   仅当 O1 证明注入不存在时才需回头（概率极低）。
4. **O4 sleep/ls/ping 等零星成员**：同主机制推定（短命+偶发命中），
   无需单独取证；根修后自然消失。

> 运维注意：sentinel/pageharvest/memtruth 的崩溃与 core 会计入 ne_events
> （exe=/data/p0x|/data/p0 与 /tmp/*），普查时按 §13.6/§14 口径扣除。

## 17. 2026-10-22 终局轮：二进制定罪 + 活体捕获（"指控坐实"）

> 本轮按"逆向分析二进制坐实指控"执行，两个方向都拿到了决定性结果：
> ①内核侧（ccci/dpmaif 驱动）环机制与常数**直接对上坏值构成**；
> ②pageharvest 在被持有期间**当场捕获外部写入者**落笔。
> 至此 §16 的机制定性从"最强假设"升级为"二进制级+活体级实证"。

### 17.1 逆向管线（可复现）

- boot 分区内核载荷熵 7.965 bits/B = **加密**（MTK 安全启动），镜像路线不通；
- 但 `CONFIG_STRICT_DEVMEM` **未启用** + root + `/proc/iomem` 的 "Kernel code"
  物理范围（0xfd910000-0xfe52ffff）→ 经 `/dev/mem` 直读**运行中内核文本**，
  12MB 全量落盘；数据段（0xfe6d0000+3.6MB）同理；
- `/proc/kallsyms`（kptr_restrict=0）6.1 万符号 + capstone → 带符号反汇编
  （工具链存档 `tmpfiles/p0x/kern/kern_an.py` + ktext/kdata/kallsyms 快照）；
- `ccmni`/`ccci` 为**内置驱动**（/lib/modules 无对应 .ko）——只能走内核文本。

### 17.2 内核侧定罪链（反汇编锚点）

| # | 事实 | 反汇编锚点 |
|---|---|---|
| 1 | **BAT 环条目数 = 0x680/0x780，条目尺寸 = 0x18/0x20，环本体 dma_alloc_attrs(0x20000)** | `dpmaif_bat_init+0x20..0x30`（`csel w20,w20,#0x18`、`csel w0,w0,#0x680`）、`+0x60 bl dma_alloc_attrs` |
| 2 | **坏值低 16 位 0x680 正是 BAT 环计数**；0x780 在 `dpmaif_start`/`dpmaif_rx_med_data_collect` 复现；受害者坏块 16/24/32B 尺寸=环条目尺寸族 | 同上 + 全文 `movz #0x780` 扫描 |
| 3 | **RX 数据缓冲 = 伙伴系统普通页**（`__alloc_skb`/`page_frag_alloc_align`+`__build_skb`），dma_map 后 PA 经 BAT 交给 MD 侧 DMA 写入 | `dpmaif_alloc_med_rx_buf+0x194/+0x28c` |
| 4 | **拆卸顺序**：disable_irq → `dpmaif_stop_hw`（UL/DL idle 轮询**有界**：10 万/160 万次上限，超时仅 dump+printk **继续走**）→ `dpmaif_stop_rx_sw`：`dma_unmap_page_attrs` + `ccci_free_skb`/`put_page` + `__page_frag_cache_drain` **全部归还伙伴系统**，随后 `memset(环,0,条目数<<4)`（**16B 步长**） | `dpmaif_stop+0xf4`、`dpmaif_stop_hw+0x8c..0x2d4`、`dpmaif_stop_rx_sw+0x228..0x2d0` |
| 5 | 环 PA 编入 **HW 寄存器**（`drv_dpmaif_dl_set_pit_base_addr`：MMIO 写 + dsb）；停止路径**不清理基址寄存器** | `drv_dpmaif_dl_set_pit_base_addr+0x24..0x40` |
| 6 | 触发面 = ccci MD 状态机经 **ops 函数指针表**调 `{start, pre_stop, stop, syssuspend, sysresume}`（MD 复位/异常/飞行模式/PDP 变更/系统挂起恢复）；停止握手等待 **medmcu** 协处理器 ack | 数据段 0xffffffc0090e93f0 表还原；字符串 "waiting medmcu ack"/"medmcu acked"、"sys_resume no need restore" |
| 7 | RX 数据通路流量（dmesg `[ccci1/dpmaif]net txq…`）与 ccmni2/3 活跃一致 | 设备日志 |

**结论**：被污染值 = **dpmaif BAT/PIT/FRG 环条目族**（含 0x680 环计数/长度字段 +
序号计数器）；写入者 = **MD 侧（MD 核/DPMAIF HW/medmcu）经失效环指针继续 DMA**；
受害页 = 驱动 stop/复位后**归还伙伴系统又被用户进程拿走的 RX 缓冲页/环页**。
"X 高 32 位"语义与 md 侧时钟/序号有关，未逐字段解出（不影响定性）。

### 17.3 活体捕获（pageharvest，2026-10-22 01:22–01:35）

- 3 个分配周期、**同一虚拟偏移（页尾 0xfc0 起）**反复出现
  `{0x9d9d,0}{0x9d9d,0}…` / `{0x36d1b,0}…` / `{0x20849,0}…` 的
  **16 字节节距记录**——页面是我们刚清零的新匿名页，写入发生在持有期间；
- 计数值 40,349 → 224,539 → 133,193：量级落在历史受害者值域（40K–160K）内、
  **非单调**（与受害者观测一致）；
- 首个命中周期的 **netdelta=70,459**（前后周期 55–600）——**写入与蜂窝数据
  突发同窗**；
- 同页邻接内容含 `0x10033d68c`（vmemmap/物理页指针形态）等内核侧结构残影，
  与"环页被回收复用"的页谱一致；
- 限制：`CONFIG_PROC_PAGE_MONITOR` 未启用 → pagemap 不给 PFN，kpagecount 不可读
  （该验证位缺失已记录；不影响写入事实本身）。

### 17.4 对 §16.5 候选表的更新

| 候选 | 判定 |
|---|---|
| 蜂窝 MD/ccci-dpmaif 环（含 medmcu 握手） | **坐实**（17.2 全链 + 17.3 活体） |
| WiFi 固件（mt76/connac） | 降为无关（无环常数匹配；X 跨重启存活亦排除） |
| AP 内核写错地址 | 排除（写入发生在我们的页上，AP 侧无人写它） |

md1img_a 固件**明文**（MTK 头 + md1rom，熵 6.16）——如需 MD 侧逐指令定罪
（谁写的 0x680 记录），素材在备份镜像 lba 376896 起 640MB。

### 17.5 根修路径细化（替代 §16.6 排序，仍不动手）

1. **首选（内核侧最小补丁）**：`dpmaif_stop_rx_sw`/`dpmaif_stop` 在
   **idle 等待超时/medmcu ack 异常路径上改为"泄漏不释放"**（leak-on-timeout）：
   环页与 RX 页不回伙伴系统，仅在 dpmaif 重新 start 成功后统一回收；
   同时 stop 时清 PIT/BAT 基址寄存器并要求硬件 ack 后才允许 free。
   一个 ~几十行的 out-of-tree 补丁模块即可钩住（项目已有 .ko 构建/加载先例）。
2. **LK cmdline 预留**（§16.6-B）保留为兜底：环页是 dma_alloc 动态页，
   仅当证实失效 PA 跨重启稳定时才可行——优先级下调。
3. EMI MPU（§16.6-C）保留为最后手段。
4. 缓解层与监控维持 §16.6-5；`ap_auto_logging=0` 等不变。
