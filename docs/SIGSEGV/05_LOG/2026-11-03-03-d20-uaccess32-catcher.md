# 03 · D20 预注册 · uaccess32 catcher：mt_wifi 的 __arch_copy_to_user 调用点捕获（2026-11-03 夜间设备线 N1）

> **预注册文档：实验开窗之前写定并 commit。** 实验后只追加 §8–11，不改 §1–7。
> 本文件按 N2 静态线更新（mtk_wed 洗清 → mt_wifi 的 12 个 __arch_copy_to_user 调用点）
> 与 N1 的 10 min 中性 canary 实测（见 §2 前提）编写。
> 本文档中性信息：不含部署目标网络名与个人凭证。

## 1. 问题

32B 记录族（`{u32 X, 0, u32 len∈{321,1600,1601,4416,4480}, __be32 ip=流端点, 0…}`）
以 16B 对齐写在**用户栈 VA**（典型 `topva=0x4e0`/`spva=0xb0`）上。N2 静态线把写入面
收敛到 mt_wifi 的 12 个 `__arch_copy_to_user` 调用点（5 个在循环、长度取自寄存器）。
本实验回答：

> **哪一个调用点在什么时候把记录族内容写向用户 VA？** 即：钩住这 12 个调用点，
> 记录每次调用的 `(site, dst, len, src 前 32B, ts, pid)`，找出 src 内容命中记录族
> `{A,0,len,ip,0}` 的样本与站点。

## 2. 前提：10 min 中性 canary（无 WiFi 客户端）实测

- 设备态：WiFi AP 在（ra0/rai0 up，SSID 在播），**无关联客户端**（`station dump`=0），
  上行 eth0 在；scanary_c2 v1.4（md5 17376b74…）固定调用 600 s。
- 结果（终值）：**6 条 inj=0 真命中 / 600 s = 0.60/min**（本预注册写作时为中途读数
  4 条/0.40；终值见 §8 与 EXIT 行）（同族 `topva=0x4e0 spva=0xb0`；
  内容 `len=321 ip=10.53.4.208` 与 `len=1601 ip=192.168.9.1`），7 条 inj=1 自注入；
  `probe_bad=0 overflow=0 selfcrash=0`；boot_id 不变、TRY_A=0。
- 判读：**写入不严格要求 WiFi 数据流量**；无客户端时速率约为同夜有客户端中性窗
  （7.20/min）的 5.6%。⇒ catcher 在当前无客户端态即可开窗（不必先恢复 WiFi 流量）；
  若后续恢复客户端流量，则作为协变量窗（不入判决）。

## 3. 假设

- **H1（点名）**：12 个站点中至少一个在正常运行时以 `len≤64`（或栈 VA 目标）被调用，
  且其 **src 内容**（前 32B）命中记录族签名 `{w0, 0, len∈族, ip=端点, 0}`。该站点
  即记录族的直接生产/搬运点（N3 的修复靶点）。
- **H0（未点名）**：12 个站点均被观测到调用（或至少有一个），但没有任何 src 内容命中
  记录族 ⇒ 记录内容在更深处装配，或来自 12 站点之外的 copy 路径。

## 4. 仪器（uacatcher v1.0）

- **钩点**：mt_wifi.ko（设备件 md5 **5e124c24bbd7beba3ccc7fc89554702a**，与本地
  `analysis/vendor/mods/5.15.134/mt_wifi.ko` 逐字节一致）`.text` 内 12 条
  `bl __arch_copy_to_user`（R_AARCH64_CALL26 重定位，静态扫描得到偏移：
  `0x25bf4, 0x5b7e0, 0x13c360, 0x1eac44, 0x1f1d94, 0x1f577c, 0x1f9864,
   0x237430, 0x2976d8, 0x2b4738, 0x2dc204, 0x33bc64`）。
- **为什么不是 vmlinux 单点**：`ptwalk` 实测 `__arch_copy_to_user`
  （0xffffffc00843b680）在设备页表中是 **PMD leaf**（`pmd=00400000fdc00f81,
  pmd_leaf=1`），现有 PTE 翻转原语拒绝 pmd_leaf；`set_memory_rw` 未导出/不在允许面。
  ⇒ 按 N2 指令改钩模块文本（PTE 映射，原语已在 tuphook v1.4/v1.5 验证）。
- **补丁语义**：把每条 `bl` 换成 `b stub_i`（4B 原子）；stub 设 site id 后进入公共
  跳板：保存 x0–x7 → 调 `uac_probe(dst,src,n,site,lr)` → 恢复 x0–x7 → 以保存的
  `target=__arch_copy_to_user` 地址 `blr` 调用 → `mov x30, ret; br ret` 回到 site+4。
  调用语义与原 `bl` 等价（参数、返回值、LR 均一致）。
