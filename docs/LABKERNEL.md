# LG6151M 实验室内核(labkernel)使用文档

> 构建套件:`tools/labkernel/`(环境/钉死/一键构建见其 README)。
> 本文:能力矩阵、刷写与恢复 runbook、TRY_A 语义、观测窗与 shell 行为。
>
> **当前资产 = v3.1(`boot-lab31-signed.img`,md5 `9934cca26d2dda425eae406ca97fb865`)。
> v3 原始镜像(`boot-lab3-signed.img`)已撤回:其 /init 以裸设备 offset 2061
> 清 TRY_A,会写坏 GPT entries CRC,禁止实机飞行。**

## 1. 能力矩阵(lab 内核 vs 厂商栈)

| 能力 | 厂商栈(5.15.134) | lab 内核 6.18.44(v3.1) | 说明 |
|---|---|---|---|
| KPROBES/KPROBE_EVENTS | 部分 | **y** | |
| DYNAMIC_FTRACE/FUNCTION(_GRAPH)_TRACER/FTRACE_SYSCALLS | 部分 | **y** | |
| UPROBE_EVENTS | 部分 | **y** | |
| PERF_EVENTS + HW_BREAKPOINT | 部分 | **y**(kptr/perf paranoid 由 /init 清零) | |
| USERFAULTFD / PROC_PAGE_MONITOR | n | **y** | |
| PAGE_OWNER | n | **y**(cmdline page_owner=on) | |
| KGDB + KGDB_SERIAL_CONSOLE + KDB | n | **y**(kgdboc=ttyS0,921600;`echo g > /proc/sysrq-trigger` 进入) | 与 console 共口,SysRq g 退出 |
| KEXEC/KEXEC_FILE | n | **y**(内核侧;用户态 kexec 未内置,见 /bin/kjump) | |
| /dev/mem | IO_STRICT | **放宽**(STRICT_DEVMEM=n) | lab 有意行为,与生产内核策略相反 |
| 串口 console | y | **y**(ttyS0 921600,earlycon 8250) | |
| eMMC(msdc) | y | **y**(MMC_MTK) | |
| 以太网(mtk_eth_soc) | y | **y**(CONFIG_NET_MEDIATEK_SOC) | /bin/netup 配 169.254.9.n/16 |
| 温度(LVTS) | y(厂商私栈) | **y**(MTK_LVTS_THERMAL,mt6980-lvts 节点同源) | 心跳带 tmax;告警/保护关机可配 |
| 看门狗 | y | **y**(MEDIATEK_WATCHDOG;/init 每 10s 喂) | lab_wdt=off 关 |
| 文件系统 | y | ext4/squashfs **y** | /bin/romount 只读挂载助手 |
| **蜂窝调制解调器(CCCI/ccmni)** | **y** | **缺失** | **最大缺口**:md1/md3 固件与 CCCI 私栈未带,蜂窝上行在 lab 上不可用 |
| WiFi(mt7992) | y(厂商私栈) | **模块已构建不加载** | mt7996e 驱动含 MT7992 PCI ID;点亮需固件四件套+eeprom,未验证(见 V5 备忘录) |
| GNSS/音频/显示等外设 | y | 未带 | 观测平台不需要 |

## 2. 刷写 runbook(p25 = boot_a)

> 铁律:B 槽 p39 不许写;bootctrl 只在验证后动;先备份。

1. **备份**(经 SSH 正常态):`dd if=/dev/mmcblk0p25` 32MB 存 /data 与 PC 双份;
   `dd if=/dev/mmcblk0 bs=1 skip=2060 count=16` 备份 misc 块。
2. **抓 LK**(drill 管线,tools/lk_flash_v4.py / lk_eth1_resume.py):
   断电重上电 × Ctrl-C 弹幕抓 LK(PINTEST)→ `kcmdline append init=/bin/sh` →
   `repeat 2000 heap alloc 65536` → raw shell → 环境重建
   (mount tmpfs /dev;mknod null/zero/urandom;proc)。
