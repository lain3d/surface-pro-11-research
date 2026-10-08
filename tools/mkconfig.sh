#!/bin/bash
#
# Generate the kernel config from Ubuntu's qcom-x1e flavour annotations, then
# overlay this project's symbols on top and verify every one of them took.
#
#   bash tools/mkconfig.sh [tree] [output]
#
# WHY THIS EXISTS
#
# Every build in this project so far used `make ARCH=arm64 defconfig` plus
# eight `scripts/config` flips -- 4777 set symbols against the flavour's 11655.
# That is upstream's generic ARM64 config running under a full Ubuntu userland,
# and it is the root cause of a string of failures that looked unrelated:
#
#   FW_LOADER_COMPRESS unset -> 29 of 35 firmware files in the initramfs
#                               unreadable; the GPU, WiFi and Bluetooth -ENOENTs
#   EXFAT_FS unset           -> /mnt/t7 will not mount, killing the diag pipeline
#   SQUASHFS_{LZO,XZ,ZSTD}   -> every snap fails to mount
#   NLS_UTF8 unset           -> exfat with a utf8 iocharset cannot work even
#                               once EXFAT_FS is on
#
# The tree carries debian.qcom-x1e/config/annotations, which is Ubuntu's config
# for exactly this hardware and already annotates CONFIG_VIDEO_IMX681. It had
# never been used.
#
# Patching symbols one boot at a time was treating symptoms. This takes the
# distro config as the basis and overlays only what is genuinely ours.
set -eu

T=${1:-/root/sp11/wt-ov13858}
OUT=${2:-/tmp/sp11.config}
ANN=debian.qcom-x1e/config/annotations
cd "$T"

say() { printf '%s\n' "$*"; }
fail=0

# --- symbols this project needs on top of the flavour ------------------------
# value  symbol                        why
OVERLAY="
y  CONFIG_USB4_DEBUGFS_WRITE          needed to poke the host routers by hand
y  CONFIG_PSTORE_RAM                  must be builtin to capture early boot
y  CONFIG_I2C_CHARDEV                 i2c-dev for userspace bus probing
y  CONFIG_USB_STORAGE                 ROOT IS ON USB: flavour has m, initrd has no usb-storage
n  CONFIG_USB_UAS                     was off before; do not add a second binding path for the T7
y  CONFIG_LOCALVERSION_AUTO           keep -g<sha> in uname -r: describe is our provenance
n  CONFIG_MODVERSIONS                 as before; revisit once module deployment is scripted
"
# CONFIG_USB_STORAGE is the one that would brick a boot. The flavour config is
# fully modular and expects a dracut initrd built against it; ours is the
# initrd dracut generated when usb-storage was builtin, so it does not contain
# the module. 679 symbols regress y->m between the two configs, but this is the
# only one the root filesystem depends on -- xhci, ext4, scsi, sd, dwc3 and
# pinctrl all stay builtin, and the QMP USB phy goes m->y.
# Symbols we depend on and must confirm the flavour already provides. Listing
# them here means a future flavour change that drops one is caught at config
# time rather than by a dead boot.
REQUIRE="
CONFIG_FW_LOADER_COMPRESS
CONFIG_FW_LOADER_COMPRESS_ZSTD
CONFIG_EXFAT_FS
CONFIG_NLS_UTF8
CONFIG_SQUASHFS_XZ
CONFIG_SQUASHFS_LZO
CONFIG_SQUASHFS_ZSTD
CONFIG_VFAT_FS
CONFIG_PSTORE
CONFIG_USB4
CONFIG_VIDEO_IMX681
CONFIG_VIDEO_OV13858
CONFIG_VIDEO_QCOM_CAMSS
CONFIG_I2C_QCOM_CCI
CONFIG_CLK_X1E80100_CAMCC
CONFIG_HOTPLUG_PCI_PCIE
CONFIG_USB_STORAGE
CONFIG_EXT4_FS
"

[ -f "$ANN" ] || { say "no $ANN in $T"; exit 1; }
[ -f debian/scripts/misc/annotations ] || {
    say "annotations tool missing -- restore with: git checkout HEAD -- debian/"; exit 1; }

say "--- export the flavour config ---"
python3 debian/scripts/misc/annotations -f "$ANN" -a arm64 -l arm64-qcom-x1e --export > "$OUT"
say "  $(grep -c '=[ym]$' "$OUT") set symbols from $ANN"

say ""
say "--- apply the overlay ---"
cp "$OUT" .config
echo "$OVERLAY" | while read -r val sym _rest; do
    [ -n "${sym:-}" ] || continue
    case "$val" in
        y) ./scripts/config --enable "$sym" ;;
        m) ./scripts/config --module "$sym" ;;
        n) ./scripts/config --disable "$sym" ;;
    esac
done
make -j"$(nproc)" olddefconfig </dev/null >/dev/null 2>&1

say ""
say "--- verify the overlay took (olddefconfig drops unmet deps silently) ---"
# A disabled symbol has no CONFIG_X= line at all -- it appears as
# "# CONFIG_X is not set". Comparing against an empty grep result reports
# failure for every n entry, i.e. failure on success. Check the negative form.
echo "$OVERLAY" | while read -r val sym _rest; do
    [ -n "${sym:-}" ] || continue
    got=$(grep -E "^${sym}=" .config | cut -d= -f2 || true)
    if [ "$val" = n ]; then
        if [ -z "$got" ]; then
            printf '  %-34s disabled\n' "$sym"
        else
            printf '  %-34s *** wanted disabled, got %s ***\n' "$sym" "$got"
        fi
    elif [ "$got" = "$val" ]; then
        printf '  %-34s %s\n' "$sym" "$got"
    else
        printf '  %-34s *** wanted %s, got %s ***\n' "$sym" "$val" "${got:-unset}"
    fi
done

say ""
say "--- verify what we depend on the flavour for ---"
for sym in $REQUIRE; do
    got=$(grep -E "^${sym}=" .config | cut -d= -f2 || true)
    if [ -n "$got" ]; then
        printf '  %-34s %s\n' "$sym" "$got"
    else
        printf '  %-34s *** NOT SET ***\n' "$sym"
        fail=1
    fi
done

say ""
say "--- consequences worth knowing before building ---"
printf '  %-34s %s\n' CONFIG_MODVERSIONS "$(grep -E '^CONFIG_MODVERSIONS=' .config | cut -d= -f2 || echo 'not set')"
printf '  %-34s %s\n' CONFIG_LOCALVERSION_AUTO "$(grep -E '^CONFIG_LOCALVERSION_AUTO=' .config | cut -d= -f2 || echo 'not set')"
say "  MODVERSIONS=y checks symbol CRCs, so modules built against a different"
say "  config are refused rather than silently mismatched. Existing initrd"
say "  modules will need rebuilding."
say "  LOCALVERSION_AUTO off removes the -g<sha> suffix, so the release string"
say "  changes and /lib/modules paths move with it."

cp .config "$OUT"
say ""
printf '  %s  (%s set symbols)\n' "$OUT" "$(grep -c '=[ym]$' "$OUT")"
[ "$fail" -eq 0 ] || { say "  *** a required symbol is missing -- do not build ***"; exit 1; }
say "  all required symbols present"
