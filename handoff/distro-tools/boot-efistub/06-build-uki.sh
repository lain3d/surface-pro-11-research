#!/bin/bash
# SPDX-License-Identifier: MIT
# Original source: boot/efistub at 53cc5ffb65bd218985a7871580de978839ae51f9.
# Historical source: target device/UUID/paths must be supplied explicitly.
# ESP replacement is disabled unless INSTALL_ESP=yes is explicitly supplied.
# Rebuild the boot path with systemd-stub 259.5, which actually supports .dtb.
#
# Three images, so one boot attempt can be retried against a different theory
# without rebuilding anything:
#
#   A  stock kernel 7.0.0-22-qcom-x1e + stock denali-oled DTB   -> BOOTAA64.EFI
#      Closest to what dwhinham's working SP11 image does (GRUB + devicetree).
#   B  stock kernel, NO dtb section -> firmware's own device tree.
#   C  our INTEG kernel + our INTEG DTB -- the actual research payload.
#
set -eu
DISK="${DISK:?set DISK to the reviewed target disk}"
ESP="${ESP:-${DISK}4}"
ROOT_PART="${ROOT_PART:-${DISK}5}"
MNT="${MNT:?set MNT to the target root mountpoint}"
STUB="${STUB:?set STUB to a DTB-capable AArch64 systemd EFI stub}"
WORK="${WORK:?set WORK to an output directory}"
ROOT_UUID="${ROOT_UUID:?set ROOT_UUID to the target root filesystem UUID}"
STOCK_KVER="${STOCK_KVER:?set STOCK_KVER to the installed kernel version}"
INTEG_DEB="${INTEG_DEB:-}"
INTEG_DTB="${INTEG_DTB:-}"
export MTOOLS_SKIP_CHECK=1

[ -f "$STUB" ] || { echo "no 259 stub"; exit 1; }
mkdir -p "$WORK"

echo "=== mount ==="
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$ROOT_PART" "$MNT"
for d in proc sys dev dev/pts; do
    mountpoint -q "$MNT/$d" || mount --bind "/$d" "$MNT/$d" 2>/dev/null || true
