# EXPERIMENT U-A1 · RO-PTE 哨兵（主件：scanary_ro 实测 CLI）—— 预注册 v4（2026-11-03 夜间窗）

> 目的：判定「RO 期目标页是否仍被外部写入」——出现记录 ⇒ 写者绕过 MMU ⇒ **非 CPU（E4）**；不出现 ⇒ **CPU/非 CPU 未判定（≤E1）**（理由见 §1.1）。
> 冻结前提：nerepair v2.2 **dry**（23:28:49 起；钥匙 nerepair.dry / no_xrep / no_arm）——不得改动；XREP/slotguard 仍关。
> **判据不依赖 kmsg**（nerepair attach 期 arm64 unhandled-fault 行结构性缺席：03_PROBES:164-166、ARMED_WINDOW §E6）。主判据只看**页内容**；nerepair 的 SEGV/REPAIR 行仅旁证。
> **RO 目标 = 受害者当前 va_list 所在页**（C-171 帧随动）；top−0x390 只是 vsurv4 历史现象，不用它定位。
> **v4 三条修正（Lead/skeptic）**：MF-1 runbook 改用 scanary_ro **真实 CLI**（空格分隔，--victim main；无「先跑 N 秒」开关，**首次 vcall 即进 RO 窗**）；MF-2 分支 C **降级为「未判定（≤E1）」**，不得写「倾向 CPU」；MF-3 RW 臂必须报 change 计数并折算 RO 窗期望（Poisson 上界）。另：**两臂都必须 --depth-list 0**（单帧深）。

## 1. 判据（预注册，写死）

| 分支 | 判据 | 结论 |
|---|---|---|
| **N（非 CPU）** | ① RO 窗内目标页出现**记录族**内容（窗末 dump 的 32B 命中记录形状，且与窗初基线不同）；② 目标页 = 该轮 va_list 所在页；③ 页在窗内确为 RO（工具自报 --ro 1 生效 + 窗末 restore 成功）；④ 窗内无 nerepair REPAIR/DREPAIR/XREPAIR、无实例切换 | **写者绕过 MMU ⇒ 非 CPU（E4）** |
| **U（未判定）** | RO 窗内无记录（无论 RW 臂是否有命中） | **CPU / 非 CPU 未判定（≤E1）**——见 §1.1 |
| **X（无效）** | 任一：RW 对照臂 0 命中（暴露不足）；目标页与 va 不自洽；页迁移；nerepair 非 dry；RO 未生效/restore 失败；窗内出现 REPAIR 行或实例切换 | **INVALID，不作阴性** |

### 1.1 为什么「RO 无变化」不能写成「倾向 CPU」（MF-2）

若写者是 **CPU uaccess**（copy_to_user 家族 / 内联 sttr），对 RO 页的写会走异常表 fixup **静默失败**：无信号、无 dmesg、无 kmsg 行；本内核又**无 PERF、无 fxhook**（厂商侧 CONFIG_PERF_EVENTS 未置、KPROBES=n）。因此「RO 期无变化」与「写者这一窗没写这页」**同形不可分**。
⇒ 只能宣布 N（非 CPU，正向发现）；**不得**由「无变化」反推 CPU。要反推 CPU，必须先有能看见 uaccess EFAULT 的通道（fxhook/PERF），今晚没有。

## 2. 装置与真实 CLI（MF-1）

- 主件：**/data/repro/scanary_ro**（已在设备）。参数**空格分隔**；`--victim=main` 这类等号写法会报 unknown arg 并退出。
- 关键 flag：`--ro 0|1`（0=RW 对照，1=RO 臂）、`--ro-sec S`（RO 保持秒数）、`--ro-loops N`（RO 轮次）、`--depth-list 0`（**单帧深**，两臂必须同值）、`--epoch-sec 3600`（不换档）、`--writeback none`（禁 sentinel，否则仪器自己写页）、`--selftest 1 --probe-sec 0`。
- **没有「先跑 60 s」开关**：**首次 vcall 即进 RO 窗**（RO 从第一次变参调用起算，--ro-sec 只决定保持多久）。
- 窗末顺序由工具保证：**先恢复 RW，再 dump**（restore 失败即 INVALID）。
- 备件：uaprobe_victim（仓内 tools/oneoff/sigsegv/uaprobe_victim.aarch64，115,912 B，sha256 1b4b8ad9e3104be6b659f92756260dc0ddb9934519cc749e89122c852a7f6b73）——仅当 scanary_ro 在设备上起不来时用；帧构造差异见 §6。

## 3. 一页纸 runbook（真实命令；无模块、无 insmod）

--- 0) 身份与前提（只读，记录时刻）---
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'date -u +%FT%TZ; cut -d. -f1 /proc/uptime; ls -d /data/gw/nerepair.dry /data/gw/no_arm; md5sum /data/repro/scanary_ro; cat /proc/sys/kernel/random/boot_id'

