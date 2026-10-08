#!/bin/bash
# Turn on the pmic_glink altmode conversation AFTER the desktop is up, and watch
# whether the root disk survives it.
#
# Run this ON the Surface, from a terminal, as root:
#
#     sudo ./sp11-try-altmode.sh
#
# WHY
#
# pan_enable=0 buys a reliable boot (34 clean boots) but costs USB-C
# DisplayPort outright: drm_aux_hpd_bridge_notify() is only ever called from the
# altmode worker, so with no notifications the DPU is never told a monitor
# exists. UCSI sees the display - it enumerates DP alt mode SVID 0xff01 - and
# nothing lights up.
#
# Every observed failure landed at ~6.1-6.5s of boot and none afterwards. If the
# danger is a boot-time race rather than the conversation itself, requesting
# notifications now gets both.
#
# WHAT IT COSTS IF IT GOES WRONG
#
# The USB link drops, SCSI returns DID_NO_CONNECT and ext4 remounts read-only.
# The filesystem is recoverable (tools/sp11-fsck.sh from the host) but you will
# need a hard power-off. Nothing is written to the disk by this script, and it
# syncs before it starts so there is nothing in flight.
set -u

P=/sys/module/pmic_glink_altmode/parameters/pan_enable

[ "$(id -u)" -eq 0 ] || { echo "must be root"; exit 1; }
[ -w "$P" ] || { echo "no writable $P - is this integ34 or later?"; exit 1; }

cur=$(cat "$P")
echo "pan_enable is currently: $cur"
[ "$cur" = "N" ] || { echo "already on; nothing to do"; exit 0; }

echo "syncing so there is nothing in flight..."
sync

echo
echo "root filesystem before:"
awk '$2 == "/" {print "  " $1 " " $3 " " $4}' /proc/mounts

echo
echo "turning altmode notifications on..."
echo 1 > "$P"

# Watch for 20s. Read /proc/mounts through a redirect - no process spawn, so
# this keeps working even after the disk stops serving exec.
i=0
while [ "$i" -lt 20 ]; do
    line=
    while read -r _ mp _ opts _; do
        [ "$mp" = "/" ] && { line=$opts; break; }
    done < /proc/mounts
    case "$line" in
        *ro,*|*emergency_ro*) echo "t+${i}s  ROOT WENT READ-ONLY - the link dropped"; break ;;
    esac
    printf 't+%ss  root=%s\n' "$i" "$line"
    sleep 1
    i=$((i + 1))
done

echo
echo "=== what the kernel said ==="
dmesg | tail -40 | grep -iE "altmode|pan_enable|typec|switch_set|mux_set|cmd cmplt|DID_NO_CONNECT|hpd|drm" || \
    dmesg | tail -20

echo
echo "If a monitor is attached over USB-C it should light up now. If root went"
echo "read-only instead, power-cycle; the previous UKI is unaffected and the"
echo "next boot starts with pan_enable=0 again."
