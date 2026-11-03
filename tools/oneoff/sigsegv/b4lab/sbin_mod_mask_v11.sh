#!/bin/sh
# mod_mask.sh v1.1 (image build) -- B4/B4b module-load mask, image copy at
# /sbin/mod_mask.sh, started by /sbin/babysit.sh v3.2 at /etc/preinit time,
# BEFORE the rcS kmodloader wave loads /etc/modules.d (~21s after power-on).
#
# Plain busybox sh only (pre-init env, no OpenWrt functions sourced).
#
# Mask file: /data/gw/ablation.mask -- one module name per line ('#'
# comments and blank lines ignored). /data is NOT mounted at preinit on
# this image chain (mounted later by rcS S000mount_all), so v1.1 reads the
# mask via a temporary READ-ONLY mount of the user_data partition
# (mmcblk0p46) at /tmp/mm_data and unmounts immediately after the read.
# The /data mountpoint itself is never touched by this script. If /data is
# already mounted (other boot chains), the mask is read directly.
#
# Actions per masked name:
#   1. every /etc/modules.d/* file whose first token matches -> bind-mount
#      an empty file over it, so the ~21s kmodloader wave skips the entry
#      (same primitive as the rc.extend /etc/shadow override);
#   2. if the name is ALREADY loaded at preinit time (it came from
#      /etc/modules-boot.d, which loads BEFORE preinit -- only path today
#      is mtk_warp via 60-warp), it is removed with /sbin/rmmod. rmmod runs
#      AFTER all bind masks are in place: a hung module-exit must not block
#      masking. The modules.d bind mask from (1) prevents reload at ~21s.
#      This is the B4b "no-warp" channel: mask line 'mtk_warp'.
#
# Fail-open policy: any error reading the mask (partition missing, mount
# failed, no mask file) => silent normal boot, zero behavior change. Arm
# validity is then caught by the runbook's mask-verification step.
#
# Empty/absent mask file => no-op (normal boot, zero behavior change).
# Log: /dev/console + /tmp/ablation.log (preinit /data is absent);
# /data/gw/logs/ablation.log is also appended once that dir exists.

UDATA_BLK=/dev/block/user_data
UDATA_MC=/dev/mmcblk0p46
MMP=/tmp/mm_data
MASK_READ=/tmp/b4lab.mask
EMPTY=/tmp/.mask_empty
MDIR=/etc/modules.d
TMPLOG=/tmp/ablation.log

mm_log() {
    echo "mod_mask: $*" > /dev/console 2>&1
    echo "$(date '+%Y-%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime 2>/dev/null) $*" >> $TMPLOG 2>/dev/null
    [ -d /data/gw/logs ] && echo "$(date '+%Y-%m-%d %H:%M:%S') up=$(cut -d. -f1 /proc/uptime 2>/dev/null) $*" >> /data/gw/logs/ablation.log 2>/dev/null
}

# --- 1. obtain the mask content (fail-open) --------------------------------
MASKSRC=
if grep -q ' /data ' /proc/mounts 2>/dev/null && [ -f /data/gw/ablation.mask ]; then
    MASKSRC=/data/gw/ablation.mask
    mm_log "mask source: /data (already mounted)"
else
    DEVS=
    [ -b "$UDATA_BLK" ] && DEVS=$UDATA_BLK
    [ -z "$DEVS" ] && [ -b "$UDATA_MC" ] && DEVS=$UDATA_MC
    if [ -z "$DEVS" ] && [ -r /sys/class/block/mmcblk0p46/dev ]; then
        majmin=$(cat /sys/class/block/mmcblk0p46/dev)
        maj=${majmin%%:*}
        min=${majmin##*:}
        case "$maj$min" in *[!0-9:]*) maj=; min= ;; esac
        if [ -n "$maj" ] && [ -n "$min" ]; then
            mkdir -p /tmp/b4lab 2>/dev/null
            rm -f /tmp/b4lab/user_data 2>/dev/null
            mknod /tmp/b4lab/user_data b "$maj" "$min" 2>/dev/null && DEVS=/tmp/b4lab/user_data
        fi
    fi
    if [ -n "$DEVS" ]; then
        mkdir -p $MMP 2>/dev/null
        if ! grep -q ext4 /proc/filesystems 2>/dev/null; then
            /sbin/modprobe ext4 >/dev/null 2>&1
        fi
        if mount -t ext4 -o ro "$DEVS" $MMP 2>/dev/null; then
            if [ -f $MMP/gw/ablation.mask ]; then
                if cp $MMP/gw/ablation.mask $MASK_READ 2>/dev/null; then
                    MASKSRC=$MASK_READ
                    mm_log "mask source: temp ro-mount $DEVS"
                else
                    mm_log "WARN mask copy failed from $DEVS"
                fi
            else
                mm_log "no /gw/ablation.mask on $DEVS (neutral boot)"
            fi
            umount $MMP 2>/dev/null
        else
            mm_log "WARN temp ro-mount failed: $DEVS (neutral boot)"
        fi
        rmdir $MMP 2>/dev/null
    else
        mm_log "WARN user_data device not found (neutral boot)"
    fi
fi
[ -n "$MASKSRC" ] || exit 0
[ -s "$MASKSRC" ] || { mm_log "mask file empty (neutral boot)"; exit 0; }
[ -d "$MDIR" ] || { mm_log "FATAL no $MDIR"; exit 1; }
: > "$EMPTY" 2>/dev/null || { mm_log "FATAL cannot write $EMPTY"; exit 1; }

# --- 2. bind-mask /etc/modules.d entries (v1.0 logic) -----------------------
n=0
RMODS=
for name in $(grep -v '^#' "$MASKSRC" | grep -v '^[[:space:]]*$' | cut -d'#' -f1); do
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
    # boot.d passthrough candidate (v1.1): already loaded at preinit?
    if grep -q "^$name " /proc/modules 2>/dev/null; then
        RMODS="$RMODS $name"
    fi
done

# --- 3. remove boot.d-loaded instances LAST (v1.1, B4b warp channel) -------
r=0
for name in $RMODS; do
    if /sbin/rmmod "$name" 2>/dev/null; then
        i=0
        while [ $i -lt 5 ]; do
            grep -q "^$name " /proc/modules 2>/dev/null || break
            sleep 1
            i=$((i+1))
        done
        if grep -q "^$name " /proc/modules 2>/dev/null; then
            mm_log "ERROR rmmod $name: still loaded after 5s"
        else
            mm_log "rmmod ok: $name (boot.d passthrough removed)"
            r=$((r+1))
        fi
    else
        mm_log "ERROR rmmod $name: rmmod call failed"
    fi
done

mm_log "done masked_entries=$n rmmoded=$r names='$RMODS' boot=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
exit 0
