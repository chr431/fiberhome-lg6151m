#!/bin/sh
# rc.extend.sh v3.1 -- slot-aware dispatcher (shared /data between v2/v3)
# v3.1 (SIGSEGV §8.13): 旧内核修复栈整体退役。slot-a 内的全部自载逻辑删除 ——
#   FIXSTACK_ENABLE 门控、pstore panic guard、两次 insmod、跨启动种子喂入、
#   fixstack.log 自载台账; 改为一处占位注释, 当前不留任何自动加载动作。
#   源码/产物/构建脚本同批删除(可经 git 历史取回), MANIFEST 同步减两条。
#   理由: 无实测收益(稳态扣留 0 页、两条新增通路空转) + 自身三次内核级故障
#   (10-22 20:45 RCU stall / 21:33 Oops / 10-23 00:48 25min 冻结)。
# v3.0 (SIGSEGV Phase 1, v3.1 已取代): 旧栈默认停用(FIXSTACK_ENABLE=0), 曾计划
#   留作两臂判决备选; 判决前操作者决定直接退役, 故 v3.1 删除而非保留。
# v2.5: TZ 取自自管配置(settings>defaults)而非早期 /etc/TZ(厂商 boot 会先写 UTC)。
# v2.4: TZ 解析提前到 toolchain_init 之前(静态工具链自举日志也走镜像时区)。
# v2.2 (SIGSEGV P2/P3): static userland bootstrap — toolchain_init.sh builds
#   /data/gw/sbin (busybox applets + static iproute2), PATH is prefixed so every
#   daemon launched below runs the static shell/tools; TZ is exported from the
#   self-managed config (static musl reads TZ, vendor musl reads /etc/TZ);
#   RLIMIT_CORE is raised to unlimited as a FALLBACK only: core_pattern is a
#   pipe and the kernel forces cprm.limit=RLIM_INFINITY for pipes
#   (fs/coredump.c:675), so RLIMIT_CORE never gates that path. It matters only
#   if something downgrades the pattern to a file form.
# v2.1(P3): shadow.override 合法性校验+.bak回退自愈(坏文件不再锁死登录)
# v2.0: +clear /tmp/gui_tokens/* at boot (P2/L-7 stale token survival)
# v1.9: /etc/shadow bind 覆盖钩子(审计P0-5 凭据轮换前置; 见文件内注释)
# v1.6: route A -- FH modem-stack environment (MODE.fh gate)
# v1.8 = v1.7 + 启动行去&(同步启动); v1.7: A槽保活 + dropbear唯一属主
#   - bootslot=a 时清 misc TRY_A(offset 2061)=厂商S99语义(v4.1删S99致LK回退B的
#     根治); 无条件恢复 hnat_qos 两行(同为S99误伤)
#   - dropbear 由此处统一先启(带/data/gw/dropbear_keys), 消除 v2_access/rc19
#     并行启动的TOCTOU双实例; 下游各启动点本就带 pgrep 守卫, 自然短路
# v1.4 SUBTRACTION mandate (2026-10-03): slot-B (v2) is the MINIMAL fallback --
#   stock firmware + pure access layer, zero contention with FH daemons.
#   b-branch reduced to v2_access.sh only. wan_policy2/v3_fix/hnat/healthdog
#   moved to slot-a (v3) where the sharing mission lives.
# v1.5: flag-gated one-shot capture launch (capture_ubus.sh) BEFORE slot case
#   -- must precede FH's mobilenetwork dial to record the stock datacall blob.
grep -q healthdog /proc/modules 2>/dev/null || true

# --- v2.2 (SIGSEGV P2/P3): static userland + timezone + core dumps ----------
# Static busybox/iproute2 remove the vendor-musl crash surface for every
# daemon child (grep/awk/sh/ip/pgrep/...). toolchain_init is idempotent and
# fails closed (removes the farm -> vendor fallback) if the binary is missing.
# v2.5: prefer the self-managed config (settings > defaults) over /etc/TZ —
# the vendor boot leaves an intermediate UTC value in /tmp/TZ before the board
# timezone is applied; reading it first made the bootstrap log line UTC.
# v2.4: TZ is resolved BEFORE toolchain_init so its early log lines are in
# image time too (vendor date was UTC here when /etc/TZ was not ready yet).
# TZ fallback: /etc/TZ -> defaults.conf carries the same zone if it is not
# readable yet (otherwise static-musl tools format UTC).
TZ_CFG=$(sed -n 's/^TZ=//p' /data/gw/defaults.conf /data/gw/settings.conf 2>/dev/null | tail -1)
if [ -n "$TZ_CFG" ]; then
    TZ=$TZ_CFG
    export TZ
elif [ -z "${TZ:-}" ]; then
    TZ=$(cat /etc/TZ 2>/dev/null)
    [ -n "$TZ" ] && export TZ
