# 调试专用环境（debug mode）与第五轮判据

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

日期：2026-10-30 10:15–11:00　设备：LG6151M（本轮结束时已恢复生产模式）

## 1. 为什么要它（用户方案的正确性）

生产固件里 NE 速率被大量无关活动调制（WiFi 打印、拨号、aee、温度守护…），单窗 A/B 完全不可信
（本轮实测：同一套受害者 60 s 内 2 起 vs 13 起）。所以需要一个"去干扰"环境。

**不需要重刷镜像**：`/etc/init.d/zz_data_hook` 会在开机时执行 `/data/rc.extend.sh`，而 `/data` 可写。
因此把"调试固件"实现为**开机叠加层**：可持久、可一键撤销、不动 squashfs。

## 2. 实现（已落地）

| 文件 | 作用 |
|---|---|
| `/data/debugmode.sh` | 开关式调试环境（见下） |
| `/data/rc.extend.sh` 末尾 3 行 | `[ -f /data/debugmode.sh ] && sh /data/debugmode.sh &` |
| `/data/DEBUGMODE` | 存在 = 进入调试模式；删除 = 回生产 |

`debugmode.sh` 做的事：
1. `mount --bind /dev/null` 覆盖 10 个厂商守护的二进制（ccci_fsd / ccci_mdinit / ccci_rpcd_com /
   aee_aed / atcid / thermal_core / scd / ql_ippt / powerkey_daemon / logd）⇒ procd 再也拉不起来；
2. 杀掉已在跑的实例；停掉我们自己的 dial_keeper/wan_eth/wan_agg/wifi_guard；
3. 拉倒 eth0 / ra0 / rai0 / apcli* / 全部 ccmni（**保留 br-lan + eth1 + dropbear**，SSH 不断）；
4. 启动受害者舰队（`/data/repro/fleet_dbg.sh`）。

**开关**：`touch /data/DEBUGMODE && reboot` 进入；`rm /data/DEBUGMODE && reboot` 退出。
实测：调试模式下 `ccci_fsd|aee_aed|thermal_core` 计数 = 0、无 ccmni 地址、SSH 正常。

## 3. 本轮用它得到的判据

| # | 实验 | 结果 | 判定 |
|---|---|---|---|
| 1 | 调试模式（零厂商用户态、无拨号、无 WiFi）下跑 6 个受害者 | **仍崩**，约 2 起/min | **写入者不需要任何厂商用户态** ⇒ 纯 AP 内核路径，不是守护进程触发的 |
| 2 | `10011000.dpmaif` sysfs unbind | 6 起 / 247 s（≈1.5/min），**与基线同量级** | 记录里出现的 dpmaif 寄存器**不是写入者** |
| 3 | CPU 亲和性（`/proc/interrupts` 显示 mmc/CCIF/usb 全在 CPU0） | 绑 CPU0 / 绑 CPU1 / 再绑 CPU0 = **1 / 1 / 1** | 写入者**不是**绑在 CPU0 上的那个 IRQ |
| 4 | WiFi（hostapd）开 vs 关，各 300 s、16 个受害者 | **7 起 vs 1 起** | WiFi 活动把速率放大约 **7×**，但**不是必需**（关掉仍会崩） |
| 5 | 内核线程是否有 mm（`use_mm` 特征） | **0 个**内核线程带 mm | 排除"`kthread_use_mm` 的内核线程做用户拷贝" |

结合上一轮（§4）的三条硬判据：**写入经用户页表、不经线性映射、不经物理地址**，
现在的画像收敛为：

> **纯 AP 内核路径，在受害者 mm 处于 current 但受害者未执行内核代码的上下文里，
> 对受害者栈上的 `va_list` 做一次 32 字节用户拷贝；该路径被 WiFi 活动显著放大。**

## 4. 仍未闭环

具体函数。剩余可走的两条路：
1. **在调试模式下做 IRQ/软中断级排除**：把 mmc / usb / CCIF / WiFi 的 IRQ 逐个 mask（需要模块写 GIC），
   看速率是否归零——本轮已验证 CPU 亲和性无关，所以要先确认"到底是不是 IRQ 上下文"；
2. **拿到 vendor 内核源码**后直接搜 `copy_to_user` 的调用者（记录里 dpmaif 寄存器说明大概率在 ccci/dpmaif 的调试面上，
   但 dpmaif unbind 无效说明是**另一条**共用该数据源的路径）。

## 5. 方法论教训（并入 §7）

28. **"调试固件"不必重刷**：`zz_data_hook → /data/rc.extend.sh` 已经是现成的持久钩子；
    `mount --bind /dev/null <bin>` 是禁用一个厂商守护最干净的办法（procd 拉不起来，且重启即复原）。
29. **禁用守护后要复核内核侧**：ccmni/ra0 这些 netdev 是**驱动 probe 时**建的，守护死了它们仍在；
    "没有 ccmni 地址" ≠ "MD 没上电"。
30. **速率类结论必须多臂同窗**：本轮 4 组 300 s 窗口里，同一配置的两次（CPU0 臂）都是 1 起，
    而更早 300 s 窗口是 7 起——环境漂移比处理效应还大。

