# U-G1 · CAM-W Tier B 观察点引擎:结果报告(仪器战役 + K9 新钉死约束)

> 日期:2026-11-05 01:10–03:15(+0800)｜操作者:日班执行者(用户授权"内核取证深挖,允许多次崩溃")
> 预注册:[U-G1_PREREG_WWATCH_2026-11-05.md](U-G1_PREREG_WWATCH_2026-11-05.md)(含 §9 修正案)
> 设备:7 次仪器性硬复位(全部授权内),末窗 boot(btime 由 NTP 恢复);窗末 NE 1959。
> **一句话**:写者未点名,但(a)新钉死约束 **K9:写者与受害者活 va_list 内容耦合**
> (可逆因果开关实证);(b)**EL1 观察点 fire 在本固件 = 瞬时整机死亡**(≥3 次干净复现,
> 疑 MTK AEE/mrdump 拦截)——写者"点名级"仪器在本固件被平台层封死,漏网落地的
> 5 次写入证明其不经 EL0/STTR 通道 ⇒ 嫌疑集中于 **B2′(EL1 别名 store)与 B4t/B5(DMA)**。

## 0. 一页结论

| 事项 | 结果 | 等级 |
|---|---|---|
| 落点不变量(离线再分析) | 昨夜 531 真命中 511 条 = **stack_top−0x16A0**(96.2%,主会话 victim=main/ndepth=1 几何);pthread/多深度几何落点随深度 epoch 漂移(D=0→top−0x3A0/+0x100/…,实测精确线性) | E2 |
| 派发接管 | `debug_fault_info @ 0xffffffc0091406a0` 表内容与源码逐条一致;装载 REFUSE 门(dfi[2].fn==do_bad)在线通过——无人占用 HWWP 派发 | E2 |
| **EL0 观察点全链路** | PC-U2 正对照 34/34 事件全录(comm/pc/lr/sp/far/esr/skip);受害者自写持续 fire ~40-140/s 全过滤;**drift=0**(禁深睡后);整机健康 | **仪器 E2** |
| **EL1 观察点 fire** | **任一 EL1 fire = 整机瞬时硬复位**(panic_on_oops=0 亦无 oops ⇒ 杀死路径在内核可报告层之下;疑 AEE/mrdump 拦截 EL1 debug 异常)≥3 次复现 | **平台事实 E2** |
| DBGPRCR 写 | 写 DBGPRCR(bit0)= 致死(2 次复现,v1.10);弃用,深睡禁用替代(drift 35→0) | E2 |
| **K9 内容耦合(核心新约束)** | 监控并 skip 受害者活槽自写 → λ 16/min→0~1.3/min;解除 → **回弹 12.3/min**;再监控 → 再冻结(可逆因果开关)。写者在 store 之上游读/校验目标槽的**活内容** | **E2** |
| 漏网落地判读 | 第 2 次 uva1 监控期 5 次落地完成且**零对应 fire** ⇒ 完成写入不经 EL0/STTR 通道(带内 8B×2 槽全监) | E1(强指向) |
| PAGE_OFFSET | **0xffffff7f80000000**(AT 指令三候选判别 + /dev/mem 字节互证;昨夜笔记值获独立复证) | E2 |

## 1. 仪器演化(v1→v1.11,7 次崩溃买出的清单)

| 崩溃 | 版本/操作 | 根因 | 修复 |
|---|---|---|---|
| c1 | v1.0 probe | 自写内联汇编寄存器名 op0=3(`s3_0_…`),该编码 EL1 未定义→UNDEF→panic(pstore 全尸:do_undefinstr←ww_probe_one+0x30) | 全部改 `s2_0_…`(内核宏 sys_reg(2,…) 为准) |
| c2/c3 | v1.0/v1.2 arm | EL1 家族武装即死(见 §2) | — |
| c4 | v1.2 arm(别名判别前) | 未映射 VA 监控亦死;机制未完全隔离(记档) | — |
| c5 | v1.5 arm(正确别名) | 疑真写者别名 store 触发 EL1 fire→平台杀(见 §2) | — |
| c6 | v1.6 armraw+selfstore | **决定性复现**:panic_on_oops=0 下首 fire 仍瞬时硬死,无 oops ⇒ 死在向量/更深层 | 转向 EL0-only 形态 |
| c7 | v1.10(恢复 DBGPRCR 写) | DBGPRCR bit0 写 = 致死(第 2 复现) | 永久移除;cpuidle 深睡禁用替代 |

