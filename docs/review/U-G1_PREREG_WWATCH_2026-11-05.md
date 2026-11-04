# U-G1 · 预注册:CAM-W Tier B 观察点引擎(watch)联合窗

> 写定时间:2026-11-05 01:35(+0800),任何数据产生**之前**。
> 依据:[12_WRITER_ID_SUITE_DESIGN.md](../SIGSEGV/12_WRITER_ID_SUITE_DESIGN.md) CAM-W Tier B;
> 用户授权:内核取证深挖,允许可控崩溃。
> 手法谱系:数据面 = wrhunt2 全套纪律(REFUSE 门/回读/NE 对账);
> 新面 = arm64 自托管调试观察点(WRP)直编程 + `debug_fault_info[2]` 派发接管。

## 0. 仪器原理(一段话)

落点不变量(昨夜 531 真命中 96.2%):**记录落在 stack_top−0x16A0 的 8 字节 qword**,
跨 4 个受害者会话一致,先验可知。在 4×DBGWVR/WCR 上布 4 个 store-only 观察点
覆盖该 qword 的全部软件写入通道,fire 时处理器在**写入现场**抛精确 watchpoint
异常,派发表 `debug_fault_info[2]`(本内核无 hw_breakpoint 框架,原值为 do_bad)
被替换为记录器:记录 {pc, lr, sp, far, esr, pstate, comm, pid} 后
**regs->pc += 4(跳过该 store)并 return 0(吞掉异常)**——系统不崩、可反复触发。

| 槽 | VA | PAC | 抓什么 |
|---|---|---|---|
| W0 | uva+0 | EL0 | EL0 写 + **内核 STTR(uaccess store 只匹配 EL0 配置)**;handler 内过滤 pc∈受害者主程序段 |
| W1 | uva+0 | EL1 | 内核 PAN-open 直写用户 VA(plain str) |
| W2 | alias+0 | EL1 | **kmap/线性别名 store(B2′ 主形态)** |
| W3 | alias+8 | EL1 | 别名 16B stp 副翼 |

不 fire 的写入方式只剩:**DMA/总线主(不经 PE 执行)**与 EL2/EL3(B5)。

## 1. 问题(一句话可判决)

写入 32B 记录的 store 指令是否由本 SoC 的 PE(EL0 或 EL1)执行?
若是→pc 即写者身份证;若否(武装窗内零外来 fire 而落地持续)→软件写者出局。

## 2. 假设与预测

- **H1(软件写者在场,B2′/B2-uaccess/内核直写)**:主窗内出现 `pc∉受害者主程序段`
  的 fire 事件;`far==uva 或 alias` 确认槽位;`pc` 反解 vmlinux/模块/受害二进制 → 候选终局 A。
- **H0(PE 不执行该 store)**:外来 fire = 0,而
  ① `dropped_own > 0`(W0 对受害者自身写持续命中 = 观察点对该地址活性实证),
  ② 同窗 scanary 真命中(inj=0)≥30(若写者未被我们吓退;注意 fire+skip 会吃掉落地,
  见 §5-4),
  ③ 正对照 PC-K/PC-STTR 全过 ⇒ **B2′(别名 store)+ B2-uaccess + B1 残余全部出局(E2)**,
  剩 B4t(DMA 环)/B5。

## 3. 判据(数值边界)

| 观察 | 判 |
|---|---|
| 任一外来事件(pc∉victim 段) | **候选终局 A**:pc/lr/comm 归属反解;二次窗复现同 pc → E3;压制复测 λ→0 → E4 |
| 外来 0 ∧ dropped_own>0 ∧ 落地≥30 ∧ 对照过 | **B2′+uaccess 直写出局(E2)** |
| 外来 0 ∧ dropped_own=0 | 观察点未覆盖活地址(布点失败)→ 本窗作废,查布点 |
| WCR 漂移计数 >0 且重写成功 | 记录在案;若漂移期间有落地 → 该时段计为覆盖缺口,窗口延长补足 30 落地 |
| 装载/武装后 10 min oops/NE 异常 | 卸载作废本轮,按事故流程(类 C-220) |
| PA 中途漂移(前后 patrace 不一致) | 记录;别名槽以旧 PA 失效时段计缺口,窗口延长 |

## 4. 暴露核算

- λ 近窗基线 3.6–10.6/min;主窗 ≥1200 s 期望落地 ≥43;不足 30 时延长窗口或 PC 灌流。
- 布点前验:受害者先跑 ≥3 条真命中确认 dist==0x16A0(不变量在本会话成立)才武装。

## 5. 混杂与处置

1. **受害者自我写洪泛**(变参 callee 每迭代自建 va_list 于同一 qword):
   W0 事件 pc∈受害者主程序段 → handler 计数 `dropped_own` 丢弃(进 ring 的只剩内核/外来 pc)。
   该计数同时是"观察点对活地址在匹配"的原位正对照。
2. **cpuidle 深睡(clusteroff_l/mcusysoff)丢观察点寄存器**:DBGPRCR.CORENPDRGG=1
   + 2s 重核计时器(漂移即重写并计数,计数本身就是仪器输出)。
