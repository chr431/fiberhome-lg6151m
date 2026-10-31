# 状态真值总线（STATE BUS）v1.0 · 2026-11-01

> 本文是 M2「监测诚实性」的**实现契约**：状态怎么产生、怎么发布、谁读、读不到时显示什么。
> 验收合同见 docs/RELIABILITY_SPEC.md §M2（R2.1–R2.7）；病理史见 docs/AVAILABILITY_DESIGN.md §8。
> 一句话：**设备真实状态 → GUI/指示灯 的链路，检测 ≤1s、呈现 ≤1s，且永不显示假绿。**

---

## 0. 为什么重构（一句话病理）

旧链路最坏滞后是分钟级：`watchdog 30s 周期判据 → /tmp/watchdog_state（迁移式快照）→
avail_sampler 10min → avail_watch 2s 边缘 → GUI 3s/8s 轮询 → led_mgr 2s 但输入陈旧`。

四次「账面全绿而实际已死」的共同根因两条（AVAILABILITY_DESIGN §8.1）：
1. **存在性判据冒充结果判据**（进程在/端口在 ⇒ 显示绿）；
2. **迁移式快照 + 稀疏采样**：采样间隔内死过又自愈，采样时快照已回绿 ⇒ 账面恒绿。

结论：**<3s 的难点不在 GUI 轮询，而在检测本身**。所以先把检测压到 1s，再谈呈现。

---

## 1. 架构（单一状态源 + 单一高频循环）

```
                ┌──────────────────────────────────────────────┐
                │ gw/fast_watch.sh  (1s 节拍, 全局唯一高频循环) │
                │  · 廉价事实: 单次 awk 扫 4 个 /proc           │
                │    (hostapd 活套接字/默认路由/监听位/accept队列)│
                │    + 免 fork 的 sysfs flags 与 /tmp/*.hb 读取  │
                │  · 网络探针(错峰): tcp80@1s dns@2s icmp@6s    │
                │    http200@10s ssh_banner@300s                │
                │  · 判据分级 L1/L2/L2+/L3 随状态一起发布        │
                └───────────────┬──────────────────────────────┘
                                │ 原子 rename 发布（唯一写入方）
     ┌──────────────────────────┼─────────────────────────────────────┐
     ▼                          ▼                                     ▼
/data/gw/run/state.json   /data/gw/run/state.led           /tmp/fast_watch.beat
（状态真值, 迁移时写）      （LED 投影, 同一次发布）          （每拍心跳, tmpfs）
     │                          │                                     │
     ▼                          ▼                                     ▼
 /api/state（api_state.sh）  led_mgr.sh（只执行不判断）       新鲜度判据（GUI/LED）
     │                          └─ 写 GPIO 后**读回校验** → /tmp/led_mgr.verify
     ▼
 gw/www/app.js（状态页真值条 + #/state 页, 1s 节拍）
     └─ 渲染新版本后回传 /api/render?v=&a=  → lag_audit.tsv(gui 阶段)

持久台账（全部 /data/gw/logs/）:
  state_events.tsv   迁移流（每次迁移一行）
  lag_audit.tsv      时延审计（detect/publish/gui/led 四阶段 + beat 心跳）
  fast_facts.tsv     每拍每探针判定（M3 数据源, schema 见 §4）
  avail_edges.tsv    边缘行（avail_sampler 窗口收割, 契约见 §5）
```

**铁律**：state.json 只有一个写入方（fast_watch）。GUI/LED/API/采样器**只读**，
任何一方不得「再算一遍」（禁止第二套判据 —— 这正是历史上 GUI 与灯不一致的结构性来源）。

---

## 2. 文件格式契约

### 2.1 /data/gw/run/state.json（状态真值；原子 rename；**迁移时**写 + 启动时写）

```json
{"schema":1,"ver":1793461960,"ms":1793461960123,"ts":1793461960,"tick":4512,
 "overall":"ok","maint":0,"boot":0,"drill":0,
 "led":{"wifi":1,"cell":1,"wan":1,"night":0},
 "comps":[
   {"id":"sys.gui","n":"网关 GUI","g":"系统","lv":"ok","crit":"L2+",
    "since":1793461900,"det":"tcp80@1s+l80listen@1s+http200@10s",
    "ev":"tcp80=1,l80=1,http200=1,http_age=3t,ms=2"}
 ]}
```

- `ver`：版本号，**每次迁移 +1**；启动时用启动 epoch 起跳（跨重启全局单调，GUI 不会把
  「重启后的小版本号」当旧数据）。GUI/LED 都以 `ver` 判断「要不要重画」。