- **过滤**：`len ≤ 64` **或** `dst` 在 current 用户栈范围
  （`dst < TASK_SIZE_MAX` 且 `start_stack-8MB ≤ dst ≤ start_stack+64KB`）。
  过滤前对每个 site 计数（calls[12]），用于测每站点真实调用率。
- **记录**（96B/条，512 条/CPU 环）：
  `{dst, len, src, site_ret, caller_lr, ts(cntvct), data[32], pid, flags}`。
  `data[32]` 由 `copy_from_kernel_nofault` 读取（坏源只置 fault 位，不 oops）。
- **读出口**：`/proc/uacatcher`（seq_file），打印 12 站点的符号名/偏移/调用计数、
  per-CPU recorded 与最新 N 条记录（dst/len/src/data/ts/pid）。
- **dryrun=1**：定位 + 12 站点指令/邻居字校验 + 解码目标，**不 patch 一字节**。

## 5. 判据（预写死）

**窗有效性（任一不满足 ⇒ INVALID）**

1. dryrun：12/12 站点指令为 `bl`（`(insn & 0xfc000000)==0x94000000`），且站点前
   3 个字的签名与本地 .ko 逐字一致；解码目标 == `__arch_copy_to_user` 或模块 .plt 范围。
2. live：12/12 补丁读回一致；`/proc/uacatcher` 头行 PATCHED；`calls[]` 总计数 > 0
   （仪器活着）；无 oops/重启，boot_id 不变。
3. 正对照：至少一次已知触发（`iwpriv ra0` 或对应 /proc 入口读/写）使对应 site 的
   `calls[]` 增量 ≥1；否则该站点标记 NOT-EXERCISED（不计入 H0 的否定面）。
4. 样本量：过滤后记录 ≥ 100 条（10–15 min），否则按实际报告并标 E1。

**判决规则**

| 分支 | 条件 | 结论 |
|---|---|---|
| **H1 点名** | 任一记录（或同站点 ≥3 条）的 `data[32]` 在任一 32B 对齐窗口内命中 `{w0, 0, len∈{321,1600,1601,4416,4480}(±8), ip=单播端点}` | 该站点为记录族生产/搬运点（N3 靶点） |
| **H0 未点名** | 记录 ≥100 且无任何 data 命中；且至少 6/12 站点 EXERCISED | 记录内容在更深处装配或来自 12 站点之外 |
| **INVALID/不确定** | 记录 <100、或 EXERCISED <6、或正对照失败 | 如实标 E1，不升级 |

- 补充报告（不入判决）：每站点 calls 率、len 直方图、dst 是否栈/堆、pid/comm 分布、
  data 中出现 `len∈族` 或 `ip=端点` 的样本列表（即使未整 32B 命中）。
- **LOD**：若某站点 0 记录，给出规则三上界 `<3/N_calls(site)`。

## 6. 捕获协议

1. 载 `dieblx.ko`（已在载则跳过），`insmod uacatcher.ko dryrun=1 base=<mt_wifi .text> target=<__arch_copy_to_user>`，
   核对 §5-1；`rmmod`。
2. `insmod uacatcher.ko base=… target=… maxread=64`（live），确认 dmesg INSTALLED 与
   /proc 头行 PATCHED。
3. 正对照：`iwpriv ra0`（或等价触发）一次，确认对应 site calls 增量。
4. 捕获 600–900 s：每 5 s 读 `/proc/uacatcher` 落盘；窗起/止记 epoch/uptime/boot_id；
   窗内不加新仪器、不改配置；WiFi 客户端状态如实记录（当前无客户端）。
5. 收窗：`rmmod uacatcher; rmmod dieblx`，核对 dmesg `restored` 与 12/12 还原；
   模块数回 163、0 个我方模块；数据 md5 双端一致后判读。

## 7. 停止规则

1. 崩溃预算：同一仪器缺陷重复崩溃 ≥2 次 ⇒ 弃该路径，停工报告。
2. 每次崩溃后查 `TRY_A`（`hexdump -C -n 2 -s 2060 /dev/mmcblk0p1`）；>0 且未清 ⇒ 暂停报告。
3. **8 分钟 lgssh 不可达红线** ⇒ 停工报告（不擅自重启）。
4. 03:45 硬停线；04:00 定时重启若发生，重启后按需重装继续或收尾。
5. 安全红线：不写 p25/p38/p39；不碰 bootctrl；misc 只读；一切设备写经 `deploy.py put`。

## 8. 结果（实验后追加，§1–7 未改动）

