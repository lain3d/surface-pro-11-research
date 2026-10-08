#!/bin/bash
# Rebuild the kernel with the Type-C stack as MODULES, the way Ubuntu ships it.
#
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-build-typec-modular.sh
#
# WHY
#
# The stockcfg builds made the whole Type-C stack built-in. Ubuntu ships every
# one of these as =m, which means none of that code runs until after root is
# mounted. Built in, they probe at 0.5-0.9s: i2c-qcom-geni brings up the bus,
# ps883x probes and RESETS the retimer over its reset GPIO, and ucsi_glink
# starts driving the connector - all while the T7 is trying to enumerate at
# ~1.5s. That race is why the same UKI boots some times and not others, and why
# 23+ failures accumulated while two identical boots succeeded.
#
# WHAT IS DELIBERATELY LEFT BUILT IN
#
# Storage. USB_STORAGE, USB_UAS, BLK_DEV_SD, USB_XHCI_HCD and USB_DWC3 stay =y
# because this initramfs has NO loadable modules for this kernel - its module
# tree is stamped for a different version. Making storage modular would produce
# a kernel that cannot reach its own root filesystem.
set -eu

K=/root/sp11/wt-cfg
cd "$K"

# ONLY the drivers that physically drive the USB-C connector. The first cut of
# this list was wider and cost a boot: PHY_QCOM_EDP is the INTERNAL panel's
# eDP PHY, nothing to do with USB-C. Modularising it (with no .ko installed)
# meant displayport-controller@aea0000 never probed, msm_dpu never bound, and
# the machine came up on the EFI simple-framebuffer with a black screen after
# the splash. The journal named it: no 'fb0: msmdrmfb', no dp_aux_backlight.
#
# I2C_QCOM_GENI stays built in too. The retimer cannot probe without ps883x
# anyway, and other peripherals need the bus.
MODULARISE="TYPEC_UCSI UCSI_PMIC_GLINK TYPEC_MUX_PS883X TYPEC_DP_ALTMODE"
KEEP_BUILTIN="USB_STORAGE USB_UAS BLK_DEV_SD USB_XHCI_HCD USB_DWC3 USB_DWC3_QCOM
              TYPEC QCOM_PMIC_GLINK PHY_QCOM_EDP I2C_QCOM_GENI
              RPMSG_QCOM_GLINK_SMEM PHY_QCOM_QMP_COMBO"

cp .config .config.before-typec-modular
echo "=== flipping to =m ==="
for s in $MODULARISE; do
    ./scripts/config --module "CONFIG_$s"
    echo "  CONFIG_$s -> m"
done

# DO NOT CHANGE CONFIG_LOCALVERSION HERE.
#
# It is tempting, so that uname says which build is running. It is wrong: the
# T7's /lib/modules holds a tree stamped 7.1.3-sp11-stockcfg-gf2cc827b6b89, and
# DRM_MSM, ATH12K, SURFACE_AGGREGATOR and HID_GENERIC are all =m. A new suffix
# orphans every one of them - the machine comes up with no GPU, no wifi and no
# keyboard, which is exactly how integ21 would have looked if it had not matched.
# Keep the release string identical to whatever is installed on the root disk.
grep -q '^CONFIG_LOCALVERSION="-sp11-stockcfg-gf2cc827b6b89"$' .config || {
    echo "CONFIG_LOCALVERSION is not the installed modules' string - refusing"
    grep -E '^CONFIG_LOCALVERSION=' .config
    cp .config.before-typec-modular .config
    exit 1
}

make olddefconfig >/dev/null

echo
echo "=== verifying ==="
fail=0
for s in $MODULARISE; do
    v=$(grep -E "^CONFIG_$s=" .config | cut -d= -f2 || true)
    printf '  %-24s %s\n' "$s" "${v:-(unset)}"
    [ "$v" = m ] || { echo "    ^ NOT modular - something built-in still selects it"; fail=1; }
done
for s in $KEEP_BUILTIN; do
    v=$(grep -E "^CONFIG_$s=" .config | cut -d= -f2 || true)
    printf '  %-24s %s\n' "$s" "${v:-(unset)}"
    [ "$v" = y ] || { echo "    ^ MUST stay built in - root would be unreachable"; fail=1; }
done
grep -E '^CONFIG_LOCALVERSION=' .config
if [ "$fail" != 0 ]; then
    echo "REFUSING to build; restoring .config"
    cp .config.before-typec-modular .config
    exit 1
fi

echo
echo "=== building ($(nproc) jobs) ==="
make LOCALVERSION= -j"$(nproc)" Image vmlinuz.efi

ls -l arch/arm64/boot/Image arch/arm64/boot/vmlinuz.efi
cp arch/arm64/boot/vmlinuz.efi /mnt/c/sp11-stage/integ-vmlinuz-tcmod.efi
echo "staged -> /mnt/c/sp11-stage/integ-vmlinuz-tcmod.efi"
