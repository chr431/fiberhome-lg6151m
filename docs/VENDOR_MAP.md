# 原厂固件 RP0103 全量逆向地图（VENDOR MAP）

> 2026-10-05 五路并行逆向（启动链 / fhrom 守护普查 / modem-MIPC 栈 / 内核模块 / 控制面）汇总。
> 分析底座：RP0103 A 槽 squashfs 完整解包树 + RP0102 对照 + 生产设备只读验证。
> 本文是"原厂如何组成一台 CPE"的权威参考；功能取舍对比见 `FEATURE_MATRIX.md`，零散结论见 `FINDINGS.md`。
> 全文脱敏：不含 IMEI/IMSI/ICCID/序列号/MAC/口令/密钥。

---

## 0. 十条关键结论（含对既有认知的修正）

1. **PID1 是 procd，但 `/etc/init.d/rcS` 并非 sysinit 入口** <!--CLM:CLM-PROCD-INTERCEPT-->：procd 内建 rcS 扫描器拦截 inittab 的 `::sysinit:` 行，串行 glob 执行 `/etc/rc.d/S*`（56 个）。FH 定制的 rcS（烽火层）真正调用者是 **S99zmtk_boot_done 的末行** —— 烽火驱动/服务层在 rc.d 链最末端才启动。
2. **应用层编排不在 procd 而在自研 sysmgr**：`process_start_list`（26 项，依赖 DAG + 两优先级）+ process_monitor（300s）+ process_check.sh（13s）构成三层看护。原厂已禁用 14 个标准 OpenWrt 服务（dnsmasq/dropbear/firewall/uhttpd/odhcpd/telnetd 等），FH 应用完全绕开标准网络栈。
3. **拨号执行者不是 netifd** <!--CLM:CLM-DIALER-QLNETD-->：`network.wan.proto='ql_datacall'` 的 proto 脚本在包里声明了但**从未落地**。原厂真拨号链 = mobilenetwork(libqlnet) → ubus ql-netd → ql_netd → MIPC TLV → modem。netifd 仅在 proto=mipc/ql_mipc 分支有效。**2026-10-05 闸门 A 定案**：mobilenetwork 是 PDN 生命周期持有者 —— 杀掉后 ccmni IP ≤10s 消失（RF 注册仍正常）；裸重启不够，需完整环境(PATH+LD_LIBRARY_PATH)重拉或重跑 rc_netfh；ql_netd 独立维持不了拨号。**裁撤 mobilenetwork 前必须先建自研拨号（ROADMAP P2）**。
4. **AT 命令的最终通道是 MIPC**：`mipc_wan_cli --at_cmd` → libql_at(ql_atcid_sender) → atcid（unix socket /dev/atci-service）→ libmipc_msg → /dev/ttyCMIPC0..14 → ccci → modem 的 ssds_atp 任务（5mipc_inject_string_hdlr 端点）。atcid 是 AT 通道本体，atci_service 是系统级伴生。
5. **锁频段无 AT 面** <!--CLM:CLM-BANDLOCK-LIBQLRIL-->：mobilenetwork 的 fh_process_lock_band 线程调用 **libqlril.so 的 `ql_nw_set_band_mode`**（168B 结构，2026-10-05 全破译并实弹验证：mode=3@0x00 / umts 位图@0x04 / LTE 双字@0x08+0x0C（band n→bit n-1 / n-33）/ NR 三字@0x28+0x2C+0x30（band n→bit n-1 / n-33 / **n-65**，N41→@0x2C bit8、N79→@0x30 bit14）/ 全 1=解锁），经 ubus ril → ql_ril_service → MIPC。锁小区才有 AT 面（AT+EMMCHLCK）。自研引擎 `mipc_cellular` 已按此结构直发（锁 NR41+79 实弹零扰动）。 <!--CLM:CLM-BANDLOCK-STRUCT-->
6. **fhdrv_* 内核驱动族（19 个 .ko）在裁剪后的设备上从未加载** <!--CLM:CLM-FHDRV-UNLOADED--> —— 此前 quecadp 引擎 ioctl ENOTTY 之谜的真正根因是整条加载链（fhdrv_common_init → pon → net）没有执行，而非加载顺序问题。
7. **双 TLS 栈并存**（OpenSSL 1.1 + wolfSSL 35.3.0）：HTTP 面走 OpenSSL，cfg/通用层走 wolfSSL。双 dnsmasq 思路同理 —— FH 对 dnsmasq 打了私有补丁（按端口绑定转发）。
8. **原厂 Web 前端是 nginx(80/443, Lua WAF) → FastCGI(127.0.0.1:8840) → webs** <!--CLM:CLM-NGINX-PORTS-->。（FINDINGS 早期记录的 ":8080" 实为 v4 复活层自足 conf 的监听，非原厂。）WAF 是三层权限模型：Lua 请求规则 + 文件级（运营商×区域×用户级）+ 数据级（xmlnode 白名单：未登录仅 1 节点可读，超管 371 节点可写）。
9. **云通道实锤**：iotagtd 内嵌 Kaa SDK，bootstrap 硬编码厂商内网地址；App 本地协议 NDMP（明文 :18998 / TLS 双向 :18996）。TR-069 CWMP 使能（连接请求口 30005，ACS URL 空）。
10. **模式门 7 项**：META（atag bootmode=0001）、工厂模式（/fhdata/factorymodeflag → fac_process_start_list 15 项）、串口门（/fhconf/uart_conf）、WiFi TestMode（e2p 0x1af bit0）、测试卡（PLMN 1001）、ADB-AT（AdbAtEnable）、printk 门。GAINftp 在本固件不存在。

