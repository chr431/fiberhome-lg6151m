# REVIEW-rxcount — wo_rxcnt_update_handle 零 patch 只读采样器(B3)

- 源码:`rxcount.c` · 构建:`build_bmods.sh` · 产物:`out/rxcount.ko`
- vermagic:`5.15.134 SMP mod_unload aarch64`
- 性质:**零 patch / 零写**。不写一字节内核文本,不写任何寄存器,不写任何
  内核内存;全部读取经 `copy_from_kernel_nofault`(extable 修复),读到坏
  指针只会得到负错误码,不会 oops(S0: ipanic 对任何 oops 强制重启)。

## 1. 观测对象(A5 静态链 + 本模块新增的环布局证据)

```
wo_rxcnt_update_handle(payload, len, bind)              mtk_warp .text+0x18b50
    cnt = *(u32*)payload
    for i in 0..cnt-1:
        wifi_chip_update_wo_rxcnt(bind+8, &payload[4+20*i])   .text+0x77dc
            ops = *(ctx+0x700); cb = *(ops+0x60); cb(*(ctx+8), entry)
```

`payload` 是 WO 固件回包,存于 warp entry 的 WO RX 环(.text+0x190f4..0x19194
反汇编):环基址 `entry+0x5110`,槽步长 `0x50`,槽内消息 VA 在 `slot+0x38`,
槽数在 `entry+0xA150`;消息 payload 在 `msg+0x20`。驱动消费回包后槽内
payload 字节仍在(状态字被清),因此 1Hz 读取即可看到"最近一次被处理的
20B×N 表"。

定位方式(与 tuphook 同一套,但**只读**):
- 锚点 = 导出符号 `warp_wlan_tx`(loader 跨模块解析),base = -0x970;
  `upd = base+0x18b50`;
- 正对照 = `sprint_symbol(upd)` 必须含 `wo_rxcnt_update_handle` + 入口字
  必须 `0xd503233f`;另用 `wifi_tx_tuple_add` 名字二次校验 base;
- bind 槽用 `sub_0` 与 `warp_entry_get_by_idx` 两处 adrp+add 交叉解码(必须
  一致),entry0+0x10 = key 非空才算活 bind;环槽数必须 1..64,否则关闭环
  采样只保留定位声明。

## 2. per-cpu 计数器 + hrtimer(1Hz)

- `alloc_percpu(struct rxc_stat)`:每 CPU 一份 {timer, samples, events,
  last_hash[64], 4 条快照环}。hrtimer 在目标 CPU 上 `HRTIMER_MODE_REL_PINNED`
  启动(`smp_call_function_single` 逐 CPU 起,错峰 cpu*1s),回调内
  `hrtimer_forward_now(+1s)` 自续。
- 每拍:对每个环槽读 payload,形状闸门 `1 <= cnt <= 70` 且 4+20*cnt 字节
  全部 nofault 可读;FNV-1a64 哈希;与上次哈希不同 = **一次事件**
  (events++,存入该 CPU 的 4 条快照环,记录 seq/时间/cpu/slot/cnt/hash/原始
  20B×N 字节)。
- /proc/rxcount:目标与名字验证行、ops/cb 名(sprint_symbol)、每 CPU
  samples/events、总事件率(mHz)、最新快照的 20B×70 表(最多 70 行 hex)。
- 事件率的用途:与 canary 命中率做相关(两条时间序列同源设备时钟)。

## 3. "零 patch"声明与静态证明

| 断言 | 证明 |
|---|---|
| 无文本写 | `check_calls.py` 闭包中 **无 stop_machine、无 apply_to_page_range、无任何 patch 路径**;未定义符号里没有写路径 API |
| 无寄存器写 | 源码无 `__raw_writel/writeq`、无 ioremap、无 MMIO 映射 |
| 无 kmem 写内核对象 | 只写自有 per-cpu 统计与自有快照环;所有目标读取经 nofault 只读 |
| 无 oops 路径 | 每一级解引用(nofault)失败即跳过;环/形状/名字全部范围断言 |
| 不改 mtk_warp 状态 | 只读 entry/ops/环;不写、不注册 notifier、不 hook |

`check_calls.py` 输出(实跑):

```
rxc_tick  -> EXT copy_from_kernel_nofault / ktime_get / hrtimer_forward / memcpy
rxc_read  -> EXT sprint_symbol / cpumask_next / mutex_* / __arch_copy_to_user
rxc_start_on_cpu -> EXT hrtimer_start_range_ns
```

无 stop_machine / 无 apply_to_page_range / 无 __arch_copy_from_user 之外的
写面;hrtimer 回调路径无锁(自有 per-cpu 数据 + nofault 读)。

## 4. 逐函数自审(锁 / 睡眠 / 故障路径 / 递归)

