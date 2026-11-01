# VERDICT v2 · 32B 记录 SIGSEGV 家族（2026-11-01 重写，取代 2026-10-31 版）

> 本文件是**对外主结论**。级别：E1 弱/单点 · E2 强推断 · E3 直接观测 · E4 因果闭环。
> 每条都带「复核」入口。**已撤回的旧结论**（88/112、自然 NE 0/4、「Transport = PA/DMA（E2）已定」、
> 「Writer = WED TX」）不得再引用，理由见 §3 与 [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md)。

---

## 0. 一句话

**一个来自进程外部的 32B 结构化写入，落在受害进程「活着的」va_list 上，把它打坏后导致 SIGSEGV；
写入的普遍性远高于崩溃率（健康 daemon 栈上也有稳定被反复重写的槽）。
写入者身份仍未点名；传输方式是「按 VA 解析」还是「按 PA 写」尚未判决。**

- 写目标 = 活栈帧内的 va_list（**E3**，见 §2.1）。
- 记录的**载体形态** = 两个 16B 槽 `{u64 值; u64 0}`（**E3**，见 §1）。
- 已**证伪**：固定物理页 + 固定页内偏移、固定栈顶相对偏移、EDMA RX 描述符、WED TXD、硬件描述符写回（§3）。
- **未排除**：H2 内核 uaccess；H5 GUP-pin + 按 VA 取偏移；H6 内核用保存的用户 sp 定位；H7 某写入方按进程缓存「最近一次 va_list 地址」。

---

## 1. 记录是什么（结构身份）

### 1.1 字节布局（E3，109/117 份可定位）

```
偏移   内容
+0x00  u64  值1：17–18 位小值 A（归一化后 48957–165456），或 (addr<<32|len)
+0x08  u64  恒 0
+0x10  u64  值2：内存字节序就是 {u32 len; __be32 addr}
+0x18  u64  恒 0
```

- **A/B 两型不是两种载荷**：va_arg 的自增（+8）作用在 `__stack` 字段上——A 型它落在偏移 0，B 型落在偏移 +0x10（表现为 len+8）。
  归一化后**只有一种载荷**：`{A, 0, {len, addr}, 0}`（**E3**，脚本 `_local/work/crash-root/static/formlen.py`）。
- **不要建模成打包 int64**：内核里没有"低半放长度"的先例；按"相邻两个字段 `{u32 len; __be32 addr}`"读更稳（**E2**）。
- len 实测 `{321, 1600, 1601, 4416, 4480}`（+8 变体）；addr 是**流端点地址**（82% 为同一公网对端、少量为本机 WAN/LAN/别名）。
- A 值域 `[0xBF45, 0x28658]` 与历史 `SIGSEGV_ANALYSIS.md §2.1` 的"长度型 16B 块 {small,0}"（small∈[0x2710,0x40000]）**重合**；
  形状与 §14「PIT 表项 16B {u64 PA, u64 0}」一致 ⇒ **与历史注入同族**（**E2**；历史那条载体是 MD 侧，仅作形态对比，不作独立证据）。

### 1.2 它不可能是什么（否证见 §3）

不是 EDMA RX 描述符、不是 WED TXD / WPDMA TX 环条目、不是信号帧、不是 `put_cmsg` 家族、不是 splice/sk_msg 的用户 iter。

---

## 2. 它落在哪里（这是本轮最硬的一组观测）

### 2.1 写目标 = 活栈帧内的 va_list（**E3**）

scanary 自扫描金丝雀（自带 8 MB 诱饵区、每 5 ms 全扫、崩不崩都记），正式臂 900 s：

| epoch | D（人为加深调用帧） | 命中数 | topva（扫描上界−记录 VA） | 残差 |
|---|---|---|---|---|
| ep0 | 0 | 218 | 0x690 | 0 |
| ep1 | 0x100 | 203 | 0x790 | 0 |
| ep2 | 0x400 | 226 | 0xa90 | 0 |
| ep3 | 0x900 | 191 | 0xf90 | 0 |
| ep4 | 0x1000 | 231 | 0x1690 | 0 |

- `topva` 增量**精确等于 D**，残差 0/0/0/0/0；`spva` 恒 0x210；诱饵区记录命中 **0**；HIT_REWRITE 0；passes 177,041。
- **ep4 的受害页 PA（0xad5a4790）与 ep0（0xc69b7790）不是同一页**，仍 231 条命中
  ⇒ 「固定 4KB 页 / 固定页内偏移 / 固定栈顶相对偏移」**三种模型同时出局**。
- 由此**推出**：H1a（固定 PA 陈旧描述符）、H1b、H3（内核直映射写固定 `__va(PA)`）、H5-as-pure-PA 全部被否证。
- 复核：`docs/SIGSEGV/05_LOG/2026-11-01-kdev-scanary-romap-ptredir.md` + 设备 `/data/repro/scanary_A.log`。
- 限制：单臂；只覆盖 scanary 自己的 victim 线程；**"写入者来自外部"仍非 E3**（受害者自写也会呈现帧相对）。

