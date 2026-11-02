# REVIEW-wdkill — mt_wifi 用户拷贝族归因杀开关(7 个包装器克隆)

- 源码:`wdkill.c` · 构建:`build_bmods.sh` · 产物:`out/wdkill.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`(构建脚本尾部自证)
- 产物 md5:`28278ac9b4548f684e4554228594f5dd`(180,064 B)
- 性质:**会写内核文本的 B3 模块**(7 个 4 字节 patch,`rmmod` 全量还原)。
  不改 mt_wifi 的任何数据结构;只把 7 个 `bl __arch_copy_to_user` 改成
  `bl wdkill_stub`,stub = `mov x0,x2; ret`(返回"全部未拷贝"=len)。
- 依据:`_local/investigations/sigsegv-tools/phase-AB/N2b-uaccess-sites.md`
  §7.0(杀开关)、§5.1(168 个调用点统一从常驻描述符取 dst)。

## 0. 重要:N2b §7.0 的 `mov x0,xzr` 方案在本内核上会立即重启,已弃用

N2b 建议把 7 个克隆的 `csel x0,x5,xzr,eq` 改成 `mov x0,xzr`,让
`copy_to_user` 恒以 NULL 为目标。**本内核不能这么做**:

| 事实 | 证据 |
|---|---|
| `CONFIG_HARDENED_USERCOPY=y` | 设备 IKCONFIG `tmpfiles/an4/config.gz` 与构建树 `.config` **逐行一致**(5163/5163 非空行,集合差为空) |
| `CONFIG_PANIC_ON_OOPS=y` | 同上 |
| 每个克隆在 copy 前都调 `__check_object_size(dst,len,true)` | W1 `0x25bc8 bl 0x15240`(x0=原始 dst);W2..W7 同构 |
| NULL dst → `usercopy_abort("null address")` → `BUG()` | `mm/usercopy.c:147-157`(`ZERO_OR_NULL_PTR(ptr)` 命中)与 `:83-100`(BUG) |
| BUG + panic_on_oops → 立即重启 | S0 已实证本机 ipanic 对任何 oops 强制重启 |

即:第一个走到的 ioctl 就会把设备重启,归因实验变成一次事故。

## 1. 实际采用的杀开关:替换 copy 调用,而不是替换目标地址

7 个克隆的尾部形状完全一致(N2b §3 + 本轮 objdump 复核):

```
    mov  x2, x4                 ; len
    mov  x1, x6                 ; src
    bl   __arch_copy_to_user    ; ← 本模块改这一条
    mov  x4, x0                 ; 返回值(未拷贝字节数)
    ...
    ldp  x29,x30,[sp],#0x10
    autiasp
    mov  x0, x4
    ret
```

把 `bl __arch_copy_to_user` 改成 `bl wdkill_stub`:

```
wdkill_stub:
    mov  x0, x2                 ; copy_to_user 契约:返回未拷贝字节数
    ret                         ; 回到 bl 的下一条
```

效果:
- **一条 sttr 都不发**,不写任何用户内存(比 N2b 方案更彻底);
- 不触发 hardened-usercopy 检查、不产生缺页异常、不 BUG;
- 168 个调用者全部看到"整段拷贝失败"→ ioctl 返回 `-EFAULT`,
  与真实坏指针的语义一致;
- 克隆自身的 `paciasp/autiasp`、栈帧、x19/x20 保存全部不碰
  (stub 只写 x0,不建帧,不动 x30)。

W7 是叶子克隆(无 paciasp 帧),同一模型同样成立:它的 copy 调用点
`0x2dc204` 后面是 `bl 0x2dc12c`,stub 返回后照常执行。

## 2. 站点表与期望字节(加载时逐点校验,不符即 -EINVAL)

`.text` 偏移取自 N2b 快照(`mt_wifi.ko` 13,551,208 B);**每个站点在写之前
校验 4~5 个字**:

| 克隆 | csel 偏移(指纹) | 期望 csel | patch 点(bl) | bl 前 3 字 |
|---|---|---|---|---|
| W1 @0x25bac | `0x25be4` | `9a9f00a0` = `a0 00 9f 9a` | `0x25bf4` | `d503229f aa0403e2 aa0603e1` |
| W2 @0x13c318 | `0x13c350` | `9a9f00a0` | `0x13c360` | 同上 |
| W3 @0x1eabfc | `0x1eac34` | `9a9f00a0` | `0x1eac44` | 同上 |
| W4 @0x1f5700 | `0x1f576c` | `9a9f00a0` | `0x1f577c` | 同上 |
| W5 @0x2373e8 | `0x237420` | `9a9f00a0` | `0x237430` | 同上 |
| W6 @0x2b46f0 | `0x2b4728` | `9a9f00a0` | `0x2b4738` | 同上 |
| W7 @0x2dc160 | `0x2dc1f8` | **`9a9f0080`** = `80 00 9f 9a` | `0x2dc204` | `d503229f aa0503e1`(W7 无 `mov x2,x4`) |

