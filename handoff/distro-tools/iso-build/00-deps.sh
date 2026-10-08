#!/usr/bin/env bash
# Install everything needed to build the patched kernel and remaster the ISO.
# Run as root inside an aarch64 Linux environment (WSL2 Ubuntu works natively -
# no cross-compilation, since the Windows host is already ARM64).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "== apt update =="
apt-get update -qq

echo "== kernel build deps =="
# libdw-dev is a build-dependency of `make bindeb-pkg` (dpkg-checkbuilddeps
# aborts without it); debhelper/fakeroot are needed by the Debian packaging path.
apt-get install -y -qq \
    build-essential git flex bison libssl-dev libelf-dev bc rsync kmod cpio \
    dwarves zstd python3 pahole libdw-dev debhelper fakeroot

echo "== ISO remastering deps =="
apt-get install -y -qq \
    squashfs-tools xorriso genisoimage rsync file

echo "== verify =="
missing=0
for p in gcc make flex bison bc mksquashfs unsquashfs xorriso rsync; do
    if command -v "$p" >/dev/null 2>&1; then
        printf '  %-12s %s\n' "$p" "$(command -v "$p")"
    else
        printf '  %-12s MISSING\n' "$p"
        missing=1
    fi
done

echo
echo "arch: $(uname -m)  cores: $(nproc)  mem: $(free -h | sed -n '2p' | tr -s ' ' | cut -d' ' -f2)"
[ "$(uname -m)" = "aarch64" ] || echo "WARNING: not aarch64 - kernel build would need cross-compilation"
exit $missing