fi
[ -x /data/gw/toolchain_init.sh ] && /data/gw/toolchain_init.sh
PATH=/data/gw/sbin:/data/gw/bin:$PATH
export PATH
# --- v2.6: loopback was DOWN on this image ---------------------------------
# Measured 2026-10-20: `ip link show lo` = state DOWN, ping 127.0.0.1 fails,
# and every on-device connect to 192.168.9.1 (HTTP/SSH/DNS) times out because
# the local route points at lo.  healthdog's loopback liveness check would
# therefore never pass (a fatal interaction once it arms the kernel watchdog).
# Bring lo up unconditionally; it is idempotent and costs nothing.
ip link set lo up 2>/dev/null
logger -t rc.extend "lo: $(ip link show lo 2>/dev/null | head -1)" 2>/dev/null
# Fallback only: the core_pattern pipe ignores RLIMIT_CORE (fs/coredump.c:675).
# Kept so a file-mode pattern would still capture. Hard limit is unlimited on
# this image, soft limit is 0 by default.
ulimit -c unlimited 2>/dev/null
logger -t rc.extend "static toolchain: PATH=$PATH TZ=${TZ:-unset} core=$(ulimit -c 2>/dev/null)" 2>/dev/null

# --- v2.6 (P1-2/P1-5): core_pattern metadata wrapper -----------------------
# aee owns core_pattern and its dumps are encrypted (no process name, no
# registers). core_meta.sh records /proc/<pid>/{exe,cmdline,status,maps} +
# parent + PATH + dmesg tail, then execs aee's forwarder with the same argv so
# aee behaviour is unchanged. The next SIGSEGV becomes attributable.
if [ -x /data/gw/core_meta.sh ]; then
    _cur=$(cat /proc/sys/kernel/core_pattern 2>/dev/null)
    case "$_cur" in
    *core_meta.sh*) ;;
    *) echo "|/data/gw/core_meta.sh %p %s %u %g" > /proc/sys/kernel/core_pattern 2>/dev/null
       logger -t rc.extend "core_pattern wrapped: [$_cur] -> [$(cat /proc/sys/kernel/core_pattern 2>/dev/null)]" ;;
    esac
fi

# --- v2.0(P2/L-7): session tokens cleared at boot -- /tmp is not tmpfs, stale
# tokens survive reboots (bad after password rotation); v3httpd/rc19 start
# after this script, ordering is safe.
rm -f /tmp/gui_tokens/* 2>/dev/null

# --- v1.9 (审计P0-5): /etc/shadow 覆盖 -- rootfs squashfs 只读, 凭据轮换经
# /data/gw/shadow.override bind 到 /etc/shadow (dropbear/getty 每次认证时读取,
# bind 后 passwd 写入会穿透到 override 文件 = 后续轮换可直接 passwd)。
# v2.1(P3): 合法性校验 + .bak 回退自愈 — 主文件无有效 toor 哈希行时改绑 .bak
# (上一次成功轮换的存档)并回写主文件; 两者皆坏则跳过 bind(回落镜像内建口令,
# 至少可登录修复), 杜绝坏 override 把 SSH+串口一起锁死的自锁类事故。
if ! grep -q ' /etc/shadow ' /proc/mounts; then
    SO=/data/gw/shadow.override; SB=/data/gw/shadow.override.bak
    _pick=""
    for _f in $SO $SB; do
        [ -f "$_f" ] && grep -qE '^toor:(\$[16]\$|!)' "$_f" 2>/dev/null && { _pick=$_f; break; }
    done
    if [ -n "$_pick" ]; then
        [ "$_pick" = "$SB" ] && cp -f "$SB" "$SO" 2>/dev/null   # bak 有效而主坏: 自愈回写
        [ "$_pick" = "$SO" ] && cp -f "$SO" "$SB" 2>/dev/null    # 主有效: 刷新存档
        chmod 600 "$SO" 2>/dev/null
        mount --bind "$SO" /etc/shadow 2>/dev/null \
            && logger -t rc.extend "shadow bind OK (via $_pick)" \
            || logger -t rc.extend "shadow bind FAILED ($_pick)"
    else
        logger -t rc.extend "shadow.override 无有效文件, 跳过 bind"
    fi
fi

# --- v1.7: dropbear single-owner (race-proof; downstream pgrep guards short-circuit)
mkdir -p /data/gw/dropbear_keys
[ -f /data/gw/dropbear_keys/rsa ] || /usr/bin/dropbearkey -t rsa -f /data/gw/dropbear_keys/rsa -s 2048 2>/dev/null
pgrep -x dropbear >/dev/null || /usr/sbin/dropbear -r /data/gw/dropbear_keys/rsa -p 22 >/dev/null 2>&1  # v1.8: 无&, dropbear自daemonize, 同步返回即监听, 杜绝rc19守卫竞态

# --- v2.6 (2026-10-20 P0-2): boot attempt ledger + conditional TRY_A --------
# v1.7 cleared TRY_A seconds into every A-slot boot, so LK's fallback counter
# never accumulated: a boot-breaking deploy could loop forever on slot A.
# New rule (analysis P0-2): the *early* clear is allowed only when the previous
# attempt is recorded healthy AND this boot is not a fast reboot; the definitive
# clear happens in boot_gate.sh once the boot chain is proven healthy.
BOOT_ATT=/data/gw/boot_attempts.tsv
BT=$(awk '/^btime/{print $2; exit}' /proc/stat 2>/dev/null)
BID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
PREV=$(grep -v "^btime=$BT " "$BOOT_ATT" 2>/dev/null | tail -1)
PREV_BT=$(echo "$PREV" | sed -n 's/^btime=\([0-9]*\).*/\1/p')
PREV_RES=$(echo "$PREV" | sed -n 's/.*result=\([a-z]*\).*/\1/p')
FAST=0
case "$PREV_BT" in ''|*[!0-9]*) ;; *) [ $((BT - PREV_BT)) -lt 180 ] && FAST=1 ;; esac
echo "btime=$BT epoch=$(date +%s) result=pending fast=$FAST boot_id=$BID" >> "$BOOT_ATT" 2>/dev/null
tail -n 30 "$BOOT_ATT" > "$BOOT_ATT.tmp" 2>/dev/null && mv "$BOOT_ATT.tmp" "$BOOT_ATT"
logger -t rc.extend "boot attempt: btime=$BT prev=$PREV_RES fast=$FAST"

