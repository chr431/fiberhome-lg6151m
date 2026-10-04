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
- bootctrl：misc 分区偏移 **2060**（magic BCAB 区），LK 按 priority 选槽；up=02 标志仅用户态消费
- **zmtk_boot_done 首启克隆槽**（厂商双槽一致设计）→ v3+ 必须注释，否则自定义槽被原厂覆盖
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
| hostapd（原厂构建） | WPA 安全层 | wifi_up.sh；**只吃 wpa_psk 原始 PMK**（wpa_passphrase 被 libfhcrypto 拦截） |

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
- **160MHz 未解锁**：配置链全通（dat VHT_BW=2/EHT_BW=2 + hostapd he_oper_chwidth=2），
  但 hwifi 架构驱动拥有射频权，持续 CSA 钳回 80MHz（wifimgr 逆向进行中）
- 本机 BSS 不被自家 apcli 扫描报告 → 分析仪合成绘制本机标记

## 7. 双上行聚合（wan_agg v2.11）

- v4：原厂 quecadp 引擎（jhash%100 < pct），ioctl 控制，权重热调
- v6：模块哈希常数缺陷 → 低 8 位 iptables 引擎（0x65/0x66）+ CONNMARK 粘性
- MARK 是覆盖非 OR：全部规则带 mark==0 守卫（曾致 catchall 覆盖钉死规则）
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
