# 原厂内容替换路线图 v2（基于两轮侦测重构）

> 2026-10-05 重构。上一版路线图（"第二阶段=替换 cfgmgr 锁定后裁撤 cfgmgr/mobilenetwork"）建立在
> 三个已被五路逆向推翻/修正的假设上：拨号者认知错误、锁频段通道未明、fhdrv 引擎根因未明。
> 本版以 VENDOR_MAP.md（原厂全量地图）+ L13-L16 测试/审计制度为依据重排。
> 原则：**每阶段有闸门实验与出口判据，断言先行，结论入台账**。

---

## 1. 现状快照（2026-10-05 实测）

v4 当前存活的原厂组件（ps 实查）：ccci 三件套 · mtk_netagent · ql_netd · ql_ril_service ·
mipc_submonitor · atcid/atci_service · thermal_core · cfgmgr · mobilenetwork · radvd/dnsmasq/hostapd
（原厂二进制+自配置）。**logmgr 已死多周无人察觉且系统正常** <!--CLM:CLM-LOGMGR-DEAD--> ——
这本身就是"应跑清单必须在测试里显式声明"的证据（watchdog v1.2 已补蜂窝面，logmgr 本就无消费者）。

内存账（实测 RSS）：九个目标守护合计约 20MB + cfg 树 16MB shm 段（size 声明值）。
**下架的真实收益是复杂度与启动链缩短，不是内存** —— 2GB 设备余量充足，别为省内存冒险。

## 2. 判决表

### 2.1 保留（load-bearing，不动）

| 组件 | 作用 | 不可替代理由 |
|---|---|---|
| ccci 三件套(fsd/mdinit/rpcd_com) | modem 引导/文件系统/RPC | modem 生命线，nice -20 先于一切 |
| mtk_netagent | MIPC 网络事件→netlink/ioctl 落到 ccmni | 无它 IP/路由不落地；另含 FCC/IC 降功率联动 |
| ql_netd + ql_ril_service | MIPC 拨号/RIL 服务端（ubus ql-netd/ril） | 自研引擎的地基，必须服务在才有 MIPC 会话 |
| mipc_submonitor | 全量 MIPC IND→ubus 16 主题分发 | 事件总线；P4 信号推送的载体 |
| atcid（+atci_service） | AT 通道本体 | --at_cmd 唯一路径；watchdog v1.2 已自愈 |
| thermal_core | AP/modem 温控（ttyCMIPC9 独占） | 温感/执行器联动，动了会失去 modem 过热保护 |
| hostapd / dnsmasq / radvd | 原厂二进制 + 自配置 | hostapd 只吃 PMK（已实证）；替换无收益 |
| scd / packet_steering / cron / 内核 WiFi 链 | 平台基础 | 时钟同步/RPS/定时；modules.d 体系已理顺 |

### 2.2 替换（有明确通道，按此优先级）

| 原厂链 | 替换为 | 通道（已实证） |
|---|---|---|
| 锁频段：cfg树→mobilenetwork | `mipc_bandlock` 自研工具 | dlopen libqlril `ql_nw_set_band_mode`（位图）；回读 `ql_nw_get_band_info` |
| 锁小区/制式 | api.sh AT 直发 | `AT+EMMCHLCK` / `AT+erat`（经 atcid） |
| 飞行模式 | ql_datacall 一条龙 | `--set_air_plane_mode`（MIPC，不占 AT 会话） |
| 信号/SIM 信息面 | 直查 | `--nw_get_signal`(RSRP) + AT(CPIN/COPS/CGSN/CCID)；无需树 |
| 流量统计 | 自轮询 | /proc/net/dev（mobilenetwork 同源做法） |
| 锁定持久化 | 自管 conf 开机重放 | cellular.conf → 新引擎直发；废弃 shmsnap 快照 |

### 2.3 下架（2.2 完成后整批）

mobilenetwork · cfgmgr+cfg_tool（16MB shm）· shmsnap 链 · logmgr（已死）。
**互锁警告：cfgmgr↔mobilenetwork 经 libfhcfg 进程内耦合，必须同批下架，不可单拆。**

### 2.4 明确不再追

quecadp 内核引擎（iptables 拆分已验证够用；完整加载链已存 VENDOR_MAP §5 备查，降级为 P5 台架实验）·
EasyMesh/VPN 三族/UPnP/DDNS/VoIP/fhdrv_net_forward 端口隔离（FEATURE_MATRIX 放弃清单，理由不变）。

