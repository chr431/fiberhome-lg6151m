# 00 · 当前状态（2026-11-03 收束版）

> 本页只写“现在该信什么、下一步做什么”。每条结论的 ID 指向 [01_CLAIMS.tsv](01_CLAIMS.tsv)。
> **2026-11-04 夜五轮（U-A1..U-E1）后下一阶段入口 = [12_WRITER_ID_SUITE_DESIGN.md](12_WRITER_ID_SUITE_DESIGN.md)**
> （写入者点名收口仪器组：终局 A 点名 / 终局 B 证明不可达；最新事实见 docs/review/U-E1_RESULT_*.md）。
> 旧的 67%/32%、两个写入者、PIT 表项等结论已撤回，见 [ARCHIVE_MAP.md](ARCHIVE_MAP.md)。
>
> **2026-11-03 兜底部署（观察模式）**：nerepair **v2.2**（`811b3e19…`，xrep 未布防 / XFORM 普查在）与
> slotguard **v1.0**（`eec51be4…`，三槽 `observe`、arm 未建）已上机并随冷启动自启
> （rc.extend v3.9 / svc_lib v1.12 / watchdog v1.53 监督零重启）；9 件落盘 md5 全等于设计 §8，
> `--selftest` 无 FAIL、`--once` 零副作用。观察窗起点 **2026-11-03 17:45:32 +0800**
> （boot `9129c459…`），24 h 复盘 ≈ 11-04 17:46，布防门禁未达 ⇒ 未布防。
> 详录见 [SLOTGUARD_DESIGN.md](SLOTGUARD_DESIGN.md) §7 与 [REVIEW_SLOTGUARD.md](REVIEW_SLOTGUARD.md)。

> **2026-11-06 U-P（busybox 稳定性判决/修复）**：p5 补丁 busybox **不稳定**（缺失文件错误
> 路径 4/4 SIGSEGV；根因 v5 shape-B 误补 3 条 va_list 拷贝 0x408c68..70）；ip-full p5 的
> `stp q0,q0` 误补**静态无效**（该命令的 `ip neigh` 崩溃为既有 vendor 家族：40 条部署前
> stock 历史）。修复 = **v5∩v6 验证子集**：busybox 58 站点（p6s，功能等价、错误路径 0 信号、
> 20min soak 4×1192 次 0 信号）、libc 140（=p4）、wpad 24（=p5）、ip-full 0（=stock）。
> rc19 **v2.43** 三挂载（libc/busybox/wpad）+ 持久 boot 标记
> `1793973483 25 libc=1 bb=1 wpad=1`；**T0=1793973483**（T0_UP_p6s_boot）。
> 详见 [U-P_RESULT](../review/U-P_RESULT_2026-11-06.md)；claims C-318..C-324。

> **2026-11-06 U-Q（全覆盖落地/稳定性判决）**：gw 静态 busybox 的 U-O 拒绝是**测试命名
> 假象**（busybox 按 argv[0] 选 applet；非 `busybox` 名执行必报 applet not found）。静态版
> 站点 v5 **149** = v6 137 + 12（v6 prologue 扫描在函数前驱是尾调用 `bl` 时误拒，v7 修正），
> **p8 = 197**（+48 个 v6 独有 q2..q7，补 `bb_perror_msg`/`bb_error_msg_and_die`/
> `ioctl_or_perror` 等漏检变参 prologue）；**q0/q1 必须保留**（v7 全集 255 会把
> `awk print 3.14` 打成 3.47e-310、`%f`→0）。rc19 **v2.45** 四挂载
> （+`/data/stealth/busybox_static_p8 → /data/gw/bin/busybox`），boot.log
> `1793978317 25 libc=1 bb=1 wpad=1 gw=1`；四件 md5 libc dc38797e / dyn bb af5f1d75 /
> wpad ad381d37 / **static bb 36e3b4df**；**T0=1793978317**（T0_UQ_p8_final）。
> **稳定性未达成**：p7/p8 窗口静态 busybox 仍死（svc_lib/wan_agg/incident awk/sed）；
> 决定性对照 **p9（255 个 q0..q7 保存全 nop）挂载后 276s 仍死 `cut`，pc=0x4c8728
> (vgetopt32) = 台账 29 条既有同族** ⇒ **FP 保存突发掩蔽封顶**；p9 破坏浮点、p10
> （vr_offs=0）破坏整数变参，均拒用。下一步 = 引擎侧 T1/T2/T3 或 va_list 结构体直瞄假设。
> 详见 [U-Q_RESULT](../review/U-Q_RESULT_2026-11-06.md)；claims C-325..C-330。

> **2026-11-07 U-R（覆盖补全 + T1/T3 范围复核）**：U-Q 的 p9 不是零签名对照——静态 busybox
> 有 **399** 条 q→[sp] 存储，v7 只补 255；未补 144 中 **40 条 = 5 个完整 q0..q7 块**
> （ioctl_or_perror_and_die / zbc_posix_error_fmt / fmtstr / out1fmt / ash_msg_and_raise_error），
> 漏因 pre-index 帧与 va_start-after-save。v11 修正后 **p11 = p8 197 + 31 = 228 站点**，
> 未补升序 q 块 = 0，q0/q1 保留；qemu 402 help/34 电池/14 定向全等，设备 44 项仅 df 8KB、
> 9×30 零信号。rc19 **v2.46** 第四挂载换 `busybox_static_p11`，重启 boot.log
> `1793980462 25 libc=1 bb=1 wpad=1 gw=1`，static md5 **eedfbe41**，**T0=1793980462**
> （T0_UR_p11）；首 NE=T0+322s vendor iptables（非 gw busybox），稳定性观察中。
> **T1/T3 范围复核**：T3 的 C-280 只覆盖 pfn_valid 子区窗 0x9c200000；ISU 顶层保留窗
> 0xbf000000/8MB 从未测，`exilewin.c` 因 `pgprot_cached` 不存在从未编译——U-R 修复后
> `exilewin.ko` 可构建（md5 c9c80e1c），`scanary_exile --win-dev` 已支持 ⇒ ISU 分支待上机。
> T1 的 C-300 只关闭内容馈源；厂商 MED IPI 任务停止（`mtk_ipi_send`/`med_stop_ack_ipi_handler`/
> 0xa5a5a5a5）在 C-298 头树重建后可构建但从未上机，预期值低。详见
> [U-R_RESULT](../review/U-R_RESULT_2026-11-07.md)；claims C-331..C-334。

> **2026-11-07 U-S（T3 ISU 顶层窗上机 + p11 判决）**：ISU 顶层保留窗 **0xbf000000/8MB**
> 用缓存映射（pfn_valid=1、unaligned RW ok、1MiB 419µs）首次实测：587s 同进程双 victim
> stackA **1147** / stackE **1075** 次 inj=0 外写，**RR=0.937**（[0.7,1.4]），冷窗/诱饵 0
> ⇒ **引擎照画 ISU 窗，T3 全面关闭**（C-280 子区窗 + 本轮顶层窗）。p11 上线后首例 gw 静态
> busybox 击杀：`awk` 1793983563 **pc=0x4b31cc（hash_clear）** far=0x4——p11 228 站点、
> 未补升序 q 块=0 仍死 ⇒ **q2..q7 覆盖不足，FP 掩蔽不是该家族机制**。写者有相位门：p11
> boot 高 λ ~100/min；计划重启后低 λ 0–2/min，合成洪水（port 9/37777）无效，ISU primer
> 仅 12–18/min，分进程 per-CPU arm 欠功效。设备已清：模块 0、ISU ON、p11 挂载、服务 3。
> 详见 [U-S_RESULT](../review/U-S_RESULT_2026-11-07.md)；claims C-335..C-338。

