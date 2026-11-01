# 配置漂移自愈 (CFG HEAL) · M4 G2 闭环 · R4.1 / R3

> 生成: 2026-11-01 · owner: cfg-heal · 合同: docs/RELIABILITY_SPEC.md §M4
> 缺口来源: docs/SELF_HEALING_AUDIT.md §4 **G2**(配置类漂移无自愈) + §5.2 第 3 条
> 交付物: gw/cfg_heal.sh · tools/cfg_heal_drill.py · 本文
> 判据: **实测证据 > 设计文档 > 口头结论**(RELIABILITY_SPEC §0)

---

## 0. 一句话

守护死了有人拉; **配置被外力删了没人管**。本文补上后者: 一个只做
"发现漂移 + 调度既有施加器重建"的自愈器, 挂已有 tick, 不新增长驻守护,
**不持 netcfg 写锁**, 正常态 0 次重建, 漂移态 ≤60s 重建。

---

## 1. 缺口(为什么这是 P0)

| 注入 | 动作 | 现状后果 | 证据 |
|---|---|---|---|
| C01 | 删一条 -o ccmniN 的 NAT MASQUERADE | 蜂窝出网客户端**永久断网**, 直到人工重启 | SELF_HEALING_AUDIT §4 G2 |
| C02 | 删 mangle WANAGG 里的 MARK 打标规则 | 分流静默失效(所有新流回落 main 表), **watchdog 判绿** | 同上 |
| C03 | 删 ip rule fwmark 分流规则 | 打标流量无处可去, 分流面残缺 | 同上 |
| L01 | 把 eth1 从 br-lan 摘除 | LAN 口失联(WiFi 同理 ra0/rai0) | 同上 |

现状根因不是"没有检查", 而是**检查不等于重建**:

- watchdog.sh 的 check nat 用 iptables -t nat -S POSTROUTING | grep -q MASQ ——
  **只要还有任意一条 MASQUERADE 就判绿**。删蜂窝那条、留家宽那条 -> 假绿 + 永久断网。
- check agg_rules 用 iptables -t mangle -S WANAGG | grep -q MARK —— CONNMARK --save-mark
  里也含 MARK 子串。删掉真正的 -j MARK --set-xmark 后**仍判绿**。
- wan_agg.sh 的 NAT/FORWARD 只在**承载口发生漂移**时写(wan_agg.sh L308-313);
  mangle 链只在**状态迁移**时重建(fw_setup)。稳态下被删 = 无人重建。
- wan_eth.sh 每 5s 补的是 **eth0** 的 NAT/FORWARD; 蜂窝侧不在它的职责内。
- br-lan 成员口: rc19 只在开机建桥; usb_mgr 只管 rndis0; wifi_guard 只在确认停滞时补 rai0;
  **eth1 没有任何重建路径**。
- ip rule fwmark: 这一项 wan_agg.ensure_rules() 每环循(3s)其实已经补装 ——
  本自愈器保留检测(它覆盖"wan_agg 活着但卡住"的窗口), 但预期多数情况下由 wan_agg 先修好,
  台账会记 transient, 不会重复写。

**已有能力 vs 缺口**:

| 面 | 现有每周期重建 | 缺口 |
|---|---|---|
| eth0 NAT/FORWARD | wan_eth 5s | 无 |
| ccmni NAT/FORWARD | 仅承载口漂移时 | **稳态被删不重建** |
| mangle WANAGG | 仅状态迁移时 | **稳态被删不重建** |
| fwmark 规则 | wan_agg ensure_rules 3s | 无(本器仅兜底) |
| br-lan 成员 | rndis0 有, ra0/rai0 条件性 | **eth1 无** |
| fw_apply 纵深链 | 仅开机/api 变更 | **稳态被删不重建** |

---

## 2. 设计: 只发现 + 调度, 不另写配置

铁律(AGENTS 铁律 1 / 项目"不搞第二套判据/第二套配置"): **规则文本一律不在 cfg_heal.sh 出现**。

| 检测项 | 判据(只读) | 施加器(既有件) |
|---|---|---|
| nat:IF | iptables -t nat -S 里有 -A POSTROUTING -s LAN_NET -o IF -j MASQUERADE | sh /data/gw/wan_agg.sh --reapply |
| fwd:IF | iptables -S 里有 br-lan 与 IF 双向放行 | 同上 |
| split:wanagg | mangle WANAGG 四件齐全(链/PREROUTING 跳转/打标/存标) | 同上 |
| mark:w1 / mark:w2 | ip rule show 里有该侧 fwmark MARK/MASK lookup T | 同上(或 wan_agg 的 ensure_rules 先修) |
| br:IF | brctl show br-lan 成员里有 eth1/ra0/rai0 | brctl addif br-lan IF(仓库共用原语) |
| fw:item | V3FWD 链 / V4WANGUARDF / V3WANGUARD 跳转在 | sh /data/gw/fw_apply.sh apply |
| dnsmasq:iface | dnsmasq cmdline 含 -i br-lan | **只观测不修**(重启 dnsmasq 属 watchdog) |

