#!/bin/bash
# Push the sp11 helper scripts from this repo onto the Surface's root filesystem,
# to BOTH places they live, and prove afterwards that no stale copy survives.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-sync-scripts.sh
#   tools\sp11-disk.ps1 to-win
#
# Why a script rather than a cp: these files exist twice on the target, once in
# /usr/local/sbin (what you run) and once in the surface-pro-11-linux checkout
# (what gets committed). Updating one and not the other has already happened
# twice, and the first time it left the *broken* version under the shorter name.
# Anything worth copying is worth copying to both, and worth auditing after.
set -u

M=/mnt/sp11root
UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
REPO=${REPO:-/mnt/c/Users/Crazy/projs/arm64-egpu/tools}
CHECKOUT=home/lain/surface/surface-pro-11-linux/scripts

# repo file            -> /usr/local/sbin name   : checkout name
MAP="
sp11-portwatch.sh            sp11-portwatch            sp11-portwatch.sh
sp11-portwatch-unbindfirst.sh sp11-portwatch-unbindfirst sp11-portwatch-unbindfirst.sh
sp11-adsp-initramfs-boot.sh  sp11-adsp                 sp11-adsp-initramfs-boot.sh
sp11-try-altmode.sh          sp11-try-altmode          sp11-try-altmode.sh
sp11-collect.sh              sp11-collect              sp11-collect.sh
"

mountpoint -q "$M" 2>/dev/null && umount "$M"
mkdir -p "$M"
DEV=$(blkid -U "$UUID") || { echo "root not visible - run sp11-disk.ps1 to-wsl"; exit 1; }
mount -o rw "$DEV" "$M" || { echo "mount rw failed"; exit 1; }
trap 'sync; umount "$M" 2>/dev/null && echo "unmounted"' EXIT
[ -f "$M/etc/os-release" ] && [ -d "$M/lib/firmware" ] || { echo "not the root fs - refusing"; exit 1; }

mkdir -p "$M/usr/local/sbin"

echo "$MAP" | while read -r src sbin chk; do
    [ -n "$src" ] || continue
    [ -f "$REPO/$src" ] || { echo "MISSING $REPO/$src"; continue; }

    for dest in "$M/usr/local/sbin/$sbin" "$M/$CHECKOUT/$chk"; do
        d=${dest%/*}
        [ -d "$d" ] || continue
        cp "$REPO/$src" "$dest"
        sed -i 's/\r$//' "$dest"
        chmod 755 "$dest"
        case "$dest" in *"$CHECKOUT"*) chown 1000:1000 "$dest" 2>/dev/null ;; esac
        echo "  -> ${dest#$M}"
    done
done

echo
echo "=== audit: every copy on the disk, with size ==="
find "$M" -xdev \( -name 'sp11-portwatch*' -o -name 'sp11-adsp*' \
                   -o -name 'sp11-try-altmode*' -o -name 'sp11-collect*' \) 2>/dev/null |
    while read -r f; do printf '  %6s  %s\n' "$(stat -c%s "$f")" "${f#$M}"; done

echo
echo "=== sizes should pair up; anything odd is a stale copy ==="
for s in sp11-portwatch.sh sp11-portwatch-unbindfirst.sh sp11-adsp-initramfs-boot.sh \
         sp11-try-altmode.sh sp11-collect.sh; do
    printf '  %-30s %s bytes in repo\n' "$s" "$(stat -c%s "$REPO/$s")"
done

echo
echo "Scripts land in /usr/local/sbin, which is on root's PATH but NOT on a"
echo "normal user's. Run them as: sudo sp11-try-altmode   (no ./, no .sh)"
