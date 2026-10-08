#!/bin/bash
# SPDX-License-Identifier: MIT
# Original source: boot/efistub at 53cc5ffb65bd218985a7871580de978839ae51f9.
set -eu
W="${W:-${TMPDIR:-/tmp}/sp11-stub}"
OUT="${OUT:-$W/linuxaa64-259.efi.stub}"
mkdir -p "$W"; cd "$W"
MIRROR="${MIRROR:-https://ports.ubuntu.com/ubuntu-ports}"
FN="${FN:-pool/universe/s/systemd/systemd-boot-efi_259.5-0ubuntu3_arm64.deb}"

echo "=== download systemd-boot-efi 259.5 ==="
curl -sSfL -o "$W/sbefi.deb" "$MIRROR/$FN"
echo "  $(stat -c%s "$W/sbefi.deb") bytes"

rm -rf "$W/sb"; mkdir -p "$W/sb"
dpkg-deb -x "$W/sbefi.deb" "$W/sb"

echo
echo "=== contents ==="
find "$W/sb" -type f | sed 's/^/  /'

STUB=$(find "$W/sb" -name 'linuxaa64.efi.stub' | head -1)
[ -n "$STUB" ] || { echo "no linuxaa64.efi.stub"; exit 1; }

echo
echo "=== stub: $(stat -c%s "$STUB") bytes ==="
strings "$STUB" | grep -oE 'systemd-stub [0-9][^ ]*' | head -1
echo "sections recognised:"
strings "$STUB" | grep -xE '\.(linux|initrd|cmdline|dtb|dtbauto|osrel|splash|uname|ucode|efifw|profile)' | sort -u | sed 's/^/  /'
echo "dtb/devicetree mentions: $(strings "$STUB" | grep -icE 'dtb|devicetree')"

mkdir -p "$(dirname "$OUT")"
cp "$STUB" "$OUT"
echo
echo "SAVED $OUT"
