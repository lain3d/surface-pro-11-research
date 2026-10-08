#!/usr/bin/env bash
# Re-negotiate the USB-C display's connector after the ADSP restart, so the
# monitor comes up without being physically replugged.
#
# WHY
#
# The dracut pre-mount hook restarts the ADSP at ~3.9 s. charger_pd restarts
# with it and loses all its PD state; the port comes back as plain USB and DP
# alt mode is never re-entered for a sink that was already attached. At ~72 s
# sp11-altmode.service turns pan_enable on, PAN_EN goes out, and charger_pd
# truthfully answers mux_set mode=1 - TYPEC_STATE_USB. Only a cable insertion
# makes it negotiate DP again.
#
# UCSI_CONNECTOR_RESET is that insertion, in software. No patch is needed:
# drivers/usb/typec/ucsi/debugfs.c is built whenever CONFIG_DEBUG_FS=y and
# ucsi_cmd() whitelists the command.
#
# WHY NOT IN THE INITRAMFS, WHERE IT WOULD BE SAFER
#
# Tried, in integ39, and it cannot work. UCSI's initialisation is gated on the
# pmic_glink PDR "up" event, and that only arrives when charger_pd restarts - so
# UCSI cannot read or command the port until after the very restart that
# destroyed what we wanted. Measured identically on two boots: insmod at 4.07 s,
# nothing for 15 s, ADSP restart at 19.17 s, PDR up at 19.52 s, UCSI alive at
# 19.86 s. Loading it early also cost 78 UCSI re-inits instead of 1, and delayed
# the sound card to 39.6 s - past the point where PipeWire builds its nodes, so
# audio disappeared.
#
# HOW THE CONNECTOR IS FOUND, WITH NO SETUP AND NO UNPLUGGING
#
# Not from PD state, which is exactly what the restart destroys - from the
# static wiring. x1-microsoft-denali.dtsi ties each pmic-glink connector to one
# USB controller:
#
#   connector@0  /* Left-side bottom port */ -> usb_1_ss0_dwc3_hs
#   connector@1  /* Left-side top port    */ -> usb_1_ss1_dwc3_hs
#
# and hamoa.dtsi gives those controllers their addresses: usb_1_ss0 is
# a600000.usb, usb_1_ss1 is a800000.usb, usb_1_ss2 is a000000.usb. UCSI numbers
# connectors from 1 in registration order, so connector@N is UCSI connector N+1.
#
# So: find which controller the root filesystem's disk hangs off, and that is
# the ONE connector never to touch. Reset the others - which is where a display
# can be - and if nothing is attached to them, do nothing.
#
# That inverts the safety problem. Rather than trying to prove a connector IS
# the display, which needs the PD data we no longer have, prove which one is the
# disk, which is static and always knowable. Resetting the disk's connector
# drops it with root mounted rw, aborts the ext4 journal and ends the session,
# so that is the only thing that has to be right.
#
# /etc/sp11-dp-connector overrides the derivation if it exists.
set -uo pipefail

CONNFILE=${SP11_DP_CONNFILE:-/etc/sp11-dp-connector}

log() {
    echo "sp11-dp-reset: $*"
    echo "sp11-dp-reset: $*" > /dev/kmsg 2>/dev/null || true
}

# ---- which UCSI connector carries the root filesystem? ----------------------
#
# Three outcomes, and the difference matters:
#
#   "none ..."   root is not on USB at all - internal NVMe, eMMC, whatever. No
#                connector carries it, so every attached connector is safe to
#                reset and nothing has to be excluded.
#   "<N> ..."    root is on the USB controller wired to connector N. That one is
#                untouchable; the rest are fair game.
#   failure      root IS on USB but the controller is not in the table below.
#                Refuse: an unknown USB controller might be the one we would be
#                about to reset.
#
# The NVMe case is the one this machine should eventually be in, and it is also
# how ubuntu-surface-pro-11 runs - which is why the pre-mount hook is not needed
# there. The DISPLAY problem is not solved by moving root, though: the ADSP
# restart still happens, because audio needs it, so charger_pd still loses its
# PD state and an attached display still needs this reset.
disk_connector() {
    _src=$(findmnt -no SOURCE / 2>/dev/null) || return 1
    [ -n "$_src" ] || return 1
    _pk=$(lsblk -no PKNAME "$_src" 2>/dev/null | head -1)
    # no parent (whole-disk root) - fall back to the source itself
    [ -n "$_pk" ] || _pk=$(basename "$_src")
    _path=$(readlink -f "/sys/class/block/$_pk" 2>/dev/null) || return 1
    [ -n "$_path" ] || return 1

    # Is it behind a USB host controller at all? A USB disk's sysfs path runs
    # .../<addr>.usb/<addr>.dwc3/xhci-hcd.N.auto/usbX/X-1/... - an NVMe one goes
    # through pcie and never mentions usb.
    case "$_path" in
        *.usb/*|*/usb[0-9]*/*) ;;
        *) echo "none - $_pk is not behind a USB controller"; return 0 ;;
    esac

    _addr=$(printf '%s\n' "$_path" | sed -n 's|.*/\([0-9a-f]\{6,8\}\)\.usb/.*|\1|p' | head -1)
    [ -n "$_addr" ] || return 1
    case "$_addr" in
        a600000) echo "1 $_addr usb_1_ss0 connector@0" ;;   # left-side bottom
        a800000) echo "2 $_addr usb_1_ss1 connector@1" ;;   # left-side top
        a000000) echo "3 $_addr usb_1_ss2 connector@2" ;;
        *)       return 1 ;;
    esac
}

