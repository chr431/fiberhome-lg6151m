# U-E1 预注册 v2 · 脉冲 + fixup_exception 点名（pc/lr/comm）

> 日期：2026-11-04 21:50（+0800）｜v2：按 [U-E1_SKEPTIC](U-E1_SKEPTIC_2026-11-04.md) M1–M9 修订
> 前置：U-A2（脉冲装置已验证 1200 s）、U-B1（fxhook v5 已验证）、U-C1（remote-GUP/缺页/fixup 排除）、
> U-D1（诱饵 0 / 同槽 sp_call-0x100 / 自旋 0 / busy 483 / 热静 CPU 3× / 包源匹配 169/173）。
> **本轮是两条已验证装置的乘积：脉冲臂 + fixup 钩子；此前从未同窗运行。**

## 0. 一句话假设

写者是**内核态 uaccess store**（`copy_to_user`/`__put_user`/内联 `sttr`），在 victim 上下文写入其栈槽。
U-A2 已证：页 RO 时落不下去（ON-fraction 0.058）。若写者在 ON 窗尝试，必进入 extable 修复路径
`fixup_exception(pt_regs*)`；`regs->pc` = 故障指令，`regs->regs[30]` = 调用者 = 写者。
U-B1 的 `calls=0` 是 **RW 窗** 测的（无故障），与 U-A2 不矛盾；同窗跑一次即可点名。

## 1. 装置与参数（M1 修订）

| 件 | 值 / 说明 |
|---|---|
| 脉冲臂 | `scanary_ro_v24 --victim main --ro 1 --pulse 1000,1000 --depth-list 0x1000 --cycle 0 --duration 1200` |
| 模块 | `fxhook_v6.ko`（md5 `963f37aa1577466771ac1f2678bd52b9`）：v5 + vpid mm 门 + `restore`/`probe` 命令 + far/mm 拒绝计数 + resume 修正 |
| insmod | `insmod fxhook_v6.ko lo=<stack_base> hi=<stack_top> vpid=<victim_pid> site=0xffffffc008126740 patchfn=0xffffffc008122394` |
| **site** | **`0xffffffc008126740`**（fixup_exception+4；`+0=d503233f paciasp`、`+4=a9be7bfd`、`+8=910003fd mov x29,sp`）。v1 误写为 +0x744，已改 |
| 过滤 | `far ∈ [lo,hi)`（2 MB 整栈）∧ `mm = current->mm ?: active_mm == victim_mm`；两门都有拒绝计数（`far_rej`/`mm_rej`） |
| 记录 | per-CPU ring 16：`{jiffies, far, pc, lr, pid, comm}`；`pc` 是故障指令、`lr` 是调用者 |

## 2. 正/负对照（M2–M4 修订；不过则 INVALID）

| # | 对照 | 期望 |
|---|---|---|
| P1 | insmod 内置 go/no-go：`copy_from_kernel_nofault(0xffff800000000000)` | `calls` ≥1、dmesg `GO/NO-GO ok`（U-B1 已证） |
| **P2** | **控制进程自写 RO 页**：`roprobe`（md5 `cde9f04a90508fe7e4264c61e0e3c4a1`）mmap 一页→`mprotect(RO)`→每 5 s `read(/dev/zero, 页, 32)`；另装一轮 `vpid=<roprobe pid> lo=<页> hi=<页+4096>` | ring 出现 `far=<页>`、`pid=<roprobe tid>`、`comm=roprobe`、**`pc=0xffffffc00843b32c`**（`read_zero → clear_user → __arch_clear_user` 的首个 `sttr xzr,[x0]`；**不是** `__arch_copy_to_user`）、**`lr=0xffffffc0084ea1e0`**（`read_zero` 里 `bl __arch_clear_user` 的返回址）；`read` 返回 -EFAULT（rc=-1 errno=14）是预期，不要求 rc>0。这是对 mm 门+far 门+故障类+ring 的唯一端到端正对照 |
| P3 | `echo 0 > /proc/fxhook`（**正确路径，不是 /proc/fxhook/armed**）后重复 P2 的 read | ring 不新增（`calls` 可增；`mm_rej/far_rej` 不应增加） |
| P4（可选） | `vpid=<control>` 时从**另一个进程**读其 RO 页（或在 shell 里 `echo probe`） | `mm_rej` +1、ring 不新增 ⇒ 证明 mm 门确实在拦 |

P2/P3 后必须 `echo clear > /proc/fxhook`（M4），P3 后必须 `echo 1 > /proc/fxhook` 并 `cat` 确认
`armed=1`（M3，U-C1 V3 复发点）。

## 3. 联合窗与判读（M7/M8 修订）

联合窗 ≥900 s（目标 1200 s）：脉冲臂 + fxhook armed。**开窗后先跑 60–120 s armed 预窗**（M7），
`cat` 确认**无 `comm=scanary_ro_v24` 记录**；若有，先查是否 victim 自身内核态 uaccess，未查清不得续窗。
判读用 **comm**：`comm ≠ scanary_ro_v24` = 外部写者；`comm == scanary_ro_v24` = 仪器自身/受害进程
（tid 仅用于拆 main/helper，不用于区分"外部"）。