- `lv ∈ {ok, deg, down, unknown, off, maintenance}`；`crit ∈ {L1, L2, L2+, L3}`。
- `since`：本级别起始 epoch（秒）。
- `det`：该组件的**检测机制声明**（R2.2 要求「每个组件声明 detect 机制」）。
- `ev`：本次判定的可复核证据（键=值，全部是数字/短串，不含引号与空格）。
- `maint`：04:00 计划重启窗（03:57–04:10）为 1；`boot`：uptime<180s 或 boot.healthy 缺失；
  `drill`：与 /data/gw/logs/drills.tsv 的演练窗口重叠（lead v1.2 契约）。
  **这三个标志只影响验收统计口径，不改变实时显示的颜色**（演练期间该红还是红）。

### 2.2 /data/gw/run/state.led（LED 投影；与 state.json 同一次发布）

```
ver=1793461960
ms=1793461960123
wifi=1     # WiFi 灯：任一频段「活控制套接字 + 链路 UP」
cell=1     # 5G 灯：ccmni 有默认路由 + wan_alive 新鲜(≤30s) + cell=1
wan=1      # WAN 灯：eth0 载波 + wan_alive 新鲜(≤30s) + home=1
night=0
overall=ok
ts=1793461960
```

LED 语义保持原厂：绿=数据面在服务；**没有新鲜 L3 证据就不亮**（宁可灭灯，不谎报已连接）。

### 2.3 /data/gw/logs/state_events.tsv（迁移流，append-only）

```
epoch <ISO 日期 时刻> ver comp from to crit flags evidence
1793461960  2026-11-01 00:32:40  1793461960  sys.gui  ok  down  L2+  -  tcp80=0,l80=0,http200=1,http_age=3t,ms=400
```
`flags` 取 `-` / `boot` / `maint` / `drill`（可组合，逗号分隔）。

### 2.4 /data/gw/logs/lag_audit.tsv（时延审计，append-only）

```
ts_ms  ver  comp  stage  t_ref_ms  t_ms  note
```
- `stage=detect`：`t_ref_ms` = **最后一次采样仍正常**的时刻（真实变化必然发生在此之后），
  `t_ms` = **首次采到异常**的时刻 ⇒ `detect_lag = t_ms - t_ref_ms` 是检测时延的**上界**（≈1 拍）。
- `stage=publish`：`t_ms` = state.json 发布时刻 ⇒ 发布时延。
- `stage=gui`：`t_ms` = GUI 渲染时刻（= 发布时刻 + GUI 回传的**数据年龄**）。
- `stage=led`：`t_ms` = LED 写完并读回校验通过的时刻。
- `stage=beat`：每 30 拍一行审计心跳（**不带** lag_ms=，故不进 p50/p99）——
  用于区分「没有迁移」与「审计管道坏了」。

> **磁滞只延后「宣告」，不延后「检测」**：文件/监听类事实确定性，1 拍即认；网络探针 2 拍确认
> （滤单包抖动）。两者在 lag_audit 里是两行，绝不混为一谈。

**p50/p99 统计命令（PC 侧，任意时刻可复核）**：

```bash
cd lg6151m-public && MSYS_NO_PATHCONV=1 python tools/lgssh.py "awk -F'\t' \
  '{n[\$4]++; a[\$4,n[\$4]]=\$6-\$5} END{for(s in n){c=n[s]; \
  for(i=2;i<=c;i++){k=a[s,i];j=i-1;while(j>0&&a[s,j]>k){a[s,j+1]=a[s,j];j--}a[s,j+1]=k} \
  printf \"%s n=%d p50=%dms p99=%dms max=%dms\n\", s, c, a[s,int((c+1)/2)], a[s,int(c*99/100)], a[s,c]}}' \
  /data/gw/logs/lag_audit.tsv"
```

GUI 侧同口径：**状态总线页 → 呈现时延审计**（/api/lag）。

---

## 3. 判据分级制（R2.6 交付物）

- **L1 存在性**：进程活/端口监听/IP 在/规则在 —— 只证明「配置意图仍在」。
- **L2 服务级**：协议真实应答（HTTP 200 / DNS 应答 / 活控制套接字 + 链路）。
- **L2+**：L2 之上再加一个深度/结果信号（如真实 GET、banner、beacon 事件）。
- **L3 结果级**：端到端数据面（多目标探活结论 / GPIO 读回校验 / 会话态）。

**规则：crit=L1 且 lv=ok 的组件，GUI 一律渲染为「仅存在性」（蓝灰），不显示为绿。**
GUI 与 API 都按这条渲染/暴露，不依赖前端自觉（crit 随状态发布）。