### 2.2 写入是普遍的，崩溃只看落点（**E3/E2**）

- **自然长驻 daemon 栈上有稳定记录槽**（sampler2，零模块：150 ms/轮读 `/proc/<pid>/mem` 的 `[start_stack−32K, start_stack)`）：
  - `dnsmasq` pid 22033：`start_stack−0x1b40`，113 次采样内容恒定（`q0=0xe48f, len=1601, addr=192.168.9.1`）；
  - `nerepair` pid 9837：`start_stack−0x3b0`，60 s 内观察到 **8 种不同 q0**（同一 VA 被反复重写）；另有 `start_stack−0x12d0` 槽。
  - **命中时这些进程都阻塞在 wait4 / ppoll** ⇒ 写入者**不需要目标进程执行**。
- **健康进程栈也含记录**：12 份健康 `sh/ash` 栈里 **2 份 / 6 条**（strict 判据，含 `len=1601+192.168.9.1` 的 canary 家族型）。
  ⇒ **"崩溃数"只是写入数的极小下界**；记录率必须用非崩溃采样（sampler2 / .stack）测。
- 复核：`_local/evidence/crash-root/natctl/`、lab 的 `sampler2.log`。

### 2.3 自然 NE 的影响面（**E2**，致死率待定）

- 13:02–13:06 的 4 起自然 NE（`sh cfg_heal` ×2 / `tr` / `tail`）的 `.stack` **4/4** 含**与 canary 完全相同的 Q2**
  （`0x04D08ADE0000062F` = len 1583 + 222.138.208.4），多份拷贝。
- **但"记录在场"≠"记录致死"**：core_meta v1.10 的 `natne/*.txt` **不含 fault addr / 寄存器**，`ne_events.tsv` 也无 addr 列
  ⇒ fault 对齐（`F==q0` 或 `F==tagstrip(q0)−8`）**当前无法执行**。
  补救：开 `show_unhandled_signals`（只影响日志）让下一批 NE 在 dmesg 打出 `unhandled ... fault (11) at 0x...`。

---

## 3. 已证伪清单（**不要再引用旧结论**）

| # | 旧结论 | 否证依据 | 级别 |
|---|---|---|---|
| X-1 | 记录 = EDMA RX 描述符 / C-138 | 记录 q0 非 page_frag 形态（`mod4096` 只可能 0x40/0x7c0）、q1=0 ⇒ DD=0、len 有 4416/4480 > 驱动 1536 上限；反汇编确认描述符里无 L3/L4 地址字段 | **E3** |
| X-2 | 记录 = WED TXD / C-145 | `TMAC_TXD_0..7` 8 字 32B 但无 L3/L4 地址；WPDMA TX 环实测 16B `{PA_lo,ctrl,PA_hi,0}` | **E2** |
| X-3 | 固定物理页 + 固定页内偏移（C-160 推论） | 75 pid / 53 种页内偏移**全部**崩；固定偏移模型预测只有 1–2 种能崩（P≈0） | **E3** |
| X-4 | 固定栈顶相对偏移 | scanary 5 档：命中点随 D 等距平移，残差 0 | **E3** |
| X-5 | 硬件描述符"写回 L3/L4" | 厂商模块无 BTF/DWARF；WED 族已排除；len 是软件量（1601/1664 > 1536 DMA 上限） | **E2** |
| X-6 | 信号帧 | 目标在活 sp **以上** 0x22b0；信号帧恒在 sp 以下 | **E3** |
| X-6b | **H1a 固定 PA 陈旧描述符 / H1b 陈旧固定 PA / H3 内核直映射写固定 __va(PA)** | 三者都预测"目标与活帧无关"：只要帧一变（D 档），命中就该消失或落到固定位置。实测 5 档全部随 D 等距平移（残差 0）⇒ 三者被否证。**注意：H5（每次按当前 VA 重新 pin）不受此否证**——它每档都可重新 pin 到当前 VA。 | **E3** |
| X-7 | `put_cmsg` 家族 | cmsg_len 排不出 A；level=0+type=0 无定义；无跨 syscall 缓存用户指针的窗口 | **E2** |
| X-8 | `pipe_to_user`/`sk_msg_recvmsg` | 两者 dst 都是**本次 syscall 自己的 iov**；受害者不可能让它们指向自己栈 | **E3**（源码级） |
| X-9 | `C-137` 88/112 与"三副本" | 复算 82/112（Wilson 95% CI 64.3–80.5）；x2−0x130 那份是 ASCII 十进制数字伪影 | **E3** |
| X-10 | 自然 NE 记录份额 0/4（上界 49%） | 新一批 4/4 含同族记录（精确 Q2）；健康基线 2/12 | **E2**（存在率） |

