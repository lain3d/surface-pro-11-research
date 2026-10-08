#!/bin/bash
# Rebuild a UKI with a different kernel command line, changing nothing else.
#
#   wsl -d Ubuntu-22.04 -u root env SRC=... OUT=... ADD='foo=1' \
#       bash tools/sp11-patch-cmdline.sh
#
# WHY THIS EXISTS
#
# These UKIs are booted directly by UEFI as BOOTAA64.EFI - there is no
# bootloader menu, so the only way to change a kernel parameter is to rewrite
# the .cmdline section. That is cheap: .cmdline sits on its own page with ~4KB
# of slack, so it can grow without moving .dtb, .linux or .initrd.
#
# NOT set -e: objcopy --dump-section exits non-zero even on success.
set -u

SRC=${SRC:?set SRC to the input UKI}
OUT=${OUT:?set OUT to the output UKI}
ADD=${ADD:-}   # append to the existing cmdline
SET=${SET:-}   # or replace it outright (root= is re-checked below either way)

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PAYLOAD="osrel uname cmdline dtb linux initrd"

declare -A VMA
while read -r idx name size vma rest; do
    case " $PAYLOAD " in *" ${name#.} "*) VMA[${name#.}]=$((16#$vma)) ;; esac
done < <(objdump -h "$SRC" | awk '/^ *[0-9]+ \./ {print $1, $2, $3, $4, $5}')

for s in $PAYLOAD; do
    objcopy --dump-section ".$s=$T/$s.bin" "$SRC" /dev/null 2>/dev/null || true
    [ -s "$T/$s.bin" ] || { echo "extract .$s failed"; exit 1; }
done

OLD=$(tr -d '\0' < "$T/cmdline.bin")
echo "old cmdline: $OLD"
[ -n "$ADD$SET" ] || { echo "set ADD= or SET="; exit 1; }
[ -z "$ADD" ] || [ -z "$SET" ] || { echo "ADD and SET are mutually exclusive"; exit 1; }

# the section is NUL-terminated; rebuild it rather than writing past the NUL
if [ -n "$SET" ]; then
    printf '%s\0' "$SET" > "$T/cmdline.bin"
else
    printf '%s %s\0' "$OLD" "$ADD" > "$T/cmdline.bin"
fi
NEW=$(tr -d '\0' < "$T/cmdline.bin")
echo "new cmdline: $NEW"

# a UKI with no root= boots to an emergency shell with no keyboard on this
# machine, which costs a power-button hold to escape. Refuse to build one.
case "$NEW" in
    *root=*) ;;
    *) echo "refusing: new cmdline has no root="; exit 1 ;;
esac

# .cmdline must still fit in the gap before .dtb
ROOM=$(( VMA[dtb] - VMA[cmdline] ))
NEWSZ=$(stat -c%s "$T/cmdline.bin")
echo "cmdline $NEWSZ bytes, $ROOM bytes of room before .dtb"
[ "$NEWSZ" -lt "$ROOM" ] || { echo "cmdline would overrun .dtb - refusing"; exit 1; }

ARGS=(); for s in $PAYLOAD; do ARGS+=(--remove-section ".$s"); done
objcopy "${ARGS[@]}" "$SRC" "$T/stub.efi"

ADDS=()
for s in $PAYLOAD; do
    ADDS+=(--add-section ".$s=$T/$s.bin" --change-section-vma ".$s=$(printf '0x%x' "${VMA[$s]}")")
done
objcopy "${ADDS[@]}" "$T/stub.efi" "$OUT"

echo
echo "=== verify ==="
fail=0
for s in $PAYLOAD; do
    objcopy --dump-section ".$s=$T/chk-$s.bin" "$OUT" /dev/null 2>/dev/null || true
    if cmp -s "$T/$s.bin" "$T/chk-$s.bin"; then echo "  ok       .$s"; else echo "  MISMATCH .$s"; fail=1; fi
done
# .dtb, .linux and .initrd must be untouched relative to the SOURCE, not just
# round-trip consistent - that is the whole claim of this script
for s in dtb linux initrd; do
    objcopy --dump-section ".$s=$T/src-$s.bin" "$SRC" /dev/null 2>/dev/null || true
    cmp -s "$T/src-$s.bin" "$T/chk-$s.bin" && echo "  ok       .$s identical to source" || { echo "  .$s CHANGED"; fail=1; }
done
printf '  cmdline: '; tr -d '\0' < "$T/chk-cmdline.bin"; echo
[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
echo "  $OUT: $(stat -c%s "$OUT") bytes"