**仪器：通过（正向对照成立）。** 最终件 `uacatcher.ko` md5
**92433a569c90cc112d03d3ed46df6013**（20480 B），`base=ffffffc000daf000`
（mt_wifi .text）、`target=ffffffc00843b680`（__arch_copy_to_user）。
dryrun 12/12 站点指令=`bl`、前三字签名逐字匹配、解码目标=target；
live 安装 `INSTALLED 12/12 sites`，pool 12 项回读全一致，12/12 补丁读回一致。
**正向对照**：`iwconfig ra0` → `site=3 ap_iw_handler` 记录
`dst=0x7fe7345750 len=6 src=ffffffc011e16ff4 data="MyHome" fl=STACK|SMALL` ——
ESSID 的 copy_to_user 落在用户栈 VA，与记录族落点同型，捕获链全程可用。

**捕获窗（897 s，无 WiFi 客户端，轻量触发）**

- 窗：epoch 1793644007 → 1793644904（897 s），180 次轮询（5 s）；boot_id
  `acde1339` 全程不变，无 oops，TRY_A=0。
- 调用计数（过滤前，每站点单调）：总 1 → 29（Δ28），**全部是 site3**；
  site0/1/2/4/5/6/7/8/9/10/11 **Δ=0**。
- 记录：去重后 **91 条，全部 site3，len=6**，dst 均为用户栈
  （fl=STACK|SMALL），`data="MyHome …"`（ESSID 拷贝）。
- 记录族命中：**0**（按 §5 的 32B 窗口扫描 `{w0,0,len∈族±8,ip=单播}` 全窗 0 条；
  len/ip 形态窗口 0 条）。
- 触发：`iwconfig ra0` 每 10 s 一次（90 次），只有其中 28 次到达 site3
  （wext 缓存/路径差异，如实记录）。

**与同夜 canary 的对照（关键）**

| 量 | 值 |
|---|---|
| 10 min 无客户端 canary（02:15–02:25） | **6 条 inj=0 / 600 s = 0.60/min**，同族 `topva=0x4e0 spva=0xb0`；5×`len=1601 ip=192.168.9.1`、1×`len=321 ip=10.53.4.208` |
| 有客户端中性窗（C-196，7.20/min） | 0.60/min = 8.3% |
| catcher 窗（02:26–02:41，897 s） | 12 站点中 11 个 **0 调用**；site3 的 91 条记录无任何族内内容 |

⇒ 在**无客户端态**，32B 写入者活跃（canary 0.60/min），而 12 个 mt_wifi
`__arch_copy_to_user` 站点中 11 个一次都没被调用、唯一被调用的 site3 的源内容
全是 ESSID —— **写入者不在 12 个站点之列**（限定：本窗与 canary 是两个相邻窗，
写入率可能漂移；客户端流量态未测）。

## 9. 偏差与终态

1. **两次仪器崩溃（均首触发即暴露，dieblx/ramoops 完整落盘）**：
   - 缺陷 1：安装代码在 C 里直接写 `.text` 中的 pool（RO）→
     `write to read-only memory at ffffffc001a410c0`，`pc=init_module+0x32c`，
     panic 重启（boot 6a17ab58 → 25df1105）。
   - 缺陷 2：pool 运行期地址与 C 符号不一致（回读读到 mt_wifi 的
     `ZeroWaitDfsQuery…` 字符串），首次触发站点时 `blr` 到 0（`pc=0`,
     `lr=uac_common+0x44`），重启（25df1105 → acde1339）。
   - 修法见 `06_INSTRUMENT_FIXES.md` F-12（pool 改可写 `.data` + 安装期 12 项回读门禁）。
   两次崩溃后 TRY_A 均为 0（boot_gate 自清），未写 misc。
2. **vmlinux 单点钩不可行**：`ptwalk` 实测 __arch_copy_to_user
   （ffffffc00843b680）为 **PMD leaf**（`pmd=00400000fdc00f81, pmd_leaf=1`），
   现有 PTE 翻转原语拒绝 pmd_leaf；按 N2 指令改钩模块文本。
3. **无 WiFi 客户端**：设备 AP 在播（ra0/rai0），`station dump`=0；未切换 PC 的
   WiFi（PC 的 WiFi 是代理/模型连接主路径，切换风险不可接受；自关联 STA
   apcli0→ra0 尝试失败：同 radio 扫描把 AP 信道从 8 推到 4，已停止并恢复）。
   因此 11/12 站点在本窗 **NOT-EXERCISED**，不是“未命中”。
4. **终态**：uacatcher 已 `rmmod`（12/12 站点还原）；设备中性（163 模块、
   0 个我方模块、boot acde1339、TRY_A=0、WiFi 4 接口 up）；p25/p38/p39/misc 未写。