> **2026-11-07 U-T（夜间轮）**：**洪水是可靠 λ 放大器**——无洪水 1.5–2.8/min，U-H 原版 ug1
> （PC→192.168.9.1:37777，3×800pps）拉到 **7–68/min**，记录载荷=洪水包 {len,ip}（C-339）。
> 真实 p11 受害者首次闭环：`grep` 死亡（pc=0x4c8728、far=0x263cd）栈内 0xf3c8 精确 32B 记录
> `{0x263cd,0,{0x141,192.168.9.1},0}`，0xf3e8 紧邻完好 va_list（C-340）。**p13 值重基关闭**：
> 语义正确（reb_test rc=6）但真实编译器变参 basereb 114 vs base 121 events/300s（RR=0.94）
> （C-341）。**per-CPU pin 是仪器放大器**：scanary unpinned 26–68/60s vs pinned 0（CPU0-3 全零，
> 随 CPU 集大小单调），但无扫描线程的被动 mini/mini2 pinned/unpinned 均 ~1 记录/60s、迁移 60 次
> 不变 ⇒ scanary 高 λ 由其扫描线程跨 CPU 读栈放大，pin 不是真实服务缓解（C-342）。放大器排除：
迭代数两端一致、wb=none 仍 15–26 APPEAR/60s（哨兵写回只加 REWRITE）、独立进程 reader 无效
（1 vs 1）、**mini5 同进程跨 CPU reader 线程（300 个活槽）也 0 记录** ⇒ 放大器机制未定
（候选：printf 重负载 32B 密度/pthread 栈布局/扫描时序），pin 不可外推（C-346/C-347）；
真实单线程速率需停顿采样。隐身天花板 =
> bb_p11 残余 9 条 stp q→[sp] + 363 条 stp q→非 sp（va_list 拷贝），拆宽需 trampoline/编译器级
> 改造（C-343）。根修复：**T1b 主路径关闭**（stop=停 RX→必复位 MED；0xa5a5a5a5 不存在于 MED 固件，
> C-344），**force_stop 分支可达**（needforcestop@0x9221a18 置 1 + chan13 同回调；窗口 >1s
> 但停数据面、不可归因，C-349）、**T2 关闭**（58/58 SMC FID 无写者/DRM/DFX 手柄；DFD 链服务
> 与写者无关且受阶段门控；三个 ATF mmap 窗口零引用，C-345）；**T4 技术开放**（SBC_EN=0、
> BL31 可重签，但关引擎载荷未知——bit15 盲写/DDRPHY+0x1520 不可读/p24/p37 无回滚——不推荐
> 上机，C-348）。详见 [U-T_RESULT](../review/U-T_RESULT_2026-11-07.md)；claims C-339..C-349。

> **2026-11-07 U-V（静态分析轮）**：RP102/RP103 官方固件离线 diff（未触碰设备）——内核
> 8.5 个月迭代**零内存子系统变更**（全 delta 72B = 分段重链接位移；kallsyms 仅 +2 符号 =
> ccmi/conninfro dev_put refcount 硬化 + `ccmni_start_xmit`/`port_mirror` 字符串；mm/EMI/MPU/
> DFX/mrdump 零变更 ⇒ 无厂商修复可跟，C-350）。B 家族记录 `{A,0,{len,ip},0}` 第一候选
> 合法消费者 = **DPMAIF PIT/PIT_NAT 环描述符**（内核全套 pit_nat 函数/dump 串；modem 写、
> AP dpmaif 驱动从保留内存环读；条目=bat/ptr+len+IPv4 包摘要，与记录同形；mrdump=后果层、
> emimpu=MPU 层均不读该格式 ⇒ 用户态无合法消费者；设备闭环待做：dump PIT_NAT 环对照
> 故障记录，C-351）。官方组件 32B q 事务普查**无指纹规避**：libc 1872 / wpad 642 /
> busybox 290 / dropbear 122 / dnsmasq 75 / … / ccci_rpcd_com 0，RP102==RP103 逐项全等 ⇒
> 命中率随活 va_list 使用面走（K9），非二进制密度；"官方原版即安全"被否，32B 拆宽仍是
> 唯一代码级隐身增强（C-352）。详见 [U-V_RESULT](../review/U-V_RESULT_2026-11-07.md)；
> claims C-350..C-352。

> **2026-11-07 U-X（根治可能性勘测轮，只读+静态）**：**DRM 簇公开对码钉死语义域**——
> preloader 的 0x10005030/34 写原语 = MTK 标准 **DDR Reserve Mode/DFD 锁存族**（MT7986/AX6000
> 公开启动日志 `drm_update_reg` 序列逐字段同形：置 bit15 / 清 +0x34 bit8·9·21 / 清 bits12-14；
> TF-A mt8188/8189/8195 DFD 驱动同偏移 LATCH_CTL 图 + 同款写 key）⇒ **T4「清 bit15」候选
> 降级为大概率错靶，T4 维持搁置**（C-357）。**相位门全量表**：全部历史 boot 皆 warm 复位、
> 断电冷启动数据为零、同型计划重启产出三种相位；重启方式/uptime/ISU/feed/补丁版本全排除
> （C-358）⇒ 冷启动配对升格为决定性实验（DDR reserve 机制给 warm 态保留以具体载体）。
> 自然 NE 每-boot：干净 04:00 boot 1–6 NE/h、11-04 boot 156/13.8h 唯一高发（流量未分离，
> C-359）。**R 路径分级**：R1 相位门工程化（冷启动配对>流量台账>高相位自动重启）首选、
> R4 后果层代码修复次选、T7 证据包 v2 并行、R0c 时钟门控归档（固件串扫零候选）。
> 设备零写（快照：boot 1794020769、p11 四挂载、emiisu 0xdecddecd 待核、/data 90%）。
> 详见 [14_ROOT_CURE_SURVEY.md](14_ROOT_CURE_SURVEY.md) 与
> [U-X_RESULT](../review/U-X_RESULT_2026-11-07.md)；claims C-357..C-359。

> **2026-11-07 U-Y（低风险上机轮：受控 λ(t) 曲线）**：预注册 7 臂 ABAB（同 boot 1794020769、
> 2.2h、零复位/零 kmod/零服务变更）——基线 λ **12.31→12.71→9.86→6.33/min 慢漂降**
> （≈2×/2.2h，无快衰减：U-A2 的 5.6×/35min 受控不复现）；洪水放大 **×2.4–2.7 三臂稳定**；
> **真实 WAN ≈23 B/s 全程而基线 12+/min 持续 ⇒ λ=相位分量(boot 级,流量无关)×活动分量**
> 因子模型首个受控支撑（C-360）；自然 NE 与仪器 λ 解耦（2.2h 仅 +1 vs 1979 命中）。
> emiisu 收口：0xdecddecd=使能魔术，**ISU 现 ON**，[B4] 解除（C-361）；bit19 逐指令定案
> 入 C-357 注记（t4 解码无误，AX6000 bit17 为真实代差）。仪器教训：设备侧采样循环禁掺
> netfilter/磁盘读（v1 do_wait 挂起）；scanary 日志块缓冲须全量重算。R1 输入：相位 boot 级
> 稳定 ⇒ R1b 检测窗可小时计；新「慢漂降」若复现 ⇒ 高相位或有小时级自愈备选臂。
> 详见 [U-Y_RESULT](../review/U-Y_RESULT_2026-11-07.md)；claims C-360/C-361。

