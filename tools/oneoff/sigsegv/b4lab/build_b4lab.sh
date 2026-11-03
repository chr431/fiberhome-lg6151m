#!/bin/sh
# build_b4lab.sh -- bake v4.2-b4lab p26 lab images (OFFLINE, PC side, no device).
# MUST run inside WSL as root (needs unsquashfs/mksquashfs 4.6.1 + mknod):
#   wsl -d Ubuntu-24.04 -u root -e sh /mnt/d/Repo/lg6151m-project/lg6151m-public/tools/oneoff/sigsegv/b4lab/build_b4lab.sh
#
# Base  : rootfs_v41.squashfs reference (md5 dec55b3722e95074722dc1761752f0ab,
#         the deploy2r/C2R-RoundA pinned asset). Pipeline proven byte-exact:
#         unsquashfs -> mksquashfs(comp xz,b 262144,no-xattrs,all-root,
#         -mkfs-time 1791112113) reproduces dec55b37... exactly, so every
#         byte of diff below comes from the intentional edits only.
# Edits : (1) sbin/babysit.sh v2 -> v3.2 image build (enabler hook prefers
#             /sbin/mod_mask.sh; hook after getty parachute; armed v3.2)
#         (2) sbin/mod_mask.sh v1.1 NEW (mask via temp ro-mount of
#             user_data p46; bind-mask modules.d; rmmod boot.d passthrough
#             = B4b no-warp channel; fail-open)
#         (3) etc/b4lab_id NEW (image identity marker for bench checks)
#         NOTHING else changes; /etc/preinit is left byte-identical (its
#         existing /sbin/babysit.sh elif branch IS the injection point).
# Variant: rootfs_b4lab_nowarp.squashfs = same tree minus
#          etc/modules-boot.d/60-warp + etc/modules.d/60-warp (structural
#          fallback if the rmmod channel fails on device).
# Outputs (to this dir): rootfs_b4lab.squashfs, rootfs_b4lab_nowarp.squashfs,
#          DIFF-manifest.txt, BUILD.log
set -eu

D=/mnt/d/Repo/lg6151m-project/lg6151m-public/tools/oneoff/sigsegv/b4lab
REF=/mnt/d/Repo/lg6151m-project/_local/investigations/sigsegv-tools/phase-AB/c2r-serial/depot/rootfs_v41.squashfs
REF_WANT=dec55b3722e95074722dc1761752f0ab
TS=1793626200            # pinned mkfs/mtime (2026-11-02 21:30 +0800) => reruns byte-identical
W=/root/b4lab_build
LOG=$D/BUILD.log

md5s() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }
say()  { echo "[b4lab] $*" | tee -a "$LOG"; }

: > "$LOG"
say "start $(date -u '+%F %T') UTC"

# --- 0. reference gate ------------------------------------------------------
[ "$(md5s "$REF")" = "$REF_WANT" ] || { say "FATAL: reference md5 mismatch"; exit 1; }
say "reference md5 OK ($REF_WANT)"

rm -rf "$W"
mkdir -p "$W"
unsquashfs -d "$W/ref" -processors 4 -no-progress "$REF" > "$W/unsq.log" 2>&1
cp -a "$W/ref" "$W/tree"
say "extracted reference tree: $(find "$W/ref" -type f | wc -l) files"

# --- 1. install edits --------------------------------------------------------
for f in sbin_babysit_v32.sh sbin_mod_mask_v11.sh; do
    sed -i 's/\r$//' "$D/$f"      # CRLF guard (files are LF, idempotent)
done
sh -n "$D/sbin_babysit_v32.sh"  && say "syntax OK: babysit v3.2"
sh -n "$D/sbin_mod_mask_v11.sh" && say "syntax OK: mod_mask v1.1"

install -m 0755 "$D/sbin_babysit_v32.sh" "$W/tree/sbin/babysit.sh"
install -m 0755 "$D/sbin_mod_mask_v11.sh" "$W/tree/sbin/mod_mask.sh"
touch -d @$TS "$W/tree/sbin/babysit.sh" "$W/tree/sbin/mod_mask.sh"

