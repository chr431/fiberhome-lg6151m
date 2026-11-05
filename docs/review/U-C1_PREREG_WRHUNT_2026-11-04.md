# U-C1 预注册 · wrhunt 多入口合围（广覆盖点名轮）

> 日期：2026-11-04 16:20（+0800）｜结果前写定，不得事后放宽。
> 前置：[U-A2_PULSE_RESULT_2026-11-04.md](U-A2_PULSE_RESULT_2026-11-04.md)（PTE 门控 / 非 DMA）、
> [U-B1_FXHOOK_RESULT_2026-11-04.md](U-B1_FXHOOK_RESULT_2026-11-04.md)（ex_table 排除）、
> [U-C1_LOCAL_AUDIT_2026-11-04.md](U-C1_LOCAL_AUDIT_2026-11-04.md)（11 候选、Top-1 = GUP 通道）。
> 本轮目标：**一次联合窗争取直接点名写者**（comm/pid/LR/调用链），不重复单点阴性。

## 0. 为什么改方向（相对 U-B1 §6 的 romap 建议）

U-B1 把 T-03 romap 列为下一步，但三点证据支持本轮的广覆盖合围：

1. **U-B1 `calls=0` 的新解读**：fxhook 只钩 `fixup_exception`（内核 uaccess **失败**路径）。
   以下三类都满足 `calls=0` 且仍是 CPU/MMU 写：
   - GUP 跨进程写（`process_vm_writev` / `/proc/<pid>/mem` → `access_remote_vm`）：
     不经 `__arch_copy_to_user`、不经 ex_table、遇 PROT_READ 时 `FOLL_WRITE` 在 GUP
     阶段直接 -EFAULT ⇒ **与 Phase-2a 的 PTE 门控完全自洽**；
   - 内核成功 `copy_to_user`（内联 `sttr`/`__put_user`）：无缺页，不进 fixup；
   - 用户态写者 RO 写失败：走 `do_page_fault` EL0 分支（发信号），也不进 fixup。
2. **本地审计定论**：全项目（含私有仓）**不存在**「构造 32B 家族形状并写向别的进程 VA」的生产代码；
   `tuphook.c:597-630` 坐实 w2 = `skb->len | ip_hdr(skb)->saddr<<32`（网络包元数据）；
   `PHASE1_REVIEW:68` 亲笔点名 `/proc/<pid>/mem → mem_write → access_remote_vm` 为
   「真正未覆盖」通道（D23/D27 漏斗 + A2 audit 均看不见）。
3. **零风险设备取证**：常驻进程无 `/proc/*/mem` fd、无 in-flight 270/271/117/67 syscall
   （瞬时采样阴性 ≠ 排除；GUP 写可短于采样周期）⇒ 必须入口钩而非快照。

## 1. 装置（wrhunt v3，单模块 5 入口）

### 1.1 钩子清单（入口字节全部离线取自 analysis/kern/vmlinux.elf .text）

| # | 函数 | 补丁点 | 原指令 | 入参（用于过滤/点名） |
|---|---|---|---|---|
| H1 | `__access_remote_vm` | `0xffffffc00824d114` (+4) | `a9b87bfd` | x0=mm, **x1=目标用户 VA**, x2=buf, x3=len, w4=gup_flags |
| H2 | `get_user_pages_remote` | `0xffffffc008247c68` (+4) | `a9bf7bfd` | x0=mm, **x1=start(目标 VA)**, x2=nr_pages, w3=gup_flags |
| H3 | `pin_user_pages_remote` | `0xffffffc008247ca8` (**+8**) | `a9bf7bfd` | 同 H2（覆盖 `process_vm_writev` 主通道） |
| H4 | `do_page_fault` | `0xffffffc008126be0` (+4) | `a9ba7bfd` | x0=far, x1=esr, x2=pt_regs* |
| H5 | `fixup_exception` | `0xffffffc008126740` (+4) | `a9be7bfd` | x0=pt_regs*（对照锚：见 §7 修订） |