> **2026-11-07 U-W（PIT_NAT + 32B 拆宽轮）**：PIT_NAT 环 live dump 解码（kmod 直读驱动 VA，
> 524/5450 非空）条目 = `{hdr,len,bat_off,idx | bat_off2,DRAM_PA}`，**无 IPv4 字段**
> （全环 c0a809xx 0 命中）⇒ 记录 ≠ PIT_NAT 条目，C-351 第一候选否定（C-353）。32B 拆宽
> 全量交付：真 STP 站点 **362**（旧掩码误纳 142 条 LDP 是本轮全部假崩溃的根因，正确掩码
> 0xFFC00000，C-354）；`b tramp`+2×str q+回跳，PT[0] 扩展，md5 7f4f4ee9，功能等价全绿
> （qemu 10/10、真机 50 applet --help 逐字节、3500 次调用零塌，C-355）。但**效果阴性**：
> v7 洪水窗内仍崩在历史同族 PC（wan_agg 0x4d5474、cfg_heal pop_arg far=0x1ddf6），与
> C-329 p9 一致 ⇒ 32B 宽度非捕获键，拆宽不作隐身增强；生产回滚 p11（C-356）。详见
> [U-W_RESULT](../review/U-W_RESULT_2026-11-07.md)；claims C-353..C-356。

## 0. 2026-11-03 收束（本轮最终态）

**本轮结题：写入者未点名；四条核心约束钉死；后果层兜底已上机观察。** 证据：C-186..C-214、
`05_LOG/` 11-02/03 各轮、[VERDICT.md](VERDICT.md) v3、[11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md) §16。

1. **非 CPU uaccess（实测内零命中，E2）**：`__arch_copy_to_user` 家族漏斗 28.96M 次
   （292.8 MB 客户端热流量）+ 嵌入拷贝宽扫描 20.2M 调用 / 2.77M 扫描（C-206/C-214）。
   口径：宽扫描形状代理 ≈148/s 误报 ⇒ 不宣布"物理排除"，按**已测未发现**。
2. **需要厂商内核态环境（E2）**：lab 6.18 极简内核两窗 3600 s 零写入（C-213；
   期望 22–36 条，P(0)=e⁻²²…e⁻³⁶）。
3. **帧相对、目标无需执行、无需进内核（E3/E2）**：D9 五档残差 0（C-171）；纯用户态忙等 victim 同样命中（C-191）。
4. **随 WiFi 客户端数据面流量放缩（E2）**：热态 13.9–20.3/min ↔ 无客户端 0.60/min ↔
   WiFi 族遮罩残余 0.20/min（C-204）。

残余 = 厂商内核态中一个「按当前帧定位、非 uaccess」的写入机制（DMA/总线主写或其等价物），
具体代码点未点名；覆盖边界（audit 不含 ptrace=117、dmahook 两变体、lab 页资格混杂等）见 VERDICT v3 §5。
修复（后果层）：nerepair v2.2 + slotguard v1.0 **观察模式在役**（见页首部署块；≥24 h 后按门禁评估布防）。
部署当晚 17:45 旧 boot 全用户态停摆 → healthdog 应急复位（设计内动作；pstore 存档）；
新组件与该 boot 运行期无关已逐条证明，停摆根因未定，观察窗内监控复现。

## 1. 一句话

**记录真实、来自进程外部、不是受害者自己生成的；它精确落在 fault-time va_list，目标随进程栈布局（top-x2 恒 0x390），固定 VA 与固定 PA 都已排除。**
当前主问题：**VA-resolved 的写入是 uaccess 还是 GUP-DMA；写入者是否在 AP 可达范围。**

**2026-11-01 更新（skeptic 审计修订）**：vsurv4 H4v1 普查 **82/112** 份 canary dump 含规范记录（73.2%，Wilson 95% CI **64.3–80.5%**；原 88/112 作废，C-161）；`top-x2=0x390` 在 **111/112** 恒定；记录有**两副本**（`x2` 82、`x2-0x240` 66，后者只出现在 x2 也命中的样本里），`x2-0x130` 的 18 份是 **ASCII 十进制数字伪影**（strict 判据 0/112）；32B stride 的全页扫描**结构性**找不到记录（dump 偏移恒 ≡16 mod 32，实测 0/112，C-162）。canary 作为记录探测器已被验证（C-137/C-139）；**自然 NE `.stack` 4/4 含同族记录**（C-142 改判，旧 0/4 作废）；且**健康进程栈 2/12 也含记录**（C-173）⇒ 写入**普遍**、崩溃只看落点；不能用 canary 外推（C-140）。

**判决（2026-11-01 13:00 重写，取代 C-145）**：**旧「Transport = PA/DMA（E2）+ 记录 = WED TXD」已作废**（C-138/C-145 → X）。
当前口径（详见 [VERDICT.md](VERDICT.md) v2 与 [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)）：
- **写目标 = 活栈帧内的 va_list**（**E3**，scanary 5 档深度臂：命中点随人为帧深 D 精确平移、残差 0/0/0/0/0，每档 n≥191，诱饵区 0，C-171）；
- **记录 = 两个 16B 槽 `{u64 值; u64 0}`**，归一化后唯一载荷 `{A, 0, {len, addr}, 0}`（A 型/B 型只是 va_arg 自增 +8 落在不同槽，C-162/formlen）；
- **已证伪**：EDMA RX 描述符、WED TXD、固定 PA+固定页内偏移、固定栈顶相对偏移、信号帧、put_cmsg、pipe_to_user/sk_msg（§3 X-1..X-10）；
- **未排除**：H2 uaccess / H5 每次按当前 VA 重新 pin / H6 pt_regs->sp 派生 / H7 按进程缓存的地址；
- **写入是普遍的**：健康进程栈 2/12 文件含记录（strict，C-173），自然长驻 daemon 栈上有**稳定槽**（dnsmasq start_stack−0x1b40、nerepair −0x3b0）；
  ⇒ **崩溃数只是写入数的下界**，不能当记录率；
- **写入者身份仍未点名**；判决实验 D15（pte_redirect 打在 daemon 稳定槽上）是"VA 解析 vs 裸 PA 写"的一刀切。

**修复（C-146..C-149）**：`nerepair` 已部署（`/data/gw/bin/nerepair` + `rc.extend v3.3` 开机自启）；修复记录家族 SIGSEGV（`Xt=sp, pc+=4`，抑制信号），覆盖所有用户进程（PID 1 + fork 跟随），排除 vsurv4 canary；**不停止 DMA 写入**（根修复需厂商驱动 R1 或 SMMU R2）。详见 [FIX.md](FIX.md)。

## 2. 已确立（E2/E3）