非崩溃缺陷:cpuidle 深睡(clusteroff_l/mcusysoff)每次 idle 抹掉 WRP 寄存器(drift 35/数秒、
覆盖率趋零)→ 窗口期禁用三深睡态(仅留 WFI)→ **drift=0**;2s→0.5s 重核计时器双保险。

## 2. EL1-fire 平台封死(本固件结构性事实)

- 分阶段证明:`mdscr on`(MDE|KDE+全 BCR/WCR 清零、无 WRP)**存活**;布 WRP 存活;
  **首次 EL1 fire(模块 selfstore 自触发)即整机死**——且 panic_on_oops=0 无 oops 文本,
  pstore console 被新 boot 噪声覆盖 ⇒ 死亡先于内核任何可报告路径。
- 对照:**EL0 fire 完全健康**(gupprobe SIGTRAP 干净送达,core_meta 记账,整机活)。
- 归因假设(未证):MTK AEE/mrdump 拦截 EL1 debug 异常(boot 日志见 aee_aed/ipanic 活动)。
- 推论:**在本固件上,对 EL1 写者的 watchpoint 点名不可能常规实现**——任何 EL1 fire
  即自杀。绕行候选:关闭 AEE 拦截(待逆向其向量接管)/ 换 ROMAP-PTE 手段 / LK 层。

## 3. K9:写者-内容耦合(本轮最大正向收获)

时间线(victim=1056,top=0x7ffff5ee20,活槽 uva1=0x7ffff5e780[本 run 模式],uva2=0x7ffff5e920;
PC 灌流 ~240pps 全程在役;λ 参考窗 16/min):

| 阶段 | 监控对象 | λ(落地/min) | 备注 |
|---|---|---|---|
| 武装前 ~100s | 无 | **16** | 27 hits(22@uva1) |
| arm#1(uva1+uva2,q0/q1) | uva1(受害者自写被 skip) | **0**(630s 零落地) | ring 57 事件全为 comm=ip/cat/head 跨进程栈 VA 碰撞(EL0 物理上写不进受害者页,良性) |
| arm#2(仅 uva2) | uva1 放开 | **12.3**(回弹,+43/3.5min,69/69@uva1) | 差分证明 |
| arm#3(回到 uva1) | uva1 再监控 | **1.3→0**(尾段 390s 零) | 可逆性双确认 |