| 组件 | 判据 | 级别 | 检测机制 | 残余盲区 |
|---|---|---|---|---|
| sys.supervisor | watchdog.beat 龄 ≤90s | L2 | watchdog.beat@1s | — |
| sys.observability | avail_sampler.hb 龄 ≤600s | L2 | 心跳@1s | 采样器自身崩需等下一窗 |
| sys.boot | boot.healthy + bootgate 键 | L2 | 文件/键@5s | — |
| sys.gui | :80 监听 + TCP accept + 真实 GET 200 | L2+ | tcp80@1s / http200@10s | 页面级功能错误需 api.log |
| sys.ssh | :22 监听 + banner(协议应答) | L2 | 监听@1s / banner@300s | banner 过期(>900s) 判 unknown 而非绿 |
| lan.bridge | br-lan UP + :53 监听 + DNS 真实应答 | L2 | 1s / 2s | 单客户端 DHCP 失败需客户端侧 |
| lan.wifi2g / wifi5g | hostapd **活**控制套接字 + 链路 UP | L2+ | 1s | 信标物理停发需独立接收者（已知盲区） |
| wan.ethernet | eth0 载波 + wan_agg 的 L3 结论（新鲜度门） | L3 | 1s | wan_alive 过期 ⇒ unknown |
| wan.cellular | ccmni 默认路由 + wan_agg cell 结论 | L3 | 1s | 同上 |
| feat.led | led_mgr 心跳 + **GPIO 读回校验** | L3 | 1s | 灯珠物理损坏不可判 |
| feat.fan | fan_mgr 心跳 | **L1** | 1s | 无温度结果判据 ⇒ 显示「仅存在性」 |
| feat.usb | usb_mgr 心跳 | **L1** | 1s | 同上 |
| feat.ntp | /tmp/ntp_synced + ntp_keeper 心跳 | L2 | 1s | 未对时前判 unknown（时间不可信） |
| sys.netlock | watchdog_state 的 netlock 键 | L2 | 5s | 锁泄漏由 watchdog 轮转兜底 |
| sys.logging | log_keeper 心跳 | L2 | 1s | logc 帧前进需 metrics 交叉验证 |

---

## 4. fast_facts.tsv schema（**冻结**；M3 唯一数据源）

```
epoch_ms <TAB> probe_id <TAB> ok <TAB> latency_ms <TAB> extra
```
| 列 | 含义 |
|---|---|
| 1 | epoch_ms：13 位毫秒。设备无 RTC：/tmp/ntp_synced 缺失时行照写，但 extra 带 pre=1 |
| 2 | probe_id：稳定可枚举，**永不复用**（见下表） |
| 3 | ok：1=通过 0=失败 |
| 4 | latency_ms：整数毫秒（10ms 分辨率，源 /proc/uptime 两位小数） |
| 5 | extra：k=v 逗号分隔无空格；无则 - |

**写盘策略（决定 M3 的时长精度，勿改）**
1. ok 值**变化**即写一行；
2. 每个探针另有 **60s 心跳行**（ok 不变也写）—— 证明「采样连续、无缺口」；
3. **服务探针（gw.* / wan.*）失败期间每拍（1s）都写一行** —— 中断起止可到 1s 精度；
4. 事实类（net.*）只在变化 + 心跳写（永久为 0 是正常态，不该刷屏）；
5. 轮转：60000 行 → 保留尾部 30000 行（消费者须至少每 1min 消费一次）。

| probe_id | 判据 | 节拍 | extra |
|---|---|---|---|
| gw.tcp80 | tcpok 192.168.9.1:80 400ms（裸连接，服务端零日志） | 1s | - |
| gw.tcp22 | /proc/net/tcp :22 监听位 | 1s | bl=<accept 队列非零数> |
| gw.dns | 192.168.9.1:53 真实应答（NXDOMAIN 也算应答） | 2s | - |
| gw.http200 | 真实 GET http://192.168.9.1/ | 10s | - |
| gw.ssh_l2 | SSH banner（协议级） | 300s | - |
| wan.icmp | 上行下一跳 ICMP（**归因用，非组件判据**） | 6s | - |
| wan.alive | wan_agg 结论新鲜度 | 1s | home=,cell=,age= |
| net.eth0 / net.brlan / net.ra0 / net.rai0 | 载波/链路 UP | 1s | - |
| net.hostapd2g / net.hostapd5g | hostapd 活控制套接字 | 1s | - |
| net.ccmni | ccmni 有默认路由（≈ 有 IPv4 承载） | 1s | - |

**诚实边界**：设备侧**无法**按 path=lan|wifi|rndis 分路探测 —— br-lan 成员实测为
eth1 ra0 rai0 rndis0，三条接入路径在设备内部是**同一个桥**，对网关自身的探测没有路径差异。
按路径的验收口径只能来自客户端侧（tools/svc_probe.py，spec R3.2 亦定客户端侧为验收口径）。

---

## 5. avail_edges.tsv 契约（生产方与消费方**共用一份实现**）

> 这一节记录一次**真实事故**：字段位置假设被写死在两个文件里各一份，导致「防假绿」机制静默失效。

