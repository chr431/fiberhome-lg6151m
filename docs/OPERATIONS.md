# 运维手册 (OPERATIONS)

> v4 日常操作、部署纪律、救援路径、已知坑。

## 启动链（A 槽 v4）

```
LK(lk_a) → boot_a(RP0103 内核) → rootfs_a(v4: RP0103+定制) → preinit[babysitter]
  → rcS(v3 注释: 无 sysmgr/无 mipc 阻塞) → S98zz_data_hook → /data/rc.extend.sh
  → rc19(v3_rc10.extend.sh v2.15): br-lan/WiFi/拨号/聚合/GUI(v3httpd)/FH栈(webs_revive)
  → rc.local: dropbear(rc19 兜底自起) / S95done: touch markers
```

- 看门 babysitter：T1=180s 杀挂起 rcS，T2=360s 自动翻 B 槽
- `/tmp/rcS.done` `/tmp/boot.done` = 启动完成观测点

## 部署纪律（deploy.py）

```bash
python tools/vercheck.py check    # 版本注册表一致性(前置)
python tools/deploy.py push       # 只部署已提交状态; .sh 自动注入 #DEPLOY 戳
python tools/deploy.py doctor     # md5 双向 + 版本 + 漂移体检
python tools/deploy.py attic      # 设备侧流浪脚本归档
```

- 改动流程：改 → tools/VERSIONS.tsv 登记版本 → `vercheck render`（同步 ARCHITECTURE.md）→ commit → push
- 运行中的 ash 脚本内容相同不重推（busybox 惰性读取）
- agg_pins.conf（MAC 钉死表）**设备侧自管**，模板 `agg_pins.conf.example`

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
| 双槽皆坏 | UART + 全盘镜像恢复（D:\Repo\lg6151m\backup\mmcblk0.img.gz，md5 双向） |

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

## 日常观测点

- `/tmp/wifi_up.log`（AP 拉起 + 自动选道结果 `/tmp/wifi_autoch`）
- `/tmp/v3httpd.log`（GUI + FH 隧道流量，proxy REQ/RESP 行）
- `/tmp/wifi_guard.log`（BA stall 计数）、`/tmp/wagg.out`（聚合状态）
- `iotagtd` 云连接：`netstat -tnp | grep iotagtd`（应见 :9991 ESTABLISHED）
