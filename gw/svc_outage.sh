#!/bin/sh
# svc_outage.sh v1.0 -- 设备侧服务中断台账（M3/R3.2-R3.5 消费端，非采样端）
#
# 设计约束（Lead 裁决 v1.1）：**全设备只允许一个 1s 循环**（state-truth 的
#   gw/fast_watch.sh）。本脚本不采样、不起循环，只消费：
#     ① /data/gw/logs/fast_facts.tsv  —— 1s 事实流（权威；schema v1.0 冻结：
#        epoch_ms / probe_id / ok / latency_ms / extra，5 列无表头）
#     ② /data/gw/logs/avail_edges.tsv —— 2s 边缘台账（**过渡期兜底**，4s 磁滞）
#   用 ② 派生出的行一律 flags 带 preliminary=1，防止把 4s 磁滞当 1s 测量。
#
# 产出：
#   /data/gw/logs/svc_outages.tsv  start end dur path probe severity attrib excluded
#                                  excl_reason evidence side flags
#   /data/gw/logs/svc_daily.tsv    date path lt5 n5_20 n20 total excluded preliminary
#
# 中断定义（与 docs/SVC_MEASUREMENT.md 同源）：
#   同一 probe 连续 >=2 行 ok=0 = 中断；时长 = 首次失败 -> 首次成功。
#   三档：<5s / 5-20s / >20s；severity SEV3/SEV2/SEV1（与 RELIABILITY_SPEC R1.2 对齐）。
#   设备侧无 path 维度（br-lan 成员 eth1/ra0/rai0/rndis0 同桥，见 state-truth 说明），
#   故 path 恒为 gw；按路径的验收口径只在客户端侧（spec R3.2）。
#
# 排除规则（R3.4，可审计）：
#   drills.tsv 窗口          -> excluded=1 reason=drill（Lead 裁决 v1.2 契约）
#   boot 窗 + reboots.log 当日计划行 -> excluded=1 reason=planned_reboot
#   boot 窗但非计划         -> excluded=0 attrib=reboot（非计划重启必须计数）
#
# 用法：
#   sh /data/gw/svc_outage.sh tick      # 增量消费（fast_watch 每 N 拍调用一次）
#   sh /data/gw/svc_outage.sh derive    # 全量重建（游标重置；离线/首次）
#   sh /data/gw/svc_outage.sh daily     # 由 svc_outages.tsv 重算日聚合
#   sh /data/gw/svc_outage.sh status    # 自检：源/游标/行数/最近一条
#
# 纪律：busybox ash —— 无 local、无数组；数值一律 case 守卫；单实例用 mkdir 原子锁
#   （不用 svc_lock：它每次 sleep 0.2s，本脚本按拍调用，代价不可接受）。
BB=/data/gw/bin/busybox
[ -x "$BB" ] || BB=busybox
# 路径可覆盖（离线/演练自测用，D2 工具可自测）：SVC_LOG_DIR / SVC_RUN_DIR
LOG=${SVC_LOG_DIR:-/data/gw/logs}
RUN=${SVC_RUN_DIR:-/data/gw/run}
FF=$LOG/fast_facts.tsv
EDGES=$LOG/avail_edges.tsv
OUT=$LOG/svc_outages.tsv
DAILY=$LOG/svc_daily.tsv
DRILLS=$LOG/drills.tsv
REBOOTS=$LOG/reboots.log
NE=$LOG/ne_events.tsv
STATE=$RUN/svc_state
CUR=$RUN/svc_cursor
LOCK=/tmp/svc_outage.lock
mkdir -p "$LOG" "$RUN" 2>/dev/null

num0() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }

take_lock() {
    mkdir "$LOCK" 2>/dev/null || return 1
    echo $$ > "$LOCK/pid" 2>/dev/null
    return 0
}
drop_lock() { rm -rf "$LOCK" 2>/dev/null; }