即任务要求的 **6×`a0 00 9f 9a` + 1×`80 00 9f 9a`** 全部作为指纹校验;
另加 `csdb`、`mov x2,x4`/`mov x1,x5`、以及 bl 操作码
(`(w & 0xfc000000) == 0x94000000`)。

离线复核(对 `analysis/vendor/mods/5.15.134/mt_wifi.ko` 实跑
`verify_sites.py` / `simulate_patch.py`):

```
=== 7 wrapper csel sites ===
W1..W6 off=... got=[a0 00 9f 9a] want=[a0 00 9f 9a] OK
W7      off=0x2dc1f8 got=[80 00 9f 9a] want=[80 00 9f 9a] OK
=== 4 inline ldr sites (wdone 用) ===
all OK
=== WDKILL: patch (simulated) ===
W1 @0x025bf4 94000000 -> 143b6903  (decodes back to stub)
...
W7 @0x2dc204 94000000 -> 14308f7f  (decodes back to stub)
```

> 注意:`bl` 在文件里是 `94000000`(重定位占位),运行期由 loader 填成
> 真实位移,所以**不能**把 `94000000` 当期望字节;本模块只校验它是 BL
> 操作码,并在报告里用 `sprint_symbol` 打出目标名(可能是
> `__arch_copy_to_user`,也可能是 mt_wifi 的 PLT 桩 —— `CONFIG_ARM64_MODULE_PLTS=y`,
> 所以**不**用目标名做门禁)。

## 3. 基址定位(三重)

`kallsyms_lookup_name` 未导出(5.7+)、`CONFIG_KPROBES=n`,因此:

1. **主路径:module 链表**。`load_module()` 在 init 之前已把
   `THIS_MODULE->list` 链入全局 `modules`;从自身出发走 `list.next`,
   用 `copy_from_kernel_nofault` 读每个候选的 `name`(偏移 24,配置无关),
   找 `mt_wifi`,取 `mod->core_layout.base`(`.text` 在 core layout 偏移 0:
   `layout_sections()` 把 SHF_EXECINSTR|SHF_ALLOC 段排在最前,`.text` 是
   段表第一个)。
   - `try_module_get()` 钉住 mt_wifi(卸载时 `module_put`),补丁期间
     驱动不会被卸载。
   - `BUILD_BUG_ON` 钉死 `offsetof(struct module,{state,list,name,core_layout})
     = {0,8,24,320}`;设备 `.config` 与构建树逐行一致,所以 320 是设备值。
2. **交叉校验:页扫描**。模块区 `[MODULES_VADDR, MODULES_END)` 逐页读 32 字节,
   匹配 mt_wifi `.text` 开头 32 字节
   (`02 48 43 91 00 48 43 91 21 1c 00 12 00 4c 33 91 3f 23 03 d5 43 48 73 39
     02 00 80 d2 7f 00 22 6b`;该 32 字节在 .ko 中出现 2 次,但只有 .text 起点
   是页对齐)。必须**恰好命中 1 处**且与链表结果**相同**,否则拒绝。
3. **身份校验**:`sprint_symbol(base+0x25be4)` 必须含 `[mt_wifi]`。

## 4. 逐函数自审

| 函数 | 锁/睡眠 | 故障路径 | 递归 |
|---|---|---|---|
| `wd_rep` | 无锁;写自有静态缓冲 | `vsnprintf` 截断由长度保护 | 无 |
| `wd_find_mt_wifi` | 无锁(模块链表读);**不睡眠** | 每步 `copy_from_kernel_nofault`;`guard<1024` 防环 | 无 |
| `wd_scan_text` | 无锁;init 上下文可睡眠但本函数不睡 | 全部 nofault;命中数 !=1 即返回 0 | 无 |
| `wd_check_site` | 无锁 | 全部 nofault;读失败记 UNREADABLE 并判失败 | 无 |
| `wd_locate` | init 上下文;`try_module_get` 不睡眠 | 任一断言失败返回负码,不写任何字节 | 无 |
| `wd_validate` | 无 | 7 点全过才置 `g_valid` | 无 |
| `wd_patch_words` | `stop_machine`(会睡眠,init/exit 上下文) | PTE walk 失败→不写;写完恢复 PTE;返回前不改 PTE 权限 | 无 |
| `wd_flip_cb` / `wd_patch_cb` | **stop_machine 回调内禁止睡眠**;只做写 + dsb + tlbi/ic | 原子计数与 `num_online_cpus()` 配对,不会死等 | 无 |
| `wd_install` | init 上下文;7 次 stop_machine | 任一点失败→回滚已写的点;写后逐点读回 | 无 |
| `wd_uninstall` | exit 上下文;同样 stop_machine | 先验"当前字==我写的字"再还原;base 变了就跳过 | 无 |
| `wd_show` | seq_file;只读自有状态 | 无解引用目标内存 | 无 |

**调用闭包**(`python check_calls.py out/wdkill.ko`,实跑):

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

