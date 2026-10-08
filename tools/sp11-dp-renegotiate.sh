#!/usr/bin/env bash
# Try to get the USB-C display back without unplugging it.
#
# THE PROBLEM
#
# The dracut pre-mount hook restarts the ADSP at ~3.9 s. charger_pd restarts
# with it and tears the Type-C port down; when it comes back it brings the port
# up as plain USB and never re-enters DP alt mode for a sink that was already
# attached. Proof, from every integ38 boot, at the moment pan_enable goes on:
#
#   fd5000.phy-mux: qmp_combo_mux_set() enter mode=1, altmode=0
#
# mode=1 is TYPEC_STATE_USB. On 2026-08-05, before the ADSP restart existed,
# the same moment logged mode=5 - TYPEC_DP_STATE_D, two DP lanes. So Linux is
# being told the truth: there is no DP on that port. Replugging works because it
# forces a full PD negotiation, which does enter DP alt mode.
#
# WHAT CANNOT WORK, ESTABLISHED FROM SOURCE
#
# Writing 1 to /sys/class/typec/portN-partner/*/active. UCSI registers the
# partner's alt modes but implements no typec_altmode_ops, so there is no
# .activate and the write returns -EOPNOTSUPP.
#
# WHAT CAN, AND NEEDS NO PATCH
#
# UCSI ships a debugfs command interface - drivers/usb/typec/ucsi/debugfs.c,
# built whenever CONFIG_DEBUG_FS=y, which it is - and ucsi_cmd() explicitly
# whitelists UCSI_CONNECTOR_RESET. So a connector reset, which is what a replug
# is, is one write to
#
#   /sys/kernel/debug/usb/ucsi/<device>/command
#
# Command encoding, from ucsi.h:
#   UCSI_CONNECTOR_RESET      = 0x03            bits 0-7
#   UCSI_CONNECTOR_NUMBER(n)  = n << 16         bits 16-22
#   BIT(23)                   = hard-reset flag, and its meaning depends on the
#                               UCSI version the LPM reports:
#     < 1.1   set   = Hard Reset
#     1.1-1.x (the field does not exist; the command IS a hard reset)
#     >= 2.0  clear = Hard Reset, set = Data Reset
#
# So BIT(23) clear is a hard reset everywhere except 1.0, and BIT(23) set is a
# hard reset only on 1.0. The version is not exported, so --try-reset sends the
# clear form first and offers the other if nothing moves.
#
# WHAT THIS TRIES
#
#   --try-pan    re-send ALTMODE_PAN_EN by toggling pan_enable 0 -> 1, and see
#                whether charger_pd re-reports the port. Cheap and safe: the
#                boot-time race that made PAN_EN dangerous is long past by the
#                time you can run this.
#   --try-swap   a USB data-role swap on the display's port, which puts a PD
#                message exchange on the wire and may prompt re-discovery.
#   --try-reset  UCSI_CONNECTOR_RESET on the display's connector. This is the
#                one that matches what a physical replug does.
#
# With no options it only reports, and touches nothing.
#
# SAFETY - READ THIS
#
# The root filesystem is on the OTHER Type-C port, and resetting that connector
# would drop the disk with root mounted rw, which aborts the ext4 journal and
# ends the session. So --try-swap and --try-reset will only act on a port whose
# partner advertises DP alt mode (SVID ff01). A USB SSD does not advertise it,
# so the disk's connector cannot be selected. If more than one port matches, or
# none does, they refuse rather than guess. --try-reset additionally needs --yes
# and syncs the filesystem first.
set -uo pipefail

DPSVID=ff01
say()   { echo "  $*"; }
head1() { echo; echo "=== $* ==="; }

