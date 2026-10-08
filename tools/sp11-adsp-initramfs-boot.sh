#!/bin/sh
# SPDX-License-Identifier: BSD-3-Clause
#
# Boot the full ADSP image from the dracut pre-mount shell, before root is
# mounted, and report whether the USB-C root disk re-enumerates afterwards.
#
# Originally written on the Surface itself; this revision adds module staging,
# without which the experiment cannot run at all (see MODULES below).
#
# WHY THIS EXISTS
#
# Audio needs the ADSP running qcadsp8380.mbn. Attaching to the processor
# Qualcomm's firmware already booted does not work: that is a ~12 MiB boot image
# (carveout adsp-boot@86b00000) that serves charger_pd but contains no audio
# service, so it never advertises the "adsp_apps" glink channel that gpr needs.
# The 21 MiB HLOS image does contain it. So the ADSP must actually be booted.
#
# Booting it restarts charger_pd, which owns USB-C power delivery, and ~89 ms
# later the Type-C port drops whatever is attached -- including the root disk.
# Doing it here, before root is mounted, means nothing is holding the disk when
# that happens. The kernel mounts root by UUID, so the disk coming back as sdb
# instead of sda is harmless.
#
# THE MEASUREMENT: does the port re-enumerate after a charger_pd restart? It has
# never been observed, because every previous attempt ended in a power cycle at
# the hang. This script waits and watches instead.
#
# MODULES. The initramfs cannot load qcom_q6v5_pas on its own, for two reasons,
# both verified against the UKI:
#
#   1. qcom_q6v5_pas, qcom_q6v5, qcom_common, qcom_sysmon, qcom_pil_info and
#      remoteproc are simply not packed into it.
#   2. The module tree it does carry is
#      /usr/lib/modules/7.1.3-sp11-integ-gf2cc827b6b89, while the kernel in the
#      UKI is 7.1.3-sp11-stockcfg-gf2cc827b6b89. modprobe looks under
#      `uname -r`, so it finds no tree at all. Nothing there is loadable. The
#      system boots anyway because the stockcfg kernel has its storage drivers
#      built in.
#
# So this stages the modules out of the mounted root into the initramfs first,
# while the disk is still there, and only then unmounts and loads them.
#
# USAGE, at the dracut pre-mount prompt (root is /dev/sda5 on this machine):
#
#     mkdir -p /r && mount -o ro /dev/sda5 /r && sh /r/sp11-adsp.sh
#
#   ...then, whatever the outcome:
#
#     exit          <-- resumes the boot; dracut mounts root by UUID
#
# It also accepts an already-mounted root anywhere, and mounts one itself if you
# give it none. It never writes to the disk.
#
# CONSTRAINTS. The initramfs has no head, tail, grep, awk, cut or basename (see
# design/boot-diagnostics.md in the audio handoff). Everything below is shell
# builtins plus modprobe/insmod/mount/umount/cp. Timing comes from /proc/uptime
# via a redirect, which is a builtin, not a process.

FWSUB=lib/firmware/qcom/x1e80100/microsoft/Denali
FWDIR=/$FWSUB
BOOT_TIMEOUT=30		# seconds to wait for "adsp is now up"
DISK_TIMEOUT=90		# seconds to wait for the root device to come back

say() { echo "[sp11-adsp] $*"; }

now() { read -r _up _idle < /proc/uptime; echo "${_up%.*}"; }

# ---- guard: this must run in the initramfs, before root is mounted ---------
#
# Running it on a booted desktop would restart the ADSP under a live root
# filesystem and take the disk down hard. Refuse.

if [ ! -e /etc/initrd-release ]; then
	say "REFUSING: /etc/initrd-release is absent, so this is not an initramfs."
	say "This script must run from the dracut pre-mount shell. On a booted"
	say "system it would drop the root disk. Nothing was done."
	exit 1
fi

# Find the ADSP by name -- do not assume it is remoteproc0. With the driver
# blacklisted nothing exists yet, which is the state we want.
adsp_sysfs() {
	for _r in /sys/class/remoteproc/remoteproc*; do
		[ -e "$_r/name" ] || continue
		read -r _nm < "$_r/name"
		[ "$_nm" = "adsp" ] && { echo "$_r"; return 0; }
	done
	return 1
}

if _existing=$(adsp_sysfs); then
	read -r _st < "$_existing/state" 2>/dev/null
	if [ "$_st" != "offline" ]; then
		say "WARNING: $_existing (adsp) already exists and is '$_st'."
		say "qcom_q6v5_pas was autoloaded before this ran, so the ADSP is"
		say "already attached to the firmware boot image. Add"
		say "  modprobe.blacklist=qcom_q6v5_pas"
		say "to the cmdline and try again. Rebinding from here risks a hard"
		say "SoC hang. Nothing was done."
		exit 1
	fi
fi

# ---- find root, from the cmdline, without grep ------------------------------

ROOTSPEC=
read -r _cmdline < /proc/cmdline
for _arg in $_cmdline; do
	case "$_arg" in
		root=*) ROOTSPEC="${_arg#root=}" ;;
	esac
