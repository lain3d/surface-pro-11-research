#!/bin/bash
#
# Build, verify and stage the CCI bus-sweep debug branch onto the exFAT drive.
#
#   https://github.com/lain3d/surface-pro-11-kernel/pull/7
#   branch: debug/cci-bus-scan
#
# Run from WSL as root:
#   bash tools/pr7_cci-bus-scan/stage-cci-scan.sh [branch] [dest]
#
# Everything happens in a scratch worktree, so the main build tree stays on
# integration/iso2 and keeps reproducing the DTB that is currently booting.
#
# THE THING THAT MAKES THIS NON-TRIVIAL
#
# CONFIG_VIDEO_IMX681=m. The scan runs from the driver's probe, and the driver
# is loaded by udev from /lib/modules/$(uname -r) on the ROOT filesystem. This
# branch has a different `git describe` than the kernel whose modules are
# installed there, so the release string differs and modprobe finds nothing --
# the image would boot and the scan would never run.
#
# So this stages the modules too, and says plainly what has to be installed.
# It does not fake LOCALVERSION to paper over the mismatch: `git describe` is
# the ground truth for which tree a build came from.

set -eu

BRANCH=${1:-debug/cci-bus-scan}
DEST=${2:-/mnt/e/surface/pr7_cci-bus-scan}
MAIN=/root/sp11/wt-ov13858
STAGE=/mnt/c/sp11-stage
W=/root/sp11/wt-prstage
AUDIT=/mnt/c/Users/Crazy/projs/arm64-egpu/tools/dt-audit.py
BOARD=x1e80100-microsoft-denali-oled
INITRD=$STAGE/initrd-sp11log.img
STUB=$STAGE/linuxaa64-259.efi.stub
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

say() { printf '%s\n' "$*"; }
hr()  { printf -- '--- %s ---\n' "$*"; }

fail=0
note_fail() { say "  *** $* ***"; fail=1; }

hr "worktree"
cd "$MAIN"
git worktree remove --force "$W" 2>/dev/null || true
rm -rf "$W"
git worktree add -q --detach "$W" "$BRANCH"
cd "$W"
say "  $BRANCH @ $(git rev-parse --short HEAD)"
say "  $(git log --format='%s' -1)"

hr "seed"
# Seed from the main tree's objects so this is incremental. Without it this is
# a cold build of ~11000 objects; the first run of this script took most of an
# hour for what should be minutes.
tar -C "$MAIN" -cf - --exclude=.git . 2>/dev/null | tar -C "$W" -xf - 2>/dev/null || true
git checkout -- . 2>/dev/null || true
say "  seeded: $(du -sh . 2>/dev/null | cut -f1)"

hr "configure"
cp "$MAIN/.config" .config
make -j"$(nproc)" olddefconfig </dev/null >/dev/null 2>&1
REL=$(make -s LOCALVERSION=-sp11-integ kernelrelease </dev/null 2>/dev/null | tail -1)
say "  kernelrelease: $REL"
IMX=$(grep -E '^CONFIG_VIDEO_IMX681=' .config | cut -d= -f2 || true)
say "  CONFIG_VIDEO_IMX681=$IMX"

hr "build"
make -j"$(nproc)" LOCALVERSION=-sp11-integ Image dtbs </dev/null > /tmp/prbuild.log 2>&1 \
    || { note_fail "kernel build failed"; tail -20 /tmp/prbuild.log; exit 1; }
say "  Image + dtbs ok"
if [ "$IMX" = "m" ]; then
    make -j"$(nproc)" LOCALVERSION=-sp11-integ modules </dev/null >> /tmp/prbuild.log 2>&1 \
        || { note_fail "modules build failed"; tail -20 /tmp/prbuild.log; exit 1; }
    rm -rf /tmp/prmod
    make -j"$(nproc)" LOCALVERSION=-sp11-integ INSTALL_MOD_PATH=/tmp/prmod \
        INSTALL_MOD_STRIP=1 modules_install </dev/null >> /tmp/prbuild.log 2>&1 \
        || { note_fail "modules_install failed"; exit 1; }
    say "  modules built and installed to /tmp/prmod"
fi