期望值来源(**单一权威, 不另立判据**):

- 聚合态 = /tmp/wan_mode(agg:S1:S2, wan_agg 每环循发布) + /tmp/wan_engine(iptables|vendor);
- 常量(LAN_NET / W1_MARK / W2_MARK / W_MASK / T1 / T2)= **source** wan_agg_lib.sh;
- 新鲜度 = svc_lib.wa_age()(/tmp/wan_alive 的 hb= uptime 基, 免疫 NTP 跳变);
- 引擎闸门: 只有 ENGINE=iptables 才判 mangle —— vendor 引擎下 mangle 链**本来就不装**
  (wan_agg 只在 iptables 引擎调 fw_setup), 判它缺失就是误判 = 双引擎对打。

---

## 3. 挂载: 不新增长驻守护

**唯一宿主 = fast_watch.sh v1.5**(state-truth 已合入, commit 36f9985), 每 5 拍(5s)一次:

    if [ $(( TICK % 5 )) -eq 0 ] && [ -r "$D/cfg_heal.sh" ]; then
        "$BB" timeout -s KILL 3 sh "$D/cfg_heal.sh" --tick >/dev/null 2>&1 || true
    fi

- 用 **[ -r ] 不用 [ -x ]**(deploy.py push 不保证 exec 位 —— AGENTS 陷阱表, 已实测)。
- 硬超时 **3s**(不是我原先设想的 8s): 这是 fast_watch 的**同步调用**, 8s 会让一拍最长停 8s,
  直接违反 R2.2(状态改变→被检测到 ≤1s)。cfg_heal 因此被设计成**非阻塞**:

**时间预算(这是 v1.1 的核心改动)**:

    --tick 只做廉价检测: 6 个外部命令(实测 23ms/fork @load12 -> 约 250-350ms)
    正常态: <0.4s 退出(3s 预算的 1/8)
    疑似漂移: 写 pending 即返回(不 sleep、不修)
    确认漂移: 后台单实例 worker(--repair)接手 -> --tick 立即返回
    修复永不在 --tick 内同步执行

- 跨拍 2-of-2: 第 N 拍记疑似, 第 N+1 拍(>=4s 后)仍缺才 spawn worker。
  这样不需要在 tick 里 sleep 2s(那会吃掉 3s 预算)。
- 修复上界: 5s(首拍) + 5s(确认) + 施加器(<2s) = **约 12s**, 远在 60s 契约内。
- **watchdog 不加调用点**(Lead 01:00 裁决): 避免双调用点重复执行, 也避免与 state-truth
  抢同一个文件。fast_watch 本身由 watchdog 监督, 它死了会被拉起。

开销: 一拍 6 个外部命令(iptables -t nat -S / iptables -S / iptables -t mangle -S /
ip rule show / brctl show / ip -o -4 addr show), 之后全部在 shell 内做字符串匹配,
**不逐条 -C**。5s 一拍约 1.2 fork/s, 比现有 wan_eth(5s, 约 10 fork)更轻。

---

## 4. 锁论证(AGENTS 陷阱表: "netcfg 写锁被长持 -> 全写方超时")

历史事故形态: 长驻子进程在锁内被 spawn -> 继承 flock fd -> 锁永不释放 -> wan_agg failover /
fw_apply / ccmni_up 全部超时 -> 整机断网 9 分钟(netlock.sh v1.3 头注)。

**cfg_heal.sh 从不获取 netcfg 写锁**。逐条:

| # | 修复路径 | 锁归属 | 为什么安全 |
|---|---|---|---|
| 1 | wan_agg.sh --reapply | **施加器自己**(既有纪律) | 独立进程; 临界区 = 一批 iptables/ip 单命令, <1s; 锁内不 spawn 长驻子进程 |
| 2 | fw_apply.sh apply | **施加器自己**(fw_apply L19 netcfg_lock 5) | 同上, 且它是既有开机/API 路径, 早已被反复验证 |
| 3 | brctl addif br-lan IF | **无锁** | 与 rc19 / wifi_up / watchdog / usb_mgr 同款; 桥成员不是路由/防火墙对象 |

额外四道:

1. **让路**: 修复前读 netcfg_busy(netlock.sh 只读原语), 有人在写就跳过本轮, 下一拍重试。
   -> 不与施加器抢, 也不会让施加器在我身上等锁。
2. **硬超时**: 施加器子进程用 mto(设备无 timeout 命令, 同 ccmni_up.sh 配方)包住, 超时 kill -9。
   卡死不会滞留。
3. **第二道兜底**: 即便施加器滞留在锁内, netlock v1.5 的目录租约 **60s TTL + 持锁 pid 死亡立即回收**
   会自动收走(v1.5 起锁目录"出现即带 owner", 不再有 flock 那种 fd 继承问题)。
4. **结构保证**: 本脚本是**短命进程**(一次 tick 内跑完退出), 不 spawn 任何后台常驻件,
   因此即使它自己在锁内被杀, 也不会留下继承锁的子孙。

**结论**: 结构上不可能重现"锁被长持 -> 全写方超时"。演练时用
/tmp/netcfg_lock_timeouts 计数与 /data/gw/logs/netcfg_repairs.tsv 的时距做交叉验证(§8 D0)。

---

## 5. 不误伤(第一原则)

误判把正常配置反复重建, 比原问题更不稳定。六道闸:

1. **期望值只来自权威发布方**(§2)。本脚本没有任何"我觉得应该是什么"的判断。
2. **2-of-2 复核**: 首次检测到缺失 -> sleep 2 -> 再检一次, 两次都缺才动手。
   正常态首检即通过(**零额外开销**); 漂移态 +2s。这一条同时免疫:
   - wan_agg 迁移窗口(fw_setup 的 -D/-F/-X/-N 序列, 亚秒级);
   - agg_bypass(ENABLE=0)下 mangle 链**应该**被拆 -> 旁路态直接不判(闸门 AGG_ON);
   - vendor 引擎下 mangle 链**本来就不装** -> 引擎闸门直接不判。
3. **只增不删**: 只补缺失项, 永不 -D/-X 任何人的规则。删是施加器的事。
4. **节流**: 同类 60s 冷却 + 每类 3 次/1h 预算; 超预算只告警(escalate budget)不重建。
   宁可红, 不抖。
5. **开机 240s 内不动作**: rc19 / rc_netfh 自己会装, 抢跑 = 双写。
6. **不越界**: rndis0 一律不判(usb_mgr 按 USB_ENABLED 主动增删, 插手即对打);
   ra0/rai0 在 wifi_up.sh 运行中或 hostapd 恢复后 120s 内不判(与 wifi_guard 同款让步);
   eth0 是 WAN, **永不**加入 br-lan(白名单只允许 eth1/ra0/rai0)。

**正面证据 = --baseline**: 正常态静默观测 N 秒, 断言 drift 样本数 == 0 且
台账 repair 行增量 == 0。见 §8 D0。

---

## 6. 台账

/data/gw/logs/cfg_heal.tsv(append-only, 4000 行轮转到 2000):

    ts <TAB> kind <TAB> item <TAB> action <TAB> result <TAB> dur_ms [pre=1]

- action: observe | repair | skip(冷却/锁忙) | escalate(无施加器/预算耗尽)
- result: ok | fail | drift | cooldown | busy | no_applier | budget
- **正常态 0 行**(只在检测到漂移/观测到漂移时才写) —— 这本身就是"不误伤"的可查证据。
- pre=1 标记沿用 netlock.sh v1.1 约定(无 RTC, NTP 首同步前的 epoch 不可信)。

**并入 incidents**: 每次修复额外调 netcfg_repair "cfg_heal:KIND" RC VERIFIED,
落到既有的 /data/gw/logs/netcfg_repairs.tsv —— 这是 incident_ledger.sh 的**输入源 5**, 零耦合。
注意其分级: 单次 = netcfg_repair(SEV3), 窗口内 >10 次 = netcfg_storm(SEV2)。
若甲方要求"每一次配置重建都算 SEV2", 需 incident_ledger 侧把 cfg_heal:* 的 reason 提到 SEV2
—— 一行映射, 属 obs-ledger 的写入范围, 本文只登记需求。

---

## 7. 施加器补丁: wan_agg.sh --reapply(**已实施**)

