#!/bin/bash
# Build the handoff tarball for a fresh session on the booted machine.
#
# Runs in WSL. Two things it must get right:
#
#   1. LF line endings. This repo is checked out with core.autocrlf=true, so the
#      Windows working copy has CRLF and any shell script taken straight from it
#      dies on Linux with "$'\r': command not found". Files are sourced with
#      `git archive`, which emits what git stores (LF), not the working copy.
#
#   2. Only public repository material is included. Private assistant memories
#      are intentionally never copied into release bundles.
#
# Usage:  bash tools/make-handoff-tar.sh [output.tar.gz]
set -euo pipefail

REPO=${REPO:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
WT=${WT:-}
# Preserved public squashed import; works in normal and bare clones.
BASE=${BASE:-31339fbd93060c569c7ae3b911f87726d3021fc6}
KERNEL_REF=${KERNEL_REF:-main}
OUT=${1:-$PWD/sp11-handoff-$(date +%Y%m%d).tar.gz}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/sp11-handoff"
mkdir -p "$ROOT"

echo "=== staging from git (LF endings, not the CRLF working copy) ==="
git -C "$REPO" archive --format=tar HEAD \
    BRINGUP.md START-HERE.md docs design probes tools data patches handoff LICENSES README.md LICENSE \
    | tar -x -C "$ROOT"
echo "  $(find "$ROOT" -type f | wc -l) files"

echo "=== kernel patch series ==="
if [ -n "$WT" ]; then
    git -C "$WT" rev-parse --verify "$BASE^{commit}" >/dev/null
    git -C "$WT" rev-parse --verify "$KERNEL_REF^{commit}" >/dev/null
    d="$ROOT/kernel-patches/main"
    mkdir -p "$d"
    git -C "$WT" format-patch -o "$d" "$BASE..$KERNEL_REF"
    git -C "$WT" log --oneline -1 "$BASE" > "$ROOT/kernel-patches/BASE.txt"
    git -C "$WT" rev-parse "$KERNEL_REF" > "$ROOT/kernel-patches/TIP.txt"
    cat >> "$ROOT/kernel-patches/BASE.txt" <<'TXT'

The series preserves the selected public kernel source tree, not a freshly
qualified integration. Apply it to the base recorded above:

  git checkout -b work <base>
  git am ../kernel-patches/main/*.patch

The base is the kernel repository's squashed upstream import. For the original
upstream provenance and experimental limits, read the public kernel README.
TXT
else
    echo "  no WT supplied; use the tagged public kernel source archive"
fi

echo "=== normalise line endings on anything executable ==="
find "$ROOT" -type f \( -name '*.sh' -o -name '*.py' \) -print0 \
    | xargs -0 -r sed -i 's/\r$//'
find "$ROOT" -type f \( -name '*.sh' -o -name '*.py' \) -exec chmod +x {} +

# PowerShell files intentionally use CRLF; only Linux executables must be LF.
bad=$(find "$ROOT" -type f \( -name '*.sh' -o -name '*.py' \) -exec grep -lq $'\r' {} \; -print)
if [ -n "$bad" ]; then
    echo "FAILED: CR still present in Linux executables:"; echo "$bad"; exit 1
fi
echo "  clean"

echo "=== pack ==="
mkdir -p "$(dirname "$OUT")"
tar -czf "$OUT" -C "$STAGE" sp11-handoff
echo
ls -la "$OUT"
sha256sum "$OUT"
echo
echo "contents:"
tar -tzf "$OUT" | sed 's|^sp11-handoff/||' | awk -F/ 'NF<=2' | sort | awk 'NR<=40'
echo
echo "Unpack on the target with:  tar -xzf $(basename "$OUT") && cd sp11-handoff && cat BRINGUP.md"
