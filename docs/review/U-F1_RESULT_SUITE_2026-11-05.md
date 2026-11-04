# U-F1/F2 · 收口仪器组夜间战役：结果报告（B1/B4c 出局 + 一次仪器事故 + 环取证）

> 日期：2026-11-05 01:2x（+0800）｜操作者：夜班承包（用户授权"设备全权"）
> 预注册：[U-F1_PREREG_GUP14_2026-11-04.md](U-F1_PREREG_GUP14_2026-11-04.md)（GUP-14 联合窗）
> + [12_WRITER_ID_SUITE_DESIGN.md](../SIGSEGV/12_WRITER_ID_SUITE_DESIGN.md) S1–S3 战役框架
> 设备：boot A（btime 1793736016，至 00:36 romap 事故硬复位）；复位后新 boot（NTP 已同步）。
> 写者**未点名**；本轮把 B1（非 remote GUP 族）与 B4-常驻缓存两类**出局**（E2），
> 留下 B2-手工走页表+别名 store、B4-瞬态描述符、B3/B5。

## 0. 一页结论

| 相机 | 结果 | 等级 |
|---|---|---|
| CAM-0 普查 | `/etc/ld.so.preload` 不存在；`LD_PRELOAD=/lib/libsetlbf.so`（OpenWrt setbuf 助剂，strings 仅 stdout/setbuf；canary 为静态 musl 无 preload 仍被写）⇒ **B3 注入库类排除** | E2 |
| CAM-E 回溯审计 | ua2/joint 两日志 **258,206 条 fault 全部单一 pc=0x101bafc**（victim 已知自写点），零外来 pc ⇒ 脉冲臂无 EL0 探测者（采样口径） | E1 |
| **CAM-G GUP-14 联合窗** | 14 钩全活性（H4 27.3M / H13 1.98M / H2,H7 1.57M / H1 356K 次调用），窗口内 **ring 零事件**，同期受害者**被持续写入**（槽位命中贯穿至 duration 末；日志 887→1080+ 行）⇒ **写者不经任何 remote/非 remote GUP 族入口、不经缺页/fixup 路径进入守护页** | **E2** |
| CAM-R romap | **仪器事故**：selftest 首次真跑即硬复位（无 pstore console ⇒ WDT 式）；修复了 3 个装载前缺陷后仍崩 ⇒ **隔离待离线修**，B2 本轮未判 | — |
| CAM-D 持久引用 | 全 RAM（~1.1GB 可读段）扫槽位 PA 值 **8 字节精确匹配唯一命中 = patrace 自身查询缓存**（页内含 "patrace" 模块名；{pid,va,pa} 与 /proc/patrace 读回一致；self=0）——观察者工件，同时充当**计划外正对照** ⇒ **无任何外部常驻/陈旧 PA 引用** | **E2** |
| CAM-D 瞬态（WED RXBM） | ringpoll 盯 `Desc AllocPA=0xa9d00000` 环 600 s @1 ms（写者活跃同期）——结果见 §4 | §4 |

**剩余机制空间（合取 U-A2..U-E1 + 本轮）**：
1. **B2'**：手工内联页表走查（不经 follow_page_mask）+ kmap/别名 store（U-A2 已证其先查用户 PTE 权限）；
2. **B4t**：同上走查后把 {victim PA, 包元数据} 写进某 DMA 环由引擎代写（描述符寿命 ~ms）；
3. B3 残余（EL0 非探测写者，需 DIS-2/CAM-P 收口）；
4. B5（EL2/EL3/自主硬件，终局 B 余项）。

## 1. S1 零风险层（普查 + 回溯）

- ld.so.preload 无；env 普查见 libsetlbf（见 §0）；maps 无 memfd:/[deleted] 异常；
- 04:00 定时重启在役（reboots.log 11-03/11-04 连续）；本轮全部窗口避开（但 00:36 事故重启先于它发生）；
- NE 基线 1953（23:10）→ 会话内逐窗对账见 §5。

## 2. S2 · GUP-14 联合窗（U-F1 预注册）

**装置链**（全部五元组入档 §6）：
- victim = scanary_ro v25（v24 同源 + stdout 无缓冲化 + DYING 面包屑，修"静默死丢日志"盲区；
  本轮实证 v24 "死亡"实为**观测通道丢行误判**（pidof 空 vs ps 在），纪律教训入档）；
- wrhunt2 v2（md5 8aecebe2）：v4 五入口 + 9 新入口（get_user_pages/__get_user_pages/
  get_user_pages_fast/internal_gup_fast/pin_user_pages(+fast)/get_user_pages_unlocked/
  follow_page_mask/follow_pte），**lr 捕获**（入口 x30）+ mm 身份门 + wide/strict；
  percpu 过大问题（6888 B/CPU 拒配）→ 全局 ring + 原子索引修复。

