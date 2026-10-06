# 原厂 RP0103 vs 自研 v4 固件功能对比（FEATURE MATRIX）

> 2026-10-05。原厂侧依据 `VENDOR_MAP.md`（五路逆向汇总），自研侧依据本仓库工作树。
> 目的：一张表看清"我们有什么、丢了什么、什么更强、什么待做"。

---

## 1. 架构对比图

```
            原厂 RP0103                              自研 v4
┌─────────────────────────────────┐    ┌─────────────────────────────────┐
│ 管理: nginx(80/443,Lua WAF)      │    │ 管理: v3httpd(:80, 348KB 自研 C) │
│        →FastCGI:8840→webs(395KB) │    │        →api.sh(876行)+SPA(8页)   │
│        RSA+AES 会话加密层         │    │        sha256 口令+token          │
│        Vue2 SPA(90 页面组件)      │    │        +插件槽(私有认证器)         │
├─────────────────────────────────┤    ├─────────────────────────────────┤
│ App:  iotagtd NDMP:18996/8       │    │ App:  ✗ 不提供(设计放弃)          │
│ 云:   Kaa SDK 云通道+RSA 密钥     │    │ 云:   ✗ 无任何外联(WAN 侧封)      │
│ ACS:  TR-069 CWMP(:30005)        │    │ ACS:  ✗ 无                        │
│ 互联: filink CoAP:5683           │    │ 互联: ✗ 无                        │
├─────────────────────────────────┤    ├─────────────────────────────────┤
│ 编排: procd(56 rc.d)             │    │ 编排: zz_data_hook(S98)→rc.extend │
│      →FH rcS→sysmgr(26 项 DAG)   │    │      →v3_rc10(WiFi/br-lan/守护)   │
│      →process_check(13s)         │    │      →rc_netfh(MODE.fh 蜂窝最小军) │
│      守护总数 50+                 │    │      守护总数 ~15                  │
├─────────────────────────────────┤    ├─────────────────────────────────┤
│ 蜂窝: mobilenetwork(树翻译器)     │    │ 蜂窝: 同款 ql_netd/ql_ril_service │
│      →libqlril/libqlnet→MIPC     │    │      +mobilenetwork(过渡期复用)    │
│      AT 面经 atcid→MIPC           │    │      api.sh 直用 mipc_wan_cli/AT  │
├─────────────────────────────────┤    ├─────────────────────────────────┤
│ WAN:  wancc(879KB)总控全家桶      │    │ WAN:  wan_agg.sh(v2.18)+iptables  │
│      quecadp 内核分流(jhash)      │    │      源端口范围拆分+fwmark+钉死     │
│      (链在自定义启动下从未加载)     │    │      +GUI 开关/热重载/旁路         │
├─────────────────────────────────┤    ├─────────────────────────────────┤
│ WiFi: wifimgr+hwifi+EasyMesh     │    │ WiFi: wifi_up.sh 工厂配方          │
│      map_master/slave(1905)      │    │      +hostapd F3 安全层接管         │
│      驱动内部 WPA(MLD 缺陷)       │    │      +自动选道+分析仪+访客 BSS     │
├─────────────────────────────────┤    ├─────────────────────────────────┤
│ 治理: process_check 13s           │    │ 治理: watchdog v1.2(17 不变量+自愈)│
│      slt2 产测×3 + meta_tst       │    │      selftest 50 断言×7 类         │
│      mdlogger/log_controld        │    │      deploy 版本登记/md5/漂移检查   │
│      (无自动化测试体系)            │    │      +刷机链(串口/A/B 槽/全回归)    │
└─────────────────────────────────┘    └─────────────────────────────────┘
```

## 2. 功能逐项对比

图例：`=功能对等` `▲自研更强` `▼自研受限` `✗设计放弃` `⏳第二阶段目标`

### 2.1 管理/控制面

