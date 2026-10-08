#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
#
# Build a test UKI that stops in the dracut pre-mount shell, so the ADSP can be
# booted before the root filesystem is mounted.
#
# It takes the UKI currently on the ESP and changes ONE thing -- .cmdline --
# adding:
#
#   rd.break=pre-mount     stop before root is mounted
#   modprobe.blacklist=qcom_q6v5_pas,...
#                          stop udev autoloading the driver during coldplug.
#                          Without this the ADSP is bound in *attach* mode
#                          before you ever get a prompt, and the test is
#                          impossible. The existing blacklist is preserved.
#
# HOW, AND WHY NOT --update-section
#
# objcopy --update-section does NOT grow a PE section: it silently truncates
# the new contents to the old section size. That was measured here -- the
# cmdline came back cut off mid-word at "modprobe.blacklist=qcom_q6v5_p", in an
# image that was otherwise byte-identical and would have booted with a
# malformed root= line.
#
# So the image is rebuilt instead: strip the UKI payload sections back to the
# bare systemd stub, then re-add every one of them at its ORIGINAL VMA. That
# works without disturbing anything because .cmdline already owns a full 4 KiB
# page and only used 0x99 bytes of it, so widening it moves nothing else. The
# result is verified to be the same total size, with an identical section table
# and identical section hashes everywhere except .cmdline.
#
#   sudo ./sp11-build-adsp-test-uki.sh              build + verify only
#   sudo ./sp11-build-adsp-test-uki.sh --install    also make it the boot default
#   sudo ./sp11-build-adsp-test-uki.sh --rollback   restore the saved original
#   sudo ./sp11-build-adsp-test-uki.sh --status     show what is on the ESP
#
# Rollback is always available: the original is copied to EFI/sp11/ before
# anything is overwritten, and stock-fallback.efi is never touched.
set -euo pipefail

ESP="${ESP:-/boot/efi}"
BOOTFILE="$ESP/EFI/BOOT/BOOTAA64.EFI"
OUTDIR="$ESP/EFI/sp11"
OUT="$OUTDIR/adsp-test.efi"
SAVED="$OUTDIR/pre-adsp-test-backup.efi"

# The payload sections a UKI adds on top of the stub, in the order they appear.
UKI_SECTIONS=(.osrel .uname .cmdline .dtb .dtbauto .hwids .linux .initrd .sbom .profile .ucode)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

say() { echo "[uki] $*"; }
die() { echo "[uki] ERROR: $*" >&2; exit 1; }

ACTION=build
case "${1:-}" in
	--install)  ACTION=install ;;
	--rollback) ACTION=rollback ;;
	--status)   ACTION=status ;;
	"")         ;;
	*)          die "unknown option '$1'" ;;
esac

[ "$(id -u)" -eq 0 ] || die "run with sudo (writes to the ESP)"
command -v objcopy >/dev/null || die "objcopy not found (install binutils)"
command -v objdump >/dev/null || die "objdump not found (install binutils)"
mountpoint -q "$ESP" || die "$ESP is not mounted"

# objcopy --dump-section returns non-zero when the output file is /dev/null even
# though the dump succeeds, so never test its exit status -- test the artefact.
dump_section() {	# <section> <file> <destfile>; returns 1 if absent/empty
	objcopy --dump-section "$1=$3" "$2" /dev/null 2>/dev/null || true
	[ -s "$3" ]
}

# "name size vma fileoff" for every section, in file order.
section_table() { objdump -h "$1" | awk '/^ *[0-9]+ \./ {print $2, $3, $4, $6}'; }

# --------------------------------------------------------------- status ----
if [ "$ACTION" = status ]; then
	for f in "$BOOTFILE" "$OUT" "$SAVED" "$OUTDIR/stock-fallback.efi"; do
		[ -f "$f" ] || continue
		printf '%12s  %s\n' "$(stat -c %s "$f")" "$f"
		if dump_section .cmdline "$f" "$WORK/c"; then
			printf '%12s  cmdline: %s\n' "" "$(tr -d '\0' < "$WORK/c")"
		fi
	done
	exit 0
fi

# ------------------------------------------------------------- rollback ----
if [ "$ACTION" = rollback ]; then
	[ -f "$SAVED" ] || die "no saved original at $SAVED"
	cp "$SAVED" "$BOOTFILE"; sync
	say "restored $SAVED -> $BOOTFILE"
	say "reboot to return to the previous behaviour."
	exit 0
fi

# ---------------------------------------------------------------- build ----
[ -f "$BOOTFILE" ] || die "$BOOTFILE not found"
mkdir -p "$OUTDIR"
say "source: $BOOTFILE ($(stat -c %s "$BOOTFILE") bytes)"

# Which payload sections does this image actually have, and at what VMA?
present=(); declare -A VMA
while read -r name size vma off; do
	for s in "${UKI_SECTIONS[@]}"; do
		if [ "$name" = "$s" ]; then present+=("$name"); VMA[$name]="0x$vma"; fi
	done
done < <(section_table "$BOOTFILE")