H1/H2/H4/H5 的 +0 = `paciasp`、+4 = 可重放 stp、resume +8（与 v5/faultwatch 同规则）。
H3 的 +0 = `tbnz w3,#2,+0x24`（WARN_ON_ONCE(FOLL_GET) 的编译产物，原函数既有行为，
与本钩无关）、+4 = `paciasp`、**+8 = `a9bf7bfd`（可重放 stp）**、resume **+0xc**。
正常 `process_vm_writev` 的 gup_flags 不带 FOLL_GET ⇒ 必走 +8 ✓。
`aarch64_insn_patch_text = 0xffffffc008122394`（当前 boot kallsyms 逐字核对）。

### 1.2 H3 补丁点依据（skeptic V1 修订）

v1 预注册曾以「+0 是 tbnz」为由禁用 H3，导致 P1 正对照
（`process_vm_writev → process_vm_rw_core → pin_user_pages_remote → __get_user_pages_remote`）
**结构上不可能命中任何已装钩子**（skeptic 对 vmlinux 全 .text BL 扫描实证：
`get_user_pages_remote` 只有 3 个调用者，无一来自 process_vm 路径）。
v2 按 skeptic 建议 (a) 启用 H3'：**patch +8、resume +0xc**，离线逐字核对
`+8=a9bf7bfd / +0xc=320e0063 / +0x10=mov x29,sp`，新增第 5 个 shim。
⇒ 实际装载 **5 入口**（H1/H2/H3/H4/H5），真正覆盖 GUP 跨进程写主通道。

### 1.3 统一记录格式（每命中一条）

```
ev hook=H1..H5 j=<jiffies> cpu=<n> far=<目标VA> aux=<gup_flags|esr>
   pid=<current->pid> comm=<current->comm>
   w0..w3=<写入内容前 32B（仅 H1：x2 指向内核 buf）>
```

- **点名字段 = `comm/pid + far + aux`**（本装置不采集栈回溯；skeptic V2 修订：
  v1 预注册承诺的 `tr/lr/pc` 调用链在代码中恒为 0 / 无 `stack_trace_save`，
  判读表已相应降级，见 §3）；
- **H1 独有**：x2 = 内核 `buf`（写入内容源），`copy_from_kernel_nofault` 读 32B →
  **当场判定是否家族形状**；H1 的 nofault 读可能触发嵌套 H4/H5，由 `g_inhook`
  跨 hook 守卫抑制（不占 ring）；
- 全部钩子共用 `wh_record(int hook, unsigned long far, unsigned long aux, void *src)`，
  per-CPU ring 32 槽、O(1) 快路径（不在窗内立即 return），递归守卫，**无栈回溯/无睡眠/无锁**；
- `p_victim="scanary_ro_v21"` 时 victim 自身访问计数但不占 ring（防观测者污染）；
- 过滤窗 = **`[victim_stack_base, victim_stack_top)` 整个 2MB 栈**（不是单页）——
  由 scanary 启动行 `stack=0x.../<size> top=0x...` 取得；窗宽换取覆盖，防 poff 漂移漏判。

### 1.4 装置纪律（全部继承 v5 / faultwatch 已验证模式）

- 每个入口独立 shim（`b .` 占位 + init 算 B-target 回填 + 反解自检；**不使用数据符号 adrp/add**——v2 UNDEF 事故）；
- 所有计数器 `DEFINE_PER_CPU` + `sum_*()`（v4 percpu 幻影地址事故）；
- 入口字校验 + site 校验 + 补丁回读，任一失败 ⇒ 全部回滚 + 装载失败；
- go/no-go 探针用**内核 VA** `0xffff800000000000`（v4 PAN 事故）；
- `armed=0` 直到 all go/no-go 通过（init 尾部自动 `armed=1` 的偏差同 U-B1 §H，
  靠「观察窗 hit=0」硬判据兜底）；
- `.proc_lseek = no_llseek`（**skeptic S1 修订**：v1 用 `seq_lseek` 但无 `.proc_open`
  ⇒ `private_data=NULL` ⇒ 任何 lseek 在 `mutex_lock(&m->lock)` NULL-deref panic；
  `no_llseek` 返回 -ESPIPE、不碰 private_data，已确认 `EXPORT_SYMBOL`）；
- **/proc/wrhunt 仅 `cat` 读、`echo` 写；禁 dd/xxd/tail/head/seek 类工具**（双保险）；
- rmmod 逐点恢复 + 逐点回读 `ok=1`（skeptic 约束 1，**5 行都要看**）。