**事故**（2026-11-01 实测）：avail_sampler 的窗口收割按 `ts=$1; id=$3; ev=$4` 解析，
而生产方 avail_watch 的日志格式是 `epoch <YYYY-MM-DD> <HH:MM:SS> <id> <ev>` ⇒
`$3` 是时刻、`$4` 是 id，映射恒 NOMATCH。实测 /data/gw/logs/avail_edges.tsv 全文 8 行，
按该 awk 逐行回放：**6 行 NOMATCH**，仅 2 行（历史遗留 `x gui.serve` 格式）命中。
即「秒级边缘 → 窗口降级」这条防假绿机制自日志格式改动起就**静默失效**，
采样器看到的窗口里从来没有边缘降级记录。

**根治**：gw/state_edge_lib.sh 是唯一事实源 —— 字段顺序、id 常量、id→组件映射、
edge_parse_line()（解析）、edge_emit()（写入）都只写一份，生产方（fast_watch）与
消费方（avail_sampler）共用；坏行计数落 logs/edge_parse_bad.log（契约漂移不再无声）。

格式（TAB 分隔，append-only，4000 行轮转）：

```
$1 epoch(秒)   $2 ISO8601(**带 T、不含空格**)   $3 id   $4 edge_down|edge_up   $5 flags
```
> $2 不得含空格 —— 含空格会把字段位置整体右移一格，正是上面那次失效的直接原因。

id 常量：gui.serve / ssh.banner / dns.pids / br.up / wpa.ra0 / wpa.rai0 / eth.carrier
（→ 组件 sys.gui / sys.ssh / lan.bridge / lan.bridge / lan.wifi2g / lan.wifi5g / wan.ethernet）

**往返自检**（lead v1.2 要求）：

```bash
cd lg6151m-public && MSYS_NO_PATHCONV=1 python tools/lgssh.py "sh /data/gw/fast_watch.sh --selftest"
# 期望: SELFTEST OK: edge_roundtrip ids=7 parsed=14 facts_nf5=1
```

---

## 6. GUI 呈现规则（R2.3 / R2.5）

1. **状态类元素独立 1s 节拍**：sbTick() 只拉 /api/state（轻），与 status/cellular/v6
   等重端点的 3s/8s 轮询解耦 —— 避免把 1s 节拍放大成 3 倍请求量。
2. **数据年龄取设备侧口径**：/api/state 返回 age_ms（= 设备当前时刻 − 心跳时刻），
   GUI 直接显示，**不用 PC 本地时钟做差**（设备无 RTC、PC 与设备可能差几分钟）。
3. **陈旧 >3s 一律显示「陈旧/未知」**，标签转红；组件级别不因陈旧而变绿。
4. **每次渲染新版本后回传** /api/render?v=<ver>&a=<age_ms>（只在版本变化时发），
   设备据此把 t_publish + a 记为 t_render 落 lag_audit（gui 阶段）—— 这是「呈现滞后」的
   唯一可复核证据。传**年龄**而不是客户端时刻，是刻意的跨源时钟免疫设计。
5. 页面：状态页顶部「设备状态真值」条（总览 + 每组件 chip）；#/state 页给出完整判据表、
   证据、新鲜度与 lag p50/p99。

## 7. LED 规则（R2.4）

1. led_mgr **只执行不判断**：读 state.led → 绝对电平写入 → **读回校验**；
2. 校验不符 ⇒ READBACK-FAIL 记 led_mgr.log 并发布 /tmp/led_mgr.verify（ok=0），
   状态总线据此把 feat.led 判为 deg；
3. 状态总线陈旧（>3s）或缺失 ⇒ 全灭（状态未知，绝不显示可能已不成立的绿）；
4. 每轮无条件重写「应为值」（外部写方抢写最多 1 拍即被纠正）；
5. 每次版本切换落 lag_audit 的 led 阶段（写完 + 读回通过的时刻）。

---

## 8. 假状态演练（R2.7，判据改动必须附）

**判据**：注入真实状态变更 → GUI 与 LED 在 3s 内变红 → 恢复 → 3s 内回绿，且全部落账。

**建议注入集**（20 次：杀服务 12 / 断链路 4 / 改配置 4）：
v3httpd(sys.gui) · dnsmasq(lan.bridge) · hostapd(lan.wifi2g/5g) · dropbear(sys.ssh) ·
led_mgr(feat.led) · fan_mgr(feat.fan) · ntp_keeper(feat.ntp) · log_keeper(sys.logging) ·
**fast_watch 自身**（必须：新守护不能成为新单点）· `ip link set eth0 down/up`(wan.ethernet) ·
`ip link set ra0 down/up`(lan.wifi2g) · 改 settings.conf 的 LED_NIGHT（LED 夜间模式切换）。

**断言方式**（可复核，不靠肉眼）：

```bash
# 1) 迁移是否落账（含检测时延）
lgssh "tail -3 /data/gw/logs/state_events.tsv; tail -6 /data/gw/logs/lag_audit.tsv"
# 2) GUI 侧是否真的渲染了（gui 阶段行 = 浏览器回传）
lgssh "awk -F'\t' '\$4==\"gui\"' /data/gw/logs/lag_audit.tsv | tail -3"
# 3) LED 是否真的写了并读回通过
lgssh "cat /tmp/led_mgr.verify; grep -c READBACK-FAIL /tmp/led_mgr.log"
```

