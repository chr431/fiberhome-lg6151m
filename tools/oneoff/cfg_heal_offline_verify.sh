#!/bin/sh
# cfg_heal_offline_verify.sh -- 用**真实设备快照**离线验证 cfg_heal 的检测判据
#   (一次性取证工具; tools/oneoff 按项目规则不登记)
# 用法: sh tools/oneoff/cfg_heal_offline_verify.sh <snapshot.txt>
#   snapshot.txt = 设备上顺序输出 @@IPR@@ / @@NAT@@ / @@FLT@@ / @@MGL@@ / @@BR@@ /
#                  @@ADR@@ / @@MODE@@ / @@ENG@@ / @@ALIVE@@ 各节内容的文本
set -u
SRC=$1
[ -r "$SRC" ] || { echo "usage: $0 <snapshot.txt>"; exit 2; }
REPO=$(cd "$(dirname "$0")/../.." && pwd)
TMP=/tmp/cfgheal_verify.$$
SNAPF=$TMP/current.txt
mkdir -p "$TMP/gw" "$TMP/bin" || exit 3
trap 'rm -rf "$TMP"' EXIT INT TERM
cp "$SRC" "$SNAPF"

cp "$REPO/gw/netlock.sh" "$REPO/gw/svc_lib.sh" "$REPO/gw/wan_agg_lib.sh" "$TMP/gw/" || exit 3
sed "s|^GWDATA=/data/gw\$|GWDATA=$TMP/gw|" "$REPO/gw/cfg_heal.sh" > "$TMP/cfg_heal_test.sh"

mk() { # $1=path $2=args-pattern $3=section
    cat > "$1" <<EOF
#!/bin/sh
case "\$*" in
"$2") awk -v n="@@$3@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
*) exit 0 ;;
esac
EOF
    chmod +x "$1"
}
cat > "$TMP/bin/iptables" <<EOF
#!/bin/sh
case "\$*" in
"-t nat -S") awk -v n="@@NAT@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
"-t mangle -S") awk -v n="@@MGL@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
"-S") awk -v n="@@FLT@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
*) exit 0 ;;
esac
EOF
cat > "$TMP/bin/ip" <<EOF
#!/bin/sh
case "\$*" in
"rule show") awk -v n="@@IPR@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
"-o -4 addr show") awk -v n="@@ADR@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
*) exit 0 ;;
esac
EOF
cat > "$TMP/bin/brctl" <<EOF
#!/bin/sh
case "\$*" in
"show br-lan") awk -v n="@@BR@@" '\$0==n{f=1;next} /^@@[A-Z]+@@\$/{if(f)exit} f' "$SNAPF" ;;
*) exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/iptables" "$TMP/bin/ip" "$TMP/bin/brctl"

sec() { awk -v n="@@$1@@" '$0==n{f=1;next} /^@@[A-Z]+@@$/{if(f)exit} f' "$SNAPF"; }
sec MODE  > /tmp/wan_mode   2>/dev/null
sec ENG   > /tmp/wan_engine 2>/dev/null
# 新鲜度: 快照里的 hb= 是抓取时刻的 uptime, 回放时会显得很旧 -> 这里改写成"此刻"
# (否则 WFRESH=0 会让聚合面整体不判, 那是**正确行为**, 但会把本用例测成空转)
UPH=$(cut -d. -f1 /proc/uptime)
echo "home=1 cell=1 ts=$(date +%s) hb=$UPH" > /tmp/wan_alive

run() { PATH="$TMP/bin:$PATH" sh "$TMP/cfg_heal_test.sh" --json 2>/dev/null; }
BAD=0
ck() { # $1=期望子串 $2=标签
    OUT=$(run); echo "   $OUT"
    case "$OUT" in
        *"$1"*) echo "   PASS $2"; return 0 ;;
        *)      echo "   FAIL $2"; BAD=$((BAD+1)); return 1 ;;
    esac
}
cknot() { # $1=不应出现的子串 $2=标签
    OUT=$(run); echo "   $OUT"
    case "$OUT" in
        *"$1"*) echo "   FAIL $2"; BAD=$((BAD+1)); return 1 ;;
        *)      echo "   PASS $2"; return 0 ;;
    esac
}

echo "== 1) 正常态(真实快照原样回放) -> 期望 drift 为空"
ck '"drift":""' "正常态 0 漂移(不误伤)"

echo "== 2) 删掉 ccmni2 的 MASQUERADE -> 期望报 nat:ccmni2"
grep -v -- '-o ccmni2 -j MASQUERADE' "$SNAPF" > "$TMP/n"; cp "$TMP/n" "$SNAPF"
ck 'nat:ccmni2' "检出 nat:ccmni2"

echo "== 3) 删掉 mangle 的打标行 -> 期望报 split:wanagg"
grep -v -- '--set-xmark' "$SNAPF" > "$TMP/n"; cp "$TMP/n" "$SNAPF"
ck 'split:wanagg' "检出 split:wanagg"

echo "== 4) 把 eth1 从 br-lan 摘掉 -> 期望报 br:eth1  [SKIP: 判据含 [ -d /sys/class/net/eth1 ], PC 无 /sys]"
echo "   SKIP (由实机演练 D4 覆盖)"

echo "== 5) 删掉 fwmark 200 规则 -> 期望报 mark:w2"
grep -v 'fwmark 0x8000000' "$SNAPF" > "$TMP/n"; cp "$TMP/n" "$SNAPF"
ck 'mark:w2' "检出 mark:w2"

echo "== 6) 删掉 V4WANGUARDF 的 eth0 跳转 -> 期望报 fw:wanguardf-eth0  [SKIP: 同上, 判据含 /sys]"
echo "   SKIP (由实机演练 D5 覆盖)"

echo "== 7) 反例: 期望值来源陈旧(wan_mode 非 agg 格式) -> 聚合面必须**不判**"
echo "stale" > /tmp/wan_mode
cknot 'split:wanagg' "陈旧状态不判 split"
cknot 'mark:w' "陈旧状态不判 mark"

echo "== 8) 反例: 引擎为 vendor -> mangle 面必须**不判**(本来就不装)"
sec ENG > /tmp/wan_engine 2>/dev/null; echo vendor > /tmp/wan_engine
cknot 'split:wanagg' "vendor 引擎不判 split"

echo "---- offline verify: failures=$BAD"
[ "$BAD" = 0 ]