| 功能 | 原厂 | 自研 | 评 |
|---|---|---|---|
| Web 管理 | nginx+webs，RSA/AES 加密 API，Vue2 90 页组件 | v3httpd+SPA 8 页，token 会话 | `=` 核心管理面齐备；页面少而精 |
| 权限分级 | 3 级用户(普通/管理/超管)+WAF 三层+节点级白名单(r0=1/w1=319/w3=371) | 单口令+token | `▼` 无分级（单用户场景够用）|
| 坏口令锁定 | LoginErrMaxCount/WaitTime | 无（LAN 单口令面小）| `▼` |
| 页面缓存对抗 | — | `?v=N` 缓存破坏+selftest 断言 | `▲` |
| 远程管理 | TR-069 ACS(:30005)+Kaa 云+NDMP App | 无任何远程面（WAN 侧 iptables 封 1899x/30005）| `✗` 有意：消解云端覆盖风险（FINDINGS §8）|
| 烽火 App | NDMP 明文 18998/TLS 18996+云绑定门控 | ✗ | `✗` |
| 多语言 | zh/en/pl 20+ 资源文件 | zh | `▼` |
| 插件机制 | 无（省份/运营商编译期分支）| /plugins.js 运行时注入页 | `▲` 可插拔认证器（公共/私有仓库分割的基石）|

### 2.2 蜂窝

| 功能 | 原厂 | 自研 | 评 |
|---|---|---|---|
| 5G 拨号 | mobilenetwork→ql_netd→MIPC | 同底层链(rc_netfh 最小军) | `=` |
| 载波/小区信息 | 树 RadioSignalParameter(16 CA 列) | 树读(过渡)+AT CSQ+mipc nw_get_signal(RSRP) | `=` `⏳`去树化 |
| 锁频段 | 树→mobilenetwork→ql_nw_set_band_mode(MIPC) | 同链(cfg_cmd 写树+快照重放) | `=` `⏳` 自研直连 libqlril |
| 锁小区 | 树→AT+EMMCHLCK | 同链 | `=` `⏳` AT 直发 |
| SIM/IMEI/PLMN | 树+AT | 树+AT(CPIN/COPS/CGSN/CCID 双源交叉验证) | `=` |
| PIN 管理 | ubus mobile_network update_pin_info | 同 | `=` |
| 短信 | 收(MIPC IND→树)+发(mn_send_sms) | 收(AT+CMGL 只读)；发禁用(CMGS 交互毒死承载) | `▼` 只收不发是工程取舍 |
| 流量统计/限额 | mobilenetwork 轮询 /proc/net/dev | ubus traffic_statistics+自管日/月限额+GUI | `=` |
| 制式/飞行 | 树→AT+erat / ql_dm | 同链 | `=` |
| PLMN 扫描 | RIL_NW_NETWORK_SCAN | ubus start_search_network | `=` |
| 信号事件流 | ril.unsol.nw.signal 推送 | 轮询 | `▼` `⏳` |

### 2.3 网络/WAN

| 功能 | 原厂 | 自研 | 评 |
|---|---|---|---|
| 多 WAN 分流 | quecadp 内核引擎 jhash（自定义启动下整链未载=实际死的）| iptables 源端口范围+fwmark 策略路由 | `▲` 我们的真在工作且可热调 |
| 分流权重 | ioctl 热调 | agg_weights 端点热重载+GUI 滑杆 | `▲` |
| MAC 钉死 | quecadp mac 表 | 源 IP 绑定(MAC→ip neigh 解析)+偏移检测 | `=` |
| 聚合开关 | Web 有(树路径) | agg_mode 端点+bypass/engage 实测 | `=` |
| 故障切换 | link_detection 守护 | wan_agg ~15s 探测切换 | `=` |
| 端口映射/DMZ/禁网 | secmgr+iptables | fw_apply.sh(iptables)+GUI | `=` |
| DHCP | udhcpd(FH 版)+静态租约 | dnsmasq 单进程(池+静态+选项) | `=` |
| IPv6 | dhcp6c/dhcp6s/radvd/nding 全家 | ULA+NAT66+radvd | `▼` 无 DHCPv6-PD 委派（当前上行场景不需要）|
| IPv6 诊断 | rastatus | — | `▼` |
| PPPoE | pppd+rp-pppoe(家宽口可拨) | eth1 DHCP 家宽口(PPPoE 未用) | `▼` 如换 PPPoE 上行需补 |
| QoS/限速 | qos(tc)+userlimit.ko+flow ACL 引擎 | 无（流量限额仅统计报警）| `▼` |
| UPnP IGD | upnpd(:1900) | ✗ | `✗` 攻击面考虑 |
| 路由协议域 | wancc 静态路由/域名转发列表 | 无静态路由 GUI | `▼` |
| DNS 分流 | dnsrelay+dnsmasq(端口绑定私补丁) | dnsmasq 双上游 | `=` |
| 防火墙体系 | firewalld(secmgr)+ebtables+CHAIN_SERVICE 体系 | iptables 直管(可审计规则集) | `=` |
| 上行认证 | 无此概念 | uplink 插座(AUTHD_CMD/MAC/TTL 伪装)+私有插件 | `▲` 原厂没有的能力 |

