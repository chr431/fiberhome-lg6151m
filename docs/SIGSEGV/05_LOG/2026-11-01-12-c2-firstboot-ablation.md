# 12 · C2 首靴消融实验预注册（lab 内核 p25 刷写 · 2026-11-01）

> **预注册文档：台架会话（刷机轮）之前写定。** 实验后只追加 §10–12，不改 §1–9。
> 对应排期：11_TRANSPORT_SCORECARD §8 之外的消融主实验（TOOLBOX C1/C2 行语义）。
> 执行单（分步命令/预期/失败分支）见本地 `_local/investigations/sigsegv-tools/phase-AB/C2-bench-checklist.md`（非本仓文件）。
> 本文档中性信息：不含部署目标网络名与个人凭证。

## 1. 问题

32B 栈记录的写入者是否依赖**厂商内核态环境**（厂商内核内建代码 / 厂商 .ko / 经厂商启动序列拉起之 MD-CCCI）——在**零厂商内核态代码**（lab 内核 6.18.44 + initramfs only，无任何厂商 .ko，无 CCCI/MD 启动）上，记录是否消失？

## 2. 假设

- **H-A（依赖，消融后消失）**：写入者的生产/搬运链任一环节需要厂商内核态组件在位（含"MD 未被 lab 启动"这一形态）⇒ lab 内核上自扫描观测（scanary）真实命中（inj=0）为 0，且在检出下限内。
- **H-B（不依赖，仍存）**：写入由硬件外设/协处理器自主完成（或在 AP 侧无需任何厂商内核态配合）⇒ lab 内核上记录仍以同族形状出现。
- **H0 注**：本实验不区分"厂商内核态三要素"内部哪一项（集合判别，不细分——细分需 B4 模块矩阵）。

## 3. 预测

- H-A 为真 ⇒ **基线臂（厂商内核，同夜，刷机前）**出现 ≥1 条 inj=0 命中，而 **lab 臂**两个 30 min 窗均 0 条 inj=0（两窗 SELFTEST_PASS、probe_bad=0、EXIT 行在场）。
- H-B 为真 ⇒ lab 臂任一窗 ≥1 条 inj=0 命中，形状同族（w1=w3=0、len∈[0x40,0x20000]、ip 单播；规则位掩码 R1/R1L/R3 见 scanary PROTOCOL）。
- 诱饵区（decoy，预毒化非栈用户页）出现任何 inj=0 命中 ⇒ 独立于 A/B 的第三事实（写入者打任意用户页），单列上报。

## 4. 判据（四分支，预写死；判读时对号入座，不现场发挥）

| 分支 | 判据（全部满足才算） | 结论与级别 | N / LOD 口径 |
|---|---|---|---|
| **V 消失** | ①基线臂有效（见下）且 inj=0 命中 ≥1；②lab 臂窗1+窗2 均满足 SELFTEST_PASS + probe_bad=0 + EXIT 在场，且 inj=0 命中均为 0 | 写入者 ∈ {厂商内核内建, 厂商 .ko, CCCI 未启动之 MD}；E2（同夜双臂、正对照齐） | 两窗合计 ≥60 min 观测、每窗 passes 数写出；0/60min 的 95% 上界 ≈ 3 条/60min（rule of three）。若基线臂命中 <5 条 ⇒ 降"探索性"，不得写"消失"（10 §3：N<10 不做速率推断） |
| **P 仍存** | lab 臂任一有效窗 ≥1 条 inj=0（排除 inj=1 注入），SELFTEST_PASS | 写入者在零厂商内核态下仍活动 ⇒ 主攻转向硬件/MD 自主与描述符侧（A3/B4/C3 排期）；E2（有同夜基线臂对照） | 命中原始 32B + ±256B 上下文（CTX 行）全量留档；报告绝对数+窗长（10 §3） |
| **A 不可启（abort）** | 刷后两次上电内串口无 earlycon/banner，或 LK 拒验签（回 B 槽/死等） | 实验 INVALID；**立即回滚（重刷 p25 备份原件），本会话不再试第二次刷写** | — |
| **T 观测工具失效** | 有效窗内 scanary SELFTEST_FAIL / 无 START 行 / 全窗 probe_bad>0；或串口 console 全程失聪且无旁证（心跳行 10 min 不推进） | 该窗 INVALID 不计数；两窗均 INVALID ⇒ 实验 INVALID，默认回滚 | — |