Lead 01:00 裁决: **gw/wan_agg.sh 归本任务**(原本无主), 授权加 --reapply, 限定
"只新增 case 分支 + 必要 helper, 复用既有函数/常量, 零新增规则文本, 不改既有逻辑路径"。
实施位置: CLI case 块内, --set-primary 分支之后、esac 之前(svc_lock 之前 —— 与
--set-primary 同款, 守护在跑时也能单跑一次)。已 sh -n 通过; 幂等性由演练 D6 实测
(连跑两次, 第二次 delta = 0 行)。

    --reapply)
        # v4.0 (M4 G2 配置漂移自愈轮): 幂等重建"当前生效态"的内核装置, 供
        #   /data/gw/cfg_heal.sh 在检测到配置被外力删除(NAT MASQUERADE / mangle
        #   WANAGG MARK / fwmark / FORWARD 放行)时调用。不重启 FSM、不改状态、
        #   不写状态文件; 状态读本守护自己发布的 /tmp/wan_mode + /tmp/wan_engine。
        #   main 表主默认不在此写(主环循 main_primary_apply 每周期已复位)。
        # 退出码: 0=完成 2=状态未知(不动手) 3=锁超时
        _ss=$(cat /tmp/wan_mode 2>/dev/null)
        case "$_ss" in agg:[01]:[01]) ;; *)
            echo "reapply: wan_mode=[$_ss] unknown, skip" >&2; exit 2 ;; esac
        _s1=$(printf '%s' "$_ss" | cut -d: -f2)
        _s2=$(printf '%s' "$_ss" | cut -d: -f3)
        agg_conf_load 30
        AGG_ON=1; grep -q '^ENABLE=0' /data/gw/agg.conf 2>/dev/null && AGG_ON=0
        _eng=$(cat /tmp/wan_engine 2>/dev/null); [ -n "$_eng" ] || _eng=iptables
        netcfg_lock 5 || { echo "reapply: netcfg lock timeout" >&2; exit 3; }
        _cw=$(cell_iface_pick 2>/dev/null)
        for _if in $_cw; do
            ip route replace default dev $_if table $T1 2>/dev/null
            ip -6 route replace default dev $_if table $T1 2>/dev/null
            iptables -t nat -C POSTROUTING -s $LAN_NET -o $_if -j MASQUERADE 2>/dev/null || \
                iptables -t nat -A POSTROUTING -s $LAN_NET -o $_if -j MASQUERADE
            iptables -C FORWARD -i br-lan -o $_if -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -i br-lan -o $_if -j ACCEPT
            iptables -C FORWARD -i $_if -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || \
                iptables -I FORWARD -i $_if -o br-lan -m state --state ESTABLISHED,RELATED -j ACCEPT
            log "REAPPLY cell if=$_if (nat+fwd ensured)"
        done
        if [ "$AGG_ON" = 1 ]; then
            if [ "$_eng" = iptables ]; then
                if [ "$_s1" = 1 ] && [ "$_s2" = 1 ]; then fw_setup $W2_PCT
                elif [ "$_s2" = 0 ]; then fw_setup 0
                else fw_setup 100; fi
            fi
            if [ "$_s1" = 1 ] && [ "$_s2" = 1 ]; then fw6_setup 1
            elif [ "$_s2" = 0 ]; then fw6_setup 0
            else fw6_setup_alive2; fi
            S1=$_s1; S2=$_s2; ensure_rules
        fi
        netcfg_unlock
        echo "reapply: ok s=$_s1/$_s2 eng=$_eng if=[$_cw]"
        exit 0 ;;

**补丁 A 缺失时 cfg_heal 的行为**(已实现, 不会半吊子): 检测到聚合/NAT 类漂移 ->
台账 action=escalate result=no_applier + netcfg_repair 落 incidents + /tmp/cfg_heal.log 记 FAIL,
**不重建**。即"宁可红, 不自己拼 iptables"。br-lan 与 fw_apply 两类**不依赖补丁 A**, 立即可用。

### 原补丁 B/C 已作废

- watchdog.sh 调用点: **取消**(Lead 01:00 裁决 + state-truth 已在 fast_watch v1.5 合入,
  双调用点会重复执行并与 state-truth 抢同一个文件)。
- fast_watch.sh 调用点: 已由 state-truth 合入(commit 36f9985), 见 §3, 本文不再重复。

---

## 8. 演练方案(判据类改动必须实弹; 无演练 = 未完成)

装置: tools/cfg_heal_drill.py(PC 侧, 强制检查 device_lock owner)。

    python tools/cfg_heal_drill.py plan        # 计划(不连设备)
    python tools/cfg_heal_drill.py status      # 设备侧 cfg_heal 现状 + 客户端探针
    python tools/cfg_heal_drill.py baseline --secs 120
    python tools/cfg_heal_drill.py case D4_bridge_eth1
    python tools/cfg_heal_drill.py all --secs 60

每个用例的固定流程(**注入前先断言配置本来是好的**, 否则测的是别的东西):

    precheck(配置正确) -> [arm deadman] -> inject(t0) -> 1s 轮询 check -> 重建时刻 t1
    -> 客户端探针(TCP22/TCP80/DNS) -> 读台账 -> 断言 latency<=60s -> 证据落 tsv

