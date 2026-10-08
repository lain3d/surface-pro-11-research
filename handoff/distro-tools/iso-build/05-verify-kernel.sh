#!/usr/bin/env bash
# Verify the built kernel actually contains what the patches were supposed to add.
# Cheap sanity check before spending 20 minutes remastering a 4 GB ISO.
set -euo pipefail

WORK="${WORK:-/root/sp11}"
TMP="$WORK/verify"

DEB=$(ls "$WORK"/linux-image-*-sp11-*_*.deb 2>/dev/null | grep -v dbg | head -1)
[ -n "$DEB" ] || { echo "no kernel .deb in $WORK"; exit 1; }
echo "deb: $(basename "$DEB")"

rm -rf "$TMP"; mkdir -p "$TMP"
dpkg-deb -x "$DEB" "$TMP"

fail=0
check() { if [ "$1" = 1 ]; then printf '  \033[32mOK\033[0m       %s\n' "$2"; else printf '  \033[31mMISSING\033[0m  %s\n' "$2"; fail=1; fi; }

echo
echo "== HID-over-SPI driver modules =="
for m in spi-hid.ko spi-hid-of.ko; do
    n=$(find "$TMP" -name "$m" | wc -l)
    check "$([ "$n" -gt 0 ] && echo 1 || echo 0)" "$m"
done

echo
echo "== device trees for this machine =="
DTB=$(find "$TMP" -name 'x1e80100-microsoft-denali-oled.dtb' | head -1)
check "$([ -n "$DTB" ] && echo 1 || echo 0)" "x1e80100-microsoft-denali-oled.dtb (this SKU: OLED / X1E)"
[ -n "$DTB" ] || { echo; echo "cannot continue without the DTB"; exit 1; }
echo "     $DTB"

echo
echo "== DTB contents =="
# Property and compatible strings are stored as plain text in a DTB, so grep on
# the binary is sufficient and avoids depending on dtc.
# These are the properties drivers/hid/spi-hid/spi-hid-of.c actually reads via
# device_property_read_u32. Note it does NOT read `hid-descr-addr` - that is an
# i2c-hid property, and checking for it here was a bug in an earlier version of
# this script that made a correct build look broken.
for s in "hid-over-spi:touchscreen driver binding (patch 0004)" \
         "input-report-header-address:HID input report header address" \
         "input-report-body-address:HID input report body address" \
         "output-report-address:HID output report address" \
         "read-opcode:SPI read opcode" \
         "write-opcode:SPI write opcode" \
         "spi-max-frequency:SPI clock property" \
         "disable-rfkill:wifi rfkill bypass (already upstream)" \
         "qcom,dmic-sample-rate:DMIC clock property (patch dmic-clock)"; do
    pat="${s%%:*}"; desc="${s#*:}"
    grep -qa "$pat" "$DTB" && check 1 "$desc" || check 0 "$desc"
done

echo
echo "== DMIC rate actually 2.4 MHz? =="
if command -v dtc >/dev/null 2>&1; then
    rate=$(dtc -I dtb -O dts "$DTB" 2>/dev/null | grep -A0 'dmic-sample-rate' | head -1 | tr -d ' \t;' )
    echo "     $rate"
    case "$rate" in
        *0x249f00*|*2400000*) check 1 "2.4 MHz (patched)" ;;
        *0x493e00*|*4800000*) check 0 "still 4.8 MHz - dmic patch did not take effect" ;;
        *) echo "     (could not determine)" ;;
    esac
fi

echo
[ "$fail" -eq 0 ] && echo "All checks passed." || echo "Some checks FAILED - do not remaster yet."
exit $fail
