#!/bin/sh
# mod_mask.sh v1.0 -- B4 module-load mask (SIGSEGV ablation enabler).
# Runs from babysit v3.1 at /etc/preinit time, BEFORE procd's rcS scan loads
# /etc/modules.d via kmodloader (~21s). Plain busybox sh only (pre-init env,
# no OpenWrt functions sourced). Reads /data/gw/ablation.mask: one module
# name per line ('#' comments and blank lines ignored). For every
# /etc/modules.d/* file whose line's first token matches a masked name,
# bind-mounts an empty file over it so kmodloader skips the entry.
# Empty/absent mask file => no-op (normal boot, zero behavior change).
# NOTE: /etc/modules-boot.d/* loads BEFORE preinit (mtk_warp) -- entries
# there are NOT maskable by this hook; do not claim otherwise.
MASK=/data/gw/ablation.mask
EMPTY=/data/gw/.mask_empty
MDIR=/etc/modules.d
LOGF=/data/gw/logs/ablation.log
mm_log() {
    echo "mod_mask: $*" > /dev/console 2>&1
    [ -d /data/gw/logs ] && echo "$(date '+%Y-%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime 2>/dev/null) $*" >> "$LOGF" 2>/dev/null
}
[ -f "$MASK" ] || exit 0
[ -d "$MDIR" ] || { mm_log "FATAL no $MDIR"; exit 1; }
[ -f "$EMPTY" ] || : > "$EMPTY"
n=0
for name in $(grep -v '^#' "$MASK" | grep -v '^[[:space:]]*$' | cut -d'#' -f1); do
    hit=0
    for f in "$MDIR"/*; do
        [ -f "$f" ] || continue
        while IFS= read -r line; do
            case "$line" in \#*) continue ;; esac
            tok=${line%%[[:space:]]*}
            [ "$tok" = "$name" ] || continue
            if grep -q " $f " /proc/mounts 2>/dev/null || grep -q "	$f " /proc/mounts 2>/dev/null; then
                mm_log "already masked: $f"; hit=1; continue
            fi
            if mount -o bind "$EMPTY" "$f" 2>/dev/null; then
                mm_log "masked $name -> $f"; hit=1; n=$((n+1))
            else
                mm_log "ERROR bind failed: $f"
            fi
            break
        done < "$f"
    done
    [ "$hit" = 0 ] && mm_log "WARN no modules.d entry for: $name"
done
mm_log "done masked_entries=$n boot=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
exit 0