---

## 1. 顶层启动树（从 LK 到应用守护）

```
LK(按 misc[2060] bootctrl 选槽) ─ kernel 5.15.134 (aarch64, OpenWrt 23.05 r23497)
 └─ /sbin/init(桩) ─ /sbin/procd [PID1]
     ├─ ubusd + inittab 解析
     ├─ [procd rcS 扫描器] 串行执行 /etc/rc.d/S*（56 项，见 §2）
     │   …末端…
     │   └─ S99zmtk_boot_done (bootctrl 置位/首启克隆对槽)
     │       └─ sh /etc/init.d/rcS        ◄── 烽火层入口（129 行）
     │           ├─ fhdata_init / fhconf_init（产测分区+配置补齐）
     │           ├─ fhdrv_common_init → kdrv_board(+impl,+impl2) + mknod
     │           ├─ ko_install（ebtables 族 20 模块 + xt_webstr）
     │           ├─ sysmgr -init（读 fh_hw_cfg=0x10007060）
     │           ├─ fhdrv_pon_init  → pon_dev→service→eth_hook→pon_drv→eth_drv
     │           ├─ fhdrv_net_init  → net_dev→forward→fdb→flow→quecadp→ondemand→userlimit
     │           ├─ iptables ccmni 9991 MARK / ebtables RA DROP / lo up
     │           ├─ fhdrv_wifi_init_BE5000 → fh_kcrypto → mt7992 链（但实机生效走 modules.d）
     │           └─ sysmgr &               ◄── 应用层入口
     │               ├─[process_start] process_start_list 26 项拓扑序:
     │               │   cfg_tool(param.pdt.enc 解密) → cfgmgr(16MB shm key 0x7539)
     │               │     ├─ logmgr → eventmgr → secmgr → protocolmgr
     │               │     ├─ mobilenetwork（taskset 0,2；蜂窝核心）
     │               │     ├─ wancc(dep×4；WAN 总控 879KB)
     │               │     │    └─ udhcp*/dhcp6*/radvd/dnsmasq/dnsrelay/pppd/nding
     │               │     ├─ web(start_webserver.sh = spawn-fcgi webs:8840 + nginx:80/443)
     │               │     ├─ iotagtd(:18996-18998 NDMP + Kaa 云)
     │               │     ├─ wifimgr(→hwifi/apcfg) / link_detection / trafficmgr
     │               │     └─ process_check.sh（13s 看门狗）
     │               ├─[process_monitor] 300s 周期查活
     │               └─[fhconf_flash_monitor] 95% 阈值 10s
     └─ console respawn → login.sh（uart_conf 存在才有 getty ttyS0）
```

## 2. rc.d 启动时序（56 项精编版）

关键节点（完整 56 行表与 81 项 init.d 清单见原文 `_re/reports/A_boot.md`，公开库存此精编）：