# ---- 排除/归因（写入时一次算清，事后可复核） ----
# 输出一行：attrib|excluded|excl_reason|evidence
classify() { # $1=probe $2=start $3=end
    _c_p=$1; _c_a=$2; _c_b=$3
    _c_attr=unknown; _c_ex=0; _c_why=""; _c_ev=""
    _c_now=$(date +%s)
    # ① 演练窗口（Lead v1.2 契约；end=0 视为仍在进行，防止忘记回填把假中断放行）
    if [ -r "$DRILLS" ]; then
        _c_d=$(awk -v a="$_c_a" -v b="$_c_b" -v now="$_c_now" '
            /^[#]/ { next }
            NF >= 2 { st=$1+0; en=$2+0; if (en==0) en=now;
                      if (a <= en+30 && b >= st-30) { print st"-"en"("$4")"; exit } }' "$DRILLS")
        if [ -n "$_c_d" ]; then
            _c_attr=drill; _c_ex=1; _c_why=drill; _c_ev="drills:$_c_d"
        fi
    fi
    # ② boot 窗（本 boot 起始时刻 = now - uptime；窗 -300s..+300s）
    if [ "$_c_ex" = 0 ]; then
        _c_up=$(cut -d. -f1 /proc/uptime)
        _c_boot=$(( _c_now - _c_up ))
        if [ "$_c_a" -ge $(( _c_boot - 300 )) ] && [ "$_c_a" -le $(( _c_boot + 300 )) ]; then
            _c_plan=0
            _c_rl=$(tail -1 "$REBOOTS" 2>/dev/null)
            case "$_c_rl" in
                "$(date +%Y-%m-%d)"*REBOOT*) _c_plan=1 ;;
            esac
            if [ "$_c_plan" = 1 ]; then
                _c_attr=reboot; _c_ex=1; _c_why=planned_reboot; _c_ev="boot@$_c_boot"
            else
                _c_attr="reboot(unplanned)"; _c_ev="boot@$_c_boot"
            fi
        fi
    fi
    # ③ 归因：probe -> 组件映射 + 设备侧证据链（NE / 边缘）
    if [ "$_c_ex" = 0 ] && [ "$_c_attr" = unknown ]; then
        case "$_c_p" in
        tcp80) _c_attr="sys.gui/v3httpd"; _c_pat=v3httpd ;;
        tcp22) _c_attr="sys.ssh/dropbear"; _c_pat=dropbear ;;
        dns)   _c_attr="lan.bridge/dnsmasq"; _c_pat=dnsmasq ;;
        icmp)  _c_attr="lan.path"; _c_pat="" ;;
        *)     _c_attr=unknown; _c_pat="" ;;
        esac
        if [ -n "$_c_pat" ] && [ -r "$NE" ]; then
            _c_n=$(awk -v a="$_c_a" -v b="$_c_b" -v p="$_c_pat" \
                'index($0,p)>0 && $1+0>=a-10 && $1+0<=b+10 {print NR"@"$1; exit}' "$NE" 2>/dev/null)
            [ -n "$_c_n" ] && { _c_ev="ne:$_c_n"; _c_attr="$_c_attr+ne"; }
        fi
        if [ -z "$_c_ev" ] && [ -r "$EDGES" ]; then
            case "$_c_p" in
            tcp80) _c_eid=gui ;;
            tcp22) _c_eid=ssh ;;
            dns)   _c_eid=dns ;;
            *)     _c_eid="" ;;
            esac
            if [ -n "$_c_eid" ]; then
                _c_e=$(awk -v a="$_c_a" -v b="$_c_b" -v i="$_c_eid" \
                    '$1+0>=a-8 && $1+0<=b+8 && index($0,i)>0 && index($0,"edge_down")>0 {print $1; exit}' "$EDGES" 2>/dev/null)
                [ -n "$_c_e" ] && _c_ev="edges:"$_c_eid"@"$_c_e
            fi
        fi
        # 无旁证时，证据链=探针本身（TCP:80 拒连/超时直接证明 GUI 未受理）
        [ -z "$_c_ev" ] && [ "$_c_attr" != unknown ] && _c_ev="probe:$_c_p"
    fi
    echo "$_c_attr|$_c_ex|$_c_why|$_c_ev"
}

sev_of() { # $1=dur_s
    awk -v d="$1" 'BEGIN{ if (d>20) print "SEV1"; else if (d>=5) print "SEV2"; else print "SEV3" }'
}

emit() { # $1=start $2=end $3=probe $4=path $5=flags
    _e_st=$(num0 "$1"); _e_en=$(num0 "$2")
    [ "$_e_en" -ge "$_e_st" ] || return 0
    # dur 单位=秒（台账字段语义）；severity 用秒判定（1s 采样下毫秒无意义）
    _e_dur=$(( ( _e_en - _e_st ) / 1000 ))
    _e_sev=$(sev_of "$_e_dur")
    _e_cls=$(classify "$3" "$_e_st" "$_e_en")
    _e_attr=$(printf '%s' "$_e_cls" | cut -d'|' -f1)
    _e_ex=$(printf '%s' "$_e_cls" | cut -d'|' -f2)
    _e_why=$(printf '%s' "$_e_cls" | cut -d'|' -f3)
    _e_ev=$(printf '%s' "$_e_cls" | cut -d'|' -f4)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tdev\t%s\n' \
        "$_e_st" "$_e_en" "$_e_dur" "$4" "$3" "$_e_sev" "$_e_attr" "$_e_ex" \
        "$_e_why" "$_e_ev" "$5" >> "$OUT"
}

