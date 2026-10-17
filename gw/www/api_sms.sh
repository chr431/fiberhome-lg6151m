# api_sms.sh v1.2 — 短信域模块 (被 api.sh 按端点懒加载; 依赖核心的 helpers)
# v1.2 (2026-10-17 日志加密轮): 发送成败/长度/模组原始响应写 /tmp/api.log
#   (号码只留末 4 位, 内容不落盘)。
# v1.0 (2026-10-17 架构轮): 自 api.sh v2.74 拆出 — sms/sms_send 端点族。
# 域历史(自 api.sh 头注迁入):
# v2.53(2026-10-07 实弹): CMGL 全线弃用 — ql_ril 的 CMGL 未读列表路径段错误
#   (新到未读短信在存储时, CMGL="ALL"/"REC UNREAD" 必崩 mipc_wan_cli, "REC READ"
#   空返回不崩; CMGR 逐条完全正常)。改为 CPMS 计数 + CMGR 1..N 循环(CMGR 读后
#   自动转已读 = 顺带绕开崩溃路径)。索引可能因删除有洞, 洞位返回 CMS ERROR 跳过。
# v2.50(2026-10-07 实弹修复): modem 出厂 CMGF=0(PDU 模式)下字符串 stat 参数必报
#   +CME ERROR:100 = GUI 短信页恒空。现每次先 AT+CMGF=1(易失配置, modem 重启回
#   0, 故幂等设置), 读毕还原 0(11:5x 入信丢失窗口与 1 态重合, 宁可信其有)。
#   正文: 中文运营商短信是 UCS2-BE 十六进制(多段带 UDH 头 050003|ref|n|seq),
#   原样透传=乱码; 现解码 UCS2->UTF-8 并按 (oa,ref) 合并多段, GSM7 可读正文
#   原样透传。busybox awk 无 strtonum -> h2d 手工换算; 无区间量词 -> 显式判长。
# v2.29 (P4): SMS 发送 -- mipc_cellular ql_sms_send_msg 直发(同步, ret=0 即成功),
#   无 AT CMGS 交互毒性; 中文需 UCS2-BE hex(text 以 ucs2: 前缀传 hex)。
get_sms() {
    mipc_wan_cli --at_cmd "AT+CMGF=1" >/dev/null 2>&1
    N=$(mipc_wan_cli --at_cmd "AT+CPMS?" 2>/dev/null | grep -oE '\+CPMS: "[A-Z]+", [0-9]+' | grep -oE '[0-9]+$')
    case "$N" in ''|*[!0-9]*) N=0;; esac
    [ "$N" -gt 30 ] && N=30
    OUT=""
    i=1
    while [ "$i" -le "$N" ]; do
        OUT="$OUT+IDX: $i
$(mipc_wan_cli --at_cmd "AT+CMGR=$i" 2>/dev/null)
"
        i=$((i+1))
    done
    mipc_wan_cli --at_cmd "AT+CMGF=0" >/dev/null 2>&1
    # +IDX: <i> 块内 +CMGR: "stat","<oa>",[...],"<time>"\n<text>
    echo "$OUT" | awk '
