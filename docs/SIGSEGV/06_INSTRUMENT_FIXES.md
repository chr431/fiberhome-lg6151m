# 06 · 仪器修复批次（2026-10-30）

> 本文件只记录“修了什么、怎么验证、还差什么”。仪器状态总表见 [03_PROBES.md](03_PROBES.md)。
> 规则：本地验证 ≠ 设备验证；设备未验证的，不得把其阴性写进 `01_CLAIMS.tsv` 的 E2 以上。

## F-01 离线分类器（已完成，本地验证）

| 文件 | 作用 | 验证 |
|---|---|---|
| `tools/oneoff/sigsegv/va_scan.py` | 16KB 转储：ucontext x2 + 32B 记录分类 | `--strict` 在 106 份上 **PASS**：71 A0B2 / 32 B0A2 / 3 other；`--legacy` 复现 71/35 |
| `tools/oneoff/sigsegv/core_scan.py` | 完整 core：NT_PRSTATUS x2 + 记录分类 | `--strict-an2` **PASS**：c27830/36/9409/r11228/r3850 A0B2，c27834 B0A2；`pf.core` A0B2；`sh.core` n/a + 2 个候选 |

**旧脚本处置**：`tmpfiles/an4/{attrib,h3table,corescan,corescan2}.py` 顶部已加 DEPRECATED；不再用于结论。

## F-02 受害者 handler（已完成，host 验证；设备待做）

- 文件：`tools/oneoff/sigsegv/vsurv4.c`；aarch64 静态编译通过（`vsurv4`）。
- 修复点：
  - `sigaltstack`（64KB）+ `SA_ONSTACK`；
  - handler 内只 `open/write/close/time`，无 `snprintf`/`/proc` 读；
  - 启动时缓存 `start_stack`；
  - 手动路径格式化；
  - 不用 `SA_NODEFER`；`g_in_handler` 递归守卫；
  - 固定 120B 头 + 8 页栈（`H4v1`）。
- Host 验证：x86_64 WSL 编译 + `kill -11`，生成 `h4_<pid>_1.bin`，文件大小 **32888 = 120 + 8×4096**；头字段 magic/pid/hit/sig/addr/pc/sp/stack_top 正确；进程继续运行。
- 设备验证待做：`raise(SIGSEGV)` 自测 + 真实崩溃；确认 `addr/pc/sp/x2/x8` 与 `siginfo/ucontext` 一致。
- 备注：`siglongjmp` 不是 POSIX async-signal-safe，但本 canary 需要继续运行；已在注释中说明。若设备上出现异常，可改为 `_exit(139)` + 外部 respawn。

## F-03 自然 NE 栈快照（已编译/已 staged；设备待做）

- `tools/oneoff/sigsegv/stackdump.c`：aarch64 静态编译通过；读 `/proc/<pid>/maps` 的 `[stack]`，`pread` 最后 16 页，写 48B 头 + 8B present 位图 + 64KB。
- `tools/oneoff/sigsegv/core_meta_v1.7.sh` + `.patch`：在 `core_meta.sh v1.6` 上增加：
  - `STACKDUMP=/data/gw/bin/stackdump`；
  - `STACK=$DIR/<bt>-<pid>-<ts>.stack`；
  - 元数据 `stack=[...]`；
  - TSV 行尾 `stack=...`；
  - 200 个 `.stack` 配额。
- 部署顺序：
  1. `deploy.py put stackdump /data/gw/bin/stackdump` + `chmod 755`；
  2. `deploy.py push core_meta.sh`（v1.7）+ `chmod 755`；
  3. `VERSIONS.tsv` bump `core_meta` 版本（部署前必须做，否则 vercheck 不过）；
  4. 冷启动/一次真实 NE 后，确认 `.stack` 文件存在且 `stackdump` 的 header 正确；
  5. 用 `va_scan.py` 的变体读 `.stack`（下一步写 `h4_scan.py`/`sd_scan.py`）。
- 注意：`core_meta.sh` 是 core_pattern helper；栈快照在元数据之后、TSV 之前，16 页毫秒级；不要让它阻塞 core 流。

## F-04 探针正对照（已编译；设备待做）

- `tools/oneoff/sigsegv/probe_selftest/`：
  - `probe_selftest.c` → `probe_selftest.ko`（aarch64，已编译）；
  - `probe_selftest_user.c` → `probe_selftest_user`（aarch64，已编译）；
  - `README.md`：`pf` / `cfu` / `uw` 三个用例、预期 dmesg、部署/执行命令。
