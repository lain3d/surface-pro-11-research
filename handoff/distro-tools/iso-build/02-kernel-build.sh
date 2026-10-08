#!/usr/bin/env bash
# Configure and build the patched kernel as .deb packages.
#
#   KSRC=/root/sp11/linux-sp11 KCONFIG=/path/to/config ./02-kernel-build.sh
#
# Config selection, in order of preference:
#   1. $KCONFIG                      - explicit
#   2. config extracted from the base ISO's squashfs (matches Ubuntu Concept)
#   3. the tree's own arm64 defconfig - last resort, will miss Ubuntu options
#
# Upstream install.sh uses `cp /boot/config-$(uname -r)`, which is wrong here:
# under WSL that is the Microsoft WSL2 kernel config, not the target's.
set -euo pipefail

KSRC="${KSRC:-/root/sp11/linux-sp11}"
WORK="${WORK:-/root/sp11}"
JOBS="${JOBS:-$(nproc)}"

cd "$KSRC"

echo "== selecting config =="
if [ -n "${KCONFIG:-}" ] && [ -f "$KCONFIG" ]; then
    echo "  using explicit: $KCONFIG"
    cp "$KCONFIG" .config
elif ls "$WORK"/squashfs-root/boot/config-* >/dev/null 2>&1; then
    src=$(ls "$WORK"/squashfs-root/boot/config-* | sort -V | tail -1)
    echo "  using ISO's kernel config: $src"
    cp "$src" .config
else
    echo "  WARNING: no Ubuntu config found, falling back to arm64 defconfig"
    make ARCH=arm64 defconfig
fi

echo
echo "== ensuring options the Surface Pro 11 needs =="
# These are what the patches actually rely on; olddefconfig would otherwise
# silently leave them unset if the source config predates them.
# NOTE: the HID-over-SPI symbols are SPI_HID*, not HID_SPI. SPI_HID_OF is the
# device-tree variant and is the one that matters here - the ACPI variant
# (SPI_HID_ACPI) is for firmware that describes the digitizer via PNP0C51, which
# is how Windows sees it, but Linux binds it from the Denali device tree.
scripts/config --file .config \
    --enable  CONFIG_SPI_QCOM_GENI \
    --enable  CONFIG_QCOM_GPI_DMA \
    --enable  CONFIG_SPI_HID \
    --module  CONFIG_SPI_HID_OF \
    --module  CONFIG_SPI_HID_CORE \
    --enable  CONFIG_ARCH_QCOM \
    --module  CONFIG_ATH12K \
    --enable  CONFIG_SND_SOC_QCOM \
    2>/dev/null || echo "  (scripts/config reported unknown symbols - checked after olddefconfig)"

# Ubuntu configs enable module signing against a key we do not have; disable so
# the build does not stop asking for one.
scripts/config --file .config \
    --disable CONFIG_MODULE_SIG_ALL \
    --disable CONFIG_MODULE_SIG_KEY \
    --disable CONFIG_SYSTEM_TRUSTED_KEYS \
    --disable CONFIG_SYSTEM_REVOCATION_KEYS \
    --disable CONFIG_DEBUG_INFO_BTF 2>/dev/null || true

make olddefconfig

echo
echo "== config check =="
for sym in CONFIG_SPI_QCOM_GENI CONFIG_QCOM_GPI_DMA CONFIG_SPI_HID CONFIG_SPI_HID_OF CONFIG_SPI_HID_CORE CONFIG_ATH12K; do
    printf '  %-24s %s\n' "$sym" "$(grep -E "^${sym}=" .config || echo 'NOT SET')"
done

echo
echo "== building ($JOBS jobs) - this takes a while =="
make -j"$JOBS" bindeb-pkg LOCALVERSION=-sp11 2>&1 | tail -25

echo
echo "== output =="
ls -la "$(dirname "$KSRC")"/*.deb