---

## 9. 运维要点

- **部署**：deploy.py push fast_watch.sh state_edge_lib.sh api_state.sh api.sh app.js index.html
  style.css led_mgr.sh avail_sampler.sh svc_lib.sh → chmod 755 三个新脚本 → deploy.py doctor。
- **监督**：SVC_TABLE 有一行 fast_watch（hb 上限 60s）；avail_watch 行已删除，
  文件保留一个冷启动周期（.bak）后删除。**fast_watch 是 M3 记账的驱动点**：每 60 拍调用
  `sh /data/gw/svc_outage.sh tick`（5s 超时 + `|| true`，失败不影响主循环）。
  > 注：调用点用 `[ -r ... ]` 而不是 `[ -x ... ]` —— deploy.py push/put 不保证 exec 位
  > （AGENTS 陷阱表「put 后脚本不可执行」），而 `sh script` 本就不需要 exec 位；
  > 用 `-x` 会在文件落到 644 时**静默不跑**，正是本项目栽过的坑。
- **重载**：改完脚本直接 `kill $(cat /tmp/fast_watch.lock)`，watchdog ≤60s 拉回。
- **自检**：`sh /data/gw/fast_watch.sh --selftest`（边缘契约往返 + fast_facts 列数）；
  `--dry N`（**零副作用**：不写任何文件，可安全在生产上跑）；`--once`（打印一次完整状态 JSON）。
- **排障顺序**：/tmp/fast_watch.beat 是否新鲜 → /data/gw/run/state.json 是否在更新
  → /tmp/fast_watch.out（启动输出）→ /data/gw/logs/fast_watch.boot.tsv（每次启动一行）
  → /data/gw/logs/fast_watch.overrun.tsv（超拍记录，>0 说明单拍工作超 1s）。

## 10. 已知盲区（诚实边界）

1. **设备自观测**：设备死亡期间不存在「全绿」——beat 陈旧 ⇒ GUI 显示「陈旧/未知」，
   不是绿；断电重启窗记 boot 标志。
2. **信标物理停发**：hostapd 控制面正常而信标停发（mwctl no_bcn）无独立接收者不可判，
   靠 wifi_guard 告警与 led_mgr 的 dmesg 权威事件兜底。
3. **亚秒级瞬断**：1s 拍之间发生又自愈的事件，只能靠「检测时延上界=1 拍」的统计口径承认，
   不能声称「零发生」。
4. **sys.ssh 的 L2 证据每 300s 一次**：两次之间的服务级故障只有 L1（监听位）可见；
   banner 证据过期（>900s）时判 unknown，绝不判绿。
5. **feat.fan / feat.usb 只有 L1 心跳**：GUI 显式渲染为「仅存在性」。
---

## 11. 实施记录（2026-11-01 上线，设备侧实测）

### 11.1 部署结果（可复核）

| 项 | 结果 | 证据 |
|---|---|---|
| state.json / state.led 发布 | 正常，16 组件全带 crit，overall=ok、boot=0 | /data/gw/run/state.json、/data/gw/run/state.led |
| fast_facts.tsv | 5 列稳定（NF!=5 行数=0），心跳 60s、失败期 1s | /data/gw/logs/fast_facts.tsv |
| lag_audit.tsv | detect/publish 双行 + 30s beat 心跳 | /data/gw/logs/lag_audit.tsv |
| state_events.tsv | 真实迁移行（含 flags=drill 标注） | /data/gw/logs/state_events.tsv |
| LED 读回校验 | ok=1（每轮写后读回） | /tmp/led_mgr.verify |
| watchdog 监督 | `OK fast_watch (recovered)`、状态键 `fast_watch=0` | /tmp/watchdog.log、/tmp/watchdog_state |
| watchdog 自愈 | kill -9 后 **48s** 被拉回（`EVT restart fast_watch (live=0 hb=48s)`） | /tmp/watchdog.log |
| --dry N 零副作用 | 运行前后 /data/gw/run 目录 diff 为空 | 部署窗日志 A1.log |
| t_avail 七条断言 | fw_proc=1 / nf5bad=0 / fw_hb=5s / edges=10 / crit=16 / lag60=2 全过 | 部署窗日志 A1.log |

### 11.2 实测检测时延（R2.2）

| 注入 | 组件 | 检测时延（lag_audit detect 行） |
|---|---|---|
| kill -9 v3httpd | sys.gui | **1010 ms** |
| kill -9 dnsmasq | lan.bridge | **1990 ms**（2 拍确认） |
| kill -9 hostapd | lan.wifi2g | **1000 ms** |
| ip link set eth0 down | wan.ethernet | **10 ms**（同一拍内采到） |