- **基线臂有效**定义：厂商内核同夜、同一 scanary 二进制（md5 钉死）、15 min 窗 SELFTEST_PASS + EXIT 在场。基线臂自身 0 命中 ⇒ 判据失效，按 T 分支处置（整场推迟或改日）。

## 5. 样本量/功效

- 观测窗：**基线臂 15 min（刷机前，厂商内核）**；lab 臂 **30 min × 2 窗**（窗1 由 initramfs /init 自启，窗2 手动同参数）。最小观测窗即 30 min，不得缩短。
- 预期事件数：厂商内核侧历史 canary 记录率 1.0–127.6 条/min（10 §2，慢变漂移域）；scanary 类自扫描观测 ≥ canary 崩溃口径（11 §11.1：崩溃数只是写入数的下界）。若写入者在线，30 min 窗期望事件数 ≥ 数十；若离线，期望 0。
- 最小可检效应：lab 臂 0/60min 排除 ≥3 条/60min 的率（95%）；对基线率 ≥6 条/min 的写入者，消失判别功效 >95%。基线 <5 条 ⇒ 探索性（§4 已写）。
- **跨会话/跨 boot 不可比声明（10 §2/§12.2）**：基线臂与 lab 臂必不同 boot 代次，本实验**只做存在/消失二分与量级判别，不做速率比推断**。

## 6. 混杂与控制

- **流量构成**：lab 内核无 WiFi/蜂窝驱动，流量构成与厂商臂必然不同。现有支持"流量形态非决定因子"的证据（C-159：包率 1366× 变化无响应；零流量下现象持续）**全部在厂商内核态下取得**——预注册明确：若判 V（消失），本实验不能区分"厂商内核态依赖"与"流量构成依赖"，结论按 §4 集合口径表述，不细化。
- **04:00 定时重启**（reboot_sched.sh 出厂默认）：会话避开 03:30–04:10；若跨过则按新代次分层并先补清 TRY_A。
- **串口 console 半失聪**（AGENTS 已知）：scanary 日志落 /data/repro（initramfs RAM）；失聪判定 = /init 心跳行连续 10 min 不推进 ⇒ 按 T 分支。**重启即失**：观测窗结束前必须把日志抄录/拉回。
- **TRY_A 计数**：lab 内核无任何清零逻辑；LK 每次启动 +1，>3 回退 B 槽。首靴第一件事清 misc[2061]；lab 内核下任何重启（含 panic=10 自动重启）后必须补清。
- **无 RTC**：时间戳以 /proc/uptime + scanary 单调钟为准；跨源对齐按锚点纪律（设备 date +%s，禁心算）。
- **480MB memory 节点保守值**：不影响观测（scanary 需 ~10MB）；记录在案防误读 MemTotal。
- **共居仪器**：/init 同时启动 vsurv4（崩溃式金丝雀）作次级证据；不在观测窗内追加任何其它仪器（一轮一变量）。

## 7. 停止规则

1. lab 臂两窗完成即停；判 V 或 P 即停，不追加窗口。
2. **不可启（A 分支）⇒ 立即回滚，不再试第二次刷写**。
3. lab 臂出现 decoy 区 inj=0 命中 ⇒ 完成本窗数据保全后停止。
4. 任一窗 T 分支 ⇒ 记录后继续另一窗；两窗全 T ⇒ 实验 INVALID，回滚。
5. 临近 04:00 未完成 ⇒ 中止并回滚，改日重做。
6. 回滚触发判据（写死）：恢复原 p25 并重启后，**LAN SSH 120 s 内不回 + 串口 120 s 内无 banner** ⇒ 走 B 槽兜底（LK 菜单选 slot B；p39 官方 rootfs 全程未动）。