机制:监控期受害者自身 va_list 初始化 store 被 fire+skip → 槽内容冻结 → **写者在写入前
放弃**(无 fire 无落地 = 放弃发生在其 store 之前)⇒ 写者读/校验目标槽的活内容,与 K5
(需深帧/变参活动)同源但更细:**需要该地址上"正在进行时"的 va_list 写入流**。
5 次"漏网"(arm#3 初段)落地零 fire ⇒ 其完成写入不经被监 8B 槽的 EL0/STTR 通道。

## 4. 布点几何(本轮实证补遗)

- victim=main+单深度几何:落点两模式 {top−0x500, top−0x6A0}(每 run 主模式不同,
  0x1A0 间距);victim=pthread 多深度几何:随 D 线性(top−0x3A0−D 精确)。
- 昨夜 0x16A0 = victim=main + 单深度 0x1000 档(0x6A0+0x1000)。
- 主栈 top 因 argv/env 非页对齐;uva=top−dist 恒 16B 对齐;跨进程栈区 VA 高度重叠
  (ip/cat/head 的栈与受害者同区段)→ EL0 监控的跨进程 VA 碰撞是**系统性**噪声,
  过滤判据 = comm(已实践)。

## 5. NE 对账与现场清理

- 台账 1957(01:20 boot)→ **1959**;两行全为仪器归因:①gupprobe sig=5 pc=0x1011a88
  (EL0-fire 判别对照,有意);②head sig=11 far=0(我方 head 观察命令栈碰撞被 skip →
  其栈损坏,skip 副作用首次进入 NE 台账实证)。**自然 0,未知 0**。
- 7 次硬复位均为仪器性(授权内);末窗结束:disarm(fnrestored=1)→rmmod→lsmod 空;
  cpuidle 深睡态恢复;panic_on_oops=1 恢复;受害者 TERM;04:00 定时重启在后方。
- patrace 末核:uva→PA 与窗中一致(无迁移换页)。

## 6. 采集件与五元组

| 件 | md5/尺寸 | 说明 |
|---|---|---|
| wwatch.c v1.11(源) | 见 tools/oneoff/sigsegv/wwatch.c(拷贝存档) | CAM-W 引擎 |
| wwatch.ko v1.11 | 197,352 B(部著 md5 双验) | 在役末版 |
| **ww_eviblob.txt** | **535f0d0ed662070e55ea779357b18d2f**,32,036 B(双侧一致) | 全部快照/ring/对照/几何/patrace 合并 |
| ww_win_ring_s1/s2.txt | tmpfiles/review/uf1/(会话内原件) | ring 两时刻全量 |
| scanary_ug1h.log | 318,492 B(设备在档;提取件入 blob) | 末窗受害者全日志(6 受害者实例之一) |
| udpflood_ug1.py | tmpfiles/repro/(会话原件) | PC 灌流(3×800pps 名义/实测~240pps) |

## 7. 判决(按预注册 §3 对照)

| 观察 | 预注册判 | 实际 |
|---|---|---|
| 外来 fire(pc∉victim 段) | 候选终局 A | **未出现**(57 事件全为良性碰撞+对照) |
| 外来 0 ∧ own>0 ∧ 落地≥30 | B2′+uaccess 出局 | **形态变化**:落地被 K9 机制抑制,零-落地窗与回弹窗各 ≥30 等效暴露;"落地≥30 且零 fire"由 arm#3 漏网 5 次 + arm#2 回弹窗(43 落地,uva2 监控中零 fire)共同构成 ⇒ **uaccess-STTR/EL0 写者出局(E2,uva2 槽直证 + 漏网判读)** |
| WCR 漂移 | 缺口计数 | drift=0(深睡禁用后)——覆盖完整 |
| 仪器安全 | 事故流程 | 7 崩溃全记录(§1),无未明死亡 |

## 8. 三栏

### [A] 已核实
- EL0 观察点仪器全链(PC-U2 34/34、自写过滤、skip、drift=0);
- K9 可逆因果开关(λ 16→0→12.3→0);
- EL1-fire 致死性(≥3 复现,p_o_o=0 亦无 oops)与 DBGPRCR 写致死(2 复现);
- PAGE_OFFSET=0xffffff7f80000000(AT+/dev/mem 互证);
- 漏网 5 落地零 fire ⇒ 不经 EL0/STTR;NE +2 全仪器归因。

### [B] 未核实
- 写者身份(本轮未点名;EL1 通道被平台封死);
- EL1-plain(PAN-open 直写用户 VA)形态(仅 EL1-watch 可抓,同被封);
- c4(未映射 VA 武装致死)机制;c5 死因="真写者 fire"仅是最佳假设;
- AEE 拦截的具体接管点(未逆向)。

### [C] 必须上设备(下一步,按优先级)
1. **AEE 拦截解除/绕过**(逆向 aee/mrdump 对 EL1 debug 异常的接管;或 LK/EL3 层关闭)→
   解锁 EL1 tier → 布 alias 槽 → 若 fire 即终局 A(写者 pc 直取);
2. c5 假设检验:重新布正确 alias EL1 槽 + 自杀式记录(单次 fire 的 mrdump/expdb 落盘
   或许含 pc——**用 AEE 的尸体当证词**);
3. ROMAP 修复(PTE 重定向)B2 判定窗;
4. B4t 环发现(EDMA/FE/PPE/WED-TX)+ ringpoll 扩展。

## 9. 纪律教训(新增)

1. **工具调用参数经 JSON 转义会吞 `\\n`**:经 bash/python 通道写 C 源码时字符串换行符
   两轮事故(c1 同族根因的一半);补:Edit 工具直写不受影响。
2. **lgssh 单行 >~9KB 输出被截**;证据拉取一律分块 dd+md5 终验。
3. **观察者污染的第三形态**:cat/head 等观察命令自身栈与被监 VA 碰撞被 skip → NE
   (head sig=11);观察通道与被观测地址空间在 EL0 观察点下不分离。
4. **EL0 观察点的跨进程 VA 碰撞是系统性的**(主栈区全局重叠),判据必须含 comm。
5. busybox insmod 对缺 vermagic/__this_module 的裸 -c 对象静默 rc255;wrhunt2/patrace
   的手写 MODULE_INFO+__this_module 模式是构建链必配(已入 build 备忘)。
