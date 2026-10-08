#!/bin/bash
# Hide or restore the ADSP firmware on the Surface's root filesystem.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-adsp-fw.sh off   # or: on
#   tools\sp11-disk.ps1 to-win
#
# Why this exists, rather than just blacklisting qcom_q6v5_pas:
#
# The ADSP is ALREADY RUNNING, booted by Qualcomm firmware before Linux starts.
# When qcom_q6v5_pas finds qcadsp8380.mbn it *restarts* it -
#
#     remoteproc0: restarting adsp with new firmware
#
# - which restarts charger_pd, the protection domain that owns USB-C power
# delivery, and 89ms later the Type-C port drops the root disk. Blacklisting the
# whole module avoids that but also loses the CDSP, and with it fastrpc/NPU.
#
# The CDSP is COLD. Its log line is "powering up cdsp", not "restarting", so
# booting it is a different operation - and in every failing boot it completed
# at ~10.6s with the disk still healthy through 11.7s. Hiding only the ADSP
# firmware reproduces stock's harmless "request_firmware failed: -2" for
# remoteproc0 while letting remoteproc1 boot normally.
#
# Pair this with a UKI whose cmdline does NOT blacklist qcom_q6v5_pas
# (BOOTAA64-integ20-fixedreg.efi); integ21 blacklists the module, so hiding the
# firmware would change nothing.
#
# Audio still will not work - that lives on the ADSP. This buys the CDSP back.
set -u
M=/mnt/sp11root
UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
D=lib/firmware/qcom/x1e80100/microsoft/Denali
FW=qcadsp8380.mbn
MODE=${1:-}

case "$MODE" in
  off|on) ;;
  *) echo "usage: $0 off|on"; exit 1 ;;
esac

if mountpoint -q "$M" 2>/dev/null; then umount "$M" || exit 1; fi
mkdir -p "$M"
DEV=$(blkid -U "$UUID") || { echo "root not visible - run sp11-disk.ps1 to-wsl"; exit 1; }
mount -o rw "$DEV" "$M" || { echo "mount rw failed"; exit 1; }
echo "mounted $DEV at $M (rw)"
trap 'sync; umount "$M" 2>/dev/null && echo "unmounted"' EXIT

[ -f "$M/etc/os-release" ] && [ -d "$M/lib/firmware" ] || { echo "not the root fs - refusing"; exit 1; }

cd "$M/$D" || { echo "no $D"; exit 1; }

if [ "$MODE" = off ]; then
    if [ -f "$FW" ]; then
        mv "$FW" "$FW.disabled" && echo "hid $FW -> $FW.disabled"
    elif [ -f "$FW.disabled" ]; then
        echo "$FW already hidden"
    else
        echo "neither $FW nor $FW.disabled present"; exit 1
    fi
else
    if [ -f "$FW.disabled" ]; then
        mv "$FW.disabled" "$FW" && echo "restored $FW"
    else
        echo "$FW.disabled not present"; exit 1
    fi
fi

echo
echo "--- $D ---"
ls -la . | grep -E 'qcadsp|qccdsp' | sed 's/^/  /'