| 阶段 | rc.d | 内容 |
|---|---|---|
| 00 基础 | S000mount_all | 分区挂载/格式化（nvcfg/nvdata/protect1, /data ext4）|
| | S001-S003 | nvram_daemon, **ccci 三件套**(fsd/mdinit/rpcd_com, nice -20) — modem 生命线 |
| | S00mtk_pre_wifi | e2p 0x1af → WiFi TestMode 门 |
| | S10boot | generate_wifi_mac + **kmodloader(169 模块)** + uci 生成 |
| | S10wpad | hostapd + wpa_supplicant（respawn 3600s）|
| 10-50 平台 | S12log/rpcd, S22mtk_netagent, S25packet_steering, S30usb(gadget+adbd), S50cron/qos/thermal_core, S53scd/lppe, S55-57 语音族, S60vnstat | |
| 80-96 SDK | S80wapp(已注释实为 EasyMesh 链), S85 auto_adapt + **ql_ippt/ql_netd/ql_ril_service**(拨号三件), S92baresip, S95aee_aed/done/hang_detect, **S96atci_service+atcid**(AT 通道对), S96led, S98mdlogger/meta_tst | |
| 99 收尾 | S99log_controld, **mipc_submonitor**(IND→ubus 16 主题), **mipc_wan.init**(APN 供给+radio on), ql_*, slt2_test(产测残留), S99zmtk_boot_done → **rcS**(烽火层) | |

三层 respawn：procd(rc.d 守护) → sysmgr process_monitor(300s) → process_check.sh(13s, FH 应用)。

## 3. 功能域 × 模块普查（fhrom/bin 81 ELF + 84 库）

### 3.1 域分布与核心成员

| 域 | 成员（守护+CLI） | 核心依赖 | 一句话 |
|---|---|---|---|
| 配置核心 | cfgmgr/cfg_tool/cfg_cmd, sysmgr, eventmgr, logmgr, su_tool, preconfig_handler×2 | libfhcfg(305 导出)/libfhapi/libfhdev | 16MB shm cfg 树（key 0x7539）是全部 FH 应用的单点依赖 |
| Web 管理 | webs(395KB), nginx(1.6MB), spawn-fcgi, (telnetd_multicall 由 webs 按需拉) | libwebkey + cfg 树 | FastCGI 集权：API+telnet 启停+printk+端口镜像一个进程全管 |
| 云/App | iotagtd, filink | libatos_port/liblocal_agent/libsmart_router_service/libcoap | Kaa 云 + NDMP 本地 + CoAP:5683 组网发现 |
| 蜂窝 | mobilenetwork, mn_send_sms/mn_send_pdu/mn_read_sms/mn_resolve, mtk_cli, peripheral, (temprotection†死代码) | usr/lib libqlril/libqlnet/libql_uinf/libql_qlog | 树↔modem 翻译器（详见 §4）|
| LAN/交换 | lancc, onu_igmpv3, nding, arping, trafficmgr, link_detection, upnpd, fhtopo | libigmp/libmld/libipi/libmc_hal/libpal/libmap* | 主机表/组播/IPv6 ND/拓扑 |
| WAN/协议 | **wancc(879KB 总控)**, protocolmgr, udhcpc/udhcpd, dhcp6c/dhcp6s, radvd, dnsmasq(私补丁), dnsrelay, pppd | rp-pppoe/pppol2tp 插件, libfhresolv | WAN 全家桶的母亲进程 |
| 安全/VPN | secmgr(瑞士军刀), xtables-legacy-multi(+6 链接), ipset, charon/starter/stroke/pki(strongSwan), openssl, curl, fh_security_usb, telnetd_multicall | libstrongswan/libcharon + 44 插件, passwordcrypt.so(dlopen) | 防火墙+ACL+家长控制+IPSec/L2TP/PPTP+USB 验签 |
| WiFi/Mesh | wifimgr, map_master/map_slave/map_cli, i5_ctl | libwifi*/libmap×6/libfhmap | EasyMesh 1905 Controller/Agent; 访客隔离 wifiguest.sh(ebtables broute 配方)→已由 gw/guest_fw.sh 复刻 |
| 语音 | sip, (baresip@rc.d) | libsip_app + libql_slic/libqlvoice | FXS 话机（移动版无硬件=空转）|
| 诊断 | pingdiag, traceroute, ntpdate, dumpleases, rastatus | libfhresolv, libpcap(†未消费) | |
| 工厂 | load_cli(48 NEEDED!), dev_mgm_debug(FTP/TFTP 后门+端口镜像), kdrv_debug, get_led_config | 14 个 *_cli 库 | 仅 factorymodeflag 激活，常态隐藏攻击面 |
| DDNS | ddnsd, inadyn, ez-ipupdate, phddns(花生壳) | 通用底座 | 四套客户端并存 |
| tr069 | tr069 | libtr069_adapter(191f)/libdata_model_adapter(899f) | CWMP=1, 连接口 30005 |

