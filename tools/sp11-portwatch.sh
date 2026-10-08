#!/bin/bash
# Answer the one open question: does the Type-C port re-enumerate after a
# charger_pd restart?
#
# Run this from a NORMAL BOOTED DESKTOP, as root:
#
#     sudo /usr/local/sbin/sp11-portwatch
#
# WHY NOT THE INITRAMFS
#
# The obvious place to do this is a dracut pre-mount shell, where nothing holds
# the root disk. That is impossible on this machine: there is no keyboard in the
# initramfs. Every input driver is a module -- SURFACE_AGGREGATOR, SURFACE_HID,
# HID_GENERIC and USB_HID are all =m in the stockcfg build -- and none of them is
# packed into the initrd. The Type Cover hangs off the Surface Aggregator
# Module, so it is not even a USB keyboard. The dracut prompt appears and
# nothing you type reaches it.
#
# So do it from a running system instead and accept that the root filesystem
# dies underneath us. We do not need root to survive. We need the log to survive,
# and the log goes to the INTERNAL NVMe's EFI System Partition -- a different
# physical disk, exactly as sp11-winlog does.
#
# HOW IT AVOIDS TOUCHING THE DYING DISK
#
#   - the ADSP firmware is staged into /run (tmpfs) and found via
#     /sys/module/firmware_class/parameters/path, so nothing is written to the
#     root filesystem and the firmware is still readable after it disappears
#   - the delay loop uses a bash builtin, not `sleep`. Staging /bin/sleep into
#     tmpfs is NOT enough and the first run of this script proved it: the binary
#     was in RAM but its dynamic loader and libc were still on the dying disk, so
#     every exec failed and 120 iterations elapsed in 1.2 seconds of real time.
#     `read -t` against a fifo opened beforehand needs no exec at all.
#   - one long-lived `cat /dev/kmsg`, exec'd before the trigger, never after
#   - the ESP is mounted -o sync, because this machine gets power-cycled at the
#     hang
#
# EXPECT TO POWER-CYCLE. When the disk goes, the desktop will wedge. Hold the
# power button, boot back into Windows, and read W:\sp11-diag\portwatch-kmsg.txt.
# Nothing is written to the T7 at any point.
#
# WHAT CHANGED SINCE THE FIRST RUN (2026-08-04)
#
# That run answered: the port does NOT come back, and cannot be forced back.
# PD recovered in ~280 ms and the mux was reprogrammed, but attach detection
# never re-ran, through two xhci and two dwc3 rebinds.
#
# Re-run it, because the thing it was measuring has changed underneath:
#
#   * patch 0001 stops ucsi_glink tearing the port down on a protection-domain
#     restart. On 2026-08-04 that bug was live and unpatched, and it is the
#     single most likely reason attach detection never re-ran. ucsi_glink is
#     loaded again as of 2026-08-05, so this is the first time 0001 is exercised
#     at all.
#   * patches 0002/0003/0004 stop three drivers reconfiguring a live retimer and
#     PHY.
#   * the +89 ms kill was originally measured during BOOT. The altmode
#     conversation turned out to be a boot-time race - fatal at 6 s, harmless at
#     66 s - so running this from a settled desktop is testing it at the hour of
#     the day that has been safe for everything else.
#
# Run it a minute after login, so sp11-altmode.service has fired and the stack is
# in its shipping configuration. `sync` first if you have unsaved work.
#
# The previous run's artefacts are preserved in
# Documents\sp11-logs\20260804-portwatch-baseline\ - this run overwrites
# portwatch.log and portwatch-kmsg.txt on the ESP.
set -u

ESP_UUID=D297-77C3      # internal NVMe ESP. The T7's is 5011-AB20 - not this one.
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
MNT=/run/sp11winesp
OUT=$MNT/sp11-diag
FWSTAGE=/run/sp11fw
BINSTAGE=/run/sp11bin
FWSUB=qcom/x1e80100/microsoft/Denali

