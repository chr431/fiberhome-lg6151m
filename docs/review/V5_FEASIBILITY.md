# V5 可行性分析：以 lab v3.1（6.18.44）为基座，能否“停止 SIGSEGV 生产者 + 保持全功能”

> 任务：task-3（team_task 看板）｜分析员：v5-analyst｜日期：2026-11-03
> 性质：**离线静态分析**为主；正文中标注「设备只读实测」的条目来自 Lead 授权的两条只读快照（审计见附录 A），全程无任何写操作。
> 证据等级：**E0** 无证据｜**E1** 弱/单点｜**E2** 强推断｜**E3** 直接观测｜**E4** 因果闭环。
> 引用纪律：本报告**不引用**已撤回结论（88/112、自然 NE 0/4、C-138、C-145「Transport=PA/DMA（E2 已定）」、C-016/017/018/019）；凡涉及 D28/消融处一律带 §9 边界。
> **禁止的偷换**：本文不把 D28 的「厂商内核态环境是必要条件」当作「换主线内核即停写」。全文唯一允许的表述是 §2.4 的三段式。

---

## 0. 结论速览

### 0.1 三问短答（详见 §6）

| 问题 | 短答 | 等级 |
|---|---|---|
| (a) 含蜂窝的「全功能 V5」是否可能？ | **路径存在，“可能”；不是“可行”**——蜂窝内核侧管道在 lab 内核里实测在场，md1 固件由 LK 加载，且本项目自制 MIPC 工具只依赖 /dev/ttyCMIPC；但“md 在 lab 内核下能否起到可拨号状态”与“数据呼叫激活是否有非厂商路径”**两项均未验证** | E3（管道在场）/ E1（端到端可行） |
| (b) 仅有线/WiFi 上行的 V5 是否可能？ | **可能（E2 静态）**，但有线 ≫ WiFi：eth0/eth1 在 lab 实测 up（2.5G），WiFi 还需固件名映射 + EEPROM + hostapd 侧重建（未验证） | E3（有线）/ E1（WiFi） |
| (c) 它能否保证停止 SIGSEGV 生产者？ | **不能保证；当前证据未支持（E0/E1）**。D28 只给“厂商环境必要性”（E2），而 C-204 表明记录率主载体是 **WiFi 客户端数据面流量**；V5 点亮 WiFi = 重新引入数据面流量 + 硬件 DMA | E0/E1 |

### 0.2 本轮新增的五条硬事实（先看这里，它们同时改写了三处既有文档措辞）

| # | 事实 | 证据 | 等级 |
|---|---|---|---|
| **F-1** | **lab 6.18.44 并非“零厂商内核态代码”**：镜像内含 MTK CCCI/ECCCI/DPMAIF/MEDMCU/ccmni 全套内建驱动（System.map 458 个 ccci 符号），config 明文 CONFIG_MTK_CCCI_DEVICES=y / MTK_ECCCI_DRIVER=y / MTK_NET_CCMNI=y，且 D28 实机日志里 ccmni0..ccmni20、ttyCMIPC0..、DPMAIF probe 全部发生 | config-lab3-6.18.44:1686-1703；System.map.lab3（grep ccci = 458）；d28b.raw lab 段 | **E3** |
| **F-2** | **lab 会话中 WiFi 硬件已在总线上**：D28 lab boot 的 PCIe 域 11288000 建桥成功并枚举 0001:01:00.0: [14c3:7992]（MT7992）；构建出的 mt7996e.ko 含别名 pci:v000014C3d00007992 | d28b.raw lab 段（PCIe 枚举行）；_local/work/lab-kernel/artifacts/modules/mt7996e.ko strings | **E3** |
| **F-3** | **WiFi 四件套在设备上存在，但命名与主线驱动期望不一致**：设备 /lib/firmware/ 17 项，含 WIFI_MT7992_PATCH_MCU_1_1_hdr.bin / WIFI_MT7992_PHY_RAM_CODE_1_1.bin / WIFI_MT7992_WACPU_RAM_CODE_1_1.bin / WIFI_RAM_CODE_MT7992_1_1.bin / MT7992_EEPROM.bin；而主线 mt7996e.ko 期望 mediatek/mt7996/mt7992_{wa,wm,dsp,rom_patch}.bin，且 /lib/firmware/mediatek/ **为空** | 设备只读实测（2026-11-03 19:21:28 +0800）；mt7996e.ko strings；rp103 rootfs 本地捕获同源 | **E3**（文件在场）/ **E0**（可加载性） |
| **F-4** | **厂商栈实测清单（只读，未扰动）**：uname -r = 5.15.134；/lib/modules/5.15.134 172 个，在载 163；含 mt_wifi 8,028,160 B、mt7992、mt_wifi_cmn、mtk_hwifi、mtk_pci、mtk_wed 20,480 B、mtk_warp 679,936 B、hw_nat 1,376,256 B、mapfilter；netfilter 类 **58** 个在载（nf_tables 带 24 依赖 + iptables + ip6tables + ipset + ebtables）；CCCI 系列**不是模块**（内建）；/dev/ttyCMIPC0.. 在场 | 设备只读实测（19:21:42 +0800） | **E3** |
| **F-5** | **蜂窝内核侧管道在 lab 内核在场**：ttyCMIPC0..N + ccmni0..20 + DPMAIF 注册全部发生在 lab 6.18 引导期；initcall modem_cd_init ... returned 0 after 161901 usecs；而本项目 gw/src/mipc_cellular.c 的唯一设备依赖就是 /dev/ttyCMIPC%d | d28b.raw lab 段；mipc_cellular.c:175-176 | **E3** |

**F-1/F-2/F-3 与三处文档措辞冲突（不在本报告内自行调和，见 §8 待对账表）**：D28 §3/§11 与 C-213 的“零厂商内核态代码、无 CCI”；LABKERNEL.md §1 能力矩阵的“CCCI/ccmni 缺失”；LABKERNEL-V5-MEMO 第 30-31 行的“lab DTS 骨架未带 WiFi/connsys 节点”。

---

## 1. lab v3.1 已知“干净”到什么程度

### 1.1 D28 的形式要件与数字（**本轮独立复算过**，不是转抄）

| 项 | 文档值 | 本轮独立复算 | 出处 |
|---|---|---|---|
| 窗长 | 1800.023 s / 1800.019 s | 串口心跳推进至 2884 s / 2944 s（窗 2 后 shell 存活） | 05_LOG/2026-11-03-12-d28…§10.2；status-d28b.txt |
| inj=0 真命中 | **0**（两窗） | grep -c inj=0 = **0 / 0** | _local/evidence/d28/scanary_c2_w{1,2}.log（本地复算） |
| 正对照 inj=1 | 19 / 19 | **19 / 19** | 同上 |
| 形式要件 | EXIT reason=duration、selftest_ok=1、probe_bad=0、passes>0、29 STAT | 日志 88 行 / 49,641 B 与 88 行 / 49,643 B；SELFTEST_OK 各 3 行 | 同上 + §10.2 |
| 日志 md5 | b1220cdb… / f4b284cf… | **逐字节一致** | md5sum 本地复算 |
| rule-of-three 上界 | 0/3600 s ⇒ 0.05/min | 算术成立（3/3600 s） | §5 |
| 厂商背景对照 | 0.36-0.60/min ⇒ 期望 22-36 条 | 与 C-199（0.60/min 无客户端）、C-196（遮罩残余 0.167-0.20/min）自洽 | §11、C-199、C-196 |
| 信道三重 | 窗末 cat 全文上 console + 交互 shell 读文件 + p46 持久化 + 双端 md5 | 存在（§4、§10.2 记录） | §10.2、§11 |