> 注：`C-160「命中页固定 PA」`本身是**重言式**（对同一 pid 反复解析同一 VA，PA 必然相同），已降 E1 并撤回。

---

## 4. 未排除与下一步判决（按成本排序）

| # | 假设 | 级别 | 判决实验 | owner |
|---|---|---|---|---|
| H7 | 某写入方**按进程缓存「最近一次 va_list/栈地址」**，活动时随帧更新、静止时不变 | E2 | sampler2 槽事件序列 + `(sp−rec_va)`/`(start_stack−rec_va)` 分布 | lab |
| H2 | 内核 **uaccess** 写（`copy_to_user`/内联 `sttr`） | E2 | uwhook（钩 `__arch_copy_to_user`，命中即 lr=写入者）+ fxhook（钩 `fixup_exception`，配 RO 受害者页） | kdev+lab |
| — | **VA 解析 vs PA 写**（总判决） | — | **pte_redirect 打在"阻塞 daemon 的稳定槽"上**：新页 Q 出现记录 ⇒ VA 解析；旧页 P 继续出现 ⇒ PA 写；两边不变 ⇒ INVALID | kdev+lab |
| H5 | GUP-pin 页 + 按 VA 取偏移 | E1 | `struct page` 五元组（`_refcount−_mapcount−1`）：受害页有额外引用 ⇒ 相容 | kdev |
| H6 | 内核用**保存的用户 sp** 定位 | E1 | 只读模块读 `task_pt_regs(tsk)->sp`，比较 `top−va` 与 `sp_saved+K`（换 wait4/ppoll 两种栈深） | kdev+lab |
| H1b/H3 | 按 PA 写 / 直映射写 | E1 | romap（`set_memory_ro(__va(PA))`）：写入继续 ⇒ 绕过 MMU；出内核 fault ⇒ 直映射 store（PC=身份） | kdev+lab |
| — | MD/SCP 侧 | E1 | 在 MD 共享区搜受害栈 VA（正对照：先搜到 `bat_va`） | lab |

**内核模块仪器路线在本机已封闭（E3，三次实证事故）**：uwhook（13:23，shim 返回地址编码错）、pte_redirect（13:35，把 `alloc_page` 内核页直接塞进用户 PTE ⇒ pfn 双重归属）、
uprot（13:56，只改权限位仍打崩）——**三次非计划重启，全部由仪器引起、非缺陷本身**；pstore 全文已留存。
⇒ VA vs PA 的最终判决**本会话未取得**，且**不应再在这台 panic_on_oops=1 的机器上用内核模块尝试**；
下一轮建议：①重编内核开 KPROBES 做页级判决；②用长驻 daemon 的自然热槽做**纯用户态**观测（sampler2 已证明可行）；③在有独立测试机的条件下再做 PTE 实验。

**诚实的边界**：393/685 个用户写站点未解析、内联 `__put_user`/`sttr` 不在扫描口径、169 个厂商 `.ko` 无 BTF/DWARF、
SRAM/MMIO 未扫。任何"AP 侧已无处可指"的说法都只在这三个口径内成立。

---

## 5. 复现与证据索引

| 内容 | 位置 |
|---|---|
| 记录形状/分类/上下文 | `_local/work/crash-root/static/{ab_form,formlen,page_records,payload_scan,recscan}.py` |
| 反汇编语料（vmlinux / ko） | `analysis/kern/vmlinux.elf`、`analysis/vendor/mods/5.15.134/` |
| canary 深度臂 | `tmpfiles/repro/scanary/`（PROTOCOL.md）+ 设备 `/data/repro/scanary_A.log` |
| 系统级栈监视器（sampler2） | 设备 `/data/repro/sampler2.log`；主机脚本 lab lane |
| 自然 NE / 健康基线 | `_local/evidence/crash-root/{natne,natctl}/` |
| 台账（162 条 claim） | `01_CLAIMS.tsv`（`python ../../tools/oneoff/sigsegv/claims_check.py`） |
| 记分卡 | [11_TRANSPORT_SCORECARD.md](11_TRANSPORT_SCORECARD.md) |
| 修复 | [FIX.md](FIX.md) |

---

## 6. 一句话给厂商/内核侧

> EDMA/WED 的 RX/TX 描述符族与本记录无关（已字段级否证）。本记录表现为「每 16B 槽 `{u64 值, u64 0}`」的写入，
> 目标精确落在用户态**活着的 va_list** 上，且在目标进程阻塞于 `ppoll`/`wait4` 时依然发生。
> 请在 **MD/SCP 侧**与 **AP 侧一切"缓存用户指针后再写"的路径**（含厂商私有 ioctl/driver）中排查该 32B 写。
