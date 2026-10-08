#!/bin/bash
# Build the audio-debugging handoff for a session running ON the Surface.
#
#   wsl -d Ubuntu-22.04 -u root bash tools/make-audio-handoff.sh [destdir]
#
# Default destination is the T7's exFAT data partition, which is on the same
# physical disk as the Linux root - so the target can read it with no usbipd
# handoff, and it stays visible from Windows too.
#
# Two things this must get right, both learned the hard way:
#
#   1. LF line endings. Files come from `git archive`, which emits what git
#      stores, not the Windows working copy.
#   2. Private assistant memories are never copied into public handoffs.
#
# exFAT keeps no permission bits and no symlinks, so nothing here is marked
# executable. Run scripts as `bash foo.sh`, not `./foo.sh`.
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
LOGS=${LOGS:-/mnt/c/sp11-stage/logs}
DEST=${1:-/mnt/e/sp11-audio-handoff}

echo "=== destination: $DEST ==="
mkdir -p "$DEST"
rm -rf "${DEST:?}"/* 2>/dev/null || true

echo "=== docs and tools from git (LF, not the working copy) ==="
# START-HERE.md lives at the repo root - the on-machine session revised it there,
# and a second copy under tools/ would go stale exactly when it matters.
git -C "$REPO" archive --format=tar HEAD design tools handoff START-HERE.md LICENSE LICENSES | tar -x -C "$DEST"
echo "  $(find "$DEST" -type f | wc -l) files"

echo "=== logs ==="
mkdir -p "$DEST/logs"
# boot0 is the current state: integ20, ADSP attached, CDSP up, no audio.
for f in boot0.txt boot-1.txt; do
    [ -f "$LOGS/$f" ] && cp "$LOGS/$f" "$DEST/logs/" && echo "  $f"
done
# the streamed console, copied out of the Windows ESP by the caller
[ -f "$LOGS/kmsg-integ20.txt" ] && cp "$LOGS/kmsg-integ20.txt" "$DEST/logs/" \
    && echo "  kmsg-integ20.txt"

echo "=== normalise line endings ==="
find "$DEST" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.md' \) -print0 \
    | xargs -0 -r sed -i 's/\r$//'
# Check only the files that must be LF. The .ps1 scripts are CRLF on purpose -
# .gitattributes declares it, they run on the Windows side - so a blanket check
# over tools/ fails on correct content.
bad=$(find "$DEST" -type f \( -name '*.sh' -o -name '*.py' \) -exec grep -lq $'\r' {} \; -print)
if [ -n "$bad" ]; then
    echo "FAILED: CR still present in:"; echo "$bad" | sed 's/^/    /'; exit 1
fi
echo "  clean"

cat > "$DEST/README.txt" <<'TXT'
Audio debugging handoff for the Surface Pro 11.

Read START-HERE.md first. design/upstream-adsp-fix.md second.

This directory is on the T7's exFAT partition, the same physical disk as the
Linux root, so it is readable from both Linux and Windows. exFAT keeps no
permission bits - run scripts as `bash foo.sh`.
TXT

echo
echo "=== built ==="
du -sh "$DEST"
find "$DEST" -maxdepth 1 | sed "s|^$DEST|  .|" | sort
