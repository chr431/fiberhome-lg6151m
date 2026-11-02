# 02 · D18 预注册 · WO rxcnt 事件率 × 32B 记录命中率 同窗相关性（2026-11-02 晚间观测线）

> **预注册文档:实验开窗之前写定并 commit。** 实验后只追加 §10–12,不改 §1–9。
> 仪器事实来源:`tools/oneoff/sigsegv/bmods/REVIEW-rxcount.md`(零 patch 只读采样器)、
> `REVIEW-dieblx.md`(黑匣子,本会话先载)、B4-runbook 的 canary 观测方法
> (`scanary_c2 --victim main --hold-us 10000 ...` 固定调用,md5 17376b74… 在设备)。
> 本文档中性信息:不含部署目标网络名与个人凭证。

## 1. 问题

同一 900 s 观测窗内,**WO rxcnt 消费环的事件率**(rxcount 采样)与 **32B 栈记录真命中出现率**
(scanary inj=0 HIT_APPEAR)是否时间相关?

## 2. 假设

- **H1(相邻)**:写入者的生产/搬运链位于 `wo_rxcnt_update_handle → wifi_chip_update_wo_rxcnt
  → ops 回调(tx_fill/rx_fill/wo_rxcnt)` 邻域(mtk_warp 主机侧消费 WO 回包的路径)⇒ 两条
  时间序列同窗共变(事件簇时间对齐)。
- **H0(独立)**:写入与 WO rxcnt 处理无时间耦合 ⇒ 同窗序列无相关(在检出功效内)。
- 方向语义(预写死):**相关 = 相容证据**(写入者活动与 WO rxcnt 处理时间锁定,支持"邻域"
  归因的下一步投入),**不是因果证明**(共同外部因——流量水平——可同时驱动两者,§6);
  **不相关 = 排除紧耦合**(在该窗口的功效内,写入者不逐 rxcnt 回包/逐槽写)。

## 3. 预测

- H1 为真:scanary 命中簇与 rxcount 事件簇落在相同 30 s 桶(或 ±1 桶滞后)的频率显著高于
  独立过程的期望;皮尔逊 r(30 s 桶计数序列)明显偏离 0(定性,量级见 §5)。
- H0 为真:桶计数序列无可分辨共动(r ≈ 0,散点无结构)。

## 4. 判据(预写死)

- **窗有效性(前提)**:rxcount dmesg 出现定位行(`upd=wo_rxcnt_update_handle+0x0/… [mtk_warp]`)
  且 `/proc/rxcount` 有 per-CPU samples 递增;scanary START 参数与 §9 逐字一致 + SELFTEST_OK×4 +
  SELFTEST_PASS + EXIT reason=duration + 全窗 probe_bad=0;日志三断言(行数/md5/字段)拉回。
  任一不满足 ⇒ **INVALID**。
- **PASS(支持 H1,相容)**:真命中(inj=0)≥ 30 条 **且** rxcnt 事件 ≥ 30 次 **且**
  桶序列皮尔逊 |r| ≥ 0.5(30 桶,粗定性阈)或互相关在 lag∈{0,±1 桶} 出现清晰峰。
- **FAIL(支持 H0,排除紧耦合)**:真命中 ≥ 30 **且** rxcnt 事件 ≥ 30 **且** |r| < 0.25
  且互相关无峰。
- **中间带(|r| 0.25–0.5)**:不定,标 E1 探索性,不进 CLAIMS 强结论。
- **探索性降级**:真命中 < 30(检出功效不足,参考同夜 B2 基线 109/900 s,但跨窗命中率
  已知漂移 1–127/min 不可比)⇒ 只写"在 N 次采样中未见共动",不得写"无耦合"。
- **0/0 类**:两侧任一为 0 ⇒ 记 N 与 LOD,INVALID(不可判)。

## 5. 样本量/功效

- 参考:B2 基线 900 s 真命中 109 条;rxcount 事件率未上机实测(首测)。30 s 桶 × 30 桶。
- 过散:两过程均为阵发型(§4.1 纪律),不用 Poisson p 值做主判据;皮尔逊/互相关仅定性,
  判据以预写阈值为准。
- 最小可检效应:桶计数共动需 |r| ≥ 0.5 才可读(PASS 阈);命中 < 30 条时功效不足自动降级。

## 6. 混杂与控制

- **共同外因**:流量水平可能同时推高 rxcnt 事件与命中率(若写入随流量)——相关不能区分
  "邻域因果"与"共同驱动",结论措辞按 §2 方向语义(只写相容/排除紧耦合)。
- 时间漂移:单窗 900 s 内完成,不开第二变量;窗内零追加仪器(除预注册的 /proc/rxcount
  只读轮询,30 s 周期)。
- audit 270/271 规则整晚在位(A2 线,所有窗恒同,非臂间变量);dieblx 常驻;
  tuphook 不参与本实验(dryrun 已在开窗前 rmmod)。
- 载荷:不主动灌流量(观测自然流量下的自发过程);/proc/net/dev 窗初/窗末各记一份。
- 同窗对照:同一时间轴双仪器(两序列同源 /proc/uptime 锚点对齐)。

## 7. 停止规则

- 任何 oops/重启 ⇒ 停整线,保 pstore/console-ramoops,按 B4 分支 C 处置;
- lgssh 连续不可达 > 8 min ⇒ 停线报告;
- rxcount insmod 后 60 s 内 dmesg 出现异常(oops/WARN)⇒ 立即 rmmod,本实验 INVALID;
- 03:30 硬停线。