# ---- 源 ①：fast_facts.tsv（1s，权威） ----
consume_ff() { # $1=tick|derive
    _mode=$1
    _cur=0
    if [ "$_mode" = tick ] && [ -r "$CUR" ]; then _cur=$(num0 "$(cat "$CUR" 2>/dev/null)"); fi
    _total=$(num0 "$(wc -l < "$FF" 2>/dev/null)")
    [ "$_total" -gt 0 ] || return 0
    [ "$_cur" -ge "$_total" ] && return 0
    : > "$RUN/svc_ep.tmp"
    : > "$RUN/svc_st.tmp"
    awk -v cur="$_cur" -v statef="$STATE" -v epf="$RUN/svc_ep.tmp" -v stf="$RUN/svc_st.tmp" '
      BEGIN {
        while ((getline ln < statef) > 0) {
          n = split(ln, a, "|")
          if (n >= 4) { fails[a[1]] = a[2]+0; start[a[1]] = a[3]+0; last[a[1]] = a[4]+0 }
        }
        close(statef)
      }
      NR <= cur { next }
      {
        ts = $1+0; p = $2; ok = $3+0
        q = ""
        if (p == "gw.tcp80") q = "tcp80"
        else if (p == "gw.tcp22") q = "tcp22"
        else if (p == "gw.dns") q = "dns"
        if (q == "") next
        # 采样缺口：失败期间出现 >90s 无行 = fast_watch 停摆，不可当连续失败，
        # 以最后已知样本收尾并标记 gap（诚实性：缺口不等于中断，也不等于无事）
        if (start[q] > 0 && last[q] > 0 && ts - last[q] > 90000) {
          print start[q] "|" last[q] "|" q "|gap" >> epf
          start[q] = 0; fails[q] = 0
        }
        last[q] = ts
        if (ok == 0) { if (start[q] == 0) start[q] = ts; fails[q]++ }
        else {
          if (start[q] > 0 && fails[q] >= 2) print start[q] "|" ts "|" q "|ok" >> epf
          start[q] = 0; fails[q] = 0
        }
      }
      END { for (k in last) print k "|" fails[k]+0 "|" start[k]+0 "|" last[k]+0 > stf }' "$FF"
    mv -f "$RUN/svc_st.tmp" "$STATE" 2>/dev/null
    while IFS='|' read -r _s _e _p _f; do
        [ -n "$_s" ] || continue
        if [ "$_f" = gap ]; then emit "$_s" "$_e" "$_p" gw "gap=1"
        else emit "$_s" "$_e" "$_p" gw ""; fi
    done < "$RUN/svc_ep.tmp"
    echo "$_total" > "$CUR"
    rm -f "$RUN/svc_ep.tmp"
}

# ---- 源 ②：avail_edges.tsv（2s 边缘，过渡期兜底，preliminary=1） ----
consume_edges() { # $1=tick|derive
    _mode=$1
    _cur=0
    if [ "$_mode" = tick ] && [ -r "$CUR" ]; then _cur=$(num0 "$(cat "$CUR" 2>/dev/null)"); fi
    _total=$(num0 "$(wc -l < "$EDGES" 2>/dev/null)")
    [ "$_total" -gt 0 ] || return 0
    [ "$_cur" -ge "$_total" ] && return 0
    _epf=$RUN/svc_ep.tmp
    _stf=$RUN/svc_edst
    : > "$_epf"
    : > "$_stf.tmp"
    awk -v cur="$_cur" -v epf="$_epf" -v stf="$_stf" -v stfnew="$_stf.tmp" '
      BEGIN {
        while ((getline ln < stf) > 0) {
          n = split(ln, a, "|"); if (n >= 2) start[a[1]] = a[2]+0
        }
        close(stf)
      }
      NR <= cur { next }
      {
        ts = $1+0; ev = ""; id = ""
        for (i = 2; i <= NF; i++) {
          if ($i == "edge_down" || $i == "edge_up") { ev = $i; id = $(i-1); break }
        }
        if (ev == "") next
        q = ""
        if (id == "gui" || id == "gui.serve") q = "tcp80"
        else if (id == "ssh" || id == "ssh.banner") q = "tcp22"
        else if (id == "dns" || id == "dns.pids") q = "dns"
        else if (id == "br.up") q = "icmp"
        if (q == "") next
        if (ev == "edge_down") { if (start[q] == 0) start[q] = ts }
        else { if (start[q] > 0) { print start[q] "|" ts "|" q "|edge" >> epf; start[q] = 0 } }
      }
      END { for (k in start) if (start[k] > 0) print k "|" start[k] > stfnew }' "$EDGES"
    mv -f "$_stf.tmp" "$_stf" 2>/dev/null
    while IFS='|' read -r _s _e _p _f; do
        [ -n "$_s" ] || continue
        # avail_edges 的时间戳是秒；统一换算成毫秒再进 emit（下游按 ms 处理）
        emit "$(( _s * 1000 ))" "$(( _e * 1000 ))" "$_p" gw "preliminary=1"
    done < "$_epf"
    echo "$_total" > "$CUR"
    rm -f "$_epf"
}