**关于“仪器噪声”的诚实记录**：lab 6.18 上厂商 busybox awk 任何调用 SIGSEGV（RC=139），心跳 MemAvail= 恒空；判据未使用该字段（§10.2）。**不得**把它当作写入者活动的证据。

### 1.2 §9 混杂与边界（逐条搬出，**必须与判决同读**）

| # | 原文要点（§9） | 对本报告的直接后果 |
|---|---|---|
| 9-1 | lab 移除了 WiFi/CCI/客户端/长驻厂商进程 ⇒ **H 只能证明“厂商环境是必要条件”，不能证明“写入者是厂商代码”** | 任何“(c) 能停写”的论证都必须另找证据；H 本身不提供 |
| 9-2 | **目标页资格共线**：lab 的 initramfs 新页可能从未当过 RX 缓冲；若写入者是“stale PA/长驻页”机制，零结果可能是**目标缺席**而非写入者缺席；本轮**无法消除** | 这是“零结果 ⇒ 生产者消失”这条推理的**结构性缺口**（与 C-208 审计认定的信道缺陷同级，区别只在于 D28 已把信道补齐） |
| 9-3 | 版本差 **6.18.44 vs 5.15.134** | 任何“lab 特性 = V5 特性”的推论都带版本差；“V5 也用 6.18”只免掉这一项，**不等于**生产者消失 |
| 9-4 | 480 MB 保守内存节点 | 影响页历史/页池组成（与 9-2 同族） |
| 9-5 | 窗 2 与窗 1 同 boot，**两次窗口非独立**；判决只取合并暴露，不做速率推断 | 有效暴露 3600 s 是“合并”口径，不是两个独立样本 |
| 9-6 | 时间以 /proc/uptime 为准（无 RTC） | 实验设计中的时间锚定纪律 |

### 1.3 H 的准确口径（防偷换）

H 的**全部**内容是：**“32B 记录写入者的产生/触发需要厂商内核态环境”**（§11；C-213 同）。它**不**包含：写入者是厂商代码、主线内核上一定不写、换了内核就等于停写。级别 **E2**（有效窗本身 E3，归因受 §9 边界限制）。

### 1.4 F-1 对 H 口径的冲击（本轮最重要的发现之一）

D28 §3 把 ablated 集写成“零厂商内核态代码、无厂商 .ko、无 WiFi、无 CCI、无客户端”；但实测：

- **内核镜像内**：config-lab3-6.18.44:1686-1703 = MTK_CCCI_DEVICES=y / MD1_SUPPORT=12 / ECCCI_DRIVER=y / ECCCI_CCIF=y / NET_CCMNI=y / TINYSYS_MEDMCU_RV33_SUPPORT=y；System.map.lab3 中 ccci|ccmni|ccif 命中 **458** 个符号（含 ccci_load_firmware、ccci_md_mem_reserve、ccci_fsm*）。
- **实机引导期**（D28 同会话 d28b.raw lab 段）：[ccci1/mcd][POWER ON] MD MTCMOS ON start/end、initcall ccci_hif_dpmaif_init returned 0 after 6537 usecs、initcall modem_cd_init returned 0 after 161901 usecs、ccmni0..ccmni20、ttyCMIPC0..N、[ccci0/dpmaif] test_irq_no ret = 0。
- **LK 阶段**：同日志里 [CCCI]Load image: [md1rom] from partition: [md1img] + md1dsp（即 **modem 固件由 LK 装入**，与 AP 内核是否厂商无关）。

⇒ 正确的 ablated 集表述应是：**“无厂商 .ko、无厂商用户态、无 WiFi 接口/客户端、无长驻厂商守护”**；**“厂商内核态代码”与“CCCI/MD”这两项并没有被 ablation 覆盖**——它们在场（至少驱动与数据面在场）。这**不推翻** H（H 是集合级必要条件，被真正移除的元素仍足以解释零结果），但它**缩小了 H 的适用范围**，并直接削弱任何“V5 用主线内核 ⇒ 不会写”的论证：**V5-lab 与 D28-lab 的差异比文档以为的小**（同类 CCCI 内核代码在场，差别只在用户态、WiFi 与客户端流量）。

> 口径建议（供 Lead/文档维护者采纳）：把 H 改写为“**在无 WiFi 接口/客户端流量、无厂商 .ko 与厂商用户态的极简 initramfs 环境中，3600 s 内 0 条**”，不要再写“零厂商内核态代码”。

---

## 2. 逻辑审查：H 成立 ⇒ “V5 建在 lab 基座上就不会产生记录”？

### 2.1 结论：**推不出来**。要推出来至少需要 4 条附加前提，全部未被证据支持

| # | 附加前提 | 现状 | 依据 |
|---|---|---|---|
| P1 | lab 窗内**所有**能触发生产者的“厂商供给物/触发器”都被移除，且 V5 也不再引入 | **假**：lab 窗是“无 WiFi 接口 + 无客户端流量 + 无厂商 .ko/用户态”，但 C-204 指出触发主载体是 **WiFi 客户端数据面流量**；V5 点亮 WiFi 就重新引入 | §9-1；C-204；C-196/C-199 |
| P2 | 生产者不依赖“目标页资格”（stale/长驻页），零结果不是目标缺席 | **未知**：§9-2 明写“本轮无法消除该共线混杂” | §9-2 |
| P3 | 6.18 lab 与 5.15 厂商内核在“生产者可达性”上同类 | **未验证**：仅知 H 在 6.18 上零、在 5.15 上非零；差异可能来自版本/配置（480 MB 节点、无厂商 .ko） | §9-3/§9-4 |
| P4 | “停止生产者”可由**更换内核与用户态**实现，而非由“移除流量与目标”实现 | **未知**：V5 的目标恰恰是把流量与目标**加回来**（WiFi AP + 客户端 + 蜂窝上行） | §2.2 |

### 2.2 逐条混杂清单（V5 会重新引入什么）

| 混杂 | lab v3.1 窗内实际状态（实测） | V5「点亮 WiFi」后 | 证据 |
|---|---|---|---|
| **WiFi 客户端数据面流量** | 无（无 wlan 接口、无客户端） | **有**（AP + 关联客户端 + TCP 数据面） | d28b lab 段无 wlan；C-204 |
| **WiFi 硬件与 DMA 引擎** | 硬件在总线上（F-2），但**驱动未加载、无 TX/RX 环活动** | mt7996e 加载并跑 PCIe DMA 环（lab DTS **无 wed@ 节点** ⇒ 走 PCIe DMA 而非 WED offload） | F-2；lab DTS grep wed@1501=0 |
| **记录率量级** | 0 / 3600 s（上界 0.05/min） | 参考同调查对照窗：无客户端 0.60/min、客户端热态 13.87-20.33/min | D28 §11；C-199；C-204 |
| **厂商内核态代码** | **在场**（CCCI/DPMAIF/MEDMCU 内建；F-1） | 在场（同族，且换主线 6.18 版） | F-1 |
| **厂商 .ko** | 无（initramfs 只有 5 个自建 WiFi 预备模块，未加载） | 无（V5 若走主线则继续无） | lab_init_v3.sh:155-156；labkernel/README「B 五模块只构建不加载」 |
| **厂商用户态（mipc/RIL/dial）** | 无 | 无（若 V5 自建）或有（若复用） | §3/§4 |
| **长驻厂商进程** | 无 | V5 自己的守护会顶上（新进程、新栈、新槽位） | C-173（健康进程栈也含记录） |
| **蜂窝数据面** | 驱动在场且已注册 ccmni/ttyCMIPC，但无用户态拨号 ⇒ 无数据流量 | 若有数据流量 ⇒ 新增一条数据面 | F-5 |

