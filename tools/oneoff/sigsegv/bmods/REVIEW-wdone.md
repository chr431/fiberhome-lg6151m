# REVIEW-wdone — mt_wifi 4 个内联站点的"一次性语义"修复(初版)

- 源码:`wdone.c` · 构建:`build_bmods.sh` · 产物:`out/wdone.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`
- 产物 md5:`82e5ca1174cf260f7ecd6f63f24471fc`(199,408 B)
- 性质:**会写内核文本的 B3 模块**(4 个站点 + 本模块 4 个回跳字,共 8 个
  4 字节 patch;`rmmod` 全量还原并读回校验)。
- 依据:N2b §7.1(一次性语义)、§4.1/§4.3/§4.4/§4.5(四个内联站点)、
  §5(dst 来源判定)。

## 1. 修复语义

四个站点的共同形状(N2b §5):

```
    ldr  xD, [xS, #0x10]     ; dst = 常驻描述符里的用户指针(可陈旧)
    ...                      ; +0x18 另写 out_len
```

把这一条 `ldr` 改成 `b wdone_os_<site>`,跳板复刻原 load 并**立即清零字段**:

```
wdone_os_<site>:
    ldr  xD, [xS, #0x10]     ; 被替换的指令,原样执行
    str  xzr, [xS, #0x10]    ; 一次性:该指针只能用这一次
    b    <site + 4>          ; init 时回填
```

于是"第二次使用同一缓存指针"必然读到 NULL → 后续 `copy_to_user` 以 NULL
为目标**返回 len(失败)**,而不是写进上一次调用者留下的用户 VA。

**为什么不是把 dst 置 NULL**(与 wdkill 同一条理由):
`CONFIG_HARDENED_USERCOPY=y` + `CONFIG_PANIC_ON_OOPS=y`(设备 IKCONFIG 与
构建树 `.config` 逐行一致),NULL dst 进 `__check_object_size()` →
`usercopy_abort("null address")` → `BUG()` → 重启。本方案清的是**缓存字段**,
dst 仍是刚从字段读出的值,不存在 NULL-dst 路径。

**为什么用跳板而不是两条原地指令**:单字替换模型(tuphook 已实证)只允许
覆盖一条 4 字节指令;`ldr`+`str` 是两条,必须出跳板。跳板在本模块 `.text`
(`.balign 4096`,4 条共 48 B,同页),`b` 进出、不建帧、不动 `x29/x30`。

## 2. 站点表与期望字节

| 站点 | ldr 偏移 | 原字(期望) | 反汇编 | 跳板 store |
|---|---|---|---|---|
| `0x2976d8` `RTMP_COM_IoctlHandle+0xc20` | `0x297690` | `f9400ad8` | `ldr x24,[x22,#0x10]` | `f9000adf` `str xzr,[x22,#0x10]` |
| `0x1f9864` `AP_E2PROM_IOCTL_PostCtrl+0xfc` | `0x1f9818` | `f9400a96` | `ldr x22,[x20,#0x10]` | `f9000a9f` `str xzr,[x20,#0x10]` |
| `0x33bc64` `ZeroWaitDfsQueryCmdHandler+0x48` | `0x33bc28` | `f9400a64` | `ldr x4,[x19,#0x10]` | `f9000a7f` `str xzr,[x19,#0x10]` |
| `0x5b7e0` `ate_cmd_proc+0x184` | `0x5b678` | `f9400af3` | `ldr x19,[x23,#0x10]` | `f9000aff` `str xzr,[x23,#0x10]` |

每个站点另校验 2~3 个邻接字(离线实跑全部 OK):

```
0x297690: mov w2,#1 | ldr x24,[x22,#0x10] | mov x0,x25 | ldrh w21,[x22,#0x18]
0x1f9818: b <back> | ldr x22,[x20,#0x10] | and x19,x0,#0xffff | mov w2,#1
0x33bc28: (BL,跳过)| ldr x4, [x19,#0x10] | mov w0,#0xf6 | strh w0,[x19,#0x18]
0x5b678:  tbnz     | ldr x19,[x23,#0x10] | mov w0,#8   | strh w0,[x23,#0x18]
```