done

case "$ROOTSPEC" in
	UUID=*) ROOTDEV="/dev/disk/by-uuid/${ROOTSPEC#UUID=}" ;;
	/dev/*) ROOTDEV="$ROOTSPEC" ;;
	*)      say "cannot understand root= ('$ROOTSPEC'); aborting"; exit 1 ;;
esac

say "root device: $ROOTDEV"
[ -e "$ROOTDEV" ] || { say "root device is not present; aborting"; exit 1; }

# ---- locate the mounted root ------------------------------------------------
#
# Prefer wherever this script was run from: if you did `mount /dev/sda5 /r` and
# ran /r/sp11-adsp.sh, then /r is the root and re-mounting it elsewhere would
# leave a second mount holding the disk when the port drops.

ROOTMNT=
_self_dir="${0%/*}"
[ "$_self_dir" = "$0" ] && _self_dir=.
if [ -d "$_self_dir/$FWSUB" ]; then
	ROOTMNT=$_self_dir
	say "using the root you already mounted at $ROOTMNT"
fi

_mounted_here=no
if [ -z "$ROOTMNT" ]; then
	ROOTMNT=/sp11root
	if [ ! -d "$ROOTMNT/$FWSUB" ]; then
		mkdir -p "$ROOTMNT" 2>/dev/null
		if mount -o ro "$ROOTDEV" "$ROOTMNT" 2>/dev/null; then
			_mounted_here=yes
			say "mounted root read-only at $ROOTMNT"
		else
			say "could not mount $ROOTDEV read-only; aborting"
			exit 1
		fi
	fi
fi

# ---- stage the firmware into the initramfs ----------------------------------

mkdir -p "$FWDIR"

_src="$ROOTMNT/$FWSUB"
_got_adsp=no
for _f in qcadsp8380.mbn qcadsp8380.mbn.disabled; do
	if [ -f "$_src/$_f" ]; then
		cp "$_src/$_f" "$FWDIR/qcadsp8380.mbn" || continue
		say "staged $_f -> $FWDIR/qcadsp8380.mbn"
		_got_adsp=yes
		break
	fi
done

if [ "$_got_adsp" = no ]; then
	say "no qcadsp8380.mbn (or .disabled) under $_src; aborting"
	[ "$_mounted_here" = yes ] && umount "$ROOTMNT"
	exit 1
fi

for _f in adsp_dtb.mbn qccdsp8380.mbn cdsp_dtb.mbn adspr.jsn adsps.jsn adspua.jsn battmgr.jsn cdspr.jsn; do
	[ -f "$_src/$_f" ] && cp "$_src/$_f" "$FWDIR/$_f" 2>/dev/null
done
say "staged the ADSP dtb, the CDSP pair and the PD maps alongside it"

# ---- stage the kernel modules into the initramfs ----------------------------
#
# This is the part the first version was missing. modprobe resolves against
# `uname -r`, and the initramfs has no tree by that name, so nothing at all can
# be loaded from it. Copy the three directories that hold qcom_q6v5_pas and
# everything it pulls in, plus the modules.* metadata modprobe needs to resolve
# dependencies and to decompress .ko.zst.

KVER=$(uname -r)
_msrc="$ROOTMNT/lib/modules/$KVER"
_mdst="/lib/modules/$KVER"

if [ ! -d "$_msrc" ]; then
	say "no module tree at $_msrc for kernel $KVER; aborting"
	[ "$_mounted_here" = yes ] && umount "$ROOTMNT"
	exit 1
fi

mkdir -p "$_mdst"
for _f in modules.dep modules.dep.bin modules.alias modules.alias.bin \
          modules.symbols modules.symbols.bin modules.builtin \
          modules.builtin.bin modules.builtin.alias.bin modules.order; do
	[ -f "$_msrc/$_f" ] && cp "$_msrc/$_f" "$_mdst/$_f" 2>/dev/null
done

for _d in kernel/drivers/remoteproc kernel/drivers/soc/qcom kernel/drivers/rpmsg; do
	if [ -d "$_msrc/$_d" ]; then
		mkdir -p "$_mdst/$_d"
		cp "$_msrc/$_d"/* "$_mdst/$_d/" 2>/dev/null
	fi
done
say "staged modules for $KVER into the initramfs"

if [ ! -e "$_mdst/kernel/drivers/remoteproc/qcom_q6v5_pas.ko" ] &&
   [ ! -e "$_mdst/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.zst" ] &&
   [ ! -e "$_mdst/kernel/drivers/remoteproc/qcom_q6v5_pas.ko.xz" ]; then
	say "WARNING: qcom_q6v5_pas.ko is not where it was expected. modprobe may"
	say "still find it via modules.dep, but if it does not, that is why."
fi

# Always release the disk, whether this script mounted it or you did by hand.
# A mount left on the device when the port drops leaves a stale mount of a dead
# block device, which can confuse the real root mount after 'exit'.
if umount "$ROOTMNT" 2>/dev/null; then
	say "unmounted root -- nothing is holding the disk now"
else
	say "WARNING: could not unmount $ROOTMNT. Something still holds the disk;"
	say "the measurement below will be about that, not about the port."
fi

# ---- boot the ADSP ----------------------------------------------------------

say ""
say "loading qcom_q6v5_pas. The ADSP will restart, charger_pd with it, and the"
say "Type-C port is expected to drop the disk about 89 ms later."
say ""

_t0=$(now)
# An explicit `modprobe <name>` ignores blacklists unless -b is given, so
# modprobe.blacklist=qcom_q6v5_pas on the cmdline does not block this.
if ! modprobe qcom_q6v5_pas; then
	say "modprobe failed. Trying insmod against the staged copies."
	for _m in qcom_pil_info mdt_loader qcom_common qcom_q6v5 qcom_sysmon qcom_q6v5_pas; do
		for _e in ko ko.zst ko.xz; do
			for _p in "$_mdst/kernel/drivers/remoteproc/$_m.$_e" \
			          "$_mdst/kernel/drivers/soc/qcom/$_m.$_e"; do
				[ -e "$_p" ] && { insmod "$_p" 2>/dev/null && say "  insmod $_m"; break 2; }
			done
		done
	done
fi

# Wait for the ADSP to come up. "running" is a full boot; "attached" means it
# found no firmware and took the attach path anyway, which is the failure case.
_adsp_state=unknown
_adsp_dir=
_i=0
while [ "$_i" -lt "$BOOT_TIMEOUT" ]; do
	if _adsp_dir=$(adsp_sysfs); then
		read -r _adsp_state < "$_adsp_dir/state"
		case "$_adsp_state" in
			running|attached) break ;;
		esac
	fi
	sleep 1
	_i=$((_i + 1))
done

say "adsp (${_adsp_dir:-not found}) state after ${_i}s: $_adsp_state"
if [ "$_adsp_state" != "running" ]; then
	say "the ADSP did NOT boot -- it is '$_adsp_state', not 'running'."
	if [ "$_adsp_state" = attached ]; then
		say "'attached' means it found no firmware and attached to the boot"
		say "image instead. The staging above did not take. Check dmesg for"
		say "qcadsp8380.mbn."
	else
		say "Check 'dmesg' for qcom_q6v5_pas and qcadsp8380.mbn."
	fi
	say "The disk was never at risk. Type 'exit' to continue booting."
	exit 1
fi
say "the ADSP booted the full image"

# ---- the actual measurement -------------------------------------------------

say ""
say "watching $ROOTDEV. This is the question nobody has answered:"
say "does the Type-C port re-enumerate after a charger_pd restart?"
say ""

_gone_at=
_back_at=
_i=0
while [ "$_i" -lt "$DISK_TIMEOUT" ]; do
	if [ -e "$ROOTDEV" ]; then
		if [ -n "$_gone_at" ]; then
			_back_at=$(now)
			break
		fi
	else
		if [ -z "$_gone_at" ]; then
			_gone_at=$(now)
			say "  disk disappeared at t+$((_gone_at - _t0))s"
		fi
	fi
	sleep 1
	_i=$((_i + 1))
done

say ""
if [ -z "$_gone_at" ]; then
	say "RESULT: the disk never went away at all."
	say "  Either the port survived the charger_pd restart, or the ADSP boot"
	say "  did not disturb PD on this port. Either way root is still here."
elif [ -n "$_back_at" ]; then
	say "RESULT: THE PORT RE-ENUMERATES."
	say "  Gone at t+$((_gone_at - _t0))s, back at t+$((_back_at - _t0))s"
	say "  ($((_back_at - _gone_at))s away). This is the answer that unblocks"
	say "  the durable fix: a dracut pre-mount hook can do exactly this on"
	say "  every boot and root will still mount afterwards."
else
	say "RESULT: the disk did NOT come back within ${DISK_TIMEOUT}s."
	say "  The initramfs approach cannot work as-is. Root will fail to mount"
	say "  when you exit; that is expected, not a new fault. Power-cycle and"
	say "  boot the previous UKI. Nothing was written to the disk."
fi

# ---- did we get what we came for? -------------------------------------------

say ""
say "glink channels now on the ADSP edge:"
_found_gpr=no
for _d in /sys/bus/rpmsg/devices/6800000.remoteproc:glink-edge.*; do
	[ -e "$_d" ] || continue
	_n="${_d##*glink-edge.}"
	_n="${_n%.*.*}"
	say "  $_n"
	[ "$_n" = "adsp_apps" ] && _found_gpr=yes
done

say ""
if [ "$_found_gpr" = yes ]; then
	say "*** adsp_apps IS PRESENT -- gpr will bind and audio can come up. ***"
else
	say "adsp_apps is still absent. If the ADSP really is 'running' on the full"
	say "image, that contradicts the diagnosis and is worth capturing."
fi

say ""
say "Type 'exit' to resume the boot (dracut mounts root by UUID, so a new"
say "device name is fine). To bail out instead, power-cycle and select the"
say "previous UKI."
