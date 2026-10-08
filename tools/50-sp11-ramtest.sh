#!/bin/sh
# dracut pre-mount hook: boot the ADSP while root is NOT mounted, and report
# whether the USB-C disk survives.
#
# Installed inside the initramfs at
#   /usr/lib/dracut/hooks/pre-mount/50-sp11-ramtest.sh
#
# WHY HERE
#
# Every previous attempt ran from a booted desktop, where the root filesystem is
# the disk under test. That made the shell itself a casualty: bash's text is
# demand-paged off the dying disk, so the script died mid-experiment twice.
# Unbinding USB first did not help either - a dwc3/xhci rebind loses the Type-C
# orientation and mux configuration, which is only ever applied from
# pmic_glink_altmode notifications that do not recur, so the device never comes
# back regardless of the ADSP.
#
# At dracut's pre-mount stage the disk IS enumerated - initqueue waited for it -
# but root is NOT mounted and nothing is executing from it. The entire initramfs
# is RAM-backed, so sleep, cat and insmod all keep working after the disk goes.
# That is the state we have never been able to test from, and it is the same
# property a toram live boot would have bought, without needing an ISO.
#
# WHAT IT PROVES
#
#   disk survives  -> the drop is caused by having the disk in use, and booting
#                     the ADSP early is a real fix. dracut then mounts root and
#                     the machine comes up with audio.
#   disk drops     -> the charger_pd restart takes the port down no matter what
#                     is or is not using it. No ordering scheme helps, and audio
#                     needs root off the Type-C port.
#
# CONSTRAINTS: /bin/bash does not exist in this initramfs. POSIX sh only.

ESP_UUID=D297-77C3          # internal NVMe ESP - survives the T7 going away
MODS=/sp11/mods
ROOTWAIT=40                 # pre-mount fires at ~1.85s, mid-enumeration
WATCH=45

say() { echo "[sp11-ramtest] $*" > /dev/kmsg 2>/dev/null; echo "[sp11-ramtest] $*"; }

# root device, straight from the cmdline
ROOTSPEC=
read -r _cmdline < /proc/cmdline
for _a in $_cmdline; do
    case "$_a" in root=*) ROOTSPEC="${_a#root=}" ;; esac
done
case "$ROOTSPEC" in
    UUID=*) ROOTDEV="/dev/disk/by-uuid/${ROOTSPEC#UUID=}" ;;
    /dev/*) ROOTDEV="$ROOTSPEC" ;;
    *)      say "cannot parse root=; skipping"; return 0 2>/dev/null || exit 0 ;;
esac

# NOT a reason to bail. With MODE=hookonly the overlay carries this hook and
# nothing else, and the whole question that build asks is "does the disk turn
# up?" - which is answered below, before any module is needed. Bailing here
# would throw away the one measurement the build exists to take.
if [ -d "$MODS" ]; then HAVE_MODS=yes; else HAVE_MODS=no; fi

# ---- the Windows ESP, on the other physical disk ---------------------------
#
# Mounted BEFORE waiting for root, so there is always a log file even when the
# disk never turns up. The first run of this hook skipped silently and left
# nothing behind but one kmsg line.
MNT=/run/sp11esp
mkdir -p "$MNT"
dev=$(blkid -U "$ESP_UUID" 2>/dev/null)
if [ -z "$dev" ] || ! mount -t vfat -o rw,sync "$dev" "$MNT" 2>/dev/null; then
    say "cannot mount ESP $ESP_UUID; running anyway with kmsg only"
    LOG=/dev/null
else
    if [ ! -d "$MNT/EFI/Microsoft" ]; then
        say "wrong volume; refusing to write"
        umount "$MNT" 2>/dev/null
        LOG=/dev/null
    else
        mkdir -p "$MNT/sp11-diag"
        LOG=$MNT/sp11-diag/ramtest.log
        : > "$LOG"
        cat /dev/kmsg > "$MNT/sp11-diag/ramtest-kmsg.txt" 2>/dev/null &
        catpid=$!
    fi
fi

log() { printf '%s\n' "$*" >> "$LOG" 2>/dev/null; }

log "=== sp11-ramtest (dracut pre-mount) ==="
read -r up _ < /proc/uptime
log "entered at  : uptime $up"
log "root device : $ROOTDEV"
log "module payload: $HAVE_MODS  (no = MODE=hookonly bisect build)"

# ---- wait for the root device ---------------------------------------------
#
# pre-mount does NOT run after initqueue has found root, as first assumed - it
# fires at ~1.85 s, right as the disk is still enumerating, and the first run of
# this hook exited immediately on a bare [ -e ] test. Poll instead.
#
# The disk being enumerated but UNMOUNTED is the whole point of running here, so
# it is worth waiting for.
w=0
while [ "$w" -lt "$ROOTWAIT" ]; do
    [ -e "$ROOTDEV" ] && break
    sleep 1
    w=$((w + 1))
done

if [ ! -e "$ROOTDEV" ]; then
    read -r up _ < /proc/uptime
    log ""
    log "ROOT DEVICE NEVER APPEARED within ${ROOTWAIT}s (uptime $up)."
    log "  The disk did not enumerate at all this boot - nothing to do with the"
    log "  ADSP, which was never touched. usb devices present:"
    for d in /sys/bus/usb/devices/*; do log "    ${d##*/}"; done
    log "=== finished (experiment did not run) ==="
    say "root device never appeared; ADSP untouched"
    [ -n "${catpid:-}" ] && kill "$catpid" 2>/dev/null
    sync
    umount "$MNT" 2>/dev/null
    return 0 2>/dev/null || exit 0
