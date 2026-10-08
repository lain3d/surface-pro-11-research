#!/bin/bash
# Front camera privacy LED: what actually drives it?
#
# RUN THIS YOURSELF so you can see the prompts while watching the LED:
#
#     ! sudo bash tools/sp11-led-probe.sh
#
# (in Claude Code, the leading "!" runs it in your session so the live output
# lands in front of you. An agent running this in a tool call cannot show you
# the prompts in real time, and cannot see the LED either -- which is exactly
# the trap that made the first attempt at this useless.)
#
# WHY A 2x2 AND NOT A NARRATIVE
#
# gpio225 was found in ACPI CAMP (_SUB "MSHW0495"), which declares exactly two
# camera GPIOs: 225 and 105. 105 is a cci_i2c pin owned by ac16000.cci, so 225
# is the only camera GPIO nothing in our DT drives. Asserting it once appeared
# to light the LED, but the LED then went out while the line was still held --
# so "225 drives the LED" does not survive contact with the evidence.
#
# There are two candidate inputs, gpio225 and camera power/streaming, so there
# are four states and guessing from a narrative is how the last hour went. Test
# all four, one variable at a time, and let the truth table say it.
set -u

CHIP=gpiochip9; PIN=225
MED=/dev/media0; VID=/dev/video0
SENSOR="imx681 1-0010"; FMT=SRGGB10_1X10; W=4032; H=3024
OUT=/tmp/sp11-led-result.txt
GPID=""; SPID=""

[ "$(id -u)" = 0 ] || { echo "needs root: sudo bash $0"; exit 1; }
for t in gpioset gpioget media-ctl v4l2-ctl; do
    command -v $t >/dev/null || { echo "missing $t"; exit 1; }
done

cleanup() {
    [ -n "$SPID" ] && kill $SPID 2>/dev/null
    [ -n "$GPID" ] && kill $GPID 2>/dev/null
    sleep 1
    gpioset -c $CHIP -t0 $PIN=0 >/dev/null 2>&1   # restore the pin low
    pkill -f "gpioset -c $CHIP" 2>/dev/null
}
trap 'echo; echo "interrupted -- restoring"; cleanup; exit 130' INT TERM

gpio_high() { cleanup_gpio; gpioset -c $CHIP -C sp11-led-probe $PIN=1 >/dev/null 2>&1 & GPID=$!; sleep 1; }
gpio_low()  { cleanup_gpio; gpioset -c $CHIP -t0 $PIN=0 >/dev/null 2>&1; sleep 1; }
cleanup_gpio() { [ -n "$GPID" ] && { kill $GPID 2>/dev/null; wait $GPID 2>/dev/null; GPID=""; }; }

stream_start() {
    for PAD in "\"$SENSOR\":0" '"msm_csiphy2":0' '"msm_csiphy2":1' \
               '"msm_csid0":0' '"msm_csid0":1' '"msm_vfe0_rdi0":0' '"msm_vfe0_rdi0":1'; do
        eval media-ctl -d $MED -V "'$PAD [fmt:$FMT/${W}x${H}]'" >/dev/null 2>&1
    done
    v4l2-ctl -d $VID --set-fmt-video=width=$W,height=$H,pixelformat=pRAA >/dev/null 2>&1
    timeout -s INT 600 v4l2-ctl -d $VID --stream-mmap --stream-count=1 \
            --stream-to=/tmp/led-probe.raw >/dev/null 2>&1 &
    SPID=$!
    sleep 5    # let set_stream run: rails, MCLK, reset, register tables, 0x0100=1
}
stream_stop() { [ -n "$SPID" ] && { kill $SPID 2>/dev/null; wait $SPID 2>/dev/null; SPID=""; }; sleep 2; }

ask() {  # ask() "<state description>" -> sets REPLY_YN
    local desc="$1" ans
    echo
    echo "  ------------------------------------------------------------"
    echo "   NOW:  $desc"
    echo "   gpio225 reads: $(gpioget -c $CHIP --as-is $PIN 2>&1 | tr -d '\n')"
    echo "  ------------------------------------------------------------"
    while :; do
        read -r -p "   Is the front camera LED LIT right now? [y/n] " ans
        case "${ans,,}" in y|yes) REPLY_YN=LIT; return;; n|no) REPLY_YN=dark; return;; esac
        echo "   please answer y or n"
    done
}

echo "=============================================================="
echo " front camera privacy LED -- 2x2 probe"
echo " Look at the camera. Four states, one question each."
echo "=============================================================="

gpio_low;  stream_stop; ask "gpio225 LOW,  camera IDLE      (baseline)";      R00=$REPLY_YN
gpio_high;              ask "gpio225 HIGH, camera IDLE";                      R10=$REPLY_YN
gpio_low;  stream_start; ask "gpio225 LOW,  camera STREAMING";                R01=$REPLY_YN
gpio_high;              ask "gpio225 HIGH, camera STREAMING";                 R11=$REPLY_YN
stream_stop
gpio_low
ask "gpio225 LOW, camera IDLE again (does it return to baseline?)";           R00b=$REPLY_YN

cleanup
{
  echo "sp11 front camera privacy LED -- 2x2 result   $(date '+%F %T')"
  echo
  printf '  %-14s %-12s %s\n' "gpio225" "camera" "LED"
  printf '  %-14s %-12s %s\n' "low"  "idle"      "$R00"
  printf '  %-14s %-12s %s\n' "HIGH" "idle"      "$R10"
  printf '  %-14s %-12s %s\n' "low"  "streaming" "$R01"
  printf '  %-14s %-12s %s\n' "HIGH" "streaming" "$R11"
  printf '  %-14s %-12s %s\n' "low"  "idle again" "$R00b"
  echo
  if [ "$R00" = dark ] && [ "$R10" = LIT ] && [ "$R11" = LIT ]; then
      echo "  => gpio225 drives the LED (independent of streaming)."
  elif [ "$R00" = dark ] && [ "$R10" = dark ] && [ "$R01" = LIT ]; then
      echo "  => streaming drives the LED, not gpio225."
  elif [ "$R10" = LIT ] && [ "$R11" = dark ]; then
      echo "  => gpio225 lights it, but the camera power-on sequence puts it OUT."
      echo "     That is the interesting case: something in power_on re-muxes or"
      echo "     overrides the pin. Check the cam_aon pinctrl group and whether"
      echo "     the sensor's power_on touches pin 225's mux."
  elif [ "$R00" = LIT ] || [ "$R00b" = LIT ]; then
      echo "  => LIT with 225 low and the camera down: neither input we control"
      echo "     drives it. Suspect the EC/firmware, and note it may latch."
  else
      echo "  => no clean single-input explanation; see the table."
  fi
} | tee $OUT

echo
echo "Result saved to $OUT -- paste it back, or just say 'done' and I will read it."
