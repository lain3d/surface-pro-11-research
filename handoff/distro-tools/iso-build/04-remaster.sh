#!/usr/bin/env bash
# Build a Surface Pro 11 live ISO from the Ubuntu Concept X1E base.
#
#   DISTRO_ROOT=/path/to/ubuntu-surface-pro-11 WORK=/root/sp11 bash 04-remaster.sh
#
# Historical base layout (Ubuntu 26.04 "Resolute Raccoon", arm64+x1e daily):
#
#   casper/vmlinuz                       kernel the live session boots
#   casper/initrd                        ~137 MB
#   casper/minimal.squashfs              ~2.9 GB   the actual root filesystem
#   casper/minimal.standard.squashfs     ~493 MB   delta layer (LibreOffice etc.)
#   casper/minimal.<lang>.squashfs       per-language delta layers
#   EFI/ boot/ .disk/ dists/ pool/
#
# The layers are *deltas*, not self-contained roots: minimal.standard.squashfs
# holds only etc/ snap/ usr/ var/ fragments and has no dpkg and no shell, so
# chrooting into it fails with "failed to run command /bin/bash". The base
# minimal.squashfs is the one with a usable root, and is therefore the layer we
# unpack, modify and repack.
#
# (/bin/bash does not appear in either listing because of usrmerge - the real
# path is /usr/bin/bash and /bin is a symlink.)
#
# It is a *layered* squashfs image, not a single casper/filesystem.squashfs, and
# `.disk/base_installable` marks it as an installer image whose target kernel
# normally comes from the archive at install time. So two separate things need
# doing: fix up the live session, and make our kernel available to the installed
# system.
set -euo pipefail

WORK="${WORK:-/root/sp11}"
# No default: this research checkout is NOT a distro runtime source.
: "${DISTRO_ROOT:?Set DISTRO_ROOT to the audited public denisix/ubuntu-surface-pro-11 checkout (see README.md)}"
DISTRO_ROOT="$(cd "$DISTRO_ROOT" && pwd)"
ISO="${ISO:-$WORK/base.iso}"
OUT="${OUT:-$WORK/surface-pro-11-ubuntu.iso}"
MNT="$WORK/iso-mnt"
TREE="$WORK/iso-tree"
LAYER="$WORK/layer"
KDEB_DIR="${KDEB_DIR:-$WORK}"

die() { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "== $* =="; }

# Audited against the public install.sh at this revision. --all does not run
# --kernel, so no kernel-patches or upstream kernel bootstrap are copied.
DISTRO_REVISION=049b1caccf153ccf7aa5d0f6b824a4dc48e8b02d
DISTRO_FILES=(
    install.sh
    grub/99-surface-pro-11.cfg
    grub/98-sp11-timeout.cfg
    grub/ubuntu-x1e-settings.cfg
    apt/99surface-pro-11-wifi-fixup
    scripts/sp11-wifi-board-fixup.sh
    scripts/sp11-grab-fw.sh
    audio/firmware/X1E80100-Microsoft-Surface-Pro-11-tplg.bin
    audio/ucm/MICROSOFT-Surface-Pro-11.conf
    audio/ucm/Surface11-HiFi.conf
    audio/ucm/x1e80100.conf
    scripts/sp11-enable-wsa-routing.sh
    scripts/sp11-pipewire-speaker-sink.sh
    scripts/sp11-fix-cpuidle-s2idle
    scripts/sp11-lid-backlight
    scripts/sp11-enable-suspend-debug
    system-sleep/sp11-cpuidle-s2idle
    systemd/sp11-wsa-routing.service
    systemd/sp11-pipewire-restart.service
    systemd/sp11-pen-daemon.service
    systemd/hexagonrpcd-condition-override.conf
    systemd/sp11-lid-backlight.service
    systemd/sp11-suspend-debug.service
    systemd/sensors-platform-info.service
    systemd/hexagonrpcd-sensors.service
    udev/99-sp11-pen.rules
    udev/99-fastrpc.rules
    pen-daemon/sp11-pen-daemon.c
    npu/CMakeUserPresets.json
    sensors/sns_reg.conf
    sensors/sp11-sensor-read.c
    sensors/sp11-sensor-discover.c
)

