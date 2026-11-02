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
- 结果：**4 条 inj=0 真命中 / 600 s = 0.40/min**（同族 `topva=0x4e0 spva=0xb0`；
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

## 8. 结果（实验后追加）

（待填）

## 9. 偏差与终态

（待填）

## 10. 判决

（待填）
