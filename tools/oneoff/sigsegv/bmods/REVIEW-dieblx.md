# REVIEW-dieblx — die_notifier / panic 黑匣子(B1)

- 源码:`dieblx.c` · 构建:`build_bmods.sh` · 产物:`out/dieblx.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`(`tr '\0' '\n' < out/dieblx.ko | grep vermagic`)
- 性质:**纯 notifier,零文本 patch、零 PTE 改写、零寄存器写**。

## 1. 内核路径事实(全部在 5.15.134 源码中核实)

| 事实 | 证据 |
|---|---|
| `notify_die(DIE_OOPS,...)` 在 `__die()` 内、`panic_on_oops` 检查之前 | arch/arm64/kernel/traps.c:193 vs :232 |
| BUG() → `die("Oops - BUG")` → 同一条 `__die` 路径 | traps.c bug_handler:966-970 |
| panic 顺序:notifier 链 → console_unblank → `console_flush_on_panic` → 定时重启 | kernel/panic.c :105/:124/:135 |
| `register_die_notifier`/`unregister_die_notifier` 对模块导出 | kernel/notifier.c:533-545 EXPORT_SYMBOL_GPL |
| `panic_notifier_list` 对模块导出(直接 atomic_notifier_chain_register) | kernel/panic.c:76 EXPORT_SYMBOL |
| `copy_from_kernel_nofault` 对模块导出(extable 修复,不睡眠) | mm/maccess.c:49 EXPORT_SYMBOL_GPL |
| 模块 `__bug_table` 节按原名注册(loader 查找名即 `__bug_table`) | lib/bug.c:88-100, kernel/module.c:3901 |

结论:**die 回调发生在 panic 之前;panic 回调发生在强制刷 console 之前**——两条路径的
KERN_EMERG printk 都必然落进 console-ramoops(设备 ramoops 区 0x9c100000,cmdline 已配)。

## 2. 逐函数自审

| 函数 | 锁 | 睡眠 | 故障路径 | 递归 |
|---|---|---|---|---|
| `blx_hx` | 无 | 无 | 纯栈写 | 无(叶子) |
| `blx_kv`/`blx_4` | 无 | 无 | buf 定长(48/112),printk("%s") | 无 |
| `blx_watch` | 无(有意:`current->mm` 无锁只读走表) | 无(`copy_from_kernel_nofault` 仅 preempt_count 开关) | 每级 `none/bad` 检查;`pfn_valid` 门;页尾截断;全部负错码返回 | 读全部经 fixup,不会二次 fault 上抛 |
| `blx_die_cb` | 无 | 无 | `val!=DIE_OOPS`/`data==NULL` 早退;`regs==NULL` 分支降级 | `atomic_xchg(blx_busy)` 进入即置位,重入打印一行抑制后返回 |
| `blx_panic_cb` | 无 | 无 | 同上;仅 2 行 printk(smp_send_stop 之后必须最小化) | 同一 guard 共用 |
| `blx_trigger_set` | 无 | 无(sysfs store 进程上下文) | `armed!=42` 拒绝;kstrtoint 失败 -EINVAL | 故意制造 BUG/NULL 读(受控自检) |
| `dieblx_init/exit` | 无(注册 API 自带) | 注册可睡眠——仅 init/exit 进程上下文合法 | 失败路径反向注销 | — |

### 红线核对(任务书)
- 零锁 ✓(无 mutex/spin;atomic_xchg 是原子指令)
- 零分配 ✓(静态缓冲/栈)
- 零睡眠 ✓(静态自检闭包,见 §3)
- 栈深最小化 ✓(每行 ≤112B 栈 buffer;hex 手写,无 vsnprintf 进 dump 路径;w[8]={0} 的 memset 已被编译器内联,闭包里无 memset 调用)
- 递归保护 ✓(blx_busy 双向 xchg;panic/die 共用)