cat > "$W/tree/etc/b4lab_id" <<EOF
IMAGE=v4.2-b4lab
VARIANT=primary
BASE=rootfs_v41.squashfs
BASE_MD5=$REF_WANT
EDITS=sbin/babysit.sh=v3.2-image,sbin/mod_mask.sh=v1.1-image,etc/b4lab_id
WARP_CHANNEL=mask-line mtk_warp -> preinit rmmod + modules.d bind-mask
ENABLER_LOG=/tmp/ablation.log
BUILD_TS=$TS
EOF
touch -d @$TS "$W/tree/etc/b4lab_id"
# pin mtimes of edited files AND of directories whose mtime the edits touched
# (mksquashfs stores directory mtimes too; unpinned => non-reproducible md5)
touch -d @$TS "$W/tree/etc" "$W/tree/sbin"

# --- 2. tree assertions (static preinit reasoning inputs) --------------------
diff -q "$W/ref/etc/preinit" "$W/tree/etc/preinit" > /dev/null \
    || { say "FATAL: preinit changed (must stay byte-identical)"; exit 1; }
say "assert OK: /etc/preinit byte-identical to reference"
grep -q 'elif \[ -x /sbin/babysit.sh \]' "$W/tree/etc/preinit" \
    || { say "FATAL: preinit /sbin branch missing"; exit 1; }
[ -x "$W/tree/sbin/babysit.sh" ] || { say "FATAL: babysit.sh not executable"; exit 1; }
[ -x "$W/tree/sbin/mod_mask.sh" ] || { say "FATAL: mod_mask.sh not executable"; exit 1; }
grep -q 'armed v3.2' "$W/tree/sbin/babysit.sh" || { say "FATAL: v3.2 marker"; exit 1; }
grep -q '/sbin/mod_mask.sh' "$W/tree/sbin/babysit.sh" || { say "FATAL: image hook"; exit 1; }
grep -n 'mod_mask.sh' "$W/tree/sbin/babysit.sh" | head -1
awk '/console parachute/{p=NR} /\/sbin\/mod_mask.sh/{m=NR} END{exit(!(m>p))}' "$W/tree/sbin/babysit.sh" \
    && say "assert OK: mod_mask hook placed AFTER getty parachute"
[ "$(stat -c '%a' "$W/tree/sbin/babysit.sh")" = 755 ] || { say "FATAL: perm babysit"; exit 1; }
for m in 60-warp 59-mt_cfg80211 60-mt_wifi_cmn 61-mt_wifi7 62-mt_hwifi 63-connac_if 63-mtk_pci 64-mt7992 64-mtk_wed 70-hw_nat; do
    [ -e "$W/tree/etc/modules.d/$m" ] || { say "FATAL: modules.d/$m missing"; exit 1; }
done
say "assert OK: all 10 modules.d targets present"
[ -L "$W/tree/etc/modules-boot.d/60-warp" ] || { say "FATAL: boot.d/60-warp not symlink"; exit 1; }
say "assert OK: boot.d/60-warp symlink intact (primary variant)"

# --- 3. build primary image --------------------------------------------------
cd "$W"
rm -f rootfs_b4lab.squashfs
mksquashfs tree rootfs_b4lab.squashfs -comp xz -b 262144 -no-xattrs -noappend \
    -all-root -processors 4 -mkfs-time $TS -no-progress > mksq1.log 2>&1
say "primary image: $(wc -c < rootfs_b4lab.squashfs) bytes md5=$(md5s rootfs_b4lab.squashfs)"

# --- 4. nowarp variant --------------------------------------------------------
cp -a tree tree_nowarp
rm -f tree_nowarp/etc/modules-boot.d/60-warp tree_nowarp/etc/modules.d/60-warp
sed -i 's/^VARIANT=primary$/VARIANT=nowarp (modules-boot.d+modules.d 60-warp removed)/' tree_nowarp/etc/b4lab_id
touch -d @$TS tree_nowarp/etc tree_nowarp/etc/modules-boot.d tree_nowarp/etc/modules.d tree_nowarp/etc/b4lab_id
rm -f rootfs_b4lab_nowarp.squashfs
mksquashfs tree_nowarp rootfs_b4lab_nowarp.squashfs -comp xz -b 262144 -no-xattrs \
    -noappend -all-root -processors 4 -mkfs-time $TS -no-progress > mksq2.log 2>&1
