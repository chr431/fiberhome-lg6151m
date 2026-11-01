#!/bin/sh
# romount -- read-only mount helper for eMMC partitions (V5 reserve:
# offline forensics / evidence collection without any network path).
# Usage: romount <name> <major:minor> [fstype]
#   romount p26   179:26        # v4.x slot-A rootfs (squashfs, ro)
#   romount p46   259:14        # second eMMC partition (fs auto-tried)
#   romount data  179:6 ext4    # force fstype
# Device node /dev/ro_<name> is created on demand; mounts land on /mnt/ro-<name>.
# Known nodes from the project drill: p26=179:26, p1=179:1, p46=259:14.
NAME=${1:?usage: romount <name> <major:minor> [fstype]}
MM=${2:?usage: romount <name> <major:minor> [fstype]}
MAJ=${MM%%:*}
MIN=${MM##*:}
DEV="/dev/ro_$NAME"
rm -f "$DEV"
mknod "$DEV" b "$MAJ" "$MIN" 2>/dev/null || { echo "romount: mknod $DEV b $MAJ $MIN failed"; exit 1; }
MP="/mnt/ro-$NAME"
mkdir -p "$MP"
for fs in "${3:-}" squashfs ext4; do
    [ -n "$fs" ] || continue
    if mount -t "$fs" -o ro "$DEV" "$MP" 2>/dev/null; then
        echo "romount: $DEV (b $MAJ:$MIN) -> $MP [$fs, ro] OK"
        exit 0
    fi
done
echo "romount: mount failed for $DEV (b $MAJ:$MIN); tried: ${3:-squashfs} squashfs ext4"
exit 1