- 设备验证待做：每个用例必须看到预期日志；任一失败 → 对应探针的阴性降级 E1。
- `c2u n=32` 未单独覆盖：`_copy_to_user` 克隆最终调用 `__arch_copy_to_user`，`ac2u` 的正对照覆盖最终 copy；`c2u` 仅作辅助 hook，不单独作为排除证据。

## F-05 `cth` 修复清单（设备待做）

| 项 | 现状 | 修法 |
|---|---|---|
| `g_hit` 上限 4000 | 可能饱和，0 命中可能是截断 | 退出时打印 `g_hit`/总调用；若 `g_hit==4000` 标“饱和”，结论降级 |
| `g_c2u_calls` 未自增 | 统计错 | 在 `cth_hook` 按 site 区分 ac2u/c2u，或删除该计数 |
| `c2u n=32` 无正对照 | 辅助 hook 未验证 | 用 `probe_selftest` 的 `c2u` 变体（若 `_copy_to_user` 可调用）或明确“不单独使用” |
| PF 无正对照 | `vro` 0 PF 不可信 | 用 `probe_selftest pf` |
| PF `pf_lo/pf_hi` raw FAR | 带 tag 可能漏 | 过滤时同时比较 tagged/untagged |
| `cfu` 只覆盖 `copy_from_user` dst 误用 | 不覆盖 `memcpy` 到用户指针 | 明确边界；`memcpy` 用静态窗口扫描/三哨兵 |

## F-06 `uw`：从“写者定位器”降级为“开窗者筛查”

**判决**：`uw` 不能点名写入者。`lr` 是 `uaccess_ttbr0_enable` 的调用者（开窗者），不是窗口内的 store；300 站点从未成功；125–130 的失败最可能是 160B trampoline 的累积栈/调用开销，不是“坏站点”。

**处置**：

1. 重命名为 `uwopen`（或文档里明确“只测开窗者”），禁止再用“点名写者”的表述。
2. 不再追 300 站点；保留 5/50/125 分级，作为“中断上下文里谁开窗”的筛查。
3. 若必须继续：
   - 用 per-CPU scratch 页保存 x0–x18/x30，替代 160B 栈（避免累积栈）；
   - per-CPU 深度计数，不吞嵌套；
   - `irq_only` 可配；`usp_lo/usp_hi` 可关；
   - 记录 `site/lr/usp/depth/cpu`；
   - 先 5 → 50 → 125，每级验证用户态/SSH；
   - 不把“0 命中”写成“没有 uaccess”。
4. 真正要抓 store，应该在 **窗口内的 store 指令** 上打点，而不是 enable/disable；当前静态扫描只有 14 条窗口内 store（全写栈），所以 **没有明显的 in-window store 目标**；如果还要做，先复核 `zz_winstore.py` 的窗口枚举/被调函数覆盖。

## F-07 `remap`/`remapu`：三哨兵（设备待做）

- 现状：uaccess 的唯一阳性，但无 60s 稳定性对照；改活栈 PTE 可自崩。
- 修法（判决实验）：
  1. 用户 PTE → S1（**只读**），内容复制；
  2. P0 线性别名 → S2（可写），内容复制；
  3. P0 原页监视；
  4. S1/S2/P0 三哨兵；
  5. 重定向后让受害者**稳定运行 60s**；60s 内崩 = INVALID；
  6. PF 钩子 + 正对照；
  7. 判据：S1 有记录 + PF → uaccess；S1 有记录无 PF → DMA 绕过 PTE；S2 → 线性映射；P0 → 裸 PA；都没有 → 实验无效。
- 在跑完前，C-013 保持 E1/open。

## F-08 `pwatch`/`va2pa`：对照页 + pin 计数（设备待做）

- 现状：pin 改变页生命周期；单页单次；§22 解释两次翻转。
- 修法：
  - 同时监视一个**对照页**（不同 PA，同样 pin）；
  - 记录 pin 次数/refcount 变化；
  - 记录同刻寄存器/引擎状态；
  - 把“写入率”与“崩溃率”分开报告；
  - 不把单页单次当机制。

## F-09 `vaguard` 台账（设备待做）

- 现状：首命中 + 每 256 次一行；3 次是下限。
- 修法：每次命中一行（或明确采样率）；`hits` 列改为“本次增量”而不是累计；报告“拦截数/进程/时间”而不是与 NE 相除。

## F-10 旧脚本/旧文档

- `attrib.py`/`h3table.py`/`corescan*.py` 已加 DEPRECATED 头。
- 旧 `docs/SIGSEGV_*.md` 已加历史/已撤回头；当前状态见 `00_STATE.md`。
- 下一步：把 `docs/SIGSEGV/` 纳入 `VERSIONS.tsv` 的 doc 行（或至少让 `vercheck` 知道它是豁免区），防止再次漂移。
