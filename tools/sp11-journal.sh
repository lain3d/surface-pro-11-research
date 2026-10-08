#!/bin/bash
# Read the Surface's journals off the T7 from WSL, with no booted Linux.
#
# Run tools/sp11-disk.ps1 to-wsl first, then:
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-journal.sh [outdir]
#
# Three things here are not obvious and each one cost a round of failures:
#
#  1. Mount ro,noload. The filesystem is left dirty every time the disk drops,
#     and a plain read-only ext4 mount still *replays the journal*, which is a
#     write to the machine's root filesystem.
#
#  2. WSL's journalctl cannot read these journals. WSL is Ubuntu 22.04
#     (systemd 249); the Surface runs 26.04 (systemd 259) and its journal files
#     use features 249 rejects with "unsupported feature, ignoring file" - which
#     looks like corruption and is not.
#
#  3. So run the *target's own* journalctl. WSL is native aarch64, so its loader
#     can run it directly with --library-path; no chroot and no bind mounts.
#     libsystemd-shared-NNN.so lives under /usr/lib/aarch64-linux-gnu/systemd,
#     which is not a default search path - find it, don't hardcode the version.
set -u

OUT=${1:-/mnt/c/sp11-stage/logs}
M=/mnt/sp11root
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

mkdir -p "$OUT"

# ---- locate and mount ------------------------------------------------------
DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
if [ -z "$DEV" ]; then
    DEV=$(lsblk -rno NAME,FSTYPE,SIZE | awk '$2=="ext4" {print "/dev/"$1}' | tail -1)
    echo "root UUID not found; falling back to largest ext4: ${DEV:-none}"
fi
if [ -z "$DEV" ]; then
    echo "No ext4 filesystem visible."
    echo "Did you run:  tools\\sp11-disk.ps1 to-wsl ?"
    lsblk -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null
    exit 1
fi

mkdir -p "$M"
if mountpoint -q "$M"; then umount "$M" || true; fi
mount -o ro,noload "$DEV" "$M" || { echo "mount failed"; exit 1; }
echo "mounted $DEV at $M (ro,noload)"

# ---- the target's own journalctl -------------------------------------------
JC=$M/usr/bin/journalctl
LD=$(ls "$M"/lib/ld-linux-aarch64.so.1 "$M"/usr/lib/ld-linux-aarch64.so.1 2>/dev/null | head -1)
SHARED=$(dirname "$(find "$M/usr/lib" "$M/lib" -name 'libsystemd-shared-*.so' 2>/dev/null | head -1)")
LP="$M/usr/lib/aarch64-linux-gnu:$M/lib/aarch64-linux-gnu:$M/usr/lib:$M/lib:$SHARED"
J=$M/var/log/journal

[ -x "$JC" ] || { echo "no journalctl at $JC"; exit 1; }
[ -d "$J" ]  || { echo "no persistent journal at $J"; exit 1; }

jc() { "$LD" --library-path "$LP" "$JC" -D "$J" "$@"; }
jc --version 2>&1 | head -1 | sed 's/^/using /'

# ---- one row per boot ------------------------------------------------------
echo
printf '%4s  %-34s %-12s %-12s %s\n' BOOT KERNEL 'T7 SPEED' DRIVER REACHED
for b in $(seq -25 0); do
    t=$OUT/boot$b.txt
    jc -b "$b" --no-pager -o short-precise > "$t" 2>/dev/null || { rm -f "$t"; continue; }
    [ -s "$t" ] || { rm -f "$t"; continue; }

    kern=$(grep -m1 -oE 'Linux version [^ ]+' "$t" | sed 's/Linux version //')
    [ -n "$kern" ] || kern='?'

    # whichever usb device usb-storage or uas ends up claiming
    port=$(grep -m1 -oE '(usb-storage|uas) [0-9]+-[0-9.]+' "$t" | awk '{print $2}' | cut -d: -f1)
    speed='-'
    if [ -n "$port" ]; then
        speed=$(grep -m1 "usb $port: new" "$t" | grep -oE 'new [a-zA-Z-]+ USB' | sed 's/new //; s/ USB//')
        [ -n "$speed" ] || speed='?'
    fi

    if   grep -q 'scsi host[0-9]*: uas'          "$t"; then drv=uas
    elif grep -q 'scsi host[0-9]*: usb-storage'  "$t"; then drv=usb-storage
    else drv='-'; fi

    if   grep -q 'Reached target graphical.target\|Started GNOME Display Manager' "$t"; then reach='DESKTOP'
    elif grep -qE 'device offline|Aborting journal|EXT4-fs error'                 "$t"; then reach='disk died'
    else reach="ends at $(tail -1 "$t" | awk '{print $3}')"; fi

    printf '%4s  %-34s %-12s %-12s %s\n' "$b" "$kern" "$speed" "$drv" "$reach"
done

echo
echo "per-boot dumps in $OUT/boot<N>.txt"
echo
echo "NOTE: the journal lives on the disk that dies, so on a failing boot it"
echo "      stops at the last flush - the errors themselves are never written."
echo "      Those only exist on the console. Photograph, or use pstore."
echo
echo "when finished:  tools\\sp11-disk.ps1 to-win"
