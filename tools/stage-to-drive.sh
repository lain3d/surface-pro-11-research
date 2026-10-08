#!/bin/bash
# Stage every deliverable onto an external drive under surface/.
#
# Copies from inside WSL (/mnt/d) rather than across the 9p share from Windows,
# which is markedly faster for multi-GB files. Verifies every checksum after the
# copy, because a truncated 4 GB ISO looks exactly like a good one.
#
# Usage:  bash tools/stage-to-drive.sh [/mnt/d/surface]
set -uo pipefail

DEST=${1:-/mnt/d/surface}
SRC=/home/lain/sp11-out
DOCS=/mnt/c/Users/Crazy/Documents

fail=0
step() { echo; echo "### $* ###"; }

step "target"
mkdir -p "$DEST"/{iso,handoff,kernel-debs} || exit 1
echo "  $DEST"
df -h "$DEST" | tail -1 | sed 's/^/  /'

step "ISOs"
for f in "$SRC/baseline/surface-pro-11-ubuntu-BASELINE-"*.iso \
         "$SRC/surface-pro-11-ubuntu-INTEG-"*.iso; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f")  $(du -h "$f" | cut -f1)"
    cp -n "$f" "$DEST/iso/" || fail=1
done
cp -n "$SRC"/*.sha256 "$DEST/iso/" 2>/dev/null
cp -n "$SRC"/baseline/SHA256SUMS "$DEST/iso/BASELINE.SHA256SUMS" 2>/dev/null

step "kernel packages"
cp -n "$SRC"/baseline/*.deb "$DEST/kernel-debs/" 2>/dev/null
ls -1 "$DEST/kernel-debs/" 2>/dev/null | sed 's/^/  /'

step "handoff tarballs"
for f in "$DOCS"/sp11-handoff-*.tar.gz "$DOCS"/sp11-repos-*.tar; do
    [ -f "$f" ] || continue
    echo "  $(basename "$f")  $(du -h "$f" | cut -f1)"
    cp -n "$f" "$DEST/handoff/" || fail=1
done

step "unpack the small bundle so the docs are readable without extracting"
if [ ! -d "$DEST/handoff/sp11-handoff" ]; then
    tar -xzf "$DEST/handoff"/sp11-handoff-*.tar.gz -C "$DEST/handoff/" && echo "  unpacked"
else
    echo "  already unpacked"
fi

step "verify every checksum"
cd "$DEST/iso"
for s in *.sha256; do
    [ -f "$s" ] || continue
    # the .sha256 files record absolute source paths; compare hashes directly
    want=$(awk '{print $1}' "$s")
    img=$(basename "$(awk '{print $2}' "$s")")
    if [ -f "$img" ]; then
        got=$(sha256sum "$img" | awk '{print $1}')
        if [ "$want" = "$got" ]; then echo "  OK       $img"; else echo "  MISMATCH $img"; fail=1; fi
    fi
done
if [ -f BASELINE.SHA256SUMS ]; then
    ( cd "$DEST/kernel-debs" && sha256sum -c --ignore-missing "$DEST/iso/BASELINE.SHA256SUMS" 2>/dev/null | sed 's/^/  /' )
fi

step "result"
du -sh "$DEST"/* 2>/dev/null
echo
if [ $fail -eq 0 ]; then echo "ALL VERIFIED"; else echo "SOMETHING FAILED - see above"; exit 1; fi
