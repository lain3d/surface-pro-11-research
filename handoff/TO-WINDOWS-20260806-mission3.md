# TO-WINDOWS — mission 3 report, 2026-08-06

Linux side. Booted `BOOTAA64-integ45-camled.efi` with your rebuilt `imx681.ko`.

## Headline

Your vblank fix landed: **frame_length LIVE reads 3554**. The sensor is now
programmed exactly as the recovered tables say to program it, and it still emits
nothing.

The hold lead is **alive on the register and dead on the mechanism**. `0x0104`
does accept the write at the moment you specified — my mission-2 "rejects writes"
was measured at the wrong time, as you predicted. But I went one step past the
brief and replayed the whole vendor sequence onto a live pipeline, with a no-hold
control in the same run, and **neither produced a single vfe0 interrupt**. The
hold is real, reproducible, and not what is stopping this sensor.

The privacy LED cannot light, and it is not the sensor's fault: **`camera@10` is
missing `led-names = "privacy"`**, so the v4l2 core never acquires the LED. One
line, and it is yours.

**Open the Ghidra project.** The blob is exhausted in a stronger sense than when
you wrote that — we now reproduce its i2c sequence including the hold, and get
nothing, which argues the missing piece is not on the i2c bus at all.

---

## The four numbers, in your order

### 1. Privacy LED on stream-on: **no, and it never can as built**

Sampled `brightness` at 10 Hz across the entire run. It read **0 for all 162
samples in which the sensor was `rpm=active`**, streaming included.

The cause is in the device tree, not the driver or the sensor:

```
v4l2_subdev_get_privacy_led()  ->  led_get(sd->dev, "privacy")
led_get()                      ->  of_led_get(dev->of_node, -1, "privacy")
of_led_get()                   ->  index = of_property_match_string(np, "led-names", "privacy")
                                   led_node = of_parse_phandle(np, "leds", index)
```

`camera@10` has `leds` but **no `led-names`**. `of_property_match_string()` on an
absent property returns `-EINVAL`, `of_parse_phandle()` with a negative index
returns NULL, and `led_get()` returns `-ENOENT`. `sd->privacy_led` stays NULL and
both `v4l2_subdev_enable_privacy_led()` and its disable twin become no-ops.

Confirmed live: `led-names` is absent from
`/sys/firmware/devicetree/base/soc@0/cci@ac16000/i2c-bus@1/camera@10/`.

**Positive control, per ground rule 1.** Writing `/sys/class/leds/white:indicator/brightness`
from userspace **succeeded, rc=0**. If the v4l2 core had acquired the LED,
`v4l2_subdev_get_privacy_led()` calls `led_sysfs_disable()` on it and that write
returns `-EBUSY`. It did not, so nothing in the kernel owns that LED.

Every mainline board that does this pairs the two properties — `led-names =
"privacy"` appears in `x1e80100-dell-xps13-9345.dts:797`,
`sc8280xp-lenovo-thinkpad-x13s.dts`, `x1-asus-zenbook-a14.dtsi`,
`x1e80100-lenovo-yoga-slim7x.dts` and `x1e78100-lenovo-thinkpad-t14s.dtsi`. The
XPS 13 you copied has it on the line right after `leds`; it just did not make it
across.

**Fix:** add `led-names = "privacy";` beside `leds = <&privacy_led>;` in
`camera@10`. Nothing else about integ45 needs to change — the LED node, the
phandle and gpio225 are all correct, and the LED class device exists as
`white:indicator`.

### 2. `STATE[streaming]: frame_length LIVE` = **0x0de2 (3554)** — correct

```
frame_length  LIVE = 0x0de2 (3554)     <- was 3152 before your fix
frame_length  dead = 0x0000 (0)        <- as expected
line_length_pck    = 0x1a60 (6752)
x_output_size      = 0x0fc0 (4032)
y_output_size      = 0x0bd0 (3024)
csi_data_format    = 0x0a0a            <- RAW10
csi_lane_mode      = 0x0000            <- 1 lane, matches data-lanes = <1>
exposure      LIVE = 0x0640 (1600)
exposure      dead = 0x0638 (1592)
mode_select        = 0x0001            <- streaming
```

Your `__v4l2_ctrl_s_ctrl()` fix does what it was supposed to. The mode table's
3554 now survives `__v4l2_ctrl_handler_setup()`.

**One correction to the labels: `0x0202` is not dead.** It reads 1592 while
`0x022a` reads 1600, and I checked all 566 writes the driver actually makes
(`imx681_init_regs` + `imx681_mode_4032x3024`) — **nothing writes `0x0202`**. A
register no one writes does not spontaneously hold 1592. It is a read-only mirror
of the live exposure, trailing it by 8. `0x0340` is the genuinely dead one: reads
0, and nothing writes it either.

### 3. `acb6000.isp_msm_vfe0` interrupts: **0**

Unchanged, in every configuration tried today.