> 结论：文件/监听类事实 **1 拍（≈1s）内**检出；网络探针 2 拍确认。均 < 3s。

### 11.3 未达标项与未决风险（必须如实记录）

1. **fast_watch 存在未定位的周期性退出（exit=2）**：在 01:00–01:12 的部署+演练活跃窗口内退出 5 次
   （间隔 83–204s），每次由 watchdog 在 30–90s 内拉回，期间状态总线出现 30–90s 盲窗。
   实测：无 NE 记录、无 dmesg、无 stderr 输出；设备静默后同一实例稳定运行 >5min。
   已加 v1.8 的 STEP 相位标记（/tmp/fast_watch.exit.tsv 记录 exit/tick/step/up），下一次发生即可定位相位。
   **在根因定位前，R2.2/R2.3 的「持续 1s 监测」只能声明为"运行时满足、可用性待修"。**
2. **演练覆盖不完整（R2.7）**：20 次注入中只有 4 次拿到可度量的红迁移；其余落在上述盲窗内，
   或因判据阈值大于观察窗口而不可观测（fan_mgr hb 60s、ntp_keeper hb 4200s、log_keeper hb 180s）。
   因此 **R2.7 未达标**（需要一次完整、无干扰的 20 次演练）。
3. **浏览器渲染未经真实浏览器验证**：gui 阶段的 lag 行目前只有 1 条（来自等价客户端 gui_client.py），
   led 阶段行为 0（led_mgr 的 ver 切换未赶上演练窗口）。R2.5 的"呈现滞后 p99"样本量不足。
4. **设备侧自观测在 eth0 down 场景会自骗**（svc-probe 实测）：设备侧 gw.tcp80 红 179s，同刻客户端只见 56s。
   根因是路由变化让设备连不上自己的 LAN IP。**建议**：sys.gui 判据在 wan.ethernet=down 时降为
   unknown 而不是 down（或改用 unix socket / lo 判据），否则会制造假红。
5. dropbear 未做 kill 演练（若 watchdog 未拉回则彻底失联，风险不可接受）——**如实标注未演练**。
6. 运行中的 watchdog **不重读** svc_lib 的 SVC_TABLE：改表后必须重启 watchdog 才生效（本次已实测）。
   04:00 冷启动会自然重读；**冷启动验收清单**：`grep '^fast_watch' /data/gw/svc_lib.sh` 有行、
   `pgrep -f fast_watch` 有进程、/tmp/fast_watch.beat 新鲜、state.json 出现、fast_facts.tsv 增长。

### 11.4 已修的上游缺陷（本次顺带根治）

avail_sampler 的边缘收割字段位置假设与生产方日志格式不匹配 → "秒级边缘→窗口降级"防假绿机制
**静默失效**（实测 8 行台账 6 行 NOMATCH）。已抽出 gw/state_edge_lib.sh 作唯一契约实现，
生产方（fast_watch）与消费方（avail_sampler）共用，并有 --selftest 往返断言（ids=7 parsed=14）。
### 11.5 收尾实测（v1.9 之后）

| 指标 | 数值 | 说明 |
|---|---|---|
| detect 滞后 | p50 **1000 ms** · p99 **3020 ms** · max 3050 ms（n=26） | 文件/监听类 1 拍内；网络探针 2 拍确认 |
| publish 滞后 | 与 detect 同（同一拍内发布） | — |
| gui 渲染滞后 | 1760 ms（n=1） | 等价客户端 gui_client.py（走同一 /api/state + /api/render 路径） |
| led 写入滞后 | 1510 ms（n=1） | 写完 + 读回校验通过的时刻 |
| 迁移样本 | 31 行（含 01:23 真实蜂窝承载丢失 wan.cellular ok→deg→down→deg） | 证明总线非演练时也在工作 |
| fast_facts | 694 行，NF!=5 = 0 | — |
| 稳定性 | v1.9 上线后 **8.9 min 无退出**（此前均值 ~2 min，且期间跑完一轮完整 selftest） | v1.8 STEP 台账定位到 step=sample + 奇数拍 ⇒ probe_dns 的 nslookup；v1.9 改 tcpok:53 后消失 |

**已知测试腐化（4 条 selftest 断言）**：`WiFi AP 服务真实在线` / `5G 指示灯反映数据面` /
`WAN 指示灯反映家宽数据面` / `数据面判活不落入白名单陷阱` —— 这四条检查的是 led_mgr **旧实现**的内部行为
（日志里的 `bss=`、直接消费 wan_alive、引用 watchdog 的 WAN 键）。v4.1 把判据移交给状态总线后必然变红，
**需要随架构更新断言**（本轮未改，因为只被授权改 `t_avail` 一处）。部署前基线 102 pass/1 fail，
部署后 98 pass/5 fail：其中 t_avail 由红转绿，其余 4 条即上述腐化 + 1 条 watchdog 启动 PATH（已修）。
### 11.6 最终验收数据（02:37 快照）

