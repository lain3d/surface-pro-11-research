#!/bin/bash
# Front camera (Sony IMX681) bring-up test. Run this ON the Surface, booted.
#
#   sudo bash tools/sp11-camera-test.sh            # diagnose only
#   sudo bash tools/sp11-camera-test.sh --capture  # also try to grab a frame
#
# Needs BOOTAA64-integ43-camera.efi, which is integ40 with a device tree that
# enables camss and csiphy2 and links the sensor's endpoint to camss port@2.
# On integ40 and earlier every check below fails by design: CONFIG_VIDEO_IMX681
# was not set, so the driver did not exist, and camss was disabled, so nothing
# could have bound anyway.
#
# WHAT A PASS DOES AND DOES NOT PROVE
#
# An i2c client is DECLARED by the DT node, not discovered -- i2c has no
# enumeration, so the device is created whether or not anything is physically
# there. Probe would therefore succeed on a board with the sensor unsoldered.
#
# What a successful probe proves: the DT is well formed, the driver matched, the
# MCLK resolved and reads back 19.2 MHz, both rails came up, the reset GPIO
# toggled, and -- the thing integ43 fixed -- camss's port@2 endpoint linked to
# the sensor's, because otherwise v4l2_async_register_subdev_sensor() fails.
#
# What it does not prove: that any silicon is at 0x10, or what it is. Step 4
# below is where that is settled: the driver's bus scan (on by default) says
# something ACKs, and the ID read says what it claims to be.
set -u

say() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
CAPTURE=0
[ "${1:-}" = "--capture" ] && CAPTURE=1

say "1. is this the camera kernel?"
uname -r
if grep -q 'sony,imx681' /sys/firmware/devicetree/base/soc@0/*/*/camera@10/compatible 2>/dev/null ||
   find /sys/firmware/devicetree/base -name 'camera@10' -print -quit 2>/dev/null | grep -q .; then
    echo "  camera@10 present in the live device tree"
else
    echo "  NO camera@10 in the device tree -- wrong UKI, expected integ43"
fi
for n in $(find /sys/firmware/devicetree/base -maxdepth 3 \
           \( -name 'isp@acb6000' -o -name 'csiphy@ace8000' \) 2>/dev/null); do
    printf '  %-40s status=%s\n' "${n#/sys/firmware/devicetree/base/}" \
           "$(tr -d '\0' < "$n/status" 2>/dev/null || echo '(none=okay)')"
done

say "2. modules"
for m in imx681 qcom_camss phy_qcom_mipi_csi2 videodev; do
    printf '  %-22s %s\n' "$m" "$(lsmod | awk -v m="$m" '$1==m {print "loaded"} ' | head -1 || true)"
done
# imx681 should autoload from its OF alias; if it did not, say why.
if ! lsmod | grep -q '^imx681'; then
    echo "  imx681 not loaded -- trying modprobe"
    modprobe imx681 2>&1 | sed 's/^/    /'
fi

say "3. did the sensor bind?"
if [ -d /sys/bus/i2c/drivers/imx681 ]; then
    ls -l /sys/bus/i2c/drivers/imx681/ | grep -E '^l' | awk '{print "  bound:", $9}'
    [ -n "$(ls -A /sys/bus/i2c/drivers/imx681 2>/dev/null | grep -- '-')" ] || \
        echo "  driver registered but NOTHING BOUND"
else
    echo "  /sys/bus/i2c/drivers/imx681 does not exist -- driver not loaded"
fi

say "4. IS ANYTHING THERE, AND WHAT IS IT?"
# This is the only evidence in the whole script that concerns the silicon
# rather than the kernel's own bookkeeping. Both lines come from probe.
echo "--- bus scan (which addresses ACK) ---"
dmesg | grep -E 'imx681.*(DEBUG|responder)' | sed 's/^/  /' \
    || echo "  no scan output -- was the sensor powered? is addr_scan=1?"
echo "--- chip ID (what the device says it is) ---"
if dmesg | grep -q 'imx681.*ID:'; then
    dmesg | grep 'imx681.*ID:' | sed 's/^/  /'
    echo
    echo "  0x0681 in either register identifies the part and settles this."
    echo "  A read failure means nothing answered at 0x10 -- which the scan"
    echo "  above will corroborate or contradict."
    echo "  Some other value means 0x10 is a real device that is NOT an IMX681."
