# REVIEW-romap — 只读页诊断 / task_pt_regs(B2a)

- 源码:`romap.c` · 构建:`build_bmods.sh` · 产物:`out/romap.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`
- 性质:**纯只读**(PTE 走查 + struct page 字段读 + 内核栈 pt_regs 读);无 notifier、无写路径。
- 口径:D12 页五元组同批对照;D14/H6 `task_pt_regs(task)->sp` + 全量寄存器
  (docs/SIGSEGV/11_TRANSPORT_SCORECARD.md §H6/§D12)。

## 1. 接口

```
echo "<pid> <hexva> [ref_hexva]" > /proc/romap   # tgt 页五元组 + ref 对照页
echo "ptregs <pid>"                 > /proc/romap   # sp(高亮)+ x00..x30 + pc/pstate
cat /proc/romap                                      # 最近一次结果(同时镜像进 dmesg)
```
ref 缺省 = 目标任务 `task_pt_regs(t)->sp` 所在页(同批普通栈页,满足 D12"必须同批对照"要求);
显式第三参数可换任意对照 VA。

## 2. 逐函数自审

| 函数 | 锁 | 睡眠 | 故障路径 | 备注 |
|---|---|---|---|---|
| `out_reset/out_append` | g_mutex(调用方持) | vscnprintf 不睡 | 缓冲 4096 封顶丢弃 | 进程上下文 |
| `walk_va` | 调用方持 mmap_read_lock | 无 | 每级 none/bad 检查,-ENOENT | patrace 实机同款 |
| `page_report` | mmap_read_lock(调用方) | 无 | walk 失败/`pfn_valid` 失败各出错误行 | D12 五元组:pfn/_refcount/_mapcount/flags/mapping(+anon-file 分类,compound_head 归一) |
| `ptregs_report` | 无(task 引用持有) | 无 | — | 内核栈顶只读;值对运行中任务是**最后一次陷入的陈旧快照**(判读注明) |
| `rm_write` | g_mutex + mmap_read_lock | 可睡(mutex/down_read/sscanf 等)——**全是 syscall 上下文,合法** | -EINVAL(输入)/-EPERM/-ESRCH/无 mm,全落错误行 | 锁序恒为 g_mutex→mmap_read_lock,无反向持锁者 |
| `rm_read` | g_mutex | copy_to_user | -EFAULT | |
| `romap_init/exit` | proc_create/remove | 可睡 | -ENOMEM | |

无 BUG_ON/panic 路径;所有失败都变成缓冲区里的错误行 + 返回码。

### 权限门槛(与任务书 mm_access 的差异,必须记录)
`mm_access()`/`ptrace_may_access()` 在 5.15 **未导出给模块**(kernel/fork.c:1327 无
EXPORT_SYMBOL;kernel/ptrace.c 仅导出 task_user_regset_view)。等效替代:
`capable(CAP_SYS_PTRACE)`(已导出)+ `get_task_mm()`(已导出,持 mm 引用)。
设备上的调用者是 root SSH 会话,恰是 PTRACE_MODE_ATTACH 会放行的同一人群;残余差异
(与目标 execve 竞态、setuid 边角)对本只读诊断无影响。

### D12 判读提示
GUP/pin 类写者会造成 `_refcount` 抬高而 `_mapcount` 不动(参照 11_TRANSPORT_SCORECARD
H5);tgt 与 ref 同批对照可压掉 1024 系统性偏差(同文件 D12 原文要求)。

## 3. 静态自检(`python check_calls.py out/romap.ko`)

全模块外呼(全部位于 syscall/init 上下文,允许睡眠):
`vscnprintf, mutex_lock/unlock, down_read/up_read, mmput, get_task_mm, find_get_pid,
get_pid_task, put_pid, __put_task_struct, refcount_warn_saturate, capable, sscanf,
strncmp, memset, _printk, __arch_copy_{from,to}_user, __check_object_size,
proc_create/proc_remove`。
**无原子上下文回调**(与 dieblx 不同),睡眠符号的存在是设计内行为。
跨节内部调用以 STT_SECTION+addend 重定位出现(如 init.text→.text+off),loader 标准
语义,check_calls.py 已按内部边解析。

## 4. 加载顺序建议

第二顺位(dieblx 之后、ioprobe 之前);常驻无害(无 notifier、无后台线程)。

## 5. 上机验证序列(F-07)

```
1. insmod romap.ko
2. 健康态 60s:dmesg 仅一行 loaded;无 oops
3. 自体回归:echo "$$ 0x7ffd00000000" ... 需真地址——用 sleep 进程:
   sleep 300 & SPID=$!
   cat /proc/$SPID/maps | head -1            # 取一个栈/anon VA
   echo "$SPID 0x<该VA>" > /proc/romap; cat /proc/romap
   # 期望:两行五元组,tgt 与 ref 的 class=anon、mapcount≈0/1、ref 正常
4. echo "ptregs $SPID" > /proc/romap; cat /proc/romap   # 期望:8 行寄存器 + sp 行
5. 错误路径回归:echo "999999 0x1000" > /proc/romap(ESRCH 行)、非 root 场景略
6. rmmod romap
```

## 6. 最大残余风险

并发窗口:walk 成功到读 struct page 之间页被回收/复用 → 读到陈旧但**合法**的数值
(不会崩;数值标 `可能陈旧`);运行中任务的 pt_regs 是上次陷入快照(H6 判读本就按
"睡眠在 syscall 里"的目标取证,建议对 hold-us 受害者采样,同 11_TRANSPORT D14 设计)。
锁序单一(g_mutex→mmap),无死锁面。
