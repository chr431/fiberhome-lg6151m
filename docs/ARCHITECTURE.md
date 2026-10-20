# 架构与版本总表

> 版本表由 `python tools/vercheck.py render` 从 `tools/VERSIONS.tsv` 生成（标记块内勿手改）。

## 系统形态（v4）

**底座**：原厂 RP0103 squashfs（slot B 永远保留原厂镜像作回滚底线）；slot A =
同底座 + 飞行层（toor 账户、dropbear、S98 数据钩子、babysitter）。
**运行层**：`/data/gw/*`（本仓库 `gw/` 目录部署而来），由 `/data/rc.extend.sh`
按槽位调度拉起。

## 组件关系

```
rc.extend.sh (槽位调度)
 ├─ rc19.sh ── br-lan + wifi_up.sh(mt7992 AP) + wan_agg.sh(双上行聚合)
 │             + led_mgr/fan_mgr/ntp_keeper + v3httpd(GUI :80)
 ├─ rc_netfh.sh ─ FH modem 栈路线(MODE.fh 门控) + radvd + fw_apply
 └─ uplink.conf(ENABLE=1 时拉起 AUTHD_CMD —— 可插拔上行认证,任意程序)

v3httpd ── 静态 /data/gw/www + /api/* → api.sh(35+ JSON 端点)
 app.js ── SPA; 启动时尝试加载可选 /plugins.js → LG_plugin() 动态注册
           插件页(GUI 扩展不进固件本体)
```

## 部署与版本纪律

