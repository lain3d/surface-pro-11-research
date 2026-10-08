#!/bin/bash
# Rebuild a UKI with a new kernel image, keeping every other section identical.
#
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-rebuild-uki.sh \
#       <source.efi> <new-vmlinuz.efi> <out.efi> [new-cmdline]
#
# WHY NOT objcopy --update-section
#
# It silently truncates the new contents to the OLD section size and exits 0.
# That produced a UKI whose .cmdline was cut mid-word at
# "modprobe.blacklist=qcom_q6v5_p" and would have booted with a malformed root=.
# The only safe method is to strip the payload sections back to the bare stub and
# re-add each one at an explicit VMA.
#
# THE LAYOUT CONSTRAINT
#
# Payload sections are page-aligned and laid out in order, .initrd last:
#
#   .osrel .uname .cmdline .dtb .linux .initrd
#
# On the integ20 UKI, .linux ends 3584 bytes short of .initrd's VMA. So a kernel
# image that grows by more than that would overlap, and .initrd has to move up.
# This computes .initrd's VMA from the new .linux size rather than pinning it,
# and since it is the last section nothing else has to move.
#
# Also: `objcopy --dump-section` exits NON-ZERO even when the dump succeeded.
# Never test its status - test that the file exists and is non-empty.
set -u

SRC=${1:?source UKI}
NEWLINUX=${2:?new kernel image}
OUT=${3:?output UKI}
NEWCMDLINE=${4:-}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PAYLOAD="osrel uname cmdline dtb linux initrd"

echo "=== source: $SRC ($(stat -c%s "$SRC") bytes) ==="

# ---- read the existing layout ----------------------------------------------
declare -A VMA SIZE
while read -r idx name size vma rest; do
    case " $PAYLOAD " in *" ${name#.} "*) ;; *) continue ;; esac
    VMA[${name#.}]=$((16#$vma))
    SIZE[${name#.}]=$((16#$size))
done < <(objdump -h "$SRC" | awk '/^ *[0-9]+ \./ {print $1, $2, $3, $4, $5}')

for s in $PAYLOAD; do
    printf '  %-8s size %10s  vma 0x%x\n' ".$s" "${SIZE[$s]:-?}" "${VMA[$s]:-0}"
done

# ---- extract every payload section we are keeping ---------------------------
for s in $PAYLOAD; do
    objcopy --dump-section ".$s=$T/$s.bin" "$SRC" /dev/null 2>/dev/null
    [ -s "$T/$s.bin" ] || { echo "FAILED to extract .$s"; exit 1; }
done
echo "  extracted $(ls -1 "$T" | wc -l) sections"

# ---- substitutions ----------------------------------------------------------
cp "$NEWLINUX" "$T/linux.bin"
NEWSIZE=$(stat -c%s "$T/linux.bin")
echo
echo "=== new .linux: $NEWSIZE bytes (was ${SIZE[linux]}, delta $((NEWSIZE - SIZE[linux]))) ==="

if [ -n "$NEWCMDLINE" ]; then
    printf '%s\0' "$NEWCMDLINE" > "$T/cmdline.bin"
    echo "=== new .cmdline: $NEWCMDLINE ==="
fi

# ---- where does .initrd go now? --------------------------------------------
LINUX_END=$(( VMA[linux] + NEWSIZE ))
INITRD_VMA=$(( (LINUX_END + 0xfff) & ~0xfff ))
if [ "$INITRD_VMA" -le "${VMA[initrd]}" ]; then
    INITRD_VMA=${VMA[initrd]}
    echo "=== .initrd stays at 0x$(printf %x "$INITRD_VMA") (new .linux still fits) ==="
else
    echo "=== .initrd MOVES 0x$(printf %x "${VMA[initrd]}") -> 0x$(printf %x "$INITRD_VMA") ==="
fi

# ---- strip to the stub, then re-add at explicit VMAs ------------------------
ARGS=()
for s in $PAYLOAD; do ARGS+=(--remove-section ".$s"); done
objcopy "${ARGS[@]}" "$SRC" "$T/stub.efi" || { echo "strip failed"; exit 1; }
echo "  stub: $(stat -c%s "$T/stub.efi") bytes"

ADD=()
for s in $PAYLOAD; do
    if [ "$s" = initrd ]; then v=$INITRD_VMA; else v=${VMA[$s]}; fi
    ADD+=(--add-section ".$s=$T/$s.bin" --change-section-vma ".$s=$(printf '0x%x' "$v")")
done
objcopy "${ADD[@]}" "$T/stub.efi" "$OUT" || { echo "add failed"; exit 1; }

# ---- verify -----------------------------------------------------------------
echo
echo "=== result: $OUT ($(stat -c%s "$OUT") bytes) ==="
objdump -h "$OUT" | awk '/^ *[0-9]+ \./ {printf "  %-10s %10s  vma %s\n", $2, $3, $4}'

echo
echo "=== checks ==="
fail=0
for s in $PAYLOAD; do
    objcopy --dump-section ".$s=$T/chk-$s.bin" "$OUT" /dev/null 2>/dev/null
    if cmp -s "$T/$s.bin" "$T/chk-$s.bin"; then
        printf '  ok       .%s round-trips\n' "$s"
    else
        printf '  MISMATCH .%s\n' "$s"; fail=1
    fi
done
printf '  cmdline: '; tr -d '\0' < "$T/chk-cmdline.bin"; echo
[ "$fail" = 0 ] && echo "  ALL SECTIONS VERIFIED" || { echo "  FAILED"; exit 1; }
