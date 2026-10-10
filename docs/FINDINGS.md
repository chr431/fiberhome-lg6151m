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

## 11. 有线断链不转移的根因（2026-10-09 21:30 实弹）

- **现象**：eth_prio 模式下家宽断链，用户侧断网数分钟且不自动转蜂窝；日志显示
  `06:02:42 state: 5g 1->0` 之后**长达 15 小时** `5g=0`（蜂窝待命侧逻辑死），
  直到 `21:32:30` 家宽自愈才翻转 —— 即"蜂窝备份"在 eth_prio 下 15h 不可用。 <!--CLM:CLM-AUTHD-PROBE-->
- **根因（认证信号被当成充分活证据）**：`authd` 的 `succ` 一旦置位**永不复位**，
  主循环里 `if(succ) state_write("up")` 在**收到任何 EAPOL 帧**时刷新会话状态；
  服务器周期性 `Req-Identity`（日志实测每 30s 一次）也满足"收到帧" ⇒ `up` 永远新鲜。
  wan_agg v2.24 的 `w2_alive` 把"新鲜 up"当作**免 ping 的充分活证据** ⇒
  认证二层链路在、**数据面已死**时仍判活 ⇒ 永不转移。
- **修复（双保险）**：
  - `gw/wan_agg.sh` v2.26：`AUTHD_UP` 不再裸判活，必须叠加数据面 ICMP 实证
    （新 `w2_data_alive`：网关优先 + 公网兜底）；`AUTHD_DOWN` 保留协议级零延迟快路径；
    转移上界不变（25s 硬截止 + 一个环循）。
  - `authd`（私有仓）v2.2：`up` 只由**认证层证据**刷新（Identity / MD5-Challenge /
    Type254 重询问 / Success），未知 EAPOL 帧只更新 `last_act` 保活计时。
- **实弹验证**：`ip link set eth0 down` 后 **8s** 完成 `5g 0->1 home 1->0 (d2=99)`
  自动转移（对比修复前：永不转移）；2s 后 rc19 链路看门狗把 eth0 拉起、自愈回切。
  回归护栏 `t_agg_w2_probe_guard`（脚本语义断言 + 稳定态下 up/数据面假活态检测，
  转移进行中不算故障）。

## 12. 定时重启与 /etc/TZ 重启即失（2026-10-10 实弹）

- **定时重启功能**：`gw/reboot_sched.sh`（出厂默认每日 04:00，GUI 系统页可改/可停；
  配置 = defaults 叠 settings 自管三件套）。五重护栏：REBOOT_EN=1 / 年份>=2024
  （无 RTC，防 1970 假命中循环）/ 开机 >=300s（重启后窗口内不复触发）/ 命中窗口
  [目标, +5min)（容 30s 轮询抖动）/ 当日未执行（`/data/gw/reboot_sched.last` 跨重启
  去重）。实弹：API 设 now+2min → 守护窗口内触发 → **76s 回升**；rc19 开机自动拉起、
  settings 配置保持、bootctrl TRY_A 开机自清（`0f 00`）、服务面全恢复（63/0 全绿）。
- **连带发现（既有缺陷）**：`/etc/TZ` 是指向 `/tmp/TZ` 的**符号链接（tmpfs）**——
  用户时区只存在于运行态，**重启即回落 UTC**（实弹：重启前 `+0800` → 重启后 `+0000`）。
  影响：时钟显示偏移 8h；**定时重启窗口随 TZ 整体平移**（04:00 会变成 UTC 04:00 =
  北京时间 12:00）。
- **修复（自管配置范式）**：`TZ=CST-8` 入 defaults.conf 出厂基线；`apply_ntp` 落
  `gw_set TZ`（空=gw_del 回退默认）；`get_ntp` 读持有效值（原读 /etc/TZ 运行态）；
  ntp_keeper v1.2 与 reboot_sched v1.1 **每轮重应用 /etc/TZ**（幂等双保险，不依赖
  彼此时序）。实弹：守护重启后数秒内 `TZ applied: CST-8`，`date` 回 `+0800`，
  日志时间戳 UTC→本地切换。回归护栏并入 selftest `t_sys_ntp`（tz 运行态==持有效值）。
- **selftest 同族修复**（暴露于用户 10:43 经 GUI 关闭访客网络后）：
  - **配置优先级盲读**：`sort -u + 任意命中`（defaults 的 GUEST=1 恒被找到）与
    `cat settings defaults | tail -1`（恒取默认值）两类写法在用户覆盖设置后必误报
    （4 个 WiFi 测试齐红 + NTP 测试潜伏）；收敛到 `eff_conf()`（settings 覆盖
    defaults，与设备侧 cfg_load 同序）。设备行为本身正确，是测试读错。
  - **token 缺席降级**：SSE 测试 `tok.encode()` 在登录不可用时直接 AttributeError； <!--CLM:CLM-TZ-TMPFS-->
    改记因 skip；且登录前查 `/tmp/gui_auth.fails`，>=8/10 不再尝试（工具不把设备
    推向登录锁定）。用户已改 GUI 管理口令（本地 `_local/secrets` 已同步）。
  - **MLO 证据源**：GUI 在线重应用会把 `/tmp/mld_boot.log` 重写为空（dmesg 已刷屏），
    ML 组创建证据只落在 `/tmp/wifi_up.log` 的 stdout 捕获；补为第三证据源。