### 2.3 关键逻辑句（本题的诚实点）

> D28 的零结果发生在 **“没有 WiFi 客户端流量、没有数据面”** 的窗口里；V5 的定义恰好是**把这些加回来**。因此 H（厂商环境必要条件）**既不支持也不否定**“(c)”；它只说明“当前这套极简组合下不写”。**“停止生产者是否已被证据支持” = 未被支持（E0/E1）**，而不是“已被否定”。

### 2.4 允许的表述（三段式，供对外引用）

1. **已支持（E2）**：32B 记录的**产生/触发**需要厂商内核态环境（D28，带 §9 全部边界）。
2. **未支持（E0/E1）**：把 lab 基座扩成 V5（点亮 WiFi/蜂窝）之后生产者是否停止。
3. **不可推断（禁止）**：由 1 直接得出“换主线内核即停写”。

---

## 3. 全功能清单（枚举 + 逐项可行性）

### 3.1 “全功能”的边界（从 gw/ 实际功能面出发）

gw/ 顶层 51 个 shell 脚本 + 5 个配置文件 + 20 个自建二进制（gw/bin/，含 3 个内核模块 v3_fix.ko/v3_steth.ko/healthdog.ko）+ 18 份源码（gw/src/），由 rc.extend.sh 按槽位调度（rc.extend.sh:189-241）；svc_lib.sh 的声明式守护表 **14 行**（svc_lib.sh:328-343）：ntp_keeper / traffic_logger / wifi_guard / reboot_sched / led_mgr / fan_mgr / wan_eth / log_keeper / healthdog / dial_keeper / usb_mgr / nerepair / slotguard / fast_watch。

### 3.2 功能 × 可行性矩阵

> 「厂商栈现状」列 = 设备只读实测（附录 A）或仓库版本表；「lab 可行性」列 = 静态判断，**不写“可行”**，只写 可做 / **需实证** / **不可能**。

| 功能 | 厂商栈现状 | lab 6.18 + 主线用户态 | 阻塞点 | 证据 |
|---|---|---|---|---|
| LAN 桥 + IPv4 + DHCP | 开（br-lan 192.168.9.1/24；dnsmasq 单进程） | **可做** | 仅用户态（dnsmasq 静态 musl 构建）；内核 CONFIG_BRIDGE=y 已在 lab config | config BRIDGE 段；ARCHITECTURE.md:91 |
| WAN 有线（eth 上行，DHCP 客户端） | 开（eth1 家宽口） | **可做（把握最大）** | 无：lab 实测 eth0/eth1 Link is Up 2.5Gbps | d28b lab 段 netup 输出；config:2075 NET_MEDIATEK_SOC=y |
| WiFi 2.4/5G AP | 开（mt_wifi 8 MB + mt7992 + mt_wifi_cmn + mtk_hwifi + mtk_pci + cfg80211(compat)；vendor hostapd） | **需实证**（三件套：固件名映射 / EEPROM / hostapd 侧重建） | ①主线期望 mediatek/mt7996/mt7992_*.bin，设备只有厂商命名且 mediatek/ 空（F-3）；②EEPROM 选型；③lab DTS 无 wed@ 节点（只能走 PCIe DMA）；④wifi_up.sh 的 dat 配置层是厂商私有 | F-2/F-3；lab DTS grep wed@=0；V5-MEMO:26-32 |
| WiFi 分析/信道图/访客隔离 | 开（wifimgr + ebtables 隔离） | **需实证** | 隔离依赖 ebtables/netfilter（lab **无 netfilter**） | config NETFILTER/NF_*=0 命中；FEATURE_MATRIX §2.4 |
| 蜂窝上行（数据面 + 拨号） | 开（CCCI **内建**、/dev/ttyCMIPC0..、mipc_wan_cli/mipc_submonitor/mobilenetwork） | **需实证**（F-5 之后不再是“不可能”） | ①md 在 lab 内核下能否起到可拨号状态（引导期有 md1 get scp-sys-md1-main failed）；②数据呼叫激活目前依赖厂商二进制 mipc_wan_cli（ccmni_up.sh:34），或需在自制工具里重写；③SIM/RF/网络注册态未知 | F-5；ccmni_up.sh:34 |
| 上行认证插件插座（AUTHD_CMD/uplink.conf/plugins.js） | 无此概念（自研） | **可做（零内核依赖）** | 无——纯用户态 socket + 动态页面 | ARCHITECTURE.md:19、:62；FEATURE_MATRIX §2.3 |
| Web GUI（v3httpd + api.sh + SPA） | 无（厂商 nginx+webs/FastCGI） | **可做** | 仅用户态静态 musl 构建（toolchain_init.sh 链已验证） | ARCHITECTURE.md:68；labkernel/README 环境节 |
| dnsmasq（池+静态租约+双上游） | 开（厂商版 + 端口绑定私补丁） | **可做** | 需自建 musl dnsmasq；DNS 劫持类规则需 netfilter（当前缺） | ARCHITECTURE.md:91；FEATURE_MATRIX §2.3 |
| watchdog/fast_watch/svc_lib（14 守护监督） | 自研 | **可做** | 纯用户态 + /proc（lab 有 /proc、/proc/net/tcp*、/proc/<pid>/stat） | svc_lib.sh:328-343 |
| healthdog（healthdog.ko + healthdog.sh） | 自研模块（在载 20,480 B） | **可做（需移植）** | healthdog.c 只用标准内核 API（proc/timer/reboot/sched），无厂商符号；MEDIATEK_WATCHDOG=y 已在 lab（D28 实测 mtk-wdt ... Watchdog enabled） | healthdog.c:19-31、:117；d28b lab 段 wdt 行 |
| NTP（ntp_keeper 多源 + /tmp/ntp_synced） | 自研（busybox ntpclient，8 s 硬超时） | **可做** | 纯用户态；无 RTC 约束与厂商内核无关 | ntp_keeper.sh:11-12、:26 |
| LED（WiFi/5G/WAN 通道） | gpio 467/474/475/473 + leds-gpio(gpio292) + mediatek,pwm-leds | **需实证** | lab config **缺** LEDS_GPIO/PINCTRL_MTK（有 PINCTRL_MTK_PARIS=y、GPIO_SYSFS=y）；mediatek,pwm-leds 非主线驱动 | led_mgr.sh:20-29、:87-103；config LEDS_GPIO not set |
| 风扇（原厂梯度温控） | /sys/devices/platform/pwm-fan@1/hwmon/hwmon1/pwm1 | **可做（DTS 已在，实测 probe 通过）** | 路径/挡位表需适配；lab 实测 probe of pwm-fan returned 0、pwm-fan-aux returned 0；config SENSORS_PWM_FAN=y | fan_mgr.sh:10-14；d28b lab 段 probe 行 |
| IPv6（ULA + radvd + LAN v6 收敛） | 自研（radvd + v6_reconcile） | **部分可做** | LAN 侧可做（radvd 用户态）；**NAT66 需 netfilter/ip6tables**，lab config 无 netfilter | v6_reconcile 版本表行；fw_apply.sh:69-85 |
| NAT/端口映射/DMZ/WAN 纵深（fw_apply） | 开（iptables + ip6tables + nft/ipset/ebtables 共 58 模块） | **需实证（先补内核 config）** | lab config **完全没有 netfilter**（CONFIG_NETFILTER 无命中）；netfilter 是主线，加回来是“配置工作”而非“移植工作”，但**需重编内核 + 全量回归** | fw_apply.sh:20-24、:52-85；config NETFILTER=0；设备只读实测 58 模块 |
| wan_agg（多 WAN 分流/聚合/failover） | 自研（iptables MARK/fwmark + 源端口段拆分） | **需实证** | 依赖 netfilter mangle/MARK + MASQUERADE（缺）+ 策略路由（IP_MULTIPLE_TABLES=y 已在） | wan_agg.sh:250-261、:294 |
| netlock（写方串行化） | 自研（flock/目录租约） | **可做** | 纯用户态 | netlock.sh 版本表行 |
| avail_sampler / incident_ledger / log_keeper / core_meta / stackdump | 自研（读 /proc、core_pattern 管道） | **可做（aee 部分除外）** | lab 无厂商 aee forwarder ⇒ core_meta 的 exec aee 尾段无对象；其余主线可用 | core_meta.sh 版本表行；rc.extend.sh:86-93 |
| TTL 伪装 + PPE 解绑（v3_fix.ko） | 自研模块，**依赖厂商符号** ppe_hook_rx_eth / quec_eth_rx_hook | **需实证（必须重写）** | ①TTL 部分可用 netfilter hook（需先补 netfilter config）；②PPE 解绑部分在 lab 无对应对象（System.map 无 mtk_hnat 驱动符号；主线 mtk_ppe 是另一套绑定） | v3_fix.c:19-22、:68-69、:142 |
| USB-C RNDIS/ADB（usb_mgr） | 厂商 usb_net.ko 建 rndis0；/config/usb_gadget/g1 | **需实证** | lab config **无** USB_GADGET/USB_CONFIGFS/USB_F_RNDIS ⇒ 需补 config + 主线 configfs gadget 重搭 | usb_mgr.sh:12-15、:35-37；config not set |
| 蜂窝锁定/小区/SMS（mipc_cellular） | 自研工具走 /dev/ttyCMIPC（零 RIL） | **需实证（依赖 §4 蜂窝结论）** | 工具本身可移植；前提是 md 能起 | mipc_cellular.c:20-21、:61、:175-176 |
| traffic/soak/retention/diag（自研观测层） | 自研 | **可做** | 纯用户态 + /proc + /sys | 版本表 gw 行 |

