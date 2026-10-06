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
| `docs/GUI_TERMINOLOGY.md` | **v1.1** | doc | `-` | GUI用户可见文案常设基准(v1.1: +终端频段锁定行+locked错误码; 访客隔离标注固定开启; 历史版本见git) |
| `gw/bin/fhstub.so` | **v1.0** | manifest | `/data/gw/fhstub.so` | FH符号桩库(顶掉vendor api库的生态依赖,仅ioctl路径) |
| `gw/bin/healthdog.ko` | **v1.0** | manifest | `/data/gw/healthdog.ko` | 取证看门狗内核模块(forensic=1) |
| `gw/bin/mipc_cellular` | **v0.5** | manifest | `/data/gw/mipc_cellular` | 蜂窝MIPC直连CLI(getbands/setlock/unlock; 锁NR41+79实弹验证零扰动) |
| `gw/bin/multiwan_ctl` | **v1.1** | manifest | `/data/gw/multiwan_ctl` | 原厂multiwan引擎ioctl控制器(zig动态链libfhdrv_net_api,36B结构体) |
| `gw/bin/shmsnap` | **v1.0** | manifest | `/data/gw/shmsnap` | cfgmgr树共享内存快照工具(save/load 16MB原始字节, gzip后127KB, 开机恢复锁定状态) |
| `gw/bin/v3_fix.ko` | **v1.1** | manifest | `/data/gw/v3_fix.ko` | TTL伪装/PPE解绑内核模块(wan_if/ttl_mode/unhook) |
| `gw/bin/v3_steth.ko` | **v1.0** | manifest | `/data/gw/v3_steth.ko` | hook槽位听诊器(bias/interval) |
| `gw/bin/v3httpd` | **v2.4** | manifest | `/data/gw/v3httpd` | 网关GUI HTTP服务(:80, 静态+JSON API) |
| `gw/bin/wpapmk` | **v1.0** | manifest | `/data/gw/wpapmk` | WPA口令转PMK(纯C PBKDF2-SHA1; fh魔改hostapd只吃wpa_psk) |
| `gw/capture_ubus.sh` | **v1.1** | manifest | `/data/gw/capture_ubus.sh` | stock拨号一次性捕获(ubus monitor+ccmni采样) |
| `gw/cellular_replay.sh` | **v2.1** | manifest | `/data/gw/cellular_replay.sh` | 蜂窝锁定开机重放(频段/小区锁到cfgmgr树, 树每次开机由出厂档案重建) |
| `gw/consfeed.sh` | **v1.0** | manifest | `/data/gw/consfeed.sh` | v2 控制台喂食器(无setsid,v2_access拉起) |
| `gw/defaults.conf` | **v1.3** | manifest | `/data/gw/defaults.conf` | 统一配置只读出厂基线(444); 消费方source叠加settings.conf稀疏覆盖 |
| `gw/dial_5g.sh` | **v1.2** | manifest | `/data/gw/dial_5g.sh` | 生产 5G 拨号器(check_ia+netagent补丁) |
| `gw/dial_keeper.sh` | **v1.0** | manifest | `/data/gw/dial_keeper.sh` | 拨号自持兜底守护(P2): ccmni无IP超35s→MIPC直连重拨(deact_apn+act_type配方实测result:0);退避15-300s;不经mobilenetwork |
| `gw/dial_variant.sh` | **v1.1** | manifest | `/data/gw/dial_variant.sh` | 5G 拨号参数变体实验器(iptype/apn/plmn/roam) |
| `gw/fan_mgr.sh` | **v1.3** | manifest | `/data/gw/fan_mgr.sh` | 原厂梯度温控风扇(v1.3: 配置统一overlay+修复v1.2双/data/gw路径bug——GUI静音切换从未生效的根因) |
| `gw/fan_mode.conf` | **v1.0** | manifest | `/data/gw/fan_mode.conf` | 风扇模式:performance|silent(静音+6°C偏移) |
| `gw/fw_apply.sh` | **v1.4** | manifest | `/data/gw/fw_apply.sh` | 端口映射/DMZ/禁网安装器(rc_netfh开机+api共用); v1.4(审计P0): +V6WANGUARD—IPv6 WAN面默认拒绝(INPUT/FORWARD, 放行ICMPv6/DHCPv6/established), 实测堵死WAN侧v6直连:22; v1.3: +22入封禁 |
| `gw/guest_fw.sh` | **v1.6** | manifest | `/data/gw/guest_fw.sh` | 访客隔离防火墙v1.6(审计P0: GUEST_ISOLATE开关删除=强制隔离; 兼容需求改由主WiFi终端频段锁定承接; 历史版本见git) |
| `gw/healthdog.sh` | **v1.1** | manifest | `/data/gw/healthdog.sh` | 看门狗用户态心跳 |
| `gw/led_mgr.sh` | **v1.7** | manifest | `/data/gw/led_mgr.sh` | 原厂风格LED守护(v1.7: 信标看门狗vif枚举动态化适配访客双频; v1.4传输层改sysfs gpio; v1.6 配置统一overlay+信标看门狗) |
| `gw/mipc_dial_trace.sh` | **v1.0** | manifest | `/data/gw/mipc_dial_trace.sh` | 5G 拨号取证(xtrace 抓真参) |
| `gw/night_report.sh` | **v1.0** | manifest | `/data/gw/night_report.sh` | 夜间体检报告 |
| `gw/ntp_keeper.sh` | **v1.0** | manifest | `/data/gw/ntp_keeper.sh` | 每小时NTP守时(ntclient多源; 设备无RTC) |
| `gw/radvd.conf` | **v1.0** | manifest | `/data/gw/radvd.conf` | IPv6 SLAAC+RDNSS通告(br-lan, ULA fd42:9ac1:7e50::/64) |
| `gw/rc.extend.sh` | **v1.9** | manifest | `/data/rc.extend.sh` | 槽位调度器(v1.9: +/etc/shadow bind覆盖钩子(只读rootfs下的凭据轮换通道, 审计P0-5前置); v1.7: A槽TRY_A自清+hnat_qos恢复+dropbear唯一属主; b=纯访问层,a=全栈) |
| `gw/rc_netfh.sh` | **v3.1** | manifest | `/data/gw/rc_netfh.sh` | 路线A: FH modem栈环境(最小army, MODE.fh门控; v2.1=atci对复活修L14回归) |
| `gw/udhcpc_eth1.script` | **v1.0** | manifest | `/data/gw/udhcpc_eth1.script` | eth1口 udhcpc 事件钩子(补登记) |
| `gw/udhcpc_wan.script` | **v1.0** | manifest | `/data/gw/udhcpc_wan.script` | WAN口 udhcpc 事件钩子(接口无关化) |
| `gw/v2_access.sh` | **v6.1** | manifest | `/data/gw/v2_access.sh` | v2 极简访问层(串口/SSH/DHCP/防火墙22,零守护干涉) |
| `gw/v3_babysit_v2.sh` | **v2.0** | manifest | `/data/gw/babysit_v2.sh` | 启动保姆(T1杀rcS/T2核爆回B) |
| `gw/v3_rc10.extend.sh` | **v2.19** | manifest | `/data/gw/rc19.sh` | v3 启动编排 rc19v2(br-lan+wifi+wan+DNS; v2.5网口对调; v2.6/2.7 eth1 MAC钉死+归因修正) |
| `gw/wan_agg.sh` | **v2.18** | manifest | `/data/gw/wan_agg.sh` | 双上行聚合主管(v2.17: v4免插件配方(statistic插件缺libxtables.so.12/mac插件不存在——v4分流自精简启动以来从未生效): 源端口区间分流(v6同款)+钉死改源IP(邻居解析+漂移重建); v2.15: 聚合总开关ENABLE=0旁路/1参战, 热切+GUI agg_mode; 照抄原厂quecadp内核分流+fwmark路由; v1.7 to-LAN护盾规则自愈(全灭黑洞终根因) |
| `gw/watchdog.sh` | **v1.4** | manifest | `/data/gw/watchdog.sh` | 持续不变量看门狗(L13: 17项不变量; v1.2/L14: +蜂窝控制面 atcid自愈+CFUN探针+注册态, airplane容忍) |
| `gw/webs_revive.sh` | **v1.3** | manifest | `/data/gw/webs_revive.sh` | 原厂GUI复活器(自足nginx conf; 手动拉起) |
| `gw/wedge_watch.sh` | **v1.0** | manifest | `/data/gw/wedge_watch.sh` | 串口wedged值守望器(补登记) |
| `gw/wifi_guard.sh` | **v1.0** | manifest | `/data/gw/wifi_guard.sh` | BA/TX 停滞自动恢复守卫 |
| `gw/wifi_up.sh` | **v1.26** | manifest | `/data/gw/wifi_up.sh` | mt7992 AP 工厂配方(v1.26: 终端频段锁定band_pins.conf→对侧频段main BSS deny ACL(macaddr_acl=0+deny_mac_file, 指令支持已实证); 无pin时conf与v1.25逐字节一致; 历史版本见git) |
| `gw/www/api.sh` | **v2.47** | manifest | `/data/gw/www/api.sh` | GUI JSON端点(v2.47(审计P0): login失败锁定10次/15分钟(locked码); wifi_set auth补白名单堵settings.conf注入; gw_set拒控制字符; 访客隔离强制删开关+残留键清理; +band_pin/band_pin_add/band_pin_del终端频段锁定; 历史版本见git) |
| `gw/www/app.js` | **v3.30** | manifest | `/data/gw/www/app.js` | 控制台SPA(v3.30: 访客隔离开关移除(强制隔离); +终端频段锁定卡(添加/删除/应用变更); +locked错误码; 历史版本见git) |
| `gw/www/index.html` | **v2.16** | manifest | `/data/gw/www/index.html` | v3控制台页面(v2.16: 缓存v50) |
| `gw/www/style.css` | **v2.1** | manifest | `/data/gw/www/style.css` | 控制台主题 |
| `gw/zz_data_hook` | **v1.1** | manifest | `/data/build/rootfs/etc/init.d/zz_data_hook` | S98数据钩子(v1.1: plain sh——原厂无/etc/rc.common, rc.common式shebang致开机栈全灭; 回归实测发现) |
| `gw/src/fhstub.c` | **v1.0** | src | `gw/bin/fhstub.so` | FH符号桩库源码 |
| `gw/src/healthdog.c` | **v1.0** | src | `gw/bin/healthdog.ko` | 看门狗模块源码(版本随产物) |
| `gw/src/mipc_cellular.c` | **v0.5** | src | `gw/bin/mipc_cellular` | 蜂窝MIPC直连CLI源(P1): dlopen闭包预载+ql_nw_init; v0.2: 168B结构全破译(setlock lte/nr=列表 解锁=全1; NR三段位图1-32/34-64/65-96) |
| `gw/src/multiwan_ctl.c` | **v1.1** | src | `gw/bin/multiwan_ctl` | multiwan控制器源码(随产物1.1) |
| `gw/src/shmsnap.c` | **v1.0** | src | `gw/bin/shmsnap` | cfgmgr快照源码 |
| `gw/src/v3_fix.c` | **v1.1** | src | `gw/bin/v3_fix.ko` | TTL/解绑模块源码(版本随产物) |
| `gw/src/v3_steth.c` | **v1.0** | src | `gw/bin/v3_steth.ko` | 听诊器模块源码(版本随产物) |
| `gw/src/v3httpd.c` | **v2.4** | src | `gw/bin/v3httpd` | GUI HTTP服务源码(公开版经zig重编译) |
| `gw/src/wpapmk.c` | **v1.0** | src | `gw/bin/wpapmk` | WPA PMK转换源码(纯C PBKDF2) |
| `install/run.sh` | **v1.1** | tool | `-` | raw shell自驱脚本(v1.1: 分区次设备号从/proc/partitions动态解析成布局门禁, RP102/RP103通用; v1.0硬编码259:7等) |
| `tools/agg_pins.conf.example` | **v1.1** | tool | `-` | MAC钉死表模板(真实表设备侧自管, 含个人MAC不入库) |
| `tools/build_healthdog.sh` | **v1.0** | tool | `-` | healthdog.ko内核模块构建(内核树) |
| `tools/build_mipc_cellular.sh` | **v1.0** | tool | `-` | mipc_cellular构建(zig cc aarch64-musl动态) |
| `tools/build_steth.sh` | **v1.0** | tool | `-` | v3_steth.ko构建 |
| `tools/build_v3fix.sh` | **v1.0** | tool | `-` | v3_fix.ko构建 |
| `tools/build_v3httpd.sh` | **v1.0** | tool | `-` | v3httpd构建(zig cc aarch64-linux-musl全静态, 同mipc_cellular链) |
| `tools/deploy.py` | **v2.10** | tool | `-` | MANIFEST部署/漂移检查(版本注入+预检); v2.10: connect凭证链env覆盖(LG_HOST/LG_TOOR_USER/LG_TOOR_PASS优先, 与lgssh对齐)——轮换窗口期rotate_toor注入旧口令的依赖; 历史版本见git |
| `tools/device_local.py.example` | **v1.0** | tool | `-` | 凭证模板(真件gitignored) |
| `tools/doc_audit.py` | **v1.1** | tool | `-` | 台账↔文档内联标记双向审计(v1.1: 标记扫描纳入台账引用的docs/外文档如install/README.md; v1.0: 版本绑定+TEST-MISSING/STALE-CODE/UNREGISTERED-CLAIM) |
| `tools/gen_kernel_inc.py` | **v1.0** | tool | `-` | kernel头生成(构建辅助) |
| `tools/health_check.py` | **v1.1** | tool | `-` | v4全系统体检器(SSH 18项; v1.1 fw_ver读/data/gw/VERSIONS: 身份/槽位/bootctrl/服务/WiFi/5G/外网/资源/温度/存储/数据/日志) |
| `tools/identify2.py` | **v1.0** | tool | `-` | 残留终验取证器(user_data清单/p26纯净性挂载验证/proc-net快照) |
| `tools/identify_fw.py` | **v1.0** | tool | `-` | 只读固件身份取证器(release/cmdline/v4标记/挂载表; 前置空格防tty首字符丢失) |
| `tools/leak_check.py` | **v1.1** | tool | `-` | 敏感词+设备MAC零命中门禁(工作树+可选全历史; 建议pre-push) |
| `tools/lgssh.py` | **v1.2** | tool | `-` | SSH助手(env/_local/secrets凭证; run()命令通道; v1.2凭证目录解析LG_SECRETS_DIR) |
| `tools/lk_eth1_resume.py` | **v1.1** | tool | `-` | eth1续链器(LK控制台接管: kcmdline已注入态恢复; 含misc回退现场抓取; 补登记) |
| `tools/lk_flash_v4.py` | **v1.1** | tool | `-` | v1.1路径随项目根迁移; 终版刷入器(LK陷阱→raw shell→/dev/null修复→curl送deploy2.sh→后台自驱+轮询deploy.log→重启监测; 修三雷: uclient罢工/&需/dev/null/串口前台等待吃首字符) |
| `tools/lk_flash_v4_eth1.py` | **v1.1** | tool | `-` | v1.1路径随项目根迁移; eth1刷入实证器(全链条: 陷阱→raw shell→eth1起链[历史疑点:PHY仅ifup后attach]→curl传输→deploy2自驱→重启回v4.1) |
| `tools/lk_flip2.py` | **v1.1** | tool | `-` | LK 一键翻槽(a|b, misc[2060]字节) |
| `tools/lk_write.py` | **v1.6** | tool | `-` | LK raw-shell 文件写入(回显校验+tmpfs挂载+cmdlist巡检, 取代lk_fix_access) |
| `tools/rotate_toor.py` | **v1.2** | tool | `-` | toor口令轮换器(只读rootfs shadow覆盖通道); v1.2: 投递改本会话直投(deploy.put同款协议; 子进程方式在轮换窗口期不可靠)+去掉%TEMP%残件; v1.1: md5独立校验 |
| `tools/run_serial_server.sh` | **v1.0** | tool | `-` | 串口控制台守护拉起器 |
| `tools/selftest.py` | **v2.11** | tool | `-` | 断言式全功能测试(v2.11: 访客隔离断言改无条件—开关已删; 历史版本见git) |
| `tools/serial_cmd.py` | **v1.3** | tool | `-` | 串口命令瘦客户端(marker输出捕获; v1.3示例路径更新) |
| `tools/serial_server.py` | **v1.7** | tool | `-` | 常驻串口控制台守护(:7717, 唯一登录驱动; v1.7凭证外置_local/secrets) |
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
| `CLM-P4-SSE`@ROADMAP.md | ✅实证 | `gw/bin/v3httpd>=2.4` | SSE 信号事件流 (v3httpd v2.4 + api.sh sse) | ecb2e20@2026-10-06 | SSE信号推送落地: 流式CGI通道+3s事件+EventSource前端, curl/selftest双验证; P4全数完成 |
| `CLM-P5-CLOSED`@ROADMAP.md | ✅实证 | `tools/selftest.py>=2.9` | SSE 信号事件流 (v3httpd v2.4 + api.sh sse) | ecb2e20@2026-10-06 | P5关闭: 实测传输期CPU空转,瓶颈在上游非引擎; quecadp复活=高风险零收益; 重开条件=>500Mbps上游+softirq饱和 |
| `CLM-AGG-MODES`@ROADMAP.md | ✅实证 | `gw/wan_agg.sh>=2.18` | 聚合模式配置合法且一致 (v2.18 五模式) | 3aaf20b@2026-10-06 | 聚合五模式(对齐原厂): weight/cell_prio/eth_prio/cell_only/eth_only; 仅模式=E1/E2强制注入(无failover); MODE热载+旧格式迁移(100/0映射优先模式); 滑块5-95钳制(极端值语义归显式模式); GUI权重卡条件显示; 五模式API实弹循环切换全过 |

<!--CLMAUDIT:END-->
