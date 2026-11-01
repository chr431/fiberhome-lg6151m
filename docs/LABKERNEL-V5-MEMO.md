# V5-on-lab 可行性备忘录(短而诚实)

> 问题:若 v4.x 的多源耦合问题最终不可修,以 lab 内核(6.18.44)为基座做 V5
> 自定义固件,需要补什么?哪些不可能?本文只做静态判断,不调硬件。

## 结论速览

**技术上成立,但蜂窝上行是硬缺口**;WiFi 是"半可行"(驱动在,固件未验);
工作量重心在用户态(网络编排/GUI/服务监督),内核侧本套件已备好大半。

## 需要(按优先级)

1. **持久 rootfs**:initramfs 全 RAM 不可持续。p26(squashfs)或 ext4 数据分区
   方案已有内核支持(ext4/squashfs=y,romount 助手就位);需一个正式的
   rootfs 组装管线(可借现有 v4.x squashfs 生产经验)。
2. **用户态服务栈**:LAN 侧(dnsmasq/hostapd 替代品、Web GUI、SSH 服务端)
   需 musl 静态交叉构建管线(vsurv4/scanary 的 musl-cross 链已验证可用)。
3. **网络编排**:mtk_eth_soc 已编入(netup 零配置已备);NAT/防火墙用
   nft/iptables 内核模块(当前 config 未带,V5 轮补)+ busybox 侧用户态。
4. **热/稳定性治理**:LVTS 已编入(v3);仍缺 cpufreq/DVFS 档位策略
   (g3d_dvfs/cpufreq 节点在 stock DTS 有,lab 骨架未启用)——长跑前需补。
5. **kexec 工具链**:内核侧就绪;用户态 kexec-tools 静态构建(源码本地无,
   需一次网络拉取——独立小任务,做完 kjump 即活)。

## 半可行(需实证才能升级结论)

- **WiFi(mt7992)**:mt7996e 驱动内含 MT7992 PCI ID 与固件声明(pci.c
  MODULE_FIRMWARE 四件套:WA/WM/DSP+ROM patch),驱动级支持存在;但点亮还差:
  (a) PCIe 枚举到设备(lab DTS 骨架未带 WiFi/connsys 节点,需从 stock DTS
  移植 pcie/wed 节点);(b) 固件四件套(需从 stock rootfs/lib/firmware 或
  connsys 分支提取,版权与来源需登记);(c) eeprom 数据(nvmem/文件)。
  三项全未验证——**判断:可尝试,不承诺**。
- **外设(LED/USB gadget 等)**:LED 通道 sysfs 方案可移植(v4.x 经验);
  USB 设备模式 gadget 驱动在主线,需 config+DTS 工作。

## 不可能(lab 基座的硬边界)

- **蜂窝上行(CCCI/ccmni)**:需要 md1/md3 modem 固件映像 + MTK CCCI 私有
  栈(mhccif/medmcu 框架虽在树内 probe 通过,但完整拨号链是厂商私栈,
  且 modem 固件受版权/签名约束不可自由再分发)。**结论:V5 若定义蜂窝为
  必选,lab 基座不成立;若接受"有线/WiFi 上行 only",则成立。**
- **厂商二进制服务的复用**(mipc/RIL 等):闭源用户态与 5.15 厂商内核强
  耦合,不能指望在 6.18 上运行。

## 与 v4.x 的取舍对照

| 维度 | v4.x(厂商内核改造) | V5-on-lab |
|---|---|---|
| 内核观测能力 | 受限(无 kprobe/ftrace 完整栈) | 全量(本套件核心价值) |
| 蜂窝上行 | 有 | **无(硬边界)** |
| WiFi | 有(厂商栈) | 待验证(主线栈) |
| 维护性 | 多源耦合(问题源头) | 主线化,可解释 |
| 工作量 | 已在线(维护态) | rootfs+服务栈重建(一次性大投入) |

## 建议的验证顺序(若启动 V5)

1. v3 实机:热区读数/看门狗喂狗/TRYA 自清三项实机确认(明日恢复轮顺带);
2. romount 挂 p26 实机确认(离线取证通道);
3. WiFi 点亮三件套静态清点(PCIe 节点移植→固件提取→eeprom)——最便宜的
   一次性实验;
4. 全部绿灯后再谈 rootfs 管线与服务栈。