function h2d(c){ return index("0123456789ABCDEF", c)-1 }
function esc(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); gsub(/[\r\n\t]/," ",s); return s }
function dec(h,  i,cp,b1,b2,b3,o){
  o=""; h=toupper(h)
  for(i=1;i+3<=length(h);i+=4){
    cp=h2d(substr(h,i,1))*4096+h2d(substr(h,i+1,1))*256+h2d(substr(h,i+2,1))*16+h2d(substr(h,i+3,1))
    if(cp<128) o=o sprintf("%c",cp)
    else if(cp<2048){ b1=192+int(cp/64); b2=128+cp%64; o=o sprintf("%c%c",b1,b2) }
    else { b1=224+int(cp/4096); b2=128+int(cp/64)%64; b3=128+cp%64; o=o sprintf("%c%c%c",b1,b2,b3) }
  }
  return o
}
BEGIN{ n=0; cidx="?" }
/^\+IDX: /{
  gsub(/\r/,"")
  cidx=$0; sub(/^\+IDX: /,"",cidx)
}
/^\+CMGR: /{
  gsub(/\r/,"")
  idx=cidx
  # CMGR 行无 CMGL 的索引字段: [stat],[oa],[pid/dcs],[time] — 剥一层取 oa(v2.53 修补:
  # 原双剥继承自 CMGL 格式, 多剥一层 = from 列恒空)
  oa=$0; sub(/^[^,]*,/,"",oa); sub(/,.*/,"",oa); gsub(/"/,"",oa)
  tm=$0; sub(/^.*,/,"",tm); gsub(/"/,"",tm)
  getline raw; gsub(/\r/,"",raw)
  if(raw == "" || raw ~ /^(AT response|OK|\+CMS|\+CME)/) next   # 洞位/错误块
  ref=""; body=raw
  if(body ~ /^050003/ && length(body) >= 12){
    ref=substr(body,7,4)
    k=oa "|" ref
    if(k in txt){ txt[k]=txt[k] substr(body,13); next }
    body=substr(body,13)
  } else k="i" idx
  order[++n]=k; koa[k]=oa; ktm[k]=tm; kidx[k]=idx
  txt[k]=body
}
END{
  for(i=1;i<=n;i++){ k=order[i]
    h=txt[k]
    if(h ~ /^[0-9A-Fa-f]+$/ && length(h)%2==0 && length(h)>=4) t=dec(h); else t=h
    printf "{\"idx\":\"%s\",\"from\":\"%s\",\"time\":\"%s\",\"text\":\"%s\"},", kidx[k], koa[k], ktm[k], esc(t)
  }
}' > /tmp/sms.$$
    L=$(sed 's/,$//' /tmp/sms.$$); rm -f /tmp/sms.$$
    N=$(printf '%s' "$L" | grep -o '"idx"' | wc -l)
    printf '{"msgs":[%s],"count":%d,"send_supported":true,"ts":%d}' "$L" "$N" "$(date +%s)"
}

apply_sms_send() {
    NUM=$(form_kv num); TXT=$(form_kv text)
    printf '%s' "$NUM" | grep -qE '^\+?[0-9]{5,20}$' || jerr bad_num
    [ -n "$TXT" ] || jerr empty_text
    # v1.1 (RIL 清零轮): 发送走 AT 路线 — 与厂商 ql_sms_send_msg 同族
    #   (反汇编 §12.5: 服务端拼 AT+EMGS 经 AT 通道发出), 现由 mipc_wan_cli
    #   --at_cmd 直接下发(atcid 通道, 与 ql_ril_service 无关)。
    #   前置序列照抄厂商: CMGF=1 文本模式; 中文 CSCS="UCS2"(内容为 UCS2-BE hex);
    #   CSMP DCS=241(fmt0/1) / 25(UCS2)。发毕还原 CMGF=0(留在 PDU 模式)。
    case "$TXT" in
      ucs2:*)
        H=${TXT#ucs2:}
        echo "$H" | grep -qE '^[0-9a-fA-F]{4,560}$' || jerr bad_ucs2
        mipc_wan_cli --at_cmd "AT+CMGF=1" >/dev/null 2>&1
        mipc_wan_cli --at_cmd "AT+CSCS=\"UCS2\"" >/dev/null 2>&1
        mipc_wan_cli --at_cmd "AT+CSMP=37,71,0,25" >/dev/null 2>&1
        R=$(mipc_wan_cli --at_cmd "AT+EMGS=\"$NUM\",\"$H\"" 2>&1) ;;
      *)
        printf '%s' "$TXT" | grep -qE '[^ -~]' && jerr need_ucs2
        [ ${#TXT} -gt 480 ] && jerr too_long
        case "$TXT" in *'"'*) jerr bad_chars ;; esac   # 引号破坏 AT 参数结构
        mipc_wan_cli --at_cmd "AT+CMGF=1" >/dev/null 2>&1
        mipc_wan_cli --at_cmd "AT+CSCS=\"GSM\"" >/dev/null 2>&1
        mipc_wan_cli --at_cmd "AT+CSMP=37,71,0,241" >/dev/null 2>&1
        R=$(mipc_wan_cli --at_cmd "AT+EMGS=\"$NUM\",\"$TXT\"" 2>&1) ;;
    esac
    mipc_wan_cli --at_cmd "AT+CMGF=0" >/dev/null 2>&1   # 厂商同款收尾(回 PDU 模式)
    _ntail=$(printf '%s' "$NUM" | tail -c 4)
    if printf '%s' "$R" | grep -qi 'ERROR' || ! printf '%s' "$R" | grep -qi 'OK'; then
        # 失败留原始响应(截断) — 模组错误码是唯一线索; 号码只留末4位
        alog "WARN sms send failed num=***${_ntail} len=${#TXT} resp=$(printf '%s' "$R" | tr '\n' ' ' | head -c 160)"
        jerr send_fail
    fi
    alog "INFO sms send ok num=***${_ntail} len=${#TXT} route=at"
    ok_json '"via":"at-emgs"'
}