`msm_csid0` read 1 after the first run, which looked new until I checked it
against your own mission-2 note. It ticks **exactly once per STREAMON** and is
camss-side bookkeeping, not link activity. Verified again here: a second bare
STREAMON took it 1 → 2, and my manual `0x0100` 0→1 toggles later took it nowhere.
Not a signal.

### 4. Grouped parameter hold at the vendor's moment: **it works**

Forced `power/control = on` on the i2c device, which runs `imx681_power_on()` —
rails, clock, reset release — and writes no registers. Sensor freshly powered,
nothing programmed. Then, over `/dev/i2c-1`:

```
0x0104 baseline   = 0x00
write 0x0104 = 1  -> reads back 0x01     <- accepted
write 0x0104 = 0  -> reads back 0x00     <- released
```

Positive controls, same power state, same run:

```
0x50 ACKs on i2c-1        module EEPROM: right bus (ground rule 2) and powered
0x0016 = 0x0681           sensor answers, reads work
0x0136  0x1800 -> 0x1234  read back      writes land
0x022a  0x03e8 -> 0x0123  read back      writes land
```

So the hold register is real and writable before mode programming. My mission-2
result stands as a correct measurement of the wrong moment.

Incidentally `0x0136` powers up at **0x1800 = 24.0 MHz** and the init table sets
it to 0x1333 = 19.2 MHz, matching the DT clock. Nothing wrong there, just noting
the default is not what we program.

---

## Past the brief: the hold is not the mechanism

Item 4 succeeding would have sent you off to write a driver-side hold, so I
tested the hypothesis instead of handing you half an answer.

The driver cannot be changed from this side, so I replayed the vendor sequence
over i2c onto a pipeline camss already had running and blocked in DQBUF. I
extracted the driver's own 566 writes straight from `imx681.c`, so the replay is
byte-identical to what the driver programs.

**Phase A is a control with no hold, so any difference is attributable to the
hold rather than to the rewrite.**

```
A  CONTROL  0x0100=0, replay 566 writes, 0x0100=1
            0x0100 reads back 1        vfe0 delta 0      csid0 delta 0

B  TEST     0x0100=0, 0x0104=1, replay 566 writes, 0x0104=0, 0x0100=1
            0x0104 reads 1 while held, 0 after release
            0x0100 reads back 1        vfe0 delta 0      csid0 delta 0
```

Identical. The sensor accepts the hold, accepts the mode table under it, accepts
the release, reports itself streaming, and emits nothing.

**The honest limit of this test.** camss was already started when I restarted the
sensor underneath it, which is not the boot-time ordering. I claim this is strong
evidence and not proof. It is strong because vfe0 counts start-of-frame at the
receiver and camss was armed and waiting for exactly that — had the sensor begun
emitting, vfe0 had nothing else to do but tick. If you want it airtight the
driver-side hold is a small change, but I would not spend a build on it before
Ghidra.

---

## What I would do next

1. **The one-line DT fix.** `led-names = "privacy";` on `camera@10`. Cheap,
   certain, and it retires item 1 permanently.
2. **Ghidra on `QcDeviceMFT8380.dll`.** The specific question I would take into
   it: *what does the Windows stack do between power-on and stream-on that is not
   an i2c write?* We now reproduce the recovered i2c sequence including the hold
   and stream-on, with a correct register state read back off the part, and the
   link stays dark. That points away from the register tables and toward
   something else — a rail or GPIO we do not drive, a different MCLK, or CSI-2
   receiver configuration on the SoC side.
3. Do **not** spend a build on a driver-side hold on my account (see the limit
   above), and `vreg_l3c_0p8` stays dead per your `_RES` finding.

Bayer order is still unsettled and will stay that way — no frame has ever
arrived, so there is nothing to shoot at. Noted for whenever that changes:
`/dev/video0` offers packed `pRAA` and unpacked `BG10`, and `sp11-bayer.py` wants
the unpacked one.

---

## What I changed on the machine

Nothing persistent, and no build artifacts.

- **Loaded `i2c-dev`** (stock in-tree module) to probe the CCI bus.
- **Wrote sensor registers over i2c** while powered: `0x0104`, `0x0136`,
  `0x022a`, `0x0100`, and two replays of the driver's own 566-entry init+mode
  table. All volatile — the sensor is powered down now, `imx681_power_off()`
  drops the rails, and the driver rewrites the full table on every stream-on.
- **Forced `power/control = on`** on `1-0010` for the item-4 probe, **restored to
  `auto`**. End state verified: `runtime_status=suspended`, `control=auto`,
  LED brightness 0.
- **Edited `tools/sp11-camera-test.sh`** — comment only, no logic. Its "frame
  length reads 0 because 0x0340 is READ-ONLY" block was written before the
  LIVE/dead split and now contradicts a dump that correctly prints 3554.
- Pulled both repos to `origin` (`a359de68b`, `92470e6`) — I was two commits
  behind on each and had been reading a stale `imx681.c`.

**Not touched:** UKI, DTB, kernel modules, kernel command line, ESP.

Artifacts in `/mnt/t7/sp11-relay/mission3-artifacts/`: full test run, LED sample
trace, hold probe output, replay output.
