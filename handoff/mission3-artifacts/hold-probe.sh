#!/bin/bash
# Item 4: grouped parameter hold (0x0104) at the vendor's moment --
# sensor freshly powered, BEFORE any mode programming.
# Ground rule 1: every failed write gets a positive control in the same run.
set -u
BUS=1; ADDR=0x10
DEV=/sys/bus/i2c/devices/1-0010

rd8()  { i2ctransfer -f -y $BUS w2@$ADDR $(printf '0x%02x 0x%02x' $((($1>>8)&0xff)) $(($1&0xff))) r1 2>&1; }
rd16() { i2ctransfer -f -y $BUS w2@$ADDR $(printf '0x%02x 0x%02x' $((($1>>8)&0xff)) $(($1&0xff))) r2 2>&1; }
wr8()  { i2ctransfer -f -y $BUS w3@$ADDR $(printf '0x%02x 0x%02x 0x%02x' $((($1>>8)&0xff)) $(($1&0xff)) $2) 2>&1; }
wr16() { i2ctransfer -f -y $BUS w4@$ADDR $(printf '0x%02x 0x%02x 0x%02x 0x%02x' $((($1>>8)&0xff)) $(($1&0xff)) $((($2>>8)&0xff)) $(($2&0xff))) 2>&1; }

echo "### power the sensor, program nothing"
echo on > $DEV/power/control
sleep 0.3
echo "runtime_status: $(cat $DEV/power/runtime_status)"
echo "privacy LED brightness while powered-not-streaming: $(cat /sys/class/leds/white:indicator/brightness)"

echo
echo "### bus + power positive control (ground rule 2: EEPROM at 0x50)"
if i2ctransfer -f -y $BUS w1@0x50 0x00 r1 >/dev/null 2>&1; then
    echo "  0x50 ACKs on i2c-$BUS -- this is the camera CCI bus and the module is powered"
else
    echo "  0x50 does NOT ACK -- sensor not powered, probe below is meaningless"
fi

echo
echo "### read positive control: sensor_model_id 0x0016 (expect 0x0681)"
echo "  0x0016 = $(rd16 0x0016)"

echo
echo "### the measurement: grouped parameter hold 0x0104"
echo "  0x0104 baseline          = $(rd8 0x0104)"
echo "  write 0x0104 = 1         : $(wr8 0x0104 0x01; echo rc=$?)"
echo "  0x0104 read back         = $(rd8 0x0104)"

echo
echo "### write positive control, SAME power state, SAME run"
ORIG136=$(rd16 0x0136); echo "  0x0136 extclk baseline   = $ORIG136"
wr16 0x0136 0x1234 >/dev/null; echo "  wrote 0x0136 = 0x1234"
echo "  0x0136 read back         = $(rd16 0x0136)"

ORIG22A=$(rd16 0x022a); echo "  0x022a exposure baseline = $ORIG22A"
wr16 0x022a 0x0123 >/dev/null; echo "  wrote 0x022a = 0x0123"
echo "  0x022a read back         = $(rd16 0x022a)"

echo
echo "### release the hold"
echo "  write 0x0104 = 0         : $(wr8 0x0104 0x00; echo rc=$?)"
echo "  0x0104 read back         = $(rd8 0x0104)"

echo
echo "### restore and drop power"
wr16 0x0136 $((0x1333)) >/dev/null 2>&1
echo auto > $DEV/power/control
sleep 0.3
echo "runtime_status: $(cat $DEV/power/runtime_status)"