## 2. 正对照（预注册必过，否则 INVALID）

| # | 对照 | 期望 |
|---|---|---|
| P1 | 自建 helper 对 victim 栈内已知 VA 做一次 `process_vm_writev` 写 32B magic | **H3**（`pin_user_pages_remote` +8 补丁）必须出现 ≥1 条 `comm=<helper>`、`far∈窗`、`aux&FOLL_WRITE`；v1 曾期望 H2，skeptic 实证 process_vm 路径不经 H2，已按 V1 修订 |
| P2 | helper `open("/proc/<victim_pid>/mem", O_RDWR)` + `pwrite` 32B | **H1** 必须出现 1 条且 `w0..w3` = 写入的 32B；同时 **H2** 应出现 1 条（skeptic 实证 `mem_rw → access_remote_vm → get_user_pages_remote` 顺序链） |
| P3 | 已知内核 uaccess 失败正对照（内置 go/no-go 探针同机制） | **H5** 必须 +1（U-B1 已证可达）；P3 只验 H5 钩子存活，不计入联合窗判读 |
| P4 | 负对照：`echo 0 > /proc/wrhunt` 后重复 P1 | ring 不新增（calls 可增） |

任一正对照失败 ⇒ **本轮 INVALID，先修仪器，不得读联合窗数据**。

## 3. 判读表（结果前写死）

联合窗 = victim **RW 正常运行**（`scanary_ro_v21 --victim main --depth-list 0x1000 --ro 0`
等价形态，无 mprotect、无脉冲、无停放）+ wrhunt 全程 armed，≥900 s；同窗 scanner 命中作活性锚。

| 观察到 | 判 | 等级 |
|---|---|---|
| H1/H2/H3 出现 `far∈窗` ∧ `comm≠scanary_ro_v21` ∧ 内容=家族形状（或 aux&FOLL_WRITE） | **当场点名：写者 = 该 comm/pid，路径 = GUP 跨进程写**（H3⇒process_vm_writev；H1/H2⇒/proc/pid/mem） | **E4** |
| H4 出现 `far∈窗` ∧ `comm≠scanary_ro_v21` ∧ esr=permission/write | **用户态/内核权限写缺页点名（comm/pid + far + esr；本装置无栈回溯，见 §1.3）** | **E4**（身份）/E2（调用链缺） |
| H4 出现但 `comm=scanary_ro_v21` | victim 自身访问，`p_victim` 过滤后只计 calls 不占 ring；若因未传 victim 参数而入 ring ⇒ 记录后排除 | 装置注记 |
| H1–H4 的 ring 中无 `comm≠victim` 条目（`calls` 可增，含 scanary 自身）且 scanner 命中 ≥10 | 「有检出能力的多路径阴性」⇒ 写者不走 GUP/页故障/内核 uaccess 任一入口；结合 U-A2/U-B1 ⇒ **剩余 = 内核成功 uaccess 内联 store 或私有驱动缓存 VA 写** | E2（机制收窄，非点名） |
| 某路 `calls=0`（**H5 除外**——H5 以 0 为正结果，见 §7；其存活性由 go/no-go + P3 证明） | 该路钩子失效 ⇒ 该路数据作废（其余路仍可判） | 部分 INVALID |
| 正对照任一失败 | 整轮 INVALID | E0 |

**功效门槛**（同 U-A2 §2 纪律）：联合窗 scanner 页内 inj=0 命中 **≥10** 才允许下阴性；
<10 ⇒ INVALID-by-confound（不开判）。窗长 ≥900 s，期望 λ≈3.6–8.6/min ⇒ 54–129 事件。

## 4. 暴露核算

| 参数 | 值 | 来源 |
|---|---|---|
| 同状态 λ | 开窗前 300 s RW 预检实测 | U-A2：前臂 48.1/min、后臂 8.6/min、联合窗 3.6/min（时段波动大） |
| 窗总长 | ≥900 s | 本轮设计 |
| 期望事件 | λ × 15 min ⇒ **54–720** | 低流量时段取 54 仍 ≫10 |
| 正对照 | 4 项 | §2 |

## 5. 执行序列

