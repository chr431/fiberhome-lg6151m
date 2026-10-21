# 2026-10-21 事故留档：WiFi 全断但 GUI/指示灯/看门狗一致显示"正常"

> 事后留档，不是操作手册。记录现场证据、根因链、已落地修复与仍开放的问题。
> 相关提交：`ab2a0d6`(batch3 svc_lib，引入本缺陷的判据) 之后的 WiFi 修复提交；
> 前序同类事故：[INCIDENT_2026-10-19.md](INCIDENT_2026-10-19.md)（hostapd 12:41
> SIGSEGV，当时 watchdog 只检不拉）。

## 0. 摘要

| 项 | 内容 |
|---|---|
| 用户症状 | WiFi 无法连接（SSID 可见、连上即断），但指示灯与 GUI 均显示一切正常 |
| 直接原因 | 我们的 AP hostapd（`hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf`）在 13:41:37 发生 **SIGSEGV**（vendor `/usr/sbin/wpad`），之后无人拉起 |
| 为何所有观察者都说正常 | 四条判据都在测"存在"而不是"服务"：① `svc_hostapd_up` 用 `pidof hostapd`（匹配到厂商 global 实例）+ `-S` 套接字文件（崩溃后文件残留）+ 链路 flags；② GUI/API 用 `iw dev ... type AP`（驱动保持 AP 模式）；③ WiFi 灯用 netdev 存在/operstate；④ boot gate 的 BSS 计数复用同一套残留 socket 判据 |
| 持续时长 | 13:41:37 → 19:22 手动恢复（约 **5.7 小时**） |
| 修复 | 判据改为**活控制套接字**（`/proc/net/unix`）+ **自有 hostapd 身份**（argv[0]+配置路径+exe）；恢复删除残留 socket、不再因"无 socket"拒绝；进程确定不存在时即时修复；GUI/灯/selftest 同源 |
| 状态 | 已修复并实弹验证（含"复现事故态"验收：GUI 0/0、灯 w0、自动恢复 1/1） |

## 1. 时间线（设备本地时间 CST）

| 时间 | 事件 |
|---|---|
| 04:00:28 | 每日定时重启（reboot_sched），04:01–04:02 `wifi_up` 起 AP（hostapd pid 23114） |
| 11:39:43 | rai0 两个客户端完成 WPA 握手（WiFi 正常） |
| 13:08:46 | rai0 一个 STA disassociated |
| **13:41:37** | **hostapd(pid 23114) SIGSEGV**：aee `db.05.NE`；core_meta 元数据 `exe=/usr/sbin/wpad`、`args=hostapd -B /var/wlan/hap_2g.conf /var/wlan/hap_5g.conf`；syslog 记 `>>> hostapd <<<` |
| 13:41–19:19 | ra0/rai0 仍按驱动 apcfg 发信标；客户端 assoc 成功后 4-way 失败、`reason=3` 自断重试；`/var/run/hostapd/ra0|rai0` 留下**残留 socket 文件**；厂商 `hostapd -g /var/run/hostapd/global` 仍活着 |
| 13:41–19:19 | watchdog 每轮 `hostapd=0`（健康）、GUI 双频"正常"、WiFi 灯常亮、boot gate 早已退出但 bss 判据同样为真 |
| 19:19 | 用户报告"WiFi 无法连接，但指示灯和 GUI 正常" |
| 19:22 | 现场取证：`hostapd_cli -i ra0/rai0 status` = Connection refused；`/proc/net/unix` 中 ra0/rai0 条目为 0；`-S` 文件仍在；`pidof hostapd` 只命中厂商 global 实例 |
| 19:22 | 手动恢复：删残留 socket → 两频 down/up → `hostapd -B` 双 conf → `no_bcn 0`；双频 `state=ENABLED`，客户端 19:29:03 重新握手 |
| 19:24–19:33 | 部署活套接字判据；2-of-3 与即时修复两次实弹；"事故态复现"验收（STOP watchdog → kill hostapd → GUI 0/0、灯 w0 → CONT → 自动恢复 1/1） |

## 2. 根因链（按证据）

1. **hostapd 崩溃**：vendor `/usr/sbin/wpad`（hostapd 多调用二进制）SIGSEGV。aee dump 加密，
   core_meta 只拿到 exe/args/maps/status（无寄存器），触发输入未定位——与 2026-10-19
   12:41 的 hostapd SIGSEGV 同族。**这是厂商二进制的缺陷，无法从我们的源码根治**。
2. **检测谎言（本次要根治的部分）**：
   - `svc_hostapd_up()`（batch3 引入）：
     `pidof hostapd` → 厂商 global 实例在，为真；
     `[ -S /var/run/hostapd/ra0 ]` → 崩溃后 socket **文件**仍在，为真；
     `svc_link_up ra0/rai0` → 驱动保持 AP 模式，链路 UP，为真。
     三者皆真 → 判"健康"，watchdog 永不重启。
   - `svc_bss_count()` 用同一 `-S` 判据 → `bss=2`（HEALTH 里也显示 2）。
   - `api_wifi.sh wifi_state`：`iw dev ra0 info | grep -c "type AP"` → 1 → GUI 双频"正常"。
   - `led_mgr probe`：`[ -d /sys/class/net/ra0 ] && operstate != down` → WIFI=1 → 灯亮。
   - boot gate `c_wifi` = `svc_bss_count >= 2` → 同样为真（门禁当时已退出，不影响但同理）。
