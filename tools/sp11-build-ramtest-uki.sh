#!/bin/bash
# Build a UKI whose initramfs runs the ADSP experiment at dracut pre-mount.
#
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-build-ramtest-uki.sh
#
# Appends an uncompressed cpio to the existing .initrd. The kernel's initramfs
# loader processes concatenated archives in order and later entries win, which
# is the same mechanism microcode early-cpio uses. .initrd is the last payload
# section in the UKI, so growing it moves nothing else.
#
# Contents of the appended archive:
#   /lib/firmware/qcom/x1e80100/microsoft/Denali/*   the ADSP image + its dtb
#   /sp11/mods/*.ko + ORDER                          deliberately NOT under
#                                                    /usr/lib/modules, so udev
#                                                    cannot autoload them and
#                                                    the hook controls timing
#   /usr/lib/dracut/hooks/pre-mount/50-sp11-ramtest.sh
# NOT set -e: objcopy --dump-section exits non-zero even when the dump
# succeeds, so -e kills this script on a successful extraction.
set -u

STAGE=/mnt/c/sp11-stage/ramtest
REPO=/mnt/c/Users/Crazy/projs/arm64-egpu/tools
SRC=${SRC:-/mnt/c/sp11-stage/BOOTAA64-integ22-ucsipatch.efi}

# MODE=full     hook + ADSP firmware + the remoteproc modules   (~22 MB)
# MODE=hookonly hook alone                                      (~4 KB)
#
# hookonly exists as a bisect step. integ22 and integ23 were shown to differ in
# exactly one UKI section - .initrd - with .linux, .dtb and .cmdline
# byte-identical, so whatever stops the T7 enumerating is somewhere in those
# 22 MB. Shipping the hook alone says whether it is the payload or the mere act
# of appending a second archive.
MODE=${MODE:-full}
case "$MODE" in
    full)     OUT=${OUT:-/mnt/c/sp11-stage/BOOTAA64-integ23-ramtest.efi} ;;
    hookonly) OUT=${OUT:-/mnt/c/sp11-stage/BOOTAA64-integ24-hookonly.efi} ;;
    *) echo "MODE must be full or hookonly"; exit 1 ;;
esac

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

if [ "$MODE" = full ]; then
    [ -d "$STAGE/lib/firmware" ] || { echo "run gather first - no $STAGE"; exit 1; }
    [ -f "$STAGE/sp11/mods/ORDER" ] || { echo "no module ORDER file"; exit 1; }
fi

echo "=== assembling the overlay ==="
#
# NEVER ship a top-level 'lib' entry. /lib is a SYMLINK to usr/lib in this
# initramfs, and init/initramfs.c calls clean_path() before creating anything:
#
#     if (!init_stat(path, &st, AT_SYMLINK_NOFOLLOW) &&
#         (st.mode ^ fmode) & S_IFMT) {
#             if (S_ISDIR(st.mode)) init_rmdir(path); else init_unlink(path);
#     }
#
# An incoming *directory* named lib differs in type from the existing symlink,
# so the symlink is UNLINKED and replaced by a directory holding only what we
# shipped. That destroys /lib -> usr/lib, ld-linux-aarch64.so.1 disappears, and
# the kernel panics with "No working init found". It did exactly that once.
# Put the firmware at its real path instead.
mkdir -p "$T/ov/usr/lib/dracut/hooks/pre-mount"
if [ "$MODE" = full ]; then
    mkdir -p "$T/ov/usr/lib/firmware"
    cp -a "$STAGE/lib/firmware/." "$T/ov/usr/lib/firmware/"
    cp -a "$STAGE/sp11" "$T/ov/"
else
    echo "  MODE=hookonly - no firmware, no modules"
fi
cp "$REPO/50-sp11-ramtest.sh" "$T/ov/usr/lib/dracut/hooks/pre-mount/50-sp11-ramtest.sh"
sed -i 's/\r$//' "$T/ov/usr/lib/dracut/hooks/pre-mount/50-sp11-ramtest.sh"
rm -f "$T/ov/sp11/mods/ORDER.bak" 2>/dev/null

# the staging area lives on drvfs, which reports lain:lain 0777 for everything;
# those modes and owners get applied to real directories in the rootfs
chown -R 0:0 "$T/ov"
find "$T/ov" -type d -exec chmod 755 {} +
find "$T/ov" -type f -exec chmod 644 {} +
chmod 755 "$T/ov/usr/lib/dracut/hooks/pre-mount/50-sp11-ramtest.sh"

echo "  files:"
find "$T/ov" -type f | sed "s|$T/ov|    .|"

echo
echo "=== type-collision guard against the base initramfs ==="
# Any overlay entry whose type differs from the base's entry at the same path
# will DELETE the base's version. Check every path before shipping.
objcopy --dump-section .initrd="$T/base.bin" "$SRC" /dev/null 2>/dev/null || true
zstdcat "$T/base.bin" 2>/dev/null | cpio -itv 2>/dev/null > "$T/base.list"
bad=0
( cd "$T/ov" && find . -mindepth 1 -printf '%y %P\n' ) | while read -r ty path; do
    base_ty=$(awk -v p="$path" '$NF == p {print substr($1,1,1)}' "$T/base.list" | head -1)
    [ -n "$base_ty" ] || continue
    case "$ty$base_ty" in
        dd|ff|ll) ;;                       # same type, safe to merge
        *) echo "  COLLISION: /$path is '$base_ty' in the base but '$ty' here"; bad=1 ;;
    esac
