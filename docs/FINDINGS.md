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

## 13. 2.4G 信道"配置≠实况"根因与 MLO 实时观测面（2026-10-10 逆向）

- **信道问题根因（RE 实证）**：运行期唯一武装的自动切换主体是**驱动内 IDC
  （LTE 共存避让）**——`bEnabled=1`，每秒轮询模组 safe/power 掩码（`mwctl dev ra0
  show unsafeinfo`：`SafeChnBitmask=1fe-…` → **ch1–8 安全 / ch9–10 降功率 /
  ch11–14 需 TDM/FDM 避让**，随模组频段变化），必要时驱动自行 `rtmp_set_channel`
  搬道并触发 CH_SWITCH_NOTIFY（hostapd 只负责打印 "driver had channel switch"）。
  驱动 ACS 已关（`AutoChannelSelect=0`，AcsInfo 计数全零）；mtk_netagent 是纯 modem
  数据面代理（二进制无任何 wifi 字符串）；厂商 wapp/mapd 未运行。**结构性隐患**：
  我们的 auto-channel 只对 1/6/11 轻惩罚，**可能选出 ch9–13**（IDC 避让区）→ 必然
  出现"配置写 ch1 而实况被搬走"。 <!--CLM:CLM-IDC-SAFECH-->
- **修复**：wifi_up v1.27 选道前读 `SafeChnBitmask`（mwctl show 输出进 dmesg，取首段
  bit=信道号），候选集只在安全集内（读不到=模组未起 → 回退全量）；watchdog v1.5 加
  "生成配置 channel= == 实况"不变量：漂移时以实况回写 hap_*.conf + 记警（实况为
  权威，不闪 LED）；selftest `t_wifi_chcons` 同判据护栏。设备实测：mask=1fe →
  cand2g={1..8}；当前 conf=live=ch1。
- **开机后周期性同频 "channel switch" 成簇事件 = 假象**：`ChnSwitchCnt=0`、ACS 计数
  全零——实为 GUI wifiscan（apcli0/apclii0 up + 两轮 scan）与 no_bcn 重装产生的
  同频重报（每射频 3 条/簇，与 api.sh wifiscan 代码逐条同构），非信道管理。
- **MLO 实时观测面（RE 实证）**：`mwctl ra0 dump ap_mld all` **stdout 干净**（dump 段
  走 MTK vendor netlink 封装；show 段输出进 dmesg 不可脚本化）。实测输出：组号 1、
  两个 Affiliated AP（BSSID …:90/LinkID 0、BSSID …:98/LinkID 1、均 STR）→ **双链路
  健康**（此前"ml_link_num=1"只是首条 join 日志，rai0 随后加入无日志行）。纯 debugfs
  备选：`/sys/kernel/debug/mtk_hwifi/wsys/mld_bss/mld_bss1`（ref_cnt=2）。已接线：
  api.sh v2.68（wifi_state 增 mlo_grp/mlo_links，按索引去重计数）+ app.js v3.47
  （WiFi 卡片"MLO: 双链路正常（2 条）"）+ selftest v2.17（BSSID 集合=={ra0,rai0} MAC、
  LinkID 集合=={0,1} 强断言，旧日志证据链降为回退）。 <!--CLM:CLM-MLO-LIVE-->
- **工具陷阱（本轮踩到）**：`ql_wifi_sample` 交互程序在 stdin EOF 后**死循环**（两
  实例以 ~3700 行/秒刷 syslog，日志环被冲至 18 秒深 = 全部取证困难的元凶）；已清理，
  脚本化一律用 `mwctl`，勿用 ql_wifi_sample。另：`mwctl <dev> show X` 退出码 0 但
  stdout 为空，内容在 dmesg；`dump` 段才有干净 stdout。

## 14. 日志改善专项：持久化镜像与一键诊断包（2026-10-10）

- **痛点（本轮实战全部踩过）**：/tmp 日志重启即失（§13 信道取证丢失）；logread 环
  被刷爆（L28 实测 18 秒深）；dmesg 被蜂窝噪声淹没；日志散落 22 处无统一现场。
- **log_keeper v1.0（守护，rc19 拉起 + watchdog 自愈）**：每 30s 一轮，增量为零
  不落盘。syslog/dmesg **增量镜像** → /data/gw/logs/{syslog,dmesg}.log（锚行法：
  以上次镜像末行在环内定位，只追加新增；环溢出记 resync 标记 + tail 400 重同步；
  容量 4MB/2MB 轮转 .1，单轮限流 512K）；**/tmp 快照** → logs/tmp/<name>（tail 32K
  变化才写，重启后即上一个 boot 的最后现场）；**BOOT 分隔行**（wall+uptime+slot+kern）
  写入两个镜像；每次开机 +180s 自动生成 diag_boot.txt。
