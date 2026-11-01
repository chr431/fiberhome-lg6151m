#!/bin/sh
# svc_lib_selftest.sh v1.0 -- svc_lib.sh 两条 P1 修复的设备侧回归测试
#
# 覆盖:
#   A. alive() 正样本   —— 真守护(sh /data/gw/watchdog.sh)必须判活
#   B. alive() 负样本1  —— 只有 sh -c 串里提到路径的诱饵进程, 必须判死
#                          (soak-qa 2026-11-01 00:05 实弹: 注入 harness 冒充守护)
#   C. alive() 负样本2  —— 锁分支: /tmp/<name>.lock 指向诱饵进程(路径只在 -c 串里)
#   D. alive() 负样本3  —— 手工排障型: tail -f <路径> 不得冒充守护
#   E. rl_ok() 语义     —— 快预算 3 次 -> 慢重试(不放弃) -> 10 次后仍重试 -> 窗口滚动复位
#   F. rl_ok() 兼容     —— 旧 2 字段 .rec 文件
#
# 判定: 每条打印 ok/FAIL; 末尾 RESULT pass=N fail=M; 有 FAIL 则退出码 1。
# 副作用: 仅在 /tmp 建临时文件与短命诱饵进程, 全部在退出时清理; 不碰 /data/gw。
# 用法: sh /data/gw/svc_lib_selftest.sh   (或 sh tools/svc_lib_selftest.sh 于设备上)
. /data/gw/svc_lib.sh
pass=0; fail=0
chk() { # $1=desc $2=want $3=got
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1 (want=$2)"
    else fail=$((fail+1)); echo "  FAIL $1 (want=$2 got=$3)"; fi
}
DECOYS=""

# ---- A. 正样本: 真守护 ----
if pgrep -f '^sh /data/gw/watchdog[.]sh' >/dev/null 2>&1; then
    alive "" "" watchdog.sh; chk "A 真守护 watchdog.sh 判活" 0 "$?"
else
    echo "  skip A (watchdog 未运行, 本机不适用)"
fi

# ---- B. 负样本: sh -c 串里提到路径 ----
sh -c 'sleep 60; echo /data/gw/ntp_keeper_selftest.sh' >/dev/null 2>&1 &
DECOYS="$DECOYS $!"
sleep 1
alive "" "" ntp_keeper_selftest.sh; chk "B sh -c 串冒充 -> 必须判死" 1 "$?"

# ---- C. 负样本: 锁分支(锁文件指向诱饵) ----
echo "$!" > /tmp/svc_selftest.lock 2>/dev/null
alive "" svc_selftest ntp_keeper_selftest.sh; chk "C 锁分支指向诱饵 -> 必须判死" 1 "$?"
rm -f /tmp/svc_selftest.lock

# ---- D. 负样本: tail -f <路径> ----
tail -f /data/gw/ntp_keeper_selftest.sh >/dev/null 2>&1 &
DECOYS="$DECOYS $!"
sleep 1
alive "" "" ntp_keeper_selftest.sh; chk "D tail -f 提及 -> 必须判死" 1 "$?"

# ---- E. rl_ok 语义(用 RL_NOW 测试钩子, 不依赖真实时钟) ----
rm -f /tmp/watchdog_svc_selftest.rec
RL_NOW=1000 rl_ok selftest; chk "E1 第1次快重启放行" 0 "$?"
RL_NOW=1000 rl_ok selftest; chk "E2 第2次" 0 "$?"
RL_NOW=1000 rl_ok selftest; chk "E3 第3次" 0 "$?"
RL_NOW=1000 rl_ok selftest; chk "E4 预算耗尽后立即重试被限流" 1 "$?"
RL_NOW=1060 rl_ok selftest; chk "E5 60s 后慢重试放行(不再永久放弃)" 0 "$?"
RL_NOW=1090 rl_ok selftest; chk "E6 30s 后仍被限流" 1 "$?"
# 注意: ash 无 local —— rl_ok 会写 _t/_n/_l/_s/_f/_now, 测试自己的累加变量必须另起名
_tn=1060
for _i in 1 2 3 4 5 6 7 8 9; do _tn=$((_tn+60)); RL_NOW=$_tn rl_ok selftest >/dev/null 2>&1; done
RL_NOW=$((_tn+60)) rl_ok selftest; chk "E7 第11次慢重试仍放行(永不静默停止)" 0 "$?"
RL_NOW=$((_tn+60+3601)) rl_ok selftest; chk "E8 小时窗滚过快预算复位" 0 "$?"