> `0x33bc24` 是一条带重定位的 `bl`(文件里是 `94000000`,运行期被 loader
> 改写),**故意不纳入指纹**;其余邻接字均无重定位(已逐偏移核对)。

构建产物里的 4 条跳板逐字反汇编核对:

```
0x0000: f9400ad8 ldr x24,[x22,#0x10]   0x0004: f9000adf str xzr,[x22,#0x10]   0x0008: 14000000 b .
0x000c: f9400a96 ldr x22,[x20,#0x10]   0x0010: f9000a9f str xzr,[x20,#0x10]   0x0014: 14000000 b .
0x0018: f9400a64 ldr x4, [x19,#0x10]   0x001c: f9000a7f str xzr,[x19,#0x10]   0x0020: 14000000 b .
0x0024: f9400af3 ldr x19,[x23,#0x10]   0x0028: f9000aff str xzr,[x23,#0x10]   0x002c: 14000000 b .
```

## 3. 语义影响(逐站点)

| 站点 | 清零后谁还会读这个字段 | 影响 |
|---|---|---|
| `0x297690` | 同函数内另有 `0x297574 ldr x20,[x22,#0x10]`、`0x297668 ldr x7,[x22,#0x10]`,**都在 patch 点之前**;patch 点之后本函数不再读 | 本次调用不受影响;下次未刷新就失败(正是目的) |
| `0x1f9818` | 本函数只有这一处 `[x20,#0x10]` 访问 | 同上 |
| `0x33bc28` | 本函数只有这一处 `[x19,#0x10]` 访问 | 同上 |
| `0x5b678` | 本函数只有这一处;后面的拷贝**循环用的是已装入的 x19**,不再读字段 | 本次循环不会被截断;下次进入若未刷新才失败 |

> 与 wdkill 的 `bl` 替换不同,这里改的是**数据字段**。若某条路径依赖
> "handler 返回后 ioctl 层再读 `req->buf`",它会读到 NULL。N2b §9.3
> 明确"谁写 `+0x10`(setter)尚未定位",因此**这是本模块最大的语义未知**,
> 必须用功能用例兜底(见预注册文档的停止规则)。

## 4. 逐函数自审

| 函数 | 锁/睡眠 | 故障路径 | 递归 |
|---|---|---|---|
| `wd_rep` | 无锁;写自有静态缓冲 | 长度保护截断 | 无 |
| `wd_find_mt_wifi` | 无锁;不睡眠 | 全部 nofault;`guard<1024` | 无 |
| `wd_scan_text` | 不睡眠 | 全部 nofault;命中数 !=1 返回 0 | 无 |
| `wd_check_site` | 无 | 全部 nofault;失败即判失败 | 无 |
| `wd_locate` | init 上下文;`try_module_get` | 双路定位必须一致;区间/对齐/`[mt_wifi]` 断言 | 无 |
| `wd_check_stubs` | 无 | 读不到或字不符 → -EINVAL | 无 |
| `wd_patch_words` | `stop_machine` | PTE walk 失败不写;写完恢复 PTE | 无 |
| `wd_flip_cb`/`wd_patch_cb` | stop_machine 回调,禁止睡眠 | 原子计数配对;每 CPU dc/ic | 无 |
| `wd_install` | init;5 次 stop_machine | **先装回跳再装站点**;任一步失败全回滚 | 无 |
| `wd_uninstall` | exit;stop_machine | **先还原站点再还原回跳**;逐点比对后写 | 无 |
| `wd_show` | seq_file 只读 | 只打印自有状态 | 无 |

**顺序不变式**:
- 安装:回跳字先写好并读回 → 才允许站点进入跳板(否则站点会执行到
  `b .` 死循环);
- 卸载:站点先还原 → 才允许撤掉回跳(否则在途的跳板会跳到已撤的
  `b .`)。

**调用闭包**(`check_calls.py out/wdone.ko`,实跑):

```
init_module -> EXT _printk copy_from_kernel_nofault memcmp memset module_put
                    proc_create sprint_symbol strncmp strstr try_module_get
             -> INT wd_patch_words wd_rep wd_uninstall
wd_patch_words -> EXT memset stop_machine
wd_uninstall   -> EXT _printk copy_from_kernel_nofault  -> INT wd_patch_words
wd_show        -> EXT seq_printf seq_puts
wd_open        -> EXT single_open
cleanup_module -> EXT _printk module_put proc_remove    -> INT wd_uninstall
```

