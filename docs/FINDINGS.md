# 逆向发现总集 (FINDINGS)

> 按时间线整合的全部技术发现。原始工作日志见内部 RECON 文件（不随公开发布）。
> 各专题深挖见 docs/ 下同名文档；本文是索引与结论层。

## 1. Web API 加密体系（RP0102 时代还原，RP0103 不变）

- 入口 `/fh_api/tmp/FHNCAPIS?ajaxmethod=is_encrypt` 返回 RSA-2048 加密 token
- RSA 私钥与 LG6851F 同源（网页 JS 内嵌同一把，第三方仓库亦公开）
- AES-128-CBC 会话密钥 = sessionid + RSA token 经厂商 Lua 算法派生；IV 固定 `6f..7e`
- 明文 JSON hex 编码 + 6 随机字符前缀；`X-Requested-With: XMLHttpRequest`
- 四类端点：FHAPIS（Web 主接口）/ FHNCAPIS（免认证会话）/ FHTOOLAPIS（App 明文）/ cgi-bin
- 本机为 `/fh_api/` 前缀分支（LG6121F 为裸 `/api/`）
- 完整实现：`tools/login_and_read.py`

## 2. 凭据面

| 凭据 | 值/规则 | 来源 |
|---|---|---|
| superadmin | `F1ber$dm`（固件常量） | cfg 节点 DeviceInfo.X_FH_Account... 可读 |
| telnet | `admin / hg2x0+MAC后6位` | 沙箱 shell |
| root (/etc/shadow) | `F1ber@dm!n`（$6$，musl 不校验 → 所有登录口恒失败） | 沙箱 strings 读取 |
| toor（自研） | 固件内置 MD5-crypt | build_v4.sh 烘焙 |

- SMS send_msg content 反引号注入 uid=0（`tools/inject.py`）；AT 注入 RP0102 已修
- 沙箱白名单漏放 strings/md5sum/ls → 任意读

## 3. 分区/引导/切槽

- eMMC 3.66GiB，GPT 46 分区，A/B 全对称（lk/boot/rootfs/md1img/md1dsp/mcf*/gnss 成对 + misc/nvram/fh_*)
- bootctrl：misc 分区偏移 **2060**（magic BCAB 区），LK 按 priority 选槽；up=02 标志仅用户态消费 <!--CLM:CLM-BOOTCTRL-2060-->
- **zmtk_boot_done 首启克隆槽**（厂商双槽一致设计）→ v3+ 必须注释，否则自定义槽被原厂覆盖 <!--CLM:CLM-ZMTK-CLONE-->
- LK 串口攻击链（lk_flip2.py，新 LK 上仍有效）：Ctrl-C 陷阱抓 LK → `kcmdline append init=/bin/sh`
  → `repeat 2000 heap alloc 65536` 堆耗尽逃逸 → 原始 shell 写 bootctrl → sysrq-b
- 升级链 /lib/upgrade/ 无签名校验（gzip 魔数 + MD5 自检）

## 4. 原厂用户态复用面（v4 的"飞行层"依赖）

| 组件 | 用途 | 复活方式 |
|---|---|---|
| cfg_tool + cfgmgr | 16MB 共享内存 cfg 树（key 0x7539） | webs_revive.sh；shmsnap 快照跨重启 |
| webs + nginx | 原厂 Web/API（fastcgi :8840 / nginx :8080） | webs_revive.sh 自足 conf |
| iotagtd | 烽火终端 App 本地 NDMP + 云连接 | webs_revive.sh v1.3；WAN 侧 iptables 封 18996-18998 |
| quecadp | 原厂多 WAN 内核引擎 | multiwan_ctl (ioctl, fhstub.so 桩载 libfhdrv_net_api) |
| mt7992 hwifi | 射频驱动层（apcfg dat + ifconfig up 激活） | wifi_up.sh 工厂配方 |
| hostapd（原厂构建） | WPA 安全层 | wifi_up.sh；**只吃 wpa_psk 原始 PMK**（wpa_passphrase 被 libfhcrypto 拦截） | <!--CLM:CLM-PMK-ONLY-->

- cfg_cmd 树 CLI：get/set 可用，add/del 有 argc 陷阱

## 5. 烽火终端 App（com.fiberhome.terminal）