| 观察 | 判 | 等级 |
|---|---|---|
| ring 出现 `far∈窗` ∧ `mm=victim` ∧ **`comm ≠ scanary_ro_v24`** | **当场点名：pc=故障指令、lr=调用者、comm/pid**；按 kallsyms 反解 | **E4** |
| ring 出现 `far∈窗` ∧ **`comm == scanary_ro_v24`** | 装置注记（victim 自身或其 helper 线程的内核态 uaccess）；记录但不判写者 | 注记 |
| **设备 panic**，die 消息为 `access to user memory outside uaccess routines` 且故障 PC 在窗内 | **正面点名**：写者是"无 extable 的内核 store"；立即采集 console/ramoops（panic=10 会重启并消耗 TRY_A 一次） | **E4（破坏性）** |
| ring 0 条，同窗落地记录 **≥30** | **不是"盲目 uaccess store"**；候选 = ①用户态写者（U-B1 的 EL0 路径）②PTE/VMA-aware 内核写者（GUP 类或先查 VMA 再 store，U-A2 已排除纯内核别名写）。下一步 = 非 remote GUP 族（H7） | E2（收窄） |
| ring 0 条且落地 <30 | INVALID-by-exposure | — |
| P1–P4 任一失败 | 整轮 INVALID | E0 |

**暴露门槛≥30**（M8④）：U-A2 的 50/1200 s 是"盲目 uaccess"的期望；30 条把 P(0) 压到 ~1e-13。
**victim 早死/窗截断预案**：若 victim 在 <900 s 内死亡（U-B1 245 s 先例），本窗作废，重启 victim + 重装模块。

## 4. 作废/回滚（M5 修订）

1. go/no-go 失败 / 入口字不符 / 补丁回读失败；
2. **`echo restore > /proc/fxhook` 后 `dmesg` 无 `restored … ok=1`** ⇒ 立即 `sysrq-b`（**不 rmmod**，避免补丁指向已释放模块内存）；
   注意：`restored` 行由 `echo restore` 打印在 **dmesg**，不是 `/proc/fxhook`；
3. **restore 成功后 `g_patched=0`，rmmod 的 exit 只打印 `unloaded calls=… hit=…`，不会再有 `restored` 行——这是正常**；
   只有 `echo restore` 未执行/失败时 exit 才会再走 fx_remove；缺 `unloaded` 行或 restore 失败 ⇒ `sysrq-b`，不二次 rmmod；
4. 任何 oops / panic / RCU stall（panic 分支按 §3 判读并采集）；
5. victim 栈基址/top 与 insmod 不一致（重启/重跑）⇒ 重新对齐；
6. 联合窗落地 <30。

## 5. 执行序列（v2）

```
0. 本地：fxhook_v6.ko（963f…）+ roprobe（cde9…）+ scanary_ro_v24（a10f…）；五元组入 FIVETUPLE
1. 设备：/proc/kallsyms 核对 fixup_exception=0xffffffc00812673c；lsmod 无 wrhunt/fxhook
2. P2/P3/P4 控制轮：起 roprobe → 读 pid/page → insmod vpid=<roprobe> lo=page hi=page+4096
   → go/no-go → echo clear → P2 read → cat（期望 pc 在 __arch_copy_to_user）
   → echo 0 → P3 read → cat（ring 不新增）→ echo 1 → cat（armed=1）
   → echo restore → cat（restored ok=1）→ rmmod（readback）
3. 主轮：起脉冲 victim（1200 s）→ 读 stack/top/pid → insmod vpid=<victim> lo/hi=栈窗
   → go/no-go → echo clear → **60–120 s armed 预窗**（无 scanary 记录）
   → 续窗至 ≥900 s → 窗末 cat /proc/fxhook
   → echo restore → cat（ok=1）→ rmmod（readback 行）
4. 离线：pc/lr 按 kallsyms 反解；与 U-D1 的槽位/触发条件合取
5. NE 台账 / nerepair dry / 单实例
```

## 6. 版本（M9）

| 件 | md5 |
|---|---|
| fxhook_v6.ko（M1–M8 修订后重建） | `963f37aa1577466771ac1f2678bd52b9` |
| roprobe | `cde9f04a90508fe7e4264c61e0e3c4a1` |
| scanary_ro_v24 | `2b9c22d4073196e57a4c03ba1c909ea2` |

## 7. 修订记录

- v2（2026-11-04 21:50）：M1 site 地址改正 + P2 pc 预期改正；M2 P2 改为控制进程自写 RO 页（roprobe）；
  M3 补 `echo 1`+确认；M4 补 `clear`；M5 增 `echo restore`+sysrq-b 规则+回滚严格化；
  M6 resume 改为 `p_site+4`（`mov x29,sp`）并重建；M7 增 armed 预窗/tid 判读；M8 增 panic 分支、
  改"ring 0 ⇒ 非盲目 uaccess"、删 far∉窗条款（改为 far_rej 计数）、门槛 ≥30、补 victim 早死预案；M9 五元组。