# Budget, and why it is small. Once the root filesystem dies, bash's own text
# pages are backed by a dead device; if any of them is evicted and faulted back
# in, the script is gone. Measured twice: it survives roughly 45-50 s. So watch
# briefly, then force the rebind while there is still a process to do it. The
# first run put the forced phase after a 120 s watch and never reached it.
WATCH_BEFORE=8          # seconds to see whether it returns on its own
WATCH_AFTER=25          # seconds to see whether the rebind brought it back

say() { echo "[portwatch] $*"; echo "[portwatch] $*" > /dev/kmsg 2>/dev/null || true; }

[ "$(id -u)" = 0 ] || { echo "must be root"; exit 1; }
[ -e /etc/initrd-release ] && { echo "this is the initramfs; run it from a booted system"; exit 1; }

# ---- 1. stage the firmware into tmpfs --------------------------------------
#
# Do NOT rename the file on the root filesystem. Using the firmware_class search
# path keeps the disk untouched and keeps the firmware readable after the disk
# is gone.

mkdir -p "$FWSTAGE/$FWSUB"
src=/lib/firmware/$FWSUB
got=no
for f in qcadsp8380.mbn qcadsp8380.mbn.disabled; do
    if [ -f "$src/$f" ]; then
        cp "$src/$f" "$FWSTAGE/$FWSUB/qcadsp8380.mbn" && got=yes && break
    fi
done
[ "$got" = yes ] || { say "no qcadsp8380.mbn under $src; aborting"; exit 1; }
for f in adsp_dtb.mbn adspr.jsn adsps.jsn adspua.jsn battmgr.jsn; do
    [ -f "$src/$f" ] && cp "$src/$f" "$FWSTAGE/$FWSUB/$f" 2>/dev/null
done
say "staged firmware into $FWSTAGE ($(stat -c%s "$FWSTAGE/$FWSUB/qcadsp8380.mbn") bytes)"

echo -n "$FWSTAGE" > /sys/module/firmware_class/parameters/path 2>/dev/null ||
    { say "cannot set firmware_class path; aborting"; exit 1; }
say "firmware search path is now $(cat /sys/module/firmware_class/parameters/path)"

# ---- 2. a delay that survives the disk going away --------------------------
#
# NOT `sleep`. Copying /bin/sleep into tmpfs looks sufficient and is not: the
# binary is in RAM but ld-linux-aarch64.so.1 and libc are still on the disk that
# is about to vanish, so exec fails from the first iteration onward. The first
# run of this script burned its whole 120-iteration window in 1.2 seconds of
# real time for exactly that reason, and only the already-running `cat /dev/kmsg`
# saved the measurement.
#
# `read -t` is a bash builtin. Open the fifo now, while the disk is alive; after
# that, napping costs no exec, no library, and no filesystem access.

mkdir -p "$BINSTAGE"
FIFO=$BINSTAGE/nap
[ -p "$FIFO" ] || mkfifo "$FIFO" || { say "cannot create fifo; aborting"; exit 1; }
exec 9<> "$FIFO" || { say "cannot open fifo; aborting"; exit 1; }
nap() { read -t "$1" -u 9 _ 2>/dev/null || true; }

# prove it works before we depend on it
read -r _t0 _ < /proc/uptime; nap 1; read -r _t1 _ < /proc/uptime
say "nap check: 1s requested, $(awk "BEGIN{printf \"%.2f\", $_t1 - $_t0}" 2>/dev/null || echo '?')s elapsed"

# ---- 3. mount the Windows ESP, with the same guards as sp11-winlog ---------

dev=$(blkid -U "$ESP_UUID" 2>/dev/null)
[ -n "$dev" ] || { say "ESP $ESP_UUID not found; aborting"; exit 1; }
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -t vfat -o rw,sync,umask=0077 "$dev" "$MNT" ||
    { say "ESP mount failed; aborting"; exit 1; }
