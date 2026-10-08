#!/bin/bash
# Stop udev auto-loading the Type-C drivers that reconfigure a live USB-C port.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-set-typec-blacklist.sh [on|off]
#   tools\sp11-disk.ps1 to-win
#
# WHY
#
# 2026-08-05, from the winlog on the internal NVMe - the one log that survives
# the T7 dying:
#
#   1.262  usb 4-1: new SuperSpeed Plus Gen 2x1 USB device number 2
#   5.772  qcom_pmic_glink: Failed to create device link with supplier 3-0008
#   5.788  qcom_pmic_glink: Failed to create device link with supplier 5-0008
#   5.802  usb 4-1: cmd cmplt err -71            <- -EPROTO
#   5.813  usb 4-1: USB disconnect, device number 2
#
# 3-0008 and 5-0008 are the ps8830 retimers. Thirty milliseconds after they come
# into play the link dies. UEFI has already configured the retimer and mux for
# whatever is plugged in; ps883x probing resets the chip and drops the link out
# from under a mounted root filesystem.
#
# Note the speed: with these drivers built in, the port got reconfigured during
# early boot and the disk fell back to USB 2.0 high-speed (~40 MB/s) on bus 3.
# Left alone, UEFI's configuration survives and it comes up at 10 Gb/s on bus 4.
#
# COST: no USB-C DisplayPort alt mode, and no UCSI. The internal panel is eDP and
# is unaffected. blacklist only stops UDEV autoloading - `modprobe ps883x` by
# hand still works, which is what makes the experiments below possible.
set -eu

ACTION=${1:-on}
M=/mnt/sp11root
CONF="$M/etc/modprobe.d/sp11-typec.conf"
ADSPCONF="$M/etc/modprobe.d/sp11-adsp.conf"
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }

mkdir -p "$M"
mountpoint -q "$M" && umount "$M"
mount "$DEV" "$M"
trap 'sync; umount "$M" 2>/dev/null || true' EXIT

case "$ACTION" in
ucsi-only)
    # ps883x MUST stay loadable for two separate reasons, both learned the hard
    # way on 2026-08-05:
    #
    #  1. msm is a component driver. It will not complete until every
    #     displayport-controller registers, including the two USB-C ones at
    #     ae90000 and ae98000. Without the retimer they sit at
    #     "failed to acquire drm_bridge" forever, msm_dpu never binds, and there
    #     is no display at all.
    #  2. Nothing else claims the retimer's regulators. At ~31s the unused-
    #     regulator sweep switched VREG_RTMR0/1_1P15/1P8/3P3 off and the disk
    #     disconnected 2ms later. regulator_ignore_unused on the cmdline covers
    #     that, but the driver claiming them is the real answer.
    #
    # So blacklist only ucsi_glink, to find out which of the two actually
    # destroys the live link at ~5.8s.
    cat > "$CONF" <<'EOF'
# Installed by tools/sp11-set-typec-blacklist.sh ucsi-only
#
# Discriminator: keep ps883x (the display needs it - msm will not bind without
# the USB-C DP controllers) and drop only ucsi_glink. If the disk survives, the
# UCSI connector bring-up was what killed it. If it still dies around 5.8s with
# "cmd cmplt err -71", the ps8830 retimer reset is the culprit.
blacklist ucsi_glink
EOF
    echo "=== wrote $CONF (ucsi_glink only) ==="
    cat "$CONF" | sed 's/^/  /'
    ;;
on)
    cat > "$CONF" <<'EOF'
# Installed by tools/sp11-set-typec-blacklist.sh
#
# These drivers reconfigure the USB-C port after UEFI has already set it up.
# On this machine the root filesystem is ON that port, so a retimer reset
# disconnects the disk mid-boot: usb 4-1 cmd cmplt err -71, USB disconnect,
# ~30ms after the ps8830 retimers at i2c 3-0008 / 5-0008 come into play.
#
# Leaving them unloaded keeps UEFI's configuration, which also means the disk
# stays at SuperSpeed instead of falling back to USB 2.0.
#
# This only stops udev autoloading. `modprobe ps883x` still works by hand.
blacklist ps883x
blacklist ucsi_glink
blacklist typec_displayport
EOF
    echo "=== wrote $CONF ==="
    cat "$CONF" | sed 's/^/  /'
    ;;
noadsp)
    # 2026-08-05 late. Everything local has been eliminated as the cause of the
    # remaining intermittent -71: the retimer is not touched (ps883x logs
    # "no change, not touching the chip"), the PHY is not touched ("already in
    # mode 2"), and USB_QUIRK_NO_LPM did not prevent it either.
    #
    # What is left is that the -71 lands 14.9-16.3ms after the pmic_glink altmode
    # notification, and that notification comes FROM the ADSP - which is where
    # charger_pd, the owner of USB-C power delivery, runs. An ADSP *restart* is
    # already known to kill this port in 89ms. This tests whether merely
    # attaching and holding the first PD conversation can perturb it too.
    #
    # q6v5_pas drives both the ADSP and the CDSP, so this costs both. Precedent:
    # integ21-noadsp reached a desktop with exactly this blacklist, so the
    # display, GPU, wifi and keyboard are unaffected. Battery reporting is lost.
    cat > "$ADSPCONF" <<'EOF'
# Installed by tools/sp11-set-typec-blacklist.sh noadsp
#
# Diagnostic only. Without this driver Linux never attaches to the ADSP, so
# pmic_glink has no remote, no altmode notification arrives, and charger_pd is
# left entirely to firmware. If the intermittent root-disk -71 stops completely,
# the trigger is the ADSP conversation and not anything in the USB/typec path.
blacklist qcom_q6v5_pas
EOF
    echo "=== wrote $ADSPCONF ==="
    sed 's/^/  /' "$ADSPCONF"
    echo "=== existing $CONF left as-is ==="
    [ -f "$CONF" ] && sed 's/^/  /' "$CONF" || echo "  (none)"
    ;;
adsp-back)
    rm -f "$ADSPCONF"
    echo "=== removed $ADSPCONF - the ADSP and CDSP load again ==="
    ;;
off)
    rm -f "$CONF"
    echo "=== removed $CONF - udev will autoload the Type-C drivers again ==="
    ;;
*)
    echo "usage: $0 [on|ucsi-only|noadsp|adsp-back|off]"; exit 1 ;;
esac

sync
echo "done - now run: tools\\sp11-disk.ps1 to-win"