3. **传输镜像**(raw shell,(fhrom curl,勿用 uclient-fetch):
   eth0/eth1 均可零配置 169.254/16(PHY 在 ifup 后 attach),
   `/fhrom/bin/curl` + `LD_LIBRARY_PATH=/fhrom/lib:/fhrom/usr/lib` 拉镜像,
   **md5 与注册表 image 行核对**(损坏历史教训):v3.1 = `9934cca2…`;
   v3(217ccd57…)已撤回,不得写入。
4. **落盘**:`mknod /dev/mmcblk0p25 b 179 25`;
   `dd if=boot-lab31-signed.img of=/dev/mmcblk0p25 bs=1M`;
   读回 md5 二次确认(或 cmp)。备用路径:LK bio 段复制
   (`bio read mmc0pX <ram> off 0x100000` / `bio write mmc0p25 ...` 循环 + `bio dump` 校验)。
5. **重启进入**:sysrq-b(或 LK 菜单)。首屏出现 `LG6151M LAB KERNEL V3.1` +
   BOOT CARD 即成功(BUILD_ID 含 `labkernel-v3.1`)。

**rdinit=/bin/sh 模式**(v2 起可用):LK 下 `kcmdline append rdinit=/bin/sh`
后正常 boot——内核直接把 console 交给裸 shell(cpio 自带 /dev/console)。
预期行为:无挂载、无观测载荷,手工 `mount -t proc...` 或 `exec /init` 进受管流程;
**退出该 shell(Ctrl-D)= PID1 死 = panic,10s 后自动重启回 init=/init 正常流程**
(panic=10;属预期,非故障)。v1 时代该模式因缺 console 节点直接
"Attempted to kill init" panic——v2 已修,勿混淆两种 panic 的含义。

## 3. TRY_A 语义与自清(A3)

- A/B 控制块在 **misc 分区(p1)内 offset 2060**:[2060]=A 优先级,[2061]=A.TRY
  计数,[2065]=B 优先级,[2066]=B.TRY;LK 每次启动 A 槽 TRY+1,**>3 回退 B 槽
  官方**。厂商固件开机完成后清零(S99zmtk_boot_done);lab 内核没有厂商 S99。
  **p1 start=64 扇区**,故控制块在裸设备上位于 offset 64×512+2060,不是 2060。
- v3.1 起 /init 开机即清 **p1[2061]**(写前/写后打印控制块 10 字节形 + 读回
  校验,醒目日志 `TRYA_CLEARED: p1[2061] 0x01 -> 0x00 ... after: ...`),
  彻底免疫该陷阱;`lab_trya=off`(内核 cmdline)可关。
- **禁止**按裸设备 `/dev/mmcblk0` offset 2061 写:该字节属 **GPT 分区表条目**,
  写入会破坏 GPT entries CRC(v3 原始镜像即此缺陷,已撤回)。
- 手工等价(正确偏移,先读形后写单字节):
  `mknod /dev/mmcblk0p1 b 179 1; dd if=/dev/mmcblk0p1 bs=1 skip=2060 count=10 |
  hexdump -C; dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek=2061 count=1`;
  再读回须为 `0f 00 01 00 00 0e 00 01`(A.pri/A.TRY/B.pri/B.TRY)。

## 4. 观测窗与交互 shell 行为(v2/v3.1)

- 开机:BOOT CARD(能力一页)→ TRYA 清零(p1@2061)→ 喂狗 → netup(后台)→
  vsurv4 + scanary w1(预注册调用,**参数勿改**,数据可比性)→ 心跳 10s
  (`[hb i] uptime= MemAvail= tmax= vsurv4= scanary=`)。
- 观测窗 1800s 结束(或 scanary 退出连续 3 拍判死提前截断)→ **窗末日志信道**:
  `W1_LOG_PATH/W1_LOG_BYTES/W1_LOG_LINES` + `busybox md5sum` +
  `cat /data/repro/scanary_c2_w1.log` 全文 + `D28_W1_LOG_END`(v3.1 FIX-2),
  然后 console 交互 shell(setsid+cttyhack,exit 自动重拉);心跳转 60s
  `[hb-slow]`。判活按 `/proc/<pid>/stat` 的 comm(v3.1 FIX-3)。
- 任何时刻证据:`/bin/scanary_report /data/repro/scanary_c2_w1.log`;
  转储在 /data/repro(initramfs RAM,**重启即失**;要持久化先 romount 或
  netup+httpd 拉走)。

## 5. 热安全与看门狗(v3.1)

- 心跳 `tmax=` 为所有 thermal_zone 最大毫摄氏度;`lab_thermal_warn`(默认
  85000)以上每拍告警;`lab_thermal_off`(默认 95000,0=关)以上 sync 后
  poweroff(失败 10s 后 reboot 兜底)。
- 看门狗 /dev/watchdog 由 /init 每 10s 喂(fd 常开);lab_wdt=off 关。
  若内核 hang 到喂狗都停,硬件复位接管——这是 lab 会话的设备侧保险。

## 6. 回滚

- LK 菜单选 B 槽(p39 官方 rootfs 未写过)→ 回官方固件。
- 回 v4.x:重刷 p26(rootfs_v41.squashfs,md5 门禁)+ 备份的 p25。
- lab 内核下:romount 或 dd 备份件回写 p25;bootctrl 翻 A 参考
  lk_flash_v4.py(`0f 03` 写法 + 读回)。

## 7. 已知边界(诚实清单)

1. 首靴验证状态:v1(C2)已实机启动、观测窗完整跑通、scanary 采集到数据;
   **v3.1 已实机验证**(D28:两窗各 1800 s、热/狗/TRYA p1 写、窗末日志信道、
   scanary/交互 shell 全部实测,回滚闭环);v3 原始镜像因 GPT 缺陷**撤回未飞行**。
2. 签名链为 LG6851F 同款 mt2737+sec_level_0+hsm 测试密钥;LK 接受性同代互证
   (v1 实机已签名启动成功——实证)。
3. 无 RTC:date 不可信(心跳里 1970 属预期);跨源对齐用 uptime/锚点纪律。
4. MemAvail 字段在实机心跳为空(v1 起):观测现象,未改判据保持可比;
   MemAvailable 判读请用 /proc/meminfo 直读。
5. kexec 用户态未内置(kjump 会如实报缺);模块固件未捆绑(点亮 WiFi 需
   固件四件套,见 V5 备忘录)。
