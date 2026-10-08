#!/bin/bash
# fsck the T7's root filesystem using the TARGET'S OWN e2fsck, from WSL.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-fsck.sh [-y]
#   tools\sp11-disk.ps1 to-win
#
# WSL is Ubuntu 22.04 with e2fsprogs 1.46.5. The T7 was made by 26.04 and its
# root filesystem has orphan_file, which 1.46.5 rejects outright:
#     has unsupported feature(s): FEATURE_C12 FEATURE_R16
#     e2fsck: Get a newer version of e2fsck!
# Running it anyway would let a tool modify metadata whose features it does not
# understand. So use the disk's own 1.47+ binary, the same way sp11-journal.sh
# runs the target's journalctl: WSL is native aarch64, so the target's loader
# can run the target's binary with --library-path. No chroot, no downloads.
#
# THE EXTRA WRINKLE, versus journalctl: e2fsck lives ON the filesystem it is
# checking, and a filesystem cannot be checked while mounted. So stage the
# binary and every library it needs onto WSL's own disk FIRST, unmount, and run
# the staged copy. Same shape as staging bash into tmpfs before killing the
# disk under it.
set -eu

MODE=${1:--p}          # -p preen by default; pass -y to auto-answer a full check
M=/mnt/sp11root
STAGE=/tmp/sp11-e2fsck
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }
echo "=== device: $DEV ==="

mkdir -p "$M"
mountpoint -q "$M" || mount -o ro,noload "$DEV" "$M"

LD=$(ls "$M"/lib/ld-linux-aarch64.so.1 "$M"/usr/lib/ld-linux-aarch64.so.1 2>/dev/null | head -1)
[ -n "$LD" ] || { echo "no loader on the target"; exit 1; }
FSCK=$(ls "$M"/usr/sbin/e2fsck "$M"/sbin/e2fsck 2>/dev/null | head -1)
[ -n "$FSCK" ] || { echo "no e2fsck on the target"; exit 1; }
LP="$M/lib/aarch64-linux-gnu:$M/usr/lib/aarch64-linux-gnu:$M/lib:$M/usr/lib"

echo "=== target e2fsck: ${FSCK#$M} ==="
"$LD" --library-path "$LP" "$FSCK" -V 2>&1 | head -1

# ---- stage the binary and its libraries onto WSL's own disk -----------------
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp "$LD" "$STAGE/ld.so"
cp "$FSCK" "$STAGE/e2fsck"
"$LD" --library-path "$LP" --list "$FSCK" |
    awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) {print $i; break}}' |
    sort -u | while read -r lib; do
        [ -f "$lib" ] && cp -L "$lib" "$STAGE/" || true
    done
echo "=== staged $(ls -1 "$STAGE" | wc -l) files to $STAGE ==="

# ---- the filesystem must be unmounted for the check ------------------------
umount "$M"
sync

echo "=== running the target's e2fsck ($MODE) ==="
set +e
"$STAGE/ld.so" --library-path "$STAGE" "$STAGE/e2fsck" -f "$MODE" "$DEV"
rc=$?
set -e
echo "=== e2fsck exit $rc ==="
# 0 clean, 1 errors corrected, 2 corrected+reboot, 4 uncorrected, 8 op error
case "$rc" in
    0) echo "  filesystem is clean" ;;
    1|2) echo "  errors were CORRECTED" ;;
    4) echo "  errors LEFT UNCORRECTED - re-run with -y" ;;
    *) echo "  e2fsck could not complete" ;;
esac

# ---- prove the things we care about survived -------------------------------
mount -o ro "$DEV" "$M"
echo "=== post-check sanity ==="
ls -d "$M/lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89" 2>/dev/null && echo "  module tree present"
ls -1 "$M/lib/firmware/qcom/x1e80100/microsoft/Denali/" 2>/dev/null | grep -i adsp8380 || true
umount "$M"
echo "done - now run: tools\\sp11-disk.ps1 to-win"