# ---- 日聚合（三档计数；excluded 与 preliminary 单列） ----
do_daily() {
    [ -r "$OUT" ] || return 0
    _t=$RUN/svc_daily.tmp
    awk -F'\t' '
      $1 ~ /^[0-9]+$/ {
        d = strftime("%Y%m%d", int(($1+0)/1000))
        k = d "|" $4
        tot[k]++
        if ($8+0 == 1) ex[k]++
        else if ($3+0 > 20) n20[k]++
        else if ($3+0 >= 5) n5[k]++
        else lt5[k]++
        if (index($12, "preliminary=1") > 0) pre[k]++
      }
      END {
        for (k in tot) {
          split(k, p, "|")
          print p[1] "|" p[2] "|" lt5[k]+0 "|" n5[k]+0 "|" n20[k]+0 "|" tot[k]+0 "|" ex[k]+0 "|" pre[k]+0
        }
      }' "$OUT" | sort > "$_t"
    { echo "#svc_daily v1.0 | date path lt5 n5_20 n20 total excluded preliminary"
      cat "$_t"; } > "$DAILY.new"
    mv -f "$DAILY.new" "$DAILY"
    rm -f "$_t"
}

hdr() {
    [ -s "$OUT" ] || { echo "#svc_outage v1.0 | fields: start end dur path probe severity attrib excluded excl_reason evidence side flags" > "$OUT"; }
}

pick_src() {
    if [ -s "$FF" ]; then echo ff; else echo edges; fi
}

do_tick() {
    take_lock || return 0
    hdr
    _src=$(pick_src)
    if [ "$_src" = ff ]; then consume_ff tick; else consume_edges tick; fi
    drop_lock
    return 0
}

do_derive() {
    take_lock || return 0
    rm -f "$CUR" "$STATE" "$RUN/svc_edst" "$OUT"
    hdr
    _src=$(pick_src)
    if [ "$_src" = ff ]; then consume_ff derive; else consume_edges derive; fi
    drop_lock
    do_daily
    return 0
}

do_status() {
    echo "source=$(pick_src)"
    _nff=0; [ -r "$FF" ] && _nff=$(num0 "$(wc -l < "$FF")")
    _ned=0; [ -r "$EDGES" ] && _ned=$(num0 "$(wc -l < "$EDGES")")
    _nout=0; [ -r "$OUT" ] && _nout=$(( $(num0 "$(wc -l < "$OUT")") - 1 ))
    _nda=0; [ -r "$DAILY" ] && _nda=$(( $(num0 "$(wc -l < "$DAILY")") - 1 ))
    echo "fast_facts=$_nff edges=$_ned cursor=$(num0 "$(cat "$CUR" 2>/dev/null)")"
    echo "outages=$_nout daily=$_nda"
    echo "drills=$([ -r "$DRILLS" ] && num0 "$(wc -l < "$DRILLS")" || echo 0) reboots=$([ -r "$REBOOTS" ] && num0 "$(wc -l < "$REBOOTS")" || echo 0)"
    tail -3 "$OUT" 2>/dev/null
}

case "$1" in
tick)   do_tick ;;
derive) do_derive ;;
daily)  do_daily ;;
status) do_status ;;
*)      echo "usage: svc_outage.sh tick|derive|daily|status" >&2; exit 2 ;;
esac
exit 0