if [ ! -d "$MNT/EFI/Microsoft" ]; then
    say "no EFI/Microsoft on $dev - wrong volume, refusing"
    umount "$MNT"; exit 1
fi
mkdir -p "$OUT"
say "logging to $dev:/sp11-diag/portwatch-*"

LOG=$OUT/portwatch.log
: > "$LOG"
printf '=== portwatch %s ===\n' "$(date -Is 2>/dev/null)" >> "$LOG"

# ---- 4. the long-lived reader, started BEFORE the trigger ------------------

cat /dev/kmsg > "$OUT/portwatch-kmsg.txt" 2>/dev/null &
catpid=$!
nap 1

# ---- 5. find the ADSP and note where we started ----------------------------

adsp=
for r in /sys/class/remoteproc/remoteproc*; do
    [ -e "$r/name" ] || continue
    read -r nm < "$r/name"
    [ "$nm" = adsp ] && { adsp=$r; break; }
done
[ -n "$adsp" ] || { say "no adsp remoteproc found; is qcom_q6v5_pas loaded?"; kill $catpid; exit 1; }
read -r st0 < "$adsp/state"
say "adsp is $adsp, state '$st0'"
printf 'adsp %s state before: %s\n' "$adsp" "$st0" >> "$LOG"

ROOTDEV=/dev/disk/by-uuid/$ROOT_UUID

# DO NOT WATCH $ROOTDEV. It is a udev-created symlink, and udev's binaries live
# on the disk that is about to die - so once the port drops, nothing recreates
# it no matter what the hardware does. On 2026-08-06 the T7 re-attached 2.3s
# after the disconnect and this script still reported rootdev=no for 8 seconds,
# then "forced" a rebind that tore down a port which had already recovered.
#
# /proc/partitions is maintained by the kernel and needs no userspace at all.
# Snapshot the disk names now; anything new later is the drive coming back.
disks_now() {
    _d=
    while read -r _ _ _ name; do
        case "$name" in
            sd[a-z]|nvme*n[0-9]) _d="$_d $name" ;;
        esac
    done < /proc/partitions
    echo "$_d"
}
DISKS0=$(disks_now)
say "block devices before: $DISKS0"

# yes if a disk name exists that was not there before the restart
disk_returned() {
    _r=1
    while read -r _ _ _ name; do
        case "$name" in
            sd[a-z]|nvme*n[0-9])
                case " $DISKS0 " in
                    *" $name "*) ;;
                    *) _r=0 ;;
                esac ;;
        esac
    done < /proc/partitions
    return $_r
}

# ---- 6. trigger: make it boot the real image ------------------------------

say ""
say "restarting the ADSP onto the full image. charger_pd restarts with it and"
say "the Type-C port is expected to drop the root disk ~89ms later."
say "The desktop will wedge. That is expected. Power-cycle afterwards."
say ""
nap 2

read -r up0 _ < /proc/uptime

if [ "$st0" != offline ]; then
    echo stop > "$adsp/state" 2>/dev/null || say "stop failed"
    nap 1
fi
echo start > "$adsp/state" 2>/dev/null || say "start failed - trying driver rebind"

# ---- 7. watch. Builtins only from here down -------------------------------
#
# Past this point the root filesystem may vanish at any moment, so nothing below
# may start a new program: no `sleep`, no command substitution, no external
# tools. Builtins, redirections into sysfs/procfs, and the fifo nap. bash's own
# pages are still backed by the dying disk, which is the one risk left that
# cannot be designed away - keep this loop small so it stays resident.

gone=; back=; i=0
while [ "$i" -lt "$WATCH_BEFORE" ]; do
    read -r up _ < /proc/uptime 2>/dev/null || up='?'
    if [ -e "$ROOTDEV" ] || disk_returned; then
        present=yes
        [ -n "$gone" ] && [ -z "$back" ] && back=$up
    else
        present=no
        [ -z "$gone" ] && gone=$up
    fi
    read -r stnow < "$adsp/state" 2>/dev/null || stnow='?'
    printf 't=+%ss uptime=%s rootdev=%s adsp=%s\n' "$i" "$up" "$present" "$stnow" >> "$LOG"
    [ -n "$back" ] && break
    nap 1
    i=$((i + 1))