† 全 rootfs 零引用。

### 3.2 库分层（84 个 fhrom .so）

```
L0 公共运行时   musl libc, libubox, libubus, libjson-c, libuci
L1 烽火通用底座 libsecurityfunc(64bin 依赖) libfhlogmgr(56) libwolfssl(53)
                libfhcrypto_new(51) libfhcfg(50) libfhubus(50)
                libfhapi(47)→libfhdev(405f) libfhapiadapter/libfhnoti/libfhsysmgr(49)
L2 硬件驱动 API libfhdrv_kdrv_board(145f)+impl libfhdrv_pon_api(207f)
                libfhdrv_net_api(413f) libled_interface/libLedState
L3 功能域       WiFi×3 层 Mesh libmap×6 组播×7 KaaS×3 TR069×2 语音 IPsec
第三方双栈      OpenSSL 1.1(libcrypto 4381f) + wolfSSL 35.3(2513f)
```

fhrom 之外另有 usr/lib 的 Quectel SDK 层：libqlril(133K, ql_nw_* 55+/ql_sim_* 28/ql_sms_* 16/ql_dm_* 9), libqlnet(199K, ql_data_call_* 25 + qlu_* 70), libql_at(ql_atcid_sender_*), libql_atcmd(~60 个 AP 本地 AT 处理器), libql_mipc(submonitor 订阅), libql_lpa(eSIM), libql_slic/audio 等 15 库。

## 4. Modem/MIPC 栈（控制面全链）

```
[功能层]  mobilenetwork (cfg 树 X_FH_MobileNetwork.* 翻译器, ubus mobile_network 35 方法)
             ├─ AT 面: popen mipc_wan_cli --at_cmd → libql_at → atcid → MIPC
             └─ 原生面: libqlril/libqlnet → ubus ril / ql-netd → ql_ril_service/ql_netd → MIPC
[CLI 面]  mipc_wan_cli(~50 子命令) / ql_datacall — 自带 libmipc_msg 直连
[消息层]  libmipc_msg.so (95 导出: mipc_msg_* TLV 编解码 + ttyCMIPC 串口原语 + OSAL)
[内核]    /dev/ttyCMIPC0..14 → ccci 栈(内建) + mtk_pcie_smt.ko → T830 modem
[数据面]  ccmni0..2 直连 ccci DPMAIF — 不经任何控制进程
[旁路]    mtk_netagent(ccmni IP/路由执行者) mipc_submonitor(全 IND→ubus 16 主题)
          thermal_core(ttyCMIPC9 独占温控)
```

功能归属表（完整版含上层消费者见 C 报告）：

| 功能 | 执行者 | 通道 |
|---|---|---|
| 拨号(PDN) | mobilenetwork→ql_netd | MIPC TLV (ubus ql-netd datacall) |
| SIM/PIN | ql_ril_service | MIPC TLV (ubus ril ril_request) |
| 信号上报 | ql_ril_service→ril.unsol.nw.signal | MIPC IND→ubus notify |
| 制式切换 | mobilenetwork | **AT+erat=n** |
| **组网模式(SA/NSA/双)** | mobilenetwork fh_set_endc | **libqlril ql_nw_set_nr_disable_mode（纯 MIPC 无 AT；3=SA/5=NSA/7=双，非 7 值先 restore 7）** |
| 漫游开关 | mobilenetwork | **AT+ECNCFG=1,{0\|1},0,0,0,0**（data_en/roam_en —— 与 ENDC 无关，勿混淆） |
| 组网选项 AT 镜像 | （modem 内部 l5ath→SET_CACHE_ENDC_CONNECT_MODE） | **AT+E5GOPT=n**（值域同上 3/5/7；缓存型，写回需重附生效） |
| 飞行模式 | mobilenetwork ql_dm_set_air_plane_mode | MIPC + AT+CFUN 恢复链 |
| **锁频段** | mobilenetwork fh_process_lock_band | **libqlril ql_nw_set_band_mode（纯 MIPC，无 AT）** |
| 锁小区 | mobilenetwork | **AT+EMMCHLCK**（另有 ql_nw_set_cell_arfcn_lock 原生路）|
| PLMN 扫描 | ql_ril_service | MIPC (ql_nw_network_scan) |
| 短信收/发 | ql_ril_service | MIPC (ril.unsol.sms.pdu / ql_sms_send_*) |
| 流量统计 | mobilenetwork 自身 | /proc/net/dev 轮询（非 modem 数据）|
| IMEI | mipc_wan_cli --get_imei / AT+cgsn | MIPC/AT |
| 温度 | mobilenetwork + thermal_core | sysfs thermal_zone9/10 + ttyCMIPC9 |

