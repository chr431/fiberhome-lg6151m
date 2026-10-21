# 运维手册 (OPERATIONS)

> v4 日常操作、部署纪律、救援路径、已知坑。

## 启动链（A 槽 v4）

```
LK(lk_a) → boot_a(RP0103 内核) → rootfs_a(v4: RP0103+定制) → preinit[babysitter]
  → rcS(v3 注释: 无 sysmgr/无 mipc 阻塞) → S98zz_data_hook → /data/rc.extend.sh
  → rc19(v3_rc10.extend.sh v2.15): br-lan/WiFi/拨号/聚合/GUI(v3httpd)/FH栈(webs_revive)
  → rc.local: dropbear(rc19 兜底自起) / S95done: touch markers
```

- 启动判据（v2.34/batch2 起）：`boot_gate.sh` 实测关键链
  （LAN IP + lo UP + dropbear:22 + dnsmasq:53 + v3httpd:80 + rc19 完成）通过才写
  `/tmp/boot.done`；全通过写 `/data/gw/boot.healthy`（10 分钟后 `stable=1`）并在
  读回校验下清 LK `TRY_A`。失败则 marker 缺席、TRY_A 保留，LK 计数累积到回 B。
- 看门 babysitter v3.0：T1=240s 且**无进展 120s** 才杀挂起子进程（rcS/mipc_wan_cli）；
  T2=600s 且仍无进展才翻 B（有进展则延到 900s 硬帽）；dropbear :22 仍在监听时
  **抑制翻槽**并留痕。决策落 `/data/gw/logs/boot_babysit.log`。
- 内核 wedge 复位（healthdog.ko）在 `boot.healthy stable=1` 后自动 arm；armed 期间
  **重启/停掉 healthdog 必须先恢复心跳**（v1.4 已自动处理）。应急：
  `(while :; do echo hb > /proc/healthdog; sleep 10; done) &`
- `/tmp/rc19.done` `/tmp/boot.done` `/data/gw/boot.healthy` `/tmp/boot.progress` = 启动观测点
  （`boot_gate.sh --status` 可一键查看）

## 部署纪律（deploy.py）

```bash
python tools/vercheck.py check    # 版本注册表一致性(前置)
python tools/deploy.py push       # 只部署已提交状态; .sh 自动注入 #DEPLOY 戳
python tools/deploy.py doctor     # md5 双向 + 版本 + 漂移体检
python tools/deploy.py attic      # 设备侧流浪脚本归档
```

- 改动流程：改 → tools/VERSIONS.tsv 登记版本 → `vercheck render`（同步 ARCHITECTURE.md）→ commit → push
- batch3 起 `gw/svc_lib.sh` / `gw/netlock.sh` 是守护与写方的公共库，MANIFEST 顺序
  保证它们先于消费者落地；运行中的守护仍持旧函数，升级后需重启才生效。
- 运行中的 ash 脚本内容相同不重推（busybox 惰性读取）
- agg_pins.conf（MAC 钉死表）**设备侧自管**（`deploy.py` 的 `EXTRA_KEEP`：不进部署清单、
  不参与体检比对 —— 含个人 MAC，避免"仓库空版本覆盖设备真钉死"）。
  出厂只读基线 `gw/agg_pins.default`（**不含任何 MAC**）随版本部署；wan_agg 启动时
  **缺省才写**地播种活文件，已有钉死永不覆盖。格式说明与用法示例见 `tools/agg_pins.conf.example`。

## WiFi 健康判据与手动恢复

- **唯一判据 = 活控制套接字**：`svc_live_socks`（`/proc/net/unix` 里有
  `/var/run/hostapd/ra0|rai0` 的活端点）+ 自有 hostapd 进程（argv[0] hostapd、
  参数含 `/var/wlan/hap_*.conf`）。以下**都不算**服务在线：
  `pidof hostapd`（会命中厂商 global 实例）、`[ -S /var/run/hostapd/ra0 ]`
  （崩溃后文件残留）、`iw dev ... type AP`（驱动保持 AP 模式）、netdev operstate。
- 快查：`hostapd_cli -i ra0 status; hostapd_cli -i rai0 status`（都应为
  `state=ENABLED`）；GUI WiFi 卡片的"2.4/5GHz 正常"与 WiFi 灯均取同一判据。
- 手动恢复（watchdog 会自动做，以下用于人工兜底）：
  ```sh
  . /data/gw/svc_lib.sh
  for p in $(svc_our_hostapd); do kill "$p"; done
  rm -f /var/run/hostapd/ra0 /var/run/hostapd/rai0      # 崩溃残留必须清
  for v in ra0 rai0; do ifconfig $v down; done; sleep 3
  brctl addif br-lan ra0; brctl addif br-lan rai0
  LD_LIBRARY_PATH=/fhrom/lib:/usr/lib:/lib       hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf
  sleep 5; for v in ra0 rai0; do mwctl dev $v set no_bcn 0; done
  ```

## 大文件传输（SSH 大块不稳）

1. PC 起 depot：`cd <dir> && python -m http.server 8000`
2. 设备拉：`wget -O /tmp/x http://<PC>:8000/<path>`（**显式 -O + md5 校验**，静默失败常见）
3. 设备推 PC：PC `python tools/recv_server.py 8888` + 设备 `curl -T file http://<PC>:8888/file`

## 救援路径（按严重度）

