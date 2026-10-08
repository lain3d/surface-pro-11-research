#!/usr/bin/env bash
# Build the bootable ISO from an already-prepared tree ($WORK/iso-tree).
#
# Split out from 04-remaster.sh so the boot structure can be iterated on without
# repeating the 4 GB rsync, the 2.9 GB unsquash and the 2.9 GB repack.
#
# Why the first attempt failed with "Cannot open data file for appended
# partition": on this image the EFI System Partition is NOT a file in the ISO
# tree. `xorriso -report_el_torito as_mkisofs` shows it is an *appended
# partition* carved out of a byte range of the original image:
#
#   -append_partition 2 28732ac11ff8d211ba4b00a0c93ec93b \
#       --interval:local_fs:7964672d-7976959d::base.iso
#   -e '--interval:appended_partition_2_start_1991168s_size_12288d:all::'
#
# so searching the tree for efi*.img was never going to find anything. We
# extract that range to a real file and append it ourselves.
set -euo pipefail

WORK="${WORK:-/root/sp11}"
ISO="${ISO:-$WORK/base.iso}"
TREE="${TREE:-$WORK/iso-tree}"
OUT="${OUT:-$WORK/surface-pro-11-ubuntu.iso}"
EFI_IMG="$WORK/efi.img"

# EFI System Partition GUID C12A7328-F81F-11D2-BA4B-00A0C93EC93B, byte-swapped
# as xorriso reports it.
ESP_GUID=28732ac11ff8d211ba4b00a0c93ec93b

[ -d "$TREE" ] || { echo "no prepared tree at $TREE - run 04-remaster.sh first"; exit 1; }
[ -f "$ISO" ]  || { echo "missing base ISO: $ISO"; exit 1; }

echo "== extracting the EFI system partition from the base image =="
# Interval was reported in 512-byte units: 7976959 - 7964672 + 1 = 12288 blocks
# = 6 MiB, which matches the reported -boot-load-size of 12288.
dd if="$ISO" of="$EFI_IMG" bs=512 skip=7964672 count=12288 status=none
echo "  $EFI_IMG  ($(du -h "$EFI_IMG" | cut -f1))"
file "$EFI_IMG" | sed 's/^/  /'

echo
echo "== building ISO =="
rm -f "$OUT"
xorriso -as mkisofs \
    -r -V 'SP11 Ubuntu 26.04 arm64' \
    -o "$OUT" \
    --modification-date="$(date -u +%Y%m%d%H%M%S00)" \
    --protective-msdos-label \
    -partition_cyl_align off \
    -partition_offset 0 \
    --mbr-force-bootable \
    -append_partition 2 "$ESP_GUID" "$EFI_IMG" \
    -appended_part_as_gpt \
    -c '/boot/boot.cat' \
    -e '--interval:appended_partition_2:all::' \
    -no-emul-boot \
    -boot-load-size 12288 \
    "$TREE" 2>&1 | grep -vE "^libisofs: WARNING : Cannot add /(ubuntu|dists)" | tail -12

echo
echo "== verifying the result is bootable =="
ls -la "$OUT"
echo
xorriso -indev "$OUT" -report_el_torito plain 2>/dev/null | sed 's/^/  /'
echo
xorriso -indev "$OUT" -report_system_area plain 2>/dev/null | grep -E "System area summary|MBR partition|GPT type|GPT start" | sed 's/^/  /'

echo
echo "Write to USB with:"
echo "  dd if=$OUT of=/dev/sdX bs=4M status=progress conv=fsync"