| ID | 结论 | 关键数字 |
|---|---|---|
| C-001 | 32B 记录可覆盖 va_list，故障地址 = word0，PC = pop_arg | pf.core: addr=0x2204e, PC=0x1014728 |
| C-002 | 按 fault-time x2 重算，103/106 在同一 32B 记录上（E2，非 E3） | 71+32+3；43 pids/one boot/40.6 min |
| C-003 | 两种形态 A0B2 71 / B0A2 32 / other 3 | 71/32/3 |
| C-005 | 转储 word0 是 va_arg 自增后；故障地址 = 自增前 | ldr/add/str/ldr；+8 |
| C-007 | B 型“错开一个字节”是 TBI/tag 截断 | B 最高字节 = IP 最后一段 |
| C-028 | word3=0 迫使 va_arg 走栈路径 | __gr_offs=0；PC=ldr x8,[x8] |
| C-036A | vsurv3 handler 不能写记录区：x2 比 sp_fault 高 8896 B | sigframe 远在下方 |
| C-049 | 40/40 次成功 ip 运行 filter.pfx/label 全零；ip 填充只在崩溃时出现 | ipdump 20× -4 + 20× -o -4 |
| C-050 | 12 个 vsurv4 栈页 pg2 ref=1025：没有泄漏的 GUP pin | 1 + pg2 pin bias 1024 |
| C-051 | 0x780 是 va_copy 暂存槽，不是“更深的 va_list 副本”；71/32 = 两个目标地址 | ap=sp+0xb0, staging=sp+0xd0, ap2=sp+0x310 |
| C-052 | 固定 VA 与固定 PA 都排除；目标是 stack-top-relative、VA-resolved | top-x2=0x390；x2 页内偏移 0x570 vs 0xf30 |
| C-053 | sh.core 是 canary2.sh 装置 shell，不是自然进程；记录有两个零字、含公网 IP | NT_PRPSINFO pr_fname=canary2.sh |
| C-055 | 空模型 0/19232；handler 伪影排除；106 份是 43 pids/one boot/40.6 min | C-002/003/004/028 降 E2 |
| C-137 | H4v1 **strict** shape 扫描：**82/112** 含记录（两副本 82/66 + 一条 ASCII 伪影 18→0）；旧 88/112 与“三副本”作废（C-161） | 82/112；CI 64.3–80.5%；strict 0/458752 误报（C-163） |
| C-139 | vsurv4 canary 是有效记录探测器；自然 NE 0/3 不是探测器伪影 | 82/112 vs 0/3（P(0/3｜p=0.732)=1.9%） |
| C-140 | 【skeptic 2026-11-01 降级 E1】原论证方向反了：固定 PA 预测**页内偏移固定**，实测 53 种页内偏移；PA/DMA 表述与几何数据冲突（C-170）。VA-targeted 未被排除 | 82/112；top-x2 0x390×2552/2552；53 种页内偏移 |
| C-141 | core_meta v1.9 .stack/.stackerr 在真实死亡进程上验证通过 | .stack 65592 B；readable=16 |
| C-142 | **改判 2026-11-01**：自然 NE `.stack` **4/4** 含同族 32B 记录（q2=0x04D08ADE0000062F，len 1583，ip 222.138.208.4），位置 start_stack−0x1390…−0x7970 **不同深度**；旧 0/4（上界 49%）作废——判据 bug + 两批窗口不同不可混 | **4/4；Wilson 95% 下界 51%**（n=4，栈尾 16 页窗口，不可外推） |

## 3. 已撤回 / 不可再引用（X）

| ID | 旧结论 | 撤回原因 |
|---|---|---|
| C-016 | “至少两个写入者” | A/B 是同一记录的两个目标/对齐；常量是 B 的 tag |
| C-017 | “67% 可归因 / 32% 不明” | attrib.py 检查 0x780（暂存槽），不是 fault-time x2 |
| C-018 | “记录 = PIT 表项” | 活 PIT 零写；记录是 32B 上下文/网络流 |
| C-015 | “300 站点探针能点名写入者” | lr 是开窗者；300 从未成功运行 |
| C-019 | “记录 = 内核日志文本” | 单页单次；改判 aee 侧写；未独立复现（现为 open/E1） |

## 4. 未决（open）

| ID | 问题 | 当前证据 | 下一步 |
|---|---|---|---|
| C-006 | 0x780 暂存槽 vs ap2 是两个目标地址；71/32 的物理含义 | 暂存槽只活 ~10 条指令；固定写 ap2 产生不了 A0B2 | **vsurv5**：手写 va_copy 到不同暂存偏移；A0B2 跟暂存槽走/消失则 B-1 成立 |
| C-009 | sh.core 的“bystander”是否安全 | sh.core 是装置 shell；记录两个零字可把指针槽清零 | 降 E1；补良性正对照 |
| C-013/C-034 | 传输是 uaccess 还是 GUP-DMA | **旧判决「PA/DMA（E2，C-145）」已撤回**（C-171/C-176 之后 transport 未定）；页级 kprobe 被 CONFIG_KPROBES=n 阻断（C-144） | 判决实验见 11_TRANSPORT_SCORECARD §8（uprot / rovictim2 路线） |
| C-025 | 自然 NE 中记录家族占比 | **改判 2026-11-01**：自然 NE `.stack` **4/4 含同族记录**（C-142）；健康栈 **2/12** 为基线（C-173）⇒ 占比须按同一 strict 判据重扫；canary 82/112 验证探测器 | 分层重扫三套语料；不要用 canary 外推 |
| C-026/C-038 | GUP/stale 用户指针 | 内核有完整 zerocopy 栈；模块 0 GUP 导入；驱动 dma_map_page | 查 mtk_warp/mt_wifi 的 skb frag/zerocopy；ref/use-after-unpin |
| C-035 | cth_cfu 正对照 Oops/重启 | 一次未复现；3 个候选机制 | 修 cth（递归守卫、去 dump_stack、默认关 c2u）后再跑 |
| C-044..C-048 | ip 是页级写入的受害者；HIF-TXD/FOE 形状候选 | ip 全 .text 无写 filter.pfx；mtk_wed 32B 描述符 +0x10/+0x14；hw_nat FOE IP +0x10/+0x14 | **mtk_warp**（738KB，未扫）是真正 ring/DMA；mt_wifi fh_netlink_send_to_user |

## 5. 当前方向（按优先级，2026-11-01 skeptic 修订）

1. ~~**D10 语义实验（最高性价比）**~~ **已完成（2026-11-01 晚，C-186，E2）**：0/46 注入窗口（0/84 会话）len 命中注入换算集、0 精确 242/1242、0 注入源 ip，注入臂 44/46 len>1536 ⇒ **H4 未复活、证伪维持；len=与单包长度无关的软件量；无因果链迹象**（05_LOG/2026-11-01-11-d10-semantic.md）。下一优先 = 2（D9 布局扰动）。
2. **D9 布局扰动**：canary 改栈布局（b[24]/msg[160]/调用深度，或把缓冲区移到 heap）；判记录跟 va_list 还是跟缓冲区 → H2 特征（scorecard §3）。
3. **D5 环池成员（带正对照）**：命中页 PA 是否出现在 RX 环缓冲池 → H1 直接点名/排除（scorecard §2）。
4. **D6 迁移跟随**（madvise 换 PA）：VA-targeted vs PA-targeted 的终局判决（scorecard §2/§4）。
5. **D8 PTE 重定向三哨兵**（F-07 判据）：H2 vs H1/H3（scorecard §3）。
6. **D1/D2**（同会话 A/B/A；同包率 UDP vs SSH）：写入者路径归因，与 transport 正交但决定 R1（audit §5.4）。
7. **明确降级**：1–5 有结果前，不再加新仪器/新模块；不再用无正对照的阴性做排除（C-169）。

## 6. 停止规则

- 不做没有功效计算的 A/B；阵发过程的单窗差异不算效应。
- 不把 canary 崩溃率当自然 NE 率；不把 canary 记录家族当全部 NE。
- 不在没有正对照的情况下引用“0 命中”。
- 不把不同家族混成一个“总速率”。
- 不在一个窗口里改两个变量。
- 不把“记录在栈上”直接当成“记录导致本次崩溃”；必须 fault addr 对齐 + PC 证据。
- 不把“记录在场”当成“记录因果”；sh.core 的零字可以造成 later NULL。

## 7. 本轮交付物

| 文件 | 状态 |
|---|---|
| docs/SIGSEGV/ 本目录 | 新建，当前事实源 |
| **docs/SIGSEGV/11_TRANSPORT_SCORECARD.md** | **新建（2026-11-01）**：transport 假设记分卡（H1a/H1b=H5/H2/H3/H4 + 判读边界 + 判决实验排期）。**对外表述以此页为准** |
| tools/oneoff/sigsegv/va_scan.py | 106 份 71/32/3；legacy 71/35 |
| tools/oneoff/sigsegv/core_scan.py | 6 份 an2 5 A0B2 + 1 B0A2 |
| tools/oneoff/sigsegv/natural_scan.py | h4/sd 解析 |
| tools/oneoff/sigsegv/vsurv4.c | 设备自检通过；h4 32888B；随机/固定栈 A0B2/B0A2 |
| tools/oneoff/sigsegv/stackdump.c | aarch64 编译；host 通过 |
| tools/oneoff/sigsegv/core_meta_v1.7.sh | staged |
| tools/oneoff/sigsegv/probe_selftest/ | PF 通过；cfu 事故；uw 待测 |
| tools/oneoff/sigsegv/ipdump.c | 40/40 成功 ip 无 fill；ip 填充只在崩溃 |
| docs/SIGSEGV/05_LOG/2026-10-30-02-v4-first.md | vsurv4/ipdump/PA 结果 |
| docs/SIGSEGV/05_LOG/2026-10-30-01-reset.md | 106 份重分类 |