| 函数 | 锁 | 睡眠 | 故障路径 | 递归 |
|---|---|---|---|---|
| `rxc_tick`(hrtimer) | 无(per-cpu 自有) | 无(nofault 读不睡眠) | 任一读失败 -> continue;环/形状断言失败 -> 本拍空转 | 无 |
| `rxc_sample` | 无 | 无 | 槽指针/消息指针/payload 逐级 nofault;len 上限固化 1404B 栈 | 无 |
| `rxc_store_snapshot` | 无(仅本 CPU 写自有快照) | 无 | len 已由闸门限定 | 无 |
| `rxc_start_on_cpu/stop_on_cpu` | 无 | `smp_call_function_single(...,1)` 在 init/exit 进程上下文 | 失败返回由调用方忽略(计数仍能跑) | — |
| `rxc_resolve` | 无 | 无 | 名字/入口字不符 -> 拒绝加载;无活 bind -> entry=0,环采样关闭(仅告警) | — |
| `rxc_fill/rxc_read` | mutex | 可睡眠(合法) | 只读自有统计与快照 | — |
| `rxcount_init/exit` | 无 | 正常上下文 | 失败反向停 timer/释放 percpu | — |

## 5. 局限(判读必读)

1. **形状闸门是启发式**:任何 payload 首 u32 落在 1..70 的 WO 回包都会
   被当作"rxcnt 形状表"采样。事件语义 = "该槽内容发生变化",用于相关性
   分析,不声称"仅 rxcnt 回包"。
2. 环槽是驱动消费后残留的最近一次回包;若 wdma 查询停发,读数就是陈旧值
   (hash 不变 = 无事件,正确)。
3. 只取 entry0 的环(单 warp entry 设备);多 entry 需 reload。
4. 1Hz 采样会漏掉两次采样之间的抖动(设计如此:低频、零扰动)。
5. CPU 热插拔:设备不热插拔 CPU;若将来发生,PINNED timer 不迁移
   (加载后固定)。
6. 与 tuphook 同时加载时,tup 入口钩会让 rx 路径多几十条指令,采样数字
   不变(计数语义与延迟无关)。

## 6. 上机验证序列(F-07)

```
1. insmod dieblx.ko
2. insmod rxcount.ko
3. dmesg | grep rxcount
   # 期望:base=... upd=wo_rxcnt_update_handle+0x0/0xc4 [mtk_warp] ringcnt=N entry=...
   # ops: ctx=... ops=... + 三行 cb 名
4. cat /proc/rxcount | head -20            # 验证行 + 每 CPU samples 递增
5. (触发一次 wdma rxcnt 查询) 观察 events/mHz 与最新 20B×N 快照
6. rmmod rxcount
```

## 7. 最大残余风险

读到正在被驱动复用的环槽(payload 被改写中)—— 读取全为 nofault 的普通
load,最坏得到撕裂值/哈希抖动一次,**不会** oops、不会写、不影响驱动;
哈希事件率因此可能多计一次抖动(判读时用多拍一致性过滤)。

## 8. 增补(2026-11-02 夜)——环锚点纠偏:0xA150 读到 1504 的判读

实测 `entry+0xA150` = 1504 触发闸门(1..64)。对 mtk_warp.ko(md5 78fd7f00,
= A9 钉死件)全量反汇编复核结论:**偏移错读 + 字段语义不同**,1504 不是槽数。

- 环属主 = warp entry 内嵌的 woif slave 子结构,基址 **entry+0xF48**(证据:
  woif_init .text 0x198c0-0x198c4 把 chip idx 字节缓存到 entry+0xF48——
  drain tasklet(.text 0x18f2c,tasklet_init data=entry+0xF48 @0x198b8/0x199cc)
  开头 `ldrb w0,[x19]` 正是读它;A5 原判读把 drain 的 x19 当成了 entry 本体)。
- 真实锚点:槽基 `entry+0x6058`(=+0xF48+0x5110,步长 0x50 不变)、槽数
  `entry+0xB098`(=+0xF48+0xA150,drain udiv/msub 的模数 @0x19140-50)。
- **槽数 = 256**(0x100):woif_init 0x1995c-0x19970 存 `{0x100, 0x5e0}` 到
  entry+0xB098/0xB09c;槽初始化循环上界 x22==0x2000(步 0x20)= 256 次 ×
  步长 0x50 = 0x5000,恰好填满 [entry+0x6070, entry+0xB070)。TX 侧同构
  ({256,1504} @ entry+0x6048/0x604c,槽区 [entry+0x1020, +0x6020))。
- **1504 = 0x5E0 = 每槽 frag 缓冲区字节数**(page_frag_alloc_align 的
  fragsz,亦打包进 RXD ctrl 的 len 位段 ubfiz#16,#14)。旧锚 entry+0xA150
  落在 RX 槽数组内部 = 槽 207 的 desc+0x30(fragsz 字段)——1504 是结构
  必然值,不是巧合;1504×0x50=0x1CE00 会超出 entry 整体(0xb1a8)四倍,
  结构上不可能是槽数。
- 修正:RXC_OFF_RING 0x5110→0x6058、RXC_OFF_RINGCNT 0xa150→0xB098、
  RXC_MAX_SLOT 64→512(结构上界 256;闸门只挡荒谬值)。slot+0x38 语义
  = desc+0x20 = frag 缓冲 VA(WO DMA 落点),不变。旧锚下的"槽"实际落在
  TX 槽数组区,即使过闸采样也全是废数据——本次属闸门先行拦下,幸运。