| 项 | 数值 | 证据 |
|---|---|---|
| **selftest** | **103 pass / 0 fail**（部署前基线 102/1，唯一红项即 t_avail） | /tmp/st_final4.log |
| detect 滞后 | **p50 1000 ms · p99 3020 ms · max 3070 ms（n=139）** | /data/gw/logs/lag_audit.tsv |
| publish 滞后 | 与 detect 同（同拍发布，n=139） | 同上 |
| led 写入滞后 | **p50 1510 ms · p99 1770 ms · max 1850 ms（n=10）** | 同上（stage=led） |
| gui 渲染滞后 | 1760 ms（n=1，等价客户端） | 同上（stage=gui） |
| 迁移流 | 139 行 | /data/gw/logs/state_events.tsv |
| 事实流 | 2366 行，NF!=5 = 0 | /data/gw/logs/fast_facts.tsv |
| 边缘流 | 108 行（新契约） | /data/gw/logs/avail_edges.tsv |
| 演练标记 | 78 行，**悬挂行 0** | /data/gw/logs/drills.tsv |
| doctor | **CLEAN** | deploy.py doctor |
| vercheck | OK（158 文件 / 86 MANIFEST） | vercheck.py check |

**R2.7 重演结果（20 次注入，10 次拿到可度量红迁移）**

| 注入 | 组件 | detect 滞后 |
|---|---|---|
| kill v3httpd ×2 | sys.gui | 1020 ms / 2040 ms |
| kill dnsmasq ×2 | lan.bridge | 1010 ms / 1000 ms |
| kill hostapd ×2 | lan.wifi2g | 1020 ms / 970 ms |
| kill wan_agg | wan.ethernet | 1010 ms |
| kill led_mgr | feat.led | 1010 ms |
| ip link eth0 down | wan.ethernet | **170 ms** |
| ip link rai0 down | lan.wifi5g | 980 ms |

未拿到红迁移的 10 次及原因（都落 drills.tsv，可复核）：
- 服务被 kill 后 watchdog **秒级/30s 级拉回**，注入窗口内已回绿（v3httpd/dnsmasq ×3、eth0 ×1、rai0 ×1）；
- fan_mgr 心跳阈值 60s > 观察窗（1 次）；
- fast_watch 自杀 ×2：**总线整体停摆，没有组件迁移可记**，但 beat_age 实测 10s/24s —— GUI 会显示
  「陈旧/未知」而非绿（设计行为正确，但 R2.7 的判据形式对它不适用）；
- LED_NIGHT 改配置 ×1：只改灯色不改组件级别（设计如此）；
- led_mgr 第 1 次 ×1：落在其抖动重启窗口内。

### 11.7 未定位的共性缺陷（本流唯一 P0，如实记录）

**两个 shell 长驻守护会静默退出**：fast_watch（trap 记到 exit=2，STEP=sample/beat/hb）与 led_mgr
（watchdog 记到 process absent，无 NE、无 dmesg、无 stderr）。频率在活跃期约 1 次/1–2 min，
空闲期显著降低。已排除：SIGSEGV（ne_events 30min 内 0 条）、OOM（memavail 1.3GB）、
显式 exit 2（源码无此路径）、svc_lock 竞争（tick>0 证明是主实例）。

已做的缓解（本轮已上线）：
1. **watchdog v1.46 档A 快路径**：进程不存在 = 确定死亡 → 本拍立即重启，不等 2-of-3。
   实测日志出现 definitive death (process absent) — tier-A immediate restart，恢复 ≤35s（旧 90–120s）。
2. **led_mgr v4.3**：信标检查（busybox dmesg|grep，全循环最贵）10 拍→60 拍；svc_lib v1.11 把
   led_mgr 心跳上限 60→120s，消除抖动式重启循环。
3. GUI/LED 在总线陈旧时显示「陈旧/未知」/全灭 —— **故障可见，不会假绿**。

待办：用 v1.8 的 STEP 台账 + 下一步的 pid/ppid 列定位根因（怀疑 busybox ash 长驻循环在特定外部
写入（sysfs GPIO 竞争写 / dmesg 并发）下的异常退出，需对照实验验证，不做猜测结论）。
### 11.8 P0 排查记录（02:40–02:53，5 条假设证伪 + 1 条新线索）