## 8. 2026-10-30 21:15 · mtk_warp 静态（P-1/P-2）

- **WED TX ring 条目存 PA**：wed_tx_ring_reset（0x2078）步长 0x50，entry+0x10 = DMA 地址（PA）；wed_fdesc_init（0x22d4）把 fdesc[0x20] 的 64 位地址写进 16B HW 描述符 {u64 dma_addr; u64 ctrl}。
- **reset 路径有序**：warp_reset_hw（0xc964）先写 stop bit（ctx+0x208）并轮询 100 次，之后才 wed_tx_ring_reset；warp_ring_exit 也是先 warp_dma_ctrl_hw(ctx,0) 再 reset。reset 不是 stale-PA 窗口。
- **free_dma_tx_pkt（0x1bfc）**：dma_unmap_page_attrs → __dev_kfree_skb_any；先 unmap 再 free，但**不清 fdesc/ring，也不等硬件完成**。这是运行期 TX completion 的剩余 stale-PA 窗口。
- **RX token**：wed_release_rx_token（0x22c0）是 4 指令 stub；wed_acquire_rx_token（0x224c）调回调；RX refill 仍未闭合。
- **GUP/zerocopy 否定**：mtk_warp/mt_wifi/mtk_hwifi 0 个 GUP/pin/iov_iter/skb_zcopy；5 个 dma_map_page_attrs 全是内核 kaddr 且显式拒绝 vmalloc。
- **形状（历史，已作废）**：ip 的 .bss 填充是 17 个 16B {A,0}（与 17 个 WED TXD 对齐，这条观察保留）；**"32B 记录 = 两条相邻 16B TXD"已被证伪**（C-138→X，见 VERDICT v2 §3）；txdmad 位域未再追。
- **覆盖缺口**：fh_netlink_send_to_user 的实现模块不在 17 个 .ko/kallsyms 里。

**当前判决**：H-GUP 否定（0.9）；H-TOUSER 否定（0.95，warp 无 copy_to_user）；H-STALE 仍活（0.6），落点是 free_dma_tx_pkt/运行期 TX completion，而不是 reset 路径。下一步：P-C（RX 缓冲页释放+填毒+记录 PA）判决，P-B 补 free_dma_tx_pkt 的调用者（ops 结构），P-D 找缺失的 FiberHome 模块。

## 9. 测量偏差（2026-10-31，vaguard / nerepair）

- **vaguard**（自建 busybox/ip/logc/mipc_cellular/v3httpd 的 vfprintf 闸门）在自然进程里**修复**记录家族：vaguard.tsv **49 次**（44 ip、4 awk、1 ping），这些**不进** ne_events/cores → 当时的自然 NE 普查 0/4 是 post-guard 下界（C-152）。**2026-11-01 更新**：新一批自然 NE `.stack` **4/4 含同族记录**（C-142 改判），说明记录家族在自然进程里**不是罕见事件**；但 n=4、窗口只到栈尾 16 页，仍不可外推。
- **vsurv4 canary 不链 vaguard**（build_usr.sh 无 vaguard.o）→ **h4 82/112 不受影响**（C-161/C-139 仍成立）。
- **ip 的 .bss filter 填充**不是 printf 类 → **40/40 结论不受影响**；但 ip 的总崩溃数被闸门压低（44 次 printf 命中被修），ip 的自然 NE 计数偏低。
- **nerepair** 现已对全部进程修复同一家族（vsurv4 除外）→ **修复后自然 NE 不再可比**；干净的自然份额窗口需**停闸门 + 停 nerepair**（canary 仍记录 h4）。
- 闸门 49 次命中的时间跨度 ≈42 h（epoch 1793183044..1793333882）→ ≥1.17 次/小时的记录家族事件（受闸门覆盖的二进制内）；因闸门在写 core/h4 之前就修复，不能换算成自然份额（C-153）。

## 10. 运行时消元：HW_TX_EN 门控实验（2026-11-01 00:12–00:47，C-154）

**判决（02:43 经 P1 诊断修正）**：把 mtk_warp 的 `HW_TX_EN`（`/proc/warp_ctrl/warp1/ctrl`）置 FALSE，
**不改变** 32B 记录写入率；且 **P1 诊断证明 `wifi_tx_tuple_add()` 在本负载下从未被调用**。
→ 正确口径：**该路径在本负载下未被激活，因此 A/B 的"无变化"是门控惰性，不构成对该路径的证伪**。
（"WED tuple 路径不是写入者"这句话**不可**再作为结论引用。）

**关键数字**（历史记录：4× vsurv4 canary，按 WED TX 包归一；**该速率口径已作废**，见 C-166）
- A 臂（TRUE）：456 命中 / 20.3 min / 300,152 TX 包 = **1.519 命中/千包**
- B 臂（FALSE）：246 命中 / 8.1 min / 176,990 TX 包 = **1.390 命中/千包**
- 比值 **0.915（95% CI 0.783–1.068）**；吞吐 24.6→36.4 MB/min（无下降）、loadavg 12.63→12.50（无变化）
- 自然 NE：A +1、B +0 → 75 min 窗口对 0.5/h 基线无功效，**不作结论**（§6 停止规则）

**静态依据**：`warp_wlan_tx`(.text+0x970) 读 `[ctx+0xd31]`（HW_TX_EN），为 0 则 return 0，跳过
`wifi_tx_tuple_add`；`ctrl` 写处理器(.text+0x5d6c) 只 `strb`，无 MMIO 写；mtk_wed.ko 0x8b8 调
`warp_wlan_tx`、0x8bc `cbz w0` → 0 则走 `ops->tx` 软件回退。**门控是惰性的可能原因**：
`warp_wlan_tx` 还有第一道门 `wifi_hw_tx_allow`（mt_wifi 回调），本次未控制。

**副产物（测量学，已作废）**：canary 命中率 **1.3–1.5 次/千个 WED TX 包、20–35 次/min**（4 实例）——**该"每千包"口径已被 C-166 撤回**，仅存"同会话内约 20–35 次/min"这一观察；
B 臂 8 min 即 246 命中（P(0)=e^-246）→ **后续机制 A/B 只需 5–10 min/臂**；
自然 NE 仍必须 ≥6 h（**注意：2026-11-01 起"自然进程≈0"已被推翻**——4/4 自然 NE `.stack` 含同族记录（C-142 改判）；速率仍不可互推，但"家族是否存在于自然进程"这一问已答"是"）。

**证据**：`_local/evidence/crash-root/hwtx_*.jsonl`（主机侧）；设备 `/data/repro/h4_*.bin`（334→1243）；
`docs/SIGSEGV/07_LEVER.md` §6；`tools/oneoff/sigsegv/hwtx_gate.sh`（门控脚本，status/off/on/verify）。
**P1 诊断（02:41–02:43，已执行）**：`echo 2 > /proc/warp_ctrl/warp1/stat`（WARP_DBG_INF）75 s，
期间 WED_TX1_MIB 3534→3759（225 个 TX 包）；`dmesg | grep -ic tuple` = **0**，
而同期 WARP_DBG_INF 的 `warp_msg_send_cmd/HwCtrlTask` 日志正常刷屏（证明 level 2 生效）。
→ **`wifi_tx_tuple_add()` 未被调用**（该函数在 level>1 时必然打印，字符串前缀 `wifi_rx_tuple_add`）。