MODE=report
YES=no
CONNOVERRIDE=
HARDBIT=clear
while [ $# -gt 0 ]; do
    case "$1" in
        --try-pan)   MODE=pan ;;
        --try-swap)  MODE=swap ;;
        --try-reset) MODE=reset ;;
        --learn)     MODE=learn ;;
        --report)    MODE=report ;;
        --yes)       YES=yes ;;
        --hard-bit-set) HARDBIT=set ;;
        --connector) CONNOVERRIDE=${2:-}; shift ;;
        *) echo "usage: $0 [--report|--try-pan|--try-swap|--try-reset [--yes]]" >&2
           echo "       [--connector N] [--hard-bit-set]" >&2; exit 1 ;;
    esac
    shift
done

# ---- what the kernel currently thinks ---------------------------------------
head1 "root filesystem, so you know what NOT to disturb"
ROOTSRC=$(findmnt -no SOURCE / 2>/dev/null)
say "root:  $ROOTSRC"
ROOTDISK=$(lsblk -no PKNAME "$ROOTSRC" 2>/dev/null | head -1)
if [ -n "${ROOTDISK:-}" ]; then
    USBPATH=$(readlink -f "/sys/class/block/$ROOTDISK" 2>/dev/null | grep -o 'usb[0-9]*/[0-9-]*' | head -1)
    say "disk:  /dev/$ROOTDISK  usb path: ${USBPATH:-unknown}"
fi

head1 "type-c ports"
DPPORT=
DPCOUNT=0
for p in /sys/class/typec/port[0-9]; do
    [ -d "$p" ] || continue
    n=${p##*/}
    say "$n: data_role=$(cat "$p/data_role" 2>/dev/null) power_role=$(cat "$p/power_role" 2>/dev/null) port_type=$(cat "$p/port_type" 2>/dev/null)"
    if [ -d "$p-partner" ]; then
        say "   partner: present  type=$(cat "$p-partner/type" 2>/dev/null) pd_revision=$(cat "$p-partner/usb_power_delivery_revision" 2>/dev/null)"
        say "   identity: id_header=$(cat "$p-partner/identity/id_header" 2>/dev/null) product=$(cat "$p-partner/identity/product" 2>/dev/null)"
        for a in /sys/class/typec/"$n"-partner.* "$p-partner"/"$n"-partner.*; do
            [ -d "$a" ] || continue
            svid=$(cat "$a/svid" 2>/dev/null)
            act=$(cat "$a/active" 2>/dev/null)
            say "   altmode $(basename "$a"): svid=$svid active=$act"
            if [ "$svid" = "$DPSVID" ]; then
                DPPORT=$n
                DPCOUNT=$((DPCOUNT + 1))
            fi
        done
    else
        say "   partner: none"
    fi
done
[ -n "$DPPORT" ] && say "display (DP alt mode) appears to be on: $DPPORT" \
                 || say "no partner advertising DP alt mode (svid $DPSVID) was found"

# ---- the learned connector, which does not depend on any of that -----------
#
# UCSI_CAP_ALT_MODE_DETAILS is present on this machine - features 0x0004 is
# exactly that bit - but after a charger_pd restart the PPM holds no PD
# discovery state for a partner that was already attached, so
# GET_ALTERNATE_MODES returns nothing and the DP discriminator is unavailable in
# precisely the situation we need it. The connector number is a property of the
# physical socket though, so learning it once is enough. See --learn.
LEARNFILE="${XDG_CONFIG_HOME:-$HOME/.config}/sp11-dp-connector"
LEARNED=$(cat "$LEARNFILE" 2>/dev/null)
say ""
if [ -n "$LEARNED" ]; then
    say "learned display connector: $LEARNED   (from $LEARNFILE)"
else
    say "no learned connector yet - run --learn once, with the display attached"
fi

head1 "ucsi debugfs command interface"
UCSIDIR=$(sudo sh -c 'ls -d /sys/kernel/debug/usb/ucsi/*/ /sys/kernel/debug/ucsi/*/ 2>/dev/null' | head -1)
if [ -n "${UCSIDIR:-}" ]; then
    say "found: $UCSIDIR"
    say "files: $(sudo ls "$UCSIDIR" 2>/dev/null | tr '\n' ' ')"
else
    say "NOT found - is debugfs mounted? try: sudo mount -t debugfs none /sys/kernel/debug"
fi

head1 "pmic_glink altmode"
PAN=/sys/module/pmic_glink_altmode/parameters/pan_enable
say "pan_enable = $(cat $PAN 2>/dev/null || echo '(module not loaded)')"
say "last mux_set the PHY saw:"
sudo dmesg 2>/dev/null | grep -E 'qmp_combo_mux_set|typec_mux_set' | tail -4 | sed 's/^/     /'
say "mode=1 is USB only, mode=5 is TYPEC_DP_STATE_D (two DP lanes + USB)"

watch_dmesg() {
    _before=$(sudo dmesg 2>/dev/null | wc -l)
    "$@"
    sleep 5
    _after=$(sudo dmesg 2>/dev/null | wc -l)
    _new=$((_after - _before))
    head1 "kernel said ($_new new lines)"
    if [ "$_new" -gt 0 ]; then
        sudo dmesg 2>/dev/null | tail -n "$_new" |
            grep -E 'mux_set|altmode|hpd|HPD|drm|dp_|DisplayPort|typec|ucsi' |
            sed 's/^/  /' | tail -25
    fi
    say ""
    say "verdict: if you see 'mode=5' the port entered DP alt mode - it worked."
    say "         if it still says mode=1, this lever does not re-negotiate."
}

case "$MODE" in
report)
    head1 "nothing was changed"
    cat <<'EOF'
  Do this once, then the reset needs no guessing ever again:

    ./sp11-dp-renegotiate.sh --learn              identify the socket physically
    ./sp11-dp-renegotiate.sh --try-reset --yes    UCSI connector reset

  No kernel patch is needed: UCSI's debugfs command interface is built in
  whenever CONFIG_DEBUG_FS=y and it whitelists UCSI_CONNECTOR_RESET.

  --try-pan was tried and did not work. --try-swap CANNOT work here: it needs
  UCSI_CAP_SET_UOM, BIT(0), and this LPM reports features 0x0004 - only
  UCSI_CAP_ALT_MODE_DETAILS. Both are kept for the record.
