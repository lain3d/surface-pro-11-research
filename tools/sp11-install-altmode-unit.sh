#!/bin/bash
# Install the systemd unit that turns altmode notifications on after boot.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-install-altmode-unit.sh [on|off]
#   tools\sp11-disk.ps1 to-win
#
# WHY
#
# pmic_glink_altmode.pan_enable=0 on the cmdline buys a reliable boot but costs
# USB-C DisplayPort outright, because drm_aux_hpd_bridge_notify() is only ever
# called from the worker those notifications drive.
#
# 2026-08-05: writing 1 by hand at 66s and 72s of uptime was safe both times and
# the external display came up. Every failure on record landed at 6.1-6.5s. So
# the fault is a boot-time race, not the conversation - and a late enable gets
# both. This automates that.
#
# Enabling is done by symlink rather than `systemctl enable`, because systemctl
# wants a running systemd and this runs from WSL against a mounted disk.
set -eu

ACTION=${1:-on}
M=/mnt/sp11root
UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
REPO=${REPO:-/mnt/c/Users/Crazy/projs/arm64-egpu/tools}
UNIT=sp11-altmode.service

DEV=$(blkid -U "$UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }

mountpoint -q "$M" 2>/dev/null && umount "$M"
mkdir -p "$M"
mount -o rw "$DEV" "$M"
trap 'sync; umount "$M" 2>/dev/null || true' EXIT
[ -f "$M/etc/os-release" ] || { echo "not the root fs - refusing"; exit 1; }

DST="$M/etc/systemd/system/$UNIT"
LINK="$M/etc/systemd/system/multi-user.target.wants/$UNIT"

case "$ACTION" in
on)
    cp "$REPO/$UNIT" "$DST"
    sed -i 's/\r$//' "$DST"
    chmod 644 "$DST"
    mkdir -p "${LINK%/*}"
    ln -sf "/etc/systemd/system/$UNIT" "$LINK"
    echo "=== installed and enabled ==="
    echo "  $DST"
    echo "  $LINK -> $(readlink "$LINK")"
    ;;
off)
    rm -f "$LINK" "$DST"
    echo "=== removed $UNIT and its multi-user.target.wants symlink ==="
    ;;
*)
    echo "usage: $0 [on|off]"; exit 1 ;;
esac

echo
echo "=== verify ==="
ls -l "$M/etc/systemd/system/$UNIT" 2>/dev/null | sed 's/^/  /' || echo "  unit absent"
ls -l "$LINK" 2>/dev/null | sed 's/^/  /' || echo "  not enabled"
echo
echo "The cmdline must still carry pmic_glink_altmode.pan_enable=0 - this unit"
echo "turns it on later, it does not replace it. Check with:"
echo "  journalctl -b -u $UNIT   (or grep sp11-altmode in dmesg)"
sync
