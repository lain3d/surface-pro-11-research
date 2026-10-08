#!/usr/bin/env bash
# Verify the produced ISO: boot structure preserved, and our payload present.
# A successful xorriso exit says nothing about whether the image will boot or
# whether the kernel actually landed in the squashfs, so check both explicitly.
set -uo pipefail

WORK="${WORK:-/root/sp11}"
OUT="${OUT:-$WORK/surface-pro-11-ubuntu.iso}"
BASE="${ISO:-$WORK/base.iso}"
MNT="$WORK/verify-mnt"

[ -f "$OUT" ] || { echo "no ISO at $OUT"; exit 1; }
fail=0
ok()   { printf '  \033[32mOK\033[0m       %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m     %s\n' "$1"; fail=1; }
chk()  { [ "$1" = 1 ] && ok "$2" || bad "$2"; }

echo "== image =="
ls -la "$OUT" | sed 's/^/  /'

echo
echo "== boot structure vs. the base image =="
b_plat=$(xorriso -indev "$BASE" -report_el_torito plain 2>/dev/null | awk '/boot img/{print $6}')
o_plat=$(xorriso -indev "$OUT"  -report_el_torito plain 2>/dev/null | awk '/boot img/{print $6}')
b_size=$(xorriso -indev "$BASE" -report_el_torito plain 2>/dev/null | awk '/boot img/{print $10}')
o_size=$(xorriso -indev "$OUT"  -report_el_torito plain 2>/dev/null | awk '/boot img/{print $10}')
chk "$([ "$b_plat" = "$o_plat" ] && echo 1 || echo 0)" "El Torito platform matches base ($o_plat)"
chk "$([ "$b_size" = "$o_size" ] && echo 1 || echo 0)" "boot load size matches base ($o_size)"
xorriso -indev "$OUT" -report_system_area plain 2>/dev/null | grep -q 'protective-msdos-label' \
    && ok "protective MBR present" || bad "protective MBR missing"
# EFI System Partition GUID, byte-swapped as xorriso prints it
xorriso -indev "$OUT" -report_system_area plain 2>/dev/null | grep -q '28732ac11ff8d211ba4b00a0c93ec93b' \
    && ok "EFI System Partition present in GPT" || bad "no ESP in GPT"

echo
echo "== payload =="
mkdir -p "$MNT"
mountpoint -q "$MNT" && umount "$MNT"
mount -o loop,ro "$OUT" "$MNT" || { echo "  cannot mount produced ISO"; exit 1; }

[ -f "$MNT/casper/vmlinuz" ] && ok "casper/vmlinuz present" || bad "casper/vmlinuz missing"
[ -f "$MNT/casper/initrd" ]  && ok "casper/initrd present"  || bad "casper/initrd missing"

DTB=$(find "$MNT/dtb" -name 'x1e80100-microsoft-denali-oled.dtb' 2>/dev/null | head -1)
chk "$([ -n "$DTB" ] && echo 1 || echo 0)" "Denali OLED DTB shipped on the ISO"
[ -n "$DTB" ] && { grep -qa 'hid-over-spi' "$DTB" && ok "  -> DTB contains the touchscreen node" \
                                                 || bad "  -> DTB has no hid-over-spi node"; }

ls "$MNT"/sp11-kernel/linux-image-*.deb >/dev/null 2>&1 \
    && ok "kernel .deb shipped for the installed system" || bad "no kernel .deb on ISO"

grep -qa 'devicetree' "$MNT/boot/grub/grub.cfg" 2>/dev/null \
    && ok "GRUB has a devicetree line" || bad "GRUB missing devicetree line"

echo
echo "== inside the root filesystem layer =="
SQ="$MNT/casper/minimal.squashfs"
if [ -f "$SQ" ]; then
    # Write the listing to a file rather than a shell variable. It is ~180k
    # lines; capturing that in $(...) is slow and was silently truncating,
    # which made a correct image look broken.
    LIST=$(mktemp)
    unsquashfs -l "$SQ" 2>/dev/null > "$LIST"
    echo "     rootfs entries: $(wc -l < "$LIST")"

    grep -q 'opt/sp11/install.sh' "$LIST" \
        && ok "install.sh baked into the rootfs" || bad "install.sh not in rootfs"
    grep -q 'multi-user.target.wants/sp11-firstboot.service' "$LIST" \
        && ok "first-boot service enabled" || bad "first-boot service not enabled"
    n=$(grep -c 'spi-hid' "$LIST")
    chk "$([ "$n" -gt 0 ] && echo 1 || echo 0)" "spi-hid modules in the rootfs ($n files)"

    # usrmerge: modules live under /usr/lib/modules, not /lib/modules.
    kv=$(grep -oE 'squashfs-root/usr/lib/modules/[^/]+$' "$LIST" | sed 's|.*/||' | sort -u | tr '\n' ' ')
    echo "     kernels in rootfs: $kv"
    case "$kv" in
        *sp11*) ok "patched sp11 kernel present in rootfs" ;;
        *)      bad "patched sp11 kernel NOT in rootfs" ;;
    esac
    rm -f "$LIST"
else
    bad "minimal.squashfs missing from ISO"
fi

umount "$MNT" 2>/dev/null
echo
[ "$fail" -eq 0 ] && echo "ISO verified." || echo "ISO has problems - see FAIL lines above."
exit $fail
