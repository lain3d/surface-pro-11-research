#!/bin/bash
# Rebuild a UKI with a different .dtb, changing nothing else.
#
#   wsl -d Ubuntu-22.04 -u root env SRC=... DTB=... OUT=... \
#       bash tools/sp11-patch-dtb.sh
#
# .dtb sits before .linux and .initrd, so a size change would normally shift
# them. It does not here: every payload section is re-added at the VMA it had in
# the source, and the script refuses if the new .dtb will not fit in the gap
# .dtb already occupies.
#
# NOT set -e: objcopy --dump-section exits non-zero even on success.
set -u

SRC=${SRC:?set SRC to the input UKI}
DTB=${DTB:?set DTB to the replacement device tree}
OUT=${OUT:?set OUT to the output UKI}

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

echo "old .dtb: $(stat -c%s "$T/dtb.bin") bytes"
cp "$DTB" "$T/dtb.bin"
echo "new .dtb: $(stat -c%s "$T/dtb.bin") bytes  ($DTB)"

ROOM=$(( VMA[linux] - VMA[dtb] ))
NEWSZ=$(stat -c%s "$T/dtb.bin")
echo "room before .linux: $ROOM bytes"
[ "$NEWSZ" -lt "$ROOM" ] || { echo ".dtb would overrun .linux - refusing"; exit 1; }

# sanity: it must actually be a device tree
head -c4 "$T/dtb.bin" | od -An -tx1 | grep -q 'd0 0d fe ed' || { echo "not a DTB (bad magic)"; exit 1; }

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
    cmp -s "$T/$s.bin" "$T/chk-$s.bin" && echo "  ok       .$s" || { echo "  MISMATCH .$s"; fail=1; }
done
# .linux, .initrd and .cmdline must be untouched relative to the SOURCE
for s in cmdline linux initrd; do
    objcopy --dump-section ".$s=$T/src-$s.bin" "$SRC" /dev/null 2>/dev/null || true
    cmp -s "$T/src-$s.bin" "$T/chk-$s.bin" && echo "  ok       .$s identical to source" || { echo "  .$s CHANGED"; fail=1; }
done
cmp -s "$DTB" "$T/chk-dtb.bin" && echo "  ok       .dtb is the replacement" || { echo "  .dtb wrong"; fail=1; }
[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
echo "  $OUT: $(stat -c%s "$OUT") bytes"
