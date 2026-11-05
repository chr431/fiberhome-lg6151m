# U-D1 预注册 · 低风险六臂（E1–E6）：点名或把写者逼到唯一格

> 日期：2026-11-04 20:45（+0800）｜结果前冻结，不得事后放宽
> 前置：[U-C1_WRHUNT_RESULT_2026-11-04.md](U-C1_WRHUNT_RESULT_2026-11-04.md)（5 入口多路径阴性）、
> [U-A2_PULSE_RESULT_2026-11-04.md](U-A2_PULSE_RESULT_2026-11-04.md)（PTE 门控）、
> [U-B1_FXHOOK_RESULT_2026-11-04.md](U-B1_FXHOOK_RESULT_2026-11-04.md)（ex_table 排除）。
> 目标：**不加载任何内核模块、不改服务**，用「进程 / 页 / CPU / 包」四个维度把剩余写者逼到唯一格；
> 六臂全部点名不了，才按用户授权进入 H6a（站点级 `sttr` 补丁，另立预注册 + skeptic）。

## 0. 共同约束

- 同一 boot（btime 1793736016 起，全程无重启）；每臂前后 `date +%s` + `/proc/uptime` 对齐。
- 任何臂 scanner 命中 < 10 ⇒ **INVALID-by-exposure**（不开判）；selftest 必须 PASS。
- 任何 oops / panic / RCU stall ⇒ 立即停止全部实验，LK 救砖待命（`tools/lk_flash_v4.py`）。
- 日志落 `/data/repro/ud1_*.log`，窗末 `cat` 拉回本地 + md5 双核（pull 后 strip `\r\n` 再核）。
- 所有推送经 `deploy.py put`（`MSYS_NO_PATHCONV=1`），推送后 md5 双核 + `chmod 755`。
- victim 统一件 `scanary_ro_v22`（= v1.21 + `--spin/--ctxbytes/--cpu/T0`），
  **`--depth-list 0 --cycle 0`**（几何固定），不带 `--ro`（连续扫描，不 park、不 mprotect）。
- 每臂日志首行带 `T0 epoch_us=... mono_us=...`，供 E5 与包时间轴对齐（禁心算 epoch）。

## 1. E1 诱饵同 VA（VA-targeted vs context-targeted）

**装置**：victim `--victim main` 600 s（主栈，历史几何）；同时 `va_decoy <window_base> <2M>` 在
**同数值 VA** 映射 2 MB、预毒 0x5a、每 5 ms 扫同一 R1/R2 规则，日志 `DECOY_HIT`。
诱饵是 inert 进程（无 victim 循环、无变参调用），与 victim 各自独立 exec（ASLR=2 ⇒ 布局独立）。

**判读**：

| 诱饵命中 | victim 命中 | 判 | 等级 |
|---|---|---|---|
| ≥10 | ≥10 | 写者按**数值 VA**打、与进程无关（内核缓存/陈旧 user VA） | 重大：直接指向「驱动缓存 VA」类 |
| 0 | ≥10 | 写者只在 victim 的上下文/帧内发生（E-A/E-B），排除纯 VA-targeted | 机制收窄 |
| 任意 | <10 | INVALID-by-exposure | — |

注：ASLR=2 实测（两次 main 栈 top = 0x7fd58d5660 / 0x7fe4586b40）⇒「固定绝对 VA」只能来自
写者按当前栈顶重算，或按 victim mm 打；诱饵映射用 `MAP_FIXED_NOREPLACE`，冲突则重新 exec（≤5 次）。

## 2. E2 命中整页结构（固定目标 / 范围 / 自然匹配）

**装置**：E1 的 victim 臂同时开 `--ctx 200 --ctxbytes 2048`（每次命中 dump 命中点 ±2 KB = 整页 hex）。

**分析**（本地脚本）：
1. **poff 直方图**（同一页内分布）；
2. **同 VA 再现**：`HIT_GONE` 后同 VA 再次 `HIT_APPEAR` / `HIT_CHANGE` 的计数；
3. **结构签名**：命中点前后是否出现 `pt_regs`（31×8 + sp/pc/pstate）或 sigframe 特征；
   记录周围 32B 是否为调用帧/寄存器溢出区。

**判读**：

| 观察 | 判 |
|---|---|
| 同 VA 被重写 ≥3 次（GONE→APPEAR/CHANGE） | 真实写者（非自然匹配） |
| 命中点全部落在 pt_regs/sigframe 内 | 自我污染（信号帧） |
| poff 随 `ep`/`D` 单调 | 目标由 sp/`&ap` 派生 |
| poff 分散且无结构 | 自然匹配或范围写，需 E1/E3 合取 |

## 3. E3 纯自旋（victim 零 syscall）

**装置**：`--victim main --spin 1 --duration 600`（spin 循环仅 `yield`，零 syscall；scanner 线程照常 5 ms 扫）。
活性锚：同窗 selftest PASS + `passes` 计数。

