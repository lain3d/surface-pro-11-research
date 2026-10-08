#!/bin/bash
# Resume the ISO build after the kernel stage.
#
# The first run was killed during mksquashfs, but the expensive work survived:
# the kernel packages are built, installed into the layer, and vmlinuz/initrd/dtb
# are staged. An orphaned mksquashfs was still running and progressing, so this
# waits for it rather than duplicating ~15 minutes of compression.
#
# Safe to run whether or not that process is still alive: if the squashfs it
# leaves behind does not validate, this rebuilds it.
set -o pipefail
LOG=/root/sp11/build-iso2.log
exec > >(tee -a "$LOG") 2>&1
echo "=================== $(date -Is) RESUME ==================="

LAYER=/root/sp11/layer
TREE=/root/sp11/iso-tree
OUT=/home/lain/sp11-out
STAMP=$(date +%Y%m%d)
NEW=/root/sp11/minimal.new.squashfs

step() { echo; echo "### $* ###"; }
die()  { echo "FAILED: $*"; exit 1; }

step "wait for any in-flight mksquashfs"
while pgrep -x mksquashfs >/dev/null 2>&1; do
    sz=$(stat -c %s "$NEW" 2>/dev/null || echo 0)
    echo "  still compressing; $NEW is $((sz/1024/1024)) MB  [$(date +%H:%M:%S)]"
    sleep 60
done
echo "  no mksquashfs running"

step "validate the squashfs, rebuild it if it is not sound"
GOOD=0
if [ -s "$NEW" ]; then
    if unsquashfs -s "$NEW" >/tmp/sqs.txt 2>&1; then
        GOOD=1
        grep -E 'Compression|Filesystem size|Number of inodes' /tmp/sqs.txt | sed 's/^/    /'
    else
        echo "  does not validate:"; sed 's/^/    /' /tmp/sqs.txt | head -5
    fi
else
    echo "  missing or empty"
fi

if [ $GOOD -ne 1 ]; then
    echo "  rebuilding from scratch"
    rm -f "$NEW"
    COMP=$(unsquashfs -s $TREE/casper/minimal.squashfs 2>/dev/null | awk '/Compression/{print $2}')
    COMP=${COMP:-zstd}
    mksquashfs $LAYER "$NEW" -comp "$COMP" -noappend -no-progress \
        -e boot/vmlinuz-7.0.0-22-qcom-x1e >/tmp/mks.log 2>&1 || die "mksquashfs"
    unsquashfs -s "$NEW" >/dev/null 2>&1 || die "rebuilt squashfs still does not validate"
    echo "  rebuilt OK"
fi

step "install the squashfs into the ISO tree"
chmod -R u+w $TREE
mv -f "$NEW" $TREE/casper/minimal.squashfs || die "move squashfs"
du -sx --block-size=1 $LAYER | cut -f1 > $TREE/casper/minimal.size
ls -la $TREE/casper/minimal.squashfs
echo "  minimal.size = $(cat $TREE/casper/minimal.size)"

step "confirm the staged kernel is the integration one"
KVER=$(ls $LAYER/boot/vmlinuz-*sp11-integ* 2>/dev/null | head -1 | sed 's|.*/vmlinuz-||')
[ -n "$KVER" ] || die "no integration kernel in the layer"
echo "  $KVER"
cmp -s $LAYER/boot/vmlinuz-$KVER $TREE/casper/vmlinuz \
    && echo "  casper/vmlinuz matches" || die "casper/vmlinuz is not the integration kernel"
grep -q 'boot=casper' $TREE/boot/grub/grub.cfg && echo "  boot=casper present" || die "boot=casper missing"

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
    $TREE 2>&1 | tail -6
[ -f "$ISO" ] || die "no ISO produced"

step "verify the boot structure against base.iso, which is known to boot"
echo "--- NEW ---"
xorriso -indev "$ISO" -report_el_torito plain -report_system_area plain 2>/dev/null \
    | grep -E 'El Torito boot img|El Torito img blks|System area summary|MBR partition ' | sed 's/^/    /'
echo "--- base.iso (reference) ---"
xorriso -indev /root/sp11/base.iso -report_el_torito plain -report_system_area plain 2>/dev/null \
    | grep -E 'El Torito boot img|El Torito img blks|System area summary|MBR partition ' | sed 's/^/    /'

step "result"
ls -la "$ISO"
sha256sum "$ISO" | tee "$ISO.sha256"
echo
echo "baseline still intact:"
cd $OUT/baseline && sha256sum -c SHA256SUMS
echo "=================== $(date -Is) end ==================="