fi

read -r up _ < /proc/uptime
log "root device appeared after ${w}s (uptime $up), NOT mounted"

# hookonly build: the measurement is complete the moment the disk shows up.
# Do not touch the ADSP - that is a different experiment.
if [ "$HAVE_MODS" = no ]; then
    log ""
    log "RESULT: THE DISK ENUMERATED with the overlay live and no payload."
    log "  So appending a second cpio archive is harmless by itself, and"
    log "  whatever stops the T7 in the full build is in the 22 MB of"
    log "  firmware/modules, not in the act of extending the initramfs."
    log "=== finished (hookonly bisect build; ADSP untouched) ==="
    say "disk present at ${w}s; hookonly build, ADSP untouched"
    [ -n "${catpid:-}" ] && kill "$catpid" 2>/dev/null
    sync
    umount "$MNT" 2>/dev/null
    return 0 2>/dev/null || exit 0
fi

say "booting the ADSP with root unmounted. Disk present: yes"

# ---- load the driver stack; firmware is in this initramfs ------------------
log ""
log "-- loading modules --"
while read -r m; do
    [ -n "$m" ] || continue
    if insmod "$MODS/$m" 2>/dev/null; then log "  insmod $m"; else log "  insmod $m FAILED"; fi
done < "$MODS/ORDER"

# ---- watch ----------------------------------------------------------------
log ""
log "-- watching (the ADSP boots as qcom_q6v5_pas probes) --"
gone=; back=; i=0
while [ "$i" -lt "$WATCH" ]; do
    if [ -e "$ROOTDEV" ]; then
        p=yes
        [ -n "$gone" ] && [ -z "$back" ] && { read -r back _ < /proc/uptime; }
    else
        p=no
        [ -z "$gone" ] && { read -r gone _ < /proc/uptime; }
    fi
    st=none
    for r in /sys/class/remoteproc/remoteproc*; do
        [ -e "$r/name" ] || continue
        read -r nm < "$r/name"
        [ "$nm" = adsp ] && { read -r st < "$r/state"; break; }
    done
    read -r now _ < /proc/uptime
    log "  t+${i}s uptime=$now rootdev=$p adsp=$st"
    [ -n "$back" ] && break
    sleep 1
    i=$((i + 1))
done

log ""
if [ -z "$gone" ]; then
    log "RESULT: THE DISK NEVER WENT AWAY."
    log "  Booting the ADSP with root unmounted does not drop the port."
    log "  Early boot is a real fix - this hook can stay, and the machine"
    log "  should now come up with audio."
elif [ -n "$back" ]; then
    log "RESULT: dropped at $gone, RETURNED at $back."
    log "  The port re-enumerates when nothing holds the disk. Early boot works."
else
    log "RESULT: dropped at $gone and did not return within ${WATCH}s."
    log "  The charger_pd restart takes the port down regardless of whether"
    log "  anything is using the disk. No ordering scheme can fix this;"
    log "  audio needs the root filesystem off the Type-C port."
    log "  Root will fail to mount below - that is expected, not a new fault."
fi

log ""
log "glink channels on the ADSP edge:"
for d in /sys/bus/rpmsg/devices/6800000.remoteproc:glink-edge.*; do
    [ -e "$d" ] || continue
    n=${d##*glink-edge.}; n=${n%.*.*}
    log "  $n"
done
log "=== finished ==="

[ -n "${catpid:-}" ] && kill "$catpid" 2>/dev/null
sync
umount "$MNT" 2>/dev/null
say "done - read W:\\sp11-diag\\ramtest.log"
