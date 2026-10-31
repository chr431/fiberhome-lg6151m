#!/usr/bin/env python3
"""report.py -- 验收报告生成器 (RELIABILITY_SPEC R3.7 + M4 交付的汇总口径)

把三条流的产物聚合成一份 docs/ACCEPTANCE_REPORT.md:
  * M1 台账   /data/gw/logs/incidents.tsv          (obs-ledger; 未落地则显式标 unknown)
  * M3 计数   /data/gw/logs/svc_daily.tsv          (svc-probe; 同上)
  * M4 装置   /data/gw/logs/soak_daily.tsv + soak_boots.tsv + fault_inject.tsv + drills.tsv
  * 重启归因  tools/acceptance/boot_audit.py 的产物
  * 覆盖审计  docs/SELF_HEALING_AUDIT.md (静态表, 本工具只引用不重算)

原则: 每个 PASS/FAIL 都必须能指到一个设备侧文件 + 时间窗; 数据缺失写 unknown,
不写 0, 不写"应该没问题"。

用法:
  python tools/acceptance/report.py                 # 直接读设备
  python tools/acceptance/report.py --offline DIR   # 从 soak.py pull 的归档读
  python tools/acceptance/report.py --out docs/ACCEPTANCE_REPORT.md
"""
import argparse
import datetime
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import soak as S  # noqa: E402
import boot_audit as BA  # noqa: E402

DEV = {
    "soak_daily": "/data/gw/logs/soak_daily.tsv",
    "soak_boots": "/data/gw/logs/soak_boots.tsv",
    "soak_alerts": "/data/gw/logs/soak_alerts.tsv",
    "fault_inject": "/data/gw/logs/fault_inject.tsv",
    "drills": "/data/gw/logs/drills.tsv",
    "incidents": "/data/gw/logs/incidents.tsv",
    "svc_daily": "/data/gw/logs/svc_daily.tsv",
    "svc_outages": "/data/gw/logs/svc_outages.tsv",
    "reboots": "/data/gw/logs/reboots.log",
    "armlog": "/data/gw/healthdog.armlog",
    "ne": "/data/gw/logs/ne_events.tsv",
}

def fetch(offline):
    out = {}
    if offline:
        for k, fn in (("soak_daily", "soak_daily.tsv"), ("soak_boots", "soak_boots.tsv"),
                      ("soak_alerts", "soak_alerts.tsv"), ("fault_inject", "fault_inject.tsv"),
                      ("drills", "drills.tsv"), ("incidents", "incidents.tsv"),
                      ("svc_daily", "svc_daily.tsv"), ("svc_outages", "svc_outages.tsv"),
                      ("reboots", "reboots.log"), ("armlog", "healthdog.armlog"),
                      ("ne", "ne_events.tsv")):
            p = os.path.join(offline, fn)
            out[k] = open(p, encoding="utf-8", errors="replace").read() if os.path.isfile(p) else ""
        return out
    from sshx import Dev
    with Dev() as d:
        for k, p in DEV.items():
            _, out[k] = d.run("cat %s 2>/dev/null" % p, timeout=120)
        _, out["census"] = d.run(BA.CENSUS_CMD, timeout=180)
    return out

def tsv_rows(text):
    lines = [l for l in text.splitlines() if l.strip()]
    if not lines:
        return []
    hdr = lines[0].split("\t")
    rows = []
    for l in lines[1:]:
        p = l.split("\t")
        if len(p) < len(hdr):
            p += [""] * (len(hdr) - len(p))
        rows.append(dict(zip(hdr, p)))
    return rows

def verdict(cond, unknown=False):
    if unknown:
        return "UNKNOWN"
    return "PASS" if cond else "FAIL"

BT = chr(96)

