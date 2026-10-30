# VERDICT · 32B 记录 SIGSEGV 家族（2026-10-31）

## 0. 一句话
**记录是 WED TX 路径写出的 TXD，经 DMA 落到一个“已释放又被复用为 canary 栈”的物理页上；transport = PA/DMA（E2）。** 页级 kprobe 判决被本内核 `CONFIG_KPROBES=n` 阻断，故停在 E2。

## 1. Transport：PA/DMA（E2，不是 E3）
**支持证据**
1. 记录内容 = 一个 WED TXD：`w0` 长度样（0x14d8b/0x17f46…）、`w1=0`、`w2 = len|ip`（0x641 | 1.9.168.192）、`w3=0`（C-138；h4_11451 实测）。
2. **88/112** 份 canary h4 含该记录（78.6%，95% CI 70.1–85.2%）；`top-x2=0x390` 在 **111/112** 恒定；记录三副本 `x2`(82)/`x2-0x240`(66)/`x2-0x130`(18)（C-137）。
3. 外部 **uaccess/VA** 写入者没有路径拿到 canary 的 va_list VA：canary 的 `snprintf` 是纯用户态 musl，没有系统调用把 va_list 传给内核。
4. **PA/DMA + 页复用**（canary 栈页 = 回收的 WED TX 页）能同时解释高命中率与固定 top-relative 偏移（C-140）。
5. 固定 VA/PA 排除（C-052）针对的是“跨崩溃恒定”的地址；stale PA **不恒定**（随页分配变化），与页复用模型一致。
6. `copy_to_user` 强阴性（C-013/C-034）、`ref=1025` 无泄漏 GUP pin（C-050）进一步压低 uaccess/GUP 模型。

**反面（为什么不是 E3）**
- 页级判决（kprobe `dma_unmap_page_attrs`/`page_frag_free` + 投毒）**无法在本内核执行**：`CONFIG_KPROBES=n`（C-144）。
- tracefs/`kprobe_events` 不存在；`/proc/warp_ctrl` 读返回 EIO；`dmesg` 无 ring/PA 日志（已被多次 `dmesg -C` 清空）。
- 设备 `kmodloader` 拒绝 zig 直编的 `pgprobe.ko`（缺 `.gnu.linkonce.this_module`）；内核树无 `.config`/modpost，kbuild 不可用。

## 2. Writer：WED TX 路径（E2）
- 记录 = WED TXD；`w0` 长度样、`w2` len|ip；`wed_tx_ring_reset` 写 entry `+0x00 len/+0x08 VA/+0x10 PA`；`wed_fdesc_init` 写 64-bit dma_addr（C-106/C-138）。
- 具体 ring/index 未钉死（需要页级 probe 或 ring dump）。
- 写入者是 **WED 硬件 DMA**（不是 CPU 路径）；载体是 `mtk_warp` 的 TX ring 描述符 PA。

## 3. 自然 NE 份额：0/4，95% 上界 49%
- 3 份自然 core + 1 份自然 `.stack`（pid 15214，`sh /data/repro/stacktest.sh`）均无记录；Wilson 95% 上界 **49.0%**（C-142）。
- canary 88/112 证明 canary 是有效探测器；自然 0/4 不是探测器伪影（C-139）。
- 记录家族在自然 NE 中 **≤49%**（95% 置信），不能外推到全部自然 NE。

## 4. 仪器
- `core_meta v1.9` + `stackdump` 在真实死亡进程上验证通过：`.stack` 65,592 B、`.stackerr` `readable=16`（C-141）。
- 关键认知：vsurv4 捕获 SIGSEGV 后 siglongjmp，**永不进 core_meta**；`.stack` 只能在真正死亡的进程上验证。

## 5. 要把 E2 升到 E3，需要（按成本排序）
1. **重编内核**打开 `CONFIG_KPROBES=y`（或 `CONFIG_FTRACE`+`kprobe_events`），再跑 `pgprobe`（kprobe `dma_unmap_page_attrs`/`page_frag_free` + 投毒 + ring）——最直接，但要刷内核。
2. **用户态 remap/RO 实验**：把 canary 栈页 VA 重映射到新 PA（或 mprotect RO），看记录是否仍落在旧 PA——不需要内核模块，但需要改 canary/驱动配合。
3. **带 `.gnu.linkonce.this_module` 的 kbuild 模块**：用 `/proc/config.gz` 重建 .config 后 kbuild（本机内核树缺 modpost，需先 `make scripts`）。

## 6. 结论
- **Transport：PA/DMA（E2）**。
- **Writer：WED TX 路径（E2）**；精确 ring/index 待页级 probe。
- **自然 NE 份额：0/4（95% 上界 49%）**。
- 页级判决被 `CONFIG_KPROBES=n` 阻断，这是当前唯一硬缺口。