## 5. 内核层（19 个 fhrom .ko + 169 个 OpenWrt 模块）

fhdrv 家族（载入链 = common_init → pon_init → net_init）：

| 模块 | 功能 | 用户态 API |
|---|---|---|
| kdrv_board(+impl+impl2) | 板级框架：GPIO/LED/看门狗/CPLD/NVRAM/分区/解密 ioctl 汇聚，fh_hw_cfg 配置字 | libfhdrv_kdrv_board(54f) |
| net_dev | 网络族 ioctl 框架（子模块处理器挂载点）| libfhdrv_net_api(104f) |
| net_quecadp | **多 WAN 分流引擎**：conntrack 首包 jhash%100<weight 打 mark，MAC 绑定表，每用户限速 | fhad_net_set_multiwan_* |
| net_forward/fdb/flow/ondemand/userlimit | 二三层转发策略/FDB 学习上报/ACL-QoS 流分类/按需拨号统计/终端数限制 | 同上 |
| pon_dev/service/eth_hook/pon_drv/eth_drv | PON 族（LG6151M 无 PON 硬件，多半空转）| libfhdrv_pon_api(95f) |
| map_filter | EasyMesh 1905 过滤器（**依赖缺失，本版不可载**；OpenWrt mapfilter.ko 承接）| — |
| roaming_accel | 漫游加速（内核注入免费 ARP）| wifimgr 运行期 insmod |
| fh_kcrypto | 配置加解密内核加速（AES/sha256，wifi 敏感配置）| 内核 API 直调 |
| xt_webstr | iptables URL 字符串匹配扩展 | iptables -m webstr |

WiFi 实际生效链（modules.d，非 fhrom BE5000 脚本——后者是多平台遗留参数）：
`conninfra→wifi_md_coex→cfg80211→mt_wifi_cmn→mtk_warp→mt_wifi→mtk_hwifi→connac_if/mtk_pci→mt7992(option_type=3 rro_mode=0)→mtk_wed→hw_nat`
dat 机制：l1profile → mt7992.5040.1.dat（BN0/BN1 → /var/wlan/apcfg(_5)，E2pAccessMode=4，WHNAT=1）。MAC 派生 brmac(+1/+8)。带宽语义坑：dat 的 `VHT_BW`(0=20/40,1=80,2=160) 与 `EHT_ApBw`(0=20,1=20/40,2=80,3=160) 档位错位、驱动取 min —— 160MHz 必须双字段齐设(2+3)，只设其一会被钳 80（2026-10-05 实测：双设后 160MHz 生效，WiFi7 客户端 2402/2882 Mbps PHY）。

lib/modules 169 模块聚类：iptables 36/nft 23/ebtables 21/netfilter 19/ipset 17/**MTK WiFi 平台 16**/tc 8/crypto 6/sound 6/杂项 17（air_en8811h 2.5G PHY、gps_drv 等）。

## 6. 控制面入口矩阵（对外暴露面）

