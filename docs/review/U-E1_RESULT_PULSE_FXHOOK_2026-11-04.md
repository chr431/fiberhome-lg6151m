# U-E1 · 脉冲 + fixup_exception：结果 —— 排除"盲目 uaccess store"

> 日期：2026-11-04 22:20（+0800）｜预注册 v2：[U-E1_PREREG_PULSE_FXHOOK](U-E1_PREREG_PULSE_FXHOOK_2026-11-04.md)
> skeptic：[U-E1_SKEPTIC](U-E1_SKEPTIC_2026-11-04.md)（v1 REJECT → M1–M9；v2 CONDITIONAL PASS，三处文本/criterion 已改）
> 设备：新 boot（21:50 上电，bootslot=a）；模块 `fxhook_v6.ko` md5 `963f37aa1577466771ac1f2678bd52b9`。

## 0. 一页结论

**写者不是"盲目 uaccess store"（`copy_to_user`/`__put_user`/内联 `sttr`）。**

- 主窗 **1131 s**、脉冲臂 **556,880 次 RO 脉冲**、victim **61 条落地记录**（≥30 门槛）；
- `fixup_exception` 钩子 **calls=0 / hit=0 / far_rej=0 / mm_rej=0**——整个窗口 **一次 extable 修复都没有**。
- 若写者是盲目 uaccess store，ON 窗内的尝试必然 fault → fixup；U-A2 的 ON 抑制（0.058）意味着
  被挡下的尝试应与落地同量级（数十次）。**实测 0 次 ⇒ 该路径排除。**
- 写者在写之前**检查了 VMA/PTE 可写性**（或走 GUP 的 `FOLL_WRITE`，在 RO VMA 上直接 -EFAULT、不触发
  `fixup_exception`）。剩余候选：① 用户态写者（U-B1 的 EL0 路径）② PTE/VMA-aware 内核写者（GUP 类）。
- **下一步 = H7：非 remote GUP 族入口钩**（`get_user_pages` / `*_fast` / `pin_user_pages` /
  `internal_get_user_pages_fast` / `__get_user_pages`），记录 `{start, nr, gup_flags, lr, comm}`；
  `lr` 直接是写者函数的返回地址。

## 1. 控制轮（P2/P3，全部通过）

| 步 | 观察 |
|---|---|
| P2 control | `roprobe`（pid 20200，页 `0x7f9b545000`，`mprotect(RO)` 后 `read(/dev/zero)`）→ ring 3 条：`far=0x7f9b545000`、**`pc=0xffffffc00843b32c`**（`__arch_clear_user` 首条 `sttr xzr,[x0]`）、**`lr=0xffffffc0084ea1e0`**（`read_zero` 返回址）、`pid=20200 comm=roprobe`；`read` 返回 -EFAULT（预期） |
| P3 disarm | `echo 0` 后同一 read：`calls` +1、ring 不新增；`far_rej=0 mm_rej=0` |
| re-arm | `echo 1` → `armed=1` |
| restore | `echo restore` → dmesg `restored 0xffffffc008126740 to a9be7bfd (readback a9be7bfd ok=1)` |
| rmmod | `unloaded calls=4 hit=3`、`lsmod` 0 |

⇒ mm 门 + far 门 + 用户页权限故障 → extable → pc/lr/comm 整链**端到端验证**。

## 2. 主窗（脉冲 + fxhook）

| 项 | 值 |
|---|---|
| victim | `scanary_ro_v24 --victim main --pulse 1000,1000 --depth-list 0x1000 --duration 1200`，pid 2564，栈窗 `[0x7fff406c20,0x7fff606c20)` |
| 窗 | insmod → victim end，**1131 s**；armed=1 全程 |
| 脉冲 | `pulses_on=556880`；victim 自身 va_arg 故障 `pulse_vfault=725239`（EL0，siglongjmp 恢复；**不进 fixup**） |
| 落地记录 | **61** 条（`EXIT reason=duration`，`probe_ok=9`，`selftest_ok=1`） |
| fxhook | **calls=0 hit=0 dropped=0 far_rej=0 mm_rej=0** |
| 回滚 | `restored … readback ok=1`；`rmmod: unloaded calls=0 hit=0`；`lsmod` 0 |
| NE | 1949（与上电前一致；本窗 0 条） |

## 3. 判读（预注册 §3 第 4 行）

`ring 0` ∧ 落地 ≥30 ⇒ **不是盲目 uaccess store**；写者**先检查可写性**再写：

- 若是 **GUP with FOLL_WRITE**：RO VMA 上 `get_user_pages*` 直接失败（-EFAULT），不产生 `fixup_exception`；
  U-A2 的 PTE 门控 = FOLL_WRITE 在 VMA/PTE 层的拒绝。与 U-C1 的 H1–H3 阴性**不矛盾**——那三路只钩了
  `*_remote`（`__access_remote_vm`/`get_user_pages_remote`/`pin_user_pages_remote`），**非 remote 的
  `get_user_pages`/`*_fast`/`pin_user_pages` 从未被钩过**。
- 若是 **VMA 标志检查 + 内核别名 store**：U-A2 已排除纯别名/DMA（PTE 门控），但"先查 `vma->vm_flags`
  再经 uaccess store"仍可能；若 H7 也为 0，再转向 `follow_page`/PTE 层。

## 4. 合取后的剩余空间

| 已排除 | 依据 |
|---|---|
| DMA/直接映射/kmap | U-A2（PTE/FOLL 门控） |
| remote-GUP（/proc/mem、process_vm_writev、ptrace） | U-C1 H1–H3 |
| 缺页路径 / ex_table | U-C1 H4/H5；U-E1 calls=0 |
| **盲目 uaccess store（copy_to_user/__put_user/内联 sttr）** | **U-E1：61 条落地 + 556,880 脉冲，fixup=0** |
| 纯 VA-targeted / 内核线程任意写 | U-D1 E1 诱饵 0 |
| "victim 在跑就写" | U-D1 E3 自旋 0 |
| 单包同步/固定流 | U-D1 E5（±20 ms 包源匹配、双向） |

剩余：**非 remote GUP 类**（首选）或 **VMA 检查 + 别名 store**。H7 直接判第一类。

## 5. 采集件

| 文件 | 设备路径 / md5 |
|---|---|
| fxhook_v6.ko | `/data/repro/fxhook_v6.ko` `963f37aa1577466771ac1f2678bd52b9` |
| roprobe | `/data/repro/roprobe` `cde9f04a90508fe7e4264c61e0e3c4a1` |
| ue1_victim.log | `/data/repro/ue1_victim.log` `060bcdb029a68bf81de3fcdc1890771d` |
| 控制轮 dmesg | 见正文（`restored`/`unloaded` 行） |

## 6. 三栏

### [A] 已核实
- P2/P3：用户页 RO 故障 → fixup → `pc=__arch_clear_user sttr`、`lr=read_zero`、`comm=roprobe`。
- 主窗 1131 s / 61 条落地 / 556,880 脉冲 / fixup **0**。
- 回滚干净、NE 零归因。

### [B] 未核实
- 写者身份（H7 待跑）。
- 61 条落地记录的槽位/包源细节（可离线解析 ue1_victim.log）。

### [C] 必须上设备
- H7 非 remote GUP 族钩子（`get_user_pages`/`*_fast`/`pin_user_pages`/`internal_get_user_pages_fast`），
  `lr` 点名；正对照 `vmsplice`（iov_iter → get_user_pages_fast）。