## 10. 判决

- **H1（点名站点）：不成立**——全窗 0 条记录族内容。
- **H0（≥6/12 站点 EXERCISED 且无命中）：不成立**——只有 1/12 站点被调用，
  按 §5 判据为 **INVALID/不确定**。
- **有界排除（超出预注册的探索性结论，标 E1）**：在**无 WiFi 客户端**态，
  32B 写入者活跃（canary 0.60/min）而 12 个 mt_wifi copy_to_user 站点中 11 个
  零调用、site3 源内容全为 ESSID ⇒ **写入者不是这 12 个站点**（本窗与 canary
  相邻但非同一窗；客户端流量态未测）。
- **对 N3 的输入**：剩余 11 个站点需要 (a) WiFi 客户端数据面流量，或 (b) 厂商
  ATE/私有 ioctl/proc 入口才能触发；无客户端态应把搜索面移到其他模块
  （mt_wifi_cmn / mt7992 / connac_if / hw_nat / ccmni）的 copy_to_user 路径。


## 11. 后续追加 · 有流量窗（E4，2026-11-03 04:05–04:20，N3-exec）

> 本节为追加记录（§1–§10 未改动）。仪器同 §4/§6；这次是**WiFi 客户端数据面满载**的窗。

- **前置突破**：设备 AP 此前根本没在发信标（`hostapd_cli state=ENABLED` 但 PC 扫不到）。
  `mwctl dev ra0/rai0 set no_bcn 0` 后独立接收者（PC）看到 `MyHome`（2.4G ch8 /
  5G ch36），PC 以 WPA2-PSK 关联（口令 = `GW_PASS`，device WPAPSK 的 sha256 与本地
  一致；`WIFI_PASS` 是上游 WiFi 口令，不是 AP 口令），IP 192.168.9.145。
- **窗内流量**：PC 每 2 s 拉取设备静态 `app.js`（103,350 B，≈50 KB/s，900 s ≈ 450 次，
  全部 `200/103350`）+ 1/s source-bound ICMP；PC 的会话流量本身也经设备蜂窝上行
  （ccmni3，10.5.47.39）。
- **仪器**：`dieblx.ko` 在载；`uacatcher.ko` md5 92433a56…，`base=0xffffffc000dc2000`
  （本 boot 的新基址）、`target=0xffffffc00843b680`；dryrun 12/12 站点 `bl`+签名+目标
  解码全过；live `INSTALLED 12/12 sites`、`/proc/uacatcher` 头 `PATCHED`；
  正对照 30×`iwconfig ra0` + `iwpriv ra0 stat` + `iwinfo ra0 info` → **site3
  calls 7/17/0/9（合计 33）**，记录 33 条全 site3、len=6、`data=4d79486f6d65`
  （"MyHome"），与 §8 同型 —— 捕获链可用。
- **窗（900 s，boot `4a22850e…`，uptime 289→1160，88 个 10 s 快照）**：
  12 站点 calls **全程不变**（7/17/0/9；site0-2/4-11 整窗 **0 调用**）；
  快照内记录行 2937 条 = 上述 33 条正对照记录在 88 个快照中的重复，
  **len 直方图 {6: 2937}，记录族命中 0**。
- **判读（E4）**：在有 WiFi 客户端数据面满载的热窗里，mt_wifi 的 12 个调用式
  `__arch_copy_to_user` 站点**没有一个在数据面上被行使**（唯一被行使的 site3 是
  ESSID/wext 控制路径）。结合 §8 的无客户端窗（11/12 零调用）⇒ **两种客户端态下，
  记录族写入者都不在这 12 个站点里**。
- **对 D22 的直接影响**：wdone 的 4 个内联站点所在函数（`RTMP_COM_IoctlHandle`、
  `AP_E2PROM_IOCTL_PostCtrl`、`ZeroWaitDfsQueryCmdHandler`、`ate_cmd_proc`）对应的
  拷贝站点（`0x2976d8/0x1f9864/0x33bc64/0x5b7e0`）整窗 **零调用** ⇒ D22 的正对照
  不可能成立（§5.1.3），窗必 INVALID，故本轮 D22 不执行（见 05-d22 §10）。
- **下一步**：写者不在 mt_wifi 调用式 c2u 面。N2c 的剩余候选 = hw_nat 单站点
  （per-call arg 栈槽，非陈旧路径）、vmlinux 的 `_copy_to_user` 克隆（97 个，
  91 个网络相关）与**内联 `sttr` 形态**。下一轮应转向 vmlinux/内联面，而不是继续
  在 mt_wifi 上做杀开关。
