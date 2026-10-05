# 安装套件（原厂固件 → 自定义固件）

把一台**原厂 RP0103 固件**的 LG6151M 刷成自定义固件。全程不需要原厂系统的
任何漏洞利用：利用 BootROM→LK 阶段串口可注入 `init=/bin/sh` 的调试特性进入
raw shell，设备自行从 PC 拉取套件、用**你自己的 B 槽原厂树**构建镜像并刷入
A 槽。B 槽全程不动，随时可切回原厂。

> 刷机有风险。首次操作前请先备份（本套件不代替备份）。设备需能进 LK 串口
> （COM 口 @921600）。

## 前置

- PC：Python3（`pip install pyserial`）、有线网卡（与设备 eth0/eth1 直连，
  自动分配 169.254.x.x 链路本地地址）、串口线接设备调试口
- 设备：原厂固件正常开机（B 槽原厂树将作为镜像底座）

## 流程

```sh
# 0) 生成套件（PC, 在仓库根）
python install/make_payload.py       # /data 载荷（从本仓 MANIFEST 生成）
python install/make_kit.py           # 组装 kit.tar.gz + MANIFEST.md5

# 1) 起 depot（PC, install/ 目录, 供设备 curl 拉取）
cd install && python -m http.server 8931

# 2) 设备进 raw shell（串口终端, 921600 8N1）
#    断电重上电, 开机瞬间连续 Ctrl-C 抓 LK 提示符, 然后依次:
#      kcmdline append init=/bin/sh
#      repeat 2000 heap alloc 65536
#    设备落入 `~ #` raw shell（不要让它继续正常启动）

# 3) 一键刷入（PC, 新开终端）
python install/lk_flash.py COM6
#    口令: 默认取 _local/secrets/device_local.py 的 TOOR_PASS(即自定义固件的
#    root 口令), 也可 --toor-pass 指定或设 LG_TOOR_PASS
```

脚本会：预检 kit md5 → 串口 kick 设备拉取套件（设备侧再校验一次 md5）→
后台自驱：解包 ipk → 还原 /data 载荷 → 从 B 槽原厂树构建镜像 → 门禁校验
（p26 挂载验证：rcS 锚点/root 账户/S98 钩子/无 S99zmtk）→ 写 bootctrl 翻 A
并读回 `0f 03` → 重启。**任何门禁失败都不会动 bootctrl**，B 槽原厂保持可用。

## 开机后

- SSH：`toor@192.168.9.1`（口令 = 步骤 3 提供的 TOOR_PASS）
- 管理界面：<http://192.168.9.1/>（首次使用前按 `docs/OPERATIONS.md` 设置
  管理口令）
- 回原厂：切 bootctrl 回 B 槽（见 `docs/OPERATIONS.md`）

## 套件文件

| 文件 | 作用 |
|---|---|
| `make_payload.py` | 从仓库 MANIFEST 生成 `/data` 载荷 tar |
| `make_kit.py` | 组装 `kit.tar.gz`（含逐件 md5 清单） |
| `build_image.sh` | 设备端：B 槽原厂树 + 载荷 → 自定义镜像（口令哈希现场生成） |
| `flash.sh` | 设备端：门禁刷入 + bootctrl 翻转 |
| `run.sh` | 设备端编排（ipk → 载荷 → 构建 → 刷入） |
| `lk_flash.py` | PC 端串口驱动 + depot 预检 + 重启监测 |
| `ipk/` | 设备端构建依赖（squashfs-tools/liblzma/libzstd） |

`payload.tar.gz`、`kit.tar.gz`、`MANIFEST.md5` 为构建产物，不入库。
