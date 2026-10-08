#!/bin/bash
# Append a dracut pre-mount hook to a UKI's .initrd, changing nothing else.
#
#   wsl -d Ubuntu-22.04 -u root env SRC=... OUT=... bash tools/sp11-add-initrd-hook.sh
#
# WHY APPEND RATHER THAN REBUILD
#
# The initrd lives inside the UKI and there is no dracut in WSL. The kernel's
# initramfs unpacker accepts CONCATENATED archives, so a tiny uncompressed cpio
# carrying one file can be appended and it lands on top of the unpacked base.
#
# WHERE THE HOOK GOES, AND HOW THAT WAS ESTABLISHED
#
# /var/lib/dracut/hooks/pre-mount/ - NOT /usr/lib/dracut/hooks/. Read out of the
# initrd's own dracut-lib.sh:
#
#     hookdir=/var/lib/dracut/hooks
#     list_hooks() searches /var/lib/dracut/hooks, then /etc/dracut/hooks,
#     then /usr/lib/dracut/hooks   (all three, /var wins ties)
#
# and out of dracut-pre-mount.service:
#
#     ConditionDirectoryNotEmpty=|/var/lib/dracut/hooks/pre-mount
#     ConditionDirectoryNotEmpty=|/etc/dracut/hooks/pre-mount
#     ConditionDirectoryNotEmpty=|/usr/lib/dracut/hooks/pre-mount
#     After=dracut-initqueue.service
#     Before=initrd-root-fs.target sysroot.mount
#
# Two consequences worth writing down. All three pre-mount directories are
# currently EMPTY, so the service is skipped entirely - dropping this file in is
# what makes it run at all. And the hook fires AFTER initqueue has found the root
# device and BEFORE sysroot.mount, which is exactly the window we want.
#
# THE ALIGNMENT RULE
#
# init/initramfs.c takes the cpio path only when !(this_header & 3), so an
# appended archive must start 4-byte aligned. Zero padding is skipped by that
# same loop, so pad with NULs.
#
# The target directory already exists in the base archive, so this ships ONE
# regular file and no directory entries - which also sidesteps the trap that a
# directory entry whose type differs from the base gets clean_path()'d away.
set -u

SRC=${SRC:?set SRC to the input UKI}
OUT=${OUT:?set OUT to the output UKI}
HOOK=${HOOK:-/mnt/c/Users/Crazy/projs/arm64-egpu/tools/50-sp11-adsp.sh}
DEST=${DEST:-var/lib/dracut/hooks/pre-mount/50-sp11-adsp.sh}

[ -f "$HOOK" ] || { echo "no hook file at $HOOK"; exit 1; }

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
echo "source .initrd: $(stat -c%s "$T/initrd.bin") bytes"

# ---- build the overlay cpio -------------------------------------------------
mkdir -p "$T/ov/${DEST%/*}"
cp "$HOOK" "$T/ov/$DEST"
sed -i 's/\r$//' "$T/ov/$DEST"
chmod 755 "$T/ov/$DEST"

# Only the file itself - the directories exist in the base already.
( cd "$T/ov" && echo "$DEST" | cpio -o -H newc --quiet ) > "$T/overlay.cpio"
echo "overlay cpio: $(stat -c%s "$T/overlay.cpio") bytes, one entry:"
cpio -itv < "$T/overlay.cpio" 2>/dev/null | sed 's/^/  /'

# ---- pad the base to a 4-byte boundary, then append -------------------------
cp "$T/initrd.bin" "$T/new-initrd.bin"
base=$(stat -c%s "$T/new-initrd.bin")
pad=$(( (4 - (base % 4)) % 4 ))
if [ "$pad" -gt 0 ]; then
    head -c "$pad" /dev/zero >> "$T/new-initrd.bin"
    echo "padded $pad byte(s) to 4-byte alignment (was $base)"
fi
cat "$T/overlay.cpio" >> "$T/new-initrd.bin"
echo "new .initrd: $(stat -c%s "$T/new-initrd.bin") bytes"

cp "$T/new-initrd.bin" "$T/initrd.bin"

# ---- reassemble, .initrd last so nothing else moves -------------------------
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
for s in osrel uname cmdline dtb linux; do
    objcopy --dump-section ".$s=$T/src-$s.bin" "$SRC" /dev/null 2>/dev/null || true
    cmp -s "$T/src-$s.bin" "$T/chk-$s.bin" && echo "  ok       .$s identical to source" || { echo "  .$s CHANGED"; fail=1; }
done

# and prove the hook survives a round trip through the unpacker's rules
echo
echo "=== the appended archive, read back out of the result ==="
tail -c "$(stat -c%s "$T/overlay.cpio")" "$T/chk-initrd.bin" | cpio -itv 2>/dev/null | sed 's/^/  /'

[ "$fail" = 0 ] || { echo "FAILED"; exit 1; }
echo
echo "  $OUT: $(stat -c%s "$OUT") bytes"