### 已知取舍(判读时须知)
1. `esr_sr/far_sr` 是 sysreg 重读:若 oops 后又发生嵌套异常会被改写,best-effort(pt_regs 本身无 esr/far 字段,5.15 布局核实)。
2. watch 用户 VA 走表不加 mmap 锁(原子上下文禁锁):并发 munmap 最坏读到陈旧字节或返回错误码——不会崩;PTE 读是 64 位对齐单拷贝原子。
3. watch 只经内核线性映射读(`pfn_valid` 门 + fixup),**不经 ioremap**。
4. panic 回调在 `smp_send_stop()` 之后执行:其余 CPU 已停,本回调只打 1-2 行。
5. panic_on_oops=0 的 oops 路径 printk 依赖随后 irq 恢复排水;若机器在 oops 后立即硬挂,console-ramoops 尾部可能缺行——panic 路径无此问题(flush 强制)。

## 3. 静态自检(替代 objdump 的等效证据)

主机无 aarch64 objdump(msys BFD 仅 pe-x86-64;musl 交叉 objdump 是 Linux 二进制;zig 0.13 无 objdump 子命令)。
改用 `check_calls.py`(readelf 同源数据 + 自带 bl 解码器 + STT_SECTION addend 解析)做**调用图闭包**,
证据强于目测反汇编(完备枚举而非抽样):

```
$ python check_calls.py out/dieblx.ko blx_die_cb blx_panic_cb
  internal functions reached: blx_4 blx_die_cb blx_hx blx_kv blx_panic_cb blx_watch pfn_valid
  EXT CALL _printk                      (from blx_4 / blx_die_cb / blx_kv / blx_panic_cb)
  EXT CALL copy_from_kernel_nofault     (from blx_watch)
```

notifier 闭包外呼 **恰好两个**:`_printk`(环形缓冲同步写,原子安全)与
`copy_from_kernel_nofault`(extable 修复读)。无 mutex/alloc/generic 睡眠符号。
全模块外呼(kstrtoint/param_get_int 已内联/注册注销 API)仅存在于 init/exit/sysfs 上下文。

## 4. 加载顺序建议

**dieblx 最先加载**(它是后续一切实验的黑匣子;romap/ioprobe 的异常都应被它记录)。
加载后常驻不卸载;romap 其次;ioprobe 按需。

## 5. 上机验证序列(F-07 纪律:先健康态观察 60s)

```
# 传输:deploy.py put(规则 3; .ko 只被 insmod 读取,644 即可,无需 chmod)
1. insmod dieblx.ko                       # 不带参数(watch 关闭)
2. 健康态观察 60s:dmesg 无 oops、/proc/modules 有 dieblx、uptime 正常
3. rmmod dieblx && insmod dieblx.ko       # 一次重载回归(unregister 路径)
--- 以下受控自检,默认不执行 ---
4. sysctl -w kernel.panic_on_oops=0       # 前置!设备默认=1,不改就是 3s 重启
5. echo 42 > /sys/module/dieblx/parameters/armed
6. echo 1 > /sys/module/dieblx/parameters/trigger
   # 写入的 sh 进程会被 oops 杀死(make_task_dead)——预期行为,SSH 会话另开
7. dmesg | grep dieblx                    # 应见:comm/pid 行、pc/pstate/sp/esr_sr/far_sr、
   #       x00..x30 共 8 行、"Oops dump complete";cat /sys/fs/pstore/console-ramoops-0 复核
8. echo 2 > .../parameters/trigger        # 可选:NULL 读路径(die 字串不同)
9. echo 0 > .../parameters/armed; sysctl -w kernel.panic_on_oops=1   # 恢复!
```

## 6. 最大残余风险

panic 回调本身若在极小概率下再 fault,`blx_busy` 会抑制输出并让该 fault 走原始 oops/panic
路径(等效于无本模块);**唯一不可覆盖的场景**是 notifier 链在我们之前的高优先级回调
(priority 同为 INT_MAX 且注册更早者)把机器挂死——本模块已取 INT_MAX 优先级,注册于
运行期,先于我们注册的同优先级回调只有内核内置项,当前 /proc/modules 无此迹象。