### 2.4 WiFi

| 功能 | 原厂 | 自研 | 评 |
|---|---|---|---|
| 射频管理 | wifimgr(452KB)+hwifi dat | wifi_up.sh 工厂配方+自动选道评分 | `=` |
| 安全层 | 驱动内部 WPA（MLD 组网不发 EAPOL M1=缺陷）| hostapd F3 单进程 3 BSS（PMK 直喂）| `▲` 修好了原厂缺陷 |
| Mesh/EasyMesh | map_master/slave 1905 全栈 | ✗ 单机模式 | `✗` |
| 访客网络 | wifiguest.sh 隔离(type1/2) | 独立名称/频段(2G/5G/双频)/密码 + guest_fw.sh 原厂同款 ebtables 隔离(仅出网) <!--CLM:CLM-GUEST-INDEP--> | `=` 双频=同名双 BSS 漫游 |
| MLO 多链路 | 可用(wifimgr+libwifiadapter 写 MldGroup) | **可用**(两带 dat 各写 MldGroup=1;…; 访客静态组17/18; hostapd vendor-subcmd248 同步链全通, E1-E4 实证) <!--CLM:CLM-MLO--> | `=` 纯 MLO 不需 wapp; v1.15"雷区"实为全零表+缺拓扑误判; 切换需重启(FW 锁存) |
| WiFi 分析 | — | 信道图/评级/AP 列表/时间图 canvas | `▲` |
| 160MHz | 可用（同款 dat 链）| **可用**（EHT_ApBw/VHT_BW 双字段齐设后实测 2402/2882 Mbps PHY） <!--CLM:CLM-160-FM-->| `=` 早期"驱动钳制"结论是 dat 语义错位误诊，2026-10-05 翻案 |
| 漫游加速 | roaming_accel.ko(ARP 注入) | ✗ | `✗` 单 AP 无漫游场景 |

### 2.5 系统治理（差距最大的一域）

| 功能 | 原厂 | 自研 | 评 |
|---|---|---|---|
| 看门狗 | process_check 13s+sysmgr 300s（曾出现 respawn 混乱）| watchdog v1.2：17 不量+atcid 自愈+LED 告警+状态转移日志 | `▲` | <!--CLM:CLM-WATCHDOG-17-->
| 自动化测试 | 无（产测残留不算）| selftest 52 断言×7 类+数据面探测+破坏性验证+文档漂移审计 | `▲` | <!--CLM:CLM-SELFTEST-51-->
| 部署管控 | FOTA 云推（可被覆盖，见 §8 FINDINGS）| deploy.py 版本登记/md5 预检/漂移 doctor/push 后自动 selftest | `▲` |
| 刷机安全 | /lib/upgrade 无签名校验（gzip 魔数+md5）| 硬门控 flash.sh+bootctrl A/B+TOOR_PASS 构建时注入 | `▲` |
| 版本可追溯 | SoftwareVersionTable | VERSIONS.tsv+git 全历史 | `▲` |
| 日志 | logmgr/syslog/mdlogger 三层 | syslog+watchdog.log+wan_agg.log | `=` |

### 2.6 语音/其他