EOF
    ;;

pan)
    head1 "re-sending ALTMODE_PAN_EN (pan_enable 0 -> 1)"
    [ -e "$PAN" ] || { echo "  $PAN does not exist" >&2; exit 1; }
    watch_dmesg bash -c "echo 0 | sudo tee $PAN >/dev/null; sleep 2; echo 1 | sudo tee $PAN >/dev/null"
    ;;

swap)
    head1 "data-role swap on the display's port"
    if [ -z "$DPPORT" ]; then
        echo "  Refusing: no port has a partner advertising DP alt mode." >&2
        echo "  Without that I cannot tell the display apart from the root disk." >&2
        exit 1
    fi
    if [ "$DPCOUNT" -gt 1 ]; then
        echo "  Refusing: more than one port advertises DP alt mode." >&2
        exit 1
    fi
    cur=$(cat "/sys/class/typec/$DPPORT/data_role" 2>/dev/null)
    say "port:    $DPPORT"
    say "current: $cur"
    other=host
    echo "$cur" | grep -q '\[host\]' && other=device
    say "swapping to: $other"
    watch_dmesg bash -c "echo $other | sudo tee /sys/class/typec/$DPPORT/data_role >/dev/null"
    say ""
    say "put it back with: echo host | sudo tee /sys/class/typec/$DPPORT/data_role"
    ;;

learn)
    head1 "learning which connector the display is on"
    cat <<'EOF'
  The DP alt-mode discriminator is unusable after a charger_pd restart, so
  identify the socket physically instead. This is needed ONCE - the connector
  number belongs to the socket, not to the session - and afterwards --try-reset
  and any boot service can use it without identifying anything.

  Keep the T7 exactly where it is. Only the display moves.
