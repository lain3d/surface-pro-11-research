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
WT=${WT:-/root/sp11/wt-ov13858}
BASE=${BASE:-18b0b569c}
OUT=${1:-$PWD/sp11-handoff-$(date +%Y%m%d).tar.gz}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ROOT="$STAGE/sp11-handoff"
mkdir -p "$ROOT"

echo "=== staging from git (LF endings, not the CRLF working copy) ==="
git -C "$REPO" archive --format=tar HEAD \
    BRINGUP.md docs design probes tools data README.md LICENSE \
    | tar -x -C "$ROOT"
echo "  $(find "$ROOT" -type f | wc -l) files"

echo "=== kernel patch series ==="
if [ -d "$WT" ]; then
    for b in camera/ov13858-dt camera/denali-pm8010 usb4/platform-nhi \
             camera/imx681 debug/imx681-addr-scan; do
        d="$ROOT/kernel-patches/$(echo "$b" | tr / -)"
        mkdir -p "$d"
        n=$(git -C "$WT" format-patch -o "$d" "$BASE..$b" 2>/dev/null | wc -l)
        echo "  $b: $n patches"
    done
    git -C "$WT" log --oneline -1 "$BASE" > "$ROOT/kernel-patches/BASE.txt"
    cat >> "$ROOT/kernel-patches/BASE.txt" <<'TXT'

All series apply on the commit above. Its tree is byte-identical to the commit
the baseline ISO's kernel was built from -- different hashes, same content.

  git checkout -b work <base>
  git am ../kernel-patches/camera-denali-pm8010/*.patch
  ...

debug-imx681-addr-scan is a THROWAWAY. It carries a placeholder I2C address and
exists only to discover the real one. Never merge it.
TXT
else
    echo "  WARNING: no kernel worktree at $WT; skipping"
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
tar -tzf "$OUT" | sed 's|^sp11-handoff/||' | awk -F/ 'NF<=2' | sort | head -40
echo
echo "Unpack on the target with:  tar -xzf $(basename "$OUT") && cd sp11-handoff && cat BRINGUP.md"