| 功能 | 原厂 | 自研 | 评 |
|---|---|---|---|
| VoIP(SIP 话机) | sip+baresip+SLIC 驱动链 | ✗（移动版无话机硬件，原厂也空转）| `✗` |
| DDNS | 4 客户端(ddnsd/inadyn/ez-ipupdate/花生壳) | ✗ | `✗` |
| VPN 服务器 | IPSec/L2TP/PPTP 全家(strongSwan+xl2tpd) | ✗ | `✗` 如需再评估 |
| USB 功能 | RNDIS+ADB+双 ACM+USB 升级验签 | ✗(adbd 未启用) | `✗` |
| NTP | sysntpd(禁用!)+scd 体系+ntpdate | ntp_keeper 多服务器+跳变实测校验 | `▲`（原厂 sysntpd 竟是禁用的）|
| 温控 | thermal_core(MIPC 联动)+风扇 | thermal_zone 读+fan_mgr 双模式 | `=` |
| LED | peripheral+libLedState 体系 | led_mgr+夜间模式 | `=` |
| 工厂产测 | META 模式+slt2+load_cli 全层 | ✗（保留 LK 串口进入能力）| `✗` |

## 3. 攻击面对比

| 面 | 原厂 | 自研 |
|---|---|---|
| 监听端口 | 80/443/23(按需)/53/18996/18998/30005/1900/5683+8840/8841 内环 | **80/22/53 三个** | <!--CLM:CLM-ATTACK-SURFACE-->
| 常驻凭据面 | superadmin 常量口令/telnet 沙箱口令规则/RSA 私钥内置/沙箱白名单逃逸史 | 单口令 sha256+token；无内置凭据 |
| 已利用过的洞 | send_msg 反引号注入 uid=0、AT 注入、沙箱 strings 任意读、LK 串口链 | 同硬件层（LK 链不可消除，靠口令/物理接触缓解）|
| 云端覆盖 | Kaa+TR-069 可远程改配置/推固件 | 无云端 |
| 死代码引雷 | telnet 多播二进制/plusdebug/工厂域/产测残留 | 裁剪+不启动 |

## 4. 资源占用对比（同一硬件实测）

| 项 | 原厂全量 | 自研 v4 |
|---|---|---|
| 用户态守护 | 50+（fhrom 20 + rc.d SDK 25+）| ~15 |
| cfg 共享内存 | 16MB(shm 0x7539) 常驻 | 同(过渡期；第二阶段裁撤后释放) |
| rootfs 内 Web 资产 | nginx 1.6MB+webs+Vue SPA | v3httpd 348KB+SPA |
| 产测/调试残留 | slt2×3/meta_tst/mdlogger/fh_debug×8 | 0 |

## 5. 明确放弃清单（理由）

iotagtd/Kaa 云/TR-069（远程覆盖风险）· NDMP App（依赖云绑定）· filink CoAP · EasyMesh（单 AP）· VoIP（无硬件）· DDNS×4 · VPN 三族 · UPnP（攻击面）· 产测全层 · SMS 发送（承载毒性）。（160MHz 曾在此清单，2026-10-05 实测翻案移除）

## 6. 第二阶段输入（本次逆向的直接产物）

1. **锁频段自研路**：dlopen /usr/lib/libqlril.so 调 `ql_nw_set_band_mode(lte/nr/umts 位图)` —— 无需逆向裸 TLV msgid。
2. **裁撤 mobilenetwork 前必测**：它可能是拨号承重墙（stock 上 netifd proto 未落地，PDN 由 mobilenetwork→ql_netd 建立）。实验：杀 mobilenetwork→观察 ccmni 存活。
3. **cfgmgr 裁撤影响面**：cfg 树 24 分支中仅 webs/iotagtd/tr069/mobilenetwork 消费的分支可随之死亡；LANDevice/WANDevice 树数据在裁撤后无人写。
4. **quecadp 复活钥匙**：完整加载链 fhdrv_common_init→pon_init→net_init（现从未执行）；D 报告含 253 个 ioctl API 函数名表。
5. **事件流升级**：订阅 ubus `ril.unsol.nw.signal`/`submonitor_*` 16 主题可把轮询换推送。