| # | 用例 | 注入 | 期望 | 客户端影响 |
|---|---|---|---|---|
| D0 | baseline | 无 | **0 次重建**, 0 drift 样本(**30min 版**) | 无 |
| D1 | D1_nat_ccmni | 删蜂窝口 MASQUERADE | ≤60s 规则回来(--reapply) | 蜂窝为主路时才断网 |
| D2 | D2_mangle_mark | 删 WANAGG 的 -j MARK | ≤60s 四件齐全(--reapply) | 分流失效, 连通性不受影响 |
| D3 | D3_fwmark_rule | 删当前活侧 fwmark 规则 | ≤60s 回来(**预期 wan_agg 3s 先修** -> 台账记 delegated) | 部分 |
| D4 | D4_bridge_eth1 | brctl delif br-lan eth1 | ≤60s 回来 **且客户端三探针恢复** | **PC 就在 eth1 -> SSH 会断** |
| D5 | D5_fw_guard | 删 V4WANGUARDF 跳转 | ≤60s 回来(fw_apply) | 无 |
| D6 | D6_reapply_idempotent | 连跑两次 wan_agg --reapply | 第二次 delta = **0 行**(幂等硬要求) | 无 |
| D7 | D7_stale_source_negative | /tmp/wan_mode 改陈旧 + 删 MARK | **20s 内必须不动手**; 恢复来源后 ≤60s 修好 | 分流失效但不乱修 |
| D8 | D8_bridge_ra0 | brctl delif br-lan ra0 | ≤60s 加回(v1.3 修盲区后实测 **8.5s**) | WiFi 客户端失 L2 归属, PC 走 eth1 不受影响 |

> **v1.3 修的盲区(L01 复现, 2026-11-01 11:39)**: soak-qa 的 batchB 注入"摘 ra0"**301s 未自愈**,
> 而我的 D4"摘 eth1"16s 就修好 —— 差异不在成员表(eth1/ra0/rai0 都在期望表里), 而在**两道让步闸门**:
>
> | 闸门 | 实际行为 | 后果 |
> |---|---|---|
> | ② "hostapd 恢复后 120s 内不判", 用 `stat -c %Y /tmp/watchdog.log` 取 mtime | 本机**没有 stat**(实测 `/bin/stat`、`/usr/bin/stat` 均不存在, PATH 里也没有) -> `_ml` 恒为 0 -> 该闸门**从未生效**; 即便生效也是错的: watchdog.log 每 30s 写 TICK, mtime **永远新鲜** = 永久抑制 | 死代码 + 设计错误 |
> | ① `pgrep -f 'wifi_up[.]sh'` 全命令行**子串**匹配 | 实测: 只要有任何进程的 cmdline **提到** `wifi_up.sh`(演练 harness、包装脚本、甚至探针命令自己), 整个期间抑制 ra0/rai0 判定 | **这才是 301s 的机制** |
>
> **修法(v1.3)**: 拆掉①②, 只保留一个精确廉价的让步 —— **我方 hostapd 不在**(重启窗口)时不判,
> 由 watchdog 的恢复路径自己 `brctl addif`; hostapd 活着时桥成员缺了就补。
> 依据: 只增不删 + `brctl addif` 幂等 + 跨拍 2-of-2 已过滤亚秒级抖动 —— 让步的收益(少一行日志)
> 远小于代价(301s 盲区)。
>
> **对验收口径的含义**: v1.2 及以前, ra0/rai0 的检测时延**无上界**(闸门关闭期间完全不评估);
> v1.3 起检测上界 = tick 周期 5s + 跨拍确认 ≥4s + worker ≤1s ≈ **≤10s**, 实测 8.5s。
> 这条又是 §10 定律二的现场实例: **子串匹配会被"提及者"骗**, `pgrep -f` 是本项目的高危原语。

**反例(D7)是本演练的重点之一**(Lead 明确要求): 自愈器的期望值来源被破坏时必须
"宁可不修", 而不是拿陈旧状态去乱装 —— 那会比原问题更糟。D7 同时验证正反两面。

**安全网(每个用例独立, 自愈器失效也不会把设备留在坏态)**:

- 通用: 用例失败时执行 restore 命令并复核;
- **D4 额外**: 注入前在设备上 arm 一个 100s 的 deadman
  (nohup sh -c "sleep 100; brctl addif br-lan eth1" &), 即使自愈器完全失效, LAN 口 100s 后
  也一定回来 —— 不会把设备锁死到只能重启。演练测的是"自愈器是否在 60s 内先修好"。