done

# ---- 7b. if it did not come back on its own, try to force it ---------------
#
# The first run showed the port does NOT re-enumerate by itself, but also that
# pmic_glink/UCSI recovers 260 ms after the disconnect - so PD is alive and it
# is the port's attach detection that never re-runs. That is worth poking at
# directly: tearing the host controller down and back up re-enumerates the whole
# bus. Everything here is echo into sysfs, which is a builtin, so it still costs
# no exec.

if [ -n "$gone" ] && [ -z "$back" ]; then
    printf '\n-- forcing re-enumeration --\n' >> "$LOG"
    for drv in xhci-hcd dwc3-qcom dwc3; do
        d=/sys/bus/platform/drivers/$drv
        [ -d "$d" ] || continue
        for dev in "$d"/*.auto "$d"/*.usb; do
            [ -e "$dev" ] || continue
            n=${dev##*/}
            printf 'unbind/bind %s from %s\n' "$n" "$drv" >> "$LOG"
            echo "$n" > "$d/unbind" 2>/dev/null || printf '  unbind failed\n' >> "$LOG"
            nap 2
            echo "$n" > "$d/bind" 2>/dev/null || printf '  bind failed\n' >> "$LOG"
            nap 3
            if [ -e "$ROOTDEV" ] || disk_returned; then
                read -r back _ < /proc/uptime
                printf 'ROOTDEV IS BACK after rebinding %s at uptime %s\n' "$n" "$back" >> "$LOG"
                break 2
            fi
        done
    done

    j=0
    while [ "$j" -lt "$WATCH_AFTER" ] && [ -z "$back" ]; do
        read -r up _ < /proc/uptime 2>/dev/null || up='?'
        # No command substitution here. $( ) forks a subshell, and while a fork
        # needs no exec and would probably survive, there is no reason to spend
        # the risk on a yes/no string.
        if [ -e "$ROOTDEV" ] || disk_returned; then present=yes; back=$up; else present=no; fi
        printf 'forced t=+%ss uptime=%s rootdev=%s\n' "$j" "$up" "$present" >> "$LOG"
        nap 1
        j=$((j + 1))
    done
fi

# ---- 8. verdict ------------------------------------------------------------

{
    printf '\n'
    if [ -z "$gone" ]; then
        printf 'RESULT: the disk never went away.\n'
        printf '  Either the port survived the charger_pd restart or the ADSP\n'
        printf '  did not actually restart. Check adsp state above.\n'
    elif [ -n "$back" ]; then
        printf 'RESULT: THE PORT RE-ENUMERATES.\n'
        printf '  gone at uptime %s, back at uptime %s\n' "$gone" "$back"
        printf '  A dracut pre-mount hook can do this on every boot and root\n'
        printf '  will still mount afterwards. Audio is reachable.\n'
    else
        printf 'RESULT: the disk did NOT come back, before or after the rebind.\n'
        printf '  gone at uptime %s. Check the rebind lines above: if unbind\n' "$gone"
        printf '  and bind both succeeded and the device still did not appear,\n'
        printf '  the controller genuinely cannot re-find it and audio needs\n'
        printf '  the root filesystem off the Type-C port.\n'
    fi
    printf '\nglink channels on the ADSP edge now:\n'
    for d in /sys/bus/rpmsg/devices/6800000.remoteproc:glink-edge.*; do
        [ -e "$d" ] || continue
        n=${d##*glink-edge.}; n=${n%.*.*}
        printf '  %s\n' "$n"
    done
    printf '=== portwatch finished ===\n'
} >> "$LOG"

kill "$catpid" 2>/dev/null
say "done - read W:\\sp11-diag\\portwatch.log from Windows"
umount "$MNT" 2>/dev/null