**形状排除（P1 附带）**：`echo 3 [ring] [idx] > wed` 的 TX 环 dump **走 dmesg 不是 stdout**；实测 WPDMA TX 环条目 16B =
`{PA_lo, ctrl, PA_hi, 0}`（如 `00 a8 94 a4 | 48 40 4c 80 | 60 40 20 a4 | 00 00 00 00`），**不含 len/src_ip**
→ **32B 记录不是 WPDMA TX 环条目**。

**rmmod mtk_wed：已执行并导致内核 Oops + 自动重启** → 见 §11（C-155）；A/B 数据未取得，**未做 rmmod hw_nat**。

## 11. rmmod mtk_wed 触发内核 Oops（2026-11-01 02:55:16，C-155）

**事件**：02:55:16 `rmmod mtk_wed` → RC=0；同一秒 SSH 断开，ping 3/3 丢失，设备**自动重启**（02:56 恢复）。本轮唯一非计划重启。

**pstore 证据**（`/sys/fs/pstore/console-ramoops-0`，262,132 B；副本 `_local/evidence/crash-root/pstore_oops_2026-11-01.txt`）：
行 2082 `Unable to handle kernel paging request at virtual address ffffffc001535054`；行 2085 `EC = 0x21: IABT`；
行 2088 `FSC = 0x07: level 3 translation fault`；行 2091 `Oops: 86000007 [#1]`；行 2100 `pc : 0xffffffc001535054`；
行 2101 `lr : __handle_irq_event_percpu+0x58/0x120`。

**判读**：rmmod 前 `/proc/modules` 记 `mtk_wed … Live 0xffffffc001535000` → 故障地址 = **mtk_wed 基址 + 0x54**，
落在刚卸载的模块映像内；pte=0 表示已 unmap。**中断核心调用了指向已卸载模块的 handler** →
**mtk_wed 退出路径不安全（IRQ action 未注销 / 硬件中断未静默），可复现 1/1**。

**口径（必须分开写）**：这证明 **WED teardown 路径不安全 + WED 硬件在卸载后仍在产生中断**（H-STALE 同源，第一份直接实证）；
**不证明** WED 是 32B 记录的写入者（写入者仍未点名）。

**后果**：**rmmod 系杠杆全部不可用**（会打崩设备）；FIX.md R3「关 WED offload」不能靠运行期 rmmod 实现；
不要再重复 rmmod mtk_wed（每次都是非计划重启，污染 M3/M1 数据）。若要测只能用"重启后不加载模块"。





## 12. 第 4 轮（2026-11-01）条件分布与测量边界（C-156..C-159）

| ID | 结论 | 关键数字 |
|---|---|---|
| C-156 | **「命中成簇」撤回**：速率匹配泊松零模型下无超额 | 观测 131 秒 vs 期望 127 秒（比值 1.03） |
| C-157 | **两次 IP 分布矛盾澄清**：同一字段（记录 +0x14 = w2 高 32 位），不同时段流量构成不同 | 夜间 WAN 为主 ×122 / 本轮 LAN 为主 ×112 |
| C-158 | **记录字段布局**：`{u32 X, 0, u32 len≈1601, __be32 本机IP, 0,0,0,0}`；w1/w3 恒 0 | 150 份样本，75% 只有 X 变 |
| C-159 | **流量形态无关**：RX 包数跨 1366× 命中率恒定；canary 重启与 eth0 环重置均无响应 | 1.2–2.4/min 恒定；重启 1.0 vs 2.75/min；重置 4.6→4.2/千包 |

**测量边界（重要）**：canary 命中率跨会话**不可比**（同一批新 canary 差 19 倍，1.0 vs 19/min）。
「1.3 命中/千包」**已撤回**（C-166：单窗未复现 + 速率律被 09 结果 6 证伪）；它最多只能当**那次会话内的经验斜率**，详见 [10_MEASUREMENT_PROTOCOL.md](10_MEASUREMENT_PROTOCOL.md) 与 [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)。

**未排除方向**：慢变设备状态（页池组成 / stale 描述符存量）。建议下一轮做 4–6 h 长时程协变量记录（每 5 min）。

## 13. 第 5 轮：诊断内核模块（patrace.ko）· C-160

**工具已打通**：`patrace.ko`（zig cc 构建，158,344 B，`insmod` RC=0，dmesg 无 oops）
提供 `/proc/patrace`：`echo "<pid> <hexva>" > /proc/patrace` → 读回 `pa=0x...` + 该页前 16 B。
验收：用户态 mmap 写入 magic `PATRACE_MAGIC16` → VA 0x7fb6774000 → **PA 0xb4703000**，peek 与 magic 完全一致。

**C-160（已撤回，2026-11-01 skeptic）**：原写“canary 的命中页是固定物理页，被反复写入 → 存在指向该 PA 的固定引用”。**该推断不成立**：h4_meta 2552 行里 75 个 pid、**0 个 pid 有 >1 个 x2**（distinct x2 仅 62），pa_hist 对同一 pid 反复解析的是**同一个 VA**，PA 必然相同（重言式，C-164）。下表只保留观测，不再作推断；重建需 D7 正对照（同 VA 跨时刻 PA 可变性）。
| pid | VA | PA | 命中次数 | PA 是否变化 |
|---|---|---|---|---|
| 18023 | 0x7fe2b69850 | **0xb2ca1850** | **18** | **不变** |
| 18022 | 0x7fd46233a0 | **0xb46433a0** | **22** | **不变** |

→ **该推断撤回（C-164）**：同一 pid 的 x2 恒定，PA 恒定是重复解析同一 VA 的必然结果，与"固定引用"无关。

**后续搜索（未收敛）**：
- 环 dump 里没有该 PA（注意 dump 只显示 DD=0 的武装态条目）；
- 内核映像 .data/.bss（17 MB）全量扫描：0 命中；
- **全 RAM（523,008 页）按页基址 `0xb2ca1000` 扫描**：每次能找到 1–2 处，但**地址每次都变**
  （0xf7434f60 / 0xaac90f60 / 0xb08dd630，偏移 0xf60 / 0x630）→ 形似**内核栈残留**，不是常驻结构。
- `/proc/vmallocinfo` 的地址被 **指针哈希**（`0x000000008f6e0b30` 形态）→ 无法用 VA 反查分配者。

**结论**：固定 PA 这条证据成立（C-160），但"在常驻结构里找到该 PA"未成功；
若继续需能**按 VA 反查分配者**的手段（如关闭 kptr_restrict 或用模块读 vm_struct），成本较高。

## 14. 第 5 轮收尾：内核模块路线（阳性 + 三条阴性）

### 阳性
- **patrace.ko 可用**（VA→PA，验收通过，见 §13）。
- **C-160：canary 命中页是固定 PA**（原件 22/18 行，同一 pid 的 VA 与 PA 全同；两个 canary 各自不同 PA）→ **存在指向该 PA 的固定引用**。

### 三条阴性（都做了对照，不是"没找到"就算阴性）
1. **按 PA/VA 搜常驻内存 = 噪声**：全 RAM（523,008 页）扫目标值得 1–2 处，
   但**对照扫描**（随机值 `0x1122334455667788`）同样得 **6 处**、`0xdeadbeef...` 得 32 处（上限）→
   **命中数在噪声底之上不显著**，且命中地址每次变化（偏移 0xf60/0x630，形似内核栈残留）。
   → **"在内存里找到引用"这条不成立**（这是对上一轮"1–2 处命中"的自我否定）。