- **diag_dump v1.1（一键诊断包）**：基础(uptime/slot/TRY_A/内存/磁盘) + 配置(脱敏)
  + 无线(iw/MLO dump/IDC 掩码) + 网络(addr/rule/route/NAT) + 全量日志现场
  (logread/dmesg tail + 22 个 /tmp 日志 tail) + 持久镜像尾部。**脱敏**：WPAPSK/
  GUEST_PASS/AUTHD_CMD/wpa_psk 行与 URL token/pass 一律 <redacted>（实测 0 泄漏）；
  结束行带生成时刻（尾部展示时"上次生成"可读）。入口：GUI 系统页"生成诊断包"
  （diag_gen 端点 + logs.diag 尾部展示）/ 每次开机自动 / SSH `sh /data/gw/diag_dump.sh`。
- **实弹**：300 条 logger 洪泛注入 → 镜像 300/300 精确捕获；21 个 /tmp 快照就位；
  诊断包 90KB 脱敏审计 0 泄漏；selftest `t_sys_logk` 护栏（单实例/镜像新鲜<120s/
  BOOT 分隔在位）；watchdog 对 log_keeper 自愈、对 ql_wifi_sample 卡死进程
  （CPU>=120s）自动清除。 <!--CLM:CLM-LOGKEEP-->
- **已知边界**：开机早期（模组未起）IDC 掩码读取可能为空（diag 如实记录）；
  镜像为轮转单代(.1)，更早历史不留（防 flash 膨胀）；洪泛期间镜像可能丢环头部
  （resync 机制保证继续）。

## 15. 以太反复断连与手机"需要认证"误报（2026-10-11 凌晨实弹）

- **定性：上游/物理层问题，我方软件反应正确**。证据链：`carrier_changes`=98 次
  （4.3h）；载波断→恢复后**速率 1Gbps→100Mbps 降级协商**（一对线损坏/端口劣化的
  典型形态，1G 需四对线全好）；每次数据面死亡（wan_agg d2=99）都与 authd 的完整
  EAP 重认证（MD5→Success）时刻吻合——链路 flap → 上游交换机重启 EAP 会话 →
  authd 重连 → 数据恢复；100M 稳定后 flap 停止（计数不再增长）。
- **手机"需要认证"误报机理**：上游 EAP 重启窗口内"载波在/数据死"，旧判定链
  （3 击 × 最坏 6s 探测 + 25s 硬截止）确认死亡最长 ~25s，期间 LAN 探测流量走出
  eth0 被上游拦截页 302 → 手机把 SSID 标为需要认证并转投移动网络。
- **修复（wan_agg v2.27）**：探测超时 -W2→-W1；**首败同轮复核**——家宽首败立即
  复探、再败即确认（d2=3）。实弹：iptables 拦 eth0 出向 ICMP → **死亡确认 ≈1s**
  （01:57:23 注入 → 01:57:24 `home 1->0 (d2=3)`），恢复后含 18s 迟滞正常回切。
  手机可见窗口 25s 级 → 亚 10s，探测命中拦截页概率大幅下降；误报残留由 Android
  恢复后自动重验清除。 <!--CLM:CLM-ETHFLAP-->
- **遗留（物理层，需线下处理）**：速率停在 100M（当前稳定）。若 flap 复发可
  `ethtool -s eth0 autoneg on speed 100`（设备自带 ethtool）钉 100M 消除 1G
  协商振荡；根治需更换/重插墙插到 CPE 的网线或换上游端口。

## 16. 宵断确定性转移与信道振荡根治（2026-10-12 凌晨实弹）

- **背景确认**：宿舍上行每晚 00:06–00:07 定时断至 06:00（用户确认的固定作息）。
  断网本身正常；问题是转移慢——00:06 切断 → **00:12:14 才切换（~6 分钟）**。
- **检测迟缓根因（实弹还原）**：① 切断后 ~5 分钟宽限期内**网关仍答 ICMP**，而
  w2_data_alive 是"网关优先"探针链 → 短路了公网探针 = 探针全过（盲区）；
  ② 同期服务器 EAP **静默**（00:06-00:21 authd 零消息），authd 无 Failure 可写
  → 协议级信号也失明；③ 00:12:14 的触发是网关也停答后 25s 硬截止。
- **修复（wan_agg v2.28，**同日已下架**——用户裁定判定不做先验，静默型切断改由 authd v2.3 静默看门狗承接，见 §17）**：w2_data_alive 移除网关短路（判活只认公网 223.5.5.5/
  120.53.53.53，断网期实测全灭）；新增 **ETH_CURFEW 宵断时段**（defaults 叠
  settings，GUI 聚合页可改/停）：窗口内对 weight/eth_prio 模式**确定性判死**
  （最终裁决压过一切恢复规则），窗口结束自动回归探针+认证判定。实弹：部署重启
  即 `curfew enter (00:06-06:00): home forced down` → 5G 承载，零探测依赖。