# --- v1.7: A-slot keepalive (vendor S99 semantics, lost when S99 was removed)
case "$(cat /proc/cmdline)" in *bootslot=a*)
    _try=retain
    if [ "$PREV_RES" = healthy ] && [ "$FAST" = 0 ]; then
        [ -b /dev/mmcblk0p1 ] && dd if=/dev/zero of=/dev/mmcblk0p1 bs=1 seek=2061 count=1 conv=notrunc 2>/dev/null
        _try=cleared
    fi
    echo 0 1 > /proc/hnat/hnat_qos 2>/dev/null
    echo 2 1 > /proc/hnat/hnat_qos 2>/dev/null
    logger -t rc.extend "slot=a: TRY_A=$_try (prev=$PREV_RES fast=$FAST) + hnat_qos"
    ;; esac
[ -f /data/gw/DO_UBUS_CAP ] && nohup sh /data/gw/capture_ubus.sh >/dev/null 2>&1 &
slot=$(cat /proc/cmdline | tr ' ' '\n' | sed -n 's/^bootslot=//p')
case "$slot" in
  b) # v2: access layer ONLY (serial/SSH/DHCP/firewall-22 + logging)
     logger -t rc.extend "slot=b (v2 minimal): v2_access only"
     nohup sh /data/gw/v2_access.sh >/dev/null 2>&1 &
     ;;
  *) # v3: full stack (forensics, flight rc19, TTL/hnat are v3 duties)
     logger -t rc.extend "slot=$slot: v3 rc19.sh"
     # v3.1 (SIGSEGV §8.13): 旧内核修复栈已整体退役, 此处不再做任何自动加载。
     #   退役理由一句话: 稳态扣留 0 页 + 两条新增通路空转(无实测收益), 且自身
     #   造成三次内核级故障(RCU stall / Oops / 25min 冻结)。
     #   新方案接入点预留在此处: 落地时在此写它的自加载与守卫逻辑, 并同步
     #   MANIFEST 与注册表; 当前版本不执行任何 insmod/门控/台账动作。
     # v1.6: route A -- FH modem-stack environment parallel to our layer
     # (dial: mobilenetwork 过渡期 + dial_keeper 兜底; rc19 skips rmmod+dial_5g via MODE.fh gate)
     # v1.7 (D2 开箱审查): MODE.fh 首刷自建 — kit 从不创建该标志, 纯原厂直刷时
     #       rc_netfh 不跑 = 无蜂窝栈。缺省即路由A(5G CPE 必须有 modem); 移除
     #       该文件可回 frankenstein 模式(与原语义一致)。
     if [ ! -f /data/gw/MODE.fh ]; then
         touch /data/gw/MODE.fh
         echo "$(date -u +%FT%TZ) MODE.fh auto-provisioned (first boot)" >> /tmp/rc.extend.log
     fi
     [ -f /data/gw/MODE.fh ] && nohup sh /data/gw/rc_netfh.sh >/tmp/netfh.out 2>&1 &
     # v2.6 (P1-5): FORENSIC D 打印按 marker 开启(默认关, 降 dmesg 噪声)
     _fore=0; [ -e /data/gw/healthdog.forensic ] && _fore=1
     insmod /data/gw/healthdog.ko forensic=$_fore armed=0 2>/dev/null
     nohup sh /data/gw/rc19.sh >/tmp/rc19.log 2>&1 &
     # v3.0 (SIGSEGV Phase 1): 改回内核默认 0。该设置原本只为"锁内深遍历 +
     #   旧栈"组合兜底, 叠加源已随旧栈退役消失(§8.13); 保留 1 会把任何真实 RCU 停顿
     #   升级成重启, 既丢现场又会打断刚修好的 NE 台账。
     echo 0 > /proc/sys/kernel/panic_on_rcu_stall 2>/dev/null
     [ -e /proc/healthdog ] || insmod /data/gw/healthdog.ko 2>/dev/null
     pgrep -f healthdog.sh >/dev/null || nohup /data/gw/healthdog.sh >/dev/null 2>&1 &
     ;;
esac