---

## 4. 硬边界与半可行（逐条：可做 / 需实证 / 不可能 + 工作量）

> 工作量单位 = 人日（1 人 x 1 天）；区间依据写在“依据”列。**一次性** = 做完即长期可用；**长期** = 每次内核/驱动/固件变动都要重复的维护成本。

| # | 条目 | 判定 | 工作量（一次性 / 长期） | 依据 |
|---|---|---|---|---|
| B-1 | 持久 rootfs（p26 squashfs 或 ext4 数据分区 + 组装管线） | **可做** | 3-8 / 每次版本 0.5 | CONFIG_SQUASHFS=y、EXT4_FS=y（config 段）；/bin/romount 已就位（LABKERNEL.md:28）；v4.x 已有 squashfs 生产经验 |
| B-2 | 主线用户态服务栈重建（dnsmasq/GUI/SSH/守护） | **可做** | 10-25 / 1-2 | gw/ 现有 55 脚本 + 20 二进制规模；musl 交叉链已在（labkernel/README 载荷节）；其中约 60% 与内核无关可直接复用 |
| B-3 | netfilter 全家（iptables/ip6tables/nft/conntrack/ipset/ebtables） | **需实证** | 3-6（config + 依赖闭包 + 回归）/ 0.5 | lab config 0 命中；主线组件；但 fw_apply.sh / wan_agg.sh / guest_fw.sh 三条写入方全依赖它，回归面大（netlock 串行化已就位可复用） |
| B-4 | WiFi 三件套 | **需实证** | 5-15（区间宽因为固件映射未知）/ 每次固件升级 1-3 | F-2（PCIe 枚举 OK、模块 ID 匹配）+ F-3（固件在场但命名不符、mediatek/ 空）；lab DTS 无 wed@ 节点（= 只能 PCIe DMA）；hostapd 侧需自建 |
| B-5 | 蜂窝（md1/md3 + CCCI 私栈） | **需实证**（**不是不可能**） | 5-15 起（含“md 起不来”的止损点）/ 1-2 | **F-5**：CCCI/ccmni/ttyCMIPC 在 lab 内核已在（E3），md1img 由 LK 加载（E3，同会话日志），项目自制工具只依赖 ttyCMIPC；未知项 = MD 在非厂商 AP 内核下的 FSM/注册状态（引导期 md1 get scp-sys-md1-main failed 是黄灯）+ 数据呼叫激活的厂商二进制替代 |
| B-6 | 复用厂商二进制用户态（mipc/RIL/ql_*） | **不可能**（直接复用 5.15 二进制） | — | 闭源 + 与 5.15 内核接口/库强耦合（V5-MEMO:42-43）；仅“自有工具重写”路径可行（含在 B-5 内） |
| B-7 | SMMU/IOMMU 兜底（R2） | **不可能** | — | FIX.md §7.3：本内核 CONFIG_IOMMU_SUPPORT 未置；vmlinux 0 处 smmu；无 arm_smmu_*/mtk_iommu 符号（**本轮在 lab 镜像上复核：System.map.lab3 mtk_iommu|iommu_ 命中 0**） |
| B-8 | NAT/PF 内核模块 | **需实证**（= B-3） | 见 B-3 | lab config 未带（V5-MEMO:19 已如实写；本报告复核成立） |
| B-9 | cpufreq/DVFS 档位策略 | **需实证** | 2-4 / 0.2 | lab config ARM_MEDIATEK_CPUFREQ=y（config:570）已带驱动；缺的是档位表/策略与长跑散热标定；V5-MEMO:20-21 的“lab 骨架未启用 g3d_dvfs/cpufreq 节点”需按此重新表述（config 有驱动 != 有策略） |
| B-10 | kexec 用户态（/bin/kjump） | **可做（一次性小任务）** | 1-2 / 0 | 内核侧 KEXEC=y / KEXEC_FILE=y（config 段）；kjump.sh 已如实报缺（LABKERNEL.md:117） |
| B-11 | LED/pwm-leds 通道 | **需实证** | 2-4 / 0.2 | 见矩阵 LED 行：需补 LEDS_GPIO 等 config；mediatek,pwm-leds 非主线 ⇒ 走 gpio-leds 或移植 |
| B-12 | USB gadget（RNDIS/ADB） | **需实证** | 3-6 / 0.5 | config 未带 USB_GADGET/CONFIGFS（grep not set）；主线可做，但要 config + DTS + 用户态重建 |
| B-13 | v3_fix.ko（TTL/PPE 解绑） | **需实证（重写）** | 2-4 / 0.3 | v3_fix.c 依赖厂商符号（:68-69）+ netfilter hook（:142）；lab 无 hnat 符号 |
| B-14 | 厂商 hostapd 的 F3 安全层/MLD/160MHz 特性 | **不可能直接复用** | 0（需重评估）/ — | 依赖厂商 mt_wifi 私有接口（FEATURE_MATRIX §2.4「hostapd F3 单进程 3 BSS（PMK 直喂）」）；主线 mac80211/hostapd 语义不同 |

**汇总工作量级（粗算，供排期）**：

- 「仅有线 + LAN + GUI + 观测层」V5（不含 WiFi 驱动、不含蜂窝、含 netfilter 补全）≈ **25-50 人日一次性 + 1-3 人日/月长期**。
- 再加 WiFi ≈ **+8-20 人日**（含固件映射失败的返工）。
- 再加蜂窝 ≈ **+8-20 人日**，且带一个“md 起不来就到此为止”的止损门（未验证项）。