else
    echo "  no ID lines -- imx681.ko predates the chip-ID read; reinstall it"
fi

say "4b. full kernel log"
dmesg | grep -iE 'imx681|camss|csiphy|csid|vfe|cci' | tail -40

say "5. media graph"
if command -v media-ctl >/dev/null; then
    for d in /dev/media*; do
        [ -e "$d" ] || continue
        echo "--- $d"
        media-ctl -d "$d" -p 2>&1 | sed 's/^/  /'
    done
    [ -e /dev/media0 ] || echo "  no /dev/media* -- camss did not register"
else
    echo "  media-ctl missing: apt-get install -y v4l-utils"
fi

say "6. v4l2 devices"
command -v v4l2-ctl >/dev/null && v4l2-ctl --list-devices 2>&1 | sed 's/^/  /' \
    || echo "  v4l2-ctl missing: apt-get install -y v4l-utils"

say "7. sensor controls"
# media-ctl -e resolves an entity name straight to its subdev node. The old scan
# -- v4l2-ctl --all | grep -i imx681 -- picked msm_csiphy2, because --all prints
# the names of LINKED entities too, so "imx681 1-0010" appears in the csiphy's
# output and the first match won. It reported /dev/v4l-subdev0 and then listed
# no controls at all, which read as "the sensor exposes none".
SUBDEV=$(media-ctl -d "${MED:-/dev/media0}" -e "imx681 1-0010" 2>/dev/null)
[ -c "${SUBDEV:-}" ] || SUBDEV=
if [ -n "${SUBDEV:-}" ]; then
    echo "  sensor subdev: $SUBDEV"
    v4l2-ctl -d "$SUBDEV" --list-ctrls 2>&1 | sed 's/^/  /'
else
    echo "  no subdev identifies as imx681"
fi

if [ "$CAPTURE" = 0 ]; then
    printf '\nRe-run with --capture to attempt a frame.\n'
    exit 0
fi

