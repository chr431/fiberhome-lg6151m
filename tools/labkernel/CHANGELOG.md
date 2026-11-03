# labkernel 变更记录

> 只记影响产物/刷写语义的变更。构建环境、上游钉死与载荷 md5 见 `README.md` /
> `REPOMETA.txt`;能力矩阵与 runbook 见 `docs/LABKERNEL.md`。

## v3.1 -- 2026-11-03(D28 复跑构建;当前资产)

**产物**:`boot-lab31-signed.img`,33,554,432 B,md5
`9934cca26d2dda425eae406ca97fb865`(mt2737 / sec_level_0 / hsm 测试密钥签名,
cert1 嵌入 @0x9818112)。内核 6.18.44(与 v3 同 config)、scanary 同源
(md5 `17376b743d1df55240b77f8f0be0fdae`)、vsurv4 与 busybox 不变。

**修复 v3 的 GPT 破坏缺陷(严重,安全相关)**:

- v3 的 `/init` 在 A3(TRY_A 自清)中按**裸设备** `/dev/mmcblk0` offset 2061
  读写。实测 A/B 控制块位于 **p1 内 offset 2060..2069**(p1 从扇区 64 开始,
  只读实测 `0f 00 01 00 00 0e 00 01`);裸设备 offset 2061 属于 **GPT 分区表
  条目字节**(实测 `0x26`)。v3 原样启动会把该字节写成 `0x00`,**破坏 GPT
  entries CRC**,属未授权闪存写 + 分区表完整性风险。
- **v3.1 修复**:TRY_A 自清改 **p1 offset 2061**,写前/写后打印控制块
  10 字节形(`p1[2060..2069] before/after`),可复核;`TRYA_CLEARED` 行带
  after 形。`boot-lab3-signed.img`(md5 `217ccd57c64cfe46e03e57d7a1a15c9f`)
  **撤回,禁止实机飞行**,仅留档。

**其余两处 /init 修正(D28 信道/判据缺陷)**:

1. **窗末日志全文上 console(FIX-2)**:观测窗结束后输出
   `W1_LOG_PATH/W1_LOG_BYTES/W1_LOG_LINES` + `busybox md5sum` +
   `cat /data/repro/scanary_c2_w1.log` 全文 + `D28_W1_LOG_END` 终止标记。
   除窗后交互 shell 之外的第二信道,杜绝 v2 时代 `head -8` 快照式信道缺陷
   (C-187 假阴性通道)。
2. **alive_check 改读 `/proc/<pid>/stat` 的 comm(FIX-3)**:原实现整行读
   `/proc/*/cmdline`,cmdline 以 NUL 分隔,整行永不等于 argv[0] token →
   恒判 0 存活(假红)。现按 `/proc/<pid>/stat` 的 `(comm)` 精确比较,并
   继续排除自身与父进程。

**防回归(静态断言,写入即生效)**:

- `scripts/v3_repack.sh` preflight:`TRYA_GUARD` —— 要求 init 使用
  `P1=/dev/mmcblk0p1` 与 `skip=2060 count=10`;禁止 `of=/dev/mmcblk0`;
  任何 `seek=2061`/`skip=2061` 行必须引用 p1 设备。命中即 exit 1。
- `scripts/v3_selfcheck.py`:`V3.1/GPT guard` 四条 —— 每个 byte-2061
  访问必须经 p1 设备;init 内禁止裸设备写;TRY_A 目标固定
  `p1@2061` 单字节零写;控制块写前/写后形状打印在场。

**实机证据**:D28 两窗各 1800 s 有效暴露(合计 3600.04 s),`inj=0` 真命中
0,正对照/形式要件/信道三重齐备;TRY_A 实弹 `p1[2061] 0x01 -> 0x00`,回滚
p25 后读回原厂 md5。详见
`docs/SIGSEGV/05_LOG/2026-11-03-12-d28-labv3-revalidation.md`。

## v3 -- 2026-11-02(已撤回)

资产化版本:A1 LVTS 热管理(心跳带 tmax/告警/保护关机)、A2 看门狗喂狗、
A3 TRY_A 开机自清(**缺陷:裸设备 offset 2061,见 v3.1**)、A4 boot card、
B 组 mt7996e 等五模块只构建不加载 + romount/kjump 助手。
产物 `boot-lab3-signed.img`(md5 `217ccd57c64cfe46e03e57d7a1a15c9f`)
**禁止实机飞行**。

## v2 -- 2026-11-01

C2 实战缺陷修复:F1 cpio 补 `/dev/console`(v1 `rdinit=/bin/sh` panic)、
F2 观测窗后交互 shell(setsid+cttyhack 重拉)、F3 netup 零配置通道。
产物 `boot-lab2-signed.img`(md5 `c43db542a2a96f4054bd910d00268430`)。

## C2 -- 2026-11-01

台架会话版:scanary w1 自启(预注册调用,参数勿改)。

## C1 -- 2026-11-01

首个可刷内核:26 项观测 config,组包 + MTK 签名闭环(未上机)。
