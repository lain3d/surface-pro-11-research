#!/usr/bin/env bash
# Report the base ISO's layout so the remaster step can be written against
# what is actually there.
#
# Modern Ubuntu desktop images are not a single casper/filesystem.squashfs -
# they use layered squashfs (minimal / minimal.standard / .live) and a
# provisioning flow, so the remaster has to target the right layer.
set -euo pipefail

WORK="${WORK:-/root/sp11}"
ISO="${ISO:-$WORK/base.iso}"
MNT="$WORK/iso-mnt"

[ -f "$ISO" ] || { echo "missing ISO: $ISO"; exit 1; }

echo "== ISO =="
ls -la "$ISO"
file "$ISO" | head -2

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o loop,ro "$ISO" "$MNT"

echo
echo "== top level =="
ls -la "$MNT"

echo
echo "== .disk metadata =="
for f in "$MNT"/.disk/*; do [ -f "$f" ] && printf '  %-20s %s\n' "$(basename "$f")" "$(head -c 200 "$f")"; done

echo
echo "== casper / live payload =="
ls -la "$MNT"/casper 2>/dev/null || echo "  (no casper dir)"

echo
echo "== squashfs layers =="
find "$MNT" -name '*.squashfs' -printf '  %p  %s bytes\n' 2>/dev/null

echo
echo "== EFI boot =="
find "$MNT"/EFI "$MNT"/boot -maxdepth 3 -type f 2>/dev/null | head -20

echo
echo "== kernel + initrd =="
find "$MNT" -maxdepth 2 \( -name 'vmlinuz*' -o -name 'initrd*' \) -printf '  %p  %s bytes\n' 2>/dev/null

echo
echo "== device trees present? =="
find "$MNT" -name '*.dtb' 2>/dev/null | head -10
find "$MNT" -path '*dtb*' -maxdepth 3 -type d 2>/dev/null | head -5

echo
echo "== El Torito / boot image structure (for rebuilding) =="
xorriso -indev "$ISO" -report_el_torito plain 2>/dev/null | head -20

echo
echo "(leaving $MNT mounted; umount when done)"
