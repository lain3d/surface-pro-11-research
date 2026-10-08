#!/bin/bash
# Rebuild a UKI with one cmdline token REMOVED.
#
#   wsl -u root env SRC=... OUT=... DROP='modprobe.blacklist=thunderbolt' \
#       bash tools/sp11-uki-drop-arg.sh
#
# sp11-patch-cmdline.sh can append (ADD=) or replace wholesale (SET=), and
# replacing wholesale means retyping root=UUID=... by hand. That is exactly the
# kind of transcription this project cannot afford: a UKI with a wrong or
# missing root= boots to an emergency shell, and there is no keyboard in the
# initramfs, so the only way out is a power-button hold.
#
# So: read the existing cmdline out of the UKI, delete the token, and hand the
# result to SET= without a human in the loop. DROP is matched as a whole
# whitespace-delimited token, never as a substring.
set -u

SRC=${SRC:?set SRC to the input UKI}
OUT=${OUT:?set OUT to the output UKI}
DROP=${DROP:?set DROP to the cmdline token to remove}

here=$(cd "$(dirname "$0")" && pwd)

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
objcopy --dump-section ".cmdline=$T/c.bin" "$SRC" /dev/null 2>/dev/null || true
[ -s "$T/c.bin" ] || { echo "could not read .cmdline from $SRC"; exit 1; }
OLD=$(tr -d '\0' < "$T/c.bin")

NEW=""
found=0
for tok in $OLD; do
    if [ "$tok" = "$DROP" ]; then found=1; continue; fi
    NEW="${NEW:+$NEW }$tok"
done

echo "old: $OLD"
echo "new: $NEW"
if [ "$found" = 0 ]; then
    echo "refusing: '$DROP' is not present in the cmdline - nothing to do"
    exit 1
fi
case "$NEW" in *root=*) ;; *) echo "refusing: no root= left"; exit 1 ;; esac

SRC="$SRC" OUT="$OUT" SET="$NEW" bash "$here/sp11-patch-cmdline.sh"