---

## 5. 若不追求全功能：最小可行的“停止生产者”路线（≥3 备选比较）

| # | 路线 | 内容 | 代价 | 风险 | 是否“停写” | 证据/等级 |
|---|---|---|---|---|---|---|
| A1 | **FIX.md §7.1 单调用点补丁** | 点名到具体调用点后，在该 bl 装 shim：find_vma + 判用户栈 VMA → 命中即拒绝并记日志；**先做 armed=0 检测版** | 1-2 人日（检测版）+ 24 h 窗 | 点错 = 误伤/漏杀；find_vma 约 100-200 ns/次，只在单点可接受 | **是（若点名正确）** | FIX.md:405-412（E1，未点名） |
| A2 | **FIX.md §7.2 厂商 R1** | 要求厂商在释放 RX/TX 缓冲前停 DMA/清描述符，或 TXD 用 bounce buffer | 需厂商源码/NDA + 一次固件升级（不可离线完成） | 交付周期不可控 | **是（唯一彻底路径）** | FIX.md:414-417 |
| A3 | SMMU/IOMMU（R2） | 用 IOMMU 把“写复用用户页”变成 IOMMU fault | — | — | **不可行** | FIX.md:419-423（E3）；本轮复核 lab 同样 0 符号 |
| A4 | 关 WED offload（R3） | 运行期 rmmod mtk_wed / 重启后不加载 | 0 人日（V5-lab 上默认就没有 WED 节点） | **rmmod 1/1 触发 Oops + 自动重启，禁止再试** | **否**（C-211/C-197 已弱化 WED 嫌疑） | FIX.md:425-428；C-155；C-211 |
| A5 | 后果层：nerepair + slotguard（现状） | 修信号 / 消毒热槽，**不停止写入** | 已交付 0 增量 | 内存破坏面不变（R-11） | **否** | FIX.md:398 R-11（E3） |
| A6 | **V5-lab 天然无 WED/无厂商 .ko** | 不把 A4 当动作，而是把“不启用 WED offload”作为 V5 设计约束 | 0 人日 | 收益不确定（WED 已被弱化） | **否** | C-193（hw_nat 遮罩后仍 690/1200 s）、C-211 |

**排序建议**：若目标是“停写”，**A1（点名 + 单点补丁）是唯一能在离线/自持条件下推进的**；A2 是终局但不可自持；A4/A5/A6 都不是“停写”。

---

## 6. 判决（三问，含证据等级与需补实验）

### (a) 含蜂窝的“全功能 V5”是否可能？

**“可能”，但不是“可行”。** 路径存在：蜂窝的**内核侧管道在 lab 内核里实测在场**（F-5：ccmni/ttyCMIPC/DPMAIF），modem 固件在设备上并由 LK 装入（E3），而项目自己的工具链（mipc_cellular）只依赖 /dev/ttyCMIPC。这与 LABKERNEL.md/V5-MEMO 的“蜂窝不可能（硬边界）”**方向相反**。
但仍有两个未验证项把“可能”挡在“可行”之外：① md 在非厂商 AP 内核下能否完成 FSM/注册（引导期 md1 get scp-sys-md1-main failed）；② 数据呼叫激活的厂商二进制（mipc_wan_cli）替代。
**等级**：E3（内核管道在场）/ E1（端到端可行）｜**需补**：一次 lab 引导 + 只读 mipc_cellular cells（见 §7 的 N3 臂，**需 Lead 另行授权**）。

### (b) 仅有线/WiFi 上行的 V5 是否可能？

**可能（E2 静态）**。有线是最有把握的一档（eth0/eth1 在 lab 实测 up 2.5G、驱动编入）。WiFi 仍属“需实证”：PCIe 枚举与模块 ID 已对上（F-2），但固件命名/格式映射、EEPROM 选型、hostapd 侧重建三项全未验证（F-3）。
**注意功能面缺口**：即使“上线”能通，**NAT/防火墙/端口映射/访客隔离/wan_agg** 这些“全功能”要件全部依赖 lab **缺失的 netfilter**（B-3）。
**等级**：E3（有线）/ E1（WiFi）/ E2（netfilter 可补）。

#### (b) 补充："WiFi-less V5"（完全不点亮 WiFi）的暴露与功效

若 V5 **完全不点亮 WiFi**，它相对 lab 基线是“**少加回一个变量**”的版本，必须单独给暴露评估（不能用 (b) 的 WiFi 结论顶替）：

- **最贴近的对照**：B4/B4b 的 **WiFi 栈整族遮罩臂**（8 项遮罩生效、0 个 WiFi 接口、无客户端）→ C-196 arm1b = **5 / 1800 s = 0.167/min**（预注册冻结判据，P=8.5e-166 对 bracketing 基线 13.51/min）。更宽的一档是 C-199 的 **0.60/min**，但那是“WiFi AP 在、0 客户端”（栈在、流量无）。本版本结构上是前者 ⇒ 预期残余 **0.167–0.60/min** 区间。
- **暴露功效**：单窗 1800 s ⇒ 期望 5–18 条，P(0)=e^-5…e^-18 ≈ 6.7e-3…1.5e-8（**单窗零结果不足以判定**，下端只有 p≈0.007）；双窗 3600 s ⇒ 期望 10–36 条，P(0)=e^-10…e^-36 ≈ 4.5e-5…2.3e-16（**双窗零结果才有判决力**；rule-of-three 上界 3/T ≈ 0.05/min）。
- **能证明什么**：若出现 ≥1 ⇒ 生产者**不需要 WiFi 接口**（在主线内核 + 无 WiFi 条件下仍可达）⇒ “V5 停写”当场证伪（强结论，存在性判据）。
- **不能证明什么**：若为零 ⇒ **不能**推出“生产者已停”——该版本**没有加回 C-204 认定的主载体（WiFi 客户端数据面流量）**，零结果与“触发器缺席”不可区分（与 D28 同族缺口，§1.2 9-2/9-3 仍在）。它至多把上界定在 0.05/min 量级（3600 s），并与 D28 的上界互为**独立复现**，而不是“停止生产者”的证据。

### (c) 它能否保证停止 SIGSEGV 生产者？

**不能保证；当前未被证据支持（E0/E1）**。理由见 §2：H 只证明“厂商环境必要条件”，而 lab 窗内**没有 WiFi 客户端数据面流量**，V5 点亮 WiFi 正是把 C-204 认定的主载体加回来；且 lab 窗内 CCCI/MD 内核代码与数据面**本来就未 ablation**（F-1），说明“零结果”的成因比文档所述更窄。
**要把它从“未支持”提升为“支持/否证”，必须做 §7 的决定性实验**；在此之前，任何“V5 能停写”的表述都是把必要条件当充分条件。

---

## 7. 决定性实验设计（预注册模板，针对 (c)）

> 目的：判定“在 lab 基座（6.18 主线内核）上把 WiFi（与可选蜂窝）点亮之后，32B 记录生产者是否重新出现”。
> 设计原则：**判据集合 = 被判定对象集合**；全量；token 精确；排除自身；不把周期检查当判据；一窗一变量。

### 7.1 假设与判据（先写死）