# ---- F. 旧 2 字段 .rec 兼容 ----
echo "2 5000" > /tmp/watchdog_svc_selftest_legacy.rec
RL_NOW=5000 rl_ok selftest_legacy; chk "F1 旧2字段 n=2 -> 第3次放行" 0 "$?"
RL_NOW=5000 rl_ok selftest_legacy; chk "F2 旧2字段 n=3 -> 限流" 1 "$?"
RL_NOW=5060 rl_ok selftest_legacy; chk "F3 旧2字段 -> 60s 后慢重试" 0 "$?"


# ---- G. 判活陷阱回归（Lead 指派：三个流各撞一次的同族缺陷的永久护栏） ----
# G1 名字像(可达形态): 同名不同路径 —— sh /tmp/<token> 而不是 /data/gw/<token>
printf '#!/bin/sh\nsleep 60\n' > /tmp/ntp_keeper_trap.sh 2>/dev/null
chmod +x /tmp/ntp_keeper_trap.sh 2>/dev/null
sh /tmp/ntp_keeper_trap.sh >/dev/null 2>&1 &
DECOYS="$DECOYS $!"
sleep 1
alive "" "" ntp_keeper_trap.sh; chk "G1 同名不同路径(/tmp 非 /data/gw) -> 必须判死" 1 "$?"
# G1b argv[0] 冒充: 本平台**不可构造** —— busybox ash 无 exec -a, busybox 按 argv[0] 派发
#   applet, 镜像内也没有独立 sleep 可做 symlink 伪装。**如实 skip, 不假装覆盖**
#   (同族已由 G2/G3 覆盖; 若将来换了 shell 支持 exec -a, 这段会自动变成真断言)。
if sh -c 'exec -a probe_xyz_selftest sleep 2' >/dev/null 2>&1 && \
   [ -n "$(pgrep -f '^probe_xyz_selftest' 2>/dev/null)" ]; then
    sh -c 'exec -a /data/gw/ntp_keeper_trap.sh sleep 30' >/dev/null 2>&1 &
    DECOYS="$DECOYS $!"
    sleep 1
    alive "" "" ntp_keeper_trap.sh; chk "G1b exec -a 冒充 argv[0] -> 必须判死" 1 "$?"
else
    echo "  skip G1b (本平台不支持 exec -a, argv[0] 冒充不可构造; 同族由 G2/G3 覆盖)"
fi
# G2 路径像: argv 里有目标路径, 但 argv[0] 不是它
sh -c 'exec sleep 60 /data/gw/ntp_keeper_trap.sh' >/dev/null 2>&1 &
DECOYS="$DECOYS $!"
sleep 1
alive "" "" ntp_keeper_trap.sh; chk "G2 路径只出现在参数里 -> 必须判死" 1 "$?"
# G3 自己像: 测试命令自身的 cmdline 含被查字符串, 不得把测试自己算进去
sh -c 'echo /data/gw/ntp_keeper_trap.sh >/dev/null; sleep 30' >/dev/null 2>&1 &
DECOYS="$DECOYS $!"
sleep 1
alive "" "" ntp_keeper_trap.sh; chk "G3 测试自身 cmdline 含路径 -> 必须判死" 1 "$?"

# ---- 清理 ----
for _p in $DECOYS; do kill "$_p" 2>/dev/null; done
rm -f /tmp/watchdog_svc_selftest.rec /tmp/watchdog_svc_selftest_legacy.rec /tmp/svc_selftest.lock
echo "RESULT pass=$pass fail=$fail"
[ "$fail" = 0 ] || exit 1
exit 0
