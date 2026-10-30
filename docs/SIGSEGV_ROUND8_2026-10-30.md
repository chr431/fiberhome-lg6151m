# NE 崩溃调查 · 第八轮（2026-10-30 下午）

> **历史文档（2026-10-30 归档）**：当前状态见 [docs/SIGSEGV/00_STATE.md](SIGSEGV/00_STATE.md)；结论台账见 [01_CLAIMS.tsv](SIGSEGV/01_CLAIMS.tsv)。本文保留原样，勿据此判断当前结论。

本轮目标：把上一轮定型的 **300 站点 uaccess-window 探针**搭起来。

## 1. 仪器已建成（`tmpfiles/an4/uw.ko`，生成器 `gen_uw.py`）

思路：SW TTBR0 PAN 下，任何内联 uaccess 存储都必须先打开 uaccess 窗口，即调用
`uaccess_ttbr0_enable.isra.0` / `uaccess_ttbr0_disable.isra.0`。这两个符号在内核镜像里
各有 150 个本地克隆（共 300），**全部以 `paciasp` 开头**（本轮实测 300/300）。

于是给每个克隆生成一个专属 trampoline：

```
paciasp                      ; 在克隆入口 SP 上重放原指令，PAC 语义与原来等价
stp x0,x1 ... x18,x30        ; 保存全部 caller-saved（含 x10..x17、x18）
ldr x0, =<克隆地址>          ; site
ldr x1, [sp, #8]             ; 调用者返回地址
mov x2, #<enable|disable>
bl  uw_hook
ldp ...                      ; 还原
ldr x9, =<克隆地址+4>
br  x9                       ; 继续执行克隆本体
```

`uw_hook` 只在 `in_interrupt()` 时记录：`site` / `lr` / `current_pt_regs()->sp` /
`comm` / `cpu`，前 25 条附 `dump_stack()`，并有 per-CPU 递归保护。
判据：**只要被中断的用户 sp 落在受害者栈页，`lr` 所在函数就是写入者**。

## 2. 分级实测（结果都拿到了）

| 补丁站点数 | 结果 |
|---|---|
| 5 | 正常；`rmmod` 正确恢复 300 条（`restored ... (nsites=5)`） |
| 50 | 正常；系统照跑 |
| **300** | **用户态被打坏** |

300 站点加载后立刻出现：`sleep/dmesg/grep/cat/ps` 全部 "not found"，
随后 SSH 认证失败、`/api/*` 全部 200 空体（`v3httpd` 活着但 exec 不出 `api.sh`）。

⇒ **51..300 之间有一个（或几个）站点不能这样打。** 第一个坏掉的症状是 `execve`
（路径字符串靠 `copy_from_user` 拿），所以嫌疑集中在 `_copy_from_user` 用的那批克隆上。

## 3. 现场状态（需要断电）

模块不持久化，**断电重上电即可完全恢复**。当前无法远程重启：

- SSH：密码认证被拒（同机同 host key，说明还是同一固件，只是用户态坏了）；
- Web：`v3httpd` 在（80 端口 200），但 `/api/*` 一律 0 字节 —— `api.sh` exec 不出来，
  所以 `sys_reboot` 端点也用不了；
- 串口：只有内核 console，没有 getty，发 CRLF 只回 2 字节。

## 4. 恢复后的下一步（已定）

1. 断电重启，确认 `uw.ko` 不在 `lsmod` 里；
2. 二分：`nsites=100 / 150 / 200 / 250`，定位第一个坏站点；
3. 修法二选一：
   - 只打 `uaccess_ttbr0_enable`（150 个）——我们要的是"谁开了窗口"，disable 侧不需要；
   - 或对坏站点单独分析（很可能是被汇编以非标准 ABI 调用的克隆）。

## 5. 教训

- **教训 40**：改内核 text 的探针必须**分级上线**（5 → 50 → 300）。本轮如果直接上 300，
  就没有"50 是好的"这个信息，二分区间会大一倍。
- **教训 41**：用户态"命令找不到"是第一现场信号——它指向 `execve` 的
  `copy_from_user` 路径，而不是内核崩溃。看到这个要立刻停手，不要继续在同一次开机里试。
- **教训 42**：设备必须保留一条不依赖被改代码的退路。本轮 `v3httpd`/dropbear 都被同一次
  破坏波及，远程重启通道全断，只能靠人断电。
