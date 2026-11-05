# U-G2 · 预注册:串口捕捞自杀窗(EL1 别名监控,写者 fire = 尸体带 pc)

> 写定时间:2026-11-05 11:15(+0800),任何数据产生之前。
> 依据:U-G1 结论(EL1 fire = 整机瞬时死且无 fatal 尸体/无 oops 进 pstore;
> 但 loglevel=8 全量串口控制台是独立记录通道,serial_server 全字节落盘);
> 用户授权:点名优先,崩溃无妨。
> 手法谱系:wwatch v1.11(EL1 布防)+ 串口录像机(PC 侧 tmpfiles/serial_ring.log)。

## 1. 问题(一句话可判决)

写者的 32B store 若以 EL1(别名 kmap 或 PAN-open 直写用户 VA)执行,武装该槽的
EL1 观察点后 fire 会杀死整机——**但临终文本(含 pc)会先打到串口**;
捞取并反解 pc = 候选终局 A。

## 2. 布防(执行前钉死)

- 槽 = 本 run 主导落点 uva(≥3 真命中验证几何后取);
- 4 槽全 EL1 store-only 8B:W0=alias+0、W1=uva+0、W2=alias+8、W3=uva+8
  (alias = 0xffffff7f80000000 + pa,PO 已 E2 钉死;两 VA 形态、q0+q1 双字);
- **无 selfstore、无任何 EL1 主动触发**(与 U-G1 c5/c6 的区别:只等真写者);
- 禁深睡(cpuoff_l/clusteroff_l/mcusysoff)保 WRP 寄存器;panic_on_oops=0;
  PC 灌流 ~240pps;受害者 main/单深度/wb=0(与昨夜主窗同几何)。

## 3. 判据

| 观察 | 判 |
|---|---|
| 武装后整机死 + 串口含 pc 行(pc 非我方上下文) | **候选终局 A**:pc/lr 反解 vmlinux/模块 → 二次窗复现同 pc → E3;压制复测 → E4 |
| 整机死 + 串口无 pc(纯静默硬件死) | EL1 fire 通道在 oops 打印层之下死亡 → 串口通道也废 → EL1 tier 判"本平台不可用"终局(仪器不可能性 E2 补强) |
| ≥30 落地零崩溃 | 写者完成写入不触及被监 alias/uva 槽 q0/q1 的 EL1 store ⇒ **B2′ 别名形态与 PAN-open 直写形态双双大削弱(E2)**;残余 = EL1-plain 经其它 VA?不可能(仅两别名)/STTR(已 E1 排除)/DMA(B4t/B5)→ 收口至 B4t/B5 |
| λ 塌缩(K9 样) | 不应发生(受害者自写是 EL0→用户 VA,EL1 观察不匹配);若发生 = 新现象,如实记录 |
| 期间 NE 自然行 | 照常记账,窗口前后对账 |

## 4. 风险与边界

- 写者写序若 q2/q3 先行(+0x10/+0x18 未监)→ fire 滞后到 q0/q1 或漏;
  预注册按"绝大多数 memcpy 升序"接受此边界;
- 非写者的合法内核别名 store(迁移/compaction)可能先 fire → 尸体 pc 可判别
  (migrate/copy 族=良性)→ 记录不误报;
- 串口控制台长会话失聪风险:开窗前 serial_cmd 活性验证,失聪即中止开窗;
- 04:00 定时重启今晨已发生,窗口与下一次 04:00 无冲突。

## 5. Skeptic 自检

1. ☑ 串口录像机活性(STATE logged_in=True + date 命令回显验证)
2. ☐ 几何 ≥3 真命中验证后布防;patrace PA 互证
3. ☐ 无 selfstore/无主动 EL1 触发(与 c5/c6 的本质区别)
4. ☐ NE 基线与解除(disarm)路径就绪;串口 auto-relogin 验证过(重启安全)
5. ☐ 灌流在窗内全程;λ 参考段 ≥5/min 才算有效暴露