[ ${#present[@]} -gt 0 ] || die "no UKI payload sections found -- is this really a UKI?"
say "payload sections: ${present[*]}"

for s in .cmdline .linux; do
	[[ " ${present[*]} " == *" $s "* ]] || die "source UKI has no $s section"
done

for s in "${present[@]}"; do
	dump_section "$s" "$BOOTFILE" "$WORK/orig$s" || die "could not dump $s"
done

OLD_CMDLINE="$(tr -d '\0' < "$WORK/orig.cmdline")"
say "current cmdline: $OLD_CMDLINE"
case "$OLD_CMDLINE" in
	*rd.break*) die "source already has rd.break -- refusing to stack it" ;;
esac

# Extend the existing blacklist rather than adding a second one; the kernel
# honours only the last modprobe.blacklist= it sees.
if [[ "$OLD_CMDLINE" == *modprobe.blacklist=* ]]; then
	NEW_CMDLINE="${OLD_CMDLINE/modprobe.blacklist=/modprobe.blacklist=qcom_q6v5_pas,}"
else
	NEW_CMDLINE="$OLD_CMDLINE modprobe.blacklist=qcom_q6v5_pas"
fi
NEW_CMDLINE="$NEW_CMDLINE rd.break=pre-mount"
printf '%s\0' "$NEW_CMDLINE" > "$WORK/new.cmdline"
say "new cmdline:     $NEW_CMDLINE"

# .cmdline may only grow into its own page, or later sections would have to move.
cmd_vma=$(( ${VMA[.cmdline]} ))
next_vma=0
while read -r _n _sz vma _off; do
	v=$((0x$vma)); if [ "$v" -gt "$cmd_vma" ]; then next_vma=$v; break; fi
done < <(section_table "$BOOTFILE")
headroom=$(( next_vma - cmd_vma ))
newsize=$(stat -c %s "$WORK/new.cmdline")
say "cmdline ${#OLD_CMDLINE} -> ${#NEW_CMDLINE} chars (${newsize} bytes, ${headroom} available in the page)"
[ "$newsize" -le "$headroom" ] || die "new cmdline needs $newsize bytes but only $headroom fit before the next section"

# Strip to the bare stub, then re-add every payload section at its original VMA.
rm_args=(); for s in "${present[@]}"; do rm_args+=(--remove-section "$s"); done
objcopy "${rm_args[@]}" "$BOOTFILE" "$WORK/stub.efi" || die "failed to strip payload sections"
say "recovered stub: $(stat -c %s "$WORK/stub.efi") bytes"

add_args=()
for s in "${present[@]}"; do
	src="$WORK/orig$s"; [ "$s" = ".cmdline" ] && src="$WORK/new.cmdline"
	add_args+=(--add-section "$s=$src" --change-section-vma "$s=${VMA[$s]}")
done
objcopy "${add_args[@]}" "$WORK/stub.efi" "$WORK/out.efi" || die "failed to rebuild"

# ---- verify ---------------------------------------------------------------
say ""
say "verifying..."
ok=1

a=$(stat -c %s "$BOOTFILE"); b=$(stat -c %s "$WORK/out.efi")
if [ "$a" = "$b" ]; then say "  total size identical ($b bytes)"
else say "  total size $a -> $b (layout moved)"; ok=0; fi

# Section table must match exactly, except .cmdline's size field.
if diff <(section_table "$BOOTFILE" | grep -v '^\.cmdline ') \
        <(section_table "$WORK/out.efi" | grep -v '^\.cmdline ') >/dev/null; then
	say "  section table identical for every section except .cmdline"
else
	say "  SECTION TABLE CHANGED:"
	diff <(section_table "$BOOTFILE") <(section_table "$WORK/out.efi") | sed 's/^/    /' || true
	ok=0
fi

for s in "${present[@]}"; do
	[ "$s" = ".cmdline" ] && continue
	dump_section "$s" "$WORK/out.efi" "$WORK/chk$s" || { say "  $s MISSING in output"; ok=0; continue; }
	if cmp -s "$WORK/orig$s" "$WORK/chk$s"; then
		printf '  %-9s identical (%s bytes)\n' "$s" "$(stat -c %s "$WORK/chk$s")"
	else
		printf '  %-9s ***CHANGED*** -- rebuild corrupted it\n' "$s"; ok=0
	fi
done

dump_section .cmdline "$WORK/out.efi" "$WORK/chk.cmdline" || { say "  .cmdline MISSING"; ok=0; }
got="$(tr -d '\0' < "$WORK/chk.cmdline")"
if [ "$got" = "$NEW_CMDLINE" ]; then
	say "  .cmdline correct and NUL-terminated"
else
	say "  .cmdline WRONG -- got: $got"; ok=0
fi

[ "$ok" -eq 1 ] || die "verification FAILED -- nothing was installed, the ESP is untouched."

install -m 0644 "$WORK/out.efi" "$OUT"; sync
say ""
say "built and verified: $OUT"

if [ "$ACTION" = install ]; then
	if [ ! -f "$SAVED" ]; then cp "$BOOTFILE" "$SAVED"; say "saved original -> $SAVED"; fi
	cp "$OUT" "$BOOTFILE"; sync
	say "installed as $BOOTFILE -- the next boot will run it."
	say "undo without booting it:  sudo $0 --rollback"
else
	say "not installed. To make it the boot default:  sudo $0 --install"
fi

cat <<'EOF'

--------------------------------------------------------------------------
Next boot you land at a "dracut:/#" prompt, before root is mounted. Run:
The helper must have been copied from the public research checkout's
tools/sp11-adsp-initramfs-boot.sh to /usr/local/sbin/sp11-adsp on that root.


  mkdir -p /sp11root
  mount -o ro /dev/disk/by-uuid/<ROOT-UUID> /sp11root
  sh /sp11root/usr/local/sbin/sp11-adsp

Then, whatever it reports:

  exit          <-- resumes the boot. dracut mounts root by UUID, so the disk
                    coming back as sdb instead of sda does not matter.

If the disk does NOT come back, exiting drops you into dracut's emergency
shell. That is the "no" answer, not a new fault -- power-cycle, and the ESP
still holds EFI/sp11/stock-fallback.efi and the saved original.
--------------------------------------------------------------------------
EOF