| 分支 | 判据（全部满足） | 结论 |
|---|---|---|
| **R（重新出现）** | 有效窗内 inj=0 真命中 ≥1 | 生产者**不依赖厂商 .ko/用户态**；V5 点亮 WiFi **必然**重新引入 → “(c) 否证”（强结论，存在性判据无需速率推断） |
| **Z（仍为零）** | ≥2 个有效窗（合计 ≥3600 s）inj=0 = 0，且**同一晚**厂商内核正对照臂 ≥1（或按 bracketing 基线 ≥1 条/min 量级） | 生产者**未被主线 WiFi 通路触发**；“(c)”在**有限口径**下支持（仍不得外推为“保证停写”） |
| **I（无效）** | 形式要件任一缺失（见 7.3） | 该窗不计入；两窗皆无效 ⇒ 整场 INVALID |

### 7.2 臂与窗口（一窗一变量；跨臂不同 boot 只做存在/消失二分）

| 臂 | 环境 | 变量 | 期望（若 C-204 机制成立） |
|---|---|---|---|
| **N0** | lab 基线（无 WiFi 接口） | 参照 | 0（已有 D28 两窗，可复用但需同会话正对照） |
| **N1** | lab + mt7996e 加载 + AP up，**0 客户端** | WiFi 接口存在 | 参考厂商无客户端背景 0.60/min（C-199） |
| **N2** | lab + AP + **PC 关联 + 持续数据面流量**（固定 fetch 速率） | 客户端流量 | 参考厂商热态 13.87-20.33/min（C-204） |
| **N3**（可选，需另授权） | lab + 蜂窝 ccmni 起 + 数据呼叫 | 蜂窝数据面 | 无历史对照 ⇒ 探索性 |
| **B**（正对照，必须） | 厂商 5.15.134 内核，**同 scanary 二进制同调用**，同夜 | — | 必须 ≥1；否则仪器在该环境下无功效，Z 不可判读 |

### 7.3 形式要件与信道（缺一该窗无效）

