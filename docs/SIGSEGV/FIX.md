# FIX · 32B 记录 SIGSEGV 家族（2026-10-31）

## 0. 判决回顾
- Transport：**PA/DMA（E2）**；记录 = WED TXD，经 DMA 落到“已释放又被复用”的物理页。
- Writer：**WED TX 路径**（mtk_warp TX ring 描述符 PA）。
- 自然 NE 份额：**0/4，95% 上界 49%**。
- 页级 kprobe 判决被 `CONFIG_KPROBES=n` 阻断（C-144）。

## 1. 根修复（让写入停止）——按可行性排序
| 方案 | 做法 | 可行性 | 风险/代价 |
|---|---|---|---|
| **R1 厂商驱动修复** | `mtk_warp` 在释放 TX/RX 缓冲前停 DMA/清描述符；或 TXD 用 bounce buffer；或保留 WED 页不归还 | 需厂商源码/NDA | 最彻底；无法本地完成 |
| **R2 IOMMU/SMMU** | 让 WED DMA 走 SMMU；stale PA 在 IOMMU 中已 unmap → DMA fault 而不是写复用页 | 需 DT/内核改动 + SMMU 可用 | 需重编内核/改 DT；可能影响性能 |
| **R3 关 WED offload** | 若 `mtk_wed`/`warp_ctrl` 有参数可回退非 WED 路径 | 需实测参数/固件 | 性能下降；不确定有开关 |
| **R4 保留页** | 内核模块把 WED 缓冲页 pin 住不归还 | 需识别 WED 页 | 不可行（无法可靠识别） |
| **R5 固件升级** | 厂商新固件 | 需厂商 | 不可控 |

**结论：根修复不在本地可达范围**（无厂商驱动源码、内核 KPROBES 关闭、SMMU 未用于 WED）。

## 2. 妥协方案（已实现）：nerepair ptrace supervisor
**目标**：不停止写入，但**不让写入把进程打死**；覆盖**所有用户进程**。

### 2.1 检测（只修记录家族，不掩盖别的 bug）
- 捕获 SIGSEGV/SIGBUS；
- 故障指令是 `ldr Xt,[Xt]`（Rt==Rn，覆盖 LDR/LDUR/LDRSW/LDRB/LDRH 形式）；
- `si_addr == Xt`（加载自坏指针）；
- 故障时 va_list（x2）处的 32B 满足记录形状：
  - `w1 == 0`；
  - `w0 == fault` 或 `w0 == fault + 8`（va_arg 已自增）；
  - A0B2（fault 小、w2 大）或 B0A2（fault 大、w2 小）。
- 不满足 → **原样放行**（进程照旧死亡，不掩盖真实 bug）。

### 2.2 修复
- 令 `Xt = sp`（一个已映射的安全指针）；
- `pc += 4`（跳过故障加载）；
- 抑制信号（`PTRACE_CONT` sig=0）。
- 进程继续运行；该次 `va_arg` 得到一个**垃圾值**（输出可能错一个参数），但**不崩溃**。

### 2.3 覆盖
- 启动时 attach **PID 1** + 扫描 `/proc` attach 所有用户进程；
- `PTRACE_O_TRACEFORK|VFORK|CLONE|EXEC` 跟随 fork/clone/exec；
- 每 0.5s 在无 tracee 时重新扫描 `/proc`；
- **排除 vsurv4**（canary）：让它的 H4 诊断继续工作；
- **不覆盖内核线程**（它们没有用户 va_list，记录不会落在内核线程栈上）。

### 2.4 验证（本轮实测）
| 测试 | 结果 |
|---|---|
| 正控 `rectest`（把自己的 va_list 注入记录） | **SURVIVED，rc=0**；日志两条 `repaired` |
| 负控 `sh -c 'kill -11 $$'` | **rc=139**（不修，正常死亡） |
| PID 1 | `TracerPid: 19822`（已 attach） |
| vsurv4 | 存活；H4 计数不变（排除生效） |
| 日志 | `segv ... w=0x14d8b 0 0x109a8c000000641 0 / repaired ... rt=8` |