```
0. 离线：vmlinux.elf 入口字复核（含 H3 +8/+0xc，已做）；wrhunt.c 编译 + .ko 五元组落 FIVETUPLE.txt
1. deploy.py put → md5 双核 → chmod 644（.ko 不需 exec）
2. 300 s RW λ 预检（victim 正常跑，取 stack/top 与命中率）→ ≥10/300s 才继续
   **此后全程用这同一个 victim 进程（V3 单实例方案）**
3. devop 持锁 insmod wrhunt_v3.ko lo=<stack_base> hi=<stack_top> victim=scanary_ro_v21
   （**victim 参数必传**，否则 victim 自身缺页入 ring 触发 §6.2 作废；
   insmod 前先 `cat /proc/<pid>/comm` 逐字比对）
   → 5 入口逐点 go/no-go；观察 dmesg：5 行 hook 成功、B-target 自检、GO/NO-GO ok
4. **echo clear > /proc/wrhunt**（skeptic V2：归零 5 路 g_calls，建立干净 H5 锚）
5. 10 min 零实验观察窗（各路 hit=0；H4 全局热钩子，装置存活即自测其 shim）
6. 正对照 P1–P4（自建 helper，见 §2 修订版）
7. **echo clear > /proc/wrhunt**（清掉正对照记录）→ **echo 1 > /proc/wrhunt**
   （**V3 关键**：P4 负对照已把 armed 置 0；不 re-arm 则联合窗 hit 恒 0 而 calls 照增，
   会被误读成「多路径阴性」）
8. 联合窗 ≥900 s（**不重装模块**：lo/hi 是 0444 只读，不能换窗；全程同一 victim 同一栈窗；
   若 victim 意外死亡 ⇒ 作废重来（含重新 insmod））
9. 窗末**仅 cat /proc/wrhunt**（禁 dd/seek/xxd/tail/head）
10. echo 0 > /proc/wrhunt → **rmmod wrhunt_v3** → dmesg **5 行** `restored ... readback ... ok=1`
    ＋ 1 行 `unloaded calls:H1=.. H2=.. H3=.. H4=.. H5=..`（5 路标签一一对应，S2 已修）
    （缺任一行 ⇒ incident，LK 救砖待命，不二次 rmmod）
11. NE 台账 / nerepair dry / 单实例前后对账
```

## 6. 作废条件

1. 任一入口 go/no-go 失败、入口字不符、补丁回读失败；
2. 观察窗任一 `hit≠0`；
3. 正对照 P1–P4 任一失败；
4. 联合窗 scanner 命中 <10（暴露不足）；
5. 页/栈窗漂移（victim 重启或 stack base 变化）未重新对齐；
6. 任何 oops / RCU stall / panic 迹象 ⇒ 停止一切，LK 救砖待命（tools/lk_flash_v4.py）；
7. rmmod readback 失败 ⇒ incident 流程。

## 7. 与 U-B1 的关系

U-B1 的 fxhook v5 结论（ex_table 排除）**继续成立**；本轮不推翻，是把「未覆盖通道」
从猜测做成可观测。

**H5 对照锚的精确定义（skeptic V2/V4 修订）**：go/no-go 探针自身触发一次
`fixup_exception`，H1 的 `copy_from_kernel_nofault` 读坏内核 buf 也可能触发 H5 ⇒
insmod 后 `sum_calls(H5) ≥ 1` 是**装置噪声**，不是环境变化。判读只用
**step 7 的第二次 `echo clear` 之后、联合窗内的 H5 调用数**（step 4 与 step 7 各清一次，
数值等价；step 6 的 P3 会给 H5 +1，故基线以 step 7 为准）：
若为 0 ⇒ 与 U-B1 一致（ex_table 路径继续未命中）；若 >0 ⇒ 记录为装置内噪声或新现象，
**不改变 U-B1 结论本身**。注意 H5 是唯一以「calls=0」为正结果的钩子，不得套用 §3 的
「某路 calls=0 ⇒ 失效」规则。

若本轮 H1/H2/H3 点名 ⇒ 解释 U-A2 全部约束（PTE 门控 = FOLL_WRITE 在 GUP 阶段被 VMA
权限拒绝；非 DMA = GUP 走 CPU 页表；受害者运行态 = GUP 需要活 mm；不绑定每轮 =
流量/墙钟驱动），一次闭环。
