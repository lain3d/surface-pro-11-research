#!/usr/bin/env bash
# Clone the already-patched public Surface Pro 11 kernel tree.
# Separated from the build so it can run while the base ISO downloads.
#
#   KSRC=/root/sp11/linux-sp11 bash 01-kernel-fetch.sh
set -euo pipefail

KSRC="${KSRC:-/root/sp11/linux-sp11}"
KERNEL_REPO="${KERNEL_REPO:-https://github.com/lain3d/surface-pro-11-kernel.git}"
KERNEL_BRANCH="${KERNEL_BRANCH:-main}"

echo "== kernel source: $KSRC ($KERNEL_REPO, branch $KERNEL_BRANCH) =="
mkdir -p "$(dirname "$KSRC")"

if [ ! -d "$KSRC/.git" ]; then
    git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KSRC"
else
    echo "  already present, reusing without fetch, checkout or reset"
fi

cd "$KSRC"
# Keep these separate from echo: command substitutions in echo would mask a
# failed git or make command, despite set -e.
HEAD_INFO="$(git log --oneline -1)"
KERNEL_VERSION="$(make kernelversion)"
echo "  HEAD: $HEAD_INFO"
echo "  kernel version: $KERNEL_VERSION"