- 本地控制协议 **NDMP**（反编译 u1/q.java）：裸 TCP 4B 大端长度前缀 + JSON
  - 明文 :18998，TLS1.2 双向认证 :18996（client_key.bks，密码 "fiberhome"）
  - 封套 `{"RPCMethod":"Post1","ID":hex,"Plugin_Name":"Plugin_ID","Version":"1.0","Parameter":base64({"CmdType":CMD,"SequenceId":uuid})}`
  - 响应 return_Parameter=base64 内层 JSON；PC 端复现实测 QUERY_FILINK_CONFIG_STATUS 通过
- 本地模式门控：WiFi supplicant=COMPLETED + 网关 GET_SN_INFO 的 MAC 与云端绑定一致
- v3httpd :80 透明隧道 `/fh_api/*` + `/api/tmp/*` → 192.168.9.1:8080（nginx 只绑 LAN IP 不绑 loopback）
- App 展示数据来自 cfg 树（v4 不回写 → 显示原厂残留 SSID/0 在线设备——控制面通，展示面待同步）

## 6. WiFi 架构（自研 hostapd 面）

- 原厂 hwifi 内部 WPA 在 MLD 组网下不发 EAPOL M1 → hostapd 接管安全层，apcfg 只管射频
- MAC 计划从 brmac 派生（第二字节+1，rai0 第6字节+8）
- 启动自动选道：apcli 扫描 → 线性 mW 功率和评分（2.4G 邻道±4 + 1/6/11 偏好；5G 80M 整组）
- **160MHz 已解锁（2026-10-05 实测翻案）**：早期结论"hwifi 驱动 CSA 钳回 80MHz"是误诊 —— <!--CLM:CLM-160MHZ-->
  真因是 hwifi dat 的带宽语义错位：`VHT_BW`(0=20/40,1=80,2=160) 与 `EHT_ApBw`(0=20,1=20/40,2=80,3=160)
  档位不一致，驱动最终带宽取两者 min，只设 VHT_BW=2 而 EHT_ApBw=2 时被钳 80（wifimgr
  be_init_wlan_apcfg_file 逆向实证）。wifi_up.sh v1.10 双字段齐设(2+3)后实测：
  rai0 ch36 `width: 160 MHz`，WiFi7 手机关联 PHY 2401.9/2882.3 Mbps EHT-MCS11/13 NSS2（80MHz 物理不可能）
- 本机 BSS 不被自家 apcli 扫描报告 → 分析仪合成绘制本机标记

## 7. 双上行聚合（wan_agg v2.11）

- v4：原厂 quecadp 引擎（jhash%100 < pct），ioctl 控制，权重热调
- v6：模块哈希常数缺陷 → 低 8 位 iptables 引擎（0x65/0x66）+ CONNMARK 粘性
- MARK 是覆盖非 OR：全部规则带 mark==0 守卫（曾致 catchall 覆盖钉死规则） <!--CLM:CLM-MARK-OR-->
- MAC 钉死表 agg_pins.conf（设备侧自管）：cmd6 ioctl（v4）+ mangle mac 规则（v6）
- "v6 恒定哈希"误诊教训：先枚举自己配置里的旁路（MAC 钉死绕过哈希）再判别

## 8. RP0102 → RP0103 diff 与 v4 rebase

- 获取路径：App 触发合法 FOTA → 设备刷 B 槽 → lk_flip2 翻回 A → dd 提取四分区
- 内核同版本 5.15.134（2025-12-24 → 2026-09-09 构建）；169 模块中 151 字节级相同
- 用户态增量：wancc+66KB（静态路由/WAN DNS）、modem P40→P56、ping_detection、
  App 离线修复=一行 iptables（ccmni 9991 MARK）、eth_mac_monitor
- **RemoteUpgradeEnable 用后必须归零**（防云端再推覆盖实验现场）
- v4 定制清单 = toor + dropbear uci + rc.local + rcS 双锚点 + S98 钩子 + babysitter
- **dropbear 0 字节 host key 坑**：纯净树 key 是占位文件 → rc19 v2.15 自生成自拉起

## 9. 工程纪律（血泪教训）

- **drop_caches 在 rootfs 被重写后 = 自杀**（运行系统按旧地址页入新数据）
- busybox awk 不解析跨行嵌套三元
- Python 三引号 `\\n` 陷阱 / 含转义内容一律用 Edit 工具直改
- 设备 wget 对 PC depot 有 ~1/4 静默失败率：显式 -O + md5 校验重试
- paramiko 对本机 dropbear 大块 stdin 会劣化断链：大文件走 HTTP depot（设备 wget）/ curl scp
- 串口 tcpdump 抓不到桥成员口流量；adb pull 在 Git Bash 需 MSYS_NO_PATHCONV=1
- 版本注册表（tools/VERSIONS.tsv）是唯一版本事实源，vercheck fail-closed