--- 1) RW 对照臂（暴露/功效，必跑）---
/data/repro/scanary_ro --victim main --ro 0 --ro-sec 600 --ro-loops 1 --depth-list 0 --epoch-sec 3600 --stack 2M --decoy 8M --period-us 5000 --hold-us 10000 --writeback none --log /data/repro/ua1_rw.log --selftest 1 --probe-sec 0 --duration 660
   判：把 log 里落在**目标页**的 HIT_APPEAR/HIT_CHANGE 计数 k 记下（§4 折算）；k=0 ⇒ 今晚不判（INVALID）。

--- 2) RO 臂（正向发现臂）---
/data/repro/scanary_ro --victim main --ro 1 --ro-sec 540 --ro-loops 1 --depth-list 0 --epoch-sec 3600 --stack 2M --decoy 8M --period-us 5000 --hold-us 10000 --writeback none --log /data/repro/ua1_ro.log --selftest 1 --probe-sec 0 --duration 660
   窗末自动：恢复 RW → dump（工具输出路径见 log 尾部）→ 退出。

--- 3) 取证据（只读、单次）---
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'tail -5 /data/repro/ua1_rw.log; tail -5 /data/repro/ua1_ro.log; ls -l /data/repro/ua1_*'

--- 4) 回滚 ---
正常：工具自行恢复 RW 并退出，无需动作。卡死时：
MSYS_NO_PATHCONV=1 python tools/lgssh.py 'killall scanary_ro 2>/dev/null || true; ls -d /data/gw/nerepair.dry'
**nerepair 保持 dry，勿动**；不重启、不改 slotguard、不 insmod。

## 4. 功效：RW 计数 → RO 窗期望（MF-3）

记 RW 臂（600 s）目标页命中 k；RO 窗 540 s ⇒ 期望 λ_RO = k × (540/600) = 0.9k。Poisson 95% 单侧上界（观测 k → λ_ub(RW)）：k=0→3.0；1→4.74；2→6.30；3→7.75；5→10.5；10→17.0；17→26.0。**折算到 RO 窗再乘 0.9**。

| RW 命中 k（600 s） | λ_RO 点估计 | λ_RO 95% 上界 | RO 臂「无记录」的含义 |
|---|---|---|---|
| 0 | 0 | ~2.7 | **INVALID**（暴露不足，不得下判） |
| 1-3 | 0.9-2.7 | 4.3-7.0 | 对「同速率非 CPU」p=e^-λ 仅 0.001-0.01 级，但**写者率小时级可变（C-204）**⇒ 仍只能写「未判定」 |
| 5-10 | 4.5-9 | 9.5-15 | p 更小，但结论上限仍是「未判定（≤E1）」 |
| ≥17 | ≥15 | ≥23 | p<1e-10，可写「RO 窗内未出现非 CPU 写入（按 RW 同速率上界）」——**仍不得反推 CPU** |

纪律：两臂**尽量相邻/同窗**（同 boot、同 nerepair 状态、同流量环境，间隔越短越好）；报告必须同时给 k、λ_RO、λ_ub 与 p，缺一不得下结论。

## 5. 风险与假干扰防护（对齐 ARMED_WINDOW 教训）

1. **写者=仪器**：必须 `--writeback none`（scanary 的 sentinel 会写记录所在 VA，:601-611）；log 里 sentinel 计数非 0 ⇒ INVALID。
2. **假修复（63.6% REVIEW、hostapd 7 连修）**：不以崩溃/修复为判据；窗内出现 nerepair REPAIR/DREPAIR/XREPAIR 或实例切换（ARMED_WINDOW §A：21:11 曾切换）⇒ INVALID 重跑。
3. **双重不可见**：不读 kmsg（§E6）；主判据=页 dump。
4. **观测者污染**：窗内只跑单次只读命令；不跑 od/grep 重命令（先例 19:29 od applet 崩溃）。
5. **停摆**：RO 期进程退出 ⇒ INVALID（按 10_MP §12.3 分 hang/panic，不混）。
6. **页迁移**：RO 窗内禁止 madvise/内存压力；能取 patrace 则窗前后各记 PA 作 gate，取不到写「未验证」。

## 6. 单帧深（--depth-list 0）为什么是硬要求

默认 5 档深度每 60 s 换档 ⇒ 命中会落到**多页**（今晚第一轮实测：17 次命中跨 3 页）。RO 只能护一页 ⇒ 多档时「RO 页无命中」被其它页命中稀释，判据失效。**两臂都必须 `--depth-list 0`**（单帧深），且两臂用同一 depth、同一 --stack/--decoy/--period-us/--hold-us。

uaprobe_victim（备件）的差异：自写深帧（默认 depth=8），落点相对 top 的偏移与 vsurv4 的 top−0x390 不同 ⇒ 一律用自报 slot_va/page；活帧寿命可保持 600 s（暴露率更高）；不依赖崩溃，故不受 nerepair/信号影响。若启用备件，同样必须先跑 RW 臂证明该 &ap 会被写（bytes_changed≥1），否则 INVALID。