| # | 入口 | 守护 | 鉴权 | 裁撤影响 |
|---|---|---|---|---|
| 1 | :80/:443 `/fh_api/*/FHAPIS` | nginx→webs | 登录 sessionid + AES | Web 管理全失能 |
| 2 | FHNCAPIS(is_encrypt) | nginx→webs | 免登录 RSA token | 登录前置链断 |
| 3 | FHTOOLAPIS / fh_tool | nginx→webs | fhtool_sessionid | 维护工具面断 |
| 4 | FHUPAPIS | nginx→webs | 登录+upgrade token | FOTA/上传断 |
| 5 | cgi-bin×4 | nginx→webs | plusdebug 需超管 | 调试面断 |
| 6 | :8443 /fh_app（默认不加载）| nginx→webs | app_do_login | App HTTPS 备用 |
| 7 | 127.0.0.1:8841 内部 API | nginx Lua | 仅本机 | 进程间查询断 |
| 8 | :18998/:18996 NDMP | iotagtd | 云绑定 MAC 门控 | App 本地模式断 |
| 9 | Kaa 云通道 | iotagtd | RSA 密钥对 | 云管理/遥测断 |
| 10 | :5683 CoAP | filink | 本地网络 | App 组网发现断 |
| 11 | TR-069 + :30005 | tr069 | ConnReq 口令/证书 | ACS 远程管理断 |
| 12 | :23 telnet（按需，固定 MAC 触发）| telnetd_multicall | 白名单+沙箱口令 | 工程调试通道 |
| 13 | :22 SSH | （原厂未启用）| — | — |
| 14 | USB ADB（AT+QADBCTL 门控）| adbd_usb | AdbAtEnable(默认0) | 调试通道 |
| 15 | 串口 console | busybox init | uart_conf 文件门（默认无=封死）| 工厂/调试 |
| 16 | SSDP:1900 UPnP IGD | upnpd | 无 | 端口映射面 |
| 17 | :53 DNS | dnsmasq | 无 | LAN 服务 |

cfg 树一级 24 分支（活树实查）：DeviceInfo/ManagementServer(Time/TR069)/LANDevice(WLAN/Hosts/DHCP)/WANDevice/X_FH_MobileNetwork(21 子对象)/X_FH_FiLink/X_FH_FireWall/X_FH_{IPSec,L2TP,PPTP}VPN/X_FH_PERIPHERAL/X_FH_PORT_MIRROR/Diagnostics×5/Services.VoiceService(裁撤候选) 等。FH 主数据面不走 uci（29 个 uci 文件仅承载 OpenWrt 平台层；wireless uci 不存在，WiFi 全在 cfg 树+apcfg dat）。

## 7. 死代码 / 工厂残留清单

- temprotection（零引用）、ping_detection（零静态引用）、libpcap/libjson/libgmp（无直接消费者）
- iptables-restore→iptables-save 二级符号链（打包怪癖）
- iotagtd 内嵌开发期 KaaS bootstrap URL（厂商内网）
- fhshell 120 个脚本中：产测残留 12 + 性能测试残留 5 + 调试残留 8 + 访问面 4
- slt2_test（3 实例产测）、meta_tst、mdlogger 常驻
- mn_resolve 链接 2021 旧版 libubox/libubus（版本偏斜共存）
- 工厂域整层（load_cli/dev_mgm_debug/kdrv_debug/fac_*）仅 factorymodeflag 激活
- RP0102→RP0103 init 层零结构差异（仅 rcS +4 行：ccmni 9991 MARK + eth_mac_monitor）

## 8. 对本项目的历史修正记录

| 旧认知（FINDINGS/早期）| 修正后 |
|---|---|
| fhdrv_net_dev ioctl ENOTTY 是"加载顺序问题" | 整条 fhdrv 链在自定义启动下从未加载；复活需按完整链 common_init→pon→net |
| 原厂 nginx :8080 | 原厂=80/443；:8080 是 v4 复活层自足 conf |
| netifd ql_datacall proto 负责拨号 | proto 脚本未落地；真拨号者=ql_netd+mobilenetwork |
| 原厂启动走 OpenWrt procd rcS | procd 只管 56 个 rc.d；FH 层由 S99zmtk 末行触发自研 rcS+sysmgr |
| 锁频段可能存在 AT 面 | 无；唯一路 = libqlril ql_nw_set_band_mode (MIPC) |
| cfgmgr 守护 = 树的必要条件 | 否：shm 由 cfg_tool 建立，cfg_cmd/libfhcfg 直操作共享内存，守护可裁（P3-lite 实证） <!--CLM:CLM-TREE-DAEMONLESS--> |

## 9. 原始报告索引

完整明细（含逐二进制 NEEDED 表/全部 ioctl API 95+104+54 函数名/mipc_wan_cli 50 子命令/libmipc 95 符号/81 项 init.d 全表）存于内部工作区 `_re/reports/{A_boot,B_daemons,C_modem,D_kernel,E_web}.md`（不入公开库）；本文为公开浓缩版。