2. **vmallocinfo 无法反查**：即使 `kptr_restrict` 已为 0，`/proc/vmallocinfo` 仍输出**哈希指针**
   （`0x000000008f6e0b30` 形态，内核 `%p` 哈希；无 `no_hash_pointers` 启动参数）→ 无法用 VA 反查分配者。
3. **rxring.ko 抓不到 DD=1**：内核态 300µs/次轮询 ring0，**92,064 次全环扫描 / 30s / 60 万包流量 → `dd_total=0`**。
   → 要么扫错了环（eth1 流量可能走 ring1/edma-1），要么 DD 位语义与假设不符，要么消费太快（20k pps 下描述符寿命 ~50µs < 330µs 采样间隔）。

### 结论
本轮把问题推进到 **"命中与 eth1(LAN) RX 强相关（单窗 ×71）+ 记录落点 VA 相对（top−x2=0x390、页内偏移 53 种）"**；**"写入者在有线 EDMA RX 路径"只有 E1**（同一生成器 1 h 后复跑无效应；"每 RX 包一次机会"速率律被 09 结果 6 证伪，C-166）；**"固定 PA 引用"撤回**（C-164），
但**写入者的具体身份仍未点名**。三条用户态路径 + 两条内核态路径（内存搜索、环采样）均未收敛。
继续需要：换环（ring1/edma-1）重试 rxring、或直接读 FE 寄存器（0x15100000）搜 ring base。

### 14.1 换环重试（三条 RX 环全部 dd_total=0）· **按停止规则收口**

| 环 | VA | 扫描次数（~30s，20kpps 灌流） | DD=1 条目 |
|---|---|---|---|
| edma-0 rx ring-0 | 0xffffff801a47c000 | 92,064 | **0** |
| edma-0 rx ring-1 | 0xffffff801a458000 | 90,158 | **0** |
| edma-1 rx ring-0 | 0xffffff8019f40000 | 66,552 | **0** |

合计 **~24.9 万次全环扫描 / 约 170 万包流量 → 一次 DD=1 都没看到**。
另：`edma dump ring_status` 的 cidx/didx **再次确认是死值**（RX 恒 511/0、TX 恒 0/0，有流量时也不动）。

**按 Lead 停止规则 #4 收口**：DD 位语义或描述符寿命与假设不符（或读的不是承载流量的环），
**不再加仪器**。SIGSEGV 本轮到此为止。

### 本轮净收益（最终）
1. **写入者路径（E1，未定）**：LAN-only 臂单窗 ×71（eth0 RX 反降、rai0 TX=0、WED IRQ/s 恒定 48）；但**同一生成器 1 h 后复跑无效应** → 归因未定；判别实验 D1/D2/D6（见 05_LOG/2026-11-01-06-transport-scorecard.md §8）；
2. **C-160 撤回**：固定 PA 只是“同一 VA 反复解析”的必然结果（C-164）；需 D7 正对照后重建；
3. **可复用工具**：`patrace.ko`（VA→PA，已验收）+ `pascan`（/dev/mem 按值搜，带对照）+ `rxring.ko`（内核态环采样，已能工作但未捕到 DD=1）；
4. **测量边界**：canary 命中率跨会话不可比（见 10_MEASUREMENT_PROTOCOL.md）。

**继续投入需要新手段**（硬件调试器 / 厂商源码 / 关 `no_hash_pointers` 的内核重编），不是再跑更多实验。

---

## 15. 口径与选择效应（2026-11-01，skeptic 审计 C-168/C-170）

1. **所有 canary 记录结论的分母是“已崩溃的进程”**：“记录在 x2”“A 值 40k–150k”都是崩溃选择后的分布，**不能**反推写入者的字段语义或落点分布；w1/w3 与 w2 不在崩溃路径上，不受此污染。
2. **几何证据指向 VA 相对写入**：固定 PA 预测页内偏移固定，实测 53 种页内偏移而 top−x2 恒定；固定-PA 模型要解释 82/112 需要约 0.73×空闲页（设空闲 13 万页时 ≈9.5 万页≈380 MB）的已释放缓冲仍被环武装，量级不成立 → “PA/DMA”这个表述与最强几何数据冲突，判决实验 D6。
3. **transport 现状（2026-11-01 深度臂后）**：**写目标 = 活栈帧内的 va_list（帧相对）→ E3**（scanary 900 s 五档，残差 0，每档 n≥191；C-171）。由此 **H1a（固定 PA）、H1b（陈旧 PA DMA）、H3（直映射写）、H5（GUP-pin + 固定 VA）全部被否证（E3）**；H4（HW 描述符写回）此前已按字段语义证伪（E2）。**写入者身份仍未点名**，收敛到 **H2（uaccess）** 与 **H6（内核用 pt_regs->sp 定位用户栈，D9 逼出的新假设）**。详见 **11_TRANSPORT_SCORECARD.md**（对外以此页为准）。
   **未达 E3 的一步**：「写入者是外部（非 victim 自写）」仍需 32B 原始载荷 + 自然 NE 同载荷一致性；「ep0 与 ep4 PA 不同页」这条论证依赖"五个 epoch 同一 victim 进程"，待确认。
   **限定**：以上样本以 vsurv4 canary 为主；但自然 NE 也含同族记录——**4/4 份自然 NE `.stack` 含同族 32B 记录**（C-142 改判；旧 0/4 系判据 bug），位置随各自栈深度不同。n=4、只覆盖栈尾 16 页 ⇒ 只能写 **≥51%（Wilson 下界）**，不可外推。
4. **三条无正对照的阴性**（rxring dd_total=0 / dd_burst dd_set=0 / pascan 内核映像 0 命中）只能 E0/E1（C-169）。

> 2026-11-05 03:3x 增补:U-G1 CAM-W 观察点战役闭环(K9 内容耦合/EL1-fire 平台封死/
> 漏网落地非 EL0 通道;C-221..C-227,VERDICT §10;证据 ww_eviblob.txt 535f0d0e)。
> 2026-11-05 14:3x 增补:U-G3 长窗战役闭环(机制类级点名:总线级实时地址跟随写者,
> C-235..C-243,VERDICT §12;证据 ug3g_full.log 16b3582a/ug3_eviblob.txt 864c6610;
> 身份=EMI/互连观测基础设施或 EL3 代理,下轮入口 ATF/bl31 读闪——U-G3_RESULT §3)。
> 2026-11-05 18:4x 增补:U-G4 晚间续战闭环(协处理器 SRAM kHz 全零+MED 固件功能全图+
> 7 固件分区拉齐,C-244..C-247,VERDICT §13;身份收至 GC-TCM/EMI-hw/EL3,下轮=MED 消融)。
> 2026-11-05 20:5x 增补:U-G5 EMI 全面武器化闭环(EMI MPU 模型全解+A53 豁免+16 域穷尽消融
> 全无崩塌 ⇒ 写者不发出互连级 DRAM 写;GC 核与全部总线 master 类排除,C-248..C-255,
> VERDICT §14;身份收至 {EL3/ATF on A53, EMI/DRAMC 内部},下轮=tee_b(BL31)静态决胜
> ——U-G5_RESULT)。

- **U-G6(2026-11-05 晚)· 终局判决**:写者=EMI/DRAMC 内部硅引擎(post-MPU 注入,EL3 门禁),
  内容=MED 卸载流(hnat_info 族);EL3(BL31 全读)/EL2(无 hyp)/全部 master(U-G5)出局;
  嫌疑对={EMI-ISU, DRAMC DRM_DEBUG};点名弹=SMC 关断对照(mtk_emiisu_control sysfs 路径在手)
  ——U-G6_RESULT_2026-11-05.md,C-256..C-261,VERDICT §15)。

