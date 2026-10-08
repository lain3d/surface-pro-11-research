#!/bin/bash
# Install a single freshly-built module onto the T7, keeping a backup.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -u root env KO=drivers/thunderbolt/thunderbolt.ko \
#       bash tools/sp11-install-one-module.sh
#   tools\sp11-disk.ps1 to-win
#
# The T7's tree is .ko.zst, so the module has to be compressed on the way in;
# an uncompressed .ko sitting next to a stale .ko.zst is silently ignored by
# modprobe, which looks exactly like the patch not working.
#
# vermagic is checked against the target tree before anything is written. A
# mismatch there is the difference between "the experiment failed" and "the
# module never loaded", and that distinction has cost this project boots before.
#
# By default this only REPLACES a module that is already installed, because
# "the file is already there" is the strongest available evidence that the
# destination path is the right one. A module newly enabled in the config has no
# such evidence, so installing one needs NEW=1:
#
#   wsl -u root env NEW=1 KO=drivers/media/i2c/imx681.ko \
#       bash tools/sp11-install-one-module.sh
#
# NEW=1 mirrors the module's path inside the worktree under the target tree's
# kernel/ directory, and refuses if that directory does not already exist -- so a
# typo in KO still cannot scatter modules into places modprobe will not look.
set -eu

W=${W:-/root/sp11/wt-cfg}
KO=${KO:?set KO to the module path, relative to the worktree}
M=/mnt/sp11root
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

SRC="$W/$KO"
[ -f "$SRC" ] || { echo "no such module: $SRC"; exit 1; }

command -v zstd >/dev/null || { echo "zstd not installed in WSL: apt-get install -y zstd"; exit 1; }

DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }

mkdir -p "$M"
mountpoint -q "$M" && umount "$M"
mount "$DEV" "$M"
trap 'sync; umount "$M" 2>/dev/null || true' EXIT
[ -d "$M/home/lain" ] || { echo "wrong filesystem"; exit 1; }

# Derive the target tree from the MODULE, not from whatever sorts first under
# /lib/modules. This disk carries the stock 7.0.0-22-qcom-x1e tree alongside
# ours, and "the first one ls prints" is the stock one - which is how the first
# version of this script tried to install an SP11 module into the stock kernel.
SRCMAGIC=$(modinfo "$SRC" | awk '/^vermagic:/ {print $2}')
KVER=$SRCMAGIC
echo "=== module vermagic: $SRCMAGIC ==="
echo "    trees present: $(cd "$M/lib/modules" && echo */ | tr -d '/')"
[ -d "$M/lib/modules/$KVER" ] || {
    echo "REFUSING: no /lib/modules/$KVER on the target disk"; exit 1; }
echo "    target tree exists: /lib/modules/$KVER"

BASE=$(basename "$KO")
DEST=$(find "$M/lib/modules/$KVER" -name "$BASE.zst" -o -name "$BASE" | head -1)

if [ -z "$DEST" ]; then
    [ "${NEW:-0}" = 1 ] || {
        echo "REFUSING: $BASE is not already installed in the target tree"
        echo "          (if it is newly enabled in the config, pass NEW=1)"; exit 1; }

    # Mirror the worktree path under kernel/. The directory must already exist:
    # every module in this tree lives beside its siblings, so a KO whose parent
    # is missing means the path is wrong, not that a new directory is needed.
    DESTDIR="$M/lib/modules/$KVER/kernel/$(dirname "$KO")"
    [ -d "$DESTDIR" ] || {
        echo "REFUSING: ${DESTDIR#$M} does not exist on the target disk"; exit 1; }

    # Match the compression its siblings use rather than assuming .zst.
    if ls "$DESTDIR"/*.ko.zst >/dev/null 2>&1; then
        DEST="$DESTDIR/$BASE.zst"
    elif ls "$DESTDIR"/*.ko >/dev/null 2>&1; then
        DEST="$DESTDIR/$BASE"
    else
        echo "REFUSING: no modules in ${DESTDIR#$M} to infer compression from"; exit 1
    fi
    echo "=== installing NEW module: ${DEST#$M} ==="
else
    echo "=== replacing: ${DEST#$M} ==="
fi

if [ ! -f "$DEST" ]; then
    # New module: there is nothing to back up, and creating an empty .orig would
    # later look like a stock module worth restoring. Removing the .ko is the
    # rollback.
    echo "    new file, nothing to back up"
elif [ ! -f "$DEST.orig" ]; then
    cp -a "$DEST" "$DEST.orig"
    echo "    backup saved as $(basename "$DEST").orig"
else
    echo "    backup already exists, leaving it alone"
fi

case "$DEST" in
    *.zst) zstd -q -f -19 "$SRC" -o "$DEST" ;;
    *)     cp "$SRC" "$DEST" ;;
esac
chmod 644 "$DEST"

echo "=== depmod ==="
depmod -b "$M" "$KVER"

echo "=== verify what landed ==="
ls -la "$DEST" "$DEST.orig" 2>/dev/null || ls -la "$DEST"
zstd -dc "$DEST" 2>/dev/null > /tmp/check.ko || cp "$DEST" /tmp/check.ko
modinfo /tmp/check.ko | grep -E "^vermagic|^parm:" | head -20