3. **栈页迁移换 PA**:武装前/窗中/窗后三次 patrace 核 PA;不一致按 §3 缺口处理。
4. **fire+skip 吃掉落地**:软件写者首个 store 被 fire 后整条指令被跳过,记录可能不完整
   (scanary 侧表现为落地减少/残缺)——这是仪器效应不是 λ 下降;判读以 fire 事件为准。
5. **页迁移/compaction 的内核 memcpy**:合法别名 store 会 fire,pc∈migrate/copy 族,comm=谁
   触发迁移——记为良性行,预注册排除。
6. **panic_on_oops=1(当前设备值)**:handler 吞异常路径不进 die;若仪器缺陷导致 oops,
   设备重启(授权范围内),pstore 取证。

## 6. 正对照(缺则阴性 E0)

| # | 动作 | 预期 |
|---|---|---|
| PC-K | `selfstore`(模块对 alias+0 直写 8B) | W2 fire:pc=wwatch 模块内,comm=shell 写者 |
| PC-STTR | `vmwrite32 <pid> <uva> <32B>`(process_vm_writev→kmap memcpy) | W2 fire:pc∈memcpy/__access_remote_vm 链,comm=vmwrite32 |
| PC-ACT | 主窗内 `dropped_own>0` | W0 对该 qword 的 EL0 匹配活性 |
| PD | disarm 后重复 PC-K | 无 fire(解除语义) |

## 7. 装置与安全

- **wwatch.ko v1**:参数 dfi=0xffffffc0091406a0、dobad=0xffffffc0081267a4
  (装载 REFUSE 门:读 dfi[2].fn 必须==dobad,name 含 "watchpoint";不符即拒载——
  若不符本身即发现"有人先占了 watchpoint 派发")。
- 寄存器操作全部 per-CPU(smp_call_function_single 遍历 online cpus);
  原值先存后改,卸载逐项恢复+回读;MDSCR 只增 MDE|KDE,卸载还原;
  WCR 编码 = E|PAC(EL0=10b/EL1=01b)|LSC=store|BAS=8B(内核 hw_breakpoint.h 同源)。
- handler:NMI-safe(无锁无分配无 printk),全局 ring 64 槽原子索引,percpu 计数。
- 卸载前置:必须先 disarm;卸载后 lsmod 空 + dfi[2].fn 回读==do_bad。
- NE 台账前后对账(当前基线 **1957** @01:20);04:00 定时重启在役,全部窗口止于 03:50。
- LK 救砖链可用;romap 仍隔离不参与本轮。

## 8. Skeptic 自审清单(武装前逐项打勾)

1. ☐ dfi[2] 现值==do_bad(REFUSE 门)且 name=="hardware watchpoint"
2. ☐ probe:ID_AA64DFR0.WRPs≥2;OSLSR OSLK=0;4 CPU 全采样在案
3. ☐ 布点前 ≥3 真命中 dist==0x16A0;uva=top−0x16A0 8B 对齐
4. ☐ patrace PA 与 alias 通道互证(模块读 alias 与 /dev/mem 读 pa 字节一致)后才 selfstore
5. ☐ 受害者主程序段 [vtlo,vthi) 取自 /proc/pid/maps exe 可执行段,宁大勿小
6. ☐ PC-K/PC-STTR 事件 pc 归属可反解(模块内/内核链)才开主窗
7. ☐ handler 过滤只丢 pc∈[vtlo,vthi);其余全部进 ring(包括意外 comm)
8. ☐ 主窗期间不加载/卸载其他模块;patrace 只读查询
9. ☐ 时间预算:主窗 ≤03:50 结束;文档与卸载在 04:00 重启前完成

## 9. 变更记录

- (结果后追加,不改本文正文)

## 9. 变更记录(执行中修正,均在数据产生前后如实入档)

1. §0/槽位修正(任何 arm 之前):取消 EL0 配置的 W0 原设计(受害者变参 callee 每次
   迭代自写该 qword,EL0 监控必洪泛且 skip 毁受害者执行)→ 后在判别实验后恢复
   EL0-only 形态(v1.9,带 comm+pc 过滤)。全 EL1 布防方案因 §2 平台事实被否。
2. §6 正对照修正:PC-K/PC-STTR 因 EL1-fire 致死不可执行,替换为 PC-U2
   (gupprobe 用户态 store,34/34 全录);PC-ACT 由 own 过滤计数承担。
3. §4 λ 条款执行:灌流开(240pps 实测),λ 参考窗 16/min 达标。
4. 主窗形态变化(执行中):arm#1 出现 λ 塌缩 → 识别为受害者自写被 skip 的扰动 →
   改 arm#2(仅 uva2)取得回弹差分 → arm#3 复冻(可逆性);"落地≥30" 以
   回弹窗 43 落地 + arm#3 漏网 5 落地共同构成,原文数值边界按此解读。
5. 事故:c1 编码 UNDF、c7 DBGPRCR——全部入 U-G1_RESULT §1。