1. START 行参数与预注册**逐字一致**；EXIT reason=duration；selftest_ok=1；probe_bad=0；passes>0 且 STAT 存在。
2. 正对照：SELFTEST_OK t1_decoy/t2_stack + ≥1 条 HIT_* inj=1。
3. 信道三重（D28 §4 已实证可用）：窗末**全文 cat 到 console** + 交互 shell 读文件 + 持久化到 p46 + **设备/PC 双端 md5 一致**。
4. **环境清单（本轮新增，必须记录）**：uname -r、ls /sys/class/net/、ls /dev/ttyCMIPC*、dmesg 中 ccci 计数、PCIe 枚举行、lsmod 计数——**用于证明本窗 ablation 集到底是什么**（D28 的教训：被断言移除的东西其实在场）。
5. **判活判据（判据三定律合规）**：读**全量** /proc/*/stat 的 (comm) 做**整串精确**比较，显式排除自身 $$ 与 $PPID（lab_init_v3.sh:198-214 已是此实现，照抄，不得回退到 pgrep -f）；scanary 存活以**日志内容**（STAT 推进 + EXIT）为准，不以心跳/周期检查为准。

### 7.4 停止规则 / 预算 / 红线

- 每臂最多 2 窗 x 1800 s；lab 启动 panic 预算 2，第 3 次中止回滚。
- 串口 >5 min 无输出 ⇒ 按 I 处理；THERMAL_ALARM ⇒ 立即回滚。
- **不写 p26/p38/p39**；p25 门禁与读回校验照 D28 §7；misc 只读（TRY_A 由 v3.1 /init 自清 p1@2061）。
- 观测窗内只轮询心跳，不发命令；**实验结束后**再取环境清单与日志（避免观测者污染）。

### 7.5 分析口径与功效

- 主终点唯一：inj=0 计数（存在/消失二分）。次终点（形状同族性、slot 分布）全部探索性。
- 功效：若 N2 的真实率 ≥ C-204 热态下界（13.87/min），1800 s 期望约 416 条，**零结果的 P(0)=e^-416**，检出功效约等于 1；若真实率仅 0.60/min（无客户端），1800 s 期望 18 条，P(0)=e^-18。⇒ **只要 N2 有 C-204 的量级，本实验对“重新出现”有决定性功效**；反过来，若 N2 为零，其上界 = 3/1800 s 约 0.1/min（rule-of-three，带“暴露已证实”前提）。
- 跨 boot 不做速率推断（项目既定纪律）；0/N 一律附 N、LOD、正对照。

### 7.6 混杂控制（针对 §2 的 P1-P4）

| 混杂 | 控制 |
|---|---|
| P1 供给物回不来 | N1/N2 逐窗记录环境清单（7.3-4），证明 WiFi 栈/客户端流量**确实**在场（不是“配置写了”） |
| P2 目标页资格 | 每窗记录 /proc/meminfo 与页池状态；N0 与 N2 用**同一** initramfs/模块集（除 WiFi 开关）；把“目标页资格”作为**声明缺口**保留，不做消除性断言 |
| P3 版本差 | B 臂同夜同机；lab 侧固定同一镜像 md5 |
| P4 停了又加回 | N0 → N1 → N2 是**只加不减**序列：若 N0=0、N2≥1，则“停写”被证伪；若 N0=0、N1=0、N2=0，仍只能写“在本设计的暴露内未出现” |

### 7.7 复现材料（一次写定，勿手改）

- scanary：md5 17376b743d1df55240b77f8f0be0fdae（与厂商臂同源）；调用参数逐字同 D28 §3。
- lab 镜像：boot-lab31-signed.img md5 9934cca26d2dda425eae406ca97fb865（**注意：若要点亮 WiFi 需另出一个 v3.2 变体并单独钉 md5**）。
- **判据必须与脚本逐字对齐**（预注册前把下面两套抄进去；早前版本写的“len 0x100..0x10000 + 4 段 IP 1..254”是 canary/h4 shape 扫描（C-163）的口径，**不是**本实验的判据，已删）：
  - **主终点判据 = 仪器自身 matcher（scanary）**：源 `tmpfiles/repro/scanary/scanary.c`，二进制 md5 17376b743d1df55240b77f8f0be0fdae。`classify()` 前置 w[1]==0 && w[3]==0 && w[2]!=0（:262-263）；**R2 = loose**；**R1 = len ∈ [0x40, 0x20000]（:268）且 ip_class ∈ {1,2}（:269-271）**；**R1L = 额外 ip_class==1（:271）**；**R3 = w2 == 0x0109a8c000000641（:273）**；规则串逐字见 START 行 `rules=R2(loose)|R1(w1==0&&w3==0&&len[0x40,0x20000]&&ip-unicast)|R1L(+private)|R3(w2==0x0109a8c000000641)`（:1002-1003）。`ip_class()`（:245-256）：0=IP 全零、1=私有/本地（10/127/172.16-31/192.168/169.254）、2=普通单播、3=非法（首段 0/255 或 ≥224）。主终点计数只取 scanary 自身 `HIT_*` 行的 **inj=0**（inj=1 为自检注入，不计）。
  - **后验栈扫描判据 = natne_scan.py**（路径 `_local/work/crash-root/fix/natne_scan.py`）：`LEN_MIN, LEN_MAX = 0x400, 0x20000`（:29）；`plausible_ip()` **只校验首段**（网络序 IPv4，`1 <= b[3] <= 223 or b[3] in (0, 255)`，:36-40）；形状沿用 w[1]==0 && w[3]==0 + A0B2/B0A2（:43-56）；扫描 stride 4、32 B 去重（:72、:79-85）。
  - **两套不是同一判据**（len 下限 0x40 vs 0x400；IP 校验“unicast 类” vs “仅首段”）：预注册必须写明**主终点用哪一套**，且 canary / 自然 NE / 健康三套语料必须用**同一套**重扫；不得跨套混用数字。

---

## 8. 待对账表（文档数字/措辞矛盾，**不自行调和**，双方出处并列）

| # | 冲突点 | 说法 A（出处） | 说法 B（出处） | 处置建议 |
|---|---|---|---|---|
| T-1 | lab 是否有厂商内核态代码 | “零厂商内核态代码、无 CCI”（D28 §3；C-213；00_STATE §0） | config MTK_CCCI_DEVICES=y 等 6 项（config:1686-1703）+ System.map 458 ccci 符号 + D28 会话日志 ccmni/ttyCMIPC/DPMAIF | **A 应订正为“无厂商 .ko/无厂商用户态/无 WiFi 接口与客户端”**；H 口径随之收窄 |
| T-2 | lab 是否有 CCCI/ccmni 能力 | “蜂窝(CCCI/ccmni)… 缺失 / 最大缺口：md1/md3 固件与 CCCI 私栈未带”（LABKERNEL.md:29） | 同上（内核侧在场）+ LK 装入 md1img/md1dsp（d28b.raw）+ 设备 /dev/ttyCMIPC*（只读实测） | 拆成两句：**内核侧在场**；**端到端未验证**（md FSM/拨号链） |
| T-3 | lab DTS 是否带 WiFi/PCIe 节点 | “lab DTS 骨架未带 WiFi/connsys 节点，需从 stock DTS 移植 pcie/wed 节点”（V5-MEMO:30-31） | lab DTS **有** pcie@11280000/11288000/11290000（:4963/4996/5029）、consys@18000000（:5690）、hnat@15102200（:4663）；**无** wed@1501*（grep=0）；实机枚举 14c3:7992 | 细化为：“**缺 wed@ x3 节点**（WED offload 不可用）”；pcie/consys 已有 |
| T-4 | CONFIG_HW_NAT=y 的含义 | config:1193 明写 =y | System.map.lab3 中 **`mtk_hnat` 命中 0**；松散 'hnat' 的 2 处均为 ccmni 符号（:26981/:50380）；lab DTS 有 hnat 节点但无对应驱动符号 | 需在构建侧确认该 Kconfig 映射到哪个符号；确认前**不得**把“lab 带 hw_nat offload”写进任何结论（正确表述=“无 mtk_hnat 驱动符号”） |
| T-5 | nerepair 当前 armed/dry 状态 | 00_STATE 页首：“观察模式”；R7 日志称 /data/gw/nerepair.dry 在位 | **已由 Lead 授权只读锚点（2026-11-03 19:20-19:26 +0800）实测确认：当前为 dry-run（不修）**——/data/gw/nerepair.dry 在位（0 字节，mtime Nov 1 18:01）；nerepair.log 最后 START = ver=2.2 dry=1 xrep=0；MODE 多行 source=marker；最新 STAT（19:21:00）= mode=dry attached=45 segv=1 repaired=0 passed=1 suppressed=0 would=0 near=0；全日志真 REPAIR=0 / DREPAIR=0 / XREPAIR=0 | **已定案，移入 [A]**；文档说法 A 与实测一致；[C] 仅保留 slotguard 侧 |
| T-6 | 自然 NE 记录位置口径 | C-142：start_stack-0x1390…-0x7970 | FIX.md 附录：本地 natne_scan.py 复算字段起点 top-0x1390…-0x77c0 | 沿用 FIX.md 附录“引用前先对账”的要求；本报告不引用具体位置数字 |

---

## 9. 结尾三栏

### [A] 已核实

1. D28 两窗 1800.023 s / 1800.019 s、inj=0 **0/0**、inj=1 19/19、selftest_ok=1、probe_bad=0、日志 88 行/49,641 B 与 88 行/49,643 B、md5 b1220cdb…/f4b284cf…（**本轮本地独立复算**）。
2. D28 §9 六条混杂边界（原文照搬，见 §1.2）。
3. lab 镜像 = 6.18.44 initramfs-only；boot-lab31-signed.img md5 9934cca2…；v3 原始镜像因 GPT 缺陷禁止飞行（LABKERNEL.md:6-8、CHANGELOG v3.1）。
4. lab 内核 config 事实：CCCI/ECCCI/CCMNI/MEDMCU =y（1686-1703）；NET_MEDIATEK_SOC(_WED)=y（2074-2075）；**netfilter 0 命中**；ARM_MEDIATEK_CPUFREQ=y（570）；IP_MULTIPLE_TABLES=y；SENSORS_PWM_FAN=y；LEDS_GPIO / USB_GADGET 未置。**WiFi 两个口径分开记**：①**config `=m` 口径共 6 项**——CFG80211:1162、MAC80211:1173、MT76_CORE:2320、MT76_CONNAC_LIB:2322、MT7996E:2331、WATCHDOG_PRETIMEOUT_GOV_SEL:3072（末项不是 WiFi）；②**`.ko` 产物口径为 5 个**——cfg80211 / mac80211 / mt76 / mt76-connac-lib / mt7996e（build 清单 v3_repack.sh:136-143，产物目录 _local/work/lab-kernel/artifacts/modules/ 共 5 个文件）。另注：v3_repack.sh:98 有 `--disable MT76_LEDS`，但产物 config:2321 仍为 `CONFIG_MT76_LEDS=y`（口径差异，本轮未追因）。
5. lab 镜像符号事实：458 ccci、mtk_wed 48、ppe 27、mtk_pcie 34、mtk_iommu|iommu_ 0。**hnat 计数规则（必须标注）**：松散 grep 'hnat' 命中 **2 处**，但两处均属 CCCI 符号 `ccmni_recycle_med_hnat_info`（System.map.lab3:26981 与 :50380）；`mtk_hnat` 命中 **0** ⇒ 正确结论是“**无 mtk_hnat 驱动符号**”，而非“hnat 计数=0”。
6. D28 lab boot（d28b.raw）实测：ccmni0..20、ttyCMIPC0..、DPMAIF probe OK、modem_cd_init returned 0、eth0/eth1 up 2.5G、pwm-fan/pwm-fan-aux probe OK、PCIe 11288000 枚举 [14c3:7992]；LK 装入 md1img/md1dsp。
7. mt7996e.ko（v3.1 构建产物）PCI 别名含 14c3:7992，期望固件名 mediatek/mt7996/mt7992_{wa,wm,dsp,rom_patch}.bin（含 eeprom 变体）。
8. 设备只读实测（19:21 +0800）：5.15.134；172 模块 / 163 在载；mt_wifi 8,028,160 B、mtk_wed 20,480、mtk_warp 679,936、hw_nat 1,376,256、mt7992、mtk_pci、mapfilter；netfilter 类 58 在载（含 nf_tables + 24 依赖）；/dev/ttyCMIPC0..；/lib/firmware 17 项（含四件套 + MT7992_EEPROM.bin），/lib/firmware/mediatek 空；/proc/device-tree 有 wed@15010000/wed2/wed3/consys@18000000。
9. gw/ 功能面与内核依赖：fw_apply.sh:20-24/:52-85（iptables/ip6tables）、wan_agg.sh:250-261（NAT/MARK/fwmark）、usb_mgr.sh:12-15/:35-37（configfs g1/rndis0）、led_mgr.sh:20-29（gpio 467/474/475/473）、fan_mgr.sh:10-14（pwm-fan 路径）、ccmni_up.sh:34（厂商 mipc_wan_cli）、mipc_cellular.c:175-176（/dev/ttyCMIPC%d）、v3_fix.c:68-69（厂商符号 ppe_hook_rx_eth/quec_eth_rx_hook）、svc_lib.sh:328-343（14 守护表）。
10. FIX.md §7.1/.2/.3/.4 四条根修复路线的判定与代价（原文）。
11. 撤回清单（本报告全文未引用）：88/112、自然 NE 0/4、C-138、C-145、C-016/017/018/019。
12. **nerepair 当前为 dry-run（不修）**（**Lead 授权只读锚点**，2026-11-03 19:20-19:26 +0800，非本分析员所取）：/data/gw/nerepair.dry 在位（0 字节，mtime Nov 1 18:01）；nerepair.log 最后 START = ver=2.2 dry=1 xrep=0；MODE 多行 source=marker；最新 STAT（19:21:00）= mode=dry attached=45 segv=1 repaired=0 passed=1 suppressed=0 would=0 near=0；全日志真 REPAIR=0 / DREPAIR=0 / XREPAIR=0。⇒「观察模式」文档说法成立，且**当前无任何修复动作**（本报告 (c) 判决不依赖该状态）。

### [B] 未核实（离线不能判定 + 原因）

1. **“V5 点亮 WiFi（或蜂窝）之后生产者是否停止”** —— 未核实；缺“主线内核 + WiFi 起 + 客户端流量”的实测窗（§7 已给设计）。
2. **md（modem）在 lab 内核下能否起到可拨号状态** —— 未核实；引导期 md1 get scp-sys-md1-main failed 是黄灯，但无 FSM/注册证据；需上设备读 /dev/ttyCMIPC 做一次 cells 探测。
3. **WiFi 固件可加载性** —— 未核实（E0）：文件命名/格式映射未做，主线期望的 mediatek/mt7996/* 目录在设备上为空；EEPROM 选型未定。
4. **CONFIG_HW_NAT=y 在 lab 镜像里到底编译进了什么** —— 未核实（config 说 y，符号表 0 命中）。

5. **lab 窗内“目标页资格”是否成立** —— 未核实（§9-2 明写不可消除）。
6. **主线 mt7996e 在本板上的吞吐/稳定性/MLD 行为** —— 未核实（无实测）。
7. **WiFi-less V5 是否停写** —— 未核实，且**在构造上不可判定**：该版本没有加回 C-204 认定的主载体（WiFi 客户端数据面流量），零结果与“触发器缺席”不可区分（暴露/功效评估见 §6(b) 补充）。

### [C] 必须上设备才能确认

1. lab 基座上把 WiFi 点亮的 gate：insmod 五个模块 + 固件就位后，dmesg 是否出现 mt7996e probe/固件下载成功 + iw dev 出接口（一次只读 boot 会话即可判定）。
2. 蜂窝：lab 内核引导后只读 ls /dev/ttyCMIPC*、mipc_cellular cells、cat /sys/class/net/*/operstate、dmesg 中 ccci 段（判定 md FSM 是否起）。
3. 主题判决实验 §7 的 N2 臂（**唯一能把 (c) 从“未支持”推进的一步**）。
4. 观测窗内 **slotguard** 实际模式（读 /data/gw/slotguard.arm 与 slotguard.log 的 MODE 行）；**nerepair 侧已由只读锚点确认**（当前 dry-run，见 [A]12）。
5. lab 上 netfilter 补全后的回归（NAT/端口映射/访客隔离是否与 v4.x 行为一致）。