## 10. 蜂窝组网模式（SA/NSA/SA+NSA）与 modem AT 语义（2026-10-08/09）

- 官方固件有独立"组网模式"维度（RP103 备份 `/www/html/src/content/pages/networkSet.js`
  明文源码）：ENDC 下拉 SA=1 / NSA=2 / SA+NSA=3，与"网络模式"（0=仅4G / 2=仅5G /
  3=5G优先 / 4=仅3G）并列；联动规则：NetworkMode==2（仅5G）时强制 SA 并隐藏 NSA 选项
  （NSA 需 LTE 锚点），仅4G/3G 整行隐藏。树键
  `InternetGatewayDevice.X_FH_MobileNetwork.NetworkSettings.ENDC`。
- 下发通道**不走 AT**：mobilenetwork `fh_set_endc`@0x40a8bc 调 libqlril
  **`ql_nw_set_nr_disable_mode(3|5|7)`**（SA→3 / NSA→5 / SA+NSA→7；非 7 目标先 restore 7；
  位掩码 bit0 恒 1、bit1=SA、bit2=NSA —— 位切分推断，值集有实证）。
  libqlril 同时导出 `ql_nw_get_nr_disable_mode`（读回校验用）。自研复刻：
  `mipc_cellular endc get|set`（同库同 dlopen 闭包通道，v0.8）+ api.sh `netmode` 增
  `endc` 字段 + GUI"组网模式"下拉（联动规则照抄）+ 变更自动重附。 <!--CLM:CLM-ENDC-NRMODE-->
- **ECNCFG 陷阱**：`AT+ECNCFG=1,1,0,0,0,0` / `=1,0,...` 字符串在 mobilenetwork 里与
  endc 代码相邻，极易误读为 ENDC；md1img 格式串
  `update ECNCFG: data_en, data_roam_en, domestic, international` 实证它是**漫游/数据
  开关**（由 RoamingEnable 树键驱动）。AT 表面语义以 modem 镜像串/调用点为准。
- **E5GOPT ≡ 同一旋钮的 AT 层镜像**：modem 侧 `l5ath_e5gopt_cmd_handle` → 内部消息
  `SET_CACHE_ENDC_CONNECT_MODE_REQ/CNF` → SASE `vg_option` 通路 → NAS/nwsel 异步传播。
  双观测互证：ql API 写 3 时 E5GOPT 读数同步 7→3；值集 {3,5,7} 与 SDK 完全一致。
  **缓存型配置**（消息名即 CACHE）：写回只改缓存，在下一次连接决策才消费 ——
  LTE 驻留时改组网模式/制式，**不会自发重选回 NR-SA**（重发 AT+ERAT 也不触发），
  必须重附（CFUN 循环，厂商飞行同款）。产品化：api.sh netmode_set 检测实际变更后
  自动后台重附（幂等重应用不打扰，keeper 约 40s 重拨）。
- **ERAT 字段语义**（md1img 解析串 `parse_erat` + 范围串）：响应
  `<act>,<gprs>,<rat_mode>,<pref_rat>,<lock>` 5 字段；act=当前服务 RAT（3GPP AcT：
  7=LTE、11=NR；255 为写入后瞬态）；rat_mode 为配置值（本机恒 19,0；位分解推断
  GSM1+NR2+LTE16，20/21 亦被接受）；带 retry timer 且写 NVRAM（持久化）。
- 模组身份：**Quectel RG620T-EG**（MTK MT6990 平台）——高通系 `QNWPREFCFG` 直接
  CME ERROR 4，勿套用高通手册。SA/NSA 只读判别（固件内证实存在的查询）：
  `AT+C5GREG?`（5GS 注册态）、`AT+C5GPNSSAI?`（5GC 注册才下发 = SA 指纹）、
  `AT+QNWCFG="lte_rsrp"` + `"nr5g_ssb_rsrp"` 并存 = NSA 锚点指纹、`AT+ECELLMEAS`
  （带 rat 字段的小区实测）。
- 三档实弹（产品路径 netmode_set）：SA→持续 NR（N41/N79）；NSA→回落 LTE（本网
  未观测到 NSA 承载，符合锚点语义）；SA+NSA→NR。每档 conf/API/模组读回三层一致
  （selftest `t_cel_endc`）；变更自动重附后 75s 内新态生效。