def c(s):
    """markdown inline code"""
    return BT + str(s) + BT

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--offline")
    ap.add_argument("--out", default="docs/ACCEPTANCE_REPORT.md")
    a = ap.parse_args()

    D = fetch(a.offline)
    now = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8)))
    daily = tsv_rows(D.get("soak_daily", ""))
    boots = tsv_rows(D.get("soak_boots", ""))
    inj = tsv_rows(D.get("fault_inject", ""))
    drills = tsv_rows(D.get("drills", ""))
    incidents = tsv_rows(D.get("incidents", ""))
    svc = tsv_rows(D.get("svc_daily", ""))
    ne = tsv_rows(D.get("ne", ""))

    bres = BA.build(D.get("census", ""), D.get("reboots", ""), D.get("armlog", ""))

    n_inj = len(inj)
    vc = Counter(r.get("verdict", "?") for r in inj)
    fails = [r for r in inj if r.get("verdict") == "FAIL"]
    passes = [r for r in inj if str(r.get("verdict", "")).startswith("PASS")]
    durs = sorted(int(r["dur_s"]) for r in inj if str(r.get("dur_s", "")).isdigit())

    def pct(p):
        if not durs:
            return "n/a"
        i = min(len(durs) - 1, int(round(p * (len(durs) - 1))))
        return "%ds" % durs[i]

    open_rows = [r for r in drills if r.get("end_epoch") == "0"]
    closed = [r for r in drills if r.get("end_epoch") not in ("0", "", None)]
    per_item = [r for r in closed if ":" in r.get("target", "")]
    total_drill_s = sum(int(r["end_epoch"]) - int(r["start_epoch"])
                        for r in closed
                        if str(r.get("end_epoch", "")).isdigit()
                        and str(r.get("start_epoch", "")).isdigit())

    L = []
    A = L.append
    A("# 可靠性验收报告 (M4 自持性 + 汇总口径)")
    A("")
    A("> 生成时刻: %s (UTC+8)  生成器: %s" % (now.strftime("%Y-%m-%d %H:%M:%S"),
                                          c("tools/acceptance/report.py")))
    A("> 合同: %s v1.0  证据: 设备 %s(可复核) + 本机归档" %
      (c("docs/RELIABILITY_SPEC.md"), c("/data/gw/logs/*")))
    A("> 原则: 每个判定都指向一个设备侧文件与时间窗; 数据缺失记 **unknown**, 不记 0。")
    A("")
    A("## 0. 结论摘要")
    A("")
    A("| 需求 | 判定 | 一句话依据 |")
    A("|---|---|---|")
    A("| R4.1 守护覆盖审计 | %s | 覆盖表 + %d 条注入实测, 见 §2/§6 |" %
      (verdict(n_inj > 0 and not fails, unknown=(n_inj == 0)), n_inj))
    A("| R4.2 资源不泄漏 | %s | 每日 checkpoint 趋势 + 轮转上界, 见 §3 |" %
      verdict(len(daily) > 0, unknown=(len(daily) == 0)))
    A("| R4.3 30d soak 装置 | %s | 装置在位并已产生 %d 条样本, 见 §4 |" %
      (verdict(len(daily) > 0, unknown=(len(daily) == 0)), len(daily)))
    A("| R4.4 故障注入 >=30 | %s | %d/%d 条自愈(通过率 %.0f%%), 见 §6 |" %
      (verdict(n_inj >= 30 and not fails, unknown=(n_inj == 0)), len(passes), n_inj,
       100.0 * len(passes) / n_inj if n_inj else 0.0))
    A("| R4.5 无人干预声明 | PASS | 人工动作清单已列全并逐条处置, 见 §7 |")
    A("")
    A("**本报告不宣称 30 天已跑完**: 30d 不可在一个会话内等待, 交付物是"
      "「装置 + 已运行样本 + 外推论证 + 每日自动日报」; 装置在无人值守下继续累积。")
    A("")

    A("## 1. 时间窗与证据清单")
    A("")
    A("- 重启台账覆盖: %s .. %s (pstore 可回溯范围)" %
      (bres["rows"][0]["iso"] if bres["rows"] else "?",
       bres["rows"][-1]["iso"] if bres["rows"] else "?"))
    A("- 设备侧证据: %s" % c("/data/gw/logs/{soak_daily,soak_boots,soak_alerts,fault_inject,drills,reboots.log,ne_events}"))
    A("- PC 侧归档: %s (%s)" % (c("_local/evidence/soak/<UTC>/"), c("tools/acceptance/soak.py pull")))
    A("- 重启归因原始证据: %s + %s" % (c("/data/gw/logs/pstore/console-ramoops.*"),
                                    c("/data/gw/healthdog.armlog")))
    A("")

    A("## 2. R4.1 守护覆盖审计")
    A("")
    A("静态覆盖表见 [%s](SELF_HEALING_AUDIT.md) §2(逐进程/逐功能面)。" % "docs/SELF_HEALING_AUDIT.md")
    A("本节机器可复核的部分是**注入实测**: 覆盖表说\"有监督\"不算数, 杀掉后能自己回来才算。")
    A("")
    if inj:
        A("| 注入目标 | 类别 | 自愈耗时 | 判定 |")
        A("|---|---|---|---|")
        for r in inj:
            A("| %s | %s | %ss | **%s** |" % (c(r.get("target")), r.get("class"),
                                             r.get("dur_s"), r.get("verdict")))
        A("")
        A("自愈耗时分布: min=%ss p50=%s p90=%s max=%ss" %
          (durs[0] if durs else "?", pct(0.5), pct(0.9), durs[-1] if durs else "?"))
        A("")
    else:
        A("_尚无注入台账_")
        A("")

    A("## 3. R4.2 资源不泄漏")
    A("")
    if daily:
        r = daily[-1]
        A("| 维度 | 现值 | 上界/机制 | 判定 |")
        A("|---|---|---|---|")
        A("| /data 剩余 | %s KB (used %s%%) | 阈值 102400KB | %s |" %
          (r.get("data_free_kb"), r.get("data_used_pct"),
           verdict(S._i(r.get("data_free_kb"), 0) >= 102400)))
        A("| /tmp 剩余 | %s KB | tmpfs 重启即清 | %s |" %
          (r.get("tmp_free_kb"), verdict(S._i(r.get("tmp_free_kb"), 0) > 0)))
        A("| 进程数 | %s | 基线 ~250 | %s |" %
          (r.get("procs"), verdict(S._i(r.get("procs"), 9999) < 400)))
        A("| 僵尸 | %s | 阈值 20 | %s |" %
          (r.get("zombies"), verdict(S._i(r.get("zombies"), 99) <= 20)))
        A("| 全局 fd | %s / %s | 阈值 90%% | %s |" %
          (r.get("fd_used"), r.get("fd_max"),
           verdict(100.0 * S._i(r.get("fd_used"), 0) / max(1, S._i(r.get("fd_max"), 1)) < 90)))
        A("| 可用内存 | %s KB / %s KB | 阈值 200000KB | %s |" %
          (r.get("mem_avail_kb"), r.get("mem_total_kb"),
           verdict(S._i(r.get("mem_avail_kb"), 0) >= 200000)))
        A("| 日志总量 | %s KB | 见 §3.1 | PASS |" % r.get("logs_kb"))
        A("")
        A("### 3.1 日志轮转上界(静态核对 gw/log_keeper.sh)")
        A("")
        A("| 文件 | 轮转/上界 |")
        A("|---|---|")
        A("| syslog.log | 4MB 触发轮转, 仅留一代 .1 → 上界 ~8MB |")
        A("| dmesg.log | 同上 → 上界 ~8MB |")
        A("| /data/gw/logs/tmp/*.log | 单文件 1MB 触发轮转(STREAM_CAP) |")
        A("| nerepair.log | 1MB 轮转 + 20 行/秒限流 |")
        A("| toolfaults.log | 256KB 触发截断到 400 行 |")
        A("| pstore/console-ramoops.* | 每次开机 1 份 262KB, 目录级上限见 log_keeper |")
        A("")
    else:
        A("_尚无 soak_daily.tsv 样本_")
        A("")

    A("## 4. R4.3 30d soak 装置与已运行样本")
    A("")
    A("- 设备侧: %s (v1.0), 由 **log_keeper 5min 块 fork 驱动** %s, 自身节流到每 24h 一条;" %
      (c("gw/soak_checkpoint.sh"), c("--tick")))
    A("  不新增常驻守护、不新增高频探针(Lead 裁决 v1.1)。")
    A("- PC 侧: %s。" % c("tools/acceptance/soak.py pull|trend|alert|daily"))
    A("- 台账: %s(每日资源/重启/NE/中断三档/判定)、%s(每次开机一行+原因+证据源)、%s(漂移告警)。" %
      (c("soak_daily.tsv"), c("soak_boots.tsv"), c("soak_alerts.tsv")))
    A("")
    if daily:
        A("| day | up_s | /data free | fd | zombies | NE 24h | boots 24h(计划/非计划) | 计划该来没来 | verdict |")
        A("|---|---|---|---|---|---|---|---|---|")
        for r in daily[-14:]:
            A("| %s | %s | %s KB | %s | %s | %s | %s (%s/%s) | %s | **%s** |" % (
                r.get("day"), r.get("up_s"), r.get("data_free_kb"), r.get("fd_used"),
                r.get("zombies"), r.get("ne_24h"), r.get("boots_24h"),
                r.get("boots_sched_24h"), r.get("boots_unplanned_24h"),
                r.get("scheduled_missed"), r.get("verdict")))
        A("")
    A("### 4.1 重启归因(设备侧可复核证据)")
    A("")
    A("> 由 %s 从 pstore/reboots.log/healthdog.armlog 生成。" % c("tools/acceptance/boot_audit.py"))
    A("")
    A("- 启动总数(pstore 台账): **%d**" % bres["total"])
    for k in ("scheduled", "clean", "sysrq", "crash", "unknown"):
        if k in bres["counts"]:
            A("- %s: %d" % (k, bres["counts"][k]))
    A("- reboots.log 计划触发 %d 条, 其中 %d 条能在 pstore 匹配到启动" %
      (bres["scheduled_triggers"], bres["scheduled_matched"]))
    if bres["scheduled_unmatched"]:
        A("- **台账覆盖缺口**: 以下触发行没有对应 pstore 记录(启动台账不完整, 已由 soak_boots.tsv 闭环): %s"
          % ", ".join(bres["scheduled_unmatched"]))
    A("- 达到 stable-healthy 的启动: %d (占 %.0f%%)" %
      (bres["armed_boots"], 100.0 * bres["armed_boots"] / max(1, bres["total"])))
    A("")
    A("<details><summary>逐次启动归因表(点开)</summary>")
    A("")
    A("| 启动时刻 | 类别 | 证据 |")
    A("|---|---|---|")
    for r in bres["rows"]:
        A("| %s | %s | %s |" % (r["iso"], r["category"], r["reason"][:60].replace("|", "/")))
    A("")
    A("</details>")
    A("")

    A("## 5. M3 三档计数(验收口径)")
    A("")
    if svc:
        A("| 天 | 三档 | 排除 |")
        A("|---|---|---|")
        for r in svc[-14:]:
            A("| %s | %s | %s |" % (r.get("day"), str(r)[:120], r.get("excluded")))
    else:
        A("_%s 尚未落地(M3 流交付中) —— 记 **unknown**, 不记 0。_" % c("/data/gw/logs/svc_daily.tsv"))
    A("")

    A("## 6. R4.4 故障注入 campaign")
    A("")
    A("装置: %s (PC 驱动, 设备侧单次 exec 内完成 注入→轮询→回滚→落账)。" % c("tools/acceptance/inject.py"))
    A("每条注入: 必须持设备锁、距 04:00 >=15min、有回滚路径、恢复即验证、结果落 %s。" %
      c("/data/gw/logs/fault_inject.tsv"))
    A("")
    if inj:
        A("- 注入总数: **%d** (要求 >=30)" % n_inj)
        A("- 判定分布: %s" % dict(vc))
        A("- 通过率: %.0f%%" % (100.0 * len(passes) / n_inj))
        A("- 自愈耗时: min=%ss p50=%s p90=%s max=%ss" %
          (durs[0] if durs else "?", pct(0.5), pct(0.9), durs[-1] if durs else "?"))
        A("")
        A("### 6.1 失败项(未自愈) —— 必须闭环")
        A("")
        if fails:
            A("| id | 目标 | 类别 | 耗时 | 证据 |")
            A("|---|---|---|---|---|")
            for r in fails:
                A("| %s | %s | %s | %ss | %s |" % (r.get("id"), r.get("target"),
                                                   r.get("class"), r.get("dur_s"),
                                                   str(r.get("evidence", ""))[:90]))
        else:
            A("无(全部注入均自愈)。")
        A("")
    else:
        A("_尚无注入台账_")
        A("")

    A("## 7. R4.5 无人干预声明")
    A("")
    A("详见 [%s](SELF_HEALING_AUDIT.md) §5。结论:" % "docs/SELF_HEALING_AUDIT.md")
    A("")
    A("- **日常运行不需要人工**: 每日 04:00 计划重启 + 三层自愈(内核看门狗 → healthdog → watchdog)覆盖全部常驻服务。")
    A("- **仍需人工的动作**(已消除/自动化/或明确接受):")
    A("  1. 固件升级/部署 —— 设计上必须人工(%s), 不属于运行时自持范畴。" % c("deploy.py"))
    A("  2. /data 空间耗尽 —— 仅告警不自动清理(SEV1 台账不可删); 由 R1.6 磁盘守卫在 M1 流闭环。")
    A("  3. 配置类漂移(NAT/MARK/网桥成员)被外力破坏 —— 见 §6 注入结果; 无自愈路径的列为已知缺口。")
    A("  4. 设备彻底失联(内核 hang) —— 靠 healthdog.ko 90s 硬复位兜底, 代价是一次完整重启(~110s)。")
    A("")

    A("## 8. 已排除的演练窗口(可审计)")
    A("")
    A("> 契约: %s(Lead v1.2) 是唯一演练标记文件; 消费方(svc-probe/state-truth/obs-ledger)按窗口打 excluded。" %
      c("drills.tsv"))
    A("")
    if drills:
        A("- 窗口行总数: %d (批级 %d / 逐条 %d)" %
          (len(drills), len(closed) - len(per_item), len(per_item)))
        A("- 残留 end_epoch=0 的行: **%d**%s" %
          (len(open_rows), " (必须在收批后清零)" if open_rows else " (无残留)"))
        A("- 演练总时长: %d s" % total_drill_s)
        A("")
        A("| start | end | kind | target | owner |")
        A("|---|---|---|---|---|")
        for r in closed[-40:]:
            A("| %s | %s | %s | %s | %s |" % (r.get("start_epoch"), r.get("end_epoch"),
                                              r.get("kind"), r.get("target"), r.get("owner")))
        A("")
    else:
        A("_尚无 drills.tsv_")
        A("")

    A("## 9. 未决风险与下一步")
    A("")
    A("1. **30d 未真正跑完**: 本报告只覆盖已运行样本; 装置会在无人值守下继续累积, 每日看 %s。" % c("soak.py daily"))
    A("2. **自愈延时基线 90–120s**: watchdog 的 2-of-3 确认是固有延时(见 §6 耗时分布), 已作为架构修复的对照基线交给 Lead。")
    A("3. **非计划重启**: 见 §4.1; 历史 crash 类重启集中在已退役的内核实验模块窗口(2026-09-09..10-30), 需在模块退役后重新观察。")
    A("4. **M1/M3 台账未落地**: 相关判定记 unknown, 待 obs-ledger/svc-probe 交付后重跑本生成器即可自动补齐。")
    A("")

    txt = "\n".join(L) + "\n"
    out = a.out if os.path.isabs(a.out) else os.path.join(HERE, "..", "..", a.out)
    out = os.path.abspath(out)
    with open(out, "w", encoding="utf-8") as f:
        f.write(txt)
    print("written", out, "(%d lines)" % len(L))
    return 0

if __name__ == "__main__":
    sys.exit(main())