---

## 附录 A：设备只读访问审计（观测者污染留痕）

| # | 时刻（设备 UTC，本地 +0800） | 命令（只读） | 说明 |
|---|---|---|---|
| 1 | 2026-11-03T11:21:28Z（19:21:28）uptime=5755 s | echo；uname -r；lsmod 管道 head -80；ls /lib/modules/$(uname -r) 管道 head -40；ls -l /lib/firmware 管道 head -70；ls -l /lib/firmware/mediatek 管道 head -30；ls /proc/device-tree 管道 head -60；ls /proc/device-tree 管道 grep pcie/conn/wed/md；ls /lib/firmware 管道 grep md1/md3/ccci/dsp；lsmod 管道 grep ccci/mhccif/medmcu | 单次快照，全部只读，含 head 限幅；无重定向、无写、无 kill/reboot |
| 2 | 2026-11-03T11:21:42Z（19:21:42）uptime=5770 s | ls /lib/modules/$(uname -r) 管道 wc -l；lsmod 管道 wc -l；lsmod 管道 grep mtk_wed/mtk_warp/mtk_pci/mtk_hwifi/hw_nat/mapfilter/quecadp；lsmod 管道 grep ccci/mhccif/medmcu/dpmaif；lsmod 管道 grep -c nf_/xt_/iptable/ip6table/ebtable；lsmod 管道 grep nf_tables/nft；ls /dev/ttyCMIPC* 管道 head -6；ls /proc/device-tree 管道 grep consys/wed；ls /lib/firmware 管道 wc -l；ls -l /dev/mmcblk0p* 管道 head -8 | 同上；两次快照间隔 15 s，**未轮询**；未触碰 24 h 观察窗任何状态 |

两次访问均通过 lgssh.py（v1.4 重试）执行；**未**使用 deploy.py/devop.py，**未**做任何 dd/chmod/touch/rm/mkdir/kill/reboot/mount/ip link set/iptables 变更/重定向。设备侧 uptime 连续（5755 → 5770），观察窗未受影响。

## 附录 B：本报告引用的关键路径索引

| 内容 | 路径（相对 D:/Repo/lg6151m-project） |
|---|---|
| D28 预注册+结果 | lg6151m-public/docs/SIGSEGV/05_LOG/2026-11-03-12-d28-labv3-revalidation.md |
| D28 原始串口（lab 段） | _local/evidence/d28/d28b.raw（lab 段 = 第 6159 行起；本轮抽存 tmpfiles/review/v5/d28b_lab_segment.txt） |
| D28 两窗日志（复算用） | _local/evidence/d28/scanary_c2_w1.log、_w2.log |
| C2 消融 + FN-audit 修正 | lg6151m-public/docs/SIGSEGV/05_LOG/2026-11-01-12-c2-firstboot-ablation.md §10-13 |
| transport 记分卡/收束 | lg6151m-public/docs/SIGSEGV/11_TRANSPORT_SCORECARD.md §11-16 |
| 根修复路线 | lg6151m-public/docs/SIGSEGV/FIX.md §7、§6（R-11/R-12） |
| lab 能力矩阵/边界 | lg6151m-public/docs/LABKERNEL.md §1、§7 |
| V5 备忘录 | lg6151m-public/docs/LABKERNEL-V5-MEMO.md |
| lab config（v3.1 构建配置，与产物同 md5 0985a9ed90a4cf6fffa31edfe26aa3a3） | lg6151m-public/tools/labkernel/config/config-lab3-6.18.44 |
| lab v3.1 init | lg6151m-public/tools/labkernel/scripts/lab_init_v3.sh |
| lab DTS 骨架 | lg6151m-public/tools/labkernel/dts/mt6990-fiberhome-lg6151m.dts |
| lab 构建产物（本地） | _local/work/lab-kernel/artifacts/{System.map.lab3,modules/mt7996e.ko,config-lab3-6.18.44} |
| claims 台账 | lg6151m-public/docs/SIGSEGV/01_CLAIMS.tsv（C-192/193/196/199/204/206/211/213/214） |
| gw 功能与依赖 | lg6151m-public/gw/{rc.extend.sh,fw_apply.sh,wan_agg.sh,usb_mgr.sh,led_mgr.sh,fan_mgr.sh,ccmni_up.sh,svc_lib.sh}、gw/src/{mipc_cellular.c,v3_fix.c,healthdog.c} |
| 功能面/版本表 | lg6151m-public/docs/ARCHITECTURE.md、docs/FEATURE_MATRIX.md |