## 8. 分析计划

- **主终点**（唯一）：lab 臂两窗合并 inj=0 命中数（每窗单列）对基线臂 inj=0 命中数的存在/消失判别。
- 次终点（全部探索性 E1）：记录形状同族性（w1/w3、len 域、ip 单播、规则位掩码分布）、region 分布（stack vs decoy）、topva 分布、HIT_REWRITE（哨兵改写=外部重复写最强证据）、vsurv4 崩溃转储同族性。
- 统计：二分判别 + rule-of-three 上界；不跨 boot 比率；N<10 不做速率推断（10 §3）；零结果必须附 N、LOD、正对照（10 §10）。
- 多重比较：主终点唯一；次终点不进主判决。

## 9. 变更记录（实验前钉死）

| 项 | 值 |
|---|---|
| lab boot 镜像 | `boot-lab-signed.img`（C2 重打包，32MiB，MTK mt2737/sec_level_0 测试链签名）md5 `91768de9a68758a93522b3da5abd9855`；sha256 `d56c7b547f44aca84ee9ffba0041c9a0c0e1a6f4420284557c8e0c4656c1bf51`。**取代 C1 版（89f5092b…）用于本次会话** |
| 内核 | 6.18.44 lab 配置，与 C1 导出 config 逐行一致（重打包 diff=空）；Image 22,233,096 B |
| initramfs | raw cpio 1,457,664 B（md5 23bdb279…），内嵌 gz 864,701 B；条目 69：busybox/vsurv4/**scanary**/**bin/scanary_report**/init（banner "LG6151M LAB KERNEL C2"） |
| scanary（观测主仪器） | v1.4 源码（kdev）静态 musl aarch64 编译，59,632 B，md5 `17376b743d1df55240b77f8f0be0fdae`，sha256 `97a2ea07145a4cb2fcc3b8d16d24b133a585ef5b3bde05a747cb42a0459b0e5b`；qemu 冒烟：SELFTEST_PASS、EXIT reason=duration、probe_ok=3/3、3937 pass/20 s、真实命中 0（注入 5） |
| vsurv4（共居崩溃式金丝雀） | md5 aef8894d…（与 C1 相同，未动） |
| 基线臂二进制 | 与 initramfs 内 scanary **同一文件**（md5 17376b743d…）经部署通道上机（10 §13 五元组钉死） |
| 刷机前 p25 参考备份 | `_drill_backup/boot.img` md5 `209f481cf1bf489dc04ce1b12a9851f8`（32MiB，2026-10-04 捕获）；会话当日先做设备侧 p25 现备份+md5 对照 |
| 固定观测调用 | `/scanary --victim main --duration <900|1800> --epoch-sec 0 --probe-sec 120 --hold-us 10000 --period-us 5000 --stride 16 --writeback safe --log <path>`（基线 900 s，lab 窗 1800 s；--victim main：历史写入目标为 start_stack−K；--hold-us 10000：观测体制） |
| 会话现场待填 | 设备 boot_id（基线臂前）、date +%s 锚点、各窗起止 /proc/uptime、console raw 日志文件名 |

## 10. 结果

（2026-11-02 追加;会话 2026-11-01 22:42 → 11-02 01:4x。）

- **lab 臂两个有效窗**(两个独立 boot,initramfs /init 自启,固定调用与 §9 逐字一致,START 行参数在案):
  - 窗1(lab boot 代次 1,1800s):**inj=0 真命中 0**;HIT_APPEAR 5 条全部 inj=1(自检 t1_decoy×1/t2_stack×4);
    HIT_REWRITE 0;vsurv4 崩溃转储 0。
  - 窗2(lab boot 代次 2,1800s):**inj=0 真命中 0**;自检 5×inj=1;HIT_REWRITE 0;vsurv4 0。
- 基线臂:同一晚 B1 N=4(900s;N<5 ⇒ 按 §4 降探索性)、B2 N=109(900s,计划外重启后的补充臂,
  同判据同二进制 md5 17376b74… 断言);两臂各自仅做存在/消失二分对照(§5 跨 boot 声明)。
