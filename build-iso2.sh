#!/bin/bash
# Build a second Surface Pro 11 ISO carrying all the feature branches.
#
# NEVER writes to the baseline. Output goes to a new filename; the preserved
# copy in sp11-out/baseline/ is immutable and is not touched.
set -o pipefail
LOG=/root/sp11/build-iso2.log
exec > >(tee -a "$LOG") 2>&1
echo "=================== $(date -Is) start ==================="

WT=/root/sp11/wt-ov13858
LAYER=/root/sp11/layer
TREE=/root/sp11/iso-tree
OUT=/home/lain/sp11-out
STAMP=$(date +%Y%m%d)

step() { echo; echo "### $* ###"; }
die()  { echo "FAILED: $*"; exit 1; }

# ---------------------------------------------------------------- branches ---
step "compose the integration branch"
cd $WT || die "no worktree"
git checkout -q debug/imx681-addr-scan || die "checkout"
git branch -D integration/iso2 2>/dev/null
git checkout -q -b integration/iso2 || die "branch"
for b in camera/ov13858-dt usb4/platform-nhi; do
    git merge --no-edit -q "$b" || die "merge $b"
    echo "  merged $b"
done
git log --oneline -1

# ------------------------------------------------------------------ config ---
step "configure"
./scripts/config --file .config \
    -m CONFIG_USB4 \
    -e CONFIG_USB4_DEBUGFS_WRITE \
    -e CONFIG_HOTPLUG_PCI_PCIE \
    -m CONFIG_VIDEO_OV13858 \
    -m CONFIG_VIDEO_IMX681 \
    -m CONFIG_CLK_X1E80100_CAMCC \
    -m CONFIG_VIDEO_QCOM_CAMSS \
    -m CONFIG_I2C_QCOM_CCI \
    -e CONFIG_I2C_CHARDEV
make olddefconfig </dev/null >/dev/null 2>&1

echo "  verifying every symbol actually took:"
FAIL=0
for s in CONFIG_USB4=m CONFIG_USB4_DEBUGFS_WRITE=y CONFIG_HOTPLUG_PCI_PCIE=y \
         CONFIG_VIDEO_OV13858=m CONFIG_VIDEO_IMX681=m CONFIG_CLK_X1E80100_CAMCC=m \
         CONFIG_VIDEO_QCOM_CAMSS=m CONFIG_I2C_QCOM_CCI=m; do
    if grep -qx "$s" .config; then echo "    OK   $s"; else echo "    MISS $s"; FAIL=1; fi
done
[ $FAIL -eq 0 ] || die "config symbols did not take"

# ------------------------------------------------------------------ kernel ---
step "build the kernel packages (this is the long part)"
rm -f /root/sp11/linux-image-*-integ*.deb
make -j"$(nproc)" bindeb-pkg LOCALVERSION=-sp11-integ KDEB_PKGVERSION=1 </dev/null \
    || die "kernel build"

DEB=$(ls -t /root/sp11/linux-image-*sp11-integ*_arm64.deb 2>/dev/null | grep -v dbg | head -1)
[ -n "$DEB" ] || die "no linux-image deb produced"
KVER=$(basename "$DEB" | sed 's/^linux-image-//; s/_.*//')
echo "  built $KVER"
echo "  $DEB"

# --------------------------------------------------------------- into layer ---
step "install the kernel into the live filesystem layer"
for m in proc sys dev dev/pts; do mountpoint -q $LAYER/$m || mount --bind /$m $LAYER/$m; done
cp "$DEB" $LAYER/tmp/
HDR=$(ls -t /root/sp11/linux-headers-*sp11-integ*_arm64.deb 2>/dev/null | head -1)
[ -n "$HDR" ] && cp "$HDR" $LAYER/tmp/
chroot $LAYER dpkg -i /tmp/$(basename "$DEB") || die "dpkg -i"
chroot $LAYER update-initramfs -c -k "$KVER" || die "update-initramfs"
rm -f $LAYER/tmp/linux-*.deb
for m in dev/pts dev sys proc; do umount $LAYER/$m 2>/dev/null; done

# ------------------------------------------------------------------- staging ---
step "stage kernel, initrd and dtb into the ISO tree"
chmod -R u+w $TREE
cp -f $LAYER/boot/vmlinuz-$KVER      $TREE/casper/vmlinuz     || die "vmlinuz"
cp -f $LAYER/boot/initrd.img-$KVER   $TREE/casper/initrd      || die "initrd"
DTB=$(find $LAYER/usr/lib/linux-image-$KVER -name 'x1e80100-microsoft-denali-oled.dtb' | head -1)
[ -n "$DTB" ] || die "no dtb for $KVER"
mkdir -p $TREE/dtb/qcom
cp -f "$DTB" $TREE/dtb/qcom/x1e80100-microsoft-denali-oled.dtb || die "dtb copy"
ls -la $TREE/casper/vmlinuz $TREE/casper/initrd $TREE/dtb/qcom/

step "add boot=casper to grub.cfg"
# Absent in the first build; if casper does not autodetect, the boot drops to an
# initramfs prompt. Harmless when redundant.
if grep -q 'boot=casper' $TREE/boot/grub/grub.cfg; then
    echo "  already present"
else
    sed -i 's|linux  /casper/vmlinuz \$cmdline|linux  /casper/vmlinuz boot=casper $cmdline|' \
        $TREE/boot/grub/grub.cfg
    grep -n 'casper/vmlinuz' $TREE/boot/grub/grub.cfg
fi

# ------------------------------------------------------------------ squashfs ---
step "rebuild minimal.squashfs"
COMP=$(unsquashfs -s $TREE/casper/minimal.squashfs 2>/dev/null | awk '/Compression/{print $2}')
COMP=${COMP:-zstd}
echo "  compression: $COMP"
rm -f /root/sp11/minimal.new.squashfs
mksquashfs $LAYER /root/sp11/minimal.new.squashfs -comp "$COMP" -noappend -no-progress \
    -e boot/vmlinuz-7.0.0-22-qcom-x1e 2>&1 | tail -5 || die "mksquashfs"
mv -f /root/sp11/minimal.new.squashfs $TREE/casper/minimal.squashfs
printf '%s' "$(du -sx --block-size=1 $LAYER | cut -f1)" > $TREE/casper/minimal.size
ls -la $TREE/casper/minimal.squashfs

# ---------------------------------------------------------------------- ISO ---
step "pack the ISO"
ISO=$OUT/surface-pro-11-ubuntu-INTEG-$STAMP.iso
rm -f "$ISO"
xorriso -as mkisofs \
    -r -V "SP11_INTEG_$STAMP" \
    -o "$ISO" \
    -partition_offset 0 \
    -append_partition 2 0xef /root/sp11/efi.img \
    -appended_part_as_gpt \
    --mbr-force-bootable \
    -e '--interval:appended_partition_2:all::' \
    -no-emul-boot \
    $TREE 2>&1 | tail -8
[ -f "$ISO" ] || die "no ISO produced"

step "verify the boot structure matches the original"
echo "--- new ISO ---"
xorriso -indev "$ISO" -report_el_torito plain 2>/dev/null | head -8
echo "--- base.iso (reference) ---"
xorriso -indev /root/sp11/base.iso -report_el_torito plain 2>/dev/null | head -8

step "done"
ls -la "$ISO"
sha256sum "$ISO" | tee "$ISO.sha256"
echo
echo "BASELINE UNTOUCHED:"
ls -la $OUT/baseline/
echo "=================== $(date -Is) end ==================="