3. **客户端表现**：驱动 apcfg 继续发信标（SSID 可见），但 WPA 层不在 → assoc 成功、
   EAPOL 无响应 → `reason=3` 反复重试；dmesg `ap_peer_deauth_action` 每 ~12s 一轮。
   这正是用户看到的"能看到 SSID、连不上"。

**一句话**：崩溃本身是厂商缺陷；5.7 小时无人修复，是我们把"文件/进程/接口存在"
当成了"服务在服务"。

## 3. 修复

| 文件 | 版本 | 变更 |
|---|---|---|
| `gw/svc_lib.sh` | 1.1 | `svc_sock_live()`：`/proc/net/unix` 里必须有该路径的**活端点**（残留文件不算）；`svc_our_hostapd()`：只认 argv[0] 为 hostapd、参数含 `/var/wlan/hap_*.conf`、exe 为 wpad/hostapd 的**我们自己的**实例（不再 `pidof hostapd`）；`svc_bss_count()`/`svc_hostapd_up()` 改用活套接字；新增 `svc_live_socks()` 诊断 |
| `gw/watchdog.sh` | 1.30 | 健康判据 = 自有进程 + ra0/rai0 **活**套接字 + 链路 UP；恢复前删除残留 socket、只杀自有实例；**不再因"没有 socket"拒绝恢复**（那正是崩溃后的状态）；进程确定不存在时**即时修复**（2-of-3 仅用于"进程在但不服务"的模糊态）；恢复后以活套接字判定并记录双频结果 |
| `gw/www/api_wifi.sh` | 1.1 | `hostapd2g/hostapd5g` = 活控制套接字（原 `iw type AP` 在 hostapd 死后仍为 1） |
| `gw/led_mgr.sh` | 3.0 | WiFi 灯 = `svc_bss_count >= 1`（AP 服务在服务），不再是 netdev 存在 |
| `tools/selftest.py` | 2.54 | `t_wifi_ap_service`：活套接字 2/2、自有 hostapd pid、双频 `state=ENABLED`、svc_lib/GUI/LED 判据同源；静态断言 `svc_lib` 不再出现 `pidof hostapd` |

## 4. 验证（实弹）

- **正常态**：`svc_live_socks=ra0 rai0`、自有 pid、`bss=2`、`hostapd_cli` 双频 `state=ENABLED`；
  GUI `/api/wifi` `hostapd2g=1, hostapd5g=1`；灯 `state: w1`。
- **2-of-3 路径**：kill hostapd → 第 1 次采样 `FAIL + SKIP`；第 2 次（30s 后）
  `EVT recover hostapd` → `OK hostapd recovered (bss=2)`；客户端 10s 内重新握手。
- **即时路径**：kill hostapd → 同一轮 `EVT hostapd process absent — immediate repair
  (definitive)` → `EVT recover` → 2s 内新实例、双频 ENABLED。
- **事故态复现**（STOP watchdog，保证观察者看到真实故障）：
  - kill hostapd 后 GUI `/api/wifi` 立刻 `hostapd2g=0, hostapd5g=0`；
  - `led_mgr` 日志 `state: w0`（灯灭）；
  - CONT watchdog 后自动 `EVT recover` + `OK`，GUI 回到 1/1，灯 `w1`。
- **真实客户端**：手机 `56:fe:92:5c:ca:c9` 在每次恢复后 10–20s 内
  `associated` + `WPA: pairwise key handshake completed (RSN)`（rai0 与 ra0 均验证）。
- **回归**：`selftest.py wifi` 9/9；全量套件 96 pass / 0 fail；`deploy.py doctor` CLEAN。

## 5. 仍未闭环

1. **hostapd SIGSEGV 的触发输入**：aee dump 加密，无寄存器/调用栈；core_meta 已保留
   exe/args/maps/父进程/环境 PATH。下一次若落在每日 core 窗口（03:20–03:30，core_pattern
   切到 `/tmp/core.%p`），可拿到完整 core 解析（参考 [SIGSEGV_ANALYSIS.md](SIGSEGV_ANALYSIS.md)
   的 core 工具链）。
2. **重启预算**：hostapd 恢复沿用 3 次/小时上限；若厂商崩溃频率超过该值，会转为只告警
   （防止射频反复抖动）。必要时按崩溃类型拆分预算（进程缺失 vs 模糊态）。
3. **厂商 global hostapd 与我们并存**：本次它正是 `pidof hostapd` 谎报的一半原因。它承担
   STA（apcli0）侧职责，未移除；所有判据现在只认自有配置路径的实例。
4. **logc 崩溃风暴（与本事故独立的观察）**：`/data/gw/logs/logc_crash/` 已有 101 个
   面包屑（示例：`version=1.3 sig=11 frame_off=43052 frame_len=200 buf_len=65568
   frames_emitted=7785`），约每 10–40 分钟一次。它不影响 WiFi，但会让日志镜像出现缺口，
   建议作为下一轮 P1 根因专项（面包屑已把范围收敛到单帧）。