done
if ( cd "$T/ov" && find . -mindepth 1 -printf '%y %P\n' ) | while read -r ty path; do
       base_ty=$(awk -v p="$path" '$NF == p {print substr($1,1,1)}' "$T/base.list" | head -1)
       [ -n "$base_ty" ] || continue
       case "$ty$base_ty" in dd|ff|ll) ;; *) exit 1 ;; esac
   done; then
    echo "  no type collisions"
else
    echo "  REFUSING to build - a collision would delete the base's entry"
    exit 1
fi

echo
echo "=== building the cpio (newc, uncompressed) ==="
( cd "$T/ov" && find . -print0 | cpio --null -o -H newc --quiet ) > "$T/overlay.cpio"
echo "  overlay.cpio: $(stat -c%s "$T/overlay.cpio") bytes"

echo
echo "=== extracting and extending .initrd ==="
objcopy --dump-section .initrd="$T/initrd.orig" "$SRC" /dev/null 2>/dev/null || true
[ -s "$T/initrd.orig" ] || { echo "could not extract .initrd"; exit 1; }
ORIG=$(stat -c%s "$T/initrd.orig")
echo "  original: $ORIG bytes"

# ALIGNMENT. init/initramfs.c takes the cpio path only when
#     *buf == '0' && !(state_offset & 3)
# so a concatenated archive must begin at a 4-byte aligned offset. The first
# build appended at offset 57369577 (& 3 == 1); the kernel fell through to the
# decompressors, matched none, and printed
#     "Initramfs unpacking failed: invalid magic at start of compressed archive"
# The overlay was silently absent and dracut skipped pre-mount for want of a
# hook. Zero bytes ARE skipped by that same loop, so pad to alignment.
PAD=$(( (4 - (ORIG % 4)) % 4 ))
echo "  padding : $PAD zero byte(s) to reach 4-byte alignment"
cp "$T/initrd.orig" "$T/initrd.new"
[ "$PAD" -gt 0 ] && head -c "$PAD" /dev/zero >> "$T/initrd.new"
cat "$T/overlay.cpio" >> "$T/initrd.new"
NEW=$(stat -c%s "$T/initrd.new")
echo "  extended: $NEW bytes (overlay starts at $((ORIG + PAD)), aligned: $(( (ORIG + PAD) % 4 == 0 )))"

echo
echo "=== rebuilding the UKI ==="
# reuse the section-safe rebuilder, but it replaces .linux; here we need .initrd,
# so do the same strip-and-re-add explicitly.
PAYLOAD="osrel uname cmdline dtb linux initrd"
declare -A VMA
while read -r idx name size vma rest; do
    case " $PAYLOAD " in *" ${name#.} "*) VMA[${name#.}]=$((16#$vma)) ;; esac
done < <(objdump -h "$SRC" | awk '/^ *[0-9]+ \./ {print $1, $2, $3, $4, $5}')

for s in osrel uname cmdline dtb linux; do
    objcopy --dump-section ".$s=$T/$s.bin" "$SRC" /dev/null 2>/dev/null || true
    [ -s "$T/$s.bin" ] || { echo "extract .$s failed"; exit 1; }
done
cp "$T/initrd.new" "$T/initrd.bin"

ARGS=(); for s in $PAYLOAD; do ARGS+=(--remove-section ".$s"); done
objcopy "${ARGS[@]}" "$SRC" "$T/stub.efi"

ADD=()
for s in $PAYLOAD; do
    ADD+=(--add-section ".$s=$T/$s.bin" --change-section-vma ".$s=$(printf '0x%x' "${VMA[$s]}")")
done
objcopy "${ADD[@]}" "$T/stub.efi" "$OUT"

echo "  $OUT: $(stat -c%s "$OUT") bytes"
objdump -h "$OUT" | awk '/^ *[0-9]+ \./ {printf "    %-10s %10s  vma %s\n", $2, $3, $4}'

echo
echo "=== verify ==="
fail=0
for s in osrel uname cmdline dtb linux initrd; do
    objcopy --dump-section ".$s=$T/chk-$s.bin" "$OUT" /dev/null 2>/dev/null || true
    if cmp -s "$T/$s.bin" "$T/chk-$s.bin"; then echo "  ok       .$s"; else echo "  MISMATCH .$s"; fail=1; fi
done
printf '  cmdline: '; tr -d '\0' < "$T/chk-cmdline.bin"; echo
# prove the overlay is really in there
if zstdcat "$T/chk-initrd.bin" 2>/dev/null | cpio -t 2>/dev/null | grep -q .; then
    echo "  ok       .initrd first archive still lists"
fi
[ "$fail" = 0 ] || { echo "  FAILED"; exit 1; }
echo "  ALL SECTIONS VERIFIED"