外部符号全部是内核导出;无 module_alloc/vmap/ioremap/apply_to_page_range。

## 5. 崩溃路径分析

| 风险 | 处置 |
|---|---|
| 站点漂移 | 4 个 ldr 字 + 邻接字指纹;不符 -EINVAL 并打印实际字 |
| 基址错 | 链表 + 页扫描一致 + `sprint_symbol [mt_wifi]` |
| 跳板跨页 | init 断言 4 条跳板与 4 个回跳字同页 |
| `b` 越界 | 逐点范围检查 + 反解码比对 |
| **清零写坏内存** | `str` 的地址就是 `ldr` 刚读的同一个 `[xS,#0x10]`;若 xS 非法,`ldr` 已先 fault(与原始行为相同)。字段本身是可写的(其它路径会写它,这正是根因) |
| 写入竞争 | 8 字节对齐 store 原子;stop_machine 全 CPU 停 + icache 维护 |
| 跳板执行中撤除 | 卸载顺序:先站点后回跳 |
| `rmmod -f` | **禁止**:会释放本模块 .text,残留 `b` 跳进已释放页 |
| mt_wifi 卸载 | `try_module_get` 钉住;base 变化时跳过还原 |

## 6. 加载 / 卸载序列

```
insmod /data/gw/wdone.ko dryrun=1
dmesg | tail -40 ; cat /proc/wdone
#   期望:VALIDATION OK: 4/4 inline sites;4 行 "ok";4 行 tramp 字

insmod /data/gw/wdone.ko
cat /proc/wdone        # 顶部 PATCHED;tramp0..3 的第三个字应是 b <site+4>

# 功能用例(必须):WiFi 关联/查询/雷达 debug proc 各跑一遍
# 记录率观察窗口见 05_LOG/2026-11-03-04

rmmod wdone
dmesg | tail -10       # 期望 "restored 4/4 sites, 0 skipped"
```

**与 wdkill 的关系**:两者可同时加载(站点集合不重叠:wdkill 改 7 条
`bl`,wdone 改 4 条 `ldr`)。建议先 wdkill(定族)→ 卸载 → 再 wdone
(收窄到内联 4 点),避免一次实验里两个变量。

## 7. 残余风险

1. **`+0x10` 的 setter 未定位**(N2b §9.3):清零是否影响合法路径取决于
   setter 的调用频率。若 setter 只在 ioctl 入口写一次,则每次合法调用都会
   重新写入,清零无副作用;若某些路径复用旧值,则会退化为 -EFAULT。
   → 必须用功能用例判"WiFi 功能保持"。
2. **同族其它读者**:`adapter+0xd6f8` 在模块内被大量 `movz #0xd6e8` 访问
   (全 .text 命中 520 处,多数是别的结构),本轮只确认了
   `RTMP_COM_IoctlHandle` 内 patch 点之后不再读;其它读者若不做 NULL 检查,
   清零后可能走进错误分支(已见 `0x68b0 ldr x0,[x21,#0x10]; cbz x0` 这类
   带 NULL 检查的读者)。这是 wdone 作为"初版"的主要未知。
3. **只覆盖 4 个内联站点**:7 个包装器克隆的 168 个调用点仍需 wdkill 或
   §7.3 的系统性方案。
4. **不是最终修复**:一次性语义把"写陈旧地址"降级为"第二次失败",
   没有解决 `req->buf` 的生命周期;结论成立后应按 N2b §7.3 A/B 落地。

## 8. 复跑

```
python _local/work/n3-build/verify_sites.py
python _local/work/n3-build/simulate_patch.py
python _local/work/n3-build/reread_check.py      # +0x10 重读分析
python lg6151m-public/tools/oneoff/sigsegv/bmods/check_calls.py \
       lg6151m-public/tools/oneoff/sigsegv/bmods/out/wdone.ko
sh lg6151m-public/tools/oneoff/sigsegv/bmods/build_bmods.sh
```