- **连带发现并修复**：
  - **IDC 掩码动态收缩致信道振荡**：掩码随时段 1fe(ch1-8)→1fc(ch2-8)→08(仅 ch3)； <!--CLM:CLM-IDC-BOUNCE-->
    04:02 定时重启开机时模组未起、掩码不可用，wifi_up 回退选出边界道 ch9（功率
    压缩区）→ 驱动 IDC 整晚搬运 2↔3↔9（客户端每 30-60s 被踢）。修复 wifi_up
    v1.28：候选收敛安全集深部 {1,6}（两掩码形态下 ch6 恒安全），掩码不可用期
    回退亦为 {1,6}；现场重应用后 conf=live=3（当前掩码仅 ch3，逻辑正确自洽）。
  - **log_keeper 轮转丢 boot 分隔**：syslog 4MB 轮转后新生代无 BOOT 行（selftest
    护栏实弹抓获）。修复 v1.1：轮转后重写 boot 上下文。另确认 04:03 诊断包
    diag_boot.txt 随定时重启自动生成（全链路闭环）。
- **明早 06:00 恢复机制**：authd 30s 重试循环整夜在打 → 06:00 服务器放行 →
  EAP-Success → 探针恢复 → U2≥6（~18s）→ 自动回切有线。无需人工干预。
- **备选探针否定记录**：generate_204 类 HTTP 探针（miui/vivo/hicloud）从 CPE 发起
  一律被 RST（这些端点拒绝非手机客户端），baidu 等普通 HTTP 正常——HTTP 探针
  方案被否决（端点拒绝非手机客户端）；公网 ICMP 探针 + authd 静默看门狗为最终形态。

## 17. 断网判定最终形态：认证静默看门狗（2026-10-12）

- **裁定**：先验时段（ETH_CURFEW，§16）整体下架——判定不做先验，靠证据链本身
  精确快速。wan_agg v2.29 / defaults v1.8 / api v2.71 / app v3.51 同步移除。
- **authd v2.3 静默看门狗**（私有仓）：健康期服务器每 30s Req-Identity 重询问
  （实弹连续数小时 30s 节拍）。succ 锁存且 **>40s 无任何 EAP 帧 = 会话已死**
  → 降级进重试循环（Start 每 8s）+ 写 down（wan_agg AUTHD_DOWN 秒级通路，
  30s 周期刷新供新鲜度判定）。宵断型静默切断（服务器不发 Failure 只沉默）
  由此获得 **≤45s 本地判定**，替代旧逻辑的 5min idle 才判。
- **检测链最终形态**（四路独立证据，谁先触发谁生效）：
  1. 载波/IP 丢失 → 环循内立即（≤3s）；
  2. EAP Failure（显式踢）→ 瞬时（authd 直写 down）；
  3. 认证静默 → ≤43s（authd v2.3 看门狗，不依赖任何探测、不受宽限期影响）；
  4. 数据面公网 ICMP（首败同轮复核，v2.27）→ ≤6s（仅当 ICMP 可用作证时）。
  转移动作统一走既有状态机（kernel_apply+policy routing），恢复迟滞 U≥6 不变。 <!--CLM:CLM-AUTHD-SILENCE-->
- **验证状态**：authd v2.3 已部署运行（Failure→down 刷新实测 ✓）；静默路径待
  下次 00:06 切断实战检验（log_keeper 镜像将留全量现场）；06:00 恢复为
  重试循环自动完成。

## 18. 模组 EE 致命异常事故：5G 断联、恢复缺口与指示灯谎报（2026-10-14 凌晨实弹）

- **事故本体**：01:07:47 蜂窝模组固件致命异常（AEE 抛 `Externel (EE)`，类型 modem，
  `md1:(MSONIC0) [Fatal error] err_code1:0x12 err_code2:0x71B3E53B err_code3:0`，
  `MD Offender:DSPNR1s`；构建 `MOLY.NR16.R2.MD800.MP.V86.P56 / QUECTEL_2305MP2`）。
  AP 侧零前兆：温度平直 47–52°C、无 OOM、无内核挂死。异常前 1s thermal_core 先丢
  数据源（`mipc_sys_get_all_thermal_info error` + 五路 -274000 假值）——模组侧先死，
  温度假值是果不是因。转储 `/data/log/aee_exp/db.03.EE`（6.2MB，内容加密，仅
  ZZ_INTERNAL 可读；db_history 显示为 10-05 以来首个 EE = 低频偶发、厂商固件缺陷）。 <!--CLM:CLM-MD-EE-->