**离线判据验证(不连设备, 用真实快照回放)**: tools/oneoff/cfg_heal_offline_verify.sh

    把设备上的 iptables -S / -t nat -S / -t mangle -S / ip rule / brctl show 抓成快照,
    用 stub 命令回放给**真实脚本**跑 --json, 证明: 正常态 0 漂移; 删任一项必被检出;
    期望值来源陈旧 / vendor 引擎 时**不判**(负向)。

实测结果(2026-11-01, 真实设备快照): failures=0 ——
正常态 0 漂移 / 删 ccmni NAT 检出 nat:ccmni2 / 删 MARK 检出 split:wanagg /
删 fwmark 检出 mark:w2 / wan_mode 陈旧时 split+mark **不判** / vendor 引擎下 split **不判**。
(br:eth1 与 fw 两项的判据含 [ -d /sys/class/net/... ], PC 无 /sys, 由实机 D4/D5 覆盖。)

**首轮实弹结果(2026-11-01 00:50-01:00, 设备侧, 窗口外空档)**:

| 用例 | 结果 | 证据 |
|---|---|---|
| 正常态 | **--check => OK drift=0 rc=0**; tick 耗时 **140/200/140 ms** | 设备侧命令输出; 3s 预算的 15 倍余量 |
| D6 幂等 | run1 delta vs before = **0 行**; run2 delta vs run1 = **0 行** => PASS | _local/evidence/cfg_heal/20261101-005028_drill.tsv |
| D1 NAT(C01) | 删 ccmni2 MASQUERADE -> 检出 DRIFT nat ccmni2 rc=1 -> 修复 -> 规则回来 -> OK rc=0 | 台账 agg/wan_agg/repair/ok/50; netcfg_repairs cfg_heal:agg rc=0 verified=ok |
| D5 fw 纵深 | 删 V4WANGUARDF 两条跳转 -> 检出 2 条 -> fw_apply 修复 -> OK rc=0 | 台账 fw/fw_apply/repair/ok/50 |
| D2 mangle(C02) | **首轮假绿**, 修判据后: 检出 DRIFT split wanagg -> 修复 -> 链恢复三件 -> OK rc=0 | 台账 agg/wan_agg/repair/ok/50 |
| 锁 | 全程 /tmp/netcfg_lock_timeouts = **0**, netcfg.log 无 WARN | 修复耗时 50ms; cfg_heal 不持锁 |

**第二轮实弹(02:02-02:07, 正式窗口, 生产 tick 路径)**:

| 用例 | 结果 | 证据 |
|---|---|---|
| D1 NAT(**async tick**) | 注入 -> **11.1s** 重建 -> 客户端 tcp22/80/dns 全 1 | 台账 agg/wan_agg/repair/ok/**330** |
| D4 br-lan eth1(L01) | 注入 -> **16.0s** 重建 -> 客户端三探针恢复 | 台账 br/bridge/repair/ok/20; drills.tsv 已标窗口 |
| D7 反例(负向) | /tmp/wan_mode 置陈旧 + 真删 MARK -> **20s 内不动手** | 台账只记 observe/suspect, 无 repair 行 |
| D7 反例(正向) | 恢复来源后自动修复: **修 bug 前未通过**; 修后未单独重跑 | 同一机制已由 D1/D4 的 async 路径实测通过 |
| D0 baseline(30min) #1 | 346 采样, drift_samples=0, 台账 0 新增, repairs 0 新增 | _local/evidence/cfg_heal/20261101-013506_drill.tsv |
| D0 baseline(30min) #2 | 同上(346 采样, 0 漂移, 0 重建) —— **跑在 state-truth 的 R2.7 20 次注入窗口内** | _local/evidence/cfg_heal/20261101-023543_drill.tsv |

> **一次被推翻的结论(留档, 不删)**: 我曾在报告里把 san_up() 定性为"冷启动杀手修复", 依据是
> `gw/rc.extend.sh` 第 88 行注释 "v2.0(P2/L-7): ... /tmp is not tmpfs"。Lead 实测推翻:
> `mount` = `tmpfs on /tmp type tmpfs`, `/tmp` 最老文件 = 本次 boot 时刻, `find` 零结果;
> `AGENTS.md` 陷阱表也写的是 "/tmp 文件消失 | tmpfs 重启即清"。**结论: rc.extend.sh 第 88 行注释
> 与实测不符(疑似早期配置遗留), 我引用它而未自己验证 —— 这是反猜测方法论的反面教材。**
> san_up() 代码保留(无害且覆盖 uptime 回绕等情形), 但定性改为"防御性加固"。
>
> **D0 #2 的意义**: 第二段 30min baseline 与 state-truth 的 20 次故障注入(R2.7)重叠。
> 也就是说: 设备在被人反复杀服务/断链路的时候, 本自愈器**一次误判都没有**
> (346 采样 0 漂移、台账 0 新增)。这是"不误伤"最强的形态 —— 不是空闲时安静, 而是噪声中不误动。

> **第二个真 bug(重要)**: 跨拍 2-of-2 确认**永不成立** —— DET 首元素带前导空格, 而 pending 用
> `read _pu _pd` 读回时 IFS 会折叠连续空白, 两者永不相等 -> 只反复记 SUSPECT 不修复。
> 修法: detect() 末尾归一(去掉前导空格)。教训: **跨进程传递的字符串必须归一**。
>
> **D2 抓出的真 bug(重要)**: v1.0 用整表 `iptables -t mangle -S` 文本查打标, 而本机 mangle 表里
> 有厂商 QoS 链(qos_Default / qos_Default_ct)满载 `--set-xmark` 与 `CONNMARK --save-mark` ——
> 删掉 WANAGG 的打标后**仍判绿**, 与 watchdog 的 `grep -q MARK` 是同一类错误。
> v1.1 起: 打标/存标/链存在性只看 **WANAGG 链内**文本(`-S WANAGG`), 跳转才看整表。
> 教训: **检测判据必须作用域最小化**; 整表/全局 grep 一定会被无关对象骗。

**验收断言**:

1. D0: drift_samples == 0 且 repairs 增量 == 0 -> 证明不误伤;
2. D1/D2/D3/D4/D5: latency_s <= 60;
3. D4: conn = tcp22=1 tcp80=1 dns=1(客户端侧连通性恢复, 与 R3.1 口径一致);
4. 台账有对应 repair/escalate 行, 且 netcfg_repairs.tsv 有 cfg_heal:* 行(并入 incidents);
5. 全程 /tmp/netcfg_lock_timeouts 无新增(锁论证的现场反证)。

证据: _local/evidence/cfg_heal/<ts>_drill.tsv(列: case / t0 / t_repaired / latency_s /
passed / conn / ledger / note)。

---

## 9. 未决风险

| # | 风险 | 现状 | 处置 |
|---|---|---|---|
| 1 | wan_agg --reapply 的幂等性只在演练 D6 验证一次 | 已实施(Lead 授权 A 项) | D6 断言"第二次 delta=0 行"; 后续若有 wan_agg 改动需重跑 |
| 2 | tick 被 fast_watch 3s 硬超时打断 | 正常态 <0.4s; 修复已移出 tick(后台 worker) | 若出现 tick 超时, 现象是 pending 不推进(不修也不坏) |
| 3 | incidents 里单次修复是 SEV3 而非合同要求的 SEV2 | incident_ledger 既有映射 | 需求登记给 obs-ledger(一行 reason 映射) |
| 4 | vendor 引擎(内核模块分流)下 mangle 面不适用 | 已加引擎闸门, 不判 | 引擎切换时本器自动跟随 /tmp/wan_engine |
| 5 | 承载口在 --reapply 期间刚好漂移 -> 可能短暂双写 | 两者都持同一把 netcfg 锁, 串行 | 观测; 若出现则让 --reapply 复用主环循的 W1_IF 缓存 |
| 6 | 后台 worker 是短命进程, 但若施加器卡死它最长占 8s(硬超时) | mto 兜底 + netlock 60s TTL | 有界; 不新增长驻进程 |
| 7 | 演练窗口只有 15min(排队), 30min baseline 需跨窗 | 两段各 30min 均 PASS | baseline 只读, 可跨窗; 注入类必须持锁 |
| 8 | ~~重启后 /tmp 残值致自愈器静默瘫掉~~ —— **前提不成立, 已更正**: 实测 `mount` 显示 `tmpfs on /tmp`, `ls -lat /tmp` 最老文件 = 本次开机时刻, **/tmp 重启即清** | san_up() 归一**保留但降级为"防御性加固"**(理由: uptime 回绕 / 未来若改持久挂载 / 多实例怪值), 不是修 bug | 不再作为验收依据; 引用出处见下 |
| 9 | 一次锁纪律违规: acquire 返回 BUSY 时 push 仍执行(在他人锁窗口内写了 15s 的一个文件) | 已向 Lead/state-truth 报告并认领 | 流程改正: acquire 与后续写操作串成一条命令并检查退出码 |

---

## 10. 判据纪律: 进程/角色判活的三条定律(通用, 不限本模块)