**装载与对照**：14 站点字比对全过 + GO/NO-GO ok；
P1 vmwrite32→H3(aux=0x1)/H7 ✓；P2 mempoke→H1(aux=0x11, **w0..w3 逐字节=载荷**) ✓；
PG1 vmsplice→H8+H9(lr 链对) ✓；PG2 mlock 因页已驻留不触发 GUP（H7 已由 P1 覆盖，注记）；
背景噪声 = /proc/*/cmdline 读者（pgrep/tr，fast_watch 链）落在 argv 页——窗口收窄至活槽页后清零。
PD（disarm 对照）未跑（模块已卸）——覆盖边界注记，不影响零命中结论。

**主窗（23:57–00:26，armed=1，窗=活槽页 0x7fdec31000-0x7fdec32000，mm=victim）**：
- 活性（unloaded 行）：H1=364,429 / H2=1,600,351 / H3=0 / H4=27,715,322 / H5=0 / H6=0 /
  H7=1,600,351 / H8=2 / H9=2 / H10=0 / H11=0 / H12=0 / H13=1,975,480 / H14=0；
- ring：**0 事件**；受害者 HIT 持续（含最后 5 s 内两条 HIT_APPEAR/GONE，residency 5 ms）；
- 判读（预注册 §3 第 3 行）：H1/H2/H4/H7/H13 有巨量活性+对照 ⇒ 这些路径的阴性 **E2**；
  H3/H6/H8–H12/H14 窗内 calls=0（路径零流量；H3/H8/H9 有装载期对照，H6/H10–H12/H14 无
  独立对照）⇒ 按预注册注记 E0 附加，不影响"写者若走 GUP 族必有 calls/hit"的窗口内排除。

## 3. romap 仪器事故（如实全录）

修复 3 个装载前缺陷：① UNDEF `panic_on_oops`/`init_mm`（未导出；init_mm 以
`setup_initial_init_mm` 反解 adrp+add = **0xffffffc0090b2e20**，与 4 处 store 偏移自洽）；
② `if (*st)` 把成功串 "ok" 当错误（原生 bug，从未上机所以未暴露）；③ diag 打印。
修复后 selftest 首次真实 PTE 编辑 → **设备硬复位**（SSH 10054；pstore 无新 console
⇒ WDT 式死亡，非可捕获 panic；panic_on_oops 当时=0 仍死 ⇒ 疑 oops 风暴/原子上下文锁死）。
**处置**：romap 隔离（同 pte_redirect C-174 先例），修好并冒烟前不得再上；
B2 判定顺延。副作用：新 boot、时钟经 NTP 恢复、panic_on_oops 复原默认。

## 4. S3 · CAM-D 环取证（B4）

- 槽位页 VA→PA：patrace（pid 21480, va 0x7feb011000 → **pa 0xae822000**）；
- 全 RAM 8 字节精确扫描（a1ca0000–eeff0000 + 80000000–a1c9ffff + eeff8000–ffffefff；
  未读页 26,482 为保留洞）：**唯一非自身命中 pa=0xae1f32d8 = {ptr→模块符号区, pid=21480,
  va=0x7feb011000, pa=0xae822000, {0,1}}** —— dump 上下文见 "patrace" 模块名与
  /proc/patrace 一致 ⇒ **观察者查询缓存**（判据纪律 #3 实弹：观测者污染），
  同时证明扫描对 {va,pa} 对的检出能力（正对照）；pascan 自身栈命中按 self=1 剔除；
- **ringpoll**（瞬态臂）：/proc/warp_ctrl/warp1/rxbm 暴露 `Desc AllocPA=0xa9d00000`
  （ring_len 65536 / pkt_num 24576 / rxd_len 8）→ /dev/mem mmap 轮询 256 KB @1 ms × 600 s，
  目标值=槽位 PA；结果：（见下——运行于 01:06–01:16，本节写作时收尾）。

### 4.1 ringpoll 结果（终值）

- **主轮**：`iters=116,233 hits=0`（600 s × 256 KB @1 ms，目标=槽位 PA 0xae822000；
  同窗受害者 HIT 持续增长）⇒ **WED RXBM 环 600 s 内从未持有该 PA**；
- **正对照**：以环内现行条目值（0x…ac7b1140 族）为目标重跑 20 s → **3827/3827 迭代全中
  （off=0x10）** ⇒ 轮询器对环内值的检出能力确定；
- 环内容独立验证：0xa9d00000 处为活 RXD（buf 指针 0xac7bxxxx 系列）；
- 边界：仅覆盖 WED RXBM 一环（EDMA/FE/PPE/WED-TX 环未覆盖——环 PA 发现手段待建）。

### 4.2 灵敏度复证（换受害者）

新受害者（pid 17362）槽位页 0x7fdba97000→PA 0xaf8f7000（patrace）；对新区间重扫：
**唯一非自身命中仍在 0xae1f32d8**，内容已**原地更新**为 {va=0x7fdba97000, pa=0xaf8f7000}
——旧对无任何残存副本 + 新对即刻可见 ⇒ 扫描对 {va,pa} 对的灵敏度与时鲜性均实证。

### 4.3 全夜会话与命中统计（scanary.log 1,173,031 B，md5 7f7e1720…）

| victim | 版本 | 时长/去向 | inj=0 HIT_APPEAR |
|---|---|---|---|
| 5991 | v24 | 87 s stray（当夜早段，TERM） | 28 |
| 27270 | v24 | ~61 min（被误判死亡、实活，TERM 清场） | **272** |
| 5301 | v25 | 短（TERM 清场） | 2 |
| **17923** | **v25** | **S2 武装窗受害者（23:46–00:26，2400 s duration 满）** | **208** |
| 21480 | v25 | CAM-D 窗（1500 s 满程） | 33 |
| 17362 | v25 | 300 s（灵敏度臂，duration 满） | 6 |

全夜真命中合计 **549 条**；诱饵/注入命中另计（探测器存活对照，全部按 inj 标记分离）。

## 5. 完整性对账

- wrhunt2 卸载：14/14 站点恢复回读 ok=1，lsmod 清空；
- NE 台账：1953（23:10）→ 会话结束复点（见 §6 表）；本轮仪器零 NE 归因；
  设备 00:36 一次非计划硬复位（romap 事故，§3）；
- nerepair/slotguard：观察模式随新 boot 自启，全程未动（dry/observe）；
- 04:00 定时重启仍在前方（reboots.log 将再录一行，与本轮无关）。

## 6. 采集件与五元组

| 件 | md5 | 说明 |
|---|---|---|
| wrhunt2.ko | 89e33c81…（v1）→ **8aecebe2…（v2 在役）** | 14 入口 |
| gupprobe | 1a7e7ff2… | vmsplice/mlock 对照 |
| scanary_ro_v25 | 780c56da…（_IOLBF 误版）→ **b8b0a22a…（_IONBF 在役）** | 无缓冲化 |
| romap.ko | 314974d6…（档）→ bf470768/b116779e/a43b01b2…（三次修复链） | **隔离** |
| ringpoll | 569bee79… | /dev/mem 轮询 |
| uf1_obs_end.txt / uf1_final.txt | 8e892800… / 7abba9eb… | 观察窗末/窗末快照 |
| scanary.log | **7f7e172074ddbd42857dce4f9ed2df20**（1,173,031 B，双侧一致） | 全夜 6 victim 会话 |
| uf2_ringpoll.log | e4e2e9e1… | WED RXBM 轮询（116,233 iter / 0 hit + 对照全中） |

NE 对账：1953（23:10 基线）→ **1954**；新增 1 条 = `awk sig=11 far=0x4`
（监督链 svc awk 自然崩溃，家族下游效应形态），**仪器归因 0 条**；
设备重启 1 次（00:36 romap 事故，§3），04:00 定时重启在本报告之后。

## 7. 判决与下一步（按 12_ 设计树）

- S2 判决 = 预注册第 3 行：**B1 出局（E2）**，不升级 S5；
- S3 判决：**B4-常驻缓存出局（E2）**；B4t 视 ringpoll；B2 因 romap 事故**未判**；
- 下一步（按序）：
  1. **romap 离线修复**（疑点：PTE 编辑的 set_pte+flush 在本内核线性映射上的正确性；
     用 lab 内核先冒烟）→ B2 判定；
  2. ringpoll 扩到 EDMA/FE/PPE 环（需环 PA 发现手段）→ B4t；
  3. CAM-W Tier B（观察点引擎）或 DIS-2+CAM-P → B3 收口；
  4. 以上全阴 ⇒ 终局 B（12_ §1 五条门）。
- 纪律教训入档（三条）：① lgssh 单行命令输出被 tail/排序吞行 = 观测通道缺陷
  （本轮一度误判 victim 死亡——**判据必须落在文件/计数器上，不落在管道回显上**）；
  ② deploy put 后 exec 位重置陷阱再现（AGENTS 已有，本轮实弹一次）；
  ③ musl 对非 tty 不落实 _IOLBF（改 _IONBF）。

## 8. 三栏

### [A] 已核实
- wrhunt2 14 钩装载/对照/主窗/卸载全链（dmesg+回读）；
- 主窗零事件 vs 受害者持续被写（scanary.log 同窗 193+ 条落地）；
- 全 RAM PA 扫描唯一命中=patrace 自身（上下文 dump 钉死）；
- ringpoll 装置与 /proc/warp_ctrl 环地址（§4.1 回填）。

### [B] 未核实
- 写者身份（本轮新出局的只有 B1/B4c）；
- B2（romap 隔离）、B4t 其他环、B3 终判；
- H6/H10–H12/H14 的独立正对照。

### [C] 必须上设备
- romap 修复版冒烟 + B2 判定窗；
- EDMA/FE/PPE 环 PA 发现 + ringpoll 扩展；
- CAM-W Tier B / DIS-2 / CAM-P。
