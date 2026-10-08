#!/bin/bash
# Make sp11-winlog keep the previous boots' kernel logs instead of overwriting.
#
#   tools\sp11-disk.ps1 to-wsl
#   wsl -d Ubuntu-22.04 -u root bash tools/sp11-winlog-rotate.sh
#   tools\sp11-disk.ps1 to-win
#
# WHY
#
# sp11-winlog writes kmsg.txt with '>', so each boot overwrites the last. On
# 2026-08-05 the ps883x fix made the boot succeed 2 times out of 3 - and the two
# successes destroyed the kernel log of the one failure, which was the only boot
# worth reading. live.log survived only because it happens to append.
#
# An intermittent fault needs the FAILING run's log to survive the runs that
# follow it. Keep three generations.
set -eu

M=/mnt/sp11root
S="$M/usr/local/sbin/sp11-winlog"
ROOT_UUID=803b0fd3-9905-4cb7-8c44-a6dbcac1d4fd

DEV=$(blkid -U "$ROOT_UUID" 2>/dev/null || true)
[ -n "$DEV" ] || { echo "root fs not visible - run: tools\\sp11-disk.ps1 to-wsl"; exit 1; }

mkdir -p "$M"
mountpoint -q "$M" && umount "$M"
mount "$DEV" "$M"
trap 'sync; umount "$M" 2>/dev/null || true' EXIT

[ -f "$S" ] || { echo "no $S"; exit 1; }

if grep -q 'sp11-winlog: rotate' "$S"; then
    echo "already rotating - nothing to do"
    exit 0
fi

# Insert the rotation immediately before the cat that opens kmsg.txt.
python3 - "$S" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
anchor = 'cat /dev/kmsg > "$OUT/kmsg.txt" 2>/dev/null &\n'
rot = (
    '# sp11-winlog: rotate - keep the previous boots. Overwriting kmsg.txt means a\n'
    '# boot that succeeds destroys the log of the failure before it, which is\n'
    '# exactly backwards for an intermittent fault. Three generations is plenty.\n'
    'rm -f "$OUT/kmsg.2.txt" 2>/dev/null\n'
    'mv "$OUT/kmsg.1.txt" "$OUT/kmsg.2.txt" 2>/dev/null || true\n'
    'mv "$OUT/kmsg.txt"   "$OUT/kmsg.1.txt" 2>/dev/null || true\n'
    '\n'
)
if anchor not in s:
    sys.exit("anchor not found in sp11-winlog")
s = s.replace(anchor, rot + anchor, 1)
open(p, 'w').write(s)
print("rotation added")
PY

echo "=== resulting section ==="
grep -n -B2 -A6 'rotate' "$S" | sed 's/^/  /'
sync
echo "done - now run: tools\\sp11-disk.ps1 to-win"