say "nowarp image: $(wc -c < rootfs_b4lab_nowarp.squashfs) bytes md5=$(md5s rootfs_b4lab_nowarp.squashfs)"

# --- 5. round-trip verify both images ----------------------------------------
# GNU diff quirks to avoid: dangling symlinks error out, char devices report
# "is a character special file" even when identical. So: (a) diff -r with
# --no-dereference and /dev excluded; (b) compare device node maj:min+type;
# (c) compare the full permission/type map.
rt_verify() {
    t=$1; c=$2
    diff -r --no-dereference -x dev "$t" "$c" > rt.diff 2>&1 || { head -20 rt.diff; return 1; }
    find "$t/dev" \( -type b -o -type c \) -printf '%P %y %t:%T\n' | sort > rt.dev1
    ( cd "$c/dev" && find . \( -type b -o -type c \) -printf '%P %y %t:%T\n' | sort ) > rt.dev2
    cmp -s rt.dev1 rt.dev2 || { echo "device nodes differ:"; diff rt.dev1 rt.dev2; return 1; }
    ( cd "$t" && find . -printf '%m %y %P\n' | sort ) > rt.pm1
    ( cd "$c" && find . -printf '%m %y %P\n' | sort ) > rt.pm2
    cmp -s rt.pm1 rt.pm2 || { echo "perm/type map differs:"; diff rt.pm1 rt.pm2 | head -20; return 1; }
    return 0
}
for v in b4lab b4lab_nowarp; do
    unsquashfs -d "chk_$v" -processors 4 -no-progress "rootfs_$v.squashfs" > "unsq_$v.log" 2>&1
    if rt_verify "$([ "$v" = b4lab ] && echo tree || echo tree_nowarp)" "chk_$v"; then
        say "round-trip OK: $v (content + device nodes + perm map == built tree)"
    else
        say "FATAL: round-trip verify $v failed"; exit 1
    fi
done
# spot-verify from the IMAGE (not the tree): executable bits + hook content
[ -x chk_b4lab/sbin/babysit.sh ] && [ -x chk_b4lab/sbin/mod_mask.sh ] \
    && say "image OK: sbin scripts executable in unpacked image"
grep -q 'rmmod' chk_b4lab/sbin/mod_mask.sh && grep -q 'mm_data' chk_b4lab/sbin/mod_mask.sh \
    && say "image OK: mod_mask v1.1 temp-mount+rmmod logic present in image"
[ ! -e chk_b4lab_nowarp/etc/modules.d/60-warp ] && [ ! -e chk_b4lab_nowarp/etc/modules-boot.d/60-warp ] \
    && say "image OK: nowarp variant has no 60-warp anywhere"

# --- 6. diff manifest vs reference -------------------------------------------
{
  echo "# v4.2-b4lab vs rootfs_v41 reference -- content diff (diff -r --no-dereference)"
  echo "# /dev excluded (device nodes byte-identical to reference: never touched);"
  echo "# dangling symlinks compared by target text via --no-dereference."
  echo "# generated $(date -u '+%F %T') UTC by build_b4lab.sh"
  echo
  echo "## primary variant"
  diff -r --no-dereference -x dev ref tree || true
  echo
  echo "## nowarp variant (relative to primary tree)"
  diff -r --no-dereference -x dev tree tree_nowarp || true
} > "$D/DIFF-manifest.txt"
say "diff manifest written"

# --- 7. ship artifacts ---------------------------------------------------------
cp rootfs_b4lab.squashfs rootfs_b4lab_nowarp.squashfs "$D/"
{
  echo "rootfs_b4lab.squashfs         $(wc -c < rootfs_b4lab.squashfs) bytes  md5=$(md5s rootfs_b4lab.squashfs)"
  echo "rootfs_b4lab_nowarp.squashfs  $(wc -c < rootfs_b4lab_nowarp.squashfs) bytes  md5=$(md5s rootfs_b4lab_nowarp.squashfs)"
} | tee -a "$LOG"
say "DONE"
