# U-D1 · 低风险六臂（E1–E6）：结果 —— 写者未点名，但收敛到唯一槽位与两类触发

> 日期：2026-11-04 21:40（+0800）｜预注册：[U-D1_PREREG_LOWRISK](U-D1_PREREG_LOWRISK_2026-11-04.md)（结果前冻结）
> 设备：同一 boot（btime 1793736016，全程无重启）；六臂顺序执行，无 oops/panic。
> 仪器：`scanary_ro_v22/v24`（v21 + `--spin/--ctxbytes/--cpu/FRAME/T0`）；`va_decoy`（E1 inert 诱饵）。

## 0. 一页结论

六臂全部完成、暴露全部达标（victim 真实命中 83 / 0 / 483 / 173 / 56），**写者身份仍未点名**。
但新数据把它逼进了一个**唯一栈槽位**和**两类触发条件**：

1. **槽位 = `sp_call - 0x100`**（`--victim main`、D=0x1000；`sp_call` 是 `hot_call` 里变参调用点的 SP）。
   82/83（E1）、172/173（E4 热）命中都在同一 VA；同址反复被**新包**重写（25 组不同 `len|saddr`，592 s）。
2. **触发需要循环体**：纯自旋（零 syscall、零调用）600 s **0 条**；busy hold（无 nanosleep，但有 snprintf+sigsetjmp）600 s **483 条**。
   ⇒ 不需要 nanosleep；需要 `snprintf`/`sigsetjmp`/深帧这一组活动。
3. **速率随 victim CPU 的网络负载变化 ~3×**：热 CPU2 17.3/min vs 静 CPU3 5.6/min vs 不绑核 8.3/min；
   但静 CPU 也不是 0（该 CPU 仍有 ~14 NET_RX/s）⇒ 支持"包路径参与"，未把中断上下文单独隔离。
4. **记录值 = 最近的真实 IP 包元数据**：173 条中 169 条能在 ±20 ms 内找到 `pkt.saddr == record.ip` 的包（±10 ms 121 条，±1 ms 6 条，中位 7.2 ms）；
   `len` 是 skb/GRO/GSO 长度（1664 典型），**不是线缆长度**；TX（saddr=WAN）与 RX（saddr=远端）都有，LAN 也有。

⇒ 写者是一个**在 victim 上下文里、每次循环把"最近一个包"的 32B 记录写到 `user_sp-0x100`** 的内核侧路径。
这与 U-A2（PTE 门控）、U-C1（remote-GUP/缺页/fixup 全排除）合取后，只剩"内核 uaccess store 或 GUP 类"两类。
**下一步 = U-E1：脉冲 + `fixup_exception` 钩子（pc/lr 点名），预注册已写，skeptic 审查中。**

## 1. E1 · 诱饵同 VA（600 s）

| 项 | 值 |
|---|---|
| victim | `--victim main`，83 条真实命中（8.3/min），槽位 `0x7fcbe5dad0`（top-0x1690） |
| 诱饵 | `va_decoy` 在同一数值 VA 映射 2 MB、预毒 0x5a、116,391 passes | **0 条** |
| 判读（预注册 §1 第 2 行） | **写者只在 victim 的上下文/帧内发生，排除纯 VA-targeted** |

## 2. E2 · 命中整页结构（同 E1 窗）

- **82/83 在同一 VA**：`poff=0xad0`、`topva=0x1690`、`spva=0x100`（= `sp_call-0x100`）；592 s 内 25 组不同 `(len,ip)`，
  35 条 `HIT_CHANGE`、83 条 `HIT_GONE`、0 rewrite（sentinel 未写活帧）——**同址重写铁证**。
- **整页 CTX**（`--ctxbytes 2048`）：命中点周围是普通栈帧（`ts`/`sp_call` 指针、零、静态数据指针），
  **没有包字节**；写者只写了 32 B，不是把包 copy 到栈上。
- 1 条启动命中（0.010 s，1664|110.65.xx.28）：真包，不是固定残留（dry-run 的启动值不同）。

## 3. E3 · 纯自旋（600 s，v22）

`--victim main --spin 1`：victim 只 `yield`，零 syscall；scanner 照常 5 ms 扫。

- `EXIT reason=duration passes=116619`、`probe_ok=4`、**真实命中 0**（唯一 1 条是 6.6 ms 启动时的 LAN 包）。
- 判读（预注册 §3 第 2 行）：**写者挂在 victim 的 syscall/用户态路径上（E-A）**，不是"只要 victim 在跑就会被写"。

## 4. E3b · busy hold（无 nanosleep，600 s，v24）

`--hold-us 10000 --hold-mode busy`：深帧内纯用户态自旋，**不调用 nanosleep**（`BUSY_CAL per_hold=3,114,294`）。

| 项 | 值 |
|---|---|
| 真实命中 | **483**（48/min），`iters=84497`，同一槽位 `sp_call-0x100` |
| FRAME | `ts=sp_call+0x1000`（编译器把 timespec 放在 hot_call 帧内） |
| 判读 | **不需要 nanosleep**；需要 `snprintf`+`sigsetjmp`/深帧这一组活动（与 E3 合取） |

## 5. E4 · CPU 亲和（各 600 s）