| 症状 | 动作 |
|---|---|
| 服务挂/ WiFi 死 | `sh <数据目录>/wifi_up.sh`；wifi_guard 自动 BA-stall 恢复 |
| SSH 不通 GUI 通 | GUI 系统页重启；或 serial_cmd.py（serial_server.py :7717 自动登录） |
| 整机死 | 断电重启；babysitter 保证最坏 6 分钟自动翻 B |
| A 槽起不来 | `python tools/lk_flip2.py COM6 b`（串口 921600；流程：陷阱→kcmdline→堆耗尽→写 bootctrl→sysrq-b） |
| 双槽皆坏 | UART + 全盘镜像恢复（D:\Repo\lg6151m-project\lg6151m\backup\mmcblk0.img.gz，md5 双向） |

**串口注意**：CH340 拔插后 COM 口可能进坏状态（重复打开失败）→ 物理重插；
强杀持有进程会 wedge 驱动，用 serial_server 的 QUIT 优雅退出。

## 固件升级（FOTA）

- 云端会推升级（RemoteUpgradeEnable=1 时）。**实验/自定义期间保持 =0**：
  `cfg_cmd set InternetGatewayDevice.X_FH_IotagtdConf.RemoteUpgradeEnable 0`
- 升级落 B 槽（A/B 架构），刷后设备重启进原厂新版本 → lk_flip2 翻回 A 即可，
  顺手 dd 提取新镜像（参考 RECON "RP0103 固件获取"节）
- rebase 到新版：`build_v4.sh` 模式（挂 p39 取树 → 全套定制 → mksquashfs → 刷 A），
  mksquashfs 工具链经 depot 推 squashfs ipk 解包

## 已知坑（操作红线）

- **rootfs_a 被 dd 重写后严禁 drop_caches**（自毁运行视图，只能断电）
- 修改 wifi.conf 后由 wifi_up.sh 派生实际 SSID（勿手改派生值）
- 160MHz 选项已通配置链但射频被驱动钳 80（wifimgr 逆向中）
- CMGS 交互式 AT 会毒化 ril（需 sysrq-b 恢复）→ 短信发送未启用
- 上行认证守护按 AUTHD_CMD 配置运行（现场 EAP 类认证建议先在测试口验证）

## 守护拓扑（2026-10-17 架构轮拆分后）

- 已下架：cfgmgr / logmgr（树不经守护，shm 由 cfg_tool 建立；rc_netfh v3.0）
- 已下架：cfgmgr / logmgr / **mobilenetwork**（树翻译层；自研拨号 mipc 直连 +
  dial_keeper 已接管，2026-10-17 实查确认不在运行）/ cfg 树整体（KEEP_TREE=0）/
  **mtk_netagent**（ccmni IP 执行者；2026-10-17 摘除试验实证身份，职能由自研
  ccmni_up.sh 承接，rc_netfh v3.7 开机 service delete 退役）
- 仍在跑的原厂件（RIL 瘦身后仅存）：ccci 三件（modem 生命线）/ ql_ril_service
  （不可约：mipc_cellular cells 数据源，拔管实证）/ atcid 对（AT 通道）/
  thermal_core（modem 温控）。ql_netd/mipc_submonitor/mtk_netagent 已退役
  （2026-10-17 拔管实验，零依赖实证）
- 自研：dial_keeper（拨号兜底, 35s 宽限）· watchdog v1.12（不变量+自愈, 含
  wan_eth/led_mgr/log_keeper 兜底拉）· v3httpd/api.sh（路由核心 + 六域模块
  `www/api_{sys,wifi,lan,agg,cell,sms}.sh` 按端点懒加载）· wan_agg v3.0
  （探活+FSM+主路策略; 引擎落地层 source `wan_agg_lib.sh`）· wan_eth v1.0
  （eth0 租约/NAT/路由看门狗, 自 ensure_lease 拆出, rc19 先于 wan_agg 拉起）·
  wifi_up/hostapd（MAC 派生 `wifi_macplan.sh` / 自动选道 `wifi_autoch.sh`
  已拆出为独立可复用件）
- 首刷默认：WiFi `LG6151M`/`lg6151m`，GUI `lg6151m`（均见 install/README）

## 日常观测点

- `/tmp/wifi_up.log`（AP 拉起 + 自动选道结果 `/tmp/wifi_autoch`）
- `/tmp/v3httpd.log`（GUI + FH 隧道流量，proxy REQ/RESP 行）
- `/tmp/wifi_guard.log`（BA stall 计数）、`/tmp/wagg.out`（聚合状态）
- `/tmp/wan_eth.log`（eth0 租约/看门狗动作）、`/tmp/wan_agg.log`（FSM/主路/模式热载）
- `iotagtd` 云连接：`netstat -tnp | grep iotagtd`（应见 :9991 ESTABLISHED）
- batch3 观测：`/data/gw/logs/stability_metrics.tsv`（5min 长期指标：logc 帧/异常/
  崩溃、repairs_1h、load/MemAvailable）；`/data/gw/logs/netcfg_repairs.tsv`
  （每次路由/防火墙补装 epoch/what/rc/verified）；`/tmp/netcfg_lock_timeouts`
  （写方争用超时计数，健康时应为 0 或空）。
- logc 自检：`/data/gw/bin/logc --selftest`、`/data/gw/bin/logc --fuzz 200`；
  ASAN 版在 PC/Linux 侧 `sh tools/build_logc.sh --asan`（不入设备）。