- `tools/deploy.py`：MANIFEST 唯一部署事实源；`push`(带 #DEPLOY 溯源戳) /
  `put`(任意文件, 原子 mv + md5 双校验) / `doctor`(漂移体检) / `snapshot`。
- `tools/VERSIONS.tsv`：唯一版本事实源；改动必 bump + commit；
  `python tools/vercheck.py check` 全绿才允许任何部署操作。
- `tools/leak_check.py`：敏感词零命中门禁（建议 pre-push 跑 `--history`）。
- `docs/GUI_TERMINOLOGY.md`：GUI 用户可见文案的唯一用词基准（常设）。
  修改 `gw/www/` 任何界面文案前先查该表；引入新概念先在表中补行再写代码。
  整改历史见 `docs/GUI_COPY_AUDIT.md`。

## 版本总表

<!--VERCHECK:BEGIN (generated from tools/VERSIONS.tsv; edit THERE, then `vercheck.py render`)-->
| 文件 | 版本 | 类别 | 设备路径 | 用途 |
|---|---|---|---|---|
| `README.md` | **v1.1** | doc | `-` | 仓库总览与快速上手 |
| `docs/ARCHITECTURE.md` | **v1.1** | doc | `-` | 架构+版本总表(本表生成; v1.1: 增GUI术语规范常设指针) |
| `docs/GUI_TERMINOLOGY.md` | **v1.2** | doc | `-` | GUI文案基准; v1.2: bad_cmd文案更新+sse_busy码; 历史见git |
| `gw/agg_pins.default` | **v1.0** | manifest | `/data/gw/agg_pins.default` | MAC钉死表出厂缺省基线(只读, 不含任何MAC; 设备侧活文件 agg_pins.conf 由 wan_agg 缺省才写地播种, 个人MAC不入库) |
| `gw/bin/busybox` | **v1.0** | manifest | `/data/gw/bin/busybox` | 静态 aarch64 busybox 1.36.1(Alpine busybox-static 1.36.1-r31, 与厂商同版本); P2 崩溃家族工具链静态化 |
| `gw/bin/fhstub.so` | **v1.0** | manifest | `/data/gw/fhstub.so` | FH符号桩库(顶掉vendor api库的生态依赖,仅ioctl路径) |
| `gw/bin/healthdog.ko` | **v1.0** | manifest | `/data/gw/healthdog.ko` | 取证看门狗内核模块(forensic=1) |
| `gw/bin/ip` | **v1.0** | manifest | `/data/gw/bin/ip` | 静态 aarch64 iproute2 6.3.0(与厂商 ip -V 同版本, zig cc musl 重建); 输出与厂商逐字节一致, 保留 link add type bridge |
| `gw/bin/logc` | **v1.2** | manifest | `/data/gw/bin/logc` | 静态日志采集器; v1.2(P1-2): 信号面包屑(/tmp/logc.crash: 帧偏移/长度)+--dump-raw 原始流+--selftest+ubus 缓冲移出栈+stack-protector; v1.1(batch1): socket/oneshot 超时; 历史见git |
| `gw/bin/mipc_cellular` | **v0.17** | manifest | `/data/gw/mipc_cellular` | 蜂窝MIPC直连CLI; v0.17: 日志 primary/last 传输分开(plen/prc/pms+lrlen/lrc/lms); v0.16: cells tag 双变体 0x810b/0x010b(19邻区用 0x010b); 解码失败原始载荷落盘 |
| `gw/bin/multiwan_ctl` | **v1.1** | manifest | `/data/gw/multiwan_ctl` | 原厂multiwan引擎ioctl控制器(zig动态链libfhdrv_net_api,36B结构体) |
| `gw/bin/shmsnap` | **v1.0** | manifest | `/data/gw/shmsnap` | cfgmgr树共享内存快照工具(save/load 16MB原始字节, gzip后127KB, 开机恢复锁定状态) |
| `gw/bin/v3_fix.ko` | **v1.2** | manifest | `/data/gw/v3_fix.ko` | TTL伪装/PPE解绑内核模块(wan_if/ttl_mode/unhook); v1.2(24h 日志轮): 重建产物 — 旧文件 ELF 节表错位 1B 致每次开机 insmod 静默失败(type 768), 实测 rc=0/TTL/RX 解绑在位 |
| `gw/bin/v3_steth.ko` | **v1.0** | manifest | `/data/gw/v3_steth.ko` | hook槽位听诊器(bias/interval) |
| `gw/bin/v3httpd` | **v2.6** | manifest | `/data/gw/v3httpd` | 网关GUI HTTP服务; v2.6(P2): 静态面拒*.sh(免认证源码泄露)+Host头校验(根治DNS rebinding) |
| `gw/bin/wpapmk` | **v1.0** | manifest | `/data/gw/wpapmk` | WPA口令转PMK(纯C PBKDF2-SHA1; fh魔改hostapd只吃wpa_psk) |
| `gw/boot_gate.sh` | **v1.1** | manifest | `/data/gw/boot_gate.sh` | 启动健康门禁(P0-2); v1.1: GUI 判据加 HTTP 200; v1.0: 关键链实测通过才写 boot.done, 全通过写 boot.healthy 并清 TRY_A(读回校验), 10min 稳定窗, --check |
| `gw/capture_ubus.sh` | **v1.1** | manifest | `/data/gw/capture_ubus.sh` | stock拨号一次性捕获(ubus monitor+ccmni采样) |
| `gw/ccmni_up.sh` | **v1.1** | manifest | `/data/gw/ccmni_up.sh` | netagent-lite: MIPC 拨号+ccmni 落地(deact+act→解析→flush+add+mtu); v1.1(日志加密轮): 入口旧地址/deact/act rc+耗时/响应/flush/add rc/总耗时全程留痕; 不写路由/NAT |
| `gw/cellular_replay.sh` | **v2.1** | manifest | `/data/gw/cellular_replay.sh` | 蜂窝锁定开机重放(频段/小区锁到cfgmgr树, 树每次开机由出厂档案重建) |
| `gw/consfeed.sh` | **v1.0** | manifest | `/data/gw/consfeed.sh` | v2 控制台喂食器(无setsid,v2_access拉起) |
| `gw/core_meta.sh` | **v1.0** | manifest | `/data/gw/core_meta.sh` | core_pattern 元数据 wrapper(P1-2/P1-5): 记录 exe/cmdline/status/maps/父进程/PATH/dmesg 尾后 exec aee forwarder(行为不变, stdin 不碰) |
| `gw/core_trap.sh` | **v1.1** | manifest | `/data/gw/core_trap.sh` | 每日 core 捕获窗口(P3); v1.1(stability P1-5): restore 目标改 core_meta wrapper + 启动校验 + 心跳 + 全局配额(60 个/200MB, quota.tsv) |
| `gw/defaults.conf` | **v1.8** | manifest | `/data/gw/defaults.conf` | 统一配置只读出厂基线(444); 消费方source叠加settings.conf稀疏覆盖; v1.8: -ETH_CURFEW(先验时段下架); v1.6: +TZ(时区入自管配置) |
| `gw/diag_dump.sh` | **v1.2** | manifest | `/data/gw/diag_dump.sh` | 一键诊断包(脱敏); v1.2(SIGSEGV P1/P2): 环读取改静态 logc + 静态工具链自述; v1.1: 结束行带生成时刻 |
| `gw/dial_5g.sh` | **v1.6** | manifest | `/data/gw/dial_5g.sh` | 生产 5G 拨号器; v1.6: ubus 冷启动引导不再拉起 ql_ril_service(已退役); 历史见git |
| `gw/dial_keeper.sh` | **v1.8** | manifest | `/data/gw/dial_keeper.sh` | v1.8: 锁排除自身 pid(spawn 预写锁); v1.7: 单实例锁判据收紧(绝对路径+非僵尸); 拨号自持守护; v1.5(日志加密轮): 60s TICK(has_ip/cell_alive/wan_alive 原文+年龄/down/backoff/APN/cci)+僵尸IP边沿+modem未就绪原因+飞行切换+ccmni_up rc/输出/耗时; v1.4: ccmni_up 一体+数据面触发+飞行守卫; v1.6(日志加密轮补): 日志行补 epoch 时间基准(跨日志关联) |
| `gw/dial_variant.sh` | **v1.3** | manifest | `/data/gw/dial_variant.sh` | 5G 拨号参数变体实验器; v1.3: ubus 引导同步去除 ql_ril_service |
| `gw/fan_mgr.sh` | **v1.5** | manifest | `/data/gw/fan_mgr.sh` | 原厂梯度温控风扇; v1.5(P1-1): 单实例锁; v1.4: 心跳; 历史见git |
| `gw/fan_mode.conf` | **v1.0** | manifest | `/data/gw/fan_mode.conf` | 风扇模式:performance|silent(静音+6°C偏移) |
| `gw/fw_apply.sh` | **v1.5** | manifest | `/data/gw/fw_apply.sh` | 端口映射/DMZ/禁网安装器(rc_netfh开机+api共用); v1.5(P1): v4 WAN面default-deny(icmp/DHCP客户端/established放行其余DROP, 含旧7端口黑名单语义)+V4WANGUARDF挡WAN->LAN新建转发(-A挂载保DNAT优先); v1.4: v6同构; 历史见git |
| `gw/guest_fw.sh` | **v1.6** | manifest | `/data/gw/guest_fw.sh` | 访客隔离防火墙v1.6(审计P0: GUEST_ISOLATE开关删除=强制隔离; 兼容需求改由主WiFi终端频段锁定承接; 历史版本见git) |
| `gw/healthdog.sh` | **v1.4** | manifest | `/data/gw/healthdog.sh` | 看门狗用户态心跳 + 二级监督; v1.4: 跨重启恢复已 arm 内核的心跳(否则 90s 复位); v1.3: lo 强制 up; v1.2(P0-1): 稳定窗后主动 arm + 重启环保护栏 + pstore 回收; 历史见git |
| `gw/led_mgr.sh` | **v2.8** | manifest | `/data/gw/led_mgr.sh` | 原厂风格LED守护(绝对电平+自愈); v2.8(batch1): 每 2s 心跳; v2.7: 单实例锁排除自身; 历史见git |
| `gw/log_keeper.sh` | **v2.3** | manifest | `/data/gw/log_keeper.sh` | 日志持久化守护; v2.3: 写锁回读校验(防监督重启竞态双实例); v2.2: TZ; v2.1: BOOT 门禁 boot_id; v2.0(P1-5): 单实例锁+ne_census+崩溃面包屑; 历史见git |
| `gw/mipc_dial_trace.sh` | **v1.0** | manifest | `/data/gw/mipc_dial_trace.sh` | 5G 拨号取证(xtrace 抓真参) |
| `gw/night_report.sh` | **v1.0** | manifest | `/data/gw/night_report.sh` | 夜间体检报告 |
| `gw/ntp_keeper.sh` | **v1.4** | manifest | `/data/gw/ntp_keeper.sh` | 每小时NTP守时(多源; 设备无RTC); v1.4(P1-1): 单实例锁; v1.3: 首同步失败 60s 重试+心跳; v1.2: 时区自愈; 历史见git |
| `gw/radvd.conf` | **v1.0** | manifest | `/data/gw/radvd.conf` | IPv6 SLAAC+RDNSS通告(br-lan, ULA fd42:9ac1:7e50::/64) |
| `gw/rc.extend.sh` | **v2.6** | manifest | `/data/rc.extend.sh` | 槽位调度器; v2.6(stability P0-2/P1-5): boot 尝试台账+条件清 TRY_A(上次 healthy 且非快速重启)+boot_gate 终判; core_pattern 改 core_meta wrapper; healthdog forensic 按 marker; 历史见git |
| `gw/rc_netfh.sh` | **v3.11** | manifest | `/data/gw/rc_netfh.sh` | 路线A: FH modem栈环境; v3.10(日志加密轮): 相位计时+settle 每10s ccmni 清单+route/NAT REPAIR+fw_apply rc+总耗时; v3.9: RIL 四件套全退役, 读/写路径直连; v3.11(日志加密轮补): 日志行补 epoch 时间基准(跨日志关联) |
| `gw/reboot_sched.sh` | **v1.3** | manifest | `/data/gw/reboot_sched.sh` | 定时重启守护; v1.3(P1-1): 单实例锁+心跳; v1.2: 触发行先落 /data+sync; 历史见git |
| `gw/toolchain_init.sh` | **v1.0** | manifest | `/data/gw/toolchain_init.sh` | 静态工具链自举: /data/gw/sbin 符号链接农场(busybox 305 applet + 静态 iproute2 ip), 原子换入/失败回退 vendor; rc.extend 开机调用 |
| `gw/traffic_logger.sh` | **v1.3** | manifest | `/data/gw/traffic_logger.sh` | 流量采样器; v1.3(P1-1): 单实例锁+心跳; v1.2b: 基线带源标记; 历史见git |
| `gw/udhcpc_eth1.script` | **v1.0** | manifest | `/data/gw/udhcpc_eth1.script` | eth1口 udhcpc 事件钩子(补登记) |
| `gw/udhcpc_wan.script` | **v1.0** | manifest | `/data/gw/udhcpc_wan.script` | WAN口 udhcpc 事件钩子(接口无关化) |
| `gw/v2_access.sh` | **v6.1** | manifest | `/data/gw/v2_access.sh` | v2 极简访问层(串口/SSH/DHCP/防火墙22,零守护干涉) |
| `gw/v3_babysit_v2.sh` | **v3.0** | manifest | `/data/rescue/babysit.sh` | 启动保姆; v3.0(P0-2): 进展式 T1=240s(无进展 120s 才杀 rcS/mipc_wan_cli) + T2=600s(仍无进展才翻 B) + 900s 硬帽 + 决策落 /data; 目标路径改为 preinit 实跑的 /data/rescue/babysit.sh; 历史见git |
| `gw/v3_rc10.extend.sh` | **v2.34** | manifest | `/data/gw/rc19.sh` | v3 启动编排 rc19v2; v2.34(P0-2): 120s 定时器退役 → boot_gate 健康门禁 + boot.progress 相位推进 + rc19.done; v2.33(batch1): authd 先于 wan_agg; 历史见git |
| `gw/wan_agg.sh` | **v3.3** | manifest | `/data/gw/wan_agg.sh` | 双上行聚合主管; v3.2(日志加密轮): TICK(30s)汇总+探活逐目标+硬截止/authd/W2_READY 边沿+主路写失败留痕; v3.1: 探活实证选承载口(僵尸口); 历史见git; v3.3(日志加密轮补): 日志行补 epoch 时间基准(跨日志关联) |
| `gw/wan_agg_lib.sh` | **v1.2** | manifest | `/data/gw/wan_agg_lib.sh` | 聚合引擎落地层+conf 管理库; v1.2(日志加密轮): ensure_rules 每次补装记 REPAIR+rc(规则被外力蒸发不再静默); v1.1: +cell_iface_pick(探活实证选承载口) |
| `gw/wan_eth.sh` | **v1.4** | manifest | `/data/gw/wan_eth.sh` | 有线 WAN(eth0) 接口管理守护; v1.4(P1-1): 单实例锁; v1.3(batch1): 心跳供 watchdog 判卡死; 历史见git |
| `gw/watchdog.sh` | **v1.28** | manifest | `/data/gw/watchdog.sh` | 持续不变量看门狗; v1.28: 2-of-3 采样确认 + 全部内联探针限时 + v3httpd HTTP 200/dnsmasq DNS 功能探针(仅告警); v1.27(P0/P1): 限时/统一监督表/工具故障台账/心跳/门禁复检; 历史见git |
| `gw/webs_revive.sh` | **v1.3** | manifest | `/data/gw/webs_revive.sh` | 原厂GUI复活器(自足nginx conf; 手动拉起) |
| `gw/wedge_watch.sh` | **v1.0** | manifest | `/data/gw/wedge_watch.sh` | 串口wedged值守望器(补登记) |
| `gw/wifi_autoch.sh` | **v1.1** | manifest | `/data/gw/wifi_autoch.sh` | WiFi 自动选道器; v1.1(日志加密轮): 输出 # 注释行记录扫描规模/候选/评分(源码时无害) — 选道依据可复盘; IDC 安全掩码+候选{1,6} |
| `gw/wifi_guard.sh` | **v1.3** | manifest | `/data/gw/wifi_guard.sh` | BA/TX 停滞自动恢复守卫; v1.3: iw/tc 探针限时; v1.2(P1-4): 连续 4 样本(60s)确认+站点/backlog 前置+2 次/小时限频+心跳+单实例; 历史见git |
| `gw/wifi_macplan.sh` | **v1.0** | manifest | `/data/gw/wifi_macplan.sh` | 出厂 MAC 派生计划(自 wifi_up v1.29 拆出; api uplink 的 eth0 原生 MAC 还原同步收敛到此唯一实现 — 原内联副本缺两级兜底属算法漂移实例) |
| `gw/wifi_up.sh` | **v1.29** | manifest | `/data/gw/wifi_up.sh` | mt7992 AP 工厂配方(v1.29 架构轮: MAC 派生拆出 wifi_macplan.sh + 自动选道拆出 wifi_autoch.sh, 主文件收敛为拉起配方本体, 变量/契约零变化; v1.28: 候选收敛安全集深部{1,6}; 历史见git) |
| `gw/www/api.sh` | **v2.77** | manifest | `/data/gw/www/api.sh` | API 核心路由器+helpers; v2.76(日志加密轮): +/tmp/api.log 请求级日志(写端点全记/读端点仅慢或错误, 只含端点/方法/耗时/错误码, 不记 body/token/口令); v2.75: 六域模块懒加载拆分; v2.77(日志加密轮补): 日志行补 epoch 时间基准(跨日志关联) |
| `gw/www/api_agg.sh` | **v1.1** | manifest | `/data/gw/www/api_agg.sh` | API 聚合+上行域模块; v1.1(日志加密轮): 权重/模式/钉死/上行档案变更写 api.log(凭证脱敏) |
| `gw/www/api_cell.sh` | **v1.1** | manifest | `/data/gw/www/api_cell.sh` | API 蜂窝域模块; v1.1(日志加密轮): cells 成败/耗时、锁频/锁小区/制式/飞行/扫描/PIN 动作写 api.log(PIN 值脱敏) |
| `gw/www/api_lan.sh` | **v1.0** | manifest | `/data/gw/www/api_lan.sh` | API LAN 服务域模块(v2.75 拆出: dhcp/dhcp_static/fw 族; fw_apply.sh 改域内懒加载 — 原对全部请求无条件 source) |
| `gw/www/api_sms.sh` | **v1.2** | manifest | `/data/gw/www/api_sms.sh` | API 短信域模块; v1.2(日志加密轮): 发送成败/长度/模组原始响应写 api.log(号码仅末4位, 内容不落盘); v1.1: AT+EMGS 路线 |
| `gw/www/api_sys.sh` | **v1.3** | manifest | `/data/gw/www/api_sys.sh` | API 系统/状态域模块; v1.3(日志加密轮): traffic 选口回退/qdisc 缺失留痕; v1.2: /api/traffic 增 if 字段; v1.1: 探活实证选口 |
| `gw/www/api_wifi.sh` | **v1.0** | manifest | `/data/gw/www/api_wifi.sh` | API WiFi 域模块(v2.75 拆出: wifi/wifi_adv/band_pin/wifiscan 族; 域历史随域迁入头注) |
| `gw/www/app.js` | **v3.51** | manifest | `/data/gw/www/app.js` | 控制台SPA; v3.51: 移除宵断卡片(先验方案下架); 历史见git |
| `gw/www/index.html` | **v2.32** | manifest | `/data/gw/www/index.html` | v3控制台页面(v2.32: 缓存v66) |
| `gw/www/style.css` | **v2.1** | manifest | `/data/gw/www/style.css` | 控制台主题 |
| `gw/zz_data_hook` | **v1.1** | manifest | `/data/build/rootfs/etc/init.d/zz_data_hook` | S98数据钩子(v1.1: plain sh——原厂无/etc/rc.common, rc.common式shebang致开机栈全灭; 回归实测发现) |
| `gw/src/fhstub.c` | **v1.0** | src | `gw/bin/fhstub.so` | FH符号桩库源码 |
| `gw/src/healthdog.c` | **v1.0** | src | `gw/bin/healthdog.ko` | 看门狗模块源码(版本随产物) |
| `gw/src/logc.c` | **v1.2** | src | `gw/bin/logc` | logc 源码(同产物; 面包屑/dump-raw/selftest/防栈溢出) |
| `gw/src/mipc_cellular.c` | **v0.17** | src | `gw/bin/mipc_cellular` | 蜂窝MIPC直连CLI源码; v0.17: 日志 primary/last 传输分开(plen/prc/pms+lrlen/lrc/lms); v0.16: cells tag 双变体 0x810b/0x010b(19邻区用 0x010b); 解码失败原始载荷落盘 |
| `gw/src/multiwan_ctl.c` | **v1.1** | src | `gw/bin/multiwan_ctl` | multiwan控制器源码(随产物1.1) |
| `gw/src/shmsnap.c` | **v1.0** | src | `gw/bin/shmsnap` | cfgmgr快照源码 |
| `gw/src/v3_fix.c` | **v1.2** | src | `gw/bin/v3_fix.ko` | TTL/解绑模块源码(版本随产物); v1.2 随产物重建 |
| `gw/src/v3_steth.c` | **v1.0** | src | `gw/bin/v3_steth.ko` | 听诊器模块源码(版本随产物) |
| `gw/src/v3httpd.c` | **v2.6** | src | `gw/bin/v3httpd` | GUI HTTP服务源码; v2.6: 同产物 |
| `gw/src/wpapmk.c` | **v1.0** | src | `gw/bin/wpapmk` | WPA PMK转换源码(纯C PBKDF2) |
| `install/run.sh` | **v1.1** | tool | `-` | raw shell自驱脚本(v1.1: 分区次设备号从/proc/partitions动态解析成布局门禁, RP102/RP103通用; v1.0硬编码259:7等) |
| `tools/agg_pins.conf.example` | **v1.1** | tool | `-` | MAC钉死表模板(真实表设备侧自管, 含个人MAC不入库) |
| `tools/build_healthdog.sh` | **v1.0** | tool | `-` | healthdog.ko内核模块构建(内核树) |
| `tools/build_logc.sh` | **v1.1** | tool | `-` | logc 静态构建(zig cc aarch64-linux-musl; v1.1: -fstack-protector-all) |
| `tools/build_mipc_cellular.sh` | **v1.1** | tool | `-` | mipc_cellular构建(zig cc aarch64-musl 静态); v1.1: 移除 libqlril 链接(v0.12+ 零 RIL 依赖) |
| `tools/build_static_ip.sh` | **v1.0** | tool | `-` | iproute2 6.3.0 静态构建(zig cc aarch64-linux-musl, 与厂商同版本) |
| `tools/build_steth.sh` | **v1.0** | tool | `-` | v3_steth.ko构建 |
| `tools/build_v3fix.sh` | **v1.1** | tool | `-` | v3_fix.ko构建; v1.1: 路径修正当前布局 + uapi/asm junction 失效改就地复制 + 记录产物错位事故 |
| `tools/build_v3httpd.sh` | **v1.0** | tool | `-` | v3httpd构建(zig cc aarch64-linux-musl全静态, 同mipc_cellular链) |
| `tools/deploy.py` | **v2.23** | tool | `-` | 部署/漂移守卫; v2.23: babysit 目标修正为 preinit 实跑的 /data/rescue/babysit.sh + MANIFEST +boot_gate/core_meta; 历史见git |
| `tools/device_local.py.example` | **v1.0** | tool | `-` | 凭证模板(真件gitignored) |
| `tools/doc_audit.py` | **v1.2** | tool | `-` | 台账↔文档内联标记双向审计; v1.2: 子进程显式 UTF-8(gbk 环境不再中断 deploy 文档门禁); 历史见git |
| `tools/fetch_static_busybox.sh` | **v1.0** | tool | `-` | Alpine busybox-static 1.36.1-r31 拉取+SHA256 钉死(解包到 gw/bin/busybox) |
| `tools/fuzz_logc.py` | **v1.0** | tool | `-` | logc 帧解析器在设备侧的结构化 fuzz(合法帧+截断+伪长度+类型污染+噪声; 崩溃留面包屑并保存语料) |
| `tools/gen_kernel_inc.py` | **v1.0** | tool | `-` | kernel头生成(构建辅助) |
| `tools/health_check.py` | **v1.1** | tool | `-` | v4全系统体检器(SSH 18项; v1.1 fw_ver读/data/gw/VERSIONS: 身份/槽位/bootctrl/服务/WiFi/5G/外网/资源/温度/存储/数据/日志) |
| `tools/identify2.py` | **v1.0** | tool | `-` | 残留终验取证器(user_data清单/p26纯净性挂载验证/proc-net快照) |
| `tools/identify_fw.py` | **v1.0** | tool | `-` | 只读固件身份取证器(release/cmdline/v4标记/挂载表; 前置空格防tty首字符丢失) |
| `tools/leak_check.py` | **v2.2** | tool | `-` | 敏感词零命中门禁; v2.2: --history 全量扫提交正文(%B, 原仅扫标题%s可漏检消息体); v2.1: 修复 PAT_PARTS NameError; 历史见git |
| `tools/lgssh.py` | **v1.3** | tool | `-` | SSH助手(env/_local/secrets凭证; run()命令通道); v1.3: 主机密钥指纹钉死PinPolicy(HOST_KEY_FP/LG_HOST_KEY_FP, 认证前校验, 审计P0-5) |
| `tools/lk_eth1_resume.py` | **v1.1** | tool | `-` | eth1续链器(LK控制台接管: kcmdline已注入态恢复; 含misc回退现场抓取; 补登记) |
| `tools/lk_flash_v4.py` | **v1.1** | tool | `-` | v1.1路径随项目根迁移; 终版刷入器(LK陷阱→raw shell→/dev/null修复→curl送deploy2.sh→后台自驱+轮询deploy.log→重启监测; 修三雷: uclient罢工/&需/dev/null/串口前台等待吃首字符) |
| `tools/lk_flash_v4_eth1.py` | **v1.1** | tool | `-` | v1.1路径随项目根迁移; eth1刷入实证器(全链条: 陷阱→raw shell→eth1起链[历史疑点:PHY仅ifup后attach]→curl传输→deploy2自驱→重启回v4.1) |
| `tools/lk_flip2.py` | **v1.1** | tool | `-` | LK 一键翻槽(a|b, misc[2060]字节) |
| `tools/lk_write.py` | **v1.6** | tool | `-` | LK raw-shell 文件写入(回显校验+tmpfs挂载+cmdlist巡检, 取代lk_fix_access) |
| `tools/rescue_shadow.py` | **v1.0** | tool | `-` | shadow.override未bind网络救援(getpass旧口令→只读探针: 文件md5/grep行为单测/部署钩子sh -x跟踪→从.bak恢复+重bind; 依赖rc.extend v2.1) |
| `tools/rotate_toor.py` | **v1.4** | tool | `-` | toor口令轮换器; v1.4: 轮换前存档.bak(rc.extend v2.1回退源); 历史见git |
| `tools/run_serial_server.sh` | **v1.0** | tool | `-` | 串口控制台守护拉起器 |
| `tools/selftest.py` | **v2.51** | tool | `-` | 设备自检; v2.51: 控制台 UTF-8 重配置(GBK 终端不再中断 post-deploy 门禁); v2.50(P0/P1): +7 条 stability 判据; 历史见git |
| `tools/serial_cmd.py` | **v1.3** | tool | `-` | 串口命令瘦客户端(marker输出捕获; v1.3示例路径更新) |
| `tools/serial_server.py` | **v1.7** | tool | `-` | 常驻串口控制台守护(:7717, 唯一登录驱动; v1.7凭证外置_local/secrets) |
| `tools/upgrade_slot.py` | **v1.0** | tool | `-` | SSH整槽升级器(P3第一档: vercheck/槽位/空间预检→md5门禁→dd备份旧p26→写新镜像→挂载sanity断言(toor/rcS/#v3:/procd)→失败自动整槽还原不重启→清TRY_A→reboot; PC侧轮询日志+回连终检; --dry-run) |
| `tools/vercheck.py` | **v1.5** | tool | `-` | 版本注册表校验/渲染/设备比对(v1.3: device()随deploy基座迁/data/gw; v1.2性质分区双向强制+全跟踪文件可归类; v1.1 image类md5钉死) |
| `tools/verify_v4.py` | **v1.0** | tool | `-` | v4刷后落地验证器(串口toor登录; 身份/钩子/数据/网络/进程巡检; 口令走argv不落盘) |
| `tools/verify_v4_services.py` | **v1.0** | tool | `-` | v4服务巡检器(监听端口/GUI/WiFi双频/5G WAN实网ping) |
| `tools/wait_ready.py` | **v1.1** | tool | `-` | 轮询等待器(tcp/串口marker, 代替长sleep) |
<!--VERCHECK:END-->

## 结论台账 (审计生成, 勿手改)


<!--CLMAUDIT:BEGIN (generated from docs/CONCLUSIONS.tsv; `doc_audit.py render`)-->

| 结论 | 状态 | 代码证据 | 测试护栏 | 验证锚点 | 说明 |
|---|---|---|---|---|---|
| `CLM-160MHZ`@FINDINGS.md | ✅实证 | `gw/wifi_up.sh>=1.10` | 5G 带宽配置与射频实际一致 (跨层) | e76abba@2026-10-05 | 160MHz可用;旧"驱动钳制"系dat双字段语义错位误诊 |
| `CLM-160-FM`@FEATURE_MATRIX.md | ✅实证 | `gw/wifi_up.sh>=1.10` | 5G 带宽配置与射频实际一致 (跨层) | e76abba@2026-10-05 | 同上,对比表行 |
| `CLM-BOOTCTRL-2060`@FINDINGS.md | ✅实证 | `tools/lk_flash_v4.py>=1.1` | TRY_A 已自清 | e76abba@2026-10-05 | misc偏移2060 magic BCAB |
| `CLM-ZMTK-CLONE`@FINDINGS.md | ✅实证 | `gw/zz_data_hook>=1.1` | boot.done 存在 (启动链完整) | e76abba@2026-10-05 | 首启克隆槽必须在自定义链中禁用 |
| `CLM-PMK-ONLY`@FINDINGS.md | ✅实证 | `gw/wifi_up.sh>=1.18` | BSS 接口集合与访客配置一致 (v1.17 配置感知) | c39b0d4@2026-10-06 | hostapd只吃原始PMK(wpa_passphrase被libfhcrypto拦截); v1.18访客多BSS下断言改配置感知 |
| `CLM-MARK-OR`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.15` | 分流规则已安装 (模式感知) | 6398974@2026-10-06 | iptables MARK覆盖非OR;mark==0守卫 |
| `CLM-PROCD-INTERCEPT`@VENDOR_MAP.md | ✅实证 | `—` | — | 54e89f0@2026-10-05 | RE静态+设备佐证: procd拦截sysinit,FH层由S99末行触发 |
| `CLM-DIALER-QLNETD`@VENDOR_MAP.md | ✅实证 | `gw/rc_netfh.sh>=2.2` | 拨号兜底守护存活 (P2) | 89dad51@2026-10-06 | 闸门A定案:mobilenetwork=PDN生命周期持有者(杀后ccmni≤10s掉IP,裸重启不够);P2 dial_keeper兜底接管,裁撤前置条件已备 |
| `CLM-BANDLOCK-LIBQLRIL`@VENDOR_MAP.md | ✅实证 | `—` | — | 54e89f0@2026-10-05 | RE实证: ql_nw_set_band_mode(readelf UND),无AT面 |
| `CLM-FHDRV-UNLOADED`@VENDOR_MAP.md | ✅实证 | `—` | — | 54e89f0@2026-10-05 | fhdrv链自定义启动下未载=ENOTTY真因;复活需完整加载链 |
| `CLM-NGINX-PORTS`@VENDOR_MAP.md | ✅实证 | `—` | — | 54e89f0@2026-10-05 | 原厂nginx=80/443;8080是v4复活层 |
| `CLM-ATTACK-SURFACE`@FEATURE_MATRIX.md | ✅实证 | `gw/v3_rc10.extend.sh>=2.19` | telnet 口关闭,厂商 Web/App 后端未复活 (8080/8840/1899x),SSH 可达 (dropbear 单监听) | e76abba@2026-10-05 | 自研监听面=80/22/53 |
| `CLM-WATCHDOG-17`@FEATURE_MATRIX.md | ✅实证 | `gw/watchdog.sh>=1.2` | 不变量看门狗活着且无未恢复故障 | 2ea76ed@2026-10-05 | 17项不变量+atcid自愈+LED告警 |
| `CLM-SELFTEST-51`@FEATURE_MATRIX.md | ✅实证 | `tools/selftest.py>=1.4` | WAN 面纵深封禁链在位 (P0) | e2fe2e3@2026-10-05 | 52断言7类+数据面+破坏性验证+文档漂移审计链 |
| `CLM-LOGMGR-DEAD`@ROADMAP.md | ✅实证 | `—` | — | e76abba@2026-10-05 | logmgr已死多周系统正常(rc_netfh拉起后自灭,无消费者);下架无风险 |
| `CLM-MIPCTOOL`@ROADMAP.md | ✅实证 | `gw/src/mipc_cellular.c>=0.3` | SMS 引擎二进制冒烟 (P4) | eb7dacc@2026-10-06 | v0.3 +SMS发送(ql_sms_send_msg结构1704B逆向: fmt/addr/len/content; 同步ret=0=已发, 实弹到机主手机成功) |
| `CLM-BANDLOCK-STRUCT`@VENDOR_MAP.md | ✅实证 | `gw/src/mipc_cellular.c>=0.2` | 锁定状态跨层一致 (conf=树=模组 / mipc 引擎就位) | 1448d9e@2026-10-05 | 168B全破译: mode3@0/umts@4/LTE@8+@C/NR@28+@2C+@30(段n-1/n-33/n-65);锁N41+N79实弹验证+解锁恢复 |
| `CLM-FIRSTBOOT-AUTH`@ROADMAP.md | ✅实证 | `gw/www/api.sh>=2.23` | 首刷口令自举就位 (不运行在默认口令) | a7648e3@2026-10-06 | 纯原厂直刷首启: login以文档化默认口令lg6151m建档+default标记; GUI强制改密弹窗; SSH(22)入WANGUARD |
| `CLM-DIALKEEPER`@ROADMAP.md | ✅实证 | `gw/dial_keeper.sh>=1.0` | 拨号兜底守护存活 (P2) | 7814905@2026-10-06 | P2验收全过: 冷拨35s接管/净8min稳定/飞行循环自愈(FAIL退避恢复)/mobilenetwork死后PDN独立;呼叫所有权随deact/act转移(厂商TERM清理只及自身呼叫) |
| `CLM-P3LITE`@ROADMAP.md | ✅实证 | `gw/rc_netfh.sh>=3.0` | 拨号兜底守护存活 (P2) | a3dbf44@2026-10-06 | P3-lite: cfgmgr+logmgr守护下架; 3次冷启动54/54全绿; 守护0在位树通 |
| `CLM-TREE-DAEMONLESS`@VENDOR_MAP.md | ✅实证 | `gw/rc_netfh.sh>=3.0` | 蜂窝引擎小区列表活着 (P3 终章) | 36be34c@2026-10-06 | v3.1 终章: 树整体退役(KEEP_TREE回滚门控); 小区列表=ql_nw_get_cell_info直读(0x520/0x30布局, cellraw实证); 重启#1全绿 |
| `CLM-ERAT-MAP`@ROADMAP.md | ✅实证 | `gw/www/api.sh>=2.30` | SIM 就绪 (CPIN) | 22dd503@2026-10-06 | A组指令级实证: mode0→erat3/1,3→19,0/2→15/4→1; 飞行=deact+cfun0/cfun1; 实弹模式切换+飞行循环含keeper重拨 |
| `CLM-SMS-SEND`@ROADMAP.md | ✅实证 | `gw/src/mipc_cellular.c>=0.3` | SMS 引擎二进制冒烟 (P4) | 22dd503@2026-10-06 | B组逆向ql_sms_send_msg结构1704B(fmt/addr[252]/len/content[1440])+同步ret=0即成; 实弹到机主手机成功; 无CMGS毒性 |
| `CLM-CELLLOCK-AT`@ROADMAP.md | ✅实证 | `gw/www/api.sh>=2.28` | 锁定状态跨层一致 (conf=树=模组 / mipc 引擎就位) | 22dd503@2026-10-06 | EMMCHLCK AT直发(lte7/nr11); 锁服务小区零扰动+真解锁cells:0 |
| `CLM-PLMN-SCAN`@ROADMAP.md | ✅实证 | `gw/src/mipc_cellular.c>=0.4` | SIM 就绪 (CPIN) | f48b803@2026-10-06 | C组逆向集成: ql_nw_network_scan异步回调+0x1288结构; 首发实弹8网络(真EONS名+status/RAT); GUI按钮实测渲染 |
| `CLM-PIN-SIM-AT`@ROADMAP.md | ✅实证 | `gw/www/api.sh>=2.33` | API login + token 生命周期 | f48b803@2026-10-06 | PIN管理AT直发引擎(厂商序列clck/cpwd/cpin; enable/disable未实弹-有锁卡风险) + get_sim AT直读优先(CPIN/CIMI/CCID/CGSN/COPS实测全对) |
| `CLM-P3-FINALE`@ROADMAP.md | ✅实证 | `gw/rc_netfh.sh>=3.1` | 蜂窝引擎小区列表活着 (P3 终章) | ba9bb1d@2026-10-06 | P3完整收官: cfgmgr+logmgr+mobilenetwork+cfg_tool+shmsnap全部下架; 2次冷启动(守护0/shm0/keeper拨号35s)+55/55×2+全端点引擎化; KEEP_TREE=1一键回滚 |
| `CLM-GUEST-INDEP`@FEATURE_MATRIX.md | ✅实证 | `gw/wifi_up.sh>=1.22` | 访客 BSS 配置/隔离防火墙一致 (guest_fw) | 87bebe7@2026-10-06 | 访客独立名称/频段(2g/5g/both)/密码; 隔离=原厂wifiguest.sh配方(仅出网); v1.22: 动态BSS必须显式入桥(hostapd不自动加, 帧死无IP接口致dnsmasq盲=tcpdump实证真根因); 真MLO见CLM-MLO |
| `CLM-MLO`@FEATURE_MATRIX.md | ✅实证 | `gw/wifi_up.sh>=1.23` | MLO 状态与 dat 键一致 (v1.19) | 2a6b1c5@2026-10-06 | MLO真双链路可用+在线即时生效(v1.23拆链修复): -B在线重应用死亡机制已完全闭环(旧实例TERM不注销驱动MLD(设计行为), rai0 sync调和残留态发ML REMOVE(ra0)拆组退出,尾部日志被stdio缓冲吞; 下电清bss_mngr链路态即愈, T1-T7实证); 原厂=global守护永不重启+逐BSS REMOVE/ADD热重载; MLO开关双向在线切换验证; 全零表=v1.15事故形态禁写 |
| `CLM-RP102-COMPAT`@install/README.md | ✅实证 | `install/run.sh>=1.1` | API login + token 生命周期 | a808fe0@2026-10-06 | RP102前向兼容: kit现场构建路径全兼容(底座自适应); 预构建RP103镜像禁入RP102(MDDB P56/P40+18个.ko+fhrom漂移三处错配); LK代码级相同仅签名槽差异; run.sh分区号动态解析成门禁 |
| `CLM-P4-SSE`@ROADMAP.md | ✅实证 | `gw/bin/v3httpd>=2.4` | SSE 信号事件流 (v3httpd v2.5 + api.sh sse token 门) | ecb2e20@2026-10-06 | SSE信号推送落地: 流式CGI通道+3s事件+EventSource前端, curl/selftest双验证; P4全数完成 |
| `CLM-P5-CLOSED`@ROADMAP.md | ✅实证 | `tools/selftest.py>=2.9` | SSE 信号事件流 (v3httpd v2.5 + api.sh sse token 门) | ecb2e20@2026-10-06 | P5关闭: 实测传输期CPU空转,瓶颈在上游非引擎; quecadp复活=高风险零收益; 重开条件=>500Mbps上游+softirq饱和 |
| `CLM-AGG-MODES`@ROADMAP.md | ✅实证 | `gw/wan_agg.sh>=2.18` | 聚合模式配置合法且一致 (v2.18 五模式) | 3aaf20b@2026-10-06 | 聚合五模式(对齐原厂): weight/cell_prio/eth_prio/cell_only/eth_only; 仅模式=E1/E2强制注入(无failover); MODE热载+旧格式迁移(100/0映射优先模式); 滑块5-95钳制(极端值语义归显式模式); GUI权重卡条件显示; 五模式API实弹循环切换全过 |
| `CLM-ENDC-NRMODE`@FINDINGS.md | ✅实证 | `gw/src/mipc_cellular.c>=0.8` | 组网模式 ENDC conf=API=模组读回一致 | ddee9bb@2026-10-09 | 官方ENDC: SA=1/NSA=2/双=3→ql_nw_set_nr_disable_mode(3/5/7)非先restore7; ECNCFG=漫游勿混淆; E5GOPT=同旋钮AT镜像(SET_CACHE_ENDC_CONNECT_MODE缓存型,写回需重附生效); LTE→NR-SA不自发重选 |
| `CLM-AUTHD-PROBE`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.26` | 有线侧探活语义护栏 (up 必叠加数据面 ICMP) | 6d137b6@2026-10-09 | 21:30实弹: authd succ永不复位+Req-Identity持续刷up → 上层把"up"当充分活证据 → eth_prio下5G待命侧15h无接班(06:02→21:32); 修复=up必叠加数据面ICMP(w2.26)+authd up只认认证证据(v2.2); 实弹down 8s转移 |
| `CLM-REBOOT-SCHED`@FEATURE_MATRIX.md | ✅实证 | `gw/reboot_sched.sh>=1.1` | 定时重启守护单实例且与配置同源 (默认每日 04:00) | c16f42e@2026-10-10 | 实弹: API设now+2min→窗口内触发→76s回升; rc19开机自拉/配置保持/TRY_A自清; 护栏: 时钟可信+开机300s+5min窗+当日去重 |
| `CLM-TZ-TMPFS`@FINDINGS.md | ✅实证 | `gw/ntp_keeper.sh>=1.2` | NTP 服务器自管配置生效 (defaults叠settings) | ac47aa2@2026-10-10 | /etc/TZ→/tmp/TZ符号链接(tmpfs)重启即失回落UTC(实弹+0800→+0000); 修: TZ入自管配置+双守护每轮自愈; 连带修selftest优先级盲读(4 WiFi测试误报)与token缺席降级 |
| `CLM-IDC-SAFECH`@FINDINGS.md | ✅实证 | `gw/wifi_up.sh>=1.27` | AP 信道配置==实况 (IDC 漂移护栏) | cece8c5@2026-10-10 | RE: 驱动IDC(LTE共存避让)bEnabled=1每秒轮询掩码自行搬道; 实测mask=1fe→cand2g{1..8}; wifi_up仅安全集选道+watchdog漂移回写; 周期"切换"事件=wifiscan假象(ChnSwitchCnt=0) |
| `CLM-MLO-LIVE`@FINDINGS.md | ✅实证 | `gw/www/api.sh>=2.68` | MLO 状态与 dat 键一致 (v1.19) | 013a7ce@2026-10-10 | mwctl dump ap_mld stdout直读(RE: dump段干净/show段进dmesg); 实测组1双链路STR; api/app/selftest三处接线(BSSID集合==ra0/rai0 MAC) |
| `CLM-LOGKEEP`@FINDINGS.md | ✅实证 | `gw/log_keeper.sh>=1.0` | 日志持久化守护活着且镜像新鲜 | 8c0fedf@2026-10-10 | 实测300条洪泛300/300精确捕获+21快照+诊断包90KB脱敏0泄漏; watchdog自愈+ql_wifi_sample卡死清除; GUI/SSH/开机三入口 |
| `CLM-ETHFLAP`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.27` | 有线侧探活语义护栏 (up 必叠加数据面 ICMP) | dd01765@2026-10-11 | 载波flap98次/4.3h+1G→100M降速=上游物理层; EAP重认证与d2=99一一对应; 修: 首败同轮复核+探测-W1, 实弹死亡确认≈1s(原25s级) |
| `CLM-IDC-BOUNCE`@FINDINGS.md | ✅实证 | `gw/wifi_up.sh>=1.28` | AP 信道配置==实况 (IDC 漂移护栏) | 64e3a6e@2026-10-12 | IDC掩码动态收缩(1fe→1fc→08)致驱动整晚搬运2↔3↔9; 修: wifi_up v1.28 候选收敛安全集深部{1,6}; 掩码不可用期回退{1,6}; 现场重应用conf=live=3 |
| `CLM-AUTHD-SILENCE`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.29` | 有线侧探活语义护栏 (up 必叠加数据面 ICMP) | ec28b9d@2026-10-12 | 静默看门狗: 健康期30s重询问节拍, >40s无EAP帧=会话死(authd v2.3); 检测链四路: 载波≤3s/EAP Failure瞬时/静默≤43s/公网ICMP≤6s; curfew先验方案同日下架 |
| `CLM-MD-EE`@FINDINGS.md | ✅实证 | `—` | — | 12717c3@2026-10-14 | 01:07:47模组固件Fatal(AEE EE/modem/DSPNR1s; err 0x12/0x71B3E53B; P56构建)AP侧零前兆; 先兆=thermal_core丢MD数据源早1s(-274假读); 转储加密仅ZZ_INTERNAL可读; db_history 10-05以来首EE |
| `CLM-DIAL-GAP`@FINDINGS.md | ✅实证 | `gw/dial_keeper.sh>=1.1, gw/watchdog.sh>=1.7` | 拨号守护心跳新鲜且 mipc 硬超时在线 (卡死可自愈) | 12717c3@2026-10-14 | MD offline后5.4min零重拨留痕(拨号动作有data_call_act_type日志特征, 零命中); 疑RIL重启瞬间mipc调用无限阻塞(设备无timeout命令); 修: mto()硬超时+心跳+EE转储增量强制重拨+logger落syslog |
| `CLM-LED-LIE`@FINDINGS.md | ✅实证 | `gw/led_mgr.sh>=1.9` | 5G 指示灯反映数据面 (无数据不得点亮) | 12717c3@2026-10-14 | 旧"无承载=橙常亮"模组崩溃期点亮=谎报"5G在"; v1.9数据面唯一(ccmni IPv4=绿, 余全灭, 细分态只进日志); 实弹deact→15s三灯全灭→自动重拨42s恢复→绿回 |
| `CLM-LED-LIE-FM`@FEATURE_MATRIX.md | ✅实证 | `gw/led_mgr.sh>=1.9` | 5G 指示灯反映数据面 (无数据不得点亮) | 12717c3@2026-10-14 | 同上, 对比表行 |
| `CLM-SNAP-PREV`@FINDINGS.md | ✅实证 | `gw/log_keeper.sh>=1.2` | 日志持久化守护活着且镜像新鲜 | 12717c3@2026-10-14 | 新boot首轮tmp→tmp.prev整目录转存(.snap_up归属判定; 同boot守护重启不转存); 旧"变化才写"致新boot+90s覆盖事故现场(当晚dial_keeper/watchdog现场丢失); 实测转存10+份 |
| `CLM-KEEPER-LOCK`@FINDINGS.md | ✅实证 | `gw/watchdog.sh>=1.8, gw/dial_keeper.sh>=1.3` | 拨号守护心跳新鲜且 mipc 硬超时在线 (卡死可自愈) | 661d4fe@2026-10-14 | 自暴露双坑: 首见无hb误判陈旧杀拉→v1.2启动即写心跳; pgrep -f判据启动者argv自匹配(实测两次静默不启动)+杀所有匹配误伤旁观→v1.3 PID锁+cmdline复核 |
| `CLM-LED-WRITE`@FINDINGS.md | ✅实证 | `gw/led_mgr.sh>=2.0, gw/watchdog.sh>=1.9` | WAN 指示灯反映家宽数据面 (绝对电平自愈) | 0e477f4@2026-10-15 | eth0有公网IP/数据面通而WAN灯不亮; 两层根因: 1)led_mgr v1.x边沿触发(状态串不变即不写)- 实弹状态b1起5h一次没写; 2)watchdog告警闪WAN灯后停0; 修: v2.0绝对电平驱动(2s轮询,外部扰动2s纠回)+watchdog告警迁5G橙灯gpio473, WAN写权单一化; 全灯彻查: sysfs 4类(WiFi467/5G三色475-473-474/WAN292)+class 4个PMIC RGB未接外壳不点 |
| `CLM-LED-WRITE-FM`@FEATURE_MATRIX.md | ✅实证 | `gw/led_mgr.sh>=2.0, gw/watchdog.sh>=1.9` | WAN 指示灯反映家宽数据面 (绝对电平自愈) | 0e477f4@2026-10-15 | 同上, 对比表行; 实弹: 外部同时改错WAN/5G/WiFi三灯→2s内全纠回(旧版5h不纠); 告警闪烁全程不碰WAN灯; cfun=0真拆数据面→2s灭, cfun=1重拨→24s亮(22s为模组重注册固有耗时) |
| `CLM-AGG-ROUTE`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.30` | 蜂窝侧不再抢 main 表默认 (聚合路由地雷) | 1b93c69@2026-10-15 | 蜂窝探活路由 metric 50 插在家宽主默认(0)与备用(200)之间, 且家宽主默认只在状态迁移时装一次无看门狗 → 被冲刷后未打标流量(netagent/DNS/NTP+丢标记转发流)静默改走蜂窝且长期滞留; 修: 50→250 + 漂移块不再写 main + 补家宽主默认看门狗; 实弹: 删主默认后 ip route get 仍选 eth0, 8s 内自愈 |
| `CLM-TRAFFIC-SRC`@FINDINGS.md | ✅实证 | `gw/traffic_logger.sh>=1.2, gw/www/api.sh>=2.72, gw/watchdog.sh>=1.10` | 流量统计口径 = Linux 发送路径 (非网卡报告值) | 1b93c69@2026-10-15 | 蜂窝网卡 tx_bytes 被厂商卸载记账灌入无佐证增量(单秒 +1.22MB/813 包而 qdisc +29B、抓包只有 6 个探针包; DOWN 无 IP 的 ccmni1 记 47MB); 已知量注入实测 qdisc 与接口逐字节一致 → 改用 qdisc 口径(traffic_logger v1.2/api v2.72), 基线带源标记防切换假尖峰; watchdog v1.10 偏差护栏(256KB); 下行仍 netdev rx(实测准确) |
| `CLM-CELL-QUERY`@FINDINGS.md | ✅实证 | `gw/watchdog.sh>=1.11` | 蜂窝引擎小区列表活着 (P3 终章) | 1b93c69@2026-10-15 | ql_ril_service 活着/数据面正常(有 IP 可 ping)但 cells/endc 恒返 -2147024889: 厂商 RIL ql_nw 子服务静默失效, 无守护察觉, GUI 小区与组网卡片静默报错; 轮中撞上并按项目清栈路径(kill ql_netd ql_ril_service 后重启)实测恢复; watchdog v1.11 每 5min 探 serving 字段, 只告警不自动重启(蜂窝主力时重启会打断数据面) |
| `CLM-MAIN-PRIMARY`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.31, gw/dial_5g.sh>=1.3, gw/rc_netfh.sh>=3.4` | 未打标主路由聚合模式推导 (v4 与 v6 同源) | 8b2b15c@2026-10-15 | v4 原先只在状态迁移瞬间定 main 主默认、v6 无人管(靠 RA metric 恒偏好蜂窝), 且 dial_5g/rc_netfh 另写 metric 50/0 默认=地雷; 改: prim_want(模式+权重+真实存活)+main_primary_apply 唯一写方每周期复位(level-driven), 蜂窝侧 v6 用设备路由不依赖重发 RA; 实弹: eth_prio→v4/v6 均 eth0, --set-primary w1→v4/v6 均 ccmni2 且 v6 有回包, weight 跟权重侧 |
| `CLM-ALIVE-AUTHORITY`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.32, gw/led_mgr.sh>=2.1, gw/www/api.sh>=2.73` | 数据面判活不落入白名单陷阱 (宵断可见/唯一权威) | 3aeb573@2026-10-16 | 宵断(白名单式切断)未被识别: 判活目标 223.5.5.5/120.53.53.53 恰好被白名单放行→判活恒真永不转移; 且同一错判据在 wan_agg/led_mgr(含网关优先短路)/api 三处副本→灯与GUI一起谎报; 修: 目标改3个不同运营商且不在白名单内(任一通过即活)+ICMP全灭时TCP兜底, 发布 /tmp/wan_alive 为唯一权威, 两处消费; 实弹: home=0 灯灭 硬截止判死 客户端经蜂窝 72/0 |
| `CLM-PINS-SEED`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=2.34, tools/deploy.py>=2.17` | 钉死表缺省播种 (缺失不再报错/静默失效) | 30e81d6@2026-10-16 | 活文件 agg_pins.conf 设备侧自管(含个人MAC不入库)但缺失时重放循环报错+钉死静默失效(weight 模式每环循重复); 修: 随版本部署只读基线 gw/agg_pins.default(不含任何MAC, 自带说明), wan_agg 缺省才写地播种, 已有钉死永不覆盖; 活文件保持 EXTRA_KEEP 以防仓库空版本覆盖设备真钉死(L10 类事故); 行为等价(基线仅注释行) |
| `CLM-MODSPLIT`@FINDINGS.md | ✅实证 | `gw/wan_agg.sh>=3.0, gw/wan_agg_lib.sh>=1.0, gw/wan_eth.sh>=1.0, gw/www/api.sh>=2.75, gw/wifi_up.sh>=1.29, gw/wifi_macplan.sh>=1.0, gw/wifi_autoch.sh>=1.0` | wan_agg 拆分件在位 (lib 被 source + eth0 归属移交), wan_eth 守护进程存活 (有线 WAN 接口管理), API 域模块在位且静态面拒绝直出 (v2.75 拆分护栏) | b1e5fbd@2026-10-17 | 架构轮三分: 引擎落地层(wan_agg_lib, sourced=单写方不变)+eth0 接口管理(wan_eth 独立守护, udhcpc 9s 不再阻塞探活 FSM)+决策核心(wan_agg); api 六域懒加载(每请求只解析所需域, *.sh 直出拒绝受保护面扩大); wifi_up 拆出 macplan/autoch(消除 MAC 算法漂移副本); MODE/W1_PCT 三处重复校验收敛; 行为零变化除 udhcpc 阻塞修复 |
| `CLM-RIL-DUP`@FINDINGS.md | ✅实证 | `gw/rc_netfh.sh>=3.6` | RIL 守护全退役 (ql_ril_service/netd/submonitor/netagent) | 6161950@v3.6收编制: 有界等待rc.d套+只补缺席者+数量复核; v3.5的SIGKILL清场被procd respawn推翻(杀掉必复活+与S22/S85并发起跑) — 清理打不赢看护者时正确答案是收编制; 同轮修正OPERATIONS拓扑(mobilenetwork实查已不在运行) | SIGTERM 清场被厂商守护忽略 → mtk_netagent/ql_netd/ql_ril_service 开机各双实例(rc.d 套+rc_netfh 套); ubus 仅一套注册成功另一套空转, 双 netagent 同消费 netlink(多为 ignore); submonitor 未双属侥幸(资源冲突天然去重); 修: SIGKILL×3 重试+拉起后逐件复核; 同轮修正 OPERATIONS 拓扑(mobilenetwork 实查已不在运行, 自研拨号接管) |
| `CLM-NETAGENT-RETIRE`@FINDINGS.md | ✅实证 | `gw/rc_netfh.sh>=3.7, gw/ccmni_up.sh>=1.0, gw/dial_keeper.sh>=1.4, gw/dial_5g.sh>=1.4` | mtk_netagent 退役 (ccmni_up 接管落地), RIL 瘦身终态 (ql_netd/mipc_submonitor 退役) | 9d6a410@2026-10-17 | 实证 netagent 是 ccmni IP 执行者(act 响应含 v4/v6 全套地址而无人落地; proto mipc.sh 同样无落地语句, 两条拨号路径都靠它); 无它时拨号 result:0+僵尸 IP(飞行往返实弹); 退役=开机 service delete+SIGKILL; ccmni_up(解析落地)+keeper 数据面触发(堵僵尸洞)承接; 附带发现: 旧'IP already applied by the proto'注释错误归属已纠正 |
| `CLM-RIL-THIN`@FINDINGS.md | ✅实证 | `gw/rc_netfh.sh>=3.8` | RIL 瘦身终态 (ql_netd/mipc_submonitor 退役), RIL 守护全退役 (ql_ril_service/netd/submonitor/netagent) | 4f4dbdf@2026-10-17 | 拔管实验(8 项功能矩阵逐件 service delete): ql_netd 与 mipc_submonitor 零依赖(全矩阵绿) — 含拨号路径(目标终态飞行往返 t+61s 自愈, dial=mipc_wan_cli 直连不经 ql_netd); ql_ril_service 不可约 — 拔之 mipc_cellular cells 恒返 -2147024889(GUI 小区卡/SSE 消费的 ql_nw 路径唯一依赖), 保留并靠 procd respawn+watchdog v1.11 护栏; submonitor 的 procd 服务名带 .init 后缀(易踩坑) |
| `CLM-MIPC-TRANSPORT`@FINDINGS.md | ✅实证 | `gw/src/mipc_cellular.c>=0.9, gw/bin/mipc_cellular>=0.9` | 蜂窝引擎小区列表活着 (P3 终章) | da31456@2026-10-17 | MIPC 帧格式破解(magic/seq/msgid/txid/len; rsp=req+1+txid回显)+cells=0x23空请求→0x24载荷; ttyCMIPC 单开者语义+kill-9 楔端口陷阱; 判决实验: ql_ril_service 死后直连照常应答 — 守护可退的传输前提成立; v0.9 落地传输层+标定取证(输出仍 libqlril 回退, 行为零变化); 记录级解码(rsrp/sinr 编码)未竟, 见 FINDINGS §28 |
| `CLM-CELLS-DIRECT`@FINDINGS.md | ✅实证 | `gw/bin/mipc_cellular>=0.10` | cells 直连解码 (mipc_cellular 0x23→0x24 TLV) | 9b816ea@2026-10-17 | 反汇编还原 ql_ril_service 小区解码: TLV 层(tag/len 4对齐)+NR 记录 0xB8 布局+编码公式(rsrp=raw-156, sinr=raw/2-43)+0x4F 的 bw ASCII; 3 对新鲜样本逐字段验证; v0.10 直连主路径(多帧重组+libqlril 回退), 守护死亡态全 JSON 实弹; 顺带修旧 cells pci 错位 bug; 退役前置就绪(写路径 msgid 表在案); v0.16 实弹: 数组 tag 双变体 0x810b/0x010b(19 邻区响应用 0x010b, 旧码间歇 decode=-2; /tmp/cells_decode_fail.bin 原始载荷取证) |
| `CLM-RIL-ZERO`@FINDINGS.md | ✅实证 | `gw/rc_netfh.sh>=3.9, gw/bin/mipc_cellular>=0.12, gw/www/api_sms.sh>=1.1` | RIL 守护全退役 (ql_ril_service/netd/submonitor/netagent), 蜂窝写路径直连 (endc/setlock/unlock) | 88f81e6@2026-10-17 | RIL 四件套全退役: 读(cells/getbands)+写(setlock/endc/scan)+短信发送(AT+EMGS, 厂商同族)全部直连 MIPC; mipc_cellular v0.12 移除 libqlril(NEEDED 空); 硬教训: msgid 是 u16/TLV 步进 (4+len+7)&~7/大响应分帧须等齐/AT+EMGS 无负向测试余地(modem 不校验号码, 非法号也投递); 位映射修正旧 off-by-one(N41 曾锁到 N40) |
| `CLM-LOGGING-FINE`@FINDINGS.md | ✅实证 | `gw/log_keeper.sh>=1.3, gw/wan_agg.sh>=3.2, gw/watchdog.sh>=1.15, gw/bin/mipc_cellular>=0.13, gw/www/api.sh>=2.76` | 日志细粒度与 24h 持久化管线 (log_keeper v1.3 增量) | 9b816ea@2026-10-17 | 细粒度日志两级设计: 本文件自轮转(TICK/EVT/WARN/REPAIR/DRIFT)+log_keeper v1.3 增量追加(锚行定位/1MB 轮转/resync); 覆盖 wan_agg/wan_eth/ccmni_up/dial_keeper/rc_netfh/watchdog/led_mgr/api/mipc_cellular/wifi_autoch; 日志量约1-2MB/天; 凭证/短信内容/号码(仅末4位)脱敏 |
| `CLM-V3FIX-CORRUPT`@FINDINGS.md | ✅实证 | `gw/bin/v3_fix.ko>=1.2, gw/v3_rc10.extend.sh>=2.30` | v3_fix 内核模块在位 (TTL 伪装/RX 解绑) | b8812b7@2026-10-18 | 旧产物 ELF 节表错位 1B → 每次开机 insmod 静默失败(type 768), TTL 伪装/RX 解绑长期死亡; 由 syslog 镜像的 daemon.err 捕获; 重建(内核树+zig cc)实测 rc=0, wan_if 改全接口(承载口 ccmni2↔3 漂移), selftest t_v3fix_loaded 护栏 |

<!--CLMAUDIT:END-->