DISTRO_ORIGIN="$(git -C "$DISTRO_ROOT" remote get-url origin)"
case "$DISTRO_ORIGIN" in
    https://github.com/denisix/ubuntu-surface-pro-11|https://github.com/denisix/ubuntu-surface-pro-11.git|git@github.com:denisix/ubuntu-surface-pro-11.git|ssh://git@github.com/denisix/ubuntu-surface-pro-11.git) ;;
    *) die "DISTRO_ROOT must be a public denisix/ubuntu-surface-pro-11 checkout" ;;
esac
[ "$(git -C "$DISTRO_ROOT" rev-parse HEAD)" = "$DISTRO_REVISION" ] || \
    die "check out audited distro revision $DISTRO_REVISION (see README.md)"
git -C "$DISTRO_ROOT" diff --quiet HEAD -- "${DISTRO_FILES[@]}" || \
    die "audited runtime files have local modifications"
for runtime_file in "${DISTRO_FILES[@]}"; do
    [ -f "$DISTRO_ROOT/$runtime_file" ] && [ ! -L "$DISTRO_ROOT/$runtime_file" ] || \
        die "missing or symlinked runtime file: $runtime_file"
done

[ -f "$ISO" ] || die "missing base ISO: $ISO"
ls "$KDEB_DIR"/linux-image-*.deb >/dev/null 2>&1 || die "no kernel .debs in $KDEB_DIR - run 02-kernel-build.sh first"

step "mounting base ISO"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount -o loop,ro "$ISO" "$MNT"

TARGET_LAYER="${TARGET_LAYER:-minimal.squashfs}"

step "copying ISO tree (rsync, ~4 GB)"
rm -rf "$TREE"; mkdir -p "$TREE"
rsync -a --exclude="casper/$TARGET_LAYER" "$MNT"/ "$TREE"/

step "unpacking $TARGET_LAYER (~2.9 GB, a few minutes)"
rm -rf "$LAYER"
unsquashfs -q -d "$LAYER" "$MNT/casper/$TARGET_LAYER"
[ -x "$LAYER/usr/bin/dpkg" ] || die "$TARGET_LAYER has no dpkg - wrong layer?"

step "installing kernel into the layer"
# Native aarch64 chroot - the host is ARM64, so no qemu-user needed.
mkdir -p "$LAYER/tmp/kdeb"
cp "$KDEB_DIR"/linux-image-*.deb "$KDEB_DIR"/linux-headers-*.deb "$LAYER/tmp/kdeb/" 2>/dev/null || true
for fs in proc sys dev dev/pts; do mount --bind "/$fs" "$LAYER/$fs" 2>/dev/null || true; done
chroot "$LAYER" /bin/bash -c 'dpkg -i /tmp/kdeb/*.deb 2>&1 | tail -5' || echo "  (dpkg reported issues - check above)"
rm -rf "$LAYER/tmp/kdeb"

step "baking in the Surface Pro 11 userspace"
mkdir -p "$LAYER/opt/sp11"
# A file allowlist, not a recursive repo copy: development checkouts, compiled
# daemons, firmware archives, .git and unrelated research never enter /opt/sp11.
# The topology binary is an EXTERNAL runtime dependency, not shipped here.
rsync -aR -- "${DISTRO_FILES[@]/#/$DISTRO_ROOT/./}" "$LAYER/opt/sp11/"

# The runtime phases of install.sh (systemd --user, PipeWire, hardware probing)
# cannot meaningfully run inside a chroot with no session and no hardware. Defer
# them to first boot instead of trying to fake it.
cat > "$LAYER/etc/systemd/system/sp11-firstboot.service" <<'UNIT'
[Unit]
Description=Surface Pro 11 first-boot enablement
After=multi-user.target systemd-user-sessions.service
ConditionPathExists=!/var/lib/sp11-firstboot.done

[Service]
Type=oneshot
ExecStart=/opt/sp11/install.sh --all
ExecStartPost=/usr/bin/touch /var/lib/sp11-firstboot.done
RemainAfterExit=yes
StandardOutput=journal+console

