#!/bin/bash
# Make the user's PipeWire wait for the WSA route, not just for the ALSA card.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-fix-pipewire-wait.sh
#   tools\sp11-disk.ps1 to-win
#
# THE BUG THIS FIXES, measured 2026-08-06:
#
#   19.38s  card0 registers (Headset Jack)
#   20.05s  pipewire opens hw:X1E80100Microso,1 -> Invalid argument
#           kernel: MultiMedia2 Playback: no backend DAIs enabled ...
#   20.22 / 20.37 / 20.58 / 20.73  four more identical failures
#           pipewire.service hits its start limit and stays dead
#   21.63s  sp11-enable-wsa-routing: WSA speaker routing enabled
#   21.65s  ... wrote /run/sp11-wsa-routing-done
#
# PipeWire gave up 900 ms before the route it needs existed. The old
# ExecStartPre waited for the CARD, which appears 2.2 s too early - the card
# existing is not the same as MultiMedia2 having backend DAIs.
#
# The routing script already writes /run/sp11-wsa-routing-done and says in its
# own log that the flag is "for user-level PipeWire restart". Nothing consumed
# it. Now something does.
#
# The fallback matters: if sp11-wsa-routing is ever disabled the flag never
# appears, and blocking forever would turn a race into a permanent outage. So
# after 60 s fall back to the old card check.
set -eu

M=/mnt/sp11root
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
REL=.config/systemd/user/pipewire.service.d/50-sp11-wait-for-card.conf

DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }

mkdir -p "$M"
mountpoint -q "$M" && umount "$M"
mount "$DEV" "$M"
trap 'sync; umount "$M" 2>/dev/null || true' EXIT
[ -d "$M/home/lain" ] || { echo "wrong filesystem"; exit 1; }

F="$M/home/lain/$REL"
[ -f "$F" ] || { echo "not found: /home/lain/$REL"; exit 1; }

OWNER=$(stat -c '%u:%g' "$F")
echo "=== current (owner $OWNER) ==="
cat "$F"

[ -f "$F.pre-wsaflag" ] || cp -a "$F" "$F.pre-wsaflag"

cat > "$F" <<'EOF'
# Hold PipeWire until the WSA speaker route is actually enabled.
#
# Waiting for the ALSA card is not enough: the card registers ~2.2s before
# sp11-wsa-routing.service enables the MultiMedia2 backend DAIs, and a PCM open
# in that window fails with EINVAL. PipeWire retries five times in 0.7s, hits
# its start limit, and stays dead for the rest of the session - which is what
# "sound stopped working" looked like on 2026-08-06.
#
# sp11-enable-wsa-routing.sh writes the flag file below as its last action.
[Unit]
# Five rapid failures used to be terminal. Give it room in case anything else
# races; with the wait below it should not need it.
StartLimitIntervalSec=30
StartLimitBurst=10

[Service]
ExecStartPre=
ExecStartPre=/bin/sh -c 'i=0; while [ "$i" -lt 60 ]; do if [ -e /run/sp11-wsa-routing-done ]; then exit 0; fi; i=$((i+1)); sleep 1; done; if aplay -l 2>/dev/null | grep -q X1E80100Microso; then echo "sp11: WSA routing flag never appeared after 60s; card is present, starting anyway" >&2; exit 0; fi; echo "sp11: neither the WSA routing flag nor the ALSA card appeared within 60s" >&2; exit 1'
EOF

chown "$OWNER" "$F"
chmod 644 "$F"

echo
echo "=== new ==="
cat "$F"
echo
echo "=== files in that drop-in dir ==="
ls -la "$(dirname "$F")"