done
cleanup() {
    for d in dev/pts dev sys proc; do umount -l "$MNT/$d" 2>/dev/null || true; done
    sync; umount "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
findmnt -no SOURCE,TARGET "$MNT"

# ---------------------------------------------------------------- INTEG kernel
echo
echo "=== install the INTEG kernel into the target ==="
INTEG_KVER=""
if [ -f "$INTEG_DEB" ]; then
    mkdir -p "$WORK"
    cp "$INTEG_DEB" "$MNT/tmp/integ.deb"
    if chroot "$MNT" dpkg -i /tmp/integ.deb >$WORK/dpkg.log 2>&1; then
        echo "  installed"
    else
        echo "  dpkg reported problems (last 15 lines):"
        tail -15 $WORK/dpkg.log | sed 's/^/    /'
    fi
    rm -f "$MNT/tmp/integ.deb"
    INTEG_KVER=$(ls "$MNT/lib/modules" | grep -- '-integ-' | head -1 || true)
    echo "  modules dir: ${INTEG_KVER:-NONE}"
    if [ -n "$INTEG_KVER" ] && [ ! -f "$MNT/boot/initrd.img-$INTEG_KVER" ]; then
        echo "  generating initramfs for $INTEG_KVER"
        chroot "$MNT" update-initramfs -c -k "$INTEG_KVER" >$WORK/initrd.log 2>&1 \
            && echo "    ok" || { echo "    FAILED:"; tail -10 $WORK/initrd.log | sed 's/^/      /'; }
    fi
else
    echo "  INTEG deb not found at $INTEG_DEB -- skipping variant C"
fi
echo "  /boot now:"
ls -la "$MNT/boot" | grep -E 'vmlinuz|initrd' | sed 's/^/    /'

# ---------------------------------------------------------------- UKI plumbing
cp "$MNT/etc/os-release" "$WORK/osrel"
printf 'root=UUID=%s ro earlycon=efifb keep_bootcon console=tty0 clk_ignore_unused pd_ignore_unused arm64.nopauth' \
    "$ROOT_UUID" > "$WORK/cmdline.txt"
echo
echo "cmdline: $(cat "$WORK/cmdline.txt")"

align=$(objdump -p "$STUB" | awk '/SectionAlignment/ {print strtonum("0x"$2)}')
[ -n "$align" ] && [ "$align" -gt 0 ] || align=4096
base=$(objdump -h "$STUB" | awk 'NF==7 && $1 ~ /^[0-9]+$/ {print strtonum("0x"$3)+strtonum("0x"$4)}' | sort -n | tail -1)
base=$(( (base + align - 1) / align * align ))

build() {   # build <out> <kernel> <initrd> <dtb|"">
    local out=$1 kern=$2 ird=$3 dtb=$4
    local off=$base args=() name file sz
    add() {
        name=$1; file=$2
        sz=$(stat -c%s "$file")
        args+=(--add-section ".${name}=${file}" --change-section-vma ".${name}=$(printf '0x%x' $off)")
        printf '    %-9s %10s bytes\n' ".$name" "$sz"
        off=$(( (off + sz + align - 1) / align * align ))
    }
    echo "  --- $(basename "$out") ---"
    add osrel "$WORK/osrel"
    add cmdline "$WORK/cmdline.txt"
    [ -n "$dtb" ] && add dtb "$dtb"
    add linux "$kern"
    add initrd "$ird"
    objcopy "${args[@]}" "$STUB" "$out"
    printf '    => %s\n' "$(du -h "$out" | cut -f1)"
}

SK="$MNT/boot/vmlinuz-$STOCK_KVER"
SI="$MNT/boot/initrd.img-$STOCK_KVER"
SD="$MNT/usr/lib/firmware/$STOCK_KVER/device-tree/qcom/x1e80100-microsoft-denali-oled.dtb"

echo
echo "=== build ==="
build "$WORK/A-stock-dtb.efi" "$SK" "$SI" "$SD"
build "$WORK/B-stock-nodtb.efi" "$SK" "$SI" ""

if [ -n "$INTEG_KVER" ] && [ -f "$MNT/boot/vmlinuz-$INTEG_KVER" ] && [ -f "$MNT/boot/initrd.img-$INTEG_KVER" ]; then
    D=$([ -f "$INTEG_DTB" ] && echo "$INTEG_DTB" || echo "$SD")
    echo "  variant C dtb: $D"
    build "$WORK/C-integ.efi" "$MNT/boot/vmlinuz-$INTEG_KVER" "$MNT/boot/initrd.img-$INTEG_KVER" "$D"
else
    echo "  skipping variant C (no INTEG kernel/initrd)"
fi

echo
echo "=== verify each is a valid PE with a .dtb where expected ==="
for f in "$WORK"/*.efi; do
    printf '  %-22s ' "$(basename "$f")"
    head -c 2 "$f" | grep -q MZ && printf 'MZ ok  ' || printf 'NOT PE '
    objdump -h "$f" | awk 'NF==7 && $2 ~ /^\./ {printf "%s ", $2}'
    echo
done

# ---------------------------------------------------------------- install
# Building does not replace the ESP. The original installation path below
# deletes its EFI directory; only opt in on a reviewed, expendable test ESP.
if [ "${INSTALL_ESP:-no}" != yes ]; then
    echo
    echo "UKIs built under $WORK; ESP unchanged."
    echo "Historical ESP replacement requires explicit INSTALL_ESP=yes."
    exit 0
fi
echo
echo "=== wipe and repopulate the ESP ==="
mdeltree -i "$ESP" ::/EFI 2>/dev/null || true
mmd -i "$ESP" ::/EFI ::/EFI/BOOT ::/EFI/sp11 2>/dev/null || true

mcopy -i "$ESP" -o "$WORK/A-stock-dtb.efi"   ::/EFI/BOOT/BOOTAA64.EFI
mcopy -i "$ESP" -o "$WORK/A-stock-dtb.efi"   ::/EFI/sp11/A-stock-dtb.efi
mcopy -i "$ESP" -o "$WORK/B-stock-nodtb.efi" ::/EFI/sp11/B-stock-nodtb.efi
[ -f "$WORK/C-integ.efi" ] && mcopy -i "$ESP" -o "$WORK/C-integ.efi" ::/EFI/sp11/C-integ.efi

echo
echo "=== ESP contents ==="
mdir -i "$ESP" ::/EFI/BOOT
mdir -i "$ESP" ::/EFI/sp11

echo
echo "=== stub version actually shipped ==="
strings "$WORK/A-stock-dtb.efi" | grep -oE 'systemd-stub [0-9][^ ]*' | head -1

sync
echo
echo "done."