hr "verify the image"
I=arch/arm64/boot/Image
head -c2 "$I" | grep -q MZ && say "  MZ ok" || note_fail "not a PE image"
MAGIC=$(od -An -tx4 -j56 -N4 "$I" | tr -d ' ')
[ "$MAGIC" = "644d5241" ] && say "  ARM64 magic ok" || note_fail "bad arm64 magic ($MAGIC)"
# The first 7.1.3 string in the image is the vermagic line, which is the
# release followed by " SMP preempt mod_unload aarch64". Compare the first
# field only -- comparing the whole line always fails.
INSIDE=$(strings -a "$I" | grep -m1 '^7\.1\.3' | awk '{print $1}' || true)
say "  image says: $INSIDE"
[ "$INSIDE" = "$REL" ] || note_fail "image release ($INSIDE) does not match kernelrelease ($REL)"

hr "verify the device tree"
B=arch/arm64/boot/dts/qcom/$BOARD.dtb
say "  $(stat -c%s "$B") bytes"
python3 "$AUDIT" --tree "$W" --board "$BOARD" \
    --check REG-GRID,NAME-COUNT,GDSC,DEAD-REF --quiet-hints 2>&1 | sed -n '1,8p' | sed 's/^/  /'
dtc -I dtb -O dts "$B" 2>/dev/null > /tmp/prdt.dts
NBUS=$(grep -c 'i2c-bus@' /tmp/prdt.dts || true)
say "  i2c-bus nodes under cci: $NBUS  (want 8: two controllers, two buses, twice in the tree)"
for t in 'sony,imx681' 'camera@10'; do
    printf '  %-16s %s\n' "$t" "$(grep -c "$t" /tmp/prdt.dts || true)"
done
CCI0=$(sed -n '/cci@ac15000 {/,/^\t\t};/p' /tmp/prdt.dts | grep -m1 status | tr -d '\t ')
say "  cci@ac15000 $CCI0"
[ "$CCI0" = 'status="okay";' ] && say "  cci0 enabled" || note_fail "cci0 not enabled -- the sweep would only see cci1"

hr "assemble the UKI"
Wd=/tmp/pruki; rm -rf "$Wd"; mkdir -p "$Wd"
OUT=$Wd/BOOTAA64-cci-scan.efi
printf 'ID=ubuntu\nPRETTY_NAME="Ubuntu 26.04 sp11 cci-scan"\n' > "$Wd/osrel"
printf '%s' "$REL" > "$Wd/uname"
printf 'root=UUID=%s ro loglevel=7 console=tty0 clk_ignore_unused pd_ignore_unused arm64.nopauth modprobe.blacklist=thunderbolt' \
    "$ROOT_UUID" > "$Wd/cmdline"
align=$(objdump -p "$STUB" | awk '/SectionAlignment/ {print strtonum("0x"$2)}')
[ "${align:-0}" -gt 0 ] || align=4096
off=$(objdump -h "$STUB" | awk 'NF>=6 && $2 ~ /^\./ {print strtonum("0x"$3)+strtonum("0x"$4)}' | sort -n | tail -1)
off=$(( (off + align - 1) / align * align ))
args=()
add() { local n=$1 f=$2 sz; sz=$(stat -c%s "$f")
    args+=(--add-section ".$n=$f" --change-section-vma ".$n=$(printf '0x%x' $off)")
    off=$(( (off + sz + align - 1) / align * align )); }
add osrel "$Wd/osrel"; add uname "$Wd/uname"; add cmdline "$Wd/cmdline"
add dtb "$B"; add linux "$I"; add initrd "$INITRD"
objcopy "${args[@]}" "$STUB" "$OUT"
head -c2 "$OUT" | grep -q MZ && say "  MZ ok" || note_fail "UKI is not a PE"
for s in cmdline dtb linux initrd; do
    case $s in cmdline) src=$Wd/cmdline;; dtb) src=$B;; linux) src=$I;; initrd) src=$INITRD;; esac
    objcopy -O binary --only-section=".$s" "$OUT" "$Wd/rb" 2>/dev/null
    cmp -s "$Wd/rb" "$src" && say "  .$s byte-identical" || note_fail ".$s mismatch"
done
rm -f "$Wd/rb"

hr "the module problem, stated"
STAGED_REL=7.1.3-sp11-integ-gf2cc827b6b89
if [ "$REL" = "$STAGED_REL" ]; then
    say "  release matches the installed modules -- nothing extra to install"
    NEEDMOD=no