- **U-G7(2026-11-05 深夜)· 身份判定收束**:ISU 可逆因果关断 λ 零响应 ⇒ ISU 出局(C-262);
  DRAMC-debug 无控制面且未武装(C-264);SPE 无;持址者终扫空 ⇒ 终局=**无可达控制面的 post-MPU
  固定功能注入(残余子位置 DDRPHY DFX 族)**(C-266);nerepair+slotguard 即正解
  ——U-G7_RESULT_2026-11-05.md,VERDICT §16)。

- **U-G8(2026-11-05 深夜)· DFX 正面读出**:BL31 复位路径 dump 武器化(sysrq-b 4/4,
  ~20ms,含 EL1 致死 DDRPHY+0x1520);四窗矩阵:匹配生命周期相位时写者活跃与空闲在全部
  12 个可读 DFX/DRAMC-debug 寄存器逐位相同 ⇒ 可见面零签名(C-267..C-271,VERDICT §17;
  C-254 修正:DRM_DEBUG_CTL 真址 0x10005030=0x8303)——U-G7_RESULT_2026-11-05.md,
  U-G8_RESULT_2026-11-05.md,证据 _local/evidence/b4b/ug8/)。

- **U-G9(2026-11-06 凌晨)· 自我关断实验**:DRM 页魔术写四次全被静默丢弃(NS 只读,厂商路径仅安全态);
  emicen 监视器写者活跃时本关(+0xf8=0,非写者),init 调用=总线挂死;两次复位自愈、dump 均捕获
  (C-276..C-279,VERDICT §18)——U-G9_RESULT_2026-11-06.md,证据 _local/evidence/b4b/ug9/)。

- **2026-11-06 晨· 阻断路径离线普查**(纯分析,无新 claims):按"内容供给/目标捕获/注入通道"三环节
  分解写入必要条件,枚举七条存活路径并排优先级——**T1 FE→MED hnat_info 通道断供**(medmcu 固件已见
  STATUS/MSK 寄存器与 stop 路径,材料全在) > **T3 放逐窗**(ISU 8MB 保留 DRAM,引擎对保留窗可达性
  从未测过) > T2 SIP/SMC 全表(tee_b 34K 指令在手) > T6 后果层布防(nerepair 仍 dry/slotguard 仍
  observe) > T4 boot 链核查(SBC 运行时判定在,末位高风险) > T7 厂商;§2 附防翻案关闭清单。
  入口=[13_BLOCK_PATHS.md](13_BLOCK_PATHS.md)。
- **U-H(2026-11-06 日间)· 阻断路径首批上机判决**:T3 放逐窗正面关闭(保留子区窗照画不误,
  C-280);T5 谓词钉死 **32B FP 保存事务=目标捕获签名**(四形态臂全 0 vs natfp 0.86,C-282/C-283,
  浮出"变参 prologue 改形=自研二进制隐身"缓解候选);T6 门禁量化否决布防(nerepair 覆盖 23%、
  slotguard 槽漂移,C-284)。零复位,设备干净——U-H_RESULT_2026-11-06.md,VERDICT §19,
  证据 _local/evidence/b4b/uh/)。。
- **U-I(2026-11-06 下午)· T5 隐身落地+子因矩阵+T1 位图**:真实二进制去 FP 保存 prologue
  =600s 零外写(对照 68,P=e^-68,方案 A 前提 3/6 清);签名钉死=连续 FP 源保存区写入突发
  (nat2q 1.04/qoff 1.00/nat8s 0.55);写者强度 boot 依赖(λ 塌 12–24×);MED 位图
  0x38013000+停止 IPI 路径+AP 活体面 0x15104xxx(T1 断供两路成形);自伤复位 #24(seq
  十六进制陷阱,E0 恢复)。(C-285..C-291,VERDICT §20)——U-I_RESULT_2026-11-06.md,证据
  _local/evidence/b4b/ui/。
- **U-J(2026-11-06 傍晚)· stealth2 热 boot 复验+映射/计量+链①质疑**:0/52 复验(
  两 boot 合计 0/120,P=e^-120),性能 0.9996;AP=MED−0x22500000 钉死;FE→MED 通道寄存器
  AP 不可达(8 别名全零)→AP 寄存器断供分支关闭,剩厂商 IPI(待内核头树重建);hnat_info 环
  生产 ~0.55rec/s 稳态且**洪水开关不变**→"环记录=内容馈源"链①受质疑(C-258 修订入口=
  转发 vs 本地 INPUT 判定实验);dpwr 缓存读 DMA-DRAM 陈旧实锤。(C-292..C-296,VERDICT §21)
  ——U-J_RESULT_2026-11-06.md,证据 _local/evidence/b4b/uj/。
- **U-K(2026-11-06 夜)· 双线：T1 关闭（链①证伪）+ 头树重建+供给杠杆**:2×2 因子表
  ——feed 冻结后本地洪水 λ 仍 14.2/min(80%)⇒内容通道非必要非充分(C-300);λ 随设备面向
  处理活动(本地INPUT 17.7 vs 转发 4.6 vs 空闲 2.6,C-297);内核头树重建三级验证(编译/
  加载/功能,C-298);dpmaif_stop_rx_sw() 冻结环≥8min、start 不逆转、复位恢复(C-299)。
  程序重心转 Scheme A 落地+后果层修复。(C-297..C-301,VERDICT §22)——U-K_RESULT_2026-11-06.md,
  证据 _local/evidence/b4b/uk/。
- **U-L(2026-11-06 夜)· 写者"刻意"假设判别+供给环否证**:注入记录=真实活流采样
  (712 真实 IP、按流成串、CDN/云端点,C-302);落点=帧相对地址锚定(C-303);真环块
  0x15b38000/0x15b28080 找到(stop 真索引复测冻结,U-K 获验证;start 不恢复/复位恢复,
  C-304);"补消费端环"假设否证——环已使能服务且冻结不阻止沉积(C-305)。唯一杠杆=T5。
  (C-302..C-305,VERDICT §23)——U-L_RESULT_2026-11-06.md,证据 _local/evidence/b4b/ul/。
- **U-M(2026-11-06 夜)· T5 落地**：设备 musl=8×str-q 升序保存块(24 组,C-306);补丁器 v2
  双形态;libc(191)+busybox(161)+dnsmasq(16) 三件 bind-mount 部署,新进程即时隐身,功能全绿
  (C-307);gw 静态 busybox 过匹配事故已恢复(C-308);覆盖边界:wpad 仅 libc 面、静态未覆盖、
  击杀率下降未证(弱阳性)(C-309)。下轮:持久化+wpad/其余补丁+24h A/B。(VERDICT §24)
  ——U-M_RESULT_2026-11-06.md,证据 _local/evidence/b4b/um/。
- **U-N(2026-11-06 夜)· T5 持久化+24h 验收窗**:rc19 v2.40 boot 自检挂载隐身 libc
  (t=27.4s dmesg 证据),reboot 后系统全绿(selftest 103/105);v4 补丁器(140 站点)+三态电池
  成规;grep -r 崩溃=既有缺陷平反;T0=1793967674,/data/stealth/acc_report.sh 一键验收;覆盖
  诚实=libc 面(busybox/wpad 自指纹待 v5+沙箱)。(C-310..C-313,VERDICT §25)——24h 后验收。
- **U-O(2026-11-06 夜)· T5 覆盖面拉满**:v5(vr_offs 签名)重扫,libc140/busybox106/wpad24/
  ip-full2 四件电池+压测全等后 bind-mount;rc19 v2.41 多挂载,reboot 实测 dmesg
  'libc=1 bb=1 ip=1 wpad=1';新 hostapd 实例运行补丁 wpad(inode 证据);dnsmasq/logread/aee
  零站点=经 libc 已覆盖;gw 静态 busybox 149 站点但分派坏→拒部署(v6 入口)。24h 验收窗
  T0=1793970002,acc_report.sh v3。(C-314..C-317,VERDICT §26)