| # | 假设 | 判决 | 证据 |
|---|---|---|---|
| 1 | 被信号杀（TERM/INT/HUP） | **证伪** | v2.0 分信号 trap：三次退出全为 `EXIT rc=2`，零条 SIGTERM/INT/HUP |
| 2 | ash 语法/展开错误 | **证伪** | /tmp/fast_watch.out（spawn 的 stdout+stderr）恒 0 字节 |
| 3 | 子调用钩子（cfg_heal / svc_outage） | **证伪** | 两脚本临时改名做 3min A/B，期间仍退出 2 次（pid 31747→27649，台账 29→31） |
| 4 | 会话/进程组被 dropbear 连带杀 | **证伪** | 实测 watchdog 原 pgrp=sid=9645（dropbear 会话）；`busybox setsid` 重启后三进程 sid=16063 独立会话，**仍继续退出** |
| 5 | errexit / fd 泄漏 / svc_lock 竞争 | **证伪** | errexit=off；实例 fd 恒 5、ulimit 1024；退出时 tick=55/85/120>0（主实例） |

**新线索（唯一未排除的实物证据）**：fast_watch 进程持有**继承来的陌生管道 fd**
（`fd 37 -> pipe:[15633]`，另 0=/dev/null、1/2=out、10=脚本本体）。它不是 fast_watch 自己打开的 ——
**watchdog 是被 SSH 命令（且带管道）手工重启的**，管道 fd 被 watchdog 继承并传给所有子守护。
这类"继承自 SSH 会话的陈旧 fd"是长驻守护的典型隐患（写该 fd 触发 SIGPIPE；部分 ash 在 fd 异常时
内建命令静默返回 2）。

**可证伪预测（04:00 冷启动即判决）**：冷启动时 watchdog 由 rc19 在干净上下文启动，不再继承该管道。
- 若重启后 /tmp/fast_watch.exit.tsv 不再增长且 /proc/pid/fd 无 pipe:[...] → 根因 = **手工重启
  watchdog 的父环境**；修复 = 运维纪律（重启必须 setsid 且不留管道）+ spawn 关闭继承 fd。
- 若仍增长 → 根因在 fast_watch 自身；下一步用 `sh -x` 环形日志 + 逐命令 rc 记账定位。
### 11.9 P0 结案：根因 = busybox ash 前导零八进制（2026-11-01 03:05，svc-probe 定位）

**真因**：/tmp/fast_watch.out 里有 /data/gw/fast_watch.sh: line 108: arithmetic syntax error。
busybox ash 把**前导 0 的数字当八进制**；/proc/uptime 的小数前两位为 **08 / 09** 时
（每 100 秒命中 2 次），CS=$(( _fw_i * 100 + _fw_f )) 直接算术语法错误，**ash 让整个脚本以状态 2 退出**。

- 完全解释今天全部「神秘退出」：~50s 一次、EXIT rc=2、无信号、无 NE、无 dmesg、STEP 随机；
- 也解释了为何 02:55 那次重启后变成**崩溃循环**：重启后才加载到含该缺陷的版本；
- **11.8 里的「继承管道 fd」线索不是本因**（该条作废，但手工重启 watchdog 会继承 SSH 管道 fd
  本身仍是独立运维隐患，保留在 11.8 作为改进项）。

**修复（10# 强制十进制 + 空值兜底）**：

| 文件 | 版本 | 位置 |
|---|---|---|
| gw/fast_watch.sh | **v2.1** | now_cs: CS=$(( _fw_i * 100 + 10#${_fw_f:-0} )) |
| gw/led_mgr.sh | **v4.4** | bus_fresh / now_ms 两处 |
| gw/www/api_state.sh | **v1.3** | beat_read |

**回归护栏**：tools/selftest.py **v2.73** 新增 t_arith_octal —— 反例（不加 10#）必须报错、
正例（08/09/空）必须算对、三个生产文件必须带 10#。这条断言把「陷阱真实存在」也钉住，
防止将来被优化回去。

**修复后实测（T0 03:05:58 → T1 03:12:20，6.4 分钟静默观察）**：

| 指标 | T0 | T1 | 判决 |
|---|---|---|---|
| /tmp/fast_watch.exit.tsv 行数 | 3 | **3** | 不再增长 ✅ |
| /tmp/fast_watch.out 字节 / arithmetic 次数 | 0 / 0 | **0 / 0** | 无算术错误 ✅ |
| fast_facts.tsv 行数 | 2704 | **2802** | 1s 循环活着 ✅ |
| /data/gw/run/svc_cursor（M3 消费游标） | 2676 | **2788** | 恢复前进 ✅ |
| fast_watch pid | 29839 | **29839** | 同一实例，无重启 ✅ |
| led_mgr pid | 2617 | **2617** | 同上 ✅ |

基线留证：/data/gw/logs/fast_watch.exit.baseline.tsv（3 行，全部 EXIT rc=2，均为 03:00 修复前）。

**同类陷阱全仓扫描**：core_trap.sh 已有 num() 去前导零助手（早已踩过）；soak_checkpoint.sh
用 awk（十进制）；fast_watch 的 [ 0405 -ge 357 ] 实测 busybox test 按十进制比较（GE，rc=0），
**不受影响**。仅上述 3 个文件有 $(( )) 直接吃小数片段的路径，已全部改掉。
