# labkernel -- LG6151M 实验室仪器内核构建套件

为 LG6151M(FiberHome MT6990 CPE)构建**离线观测内核**的完整配方:6.18.44 主线级
内核 + 极简 initramfs(busybox + 观测载荷),组 Android boot v2 + MTK mt2737
签名链,刷 p25(boot_a)后从串口得到一个全观测能力的 instrument 环境。
当前版本线:**v3**(v2 两缺陷修复 + 热管理/看门狗/TRY_A 自清 + V5 储备)。

## 版本线

| 版本 | 定位 | 关键差异 |
|---|---|---|
| C1 | 首个可刷内核 | 26 项观测 config;组包+签名闭环(未上机) |
| C2 | 台架会话版 | +scanary w1 自启(预注册调用,勿改) |
| v2 | C2 实战缺陷修复 | F1 cpio 补 /dev/console;F2 观测窗后交互 shell;F3 netup |
| **v3** | 资产化当前版 | A1 LVTS 热管理(心跳带温/告警/保护关机);A2 看门狗喂狗;A3 TRY_A 开机自清;A4 boot card;B: mt7996e 等五模块只构建不加载、romount/kjump 助手 |

## 环境(构建机记录,2026-11-02)

- WSL2 Ubuntu-24.04(root;跨 DrvFS 编译不可取,树在 WSL ext4 `~/lab-kernel/`)
- gcc-aarch64-linux-gnu 13.3.0、bison 3.8.2、flex、libssl-dev、cpio、dtc 1.7.0、
  qemu-user-static 8.2.2、zstd
- musl 交叉链(aarch64-linux-musl-cross;Windows 侧 /mntd 份 sysroot 残缺勿用)
- MTK 签名工具运行于 CPython 3.10.14(uv python-build-standalone;Ubuntu 24.04
  自带 3.12 与签名工具的 .pyc 不兼容)
- 已知主机陷阱:**经 wsl.exe 传内联命令,shell 变量赋值会丢**——一切非平凡
  逻辑必须走脚本文件(本套件所有脚本都按此约束编写)

## 上游钉死(REPOMETA)

- 基座仓 `13179415360/openwrt-mt6990-lg6851f`,branch main,HEAD
  `a40df9a5afb46716dea799acea69f17480df4d82`(ls-remote 2026-11-01)
- codeload tarball 36,640,559 B,sha256
  `68e1be16009a98baf6577b8522f42cca5fe2fe8d7b189ee6eccf0833c1c131a3`
- 内核源 linux-6.18.44 tarball sha256(下载三源竞速,钉死校验)
  `0f72d938f06828e82c90405174fe572287db7bfe089e2fc46572a99a7f240d43`
- 供应链处置:仅采用其 make 标准件、打包 py、MTK 签名 py(全部先读源码,
  无外呼/无 exec 陷阱);仓内 shell 脚本未整体执行;未在 Windows 侧执行仓内
  任何可执行件
- 设备侧 stock 资产:boot.img 提取 DTB(md5 686160767c2340a09919ad0f0e10a68b)
  用于 DTS 骨架互证

## 载荷 md5 钉死(initramfs 内二进制,来源与校验)

| 载荷 | md5 | 来源 |
|---|---|---|
| busybox(静态 aarch64) | baf625fa8babda6d11027bfe175e0132 | 本项目预构建(`_local/build/busybox.clean`) |
| vsurv4 | b4f32f329c6bcaaa4231e6f7d52c2915 | `tools/oneoff/sigsegv/vsurv4.c` musl 静态编译 |
| scanary | 17376b743d1df55240b77f8f0be0fdae | 调查树产物(源不入公开套件;md5 与台架预注册钉死值一致) |

## 从零准备(一次性;之后 build_labkernel.sh 一键重建)

1. `scripts/dl_kernel.sh`——内核 tarball 三源竞速下载,sha256 钉死校验
2. `scripts/prep_tree.sh`——解包→535 补丁(generic/target 两层 files 先拷)→
   放入 `dts/mt6990-fiberhome-lg6151m.dts`→config 三层合并→olddefconfig
3. `scripts/get_py310.sh`——uv 装 CPython 3.10.14(MTK 签名工具用)
4. `scripts/initramfs_skel.sh <dir> <busybox> <payload-dir>`——initramfs 骨架
   (busybox+applets+/dev/console 节点+init+helpers)
5. `scripts/build_labkernel.sh`——config 增量→Image/dtbs→模块→组包→签名→
   **自检电池全绿才落产物**

## 产物(本地 `_drill_backup/labkernel/`,注册表 image 行钉 md5)

| 产物 | md5 |
|---|---|
| boot-lab2-signed.img | c43db542a2a96f4054bd910d00268430 |
| boot-lab3-signed.img | 217ccd57c64cfe46e03e57d7a1a15c9f |

(unsigned 变体、System.map、vmlinux.zst、模块 .ko、init 源等全套在
`_local/work/lab-kernel/artifacts/`,SHA256SUMS.txt 为准。)

## 自检(每轮构建强制,exit 1 = 拒绝交付)

`scripts/v3_selfcheck.py`:继承 C1/C2/v2 电池(initramfs 内容/嵌入链/boot 头/
签名 cert1/F1 解包验证 /dev/console/F2 shell 通路/F3 netup)+ v3 新增
(A1 热管理标记、A2 喂狗、A3 TRY_A、A4 boot card、B 模块 ELF 与不自动加载、
**26 项观测 config 逐项与 v2 一致 + config 只增不删**)。
纪律注意:自动加载检查按「命令行精确匹配」而非子串——init 的*注释*提及
insmod 是文档,不是执行(判据三定律第 2 条的套件内实例)。

## 使用文档

- 能力矩阵 / 刷写与恢复 runbook / TRY_A 语义:`docs/LABKERNEL.md`
- V5-on-lab 可行性备忘录:`docs/LABKERNEL-V5-MEMO.md`
