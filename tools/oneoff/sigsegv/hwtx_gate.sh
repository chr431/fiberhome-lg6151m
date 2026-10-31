#!/bin/sh
# hwtx_gate.sh -- WED/WDMA hardware-TX gate for the 32B-record SIGSEGV family.
#
# Lever: mtk_warp exposes a pure-software switch at /proc/warp_ctrl/warp1/ctrl.
#   "echo 0 0 > ctrl" -> HW_TX_EN=FALSE : warp_wlan_tx() returns 0 before
#   wifi_tx_tuple_add(), so mtk_wed takes its software TX fallback (ops->tx).
#   No module unload, no reboot, instant rollback.
#
# Static evidence (mtk_warp.ko, sha256 246dce79...8c37):
#   .text+0x5d6c  ctrl write handler: strb w20,[x22,#0xd31]  (no HW reg write)
#   .text+0x970   warp_wlan_tx: ldrb w0,[x19,#0xd31]; cbz w0 -> return 0
#   mtk_wed.ko 0x8b8 bl warp_wlan_tx ; 0x8bc cbz w0 -> fallback ops->[0x40]
#
# Usage:
#   hwtx_gate.sh status      # show current gate + WED TX MIBs
#   hwtx_gate.sh off         # disable HW TX (apply the lever)
#   hwtx_gate.sh on          # restore HW TX (rollback)
#   hwtx_gate.sh verify on|off   # assert state, exit 1 on mismatch
#
# NOTE: writes to the device must hold _local/device.lock (project rule).
CTRL=/proc/warp_ctrl/warp1/ctrl
TXD=/proc/warp_ctrl/warp1/tx

state() {
    sed -n 's/^HW_TX_EN[[:space:]]*:[[:space:]]*\(.*\)$/\1/p' "$CTRL" 2>/dev/null
}

case "$1" in
status)
    echo "HW_TX_EN: $(state)"
    grep -E 'WED_TX0_MIB|WED_TX1_MIB' "$TXD" 2>/dev/null
    ;;
off)
    echo 0 0 > "$CTRL" || { echo "write failed"; exit 1; }
    sleep 1
    echo "HW_TX_EN: $(state)"
    ;;
on)
    echo 0 1 > "$CTRL" || { echo "write failed"; exit 1; }
    sleep 1
    echo "HW_TX_EN: $(state)"
    ;;
verify)
    want=$(echo "$2" | tr 'a-z' 'A-Z')
    got=$(state)
    [ "$got" = "$want" ] && { echo "OK HW_TX_EN=$got"; exit 0; }
    echo "MISMATCH want=$want got=$got"; exit 1
    ;;
*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
