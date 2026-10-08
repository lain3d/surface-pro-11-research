#!/bin/bash
# Install sp11-winlog onto the Surface's root filesystem.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/install-sp11-winlog.sh
#   tools\sp11-disk.ps1 to-win
#
# From Git Bash, prefix wsl with MSYS_NO_PATHCONV=1 or /mnt/c/... is rewritten
# into C:/Program Files/Git/mnt/c/... - see [[wsl-invocation-gotchas]].
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
M=/mnt/sp11root
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

# usbipd's attach returns before the device has enumerated, and the sd letter
# moves every time, so wait for the volume by UUID rather than for a node.
DEV=
for i in $(seq 1 20); do
    DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
    [ -n "$DEV" ] && break
    partprobe 2>/dev/null || true; udevadm settle 2>/dev/null || true; sleep 2
done
[ -n "$DEV" ] || { echo "root filesystem not visible after 40s"; lsblk -o NAME,SIZE,LABEL,UUID; exit 1; }

mkdir -p "$M"; mountpoint -q "$M" && umount "$M"
mount -o rw "$DEV" "$M"
echo "mounted $DEV rw at $M"

install -D -m 0755 "$HERE/sp11-winlog.sh" "$M/usr/local/sbin/sp11-winlog"
install -D -m 0644 "$HERE/sp11-winlog.service" "$M/etc/systemd/system/sp11-winlog.service"
sed -i 's/\r$//' "$M/usr/local/sbin/sp11-winlog" "$M/etc/systemd/system/sp11-winlog.service"
mkdir -p "$M/etc/systemd/system/sysinit.target.wants"
ln -sf ../sp11-winlog.service "$M/etc/systemd/system/sysinit.target.wants/sp11-winlog.service"

echo
echo "=== checks ==="
bash -n "$M/usr/local/sbin/sp11-winlog" && echo "  script parses"
# Strip comments before searching for code: the file names the T7's ESP in a
# comment explaining why it is not the target, and a raw grep matches that.
code() { sed 's/#.*//' "$1"; }
code "$M/usr/local/sbin/sp11-winlog" | grep -q 'D297-77C3' \
  && echo "  targets the Windows ESP in code" || { echo "  Windows ESP not referenced - stop"; exit 1; }
code "$M/usr/local/sbin/sp11-winlog" | grep -q '5011-AB20' \
  && { echo "  names the T7 ESP in code - stop"; exit 1; } || echo "  does not act on the T7 ESP"
grep -q 'EFI/Microsoft' "$M/usr/local/sbin/sp11-winlog" && echo "  verifies the volume before writing"

echo
echo "=== sysinit.target.wants ==="
ls -1 "$M/etc/systemd/system/sysinit.target.wants/" | sed 's/^/  /'

sync; umount "$M"
echo
echo "DONE - unmounted cleanly"