**判读**：

| 观察 | 判 |
|---|---|
| 命中 ≥10 | 写者不需要 victim 的任何 syscall/用户态栈活动 ⇒ 只剩 **E-B（打断 victim 的中断上下文）** 或同进程其它线程；结合 E1 诱饵 0 ⇒ E-B |
| 0 命中（且 E1 victim ≥10） | 写者挂在 victim 的 syscall/用户态路径上（E-A），下一步逐 syscall 二分 |

## 4. E4 CPU 亲和 + softirq

**装置**：`--cpu N` 把 victim 线程（main）绑到 CPU N；同窗每 10 s 采样 `/proc/softirqs`
（NET_RX / NET_TX 每 CPU 增量）。两臂各 600 s：N=0（网络中断主 CPU，由 softirqs 实测选）
vs N=3（静默 CPU，先验证该 CPU NET_RX 增量 ≈0）。

**判读**：

| 观察 | 判 |
|---|---|
| 热 CPU ≥10、静 CPU 0（且静 CPU NET_RX≈0） | **中断上下文写入（E-B）成立** |
| 两臂都 ≥10 且量级相近 | 与 victim CPU 无关（E-A 或全局） |
| 静 CPU 臂 NET_RX 增量不为 0 | 该臂无效，换 CPU（本轮不改 IRQ affinity，避免网络风险） |

## 5. E5 包级时间相关

**装置**：E4 的一个 600 s 臂同窗
`tcpdump -i eth0 -nn -s 96 -tt -c 200000 -w /data/repro/ud1_e5.pcap`；
窗始末 `date +%s` + scanner `T0(epoch_us,mono_us)` 双锚点。

**判读**：把每条命中 `(len, saddr, t_hit)` 与包 `(ip_len, saddr, t_pkt)` 在 **±20 ms** 内匹配：

| 观察 | 判 |
|---|---|
| 与 **RX** 包（dst=eth0）匹配 | 写者在收包路径 |
| 与 **TX** 包（src=eth0，与 w2 高 32 位=saddr 一致）匹配 | 写者在发包路径 |
| 无任何包匹配 | 记录不是单包元数据（聚合/统计结构），回到 E1/E2 |

注：eth0 = 110.65.xx.28/25（实测），即 U-C1 记录里的 `ip` 字段。

## 6. E6 设备事实（前置侦察，已做/待做）

- ASLR = **2**；两次 main 栈 top：`0x7fd58d5660` / `0x7fe4586b40` ⇒ 每 exec 随机。
- `/proc/<victim>/maps`：主栈 flags、altstack 位置、`--victim pthread` 私有栈——E1 前后各一次。
- 判读：主栈若为 `rw-p`（私有）且无共享映射 ⇒ 别名/共享页模型排除；
  若发现 `MAP_SHARED` 或与其它进程同 inode ⇒ 立即转向。

## 7. 总判读（组合表）

| E1 诱饵 | E3 自旋 | 结论 | 下一步 |
|---|---|---|---|
| ≥10 | — | VA-targeted 内核写者 | 按 VA 反查持有者；H6 不必上 |
| 0 | ≥10 | E-B 中断上下文 | E4/E5 定位；E5 匹配 RX ⇒ 钩 NAPI 路径 |
| 0 | 0 | E-A victim syscall/用户态 | 逐 syscall 二分（ptrace 或自建 wrapper） |
| 0 | <10 | INVALID-by-exposure | 延长窗/提高 λ |

## 8. 作废条件

1. 任一臂 selftest 失败；
2. 有效臂命中 <10（除已注明）；
3. 设备重启 / oops / RCU stall；
4. 诱饵 `MAP_FIXED_NOREPLACE` 冲突且 3 次 exec 重试仍失败；
5. 日志 md5 不一致。

## 9. 授权与升级

六臂全部阴性、或只落到「E-A/E-B」但点不了名 ⇒ 按用户授权进入 **H6a（站点级 `sttr`/内联
`__put_user` 补丁）**，另写 U-E1 预注册 + skeptic（关键风险：`PANIC_ON_OOPS=y`、补丁点回读、
rmmod 回滚、LK 救砖待命）。

## 10. 版本与产物

| 件 | 说明 |
|---|---|
| `scanary_ro_v22` | v1.21 + `--spin`（E3）/`--ctxbytes`（E2）/`--cpu`（E4）/`T0`（E5）；源码 `tools/oneoff/sigsegv/scanary_ro.c` |
| `va_decoy` | E1 inert 诱饵：同 VA 2 MB、预毒 0x5a、R1/R2 扫描、`DECOY_HIT` 日志；源码同目录 |
| `ud1_*.log` / `ud1_e5.pcap` | 设备 `/data/repro/`，窗末拉回本地 |
