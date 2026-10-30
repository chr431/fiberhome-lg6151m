# OVERNIGHT · 2026-10-31 · nerepair 效果验证（预登记）

## 0. 目的
在 **vaguard 关闭** 的条件下，验证 nerepair 是否真的把“记录家族”崩溃挡在进程死亡之前。明早用 `tools/oneoff/sigsegv/overnight_report.py` 复查。

## 1. 装置（已就位）
- **vaguard 关闭**：`/data/gw/bin/busybox` = `busybox.pre-vfguard`（1,115,944 B，`grep -ac vaguard`=0）；`/data/gw/bin/ip` = vendor `/usr/libexec/ip-full`（547,744 B，无 vaguard）；备份 `busybox.vfguard`（1,609,800 B）/ `ip.vfguard`（798,552 B）。
- **nerepair v1.3**（v1.3 修 SIGALRM SA_RESTART：v1.2 的 signal() 带 SA_RESTART，waitpid 被重启，心跳/STAT 不刷新，watchdog 会误判 stale 并重启）：`/data/gw/bin/nerepair`（1,150,720 B，md5 `84eff57f…`），经 `/data/gw/nerepair_launch.sh` 单实例启动（`/tmp/nerepair.lock`），每 60s 写 `/tmp/nerepair.hb`。
- **watchdog**：`svc_lib.sh v1.4` 的 `SVC_TABLE` 新增 `nerepair` 行（recipe=launcher，hb=`/tmp/nerepair.hb`，max=180）；`/tmp/watchdog_state` 已出现 `nerepair=0`。
- **status**：`avail_sampler.sh v1.11` 新增 `sys.nerepair`（pid + hb 新鲜度 → op/deg/down）。
- **canary**：vsurv4 仍 24 个（`/data/repro/h4_*` 继续增长）；nerepair 对 vsurv4 只 `PASS reason=canary`（不修）。
- **基线**（`/data/gw/logs/overnight_baseline.txt`）：epoch 1788942974，ne=1590，vaguard=49，reboots=10，h4=230，aee=19，stacks=1，nerepair_pid=6942，guard=off。

## 2. 假设
- **H1**：vaguard 关闭后，记录家族会在自然进程里重新出现；
- **H2**：nerepair 会在它们死亡前修复（`REPAIR` 行），因此**记录家族的自然 NE 应为 0 或极少**；
- **H3**：canary h4 继续增长（现象存在），且 h4 增量与 `REPAIR` 数量可比。

## 3. 明早复查项目
1. `ne_events.tsv` 新增行（基线 1590 之后）：按 comm/sig/exe 分类，重点 `sig=11`；
2. `nerepair.log`：`REPAIR`/`PASS` 按 comm/reason 计数；最后一条 `STAT`（attached/segv/repaired/passed/suppressed）；
3. `vaguard.tsv` 增量（应为 **0**；>0 说明闸门没关干净）；
4. `h4` 增量（现象仍存在）；
5. `reboots.log` / uptime（是否重启，重启后 rc.extend 会拉起 nerepair，但 watchdog 的 SVC_TABLE 需重启后才加载）；
6. `/data/log/aee_exp` 新目录、`meta/*.stack` 新增（真实死亡）；
7. `watchdog`：`/tmp/watchdog_state` 的 `nerepair` 键、`/tmp/watchdog.log` 的 `nerepair` 事件；
8. `avail_sampler`：`sys.nerepair` 的 op/deg/down；
9. load/内存/dmesg 错误。

## 4. 判据
- **有效**：vaguard 增量=0，`REPAIR`>0，新增 `sig=11` 中**没有**记录家族（或全部有 `PASS` 解释且不是 shape 失败）；
- **部分**：`REPAIR`>0 但有记录家族死亡（看 `PASS reason`：`shape-fail`/`addr-ne-xt`/`rt-ne-rn` → 检测漏；无 PASS → nerepair 没看到）；
- **无效**：记录家族死亡 ≈ 关闭闸门前水平（对照 `vaguard.tsv` 的 49 次/42h）；
- **闸门未关**：vaguard 增量>0。

## 5. 混杂因素
- 设备有**两个 watchdog 实例**（**预存在**，`svc_lock` 未阻止）；nerepair 由 launcher 锁保证单实例；
- 设备时钟为 2026-09-09（未同步），日志 ISO 以设备时间为准；
- load≈35（vsurv4 24 个 + 其他）；
- `logc`/`mipc_cellular`/`v3httpd` 仍链 vaguard（基线 0 命中）；
- nerepair 日志 1MB 轮转（`.1`）；`STAT` 60s。

## 6. 回滚
```
cp /data/gw/bin/busybox.vfguard /data/gw/bin/busybox
cp /data/gw/bin/ip.vfguard /data/gw/bin/ip
killall nerepair
```
（watchdog 的 SVC_TABLE 若保留 nerepair 行，会重新拉起；要彻底停用需删该行/停 watchdog。）

## 7. 明早命令
```
python tools/oneoff/sigsegv/overnight_report.py
```
