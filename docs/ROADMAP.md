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

> 2026-10-06 补录：P0 期间发现并修复首刷锁死 bug（payload 不带 gui_auth.conf，纯原厂
> 直刷后任何口令都无法登录 GUI —— 回归未覆盖"无 /data 残留"场景）。login 现自举文档化
> 默认口令并标记 default，GUI 强制改密；SSH(22) 亦入 WAN 封禁链。 <!--CLM:CLM-FIRSTBOOT-AUTH-->
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

### P2 拨号自持（必做 —— 闸门 A 已判 FAIL；**2026-10-06 验收通过**） <!--CLM:CLM-DIALKEEPER-->

> dial_keeper v1.0 兜底拨号器验收：冷拨 35s 接管（deact_apn+act_type 配方 result:0，
> netagent 自动配置新口）· mobilenetwork 死亡状态下 8 分钟稳定+流量 · 飞行循环
> （CFUN4 拨号失败→退避→CFUN1 恢复后 DIAL OK 54s）· 附带发现：**呼叫所有权随
> deact/act 转移** —— keeper 建立的呼叫不再随 mobilenetwork 退出而拆除（其 TERM
> 清理只及自身呼叫），P3 下架的安全边际比预期更大。
自研 dial keeper：`mipc_wan_cli --data_call_act`（APN 来自 `--apn_provision_by_sim`）+
watchdog 集成（ccmni 无 IP→重拨）。出口：拔 SIM 重插自恢复 + 10 分钟流量观测。

### P3 下架（**2026-10-06 完整收官** — P3-lite → 终章） <!--CLM:CLM-P3-FINALE-->

> **终章（同日）**：CA 小区列表替代落地 —— D 组逆向 + cellraw 实测修正（16 小区真源
> = ql_nw_get_cell_info，cells@0x520 stride 0x30，arfcn+0/rsrp+8/sinr+0xC/pci+0x2C；
> D 组的 0x528 差 8B 由原始 dump 对树值定案），mipc_cellular v0.5 `cells` 实弹全对
> （服务 N41/504990/341 + 16 邻区与树 PCI 序一致、RSRP/SINR 实时）。rc_netfh v3.1
> 上机：cfg_tool/shmsnap/mobilenetwork 全退役（KEEP_TREE=1 回滚门控），两次冷启动
> 回归 55/55（守护 0、16MB shm 0、keeper 开机 35s 拨号）。**原厂应用层彻底清零**：
> 存活的 FH 组件只剩二进制库（hostapd/dnsmasq/radvd）与 modem 底座军。

### P3-lite（中间形态，2026-10-06 晨） <!--CLM:CLM-P3LITE-->

> 实证简化：树操作不依赖 cfgmgr 守护（kill 后 get/set 全通，shm 由 cfg_tool
> 建立）→ 低风险先裁守护。rc_netfh v3.0：cfgmgr+logmgr 不再拉起，cfg_tool 的
> shm 构建/快照恢复保留，mobilenetwork（树翻译层）保留。三次冷启动回归全绿
> （54/54 ×3，守护 0 在位，树通，PDN/keeper/mobilenetwork 齐）。
> 信号面同步去树化优先（api.sh v2.24+：mipc RSRP + AT PLMN/RAT 直读，树回退
> —— 顺带修正了树里陈旧的 PLMN 显示）。
> > **2026-10-06 晚更新：mobilenetwork 已无强制消费者** —— PLMN 扫描（ql_nw_network_scan
> 原生集成，GUI 实测 8 网络真名渲染）✅ · PIN 管理 AT 引擎 ✅ · get_sim AT 直读 ✅ ·
> get_traffic sysfs 直读 ✅。**下架仅剩一项前置**：CA 小区列表展示（树的
> RadioSignalParameter 由 mobilenetwork 回填；替代 = ql_nw_get_band_info 响应
> 逆向 —— 复合结构，需一轮专注解析），之后 kill 实验 + rc_netfh v3.1 + 重启回归。
> 信号推送评估：真推送需 v3httpd 增加 SSE 端点（C 二进制改动），暂缓。
> <!--CLM:CLM-PLMN-SCAN--> <!--CLM:CLM-PIN-SIM-AT-->
>
> **2026-10-06 下午更新：控制面 P3.5 三项已全部完成** —— erat 映射（A 组
> 指令级实证五项表）✅ · 小区锁 AT 直发（EMMCHLCK，锁/解实弹）✅ · SMS 发送
> （B 组结构逆向 + 实弹 ret=0）✅。mobilenetwork 现仅剩：PLMN 扫描触发（ubus，
> 待 C 组 ql_nw_network_scan）、PIN 管理（ubus）、树信号回填（展示回退）。
> 下架它只差这三个替代面。 <!--CLM:CLM-ERAT-MAP--> <!--CLM:CLM-SMS-SEND--> <!--CLM:CLM-CELLLOCK-AT-->
- 裁去 cfg_tool/cfgmgr/logmgr/mobilenetwork + shmsnap 恢复段；MODE.fh 语义收窄为"modem 最小军"。
- selftest：删 t_cel_tree，增引擎模式断言；watchdog 不变量复核。
- **出口判据**：全量回归绿 + 开机时序对比记录（before/after）+ 冷启动三次稳定。