## 8. 分析计划

- 主终点:30 s 桶两条计数序列的皮尔逊 r + lag∈{0,±1,±2 桶} 互相关(定性,判据 §4)。
- 次终点(探索性 E1):命中记录形状(len/ip 域)与 rxcnt 快照 20B 表内容的字段级对照
  (是否存在共享位域形态)。
- 对齐:scanary EV 微秒(进程 CLOCK_MONOTONIC 起点)+ 窗起 /proc/uptime → 统一 uptime 轴;
  rxcount per-CPU events 为累计值,按轮询差分。
- 多重比较:主终点唯一;次终点不进主判决。

## 9. 变更记录(实验前钉死)

| 项 | 值 |
|---|---|
| 设备态 | v4.1 正常态,boot 222ae7d8(会话起点 uptime ≈1232 s 核验),5.15.134,163 模块 |
| 黑匣子 | dieblx.ko(md5 2ab6b5e8…)insmod 于 uptime 1582.81,60 s 健康观察通过后开窗 |
| rxcount | /data/repro/rxcount.ko md5 cce2040a442a9b25b50e9ca5284dad3b(零 patch;1 Hz per-CPU;hash 变化=事件)。
  **开窗前修订(v2)**:首版(md5 6371ada2…)只检查 warp entry0;实测设备 count=3 而 entry0
  key=0(活 bind 在 entry1),首版会把环采样错误关闭 ⇒ 窗 INVALID。v2 = entry0..cnt-1 遍历
  (步长 0xb1a8,nofault 只读语义不变,无新增外部调用);修订发生在 D18 开窗之前,tuphook
  dryrun#2 已用同款遍历实测定位 entry1(见 §10)。 |
| scanary | /data/repro/scanary_c2 md5 17376b74…(B4/D9/C2 同件,观测主仪器) |
| 固定观测调用 | `/data/repro/scanary_c2 --victim main --duration 900 --epoch-sec 0 --probe-sec 120 --hold-us 10000 --period-us 5000 --stride 16 --writeback safe --log /data/repro/d18_rxcnt.log` |
| rxcount 轮询 | 窗内每 30 s:`cat /proc/uptime; cat /proc/rxcount`(head 至 totals 行),记录于 PC 侧时间轴文件 |
| 窗起止 | /proc/uptime 双锚点 + date +%s(PC 侧对表) |
| 模块态 | dieblx 常载;rxcount 窗前置、窗末即 rmmod;tuphook 不在位 |

## 10. 结果

(2026-11-02 晚会话追加;boot 222ae7d8 全程无重启。)

- **前置正对照链全部通过**:rxcount v2 insmod 后 dmesg 依次出现
  `live bind at entry1 (entry0 unbound)` → `ring count 1504 implausible, ring sampling disabled`
  → `base=… upd=wo_rxcnt_update_handle+0x0/0x8a8 [mtk_warp] ringcnt=0 entry=0`;
  /proc/rxcount 采样器空转(samples 递增,events 恒 0)。
- **环采样被设计闸门关闭**:entry1+0xA150 槽数字段实测 **1504**,超出 REVIEW-rxcount §1
  预写安全域 1..64 ⇒ 模块按设计只保留定位声明、关闭环采样。**未在运行中放宽闸门**
  (放宽 = 把未知区域当 rxcnt 环采样,噪声事件会伪装成"≥30 次事件"进而把噪声-命中零相关
  误读为 FAIL/H0——见 §12)。
- ⇒ **900 s 同窗未开**(无 rxcnt 事件序列,主终点不可算)。
- 旁产情报(已入 05_LOG/2026-11-02-03 与 01_CLAIMS C-190):同一 entry-walk 在 tuphook
  dryrun#2 下解析出 ops 链,三个 fill 回调全部落在 mtk_wed 文本区(详见该文件 §10)。

## 11. 判决

- **INVALID(§4"0/0 类":两侧任一为 0 ⇒ 不可判)**——rxcnt 事件侧恒 0(仪器闸门),非阴性。
- 01_CLAIMS:无 D18 结论行;仪器事实入 C-190 notes。
- 重跑前置:离线复核 mtk_warp 反汇编中环槽数字段的语义(entry1+0xA150=1504 是真槽数
  还是字段偏移错位),再审 1..64 闸门;两者都定案前不得重跑。

## 12. 偏差与教训

1. **两处 oneoff 模块设计假设被实测打破**(同族教训:设计期 objdump 推断必须上机复验):
   ① bind 检查只看 entry0——实测 count=3 而 entry0 key=0(活 bind 在 entry1),v1 会把
   环采样静默关闭;② 环槽数安全域 1..64 是猜的——实测 1504。两者都是"模块按设计安全
   拒绝",设备零风险,但说明 REVIEW 文档的"实测"栏在首机上机前其实全是推断。
2. **不放宽闸门的决定**:当晚本可改 1..64 → 1..2048 强行开窗,但那会把"未知内存区域"
   当观测对象,事件的语义不可守,主终点会被系统性噪声污染—— INVALID 比脏数据便宜。
3. lgssh 文本通道在 Windows 侧引入 CRLF + 尾换行(证据回拉必须做字节级重建 + md5 复核,
   见本地 evening-observational.md §证据)。
