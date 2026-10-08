#!/bin/bash
# Collect everything worth having from a Surface Pro 11 Linux boot, in one pass.
#
# Run it early (before poking at anything) and again after each measurement. The
# output directory is self-contained -- copy it back to the host and it is the
# evidence for whatever happened.
#
#   sudo ./sp11-collect.sh [output-dir]
set -u
OUT="${1:-$HOME/sp11-state-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT" || exit 1
exec > >(tee "$OUT/collect.log") 2>&1

echo "=== sp11 state collection  $(date -Is) ==="
echo "output: $OUT"
[ "$(id -u)" -eq 0 ] || echo "WARNING: not root; several sections will be incomplete"

run() {  # run <file> <description> <command...>
    local f="$OUT/$1"; shift
    local d="$1"; shift
    echo "  $d"
    { echo "\$ $*"; echo; "$@"; } > "$f" 2>&1
}

echo
echo "--- identity and kernel ---"
run uname.txt        "uname"            uname -a
run cmdline.txt      "kernel cmdline"   cat /proc/cmdline
run os-release.txt   "os-release"       cat /etc/os-release
cp /boot/config-"$(uname -r)" "$OUT/kernel-config.txt" 2>/dev/null \
    || zcat /proc/config.gz > "$OUT/kernel-config.txt" 2>/dev/null \
    || echo "  (no kernel config available)"

echo
echo "--- the whole log ---"
run dmesg.txt        "dmesg"            dmesg
run dmesg-err.txt    "dmesg warnings+"  dmesg --level=err,warn

echo
echo "--- USB4 / thunderbolt ---"
run tb-dmesg.txt     "thunderbolt lines" sh -c 'dmesg | grep -iE "thunderbolt|usb4|nhi"'
run tb-devices.txt   "tb devices"       sh -c 'ls -la /sys/bus/thunderbolt/devices/ 2>&1; echo; for d in /sys/bus/thunderbolt/devices/*/; do echo "== $d"; for f in device_name vendor_name authorized generation; do [ -f "$d$f" ] && echo "   $f = $(cat "$d$f" 2>/dev/null)"; done; done'
run tb-drivers.txt   "tb driver bind"   sh -c 'ls -la /sys/bus/thunderbolt/drivers/*/ 2>&1'
run boltctl.txt      "boltctl"          sh -c 'boltctl list 2>&1 || echo "boltctl not installed"'
run lspci.txt        "lspci"            sh -c 'lspci -nnvv 2>&1 || echo "no lspci"'
run pci-devices.txt  "pci sysfs"        sh -c 'ls -la /sys/bus/pci/devices/'

echo
echo "--- camera ---"
run cam-dmesg.txt    "camera lines"     sh -c 'dmesg | grep -iE "imx681|ov13858|camss|cci|csiphy|camcc|DEBUG:"'
run i2c-buses.txt    "i2c buses"        sh -c 'ls -la /sys/bus/i2c/devices/ 2>&1; echo; i2cdetect -l 2>&1 || echo "i2c-tools not installed"'
run v4l.txt          "v4l2 devices"     sh -c 'ls -la /dev/video* /dev/v4l-subdev* 2>&1; echo; v4l2-ctl --list-devices 2>&1 || echo "v4l-utils not installed"'
run media.txt        "media topology"   sh -c 'for m in /dev/media*; do echo "== $m"; media-ctl -d "$m" -p 2>&1; done || echo "media-ctl not installed"'
run clocks.txt       "clock summary"    sh -c 'cat /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -200 || echo "debugfs not mounted"'
run regulators.txt   "regulators"       sh -c 'for r in /sys/class/regulator/*/; do n=$(cat "$r/name" 2>/dev/null); s=$(cat "$r/state" 2>/dev/null); v=$(cat "$r/microvolts" 2>/dev/null); echo "$n  $s  $v"; done | sort'

echo
echo "--- touchscreen / HID ---"
run hid-devices.txt  "hid devices"      sh -c 'ls -la /sys/class/hidraw/ 2>&1; echo; for d in /sys/class/hidraw/hidraw*; do echo "== $d"; cat "$d/device/uevent" 2>/dev/null; done'
echo "  hidraw report descriptors"
mkdir -p "$OUT/hidraw-descriptors"
for d in /sys/class/hidraw/hidraw*; do
    n=$(basename "$d")
    cp "$d/device/report_descriptor" "$OUT/hidraw-descriptors/$n.bin" 2>/dev/null
    xxd "$d/device/report_descriptor" > "$OUT/hidraw-descriptors/$n.hex" 2>/dev/null
done
run input-devices.txt "input devices"   cat /proc/bus/input/devices

echo
echo "--- platform ---"
run dt-model.txt     "device tree model" sh -c 'cat /proc/device-tree/model 2>/dev/null; echo; cat /proc/device-tree/compatible 2>/dev/null | tr "\0" "\n"'
run interrupts.txt   "interrupts"       cat /proc/interrupts
run iomem.txt        "iomem"            cat /proc/iomem
run modules.txt      "modules"          lsmod
run drivers-failed.txt "probe failures" sh -c 'dmesg | grep -iE "probe.*(fail|defer)|-517|EPROBE"'

echo
echo "=== done ==="
echo "collected into: $OUT"
du -sh "$OUT"
echo
echo "Copy this directory off the machine before rebooting -- a live session"
echo "keeps nothing."
