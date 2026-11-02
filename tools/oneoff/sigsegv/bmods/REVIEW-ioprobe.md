# REVIEW-ioprobe — CCB/MMIO 可达性探针(B2b)

- 源码:`ioprobe.c` · 构建:`build_bmods.sh` · 产物:`out/ioprobe.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`
- 性质:**只在 init 期探测**:ioremap → 读 16B → iounmap,init 返回后零足迹(无节点、无映射、无 notifier)。**绝不写任何寄存器。**

## 1. 默认探针表(来源标注在源码内)

| # | 地址 | 名称 | 来源 |
|---|---|---|---|
| 0 | 0x94000000 | ccb_base | 任务书/C-184(CCB 0x94000000-0x9820ffff) |
| 1 | 0x9820f000 | ccb_tail | 同上区间尾页 |
| 2 | 0x9fcb0000 | medmcu_desc | 05_LOG/wed-md-romap(lk_medmcu_reserved_desc +0x340000) |
| 3 | 0xaff00000 | lk_medmcu | 同上(lk_medmcu_reserved +0x40000) |
| 4 | 0x15000000 | ethsys | DT: ethsys@0x15000000 sz 0x10000 |
| 5 | 0x151e0000 | wocpu_ilm | DT(A3:WO 窗) |
| 6 | 0x15d00000 | scp_sram | 08-a3(SCP SRAM) |
| ~~7~~ | ~~0x18000000~~ | ~~consys~~ | **已从默认表剔除**(S0 实测该窗触发 SEA;默认表绝不包含已知 abort 区) |
| 8 | 0x15100000 | netsys | DT: netsys@0x15100000 sz 0x20000 |
| 9 | 0x15105c00 | netsys_txring | A4 实测 /dev/mem 空读点 |
| 10-12 | 0x15010000/0x15011000/0x15012000 | wed1/2/3 | DT: wed@0x15010000(wed2/wed3 各 0x10000) |

默认表共 12 个探针(原 13 个,consys 已剔除);排序原则:RAM 型预留窗在前,活寄存器块(netsys/WED)最后——若中途出事,printk 顺序
已保留最安全证据。`addrs=` 参数可覆盖(逗号分隔十六进制,≤24 个);`cached=1` 追加
第二遍 ioremap_cache(默认关,见 §4)。

## 2. 逐函数自审

| 函数 | 锁 | 睡眠 | 故障路径 |
|---|---|---|---|
| `iop_hex` | 无 | 无 | 非法字符返回 -1(自写解析器,无库依赖) |
| `iop_parse_addrs` | 无 | 无(strchr) | 坏 token -EINVAL;超 24 截断 |
| `iop_one` | 无 | ioremap/iounmap 可睡眠——**仅 init 上下文,合法** | ioremap NULL → 打印 FAILED 继续;读值全 0/全 FF 原样输出并标注 |
| `ioprobe_init/exit` | 无 | 同上 | addrs 解析失败 -EINVAL,不加载 |

两态映射:`ioremap()`=Device nGnRE(即"nocache"态)必测;`cached=1` 时加测
`ioremap_cache()`(普通可缓存)。读取 = 对齐 8 字节 volatile 载入 ×2(`__raw_readq`),
无任何写指令(反汇编级:探针路径外呼仅 `__ioremap/ioremap_cache/iounmap/_printk`,
见 §3,不存在 store 到映射区)。

## 3. 静态自检(`python check_calls.py out/ioprobe.ko`)

```
init_module -> EXT strchr                       (kernel)
iop_one     -> EXT __ioremap / ioremap_cache / iounmap / _printk
cleanup_module -> EXT _printk
```
无锁、无分配、无 notifier;唯一风险语义全部集中在 `__raw_readq` 本身(§4)。

## 4. 残余风险(本模块的核心风险,必须先读)

1. **SEA 无 fixup**:arm64 5.15 的 `do_sea()`(arch/arm64/mm/fault.c:704)不做
   `fixup_exception()`(fixup 只在 `__do_kernel_fault`:367 对翻译/权限失效生效)。
   即:若某地址的总线访问真会 raise synchronous external abort,内核态读它 = oops,
   设备 panic_on_oops=1 + panic=3 → **重启**。没有任何软件手段可以拦截。
   - 缓解依据:A3/A4 已从用户态经 /dev/mem(同为非缓存属性)实测这些窗口
     "静默返回空、无 SEA、设备无恙"(C-184/C-185),同一物理访问在内核属性下
     预期同行为;默认表只收录这些**已实测不 abort** 的窗口。
   - 新地址必须单个试探:`insmod ioprobe.ko addrs="0x<单个>"`,绝不可对未知区域整表扫描。
2. **读副作用**(即便不写):read-to-clear 类寄存器(FIFO 口、IRQ status)被读一次即消耗。
   默认表只打**区域基址**(+A4 那个已知读点);如 WED 基址 +0x0 是 GLO_CFG 类配置寄存器
   (07_LEVER 实证 0x40000045),非消耗型,风险低——但判读时须知存在此类别。
3. **cached=1 的投机读**:可缓存映射允许 CPU 投机预取到相邻地址,副作用窗口放大到
   缓存行级。默认关闭;开启前必须已用 nocache 态确认该点安全。
4. ioremap 对同一 PA 建别名映射是常规操作(vmalloc 空间独立),与在役驱动无冲突。

## 5. 加载顺序建议

最后(dieblx 黑匣子在位后再跑,SEA 万一发生也有完整现场记录)。

## 6. 上机验证序列(F-07)

```
1. insmod ioprobe.ko addrs="0x9fcb0000,0xaff00000"   # 先 RAM 型窗,2 个点
2. dmesg | grep ioprobe; 健康态观察 60s(无 oops、uptime 连续)
3. rmmod ioprobe
4. insmod ioprobe.ko                                  # 默认全表(nocache 态)
   # 判读:r0/r1 与 A3/A4 用户态读数对照——一致=属性无关;不一致=映射属性相关;
   # 全 0/全 FF 原样输出,交人工判读(可能真未上电/未解码)
5. rmmod ioprobe
6. (可选,cached 实验需显式批准)insmod ioprobe.ko cached=1 addrs="0x9fcb0000"
```

## 7. 最大残余风险

§4-1 的 SEA 重启(单点、不可拦截、有 A3/A4 证据背书)。**consys 0x18000000 已在
S0 实证触发 SEA** —— 该点因此从默认表移除(源码注释同步说明);执行纪律不变:
一次一个新地址、先 nocache 后 cached、dieblx 在位。

## 8. 本轮重编译(md5)

- 变更:默认探针表剔除 consys 0x18000000(其余 12 点不动)。
- 新产物 md5:`fb480f5c3184233022e9bd979b85ed26  out/ioprobe.ko`(123,288 B)
- 构建后自检:`check_calls.py out/ioprobe.ko` 闭包仍只有
  `__ioremap/ioremap_cache/iounmap/_printk/strchr`(无写路径)。