# ---- which connectors exist, and which have something attached -------------
attached_connectors() {
    for _p in /sys/class/typec/port[0-9]; do
        [ -d "$_p" ] || continue
        _n=${_p##*/}
        [ -d "$_p-partner" ] && echo $(( ${_n#port} + 1 ))
    done
}

if [ -r "$CONNFILE" ]; then
    read -r FORCED < "$CONNFILE"
    case "$FORCED" in
        ''|*[!0-9]*) log "'$FORCED' in $CONNFILE is not a connector number"; exit 1 ;;
    esac
    TARGETS=$FORCED
    log "connector $FORCED, from $CONNFILE"
    if DISKINFO=$(disk_connector); then
        DISKCONN=${DISKINFO%% *}
        log "root disk: connector $DISKCONN (${DISKINFO#* })"
        if [ "$DISKCONN" = "$FORCED" ]; then
            log "REFUSING: $CONNFILE names the connector the root filesystem is on"
            exit 1
        fi
    else
        log "root disk is on USB but its controller is unrecognised - trusting $CONNFILE anyway"
    fi
else
    DISKINFO=$(disk_connector) || {
        log "root is on USB but the controller is unrecognised - refusing to reset anything"
        log "write the display's connector number to $CONNFILE to override"
        exit 1
    }
    DISKCONN=${DISKINFO%% *}
    if [ "$DISKCONN" = none ]; then
        # Nothing we can reset can take the root filesystem with it.
        log "root is not on USB (${DISKINFO#* }) - every attached connector is safe"
        DISKCONN=
    else
        log "root disk is on connector $DISKCONN (${DISKINFO#* }) - never touching that one"
    fi
    TARGETS=
    for c in $(attached_connectors); do
        [ -n "$DISKCONN" ] && [ "$c" = "$DISKCONN" ] && continue
        TARGETS="$TARGETS $c"
    done
    TARGETS=$(echo $TARGETS)
    [ -n "$TARGETS" ] && log "candidates with something attached: $TARGETS" ||
        { log "nothing attached to any resettable connector - nothing to do"; exit 0; }
fi

# ---- the debugfs command interface -----------------------------------------
mountpoint -q /sys/kernel/debug 2>/dev/null ||
    mount -t debugfs none /sys/kernel/debug 2>/dev/null || true

UCSIDIR=
for d in /sys/kernel/debug/usb/ucsi/*/ /sys/kernel/debug/ucsi/*/; do
    [ -e "$d/command" ] && UCSIDIR=$d && break
done
[ -n "$UCSIDIR" ] || { log "no ucsi debugfs command file - is typec_ucsi loaded?"; exit 1; }

for CONN in $TARGETS; do
    PORT=port$(( CONN - 1 ))

    if [ ! -d "/sys/class/typec/$PORT-partner" ]; then
        log "connector $CONN: no partner attached, skipping"
        continue
    fi

    # If DP alt mode is already registered the display is working - resetting
    # would blank it for a couple of seconds for nothing.
    _already=no
    for a in /sys/class/typec/"$PORT"-partner.*; do
        [ -e "$a/svid" ] || continue
        read -r svid < "$a/svid"
        [ "$svid" = "ff01" ] && _already=yes
    done
    if [ "$_already" = yes ]; then
        log "connector $CONN: DP alt mode already registered, leaving it alone"
        continue
    fi

    # 0x03 in bits 0-7, connector in bits 16-22. BIT(23) is the hard-reset flag
    # and its sense is version-dependent; clear is a hard reset on 1.1+ and
    # 2.0+, which covers everything except a 1.0 LPM.
    CMD=$(printf '0x%08x' $(( 0x03 | (CONN << 16) )))
    log "connector $CONN: resetting with $CMD"
    sync
    if echo "$CMD" > "${UCSIDIR}command" 2>/tmp/sp11-dp-reset.err; then
        log "connector $CONN: accepted"
    else
        log "connector $CONN: rejected: $(cat /tmp/sp11-dp-reset.err 2>/dev/null)"
        continue
    fi

    sleep 5
    for a in /sys/class/typec/"$PORT"-partner.*; do
        [ -e "$a/svid" ] || continue
        read -r svid < "$a/svid"
        log "connector $CONN: after reset $(basename "$a") svid=$svid"
    done
done
log "done"
