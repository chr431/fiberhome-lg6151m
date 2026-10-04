#!/bin/sh
# mipc_dial_trace.sh — 5G dial forensics harness (the result-2 mystery).
#
# Problem (2026-10-01): manual mipc_wan_cli --data_call_act returns result 2
# while the netifd proto path once brought ccmni2 up for 0.2s — the exact
# argument/state delta was invisible. This harness:
#   1. install: wraps /lib/netifd/proto/{mipc,ql_mipc}.sh with set -x tracing
#      (originals kept as .orig) so the NEXT netifd ifup logs every command +
#      every JSON byte it sends to /tmp/proto_trace.log.
#   2. dial:  runs a fully logged manual dial attempt (radio/SIM/profile
#      before/after, deact-act with timing) to /tmp/mipc_dial_trace.log.
#   3. report: prints both logs' key lines.
# Observe-only for install; `dial` changes modem state (deact+act) — that is
# the point, with evidence.
LOG=/tmp/mipc_dial_trace.log
PROTO_LOG=/tmp/proto_trace.log
CMD_LOG=/tmp/proto_cmd.log

case "$1" in
install)
    # rootfs is squashfs(ro): direct writes silently fail -> tmpfs + bind-mount.
    # The wrapper must source a COPY: sourcing the mounted path would recurse.
    mkdir -p /tmp/protowrap
    for p in mipc ql_mipc; do
        f=/lib/netifd/proto/$p.sh
        o=/tmp/protowrap/$p.orig.sh
        w=/tmp/protowrap/$p.sh
        umount "$f" 2>/dev/null          # reveal pristine original first
        cp "$f" "$o"
        { echo '#!/bin/sh'
          echo "exec 2>>$CMD_LOG"      # ash set -x traces to stderr; capture it
          echo 'PS4="+ \$(date -u +%FT%TZ) "'
          echo 'set -x'
          echo ". $o \"\$@\""
        } > "$w"
        chmod +x "$w"
        mount -o bind "$w" "$f" && echo "wrapped $f (orig copy: $o)"
    done
    echo "next: ifup wan under netifd; then read $CMD_LOG"
    ;;
restore)
    for p in mipc ql_mipc; do
        umount /lib/netifd/proto/$p.sh 2>/dev/null && echo "unmounted $p"
    done
    ;;
dial)
    {
    echo "==== mipc dial trace $(date -u +%FT%TZ)"
    echo "-- radio/SIM --"
    ql_datacall -n; ql_datacall -G; ql_datacall -o; ql_datacall -b
    echo "-- contexts before --"
    mipc_wan_cli --at_cmd "AT+CGDCONT?"
    echo "-- profile db --"
    mipc_wan_cli --apn_profile_get
    echo "-- deact --"
    time mipc_wan_cli --data_call_deact_apn cbnet 1
    sleep 2
    echo "-- act_type (mipc.sh form) --"
    time mipc_wan_cli --data_call_act_type '{"apn":"cbnet","apn_type":0,"ip_type":3,"roaming_type":3,"auth_type":0,"username":"","password":"","bearer_bitmask":"","mtu":1400,"mode":0}' 1
    sleep 3
    echo "-- act (ql_mipc.sh form) --"
    time mipc_wan_cli --data_call_act '{"apn":"cbnet","ip_type":3,"roaming_type":3,"auth_type":0,"username":"","password":"","bearer_bitmask":"","mtu":1400,"mode":0}'
    sleep 2
    echo "-- after --"
    mipc_wan_cli --at_cmd "AT+CGDCONT?"
    mipc_wan_cli --apn_profile_get
    ip -o addr show | grep ccmni
    echo "==== end"
    } >> "$LOG" 2>&1
    tail -30 "$LOG"
    ;;
report)
    echo "==== $CMD_LOG (netifd proto commands)"; tail -30 "$CMD_LOG" 2>/dev/null
    echo "==== $LOG (manual dials)"; tail -20 "$LOG" 2>/dev/null
    ;;
*)
    echo "usage: $0 {install|restore|dial|report}"
    echo "  install = instrument netifd proto scripts (needs writable overlay)"
    echo "  dial    = fully-logged manual dial attempt (changes modem state)"
    ;;
esac