else
    say "  this build:        $REL"
    say "  modules on root:   $STAGED_REL"
    say "  -> imx681.ko will NOT be found by modprobe, and the scan will not run"
    say "     until the staged modules are installed. Booting without them gives"
    say "     a working machine and no camera output, not a failure."
    NEEDMOD=yes
fi

hr "stage"
# Refuse to stage a failed build. The first version of this script set a flag
# on failure and only consulted it at the very end -- after writing a bootable
# image and a README full of install commands onto the drive. It correctly
# detected that the DTB had two off-grid rails and would stall the boot at
# 0.196s, then staged it anyway. Detecting a problem and proceeding is worse
# than not checking, because the report reads as a warning next to an artifact
# that looks ready.
if [ "$fail" -ne 0 ]; then
    say ""
    note_fail "checks failed -- refusing to stage"
    say "  Nothing was written to $DEST. Fix the branch and re-run."
    say "  If this is the voltage-grid failure, the branch is missing 80b11c712;"
    say "  topic branches fork from sp11 and do not inherit each other's fixes."
    cd "$MAIN"
    git worktree remove --force "$W" 2>/dev/null || true
    exit 1
fi
mkdir -p "$DEST"
cp "$OUT"  "$DEST/"
cp "$I"    "$DEST/Image-cci-scan"
cp "$B"    "$DEST/$BOARD-cci-scan.dtb"
cp .config "$DEST/config-cci-scan"
if [ "$NEEDMOD" = yes ] && [ -d /tmp/prmod/lib/modules/"$REL" ]; then
    tar -C /tmp/prmod/lib/modules -czf "$DEST/modules-$REL.tar.gz" "$REL"
    say "  modules-$REL.tar.gz  $(stat -c%s "$DEST/modules-$REL.tar.gz") bytes"
fi
( cd "$DEST" && sha256sum ./* > SHA256SUMS 2>/dev/null || true )

cat > "$DEST/README.md" <<EOF
# PR #7 — sweep every CCI bus

https://github.com/lain3d/surface-pro-11-kernel/pull/7

Branch \`$BRANCH\` @ $(cd "$W" && git rev-parse --short HEAD)
Built $(date -u +'%Y-%m-%d %H:%MZ') · kernel release \`$REL\`

## What it answers

The front-camera bus scan found three responders where two were expected:
\`0x10\` (sensor), \`0x50\` (module EEPROM) and an unaccounted \`0x1a\`. This
build enables all four CCI buses and sweeps them, labelling each responder with
its bus. If \`0x1a\` is confined to \`cci1_i2c1\` the IR sensor is ruled out,
leaving the module's actuator.

A silent bus proves nothing: only the front sensor is powered, so parts still
held in reset cannot answer.

## Install

    Get-Partition -DiskNumber 1 -PartitionNumber 4 | Add-PartitionAccessPath -AccessPath 'X:\\'
    Copy-Item <this dir>\\BOOTAA64-cci-scan.efi X:\\EFI\\BOOT\\BOOTAA64.EFI -Force
    Get-Partition -DiskNumber 1 -PartitionNumber 4 | Remove-PartitionAccessPath -AccessPath 'X:\\'

## Revert

    Copy-Item C:\\sp11-stage\\BOOTAA64-integ8.efi X:\\EFI\\BOOT\\BOOTAA64.EFI -Force

\`\\EFI\\sp11\\stock-fallback.efi\` restores a known-good machine in one copy.

## Modules

CONFIG_VIDEO_IMX681=m, and this build's release string is \`$REL\` while the
modules on the root filesystem are \`$STAGED_REL\`. **modprobe will not find
imx681.ko**, so the scan will not run until \`modules-$REL.tar.gz\` is unpacked
into \`/lib/modules/\` on the root and \`depmod -a $REL\` is run.

Booting without that is harmless — it just produces no scan output.

## Read the result

The pre-pivot hook copies the previous boot's journal to the ESP under
\`sp11-diag/\`. Look for \`DEBUG:\` lines; each is labelled with its bus.
EOF

hr "result"
say "  staged to $DEST"
ls -1 "$DEST" | sed 's/^/    /'
cd "$MAIN"
git worktree remove --force "$W" 2>/dev/null || true
say "  main tree back on $(git branch --show-current)"
if [ "$fail" -ne 0 ]; then
    say ""
    say "  ONE OR MORE CHECKS FAILED -- read above before installing"
    exit 1
fi
say "  all checks passed"
