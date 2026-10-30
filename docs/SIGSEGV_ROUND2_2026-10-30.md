# SIGSEGV 写入源调查 · 第二轮（内核镜像标定 + EL1 写陷阱）

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

日期：2026-10-30 07:15–07:56　设备：LG6151M（bootslot=a，uptime 28 min，未重启留隐患）

## 1. 结论摘要

本轮把"32 字节记录"从"疑似 dpmaif 上下文"改写为**确证的 DMA 环描述符**，
并把它的落点确定为一个**可预测的栈地址**；同时用内核模块在落点页上装了
**EL1-only 存储观察点**，11 分钟窗口内**零命中**。

因此本轮的净结论是两条：

1. 记录 = `{u32 base_pa, u32 wr_pa, u64 end_pa, u64 vmalloc_va, u64 base_pa(+8)}`，
   其中 `wr_pa` 随时间前进（0x8fb44b70 → 0x8fb45350 → 0x8fb47240），
   即**某驱动的环形缓冲写指针**，不是寄存器快照。
2. 落点与"受害者当前 SP"绑定：两次独立崩溃都落在 `sp + 0x2070` 与 `sp + 0x22b0`
   （等价于 `stack_end - 0xfb0` / `- 0xdb0`）。这是**虚拟地址语义**，
   物理地址语义无法解释页内偏移随 SP 页内偏移 1:1 变化。

## 2. 内核镜像 ↔ VA 标定（解决了上一轮的 0 命中）

- 映像内 **84,544** 个 `0xffffffc0xxxxxxxx` 字面量，低 32 位全部落在
  `0x08000000 + file_offset` 上 ⇒ `VA = 0xffffffc008000000 + file_offset` 成立。
- 该结论用"页内相对量"推导（ADRP 目标页 − ADD 立即数），与基址无关，可独立复核。

## 3. 上一轮那条线索被证伪（重要）

- `drivers/misc/mediatek/lpm/modules/debug/mt6990/mt6990_dbg_spm_fs.c` 的
  136/177 字节 SPM dump 格式串位于文件偏移 `0xb688c1`（VA `0xffffffc008b688c1`）。
- 全映像 64,325 条 ADRP 中，指向该页的有 78 条，**没有一条** ADD 到
  `0xb688c1..0xb68972`；字面量池里也**没有**该 VA。
- 结论：**映像内的 SPM dump 串是死副本**，运行期打印来自别处（模块或未在此映像内）。
  §22/§23 里"内核日志文本写进用户栈"的整条推理链**不再作为线索**。

## 4. 记录解码（来自 `pfc2.core` / `pfc3.core`，同一 boot）

```
+0  u32 0x8fb00000      base_pa
+4  u32 0x8fb44b70      wr_pa   （活值，随采样前进）
+8  u64 0x000000008fb20000  end/rd_pa
+16 u64 0xffffffc010775000  vmalloc VA（同 boot 内恒定）
+24 u64 0x8fb00000 / 0x8fb00008   base_pa（±8，两份副本不同）
```

同一次崩溃里出现两份，间隔 `0x240`。

## 5. 受害者行为（实测）

`pfcanary` 采样 `/proc/<pid>/syscall` 400 次全部返回 `running`
⇒ **纯用户态自旋，无系统调用**。所以写入不是被受害者自己的 syscall 触发的，
也就排除了"用户缓冲区传给内核后被越界写"这一类。

## 6. 内核侧陷阱（本轮新建）

| 工具 | 作用 | 结果 |
|---|---|---|
| `vmwho.ko` | 用 `find_vm_area` 反查 vmalloc 属主（`caller=%pS`） | 首次探测用了**上一 boot 的 VA**，直接 oops（`Unable to handle kernel paging request at ffffffc010775000`），设备自动重启；证明该 VA 已失效 |
| `wtrap.ko` | 直接编程 `DBGWVR0..3`/`DBGWCR0..3`：E=1、LSC=store、BAS=0xff、**HMC=1（仅 EL1）**、**MASK=7（整页 4KB）**，并置 `MDSCR_EL1.MDE` | 装 4 页成功，受害者 EL0 写同页**不触发**（证明 EL1 过滤生效） |
| `wp` | 自旋受害者 + 打印自身 `sp`/`stack_end` | 用于计算落点页 |

**11 分钟窗口（受害者持续自旋、4 个落点页全时监视）零命中、零 oops。**

## 7. 由此得到的判别（诚实版）

- 已排除：**CPU 经用户 VA 的 EL1 存储**（观察点会命中；且 PAN 未触发 oops 也说明
  不存在"裸写用户 VA"的路径）。
- 未排除但更可能：**设备 DMA 写到物理地址**。记录本身是环描述符、`wr_pa` 是物理
  地址、环由 `vmalloc` 页 + `dma_map` 组成，这套结构天然是 DMA 语义。
- 观察点只覆盖 4 页，且"落点 = sp+0x2070"这一规律来自 `pfcanary` 的固定栈布局；
  换程序后落点会跟着变。**所以"零命中"还不能判死 CPU 路径**，只能说：
  在我们监视的那 4 页上，11 分钟内没有任何 EL1 存储。

## 8. 下一步（具体、可执行）

1. 用 `pfcanary` 自身当受害者（栈布局与历史崩溃一致），先在 `/proc/<pid>/maps`
   读出 `[stack]` 上界，落点页 = `stack_end - 0x1000`；`wtrap` 装该页 + 其下 3 页。
   难点是 pfcanary 秒级崩溃，需要在它 `SIGSTOP` 后装点再 `SIGCONT`。
2. 若仍零命中 → 判 DMA。用 `/sys/kernel/debug/dma_buf`、IOMMU 页表
   （`/sys/kernel/debug/iommu`）与 `mtk_iommu` 的映射表反查 `0x8fb00000` 属主。
3. 环的 `vmalloc VA` 与 `base_pa` 同 boot 恒定：一旦抓到一次同 boot 的崩溃，
   立刻 `insmod vmwho.ko va=<该 VA>`，`caller=%pS` 会直接点名驱动函数。

## 9. 环境备注

- 本内核**未编入 perf**：`perf_event_open` 返回 ENOSYS，无
  `/proc/sys/kernel/perf_event_paranoid` ⇒ 用户态硬件断点方案不可用，只能走模块。
- oops 可靠回收：`/sys/fs/pstore/console-ramoops-0`（本轮已实测抓到完整 oops）。
- 本轮新增工具：`tmpfiles/repro/{vmwho.c,wtrap.c,wp.c}`（仓外，`tmpfiles/` 不入库）。