### 2.5 风险与限制
- **不停止写入**：DMA 仍会写复用页；只是进程不再因此死亡。
- **垃圾值**：被修复的那次 `va_arg` 返回 `sp`，格式化输出可能错一个参数。
- **ptrace 开销**：只在 SIGSEGV 时处理；fork/clone 跟随有少量开销。
- **监督者自身**：root daemon；若它崩溃，tracee 自动 detach 继续（未设 `PTRACE_O_EXITKILL`）。
- **不覆盖内核线程**（无需覆盖）。
- **可能影响自然 NE 普查**：`ip` 等进程的 record 崩溃会被修复，NE 率下降；canary 已排除，仍可做诊断。

### 2.6 部署与回滚
- 二进制：`gw/bin/nerepair` → `/data/gw/bin/nerepair`（manifest）；
- 启动：`gw/rc.extend.sh v3.3` 在 v3 分支 `pgrep` 守卫启动；
- 手动：`nohup /data/gw/bin/nerepair >>/data/gw/logs/nerepair.out 2>&1 &`；
- 回滚：`killall nerepair`（tracee 自动 detach）；删除 `rc.extend.sh` 中 v3.3 块。

## 3. 建议
1. **短期**：部署 `nerepair`（已做），先止住“进程被打死”；
2. **中期**：向厂商报 `mtk_warp` TX/RX ring stale-PA 问题（附 C-137/C-138/C-140/C-145）；
3. **长期**：若拿到驱动源码，按 R1 修；或启用 SMMU（R2）。
## 4. 关于“用自建 busybox 替换原厂 busybox”（评估结论：不做）

### 4.1 事实
| 项 | 原厂 /bin/busybox | 自建 /data/gw/bin/busybox |
|---|---|---|
| 大小 | 591,784 B | 1,609,800 B |
| 权限 | setuid root (-rwsr-xr-x) | 非 setuid |
| 链接 | 动态（vendor musl + libgcc） | 静态 |
| 版本 | BusyBox 1.36.1 | BusyBox 1.36.1（同版本） |
| applet | 112（/bin/* 为符号链接 → busybox） | 402 |
| 缺失 applet | — | lock、netmsg（厂商自定义） |
| 根文件系统 | squashfs ro（不可原地替换） | /data 可写 |

### 4.2 结论：兼容性不足，不替换
1. 2 个厂商自定义 applet 缺失（lock、netmsg）：bind mount 后 /bin/lock、/bin/netmsg 会 “applet not found”；
2. setuid 语义变化：原厂 busybox 是 setuid root，自建不是；保留需 chmod u+s（402 个 applet 全 setuid，安全面扩大），不保留则 ping/su 等依赖 setuid 的 applet 行为变化；
3. 只覆盖 S98 之后启动的进程：rc.extend.sh 在 S98 运行，init/procd 及更早的进程已映射原厂二进制；
4. 零增量崩溃覆盖：nerepair 已覆盖所有用户进程（含原厂动态 busybox 进程），替换只省 ptrace 往返，收益是性能不是覆盖。

### 4.3 如果仍要替换（opt-in 设计，未实施）
- 门禁：自建 applet 集合 ⊇ 原厂集合（当前差 lock/netmsg，门禁直接失败）；
- setuid：显式决定（建议否，接受 ping/su 行为变化）；
- 冒烟：sh -c 'echo ok'、ls、cat、mount、ip、awk 全通过；
- 回滚：umount /bin/busybox；
- 持久化：rc.extend.sh 加 mount --bind 块（带门禁与冒烟），失败自动跳过。

### 4.4 建议（2026-10-31 vaguard 退役轮修订）
- **单层防御（现行）**：nerepair 独扛全进程覆盖。vaguard（vfprintf 闸门）已彻底退役
  ——理由：①故障家族的底层污染源自内核修复栈退役后已消失（连续多日 repaired=0，
  闸门拦截也归零）；②闸门是编译期防线，拦截会塑造 NE 自然普查口径，不利归因；
  ③它让静态构建依赖仓外对象（_local/build/vaguard.o），破坏可重现性。历史战绩
  （49 次拦截）见 git 存档。
- 自建 busybox 保留，但自本轮起定性为**纯工具链**（402 applet 全集 + 1.36.1 语义
  基线；7 个守护脚本依赖 PATH 型 timeout、~900 处 PATH 型工具调用），不承担防务；
- 不动原厂 busybox：替换的收益（少量 ptrace 开销）远小于风险（lock/netmsg 缺失、setuid 面扩大、init 兼容性）。
