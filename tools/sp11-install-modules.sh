#!/bin/bash
# Build the modules for the current .config and install them onto the T7,
# replacing the stale tree.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-install-modules.sh
#   tools\sp11-disk.ps1 to-win
#
# WHY
#
# /lib/modules/<release> on the T7 was installed on 2026-08-04 from a different
# build. The UKI has been rebuilt several times since with a changed config, so
# the installed modules no longer match the running vmlinux - same release
# string, different symbols. That is how you get a kernel where msm loads far
# enough to probe the DP controller but the GPU never binds.
#
# It also installs the four Type-C modules that only exist since the stack went
# modular, without which there is no USB-C alt mode and the ucsi_glink patch
# is dead code.
#
# THE FILESYSTEM IS DIRTY. Roughly ten hard power-offs, and the journals show
# "Aborting journal on device sda2" and ext4 IO errors. fsck BEFORE mounting rw.
set -eu

K=/root/sp11/wt-cfg
M=/mnt/sp11root
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd
REL=$(cat "$K/include/config/kernel.release")

echo "=== kernel release: $REL ==="

# ---- build the modules first; this needs no disk -----------------------------
cd "$K"
echo "=== building modules ($(nproc) jobs) - this is the long part ==="
make LOCALVERSION= -j"$(nproc)" modules

# ---- now the disk ------------------------------------------------------------
DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }
echo "=== root fs: $DEV ==="

umount "$M" 2>/dev/null || true

# DO NOT fsck FROM HERE.
#
# WSL is Ubuntu 22.04 with e2fsprogs 1.46.5. The T7 was made by Ubuntu 26.04 and
# its root filesystem has the orphan_file feature, which 1.46.5 reports as
#     /dev/sdX has unsupported feature(s): FEATURE_C12 FEATURE_R16
#     e2fsck: Get a newer version of e2fsck!
# An e2fsck that does not understand the features it is modifying is far more
# dangerous than a dirty filesystem. Same shape as the journalctl trap: the tool
# is older than the disk.
#
# That does NOT mean a check is impossible here - use tools/sp11-fsck.sh, which
# runs the DISK'S OWN e2fsck 1.47.2 through the target's loader, exactly as
# sp11-journal.sh runs the target's journalctl. Run it before this script if the
# filesystem is suspect.
#
# Mounting read-write replays the journal, which is the normal, supported
# recovery path and is done by a kernel new enough to know the features.
echo "=== not using WSL's e2fsck (too old); see tools/sp11-fsck.sh ==="
e2fsck -V 2>&1 | head -1

mkdir -p "$M"
mount "$DEV" "$M" || {
    echo "read-write mount FAILED - the WSL kernel may not support orphan_file."
    echo "Nothing was written. Install the modules from a booted system instead."
    exit 1
}
awk -v m="$M" '$2 == m {print "  mounted " $1 " " $2 " " $3 " " $4}' /proc/mounts
trap 'sync; umount "$M" 2>/dev/null || true' EXIT

echo "=== installing modules into $M ==="
# INSTALL_MOD_PATH prefixes /lib/modules. No firmware install - the Denali blobs
# on that disk are hand-placed from the Windows driver store and must not be
# overwritten (qcadsp8380.mbn is deliberately renamed .disabled).
make LOCALVERSION= INSTALL_MOD_PATH="$M" modules_install

depmod -b "$M" "$REL"

echo
echo "=== verify the Type-C modules landed ==="
for m in typec_ucsi ucsi_glink ps883x typec_displayport msm qcom_q6v5_pas; do
    f=$(find "$M/lib/modules/$REL" -name "$m.ko*" 2>/dev/null | head -1)
    printf '  %-20s %s\n' "$m" "${f:-MISSING}"
done
echo
echo "=== ADSP firmware must still be hidden ==="
ls -1 "$M/lib/firmware/qcom/x1e80100/microsoft/Denali/" | grep -i adsp8380 || true
echo
sync
echo "done - now run: tools\\sp11-disk.ps1 to-win"