say "8. capture"
#
# WHY THE FIRST ATTEMPT FAILED (2026-08-06):
#
#   The pixelformat 'RG10' is invalid
#   VIDIOC_STREAMON returned -1 (Broken pipe)
#   kernel: qcom-camss acb6000.isp: Failed to start media pipeline: -32
#
# Both from one cause. camss validates that formats match across every link,
# and the whole graph sits at its default UYVY8_1X16/1920x1080 while the sensor
# source pad is SRGGB10_1X10/4032x3024. -32 is -EPIPE, which is what that
# mismatch produces. RG10 was rejected for the same reason: camss enumerates a
# video node's pixelformats from the CONNECTED PAD's current mbus code, so with
# the pad on UYVY only YUV formats are offered.
#
# So the format has to be walked along the pipe BEFORE touching the video node.
# Order matters, and this is the part v4l2-ctl alone cannot do.
MODE=${MODE:-4032x3024}
W=${MODE%x*}; H=${MODE#*x}
SENSOR="imx681 1-0010"
MED=/dev/media0
FMT=SRGGB10_1X10

# 4032x3024 is the driver's mode 0, which uses link_freq index 0 = 998.4 MHz.
# The smaller modes use index 1 = 1.2 GHz, i.e. a FASTER link -- so the largest
# mode is the gentler one for a single D-PHY lane. Override with MODE=3520x2640.
echo "  mode ${W}x${H} (MODE=WxH to change)"

if ! [ -e "$MED" ]; then
    echo "  no $MED -- camss did not register; nothing to capture from"; exit 1
fi

echo "--- propagating $FMT/${W}x${H} along the pipeline ---"
for PAD in "\"$SENSOR\":0" \
           '"msm_csiphy2":0'   '"msm_csiphy2":1' \
           '"msm_csid0":0'     '"msm_csid0":1' \
           '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
    out=$(eval media-ctl -d "$MED" -V "'$PAD [fmt:$FMT/${W}x${H}]'" 2>&1)
    printf '  %-24s %s\n' "$PAD" "${out:-ok}"
done

echo "--- what the sensor pad actually settled on ---"
media-ctl -d "$MED" -p 2>/dev/null | grep -A2 "entity.*imx681" | sed 's/^/  /'

VID=$(v4l2-ctl --list-devices 2>/dev/null | awk '/camss|isp/{f=1;next} f&&/dev\/video/{print $1; exit}')
VID=${VID:-/dev/video0}

echo "--- formats $VID offers NOW (should include a Bayer one) ---"
v4l2-ctl -d "$VID" --list-formats 2>&1 | sed 's/^/  /'

# Prefer unpacked RG10 so sp11-bayer.py can read it directly; fall back to
# whatever Bayer format the driver actually lists rather than guessing again.
PIX=$(v4l2-ctl -d "$VID" --list-formats 2>/dev/null | grep -oE "'[A-Za-z0-9]{4}'" | tr -d "'" | grep -E '^(RG10|pRAA|RG10P|BA10|GB10|BG10)$' | head -1)
PIX=${PIX:-RG10}
echo "  using $VID pixelformat=$PIX"

OUT=/tmp/imx681-frame.raw
rm -f "$OUT"
v4l2-ctl -d "$VID" --set-fmt-video=width=$W,height=$H,pixelformat=$PIX 2>&1 | sed 's/^/  /'

# ALWAYS bounded. v4l2-ctl blocks in DQBUF forever when STREAMON succeeds but no
# frame ever arrives -- which is exactly the interesting failure here, and on
# 2026-08-06 it hung this script with no output at all. A diagnostic that can
# hang is worse than one that reports nothing.
echo "--- capturing (${TIMEOUT:-20}s limit) ---"
timeout -s INT "${TIMEOUT:-20}"     v4l2-ctl -d "$VID" --stream-mmap --stream-count=1 --stream-to="$OUT" 2>&1 | sed 's/^/  /'
rc=${PIPESTATUS[0]}
[ "$rc" = 124 ] && echo "  TIMED OUT: STREAMON was accepted but no frame arrived."

if [ -s "$OUT" ]; then
    ls -la "$OUT"
    echo "  expected for 10-bit unpacked: $((W*H*2)) bytes"
    echo
    echo "  Now settle the Bayer order. Shoot something STRONGLY COLOURED"
    echo "  (a red object on a neutral background) -- a grey scene cannot"
    echo "  distinguish a red/blue swap. Then:"
    echo "    ./tools/sp11-bayer.py $OUT $W $H"
else
    echo
    # The driver prints STATE[after-mode]: and STATE[streaming]:, never "STATE:".
    # The old pattern "imx681.*STATE:" matched nothing, so this section printed
    # blank and the whole state dump -- the reason the dump was added -- was
    # invisible. tail -12 was also short: the streaming block is 18 lines.
    echo "--- what the sensor says its state is (STATE[...] lines, from set_stream) ---"
    dmesg 2>/dev/null | grep "imx681.*STATE\[streaming\]" | tail -20 | sed 's/^/  /'
    echo "  Reading the dump (measured 2026-08-06, mission 3):"
    echo "    frame_length LIVE (0x033e) = 3554 is CORRECT -- that is the mode"
    echo "    table's value surviving the control handler. The 'dead' rows are"
    echo "    the SMIA addresses this part does not implement as writables;"
    echo "    0x0340 reading 0 is expected and means nothing is wrong."
    echo "    0x0202 is NOT dead despite the label: it reads ~8 below 0x022a"
    echo "    while no recovered table writes it, so it mirrors the live"
    echo "    exposure rather than being unimplemented."
    echo "  A fully correct dump with vfe0 at 0 is the standing result: the"
    echo "  sensor is programmed as the vendor programs it and still emits"
    echo "  nothing. See TO-WINDOWS.md."
    echo
    # Separates "the sensor emits nothing" from "camss drops what arrives".
    # Needs no debug build: if these never tick, nothing reached the receiver.
    echo "--- did the receiver see anything? (irq counts) ---"
    grep -iE 'msm_vfe0|msm_csid0' /proc/interrupts | sed 's/^/  /'
    echo "  vfe0 staying at 0 means no start-of-frame ever arrived."
    echo
    echo "  no frame captured. Check dmesg for 'Failed to start media pipeline'"
    echo "  and compare the pad formats printed above -- every pad in the chain"
    echo "  must carry the same code and size or camss returns -EPIPE."
    dmesg 2>/dev/null | grep -i "camss\|csid\|csiphy\|vfe" | tail -10 | sed 's/^/  /'
fi