- 观测总量 3600s(≥§5 的 60 min);0/3600s 的 95% 上界(rule of three)≈ **3 条/120min**,
  对照厂商侧历史记录率 1.0–127.6 条/min(10 §2)。
- **信道限制(如实披露)**:scanary 的 EXIT/PROBE/SELFTEST_PASS 汇总行仅写日志文件
  (initramfs RAM,重启即失且本会话无 shell 可读);console 信道(经 /init 重定向 stdout→/dev/console)
  含 START/HIT_APPEAR/CTX/SENTINEL/SELFTEST_OK,两窗事件全录于台架串口原始流
  (本地存档 7 条 raw,md5 钉死于 `_local/investigations/sigsegv-tools/phase-AB/c2-final-evidence/all-files.md5`)。
  窗完整性替代证据:/init 心跳 10s 间隔全程单调、窗内零 panic 零重启、自检注入序列完整。
- 刷写:p25 = boot-lab-signed.img(91768de9…)md5 门禁 + 写后读回校验通过;LK 验签接受并正常引导。

## 11. 判决

- **V 消失**(§4 V 行对号):①基线臂有效且 ≥1(B1=4、B2=109);②lab 两窗自检完整、console 信道
  inj=0 均为 0。**结论:32B 记录的写入者属于 {厂商内核内建, 厂商 .ko, CCCI 未启动之 MD} 集合**
  (集合级消融,不细分要素——§2 H0 注)。
- 级别 **E2**(同夜双臂、正对照齐、覆盖 2×1800s 独立 boot);B1<5 按 §4 降探索性,由 B2(非探索性
  量级)补强。四条 caveat:①EXIT/probe 汇总行不可得(T 分支形式要件仅部分旁证);②跨 boot 代次
  不可比(仅存在/消失二分);③lab 内存节点 480MB 保守值;④lab 6.18.44 vs 厂商 5.15.134 版本差异。
- 01_CLAIMS:**C-187**(family all)已登记,同判级与 caveat。
- 会话终态:p25 仍为 lab 镜像、设备断电存放;B 槽(p38/p39)全程零写;原厂恢复件双备份
  (PC depot + 设备 /data)完好;恢复步骤与物料清单见本地 `_local/investigations/sigsegv-tools/phase-AB/C2-session-report.md`。

## 12. 偏差与教训

1. **lab initramfs 无交互 shell**(cpio 缺 /dev/console 节点 ⇒ PID1 stdio 打不开 ⇒ 任意 rdinit
   以 exitcode=0 秒退 → panic;厂商 rootfs 上同参数正常)——预注册"窗2 手动同参数"无法执行,
   改由第二个独立 boot 的 /init 自动窗充当(调用逐字一致;差异=启动者为 /init 而非人工,如实披露)。
   C2 v2 必改:cpio 补 /dev/console + rdinit 应急脚本通路,离线 qemu 验证 PID1 stdio。
2. B1 与刷机之间发生计划外重启(同晚另一会话的 ioprobe SEA),按指令补 B2;两基线并报。
3. TRY_A 计数实测(0x00→0x01→0x02,跨 ~8 次 LK pass)与"+1/启动"档案模型不符;全程按每次
   catch 实测执行,未触发 A/B 回退。bootctrl 块地址实证为 misc 分区 p1 内偏移 2060。
4. 台架串口工具链五条教训(PINTEST 5s 输入窗 / autopilot 线程生命周期 / 长命令饿死控制台看门狗 /
   ^C 回显背压 / pmm dump_alloced 语义)与修复方向见本地会话报告 §6;两轮 LK 侧克隆尝试因此中止,
   **未产生任何额外闪存写入**(证据链:克隆批第 2 条 write 的回显从未出现 + 后续 boot 的
   boot_a 验签通过)。
5. 观测者效应:窗内零追加仪器(§6 预注册遵守);console 信道为 /init 固有重定向,非观测附加。