- **后果链与恢复缺口**：`MD_STA_EV_STOP` → netagent `reset all telephony services` →
  ccmni0–20 全 down（5G 数据口被拆）→ 模组重启（01:08:10 已重新注册）——**但数据呼叫
  直到 01:13:17 用户断电都未恢复**：窗口内无任何 ccmni IPv4、无任何重拨留痕
  （拨号动作有明确日志特征 `mipc_cli: data_call_act_type:...`，当窗口零命中）。
  宿舍上行宵断期（00:06–06:00）5G 是唯一承载 → 用户全断网，手动断电收场。
  缺口机理：守护现场只写 /tmp，重启即被新 boot 覆盖 → 无法分辨"死了还是卡死"；
  疑因：模组 EE 后厂商重启 RIL/ql_netd 瞬间，mipc 调用可无限阻塞（设备无 `timeout`
  命令，裸调无超时）。修复四件套：`mto()` 纯 shell 硬超时（实测 30s 卡死调用 3s
  被杀 rc=124）/ 心跳 `/tmp/dial_keeper.hb`（≤5s 分片刷新；watchdog 判陈旧 >90s
  杀+拉）/ **EE 转储增量 = 模组复位信号 → 强制重拨并重置退避**（不等被动 35s 宽限）/
  关键事件 `logger` 落 syslog 经镜像持久化。 <!--CLM:CLM-DIAL-GAP-->
- **指示灯谎报（用户第一手症状："5G 下线灯还亮着"）**：led_mgr 旧语义"无承载=橙
  常亮"——模组崩溃/离线期橙灯照样点 = 谎报"5G 在"。v1.9 收敛数据面唯一：ccmni 有
  IPv4=绿常亮，其余（未注册/无承载/模组离线）三色全灭；细分态只进日志
  （`5g=reg_no_bearer` 等）。实弹验收（趁家宽在线主动 deact）：15s 内三灯全灭 →
  dial_keeper 35s 宽限后自动重拨，42s 恢复 → 绿灯回（连带实测：重拨后数据口索引
  会变——ccmni2→ccmni3，厂商分配行为，灯/拨号/聚合均接口无关化）。 <!--CLM:CLM-LED-LIE-->
- **取证保全**：log_keeper v1.2 新 boot 首轮把上一 boot 的 /tmp 快照整目录转存
  `logs/tmp.prev`（`.snap_up` 记录归属 boot，同 boot 内守护重启不转存）；旧"变化才写"
  会在新 boot +90s 内覆盖事故现场（当晚 dial_keeper/watchdog 现场因此丢失）。实测
  转存 10+ 份守护日志。 <!--CLM:CLM-SNAP-PREV-->
- **守护定位（本轮新代码自暴露的两个坑，均已修）**：① watchdog 首见"无心跳文件且
  已过开机宽限"误判陈旧杀+拉（部署重启新实例实测命中）→ dial_keeper v1.2 启动即写
  心跳，窗口≈0；② 单实例判据用 `pgrep -f` 在"启动者 argv 含脚本路径"时自匹配
  （SSH 一行式启动实测两次静默不启动），且"杀所有匹配"会误伤旁观 shell → v1.3 改
  **PID 锁**（cmdline 复核防 PID 复用；watchdog v1.8 依锁精确定位实例）。 <!--CLM:CLM-KEEPER-LOCK-->
- **启动耗时分解（串口取证暂缓）**：断电 01:13:17 → 内核启动 01:17:00（**3m43s
  空白**，OS 侧日志无法归因）；此后 +23s 自研 rc、+70s 拨号成功、+89s WiFi 完成、
  +150s 全绿。LK 自报 preloader 1.17s + LK 2.31s（cmdline bootprof 标签）；用户态
  时间线与 04:00 例行重启同形 = 系统侧无异常。空白段只能串口分辨（LK 弹幕）。
- **排除项（防误判）**：过热（全程 47–52°C；-274 系模组死后的假读）/ 内存压力
  （无任何 oom 记录）/ "log_keeper 反复死亡"（syslog 五个 BOOT 行经核对全为 dmesg
  2MB 轮转——轮转机制会往两个镜像写 BOOT 行，勿当重启）/ 内核 FORENSIC D 风暴
  （基线打印，健康 boot 同样每 ~3s 一条、hang_detect status 0）/ 5GHz AP 故障
  （无 beacon 异常，rai0 ch36 全程在发；客户端掉线为客户侧行为）。
- **回归护栏**：selftest v2.21/v2.22 三条——5G 灯数据面一致性（`--dry-state` 映射
  c0→全灭 + 实况引脚）、拨号守护心跳/`mto` 接线/PID 锁↔活进程跨层一致、快照转存
  标记 `.snap_up`。全量 selftest 67 pass / 0 fail。