### P4 功能补全（**部分完成 2026-10-06**）

> - PLMN 扫描直读：**受阻** — AT+COPS=? 长响应撑爆 mipc_wan_cli 固定缓冲
>   （段错误，与 AT+CLAC 同类）；正确路径 = mipc_cellular 逆向
>   ql_nw_network_scan。已回退 ubus 过渡实现。
> - SMS 发送：**签名已定**（ql_sms_send_msg 单结构体指针，NULL 检查在
>   0x146d0），字段映射留待专攻轮（错结构有真实发信风险，不无人值守赌）。
- **SMS 发送**：ubus `mobile_network add_send_sms`（若 mobilenetwork 还活着）或 ql_sms 原生
  —— MIPC 通道非 AT CMGS，**无承载毒性**，旧禁令仅针对 AT 面。
- 信号推送：订阅 `ril.unsol.nw.signal`，状态页从轮询升级实时。
- PLMN 扫描结果展示（扫描后树读/原生查询）。

### P4 功能补全（**全部完成 2026-10-06 深夜** — SSE 信号推送收尾） <!--CLM:CLM-P4-SSE-->

> 终项：v3httpd v2.4 流式 CGI 通道（GET /api/sse, 头先行+管道增量转发+600s寿命/80s空闲
> 双超时）+ api.sh v2.44 sse 端点（mipc_cellular cells 服务小区信号 3s 事件流, 570s
> 自退双保险）+ app.js v3.27 EventSource 实时刷新蜂窝卡（轮询保留兜底）。curl 实测
> 事件流即通, selftest 58 项含 SSE 断言。P4 四项（SMS/PLMN/PIN/SSE）全数落地。

### P5 深水区（**关闭 2026-10-06** — 无需启动） <!--CLM:CLM-P5-CLOSED-->

> 关闭判定（实测）：并发多流传输期间设备 CPU 基本空转(top 实证) — 瓶颈在上游链路
> 本身（当晚双上行均 <1Mbps, 传输中 CPU<2%），iptables mark+NAT 引擎开销远低于
> 平台转发能力余量；quecadp 复活需完整 fhdrv 加载链(net_quecadp+ioctl 库+multiwan
> 重构) = 高风险面换零已证需求。判定：保持 iptables 引擎，P5 永久关闭；仅当未来
> 上游升级到 >500Mbps 且 CPU 画像显示 softirq 饱和时重开。

## 4. 护栏绑定（制度化）

- 断言先行：每阶段的 selftest 断言与功能同批落地，deploy push 自动执行。
- 结论入账：阶段结论以 CLM-* 入台账；本路线图的关键假设 CLM-DIALER-QLNETD（assumed）
  在闸门 A 后 `doc_audit.py refresh` 定案。
- 审计闸门：doc_audit 违规（STALE-CODE/未登记断言）阻断一切 push/put/snapshot。
