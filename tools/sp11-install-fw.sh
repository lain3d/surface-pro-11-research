#!/bin/bash
# Install firmware blobs onto the Surface's root filesystem from WSL.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-install-fw.sh
#   tools\sp11-disk.ps1 to-win
#
# Staging dir is C:\sp11-stage\fw. Files are placed under
# /lib/firmware/<relative path>, so stage them in the layout the kernel asks
# for, e.g.
#
#   C:\sp11-stage\fw\qcom\x1e80100\microsoft\Denali\qcdxkmsuc8380.mbn
#
# A bare filename with no directories is treated as
# qcom/x1e80100/microsoft/Denali/<name>, which is where this board's signed
# blobs live (Denali is the Surface Pro 11's board codename).
#
# Unlike sp11-journal.sh this mounts READ-WRITE - it has to, it is writing. So
# it checks it has the right filesystem before touching anything, and it never
# overwrites without keeping a .bak.
#
# Where the blobs come from: the Windows driver store, which is the only place
# the board-specific signed firmware exists. linux-firmware does not carry it.
#   C:\Windows\System32\DriverStore\FileRepository\qcdx8380.inf_arm64_*\
# Use the copy from the directory whose qcdx8380.inf hashes equal to the
# oemNNN.inf in C:\Windows\INF that the Adreno is actually bound to - there is
# more than one version present and they are not identical.
set -u

STAGE=${1:-/mnt/c/sp11-stage/fw}
M=/mnt/sp11root
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
DEFAULT_SUBDIR=qcom/x1e80100/microsoft/Denali

[ -d "$STAGE" ] || { echo "no staging dir $STAGE"; exit 1; }

# ---- locate and mount ------------------------------------------------------
DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
if [ -z "$DEV" ]; then
    echo "root UUID $ROOT_UUID not visible."
    echo "Did you run:  tools\\sp11-disk.ps1 to-wsl ?"
    lsblk -o NAME,SIZE,FSTYPE,LABEL 2>/dev/null
    exit 1
fi

mkdir -p "$M"
if mountpoint -q "$M"; then umount "$M" || true; fi
mount -o rw "$DEV" "$M" || { echo "mount rw failed"; exit 1; }
echo "mounted $DEV at $M (rw)"

cleanup() { sync; umount "$M" 2>/dev/null && echo "unmounted"; }
trap cleanup EXIT

# Refuse anything that is not plainly the Surface's root filesystem. A wrong
# guess here writes into someone else's disk.
if [ ! -f "$M/etc/os-release" ] || [ ! -d "$M/lib/firmware" ]; then
    echo "$M does not look like the root filesystem - refusing"
    exit 1
fi
sed -n 's/^PRETTY_NAME=//p' "$M/etc/os-release" | sed 's/^/target: /'

# ---- what is already there -------------------------------------------------
FWD=$M/lib/firmware/$DEFAULT_SUBDIR
echo
echo "--- $DEFAULT_SUBDIR before ---"
if [ -d "$FWD" ]; then
    ls -la "$FWD" | sed 's/^/  /'
else
    echo "  (directory does not exist)"
fi

# ---- install ---------------------------------------------------------------
echo
rc=0
cd "$STAGE" || exit 1
find . -type f | sed 's|^\./||' | while read -r rel; do
    case "$rel" in
        */*) dest_rel=$rel ;;                       # staged with its own path
        *)   dest_rel=$DEFAULT_SUBDIR/$rel ;;       # bare name -> this board
    esac
    dest=$M/lib/firmware/$dest_rel

    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ]; then
        if cmp -s "$rel" "$dest"; then
            echo "same    $dest_rel"
            continue
        fi
        cp -a "$dest" "$dest.bak" && echo "backup  $dest_rel.bak"
    fi

    cp "$rel" "$dest" || { echo "FAILED  $dest_rel"; rc=1; continue; }
    chmod 644 "$dest"

    want=$(sha256sum "$rel"  | cut -d' ' -f1)
    got=$(sha256sum  "$dest" | cut -d' ' -f1)
    if [ "$want" = "$got" ]; then
        echo "ok      $dest_rel  ($(stat -c%s "$dest") bytes, sha256 ${got:0:16}...)"
    else
        echo "MISMATCH $dest_rel - staged $want, on disk $got"
        rc=1
    fi
done

echo
echo "--- $DEFAULT_SUBDIR after ---"
ls -la "$FWD" | sed 's/^/  /'
echo
echo "when finished:  tools\\sp11-disk.ps1 to-win"
exit $rc