## 3. 阶段计划

### P0 纵深与卫生（半天）
- WAN 面显式封禁：1899x/30005/5683/23 进 fw_apply 常备规则（守护虽不跑，纵深不靠假设）。
- 凭据卫生：`_local/secrets` 的 GW_PASS 与设备同步（当前 stale，3 个 GUI 测试走 skip）。
- lppe_service（低功耗定位，无 GNSS 消费者）纳入下次裁剪批次评估。

### P1 蜂窝自研引擎（1-2 会话）——原"第二阶段"重构版
**闸门实验 A（第一件事，分叉点）**：杀 mobilenetwork → 观察 ccmni 存活 10 分钟 +
流量正常 → 结论写回台账（CLM-DIALER-QLNETD 由 assumed 转 verified/翻案）。
- A 通过 → 直接进 P3（mobilenetwork 非承重，ql_netd 独立维持 PDN）。
- A 失败 → 先做 P2。

> **闸门 A 已执行（2026-10-05）：FAIL** —— 杀 mobilenetwork 后 ccmni IP ≤10s 消失；
> 裸重启不够（缺完整 PATH/LD_LIBRARY_PATH 时启动即退）；恢复 = 全环境重拉。
> **P2 由条件项转为必做**。详见 VENDOR_MAP §0.3 与台账 CLM-DIALER-QLNETD。
- `mipc_bandlock`：zig cc 动态 musl 二进制，set/get 双模式，绑 selftest。
  - **v0.1 已落地（2026-10-05）**：`mipc_cellular` getbands 实证 ret=0（自研进程→libqlril→ubus ril→MIPC→modem 全链），
    setbands 已达 modem 栈（参数域拒绝=零位图非法，零服务影响）；168B 结构语义映射 = P1 续。 <!--CLM:CLM-MIPCTOOL-->
- api.sh 蜂窝域重写：`engine=tree|mipc` 特性开关平滑迁移（GUI 无感）。
- cellular_replay v2：ql_ril_service 就绪门控 + 新引擎重放。
- selftest 翻转：锁一致性断言从 conf=树=模组 改 conf=模组（双层）。
- **出口判据**：selftest 全绿 + GUI 锁频段实操（锁→查→解）+ 重启持久 + 手机在线不掉线。

### P2 拨号自持（必做 —— 闸门 A 已判 FAIL）
自研 dial keeper：`mipc_wan_cli --data_call_act`（APN 来自 `--apn_provision_by_sim`）+
watchdog 集成（ccmni 无 IP→重拨）。出口：拔 SIM 重插自恢复 + 10 分钟流量观测。

### P3 下架与开机链简化（rc_netfh v3）
- 裁去 cfg_tool/cfgmgr/logmgr/mobilenetwork + shmsnap 恢复段；MODE.fh 语义收窄为"modem 最小军"。
- selftest：删 t_cel_tree，增引擎模式断言；watchdog 不变量复核。
- **出口判据**：全量回归绿 + 开机时序对比记录（before/after）+ 冷启动三次稳定。

### P4 功能补全（价值项，顺序自由）
- **SMS 发送**：ubus `mobile_network add_send_sms`（若 mobilenetwork 还活着）或 ql_sms 原生
  —— MIPC 通道非 AT CMGS，**无承载毒性**，旧禁令仅针对 AT 面。
- 信号推送：订阅 `ril.unsol.nw.signal`，状态页从轮询升级实时。
- PLMN 扫描结果展示（扫描后树读/原生查询）。

### P5 深水区（可选、低优先、台架先行）
quecadp 复活实验（完整 fhdrv 加载链，VENDOR_MAP §5 顺序表）——仅当 iptables 拆分在实际
负载下暴露瓶颈才启动。

## 4. 护栏绑定（制度化）

- 断言先行：每阶段的 selftest 断言与功能同批落地，deploy push 自动执行。
- 结论入账：阶段结论以 CLM-* 入台账；本路线图的关键假设 CLM-DIALER-QLNETD（assumed）
  在闸门 A 后 `doc_audit.py refresh` 定案。
- 审计闸门：doc_audit 违规（STALE-CODE/未登记断言）阻断一切 push/put/snapshot。