[Install]
WantedBy=multi-user.target
UNIT
chroot "$LAYER" systemctl enable sp11-firstboot.service 2>/dev/null || \
    ln -sf /etc/systemd/system/sp11-firstboot.service \
       "$LAYER/etc/systemd/system/multi-user.target.wants/sp11-firstboot.service"

for fs in dev/pts dev sys proc; do umount -l "$LAYER/$fs" 2>/dev/null || true; done

step "extracting kernel, DTB and modules for the live session"
KVER="$(ls "$LAYER"/lib/modules | sort -V | tail -1)"
[ -n "$KVER" ] || die "no /lib/modules in layer - kernel install failed"
echo "  kernel version: $KVER"

cp "$LAYER/boot/vmlinuz-$KVER" "$TREE/casper/vmlinuz"
# `make bindeb-pkg` installs DTBs under /usr/lib/linux-image-<ver>/, not the
# /lib/firmware/<ver>/device-tree/ path Ubuntu's own kernel packages use.
DTB="$LAYER/usr/lib/linux-image-$KVER/qcom/x1e80100-microsoft-denali-oled.dtb"
[ -f "$DTB" ] || DTB="$(find "$LAYER" -name 'x1e80100-microsoft-denali-oled.dtb' | head -1)"
[ -n "$DTB" ] && { mkdir -p "$TREE/dtb/qcom"; cp "$DTB" "$TREE/dtb/qcom/"; echo "  DTB: $(basename "$DTB")"; } \
              || echo "  WARNING: no Denali DTB found"

step "regenerating initrd with our modules"
chroot "$LAYER" update-initramfs -c -k "$KVER" 2>&1 | tail -3 || true
[ -f "$LAYER/boot/initrd.img-$KVER" ] && cp "$LAYER/boot/initrd.img-$KVER" "$TREE/casper/initrd"

step "GRUB: point at our DTB"
# The Denali DTB is what makes the machine come up at all; without a devicetree
# line the firmware-provided one (if any) is used and the digitizer, audio and
# wifi nodes are absent.
for cfg in "$TREE/boot/grub/grub.cfg" "$TREE/EFI/boot/grub.cfg"; do
    [ -f "$cfg" ] || continue
    sed -i 's|^\(\s*linux\s\+/casper/vmlinuz.*\)$|\1\n\tdevicetree /dtb/qcom/x1e80100-microsoft-denali-oled.dtb|' "$cfg"
    echo "  patched $(basename "$(dirname "$cfg")")/$(basename "$cfg")"
done

step "repacking $TARGET_LAYER (slow - 2.9 GB)"
rm -f "$TREE/casper/$TARGET_LAYER"
mksquashfs "$LAYER" "$TREE/casper/$TARGET_LAYER" -comp zstd -b 1M -no-progress
printf '%s' "$(du -sx --block-size=1 "$LAYER" | cut -f1)" > "$TREE/casper/${TARGET_LAYER%.squashfs}.size"

step "also shipping the kernel debs for the installed system"
mkdir -p "$TREE/sp11-kernel"
cp "$KDEB_DIR"/linux-image-*.deb "$KDEB_DIR"/linux-headers-*.deb "$TREE/sp11-kernel/" 2>/dev/null || true

step "refreshing md5sum.txt"
( cd "$TREE" && find . -type f -not -name md5sum.txt -not -path './isolinux/*' \
    -print0 | xargs -0 md5sum > md5sum.txt ) 2>/dev/null || true

step "building ISO"
# The historical base has an appended ESP, not an EFI image in the ISO tree.
# Use the split-out writer, which can also be rerun against a prepared tree.
WORK="$WORK" ISO="$ISO" TREE="$TREE" OUT="$OUT" \
    bash "$(dirname "${BASH_SOURCE[0]}")/04b-mkiso.sh"

step "done"
ls -la "$OUT"
echo
echo "Write to USB with:"
echo "  dd if=$OUT of=/dev/sdX bs=4M status=progress conv=fsync"