| 臂 | victim CPU | 同 CPU NET_RX（30 s 采样） | 真实命中 | 速率 |
|---|---|---|---|---|
| 热 | CPU2 | ~2865/30 s | **173** | 17.3/min |
| 静 | CPU3 | ~420/30 s | **56** | 5.6/min |
| 不绑核（E1） | — | — | 83 | 8.3/min |

判读：热/静 ≈ **3.1×**；静 CPU 仍有 ~14 RX/s（不是预注册要求的"静默 CPU"），
故 E-B（中断上下文）**得到支持但未被单独隔离**；写者仍需要循环体（E3）。

## 6. E5 · 包级时间相关（eth0，600 s，9437 包 / 598.8 s）

| 窗 | `pkt.saddr == record.ip` | 备注 |
|---|---|---|
| ±1 ms | 6/173 | 扫描周期 5 ms + 槽位生存期 |
| ±10 ms | 121/173 | 中位最近 Δt = 5.6 ms |
| ±20 ms | **169/173** | 中位 7.2 ms |
| ±50 ms | 169/173 | 饱和 |

- `len` = skb/GRO/GSO 长度（1664 典型；另有 4482/4401 的 LAN/WAN 大包），**不是线缆长度**。
- 方向：114/173 记录 `saddr=110.65.xx.28`（WAN TX），其余为公网远端（RX）；LAN `192.168.9.x` 也出现。
  ⇒ 写者看到的是**最近的真实 IP 包（双向、含 LAN）**，不是单流/单方向。

## 7. E6 · 设备事实

- `randomize_va_space=2`；main 栈 top 每次 exec 随机（0x7fd58d…/0x7fe458…/0x7fcbe5…/0x7ff806…）。
- victim `[stack]` = `rw-p` 私有匿名（无共享别名）；`/proc/<pid>/maps` 无 `rw-s` 栈映射。⇒ 别名/共享页模型排除。

## 8. 合取与剩余机制

| 约束 | 来源 | 结论 |
|---|---|---|
| 必须 victim 在跑、且在其 mm/上下文 | E1 诱饵 0 + U-C1 mm 过滤 | 排除纯 VA/内核线程任意写 |
| 写必须过 VMA/PTE 许可 | U-A2 脉冲 ON-fraction 0.058 | 排除 DMA/直接映射/kmap |
| 无缺页、无 fixup、无 remote-GUP | U-C1 H1–H5 | 排除 /proc/mem、process_vm_writev、缺页、ex_table |
| 需要循环体（snprintf/sigsetjmp/深帧） | E3 vs E3b | 排除"纯中断打断即可写" |
| 速率随 CPU 网络负载 ~3× | E4 | 包路径参与 |
| 值是最近包（±20 ms，双向） | E5 | 写者持有或能取到最近 skb 元数据 |

剩余两类实现（未点名）：
1. **内核 uaccess store**（`copy_to_user`/`__put_user`/内联 `sttr`）在 victim 上下文写入 `sp-0x100`，内容取自最近 skb；
   U-C1 的 H1–H5 都看不见它（H1–H3 是 remote-GUP，H4 缺页，H5 只覆盖"已失败"的 fixup）。
2. **GUP 类**（非 remote `get_user_pages`/`*_fast` + kmap）——同样看不见，但必须每次重新过 VMA（与 U-A2 门控自洽）。

**U-E1（已预注册）= 脉冲 + `fixup_exception` 钩子**：RO 窗内写者若走 uaccess，必然进 fixup，
钩子记录 `{far, pc, lr, comm}`，`pc`=故障指令、`lr`=调用者 —— 直接点名。
若 U-E1 为 0，则排除"uaccess 直接 store"，转 H7（非 remote GUP 族）。

## 9. 采集件（设备 `/data/repro/`，md5 双核）

| 文件 | md5 |
|---|---|
| ud1_e1_victim.log | `02d4a4083b63caef13f5f3c0cf8d4539` |
| ud1_e1_decoy.log | `743038c3cd5649ab12d95b30a1e7d3e9` |
| ud1_e3_spin.log | `21a1232a34dd29770b3f5e5f1660e87d` |
| ud1_e3b_busy.log | `a5fb81a8a3e9603b3c82c0431b8e0253` |
| ud1_e45_cpu2.log | `1161505d007b865cec4d322a8cfad5c0` |
| ud1_e5.pcap | `297fc05576976c4126d9824ebb096347` |
| ud1_e4_cpu3.log | `21ef915a6324d1cb9667611590091710` |

## 10. 三栏

### [A] 已核实
- 诱饵同 VA 0 条（116K passes）vs victim 83 条 ⇒ 非 VA-targeted。
- 82/83（E1）、172/173（E4 热）同槽 `sp_call-0x100`；25 组新包同址重写。
- 纯自旋 0；busy hold 483（无 nanosleep）⇒ 触发需循环体。
- 热/静 CPU 17.3 vs 5.6/min；±20 ms 包源匹配 169/173。
- ASLR=2；栈 rw-p 私有。

### [B] 未核实
- 写者身份（U-E1 待跑）。
- `w0` 语义（值域 0x8f93–0x2dfcc，非单调；候选：时间戳低 bits/流 id）。
- "静 CPU"未真正静默（NET_RX ~14/s），E4 的 E-B 判读是程度支持而非隔离。

### [C] 必须上设备
- U-E1 脉冲+fxhook（pc/lr/comm 点名）；若 0 ⇒ H7 非 remote GUP 族。