> 本节由 2026-11-01 一天内**三个流各自撞到的同族缺陷**归纳而来。它们不是三个孤立 bug,
> 是同一类判据写法必然产生的三类错误。**写任何"判活/判据"之前先读这一节。**
> (Lead 2026-11-01 裁定落成文档; svc-probe 把三条陷阱做成 `svc_lib_selftest` 的永久回归。)

### 10.1 三个实证案例(同一天, 不同流)

| # | 位置 | 写法 | 后果(实弹) | 修法 |
|---|---|---|---|---|
| ① | `svc_lib.alive()` 回退分支 | `pgrep -f "/data/gw/<x>"` —— 全命令行**子串**匹配 | 注入 harness 的 rollback 配方里提到 `ntp_keeper.sh` 路径, 真进程已死 **153s**, watchdog 仍连报 `ntp_keeper=0`(假活) | svc_lib v1.10: argv **token 精确**匹配 + 锚定正则; `sh -c` / `grep` / `tail -f` 提及一律不算 |
| ② | selftest 某条断言 | 测试命令自己的 cmdline 含被查字符串 | 测试**自己把自己判活**, 断言恒真 | 判据必须排除自身 pid 与祖先进程 |
| ③ | `cfg_heal` dnsmasq 观测 | `pidof dnsmasq \| cut -d' ' -f1` —— 只取**第一个** pid | 多实例窗口(厂商 DNS-only 实例 + 我方 DHCP 实例并存)取到前者 -> 误报"dnsmasq 没在服务 br-lan"(2026-11-01 08:43 / 09:25 各一条假观测) | cfg_heal v1.2: 扫**全量** pid, 任一实例命中即算活 |

### 10.2 三条定律

**定律一 · 集合 vs 单点**
一个"角色"常有**多个实例**: dnsmasq(厂商 DNS-only + 我方 DHCP)、hostapd(厂商 global + 我方 AP)、
dropbear(每个 SSH 会话一个)、ccmni(多 PDN 并存, 还有僵尸口)。
只取第一个 / 只判一个 -> 必然在某些窗口判错。
**判据必须扫全量集合, 并把语义写清楚: "任一命中即活" 还是 "全部命中才算活"。**

**定律二 · 子串 vs 精确**
进程名/命令行**子串**匹配会被"提及者"骗: 注入脚本、`grep`、`tail -f`、`sh -c` 包装、测试自身。
本项目的守护都是 `sh /data/gw/<x>.sh` 形态, 这条路径会出现在无数无关 cmdline 里。
**判据必须做 argv token 精确比较(或锚定正则), 只认"argv 里真的以该脚本为执行体"的进程。**

**定律三 · 观测者污染**
判据自己也会出现在被观测的集合里(selftest 自匹配、`grep` 自己的命令行、包装脚本、注入 harness)。
**必须显式排除自身 pid 与祖先进程链。**

### 10.3 落地契约(建议进 svc_lib)

    is_alive(role) 不返回布尔, 返回**命中集合**(便于日志定位与"为什么判活"的可审计性);
    内部强制: 全量扫描 + argv token 精确 + 排除自身/祖先;
    判据失败时把"扫到的候选 + 每个候选被排除的理由"写进日志, 而不是只写一个 FAIL。

**自检方法(建议做成永久回归)**: 构造 3 个陷阱进程, 断言判据全部判"死" ——
① **名字像**: argv 里含目标脚本路径, 但执行体是别的东西(`sh -c "... /data/gw/x.sh ..."`);
② **路径像**: 工作目录或参数里含目标路径(`tail -f /data/gw/x.log`);
③ **自己是 grep**: 判据命令自身出现在 ps 输出里(`grep pgrep -f x`)。

### 10.4 与本模块的关系(自查结论)

`cfg_heal` 的主判据是 **netlink/iptables/brctl 的内核对象**(不是进程), 天然免疫前两条。
它的进程类判据只有三处, 已按三条定律逐一复核:
- `pgrep -f 'wifi_up[.]sh'` —— 带 `[.]` 自排除, 已是精确形态(且只用于"让步/延后判", 不用于修复决策);
- `pidof dnsmasq` —— 案例③, 已修为全量扫描(v1.2);
- `wan_reapply_ok()` —— 读**文件内容**判能力, 不是进程判活, 无此风险。

**另一个同族提醒**: 判据的**作用域**也要最小化 —— 本模块 bug#1(split_ok 用整表 mangle 文本查打标,
被厂商 QoS 链的 `--set-xmark` 骗成绿)与 ①②③ 是同一个病根: **用了一个比目标更大的集合**。
把 ①②③ 概括成一句: **判据的集合必须恰好等于被判定对象的集合 —— 不多(骗自己)也不少(漏判)。**

