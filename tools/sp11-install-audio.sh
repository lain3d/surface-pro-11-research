#!/bin/bash
# Install the Surface Pro 11 audio userspace onto the T7 root, offline from WSL.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-install-audio.sh
#   tools\sp11-disk.ps1 to-win
#
# WHAT THIS IS FOR
#
# With the ADSP restarted from the dracut pre-mount hook, gprsvc registers and
# q6apm binds - and then the sound card dies at the last fence:
#
#   qcom-apm gprsvc:service:2:1: Direct firmware load for
#       qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin failed -2
#   snd-x1e80100 sound: ASoC: failed to instantiate card -2
#
# The name comes from the DT: audioreach_tplg_init() builds it as
# "qcom/<card->driver_name>/<card->name>-tplg.bin", and the sound node in
# x1-microsoft-denali.dtsi sets model = "X1E80100-Microsoft-Surface-Pro-11".
# linux-firmware ships fourteen X1E80100 topologies and none of them is the
# Surface Pro 11's, so the file simply does not exist on a stock system.
#
# It does exist in ../ubuntu-surface-pro-11, which is where the rest of the
# audio userspace comes from too. That repo also diagnosed the other symptom in
# our log - "CMD timeout for [1001021] opcode" - as alsactl restoring WSA mixer
# state before the DSP graph has loaded, hence masking alsa-restore/alsa-state
# and driving the routing from a service that waits for the SoundWire slaves.
#
# WHAT THIS DELIBERATELY DOES NOT DO
#
# The upstream recipe's step 1 installs qcadsp8380.mbn under its real name. Ours
# stays hidden as .disabled on purpose: the pre-mount hook stages it into tmpfs
# and boots the ADSP before root is mounted, because a userspace ADSP restart
# drops the USB-C port that carries the root filesystem. Do not un-hide it.
set -eu

M=/mnt/sp11root
SRC=${SRC:-/mnt/c/Users/Crazy/projs/ubuntu-surface-pro-11}
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

[ -d "$SRC/audio" ] || { echo "no audio assets at $SRC"; exit 1; }

DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }
echo "=== device: $DEV ==="

mkdir -p "$M"
mountpoint -q "$M" || mount "$DEV" "$M"
trap 'umount "$M" 2>/dev/null || true' EXIT

backup() {
    [ -f "$1" ] || return 0
    [ -f "$1.pre-sp11audio" ] && return 0
    cp -a "$1" "$1.pre-sp11audio"
    echo "  backed up ${1#$M} -> .pre-sp11audio"
}

# ---- 1. the topology binary -------------------------------------------------
mkdir -p "$M/lib/firmware/qcom/x1e80100"
cp "$SRC/audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin" \
   "$M/lib/firmware/qcom/x1e80100/"
echo "=== topology installed ==="
ls -l "$M/lib/firmware/qcom/x1e80100/X1E80100-Microsoft-Surface-Pro-11-tplg.bin"

# ---- 2. UCM2, so PipeWire builds sinks and sources --------------------------
mkdir -p "$M/usr/share/alsa/ucm2/Qualcomm/x1e80100"
cp "$SRC/audio/ucm/MICROSOFT-Surface-Pro-11.conf" \
   "$SRC/audio/ucm/Surface11-HiFi.conf" \
   "$M/usr/share/alsa/ucm2/Qualcomm/x1e80100/"
mkdir -p "$M/usr/share/alsa/ucm2/conf.d/x1e80100"
backup "$M/usr/share/alsa/ucm2/conf.d/x1e80100/x1e80100.conf"
cp "$SRC/audio/ucm/x1e80100.conf" "$M/usr/share/alsa/ucm2/conf.d/x1e80100/"
echo "=== UCM2 installed ==="

# ---- 3. the boot-race fix ---------------------------------------------------
# sed, not install: these are authored on Windows and a single CR on the shebang
# makes execve fail with ENOENT, which systemd reports as status=127/n/a and
# nothing else. That is exactly how the speaker route silently never ran.
sed 's/\r$//' "$SRC/scripts/sp11-enable-wsa-routing.sh" \
    > "$M/usr/local/sbin/sp11-enable-wsa-routing.sh"
chmod 755 "$M/usr/local/sbin/sp11-enable-wsa-routing.sh"
# 644, not the repo's mode: a unit file with the exec bits set makes systemd
# complain "marked executable, please remove executable permission bits" on
# every boot.
install -m 644 "$SRC/systemd/sp11-wsa-routing.service" "$M/etc/systemd/system/"

# enable and mask by hand: systemctl cannot run against an offline root
mkdir -p "$M/etc/systemd/system/multi-user.target.wants"
ln -sf ../sp11-wsa-routing.service \
       "$M/etc/systemd/system/multi-user.target.wants/sp11-wsa-routing.service"
for u in alsa-restore.service alsa-state.service; do
    ln -sf /dev/null "$M/etc/systemd/system/$u"
done
echo "=== boot-race fix installed: routing service enabled, alsa-restore/state masked ==="

# ---- 4. the PipeWire sink is per-user, so only stage the script -------------
sed 's/\r$//' "$SRC/scripts/sp11-pipewire-speaker-sink.sh" \
    > "$M/usr/local/sbin/sp11-pipewire-speaker-sink.sh"
chmod 755 "$M/usr/local/sbin/sp11-pipewire-speaker-sink.sh"
echo "=== staged sp11-pipewire-speaker-sink.sh (run it as the user, --install --enable-route) ==="

# ---- verify -----------------------------------------------------------------
echo
echo "=== verify ==="
ls -l "$M/etc/systemd/system/" | grep -E 'alsa-|sp11-wsa' || true
ls -1 "$M/usr/share/alsa/ucm2/Qualcomm/x1e80100/"
echo "--- the ADSP image must still be hidden ---"
ls -1 "$M/lib/firmware/qcom/x1e80100/microsoft/Denali/" | grep -i qcadsp
sync
echo
echo "done - now run: tools\\sp11-disk.ps1 to-win"
