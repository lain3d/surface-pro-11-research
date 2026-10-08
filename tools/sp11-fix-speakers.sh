#!/usr/bin/env bash
# Install the Surface Pro 11 stereo speaker sink AS YOURSELF, cleaning up after
# a run that went through sudo.
#
# WHY THIS EXISTS
#
# sp11-pipewire-speaker-sink.sh writes to per-user paths:
#
#   ${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/
#   ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/pipewire.service.d/
#
# Run it under sudo and $HOME can resolve to /root, so the config lands where
# your session will never read it. Its `systemctl --user restart` calls cannot
# reach your session bus as root either, and every one of them ends in `|| true`
# - so it prints success and changes nothing at all.
#
# WHAT IT FIXES
#
# The speaker PCM has four slots and the machine has two speakers. GNOME assumes
# the default quad order [FL FR RL RR]; the DSP actually wires [FL RL FR RR], so
# every label after the first is shifted - "rear left" plays out of the right
# speaker and two slots are silent. The sink config declares the real order and
# a mix matrix that sends L to ch0 and R to BOTH ch2 and ch3, because which of
# those two carries the right speaker changes from boot to boot.
#
# Safe to run when nothing was sudo'd, and safe to run twice.
set -uo pipefail

SINK=${SP11_SINK_SCRIPT:-/usr/local/sbin/sp11-pipewire-speaker-sink.sh}
CARD=${SP11_ALSA_CARD:-X1E80100Microso}

USER_CFG="${XDG_CONFIG_HOME:-$HOME/.config}/pipewire/pipewire.conf.d/50-sp11-speakers.conf"
ROOT_CFG=/root/.config/pipewire/pipewire.conf.d/50-sp11-speakers.conf
ROOT_UNIT=/root/.config/systemd/user/pipewire.service.d

say()  { echo "  $*"; }
head1() { echo; echo "=== $* ==="; }

# ---- 1. refuse to be the bug ------------------------------------------------
if [ "$(id -u)" -eq 0 ]; then
    echo "This must NOT run as root - running it as root is the thing it fixes." >&2
    if [ -n "${SUDO_USER:-}" ]; then
        echo "Re-run it as yourself:  $0" >&2
    fi
    exit 1
fi

head1 "before"
say "user:        $(id -un)  home=$HOME"
say "sink script: $SINK $([ -x "$SINK" ] && echo '(present)' || echo 'MISSING')"
say "your config: $([ -f "$USER_CFG" ] && echo "$USER_CFG" || echo 'not installed')"
if sudo -n test -f "$ROOT_CFG" 2>/dev/null || sudo test -f "$ROOT_CFG" 2>/dev/null; then
    say "root config: $ROOT_CFG  <- stray, from a sudo'd run"
    STRAY=yes
else
    say "root config: none"
    STRAY=no
fi

[ -x "$SINK" ] || { echo "no $SINK - install it from ubuntu-surface-pro-11/scripts/" >&2; exit 1; }

# ---- 2. clear the stray root copy -------------------------------------------
if [ "$STRAY" = yes ]; then
    head1 "removing the stray root-owned copy"
    sudo rm -rf "$ROOT_CFG" "$ROOT_UNIT"
    say "removed $ROOT_CFG"
    say "removed $ROOT_UNIT"
fi

# ---- 3. install as the real user -------------------------------------------
head1 "installing as $(id -un)"
"$SINK" --install --enable-route

# ---- 4. restart the session's audio ----------------------------------------
head1 "restarting pipewire in your session"
systemctl --user daemon-reload 2>/dev/null || true
systemctl --user restart pipewire wireplumber 2>/dev/null ||
    systemctl --user restart pipewire pipewire-pulse 2>/dev/null ||
    say "could not restart pipewire - log out and back in"
sleep 2

# ---- 5. show whether it actually took --------------------------------------
head1 "after"
if [ -f "$USER_CFG" ]; then
    say "config:   $USER_CFG"
    grep -E 'audio.position|mix-matrix' "$USER_CFG" | sed 's/^[[:space:]]*/  /'
else
    say "config:   STILL MISSING - the sink script did not write it"
fi

say "services: pipewire=$(systemctl --user is-active pipewire 2>/dev/null) wireplumber=$(systemctl --user is-active wireplumber 2>/dev/null)"

# ---- 6. SELECT it ----------------------------------------------------------
#
# The sink script does not do this - its own header says "After install, select
# Surface Pro 11 Speakers in GNOME or wpctl". Meanwhile the UCM profile creates
# its own sink on the same PCM with PlaybackChannels 4, and that one stays the
# default. So both exist, everything looks installed, and audio still comes out
# of the four-slot device with the wrong channel map. Pick ours.
SINKNAME=alsa_output.sp11_speakers
if command -v pactl >/dev/null 2>&1; then
    head1 "sinks pipewire is offering"
    pactl list short sinks | sed 's/^/  /'

    if pactl list short sinks | grep -q "$SINKNAME"; then
        head1 "selecting $SINKNAME"
        pactl set-default-sink "$SINKNAME" && say "set as default"
        # drag anything already playing over to it
        pactl list short sink-inputs 2>/dev/null | while read -r id _; do
            [ -n "$id" ] && pactl move-sink-input "$id" "$SINKNAME" 2>/dev/null &&
                say "moved stream $id"
        done
        say "default is now: $(pactl info 2>/dev/null | sed -n 's/^Default Sink: //p')"
    else
        head1 "the sink was NOT created"
        say "the config is on disk but pipewire did not build a node from it."
        say "most likely the config went somewhere pipewire does not read, or it"
        say "failed to open the PCM. recent complaints:"
        journalctl --user -u pipewire -u wireplumber -b --no-pager 2>/dev/null |
            grep -iE 'sp11|error|fail|busy' | tail -15 | sed 's/^/     /'
    fi
else
    say "pactl not installed - pick 'Surface Pro 11 Speakers' in Settings > Sound"
fi

head1 "test it"
cat <<EOF
  Settings > Sound should now offer "Surface Pro 11 Speakers", and its test
  should show TWO positions, not four. A four-position grid means you are still
  on the UCM sink - pick the other output.

  Stereo through the new sink (should be left, then right):
    speaker-test -D pipewire -c 2 -t sine -f 440 -l 1

  Raw 4-channel PCM, to see the slot map directly:
    speaker-test -D hw:$CARD,1 -c 4 -t sine -f 440 -l 1
    ch0 = left speaker, ch1 silent, ch2 or ch3 = right speaker

  If ch2 AND ch3 are both silent there, the right amp did not come up this boot
  and no channel mapping can help - check: systemctl status sp11-wsa-routing
EOF
