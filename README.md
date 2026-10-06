# FiberHome LG6151M 5G CPE — 自定义固件与研究

> 对自有 FiberHome LG6151M 5G CPE（MediaTek T830/MT6990, mt7992 WiFi7, kernel 5.15.134）
> 的完整逆向 + 自定义固件工程。当前形态：**v4 = 原厂 RP0103 底座 + 自有飞行层**，
> A/B 双槽（A=v4 自定义 / B=原厂完好），两个字节可切回。
>
> 必读三件套：[docs/OPERATIONS.md](docs/OPERATIONS.md)（日常运维）·
> [docs/FINDINGS.md](docs/FINDINGS.md)（逆向发现总集）·
> [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)（架构 + 版本总表）。
> 深挖参考：[docs/VENDOR_MAP.md](docs/VENDOR_MAP.md)（原厂 RP0103 全量逆向地图）·
> [docs/FEATURE_MATRIX.md](docs/FEATURE_MATRIX.md)（原厂 vs 自研功能对比）·
> [docs/ROADMAP.md](docs/ROADMAP.md)（替换路线图 v2）。

> **免责声明**：全部研究在本人自有设备上进行。请勿对不属于自己的设备使用文中任何方法。
> 刷机有变砖风险，操作前务必全盘备份。

## 当前系统能力（v4）

| 域 | 能力 |
|---|---|
| 双上行聚合 | 5G 蜂窝 + 有线宽带双活，原厂 quecadp 内核引擎按流分流（40/60 热调），主备模式（100:0/0:100 待命秒切），MAC 钉死表，故障切换实测 0 丢包 |
| Web GUI | 自研 SPA（192.168.9.1:80，v3httpd 静态+JSON API，35+ 端点）：状态/设备/WiFi/网络/蜂窝/短信/聚合/上行认证/系统 九页 |
| WiFi | hostapd 接管安全层（原厂 hwifi WPA 引擎在 MLD 组网下损坏）；统一 SSID 命名；启动自动选道（扫描评分）；仿 WiFi Analyzer 四视图分析仪（157 AP 实测）；访客网络/双频合一 |
| 烽火终端 App | 可选：webs_revive.sh 手动拉起（默认不自启，外围裁剪）· NDMP 本地控制链路保持 |
| 网络工具 | 端口转发/DMZ/黑名单（fw_apply）、DHCP 静态租约、NTP 守护、可插拔上行认证（AUTHD_CMD 任意认证程序）、MAC/TTL 伪装 |
| 运维 | deploy.py 单一事实源部署（版本注册表 + md5 漂移体检）、看门 babysitter（T1 杀挂起 rcS / T2 自动翻槽）、串口翻槽器 lk_flip2 |

## 快速上手

```bash
cp device_local.py.example device_local.py   # 填自己设备参数(已gitignore); 或用 LG_* 环境变量
pip install paramiko
python tools/deploy.py doctor               # 部署漂移体检
python tools/deploy.py push                 # 部署(仅接受已提交状态)
python tools/lgssh.py "uptime"              # SSH root 助手
```

### 首次刷入的 GUI 默认口令

从纯原厂固件直刷本固件后，Web 管理界面初始口令为 **`lg6151m`**，WiFi 初始密码 **`lg6151m0`**（首次登录时自动建档，
GUI 会弹窗强制提醒修改）。固件不预置任何隐藏口令：口令文件 `/data/gw/gui_auth.conf`
只由 GUI 的"修改密码"动作写入；改密表单带二次确认。SSH(toor)口令在**构建时**随机生成
并注入镜像，不与 GUI 口令共用。管理面仅限 LAN：GUI 只绑 LAN IP，SSH/厂商遗留端口在
WAN 侧被 V3WANGUARD 规则链常备拦截。

## 攻破路径（精简时间线，详见 docs/FINDINGS.md）

1. Web API 加密体系完全还原（RSA token + 厂商 Lua AES 派生），可编程登录
2. 五类凭据发现（superadmin 固件常量 / telnet 规则 / shadow root / SMS 注入 root / 沙箱逃逸读取）
3. 全盘备份（eMMC 3.66GiB, 46 GPT 分区, md5 双向校验）
4. LK 串口劫持（Ctrl-C 陷阱 + kcmdline init=/bin/sh + 堆耗尽逃逸）→ bootctrl 两个字节切槽
5. v3 = RP0102 底座 + 飞行层 → v4 = RP0103 底座 rebase（内核/modem P56/用户态全套）

## 切槽速查

bootctrl 位于 misc 分区（`/dev/mmcblk0p1`）偏移 2060 共 10 字节：
`A(pri,try,succ,up) gap B(pri,try,succ,up)`

| 动作 | 字节 |
|---|---|
| 切到自定义槽 A | `0f 03 00 00 00 0e 00 01 02 00` |
| 切回原厂槽 B | `0e 00 00 00 00 0f 00 01 01 00`（自动翻槽器：`python tools/lk_flip2.py COM6 a`） |

## 仓库内容

```
v3_rc10.extend.sh      启动编排 rc19（全部守护进程拉起，v3/v4 通用）
wifi_up.sh             AP 拉起（apcfg 工厂配方 + hostapd 安全面 + 自动选道）
wan_agg.sh             双上行聚合监督器
www/                   自研 GUI（index.html + app.js + style.css + api.sh）
build_v4.sh            RP0103 rebase 构建（设备上执行）
tools/                 部署/救援/逆向工具集（deploy.py, lk_flip2.py, lgssh.py...）
docs/                  FINDINGS(发现总集) / OPERATIONS(运维) / ARCHITECTURE(架构) / 各专题
received/              RP0103 提取镜像(gitignore, 详见 FINDINGS)
rootfs_b/ analysis/    原厂 rootfs 解包与取证材料（公开发布时需剔除, 见 tools/make_public_export.py）
device_local.py.example  设备参数模板（真实文件已 gitignore）
```

## 环境变量（凭证不进仓库）

| 变量 | 用途 |
|---|---|
| `LG_HOST` / `LG_TOOR_USER` / `LG_TOOR_PASS` | SSH 访问（缺省回退 device_local.py） |
| `LG_WEB_PASS` | Web 管理密码（工具脚本用） |
| `UPLINK_IP` / `UPLINK_GW` / `UPLINK_MASK` / `UPLINK_MAC` / 认证凭证 | 静态上行/认证程序参数（uplink.conf） |

型号绑定值（原厂固件常量与自研固件内置凭证，如 superadmin/toor）按设计保留在文档中。

## 相关工作

- [codming.com — 烽火 LG6121F 研究](https://codming.com/posts/fiberhome-lg6121f-5g-cpe-research/)：加密体系/凭据规则原型
- [xxtg666 — FiberHome-LG6851F-SMS-Forward](https://github.com/xxtg666/FiberHome-LG6851F-SMS-Forward)：加密登录参考实现
- 恩山无线论坛 烽火 5G CPE 系列帖

## 许可

自有代码 MIT（见 LICENSE）。仓库中引用的原厂固件解包材料（rootfs_b/、reference/、ref*.js 等）
版权归 FiberHome，仅供研究，公开发布版不含（`tools/make_public_export.py` 生成净化导出）。