EOF
    before=$(ls -d /sys/class/typec/port[0-9]-partner 2>/dev/null | tr '\n' ' ')
    say ""
    say "partners now: ${before:-none}"
    [ -n "$before" ] || { echo "  no partners at all - is the display attached?" >&2; exit 1; }
    echo
    printf '  UNPLUG THE DISPLAY NOW, then press Enter... '
    read -r _
    for i in $(seq 1 15); do
        after=$(ls -d /sys/class/typec/port[0-9]-partner 2>/dev/null | tr '\n' ' ')
        [ "$after" != "$before" ] && break
        sleep 1
    done
    say "partners now: ${after:-none}"
    GONE=
    for b in $before; do
        case " $after " in *" $b "*) ;; *) GONE="$GONE $b" ;; esac
    done
    GONE=$(echo $GONE)
    if [ -z "$GONE" ]; then
        echo "  Nothing went away. Either the unplug was not seen, or this port" >&2
        echo "  does not report partner removal. Cannot learn it this way." >&2
        exit 1
    fi
    if [ "$(echo "$GONE" | wc -w)" -gt 1 ]; then
        echo "  More than one partner disappeared: $GONE - refusing to guess." >&2
        exit 1
    fi
    PORTN=$(basename "$GONE" | sed 's/-partner$//')
    CONN=$(( ${PORTN#port} + 1 ))
    mkdir -p "$(dirname "$LEARNFILE")"
    echo "$CONN" > "$LEARNFILE"
    head1 "learned"
    say "display is on $PORTN -> UCSI connector $CONN"
    say "saved to $LEARNFILE"
    say ""
    say "Plug the display back in. From now on: $0 --try-reset --yes"
    ;;

reset)
    head1 "UCSI connector reset - a replug, in software"
    [ -n "${UCSIDIR:-}" ] || { echo "  no ucsi debugfs dir" >&2; exit 1; }

    # UCSI connectors are 1-based and registered in order, so typec portN is
    # connector N+1. Stated rather than assumed silently.
    #
    # Three ways to know which connector, in descending order of trust:
    #   --connector N   you said so
    #   $LEARNFILE      --learn watched it physically disappear
    #   DP alt mode     only works when the PPM has discovery data, which after
    #                   a charger_pd restart it does not
    if [ -n "$CONNOVERRIDE" ]; then
        CONN=$CONNOVERRIDE
        say "connector: $CONN (from --connector, no safety check applied)"
    elif [ -n "$LEARNED" ]; then
        CONN=$LEARNED
        say "connector: $CONN (learned, from $LEARNFILE)"
    else
        if [ -z "$DPPORT" ]; then
            echo "  Refusing: no port advertises DP alt mode and nothing has been" >&2
            echo "  learned, so I cannot tell the display from the root disk." >&2
            echo "  Run '$0 --learn' once with the display attached, or pass" >&2
            echo "  --connector N if you already know the number." >&2
            exit 1
        fi
        if [ "$DPCOUNT" -gt 1 ]; then
            echo "  Refusing: more than one port advertises DP alt mode." >&2
            exit 1
        fi
        CONN=$(( ${DPPORT#port} + 1 ))
        say "display is on $DPPORT, so UCSI connector $CONN"
    fi

    # 0x03 | connector<<16, and BIT(23) per the version rules in the header
    CMD=$(printf '0x%08x' $(( 0x03 | (CONN << 16) | $([ "$HARDBIT" = set ] && echo $((1<<23)) || echo 0) )))
    say "command:  $CMD   (hard-reset bit: $HARDBIT)"
    say "target:   $UCSIDIR/command"

    if [ "$YES" != yes ]; then
        echo
        say "NOT sending. This drops whatever is on that connector for a couple of"
        say "seconds. If the connector guess is wrong it is your root disk, and the"
        say "session will not survive it. Re-run with --yes when you are ready."
        exit 0
    fi

    say "syncing filesystems first"
    sync
    watch_dmesg bash -c "echo $CMD | sudo tee $UCSIDIR/command >/dev/null" || true
    say ""
    say "if nothing moved, the LPM may be UCSI 1.0, where the hard-reset bit is"
    say "inverted. Try:  $0 --try-reset --yes --hard-bit-set"
    ;;
esac
