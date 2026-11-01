# 05_LOG · 2026-11-01-07 · A6 三次仪器事故 pstore 复盘（离线取证 + 设备当前 pstore 核对）

## 1. 问题
2026-11-01 三次仪器引发的设备重启（uwhook 13:23 / pte_redirect 13:35 / uprot ~13:47-56）各是
「仪器自伤」还是「拦截到外部写入者」？尤其 uprot：若其 boot console 里存在
「内核态非 uaccess store 打 RO 用户页」的 data-abort Oops（EC=0x25、无 ex_table fixup），
则 fault PC 即写入者指令（E3 级白捡证据）。

## 2. 假设
- H1（白捡）：uprot 置 RO 后，外部/内核写入者经该 VA 写入触发 permission-fault Oops，PC=写入者。
- H0（自伤/无 Oops）：三次事故全部为仪器自身缺陷或无 Oops 的 hang；uprot 无 fault PC 可符号化。

## 3. 预测
- H1 为真：当前/存档 pstore 含 `Internal error: Oops` + EC=0x25 + FSC=permission fault + PC 可符号化到 vmlinux/ko。
- H0 为真：uwhook=IABT（shim 返回地址错）、pte_redirect=Bad page state、uprot 的 boot console 无任何 Oops/BUG（hang→healthdog）。

## 4. 判据
- PASS(H1)：在 uprot boot 的 console 里找到 data-abort Oops；且经 vmlinux `__ex_table` 段验证该 PC 无 fixup 项。
- FAIL(H0)：uprot console 零 Oops/BUG 行（grep `Oops|BUG:|Internal error|Call trace` = 0）；另两份按既有归因复核。
- INVALID：pstore 文件缺失/截断到无法判读；或当前设备 pstore 与本地存档 md5 不一致且含无关新 panic（另行存档后再判）。

## 5. 样本量/功效
- N=3 份事故（全集，非抽样）。符号化 = vmlinux.elf symtab（47910 符号）+ /proc/kallsyms。
- 检出下限：console-ramoops-0 定长 262,132 B；Oops 文本若在截断尾巴之外则丢失——以文件实际内容为准。

## 6. 混杂与控制
- pstore 只留 console 输出（printk console loglevel 之外的不留）→ insmod/selftest 的 pr_info 可能缺席，不能以「无 uprot 日志」推断未运行。
- uptime→挂钟换算不可靠（无 RTC）：以 lab 侧时间线交叉，不做 epoch 心算。
- 符号化地址必须是当时 boot 的地址：vmlinux 符号恒定（无 KASLR 于模块前）——内核 text 有 KASLR 偏移 0x100000，需按 pstore 自带 `Kernel Offset` 行修正。

## 7. 停止规则
纯离线 + 只读 SSH；设备当前 pstore 只做 `ls/md5sum` 与必要的 `cat`（无写入）。

## 8. 分析计划
- 主终点：三份各一条判决（自伤/拦截/无 Oops-hang）+ uprot 是否存在可符号化 fault PC。
- 次终点：CONFIG_ARM64_PAN 状态登记；uwhook IABT 地址与 `__arch_copy_to_user` 期望返回地址的块级比对。

## 9. 变更记录（实验前）
- 证据：`_local/evidence/crash-root/{pstore,pstore2,pstore3}/console-ramoops-0`（md5 见 INDEX.md）。
- 符号源：`analysis/kern/vmlinux.elf`、`analysis/kern/kallsyms.txt`、`analysis/kern/config-extracted.txt`。
- 设备 boot：uptime≈20,874 s（单 boot 自 13:5x 起），当前 `/sys/fs/pstore/console-ramoops-0` md5=30cf05f28e5bbc4af5200391078b9f43（=pstore3）。
- 注意：任务书称「三份全文已留存」，但 C-175/05_LOG §12 记录 uprot 当时「未及抓 pstore」——本实验就是要核对 pstore3 是否就是 uprot boot（md5 一致性 + 内容时间线）。

## 10. 结果
（实验后追加）

## 11. 判决
（实验后追加）

## 12. 偏差与教训
（实验后追加）

## 10. 结果（2026-11-01 执行）

**证据定位**：`_local/evidence/crash-root/{pstore,pstore2,pstore3}/console-ramoops-0`；
设备当前 `/sys/fs/pstore/console-ramoops-0` md5=`30cf05f28e5bbc4af5200391078b9f43` **与 pstore3 逐字节一致**
（设备自 13:5x 起 single-boot，uptime≈20,874 s）⇒ uprot 那次 boot 的 console 就是 pstore3，无第二份可拉。
（更正：任务书「三份全文已留存」中的 uprot 份 = pstore3；05_LOG §12 的「未及抓 pstore」系当时未识别 healthdog 尾巴。）