全部外部符号均为内核导出(`try_module_get`/`module_put` = EXPORT_SYMBOL;
`stop_machine`/`copy_from_kernel_nofault`/`sprint_symbol` = EXPORT_SYMBOL_GPL;
`seq_*`/`single_*`/`proc_*` = EXPORT_SYMBOL)。**没有** module_alloc / vmap /
ioremap / apply_to_page_range / kallsyms_lookup_name 等不可用或高危 API。

## 5. 崩溃路径分析(为什么它不该 oops)

| 风险 | 处置 |
|---|---|
| 站点偏移随 build 漂移 | 7×(4~5 字指纹 + BL 操作码)全过才写;`dryrun=1` 可先看实际字节 |
| 基址找错 | 链表 + 页扫描双路必须一致;`sprint_symbol` 必须 `[mt_wifi]`;页对齐 + 区间检查 |
| `b/bl` 位移越界 | 逐点检查 `-(1<<27) <= d < (1<<27)`,并**反解码**回目标地址比对 |
| PTE walk 遇到大页 | `pmd_leaf`/`pud_leaf` 直接拒绝(否则 `apply_to_page_range` 式 BUG_ON) |
| 写入过程中别的 CPU 在执行被改指令 | `stop_machine` 全 CPU 停 + 每 CPU `dc cvau/ic ivau/dsb/isb`(与 `aarch64_insn_patch_text` 等价序列) |
| 4 字节写非原子 | arm64 对齐 4 字节 store 单拷贝原子;且写入在 stop_machine 内完成 |
| stub 执行时出错 | stub 只有 `mov x0,x2; ret`,不访存、不建帧、不改 x30 → 不可能缺页/不可能 PAC 失败 |
| mt_wifi 被卸载 | `try_module_get` 钉住;`rmmod` 时 `module_put` |
| 被人 `rmmod -f` | **禁止**:强制卸载会释放本模块 .text,残留的 `bl` 会跳进已释放页 |
| 还原时别人改过 | 先比对"当前字 == 我写的字",不符则跳过并告警,不盲写 |

## 6. 加载 / 卸载序列

```
# 0) 先确认现场(不写任何东西)
insmod /data/gw/wdkill.ko dryrun=1
dmesg | tail -60 ; cat /proc/wdkill
#    期望:VALIDATION OK: 7/7 clones match;7 行 "ok";bl -> 名字行

# 1) 正式安装(仍不写用户内存,只改 7 条 bl)
insmod /data/gw/wdkill.ko
cat /proc/wdkill     # 顶部应为 PATCHED
#    观察窗口:记录率(中性窗 vs 开关窗)—— 判据见 05_LOG/2026-11-03-03

# 2) 卸载(逐点还原 + 读回校验)
rmmod wdkill
dmesg | tail -10     # 期望 "restored 7/7 sites, 0 skipped"
cat /proc/wdkill     # 若还在:顶部不再是 PATCHED
```

**顺序建议**:若 N1 的 uacatcher 已在跑,先加载 catcher(它只读、零 patch),
再加载 wdkill;这样开关窗口内的每一次 copy 失败都有 LR/pid 上下文可对照。
若 catcher 尚未就绪,单独上 wdkill 也能做归因(看 32B 记录是否塌向 0)。

## 7. 残余风险

1. **杀开关改变管理面行为**:所有 mt_wifi 用户拷贝返回 -EFAULT,
   `iwinfo`/私有 ioctl 查询会失败。数据面(WiFi 转发)不经过这些拷贝,
   但"WiFi 功能保持"的判据必须包含管理面用例(见预注册文档)。
2. **指纹只覆盖 11 个站点邻域**:若厂商 build 在这 4~5 个字之外改了
   调用约定(例如把 len 换成 x3),指纹仍会通过而语义已变。缓解:
   `dryrun=1` 先人工看 `/proc/wdkill` 的 bl 目标名与站点上下文。
3. **`.text` 起点假设**:依赖 `layout_sections()` 把 `.text` 放在 core
   layout 偏移 0。若设备 build 的段表顺序不同,`base+off` 会错 →
   指纹必然失败 → 拒绝加载(不会误写)。页扫描交叉校验是第二道保险。
4. **未覆盖 5 个内联站点**:本模块只关 7 个克隆的 168 个调用点;
   `0x2976d8` 等 5 个内联站点仍会写用户内存 —— 归因结论必须按
   "克隆族 vs 内联族"分开表述(这正是 wdone.ko 的对象)。
5. **不是修复**:这是归因实验工具。结论出来后应卸载,再按 N2b §7.3
   选 A/B 方案。

## 8. 复跑

```
# 离线校验(不需要设备)
python _local/work/n3-build/verify_sites.py
python _local/work/n3-build/simulate_patch.py
python lg6151m-public/tools/oneoff/sigsegv/bmods/check_calls.py \
       lg6151m-public/tools/oneoff/sigsegv/bmods/out/wdkill.ko
# 构建
sh lg6151m-public/tools/oneoff/sigsegv/bmods/build_bmods.sh
```