**逐份判读（binary-safe grep `grep -ac`）**：

| 份 | md5 | 结尾事件 | Oops | BUG: | IntErr | CallTrace | panic |
|---|---|---|---|---|---|---|---|
| pstore (uwhook boot, t=33021 s) | 1629a33d… | IABT Oops | 2 | 0 | 2 | **0（缓冲截断）** | 0（未及打印） |
| pstore2 (pte_redirect boot, t=834.8 s) | cadf1fc7… | Bad page→panic | 0 | 1 | 0 | 1 | 1（panic_on_taint） |
| pstore3 (uprot boot, 事件 ~625–732 s) | 30cf05f2… | healthdog EMERGENCY RESTART | **0** | **0** | **0** | **0** | **0** |

1. **uwhook**：`Unable to handle kernel paging request at ffffffffc008b684`，`ESR=0x86000005`（EC=0x21 IABT current EL，
   FSC=0x05 L1 translation fault）。console 在寄存器段前截断（无 pc:/lr: 行）。
   符号化（kallsyms+vmlinux symtab 双验）：`__arch_copy_to_user` @ **0xffffffc00843b680**（两源一致）；
   期望 shim 返回 = +4 = 0xffffffc00843b684，16 位块分解 期望 `[ffff,ffc0,0843,b684]` vs 实际 `[ffff,ffff,c008,b684]`
   —— **两个块错**（block1 ffc0→ffff、block2 0843→c008），与 movz/movk 手拼错一致。fault VA 落在模块区未映射页。
2. **pte_redirect**：`BUG: Bad page state in process kworker/3:7 pfn:acdcb` → `panic_on_taint` panic；
   trace = panic←add_taint←bad_page←check_free_page+0x98←free_pcppages_bulk←…←free_work。
   symtab 核对：check_free_page=0xffffffc00825cc4c（+0x98=…cce4）、free_work=0xffffffc00825b3b4 等 8 符号全一致。
   pfn:acdcb 与 lab 日志 `pte_after=0xe80000acdcbf43` 页帧一致（= Q 页双重归属）。= C-174 复核通过。
3. **uprot**：全文件 0 条 Oops/BUG/Internal error/Call trace/panic；结尾唯一系统事件
   `[732.330789] healthdog: heartbeat stale >90s (hbs=6) — EMERGENCY RESTART`。
   **不存在任何 data-abort ⇒ 不存在可符号化的 fault PC。**

**环境登记**：`CONFIG_ARM64_PAN=y`、`CONFIG_DEVMEM=y`、`# CONFIG_STRICT_DEVMEM is not set`（config-extracted.txt 行 422/2659/6027）。

**__ex_table 验证**：`analysis/kern/vmlinux.elf` 仅 6 节（'' .text .data .symtab .strtab .shstrtab），**无 __ex_table 节**；
kallsyms 无 `__start___ex_table` ⇒ 该验证途径 BLOCKED。且对本案 MOOT：三份事故中没有一份产生「uaccess-store 候选 PC」
（uwhook 是 IABT 自跳；pte_redirect 是 bad_page；uprot 无 fault）。

## 11. 判决
- **H0 全部成立（三/三）**：uwhook=自伤（shim 返回地址 movz/movk 两块错→IABT）；pte_redirect=自伤（Q 页双重归属→bad_page→
  panic_on_taint）；uprot=**无 Oops 的 hang→healthdog**（非 panic，不得记 panic）。
- **「uprot PC=写入者」的 E3 白捡机会不存在**：置 RO 后 ~92 s 窗口内没有任何内核态 store 经该 VA 触发权限 fault。
  诚实边界：这不证明写入走 PA/DMA——该窗口内写入者可能根本没写（nerepair 停摆是混杂，C-175 候选 B）。
- 对应 claims：维持 C-174、C-175（本文件为独立复核 + uwhook 块级符号化细化 + vmlinux symtab 交叉验证）。
- 新增行：C-183（见 01_CLAIMS.tsv）。

## 12. 偏差与教训
- pstore/console-ramoops-0 是二进制（NUL）文件：`grep -c` 不带 `-a` 会静默产出空——第一次计数全空差点误读为 0。
- 任务书的「panic」措辞 vs 实况：uprot 是 watchdog 型重启；「白捡 E3」的期望在证据里不成立，复核必须独立于任务书措辞。
- uwhook 的块级比对揭示是**两个** 16 位块错（05_LOG §9 原记「第 2 个块错」不完整）——自伤结论不变，细节更正。
