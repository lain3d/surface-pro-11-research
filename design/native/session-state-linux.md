# Session state — Linux side, IMX681 camera bring-up

Last updated 2026-08-09, end of mission 19.
Written so a cold session can pick this up without reading nineteen missions.

---

## 1. Where this stands

**The camera works, in the desktop, from a cold boot.** GNOME Snapshot opens,
previews and captures on the front camera with nothing set by hand. That was the
project's goal and it is met as of mission 18.

**All six sensor modes capture**, on the module defaults alone:

```
4032x3024   15,240,960     3840x2640   12,672,000
3840x2160   10,368,000     3660x2440   11,165,440   (stride padded 4575 -> 4576)
3520x2640   11,616,000
```

Getting there took three independent fixes, and each one hid the next:

1. **`0x2000 = 0x01`** in mode 0's table (mission 17), or the full-resolution
   mode emits a 504x382 RAW8 thumbnail instead of a frame. `0x2000` is an
   output-path selector — `0x02` restores the thumbnail on demand, confirmed
   both directions in mission 18.
2. **A libcamera `CameraSensorHelper` for imx681** (`patches/libcamera/`), or
   auto-exposure cannot map a gain code to a gain, settles at 1.02x and every
   preview is black.
3. **The two `3840x2160` mode entries reordered** so the working one is found
   first (mission 18, Windows side). libcamera picks the smallest sensor mode
   covering a request, so every ordinary app resolution landed on the broken
   duplicate.

### Exactly what is required

```bash
# any mode, nothing to set
sudo env TIMEOUT=15 MODE=4032x3024 /mnt/t7/surface/tools/sp11-camera-test.sh --capture
```

`csid_cphy` and `cphy_force` **default to 1**, and mission 16's §2a confirmed a
capture with nothing set. **`mode0_class` no longer exists** — its finding is in
the mode table as of mission 18. The parameters now are `mode0_e8xx` (bool),
`addr_scan` (bool) and `reg_patch` (see below).

**`imx681.reg_patch` is the instrument to reach for** before proposing a mission
to test one register:

```bash
echo "0x2000=0x02,0x0368=0x01" | sudo tee /sys/module/imx681/parameters/reg_patch
```

Comma-separated 8-bit `ADDR=VAL` writes applied after the mode table, just
before streaming, each one logged. A malformed entry fails the stream rather
than being skipped — deliberately, because a silently ignored patch and a patch
with no effect look identical in the output.

**`cphy_datarate_kbps` is unnecessary.** `link_freq_menu_items` already carries
one entry per mode — 998.4 MHz and 1.2 GHz, holding *half* the C-PHY symbol rate
by the D-PHY DDR convention — and the PHY driver's `*2` recovers 4,563,657 and
5,485,714 kbps. Mode 1's derived rate is 2.6 ppm from the value we used to set by
hand. If anyone ever changes `imx681.c` to report the true symbol rate, the `*2`
must go in the same commit.

**`MODE=` is still required.** The harness hardcodes
`MODE=${MODE:-4032x3024}` at line 140 and negotiates it through media-ctl
regardless of which mode the driver enumerates first. Omitting `MODE=` silently
tests the *broken* mode. Confirm which mode ran from the state dump's PLL —
mode 0 is `op_pre_pll_div 2 / op_pll_multiplier 208`, mode 1 is `3 / 375` — not
from the mode string.

**There is a hardware video codec as of mission 19**, and it is not camera work
but it lives next door — see §6d. `iris` binds on `integ47`, `/dev/video0` and
`/dev/video1` are its decoder and encoder, and **the camss nodes moved to
`/dev/video2..17`**. Nothing that follows the media graph noticed; anything that
hardcoded `video0` for the camera now points at a video decoder.

**Every mode has a minimum `LINE_LENGTH_PCK`, and it is exact** (§6d). Below it
the sensor streams, the CSID receives clean packets, and no frame ever
completes. That single register is the whole of what was wrong with the
`3840x2160_1` duplicate.

Modules currently installed are the mission-18 set: `imx681` srcversion
`952474493B21DA992D252B2`, `qcom-camss` `D13CE257B7EBB32ED398C37`,
`phy-qcom-mipi-csi2` `6872706400130DA2682B82C` (latter two unchanged since
mission 16). libcamera is a **locally rebuilt** 0.7.0 — see
`patches/libcamera/`.
Nothing is persistent: parameters reset on reload, and every devmem poke is
rewritten by `csid_reset()` / `csid_configure_stream()` on the next STREAMON.

---

## 2. The two corrections that matter most

Both invalidate reasoning that stood for many missions. Do not re-adopt them.

**`vfe0` is not a success metric.** It reads **0 on a successful capture**. On
this hardware `buf_done` is raised by `CSID_BUF_DONE_IRQ_STATUS` inside
`csid_isr()`, not by the VFE's IRQ line, which stays silent whether or not frames
flow. Fifteen missions treated `vfe0 == 0` as the definition of failure. Watch
`csid0` instead: **+1 = the reset interrupt only, nothing streamed; +4 = a frame
completed.**

**`REG_UPDATE_CMD` (`0x018`) is write-1-to-command and self-clearing.** It always
reads `0x00000000`. Reading it tells you nothing about whether a register update
was issued. The durable statement is the Windows agent's: *the CSID never reaches
a frame boundary in mode 0.*

---

## 3. Hardware facts worth not re-deriving

```
csid0        0x0acb7000 - 0x0acb8fff
csiphy       0x0ace8000 - 0x0ace9fff    ace8000.csiphy -- the ONLY csiphy
sensor       i2c 1-0010, EEPROM at 0x50 (adapter numbers are NOT stable)
```

**Never hardcode the sensor subdev number.** It moves on every module reload —
it was `/dev/v4l-subdev22`, and `modprobe -r imx681 && modprobe imx681` in
mission 18 made it 23. Discover it, and do not suppress the error if you get it
wrong (rule 22):

```bash
SD=$(media-ctl -p | grep -A3 'entity.*imx681' \
     | grep -oP 'device node name \K/dev/v4l-subdev\d+' | head -1)
```

**`0x0ace4000` is not mapped on this machine.** Vendor and Windows-side material
refers to `csiphy0` there; nothing claims it here and reading it resets the SoC.

**Six sensor modes exist and all six now capture** (§1). This section's old
claim that there were "two sensor modes and only two" was an artefact of only
two having been tested; the sizes below are still the two most-measured.
`4032x2640`, `3520x3024` and `3840x2880` are not modes and are rejected outright
— no state dump, no streaming.

| | mode 0 `4032x3024` | mode 1 `3520x2640` |
|---|---|---|
| works | no | **yes** |
| `op_pre_pll_div` / `op_pll_multiplier` | 2 / 208 | 3 / 375 |
| C-PHY data rate | 4,563,929 kbps | 5,485,491 kbps |
| `pll_multiplier` (vt) | 180 → 144 MHz | 225 → 180 MHz |
| register count in table | 203 | 67 |

The receiver is configured for 5,485,700 kbps, which matches mode 1 to within
0.004 % and is 20 % off mode 0. **Matching the rate does not fix mode 0** —
tested with `cphy_datarate_kbps=4563929`; settle moved `0x22` → `0x26` and it
still failed.

`op_sys_clk_div` was read back live as `0x0001`, so `imx681.c`'s header comment
calling that an unverified assumption is now settled.

---

## 4. Mode 0 — solved in mission 17

**One sensor register: `0x2000 = 0x01`.** With it, `4032x3024` captures
15,240,960 bytes and renders a sharp full-resolution photograph. Without it,
zero bytes. Established by a four-way single-bit bisect with a `class=0`
control, three reproductions, and frame content checked at gain 1023:

```
mode0_class   writes             bytes
0 (control)   nothing            0
1             0x2000 = 0x01      15,240,960     <- the register
2             0x6a83 = 0x03      0
4             0x7e9b = 0x02      0
8             0xdc3c = 0x01      0
```

On the working mode 0: `csid0 +4`, `vfe0 +0`, CRC 0, ECC 0, `0x09c` =
`0x00000017`, and `0x240` = `0x0BD4` = **3,028 = 3,024 lines + 4**, the same
decomposition mode 1 gives. `0x210` reads `0x00000000` throughout.

**`0x210` = 0 is the success signature, not a null result.** It is the
*unmapped* long-packet header register. A correctly routed packet never appears
there, so the DT and word count of a working stream cannot be read from it —
only the DT of whatever got dropped. Predicting `0x2B`/5040 in that register was
a category error; the 5040 shows up as the file's 5040 bytes per line instead.

**The `0xE801–0xE899` block is unnecessary.** With all 136 registers skipped
(`mode0_e8xx=0`) and `0x2000 = 0x01` the only thing written, mode 0 still
captures a full real frame. So the block is neither the cause of the old failure
nor required for the fix.

**`0x2000` is an output-path selector — settled in mission 18, both
directions.** `reg_patch="0x2000=0x02"` on `4032x3024` gives 0 bytes and puts
`0x002A01F8` back on the wire (DT `0x2A`, word count 504) in 87.7% of 400,000
samples: the 504x382 RAW8 thumbnail, reproducible on demand. So `0x01` selects
the 4032-column RAW10 readout and `0x02` the ÷8 thumbnail, and the recovered
mode tables were correct all along. The Windows side explains why it shipped
that way: Qualcomm's own sensor library has **no 4032x3024 descriptor** — five
resolution descriptors exist and that is not one of them — so Windows never
streams this table. Our 12 MP capture is a true full-array readout that Windows
does not do; its 12 MP stills are upscaled from a 3520x2640 read.

**Do not judge a mode-0 frame at `analogue_gain=0`.** It comes out flat at
15–16, pure pedestal, and reads exactly like a routed-but-empty stream. The
first mission-17 frame was nearly filed that way. Raise the gain to 1023 before
concluding anything about content — see rule 20.

### What it used to do, before the register was found

Kept because the wire measurements are still the evidence for the descriptor
question above. It streamed cleanly, but streamed the wrong thing.

```
382 packets per burst, every burst, ~10 runs across 3 boots
burst duration   1,662 - 1,675 us      inter-packet 4.37 us, uniform
burst period     333.5 ms -> 3.0 Hz    duty cycle 0.50%
CRC 0, ECC 0 across 136,756 packets
0x210 = 0x002A01F8 -> DT 0x2A (RAW8), VC 0, word count 504
```

504 bytes at RAW8 is 504 pixels, and **4032 / 504 = 8.0 exactly**; 382 lines is
378 + 4 where 3024 / 8 = 378. So mode 0 puts a **504 × 382 eight-bit image** on
the wire — a 1/8-scale thumbnail — once per frame period, and never the 12 MP
RAW10 frame. The sensor's own `x_output_size` (4032) and `csi_data_format`
(`0x0a0a`, RAW10) describe an image that is never transmitted.

**The `0xE801–0xE899` block is ruled out — it is frame timing.** Mission 16 ran
mode 0 with `imx681.mode0_e8xx=0`, all 136 registers skipped (confirmed by the
driver's unconditional log line). The wire is identical in geometry: DT `0x2A`,
word count 504, same 382-packet bursts. Only the rate changes:

```
with 0xE8xx     16,808 pkts / 14.88 s ->  2.96 bursts/s
without         57,300 pkts / 14.96 s -> 10.03 bursts/s
```

3 Hz and 10 Hz. So the block sets frame timing and nothing else worth bisecting.

**"Which leaves no candidate at all" — that was the wrong conclusion, and it is
worth knowing why it was wrong.** I compared the two recovered tables field by
field, found nothing that could produce a 504 × 382 RAW8 stream, and concluded
the table itself must be untrustworthy. The candidate was in the table the whole
time: `0x2000`. I missed it because I was looking for a register whose *name or
value* suggested scaling, and `0x2000 = 0x02` looks like nothing. The Windows
side found it by comparing all six modes at once and asking which addresses
split one-against-five — a question about the *shape* of the difference rather
than the meaning of any value. That is the technique to reach for next time a
field-by-field read comes up empty.

Side effects of removing the block, both undecoded at the time:
`CSI2_RX_IRQ_STATUS` gains bit 11 (`0x00400017` → `0x00400817`), and CSIPHY
interrupts go from +3 to +151 over 15 s. **Bit 11 followed the failure, not the
block** — on the working mode 0 (`class=1`) `0x09c` reads `0x00000017`, bit 11
clear, and without the `0x00400000` both modes carried in mission 16. It only
ever appeared on the broken 10 Hz thumbnail stream, so it needs no decode.

Ruled out with evidence, do not revisit:
- **Backpressure / FIFO overflow.** `RDIN_IRQ_STATUS` is zero across 1,089
  samples with the mask forced fully open (`0x3FFFFFFF`). Binning is off the
  table permanently; do not port the SP10 remedy.
- **Bandwidth.** Mode 0 is 732 Mbps payload vs mode 1's 697 — 5 % more, on a
  *slower* link. Not a bandwidth wall.
- **`win_reset`.** Bit-identical results with and without.
- **Marginal link / settle timing.** CRC is exactly 0, and packet counts
  reproduce to the digit (22,538 six times).

---

## 5. Findings that contradict the Surface Pro 10 thread

The SP10 IMX681 work (`linux-surface/linux-surface#2153`) is a different SoC
(Intel/IPU6) and two of its sensor findings do not transfer:

- **Analogue gain is NOT inverted here.** They report code 0 = 16×, code 960 =
  1×. Measured on this module, brightness *increases* with the code: mean 24.46 →
  31.30 → 67.96 for gain 0 → 512 → 1023.
- **Frame length being inert IS reproduced.** `vertical_blanking` accepts 4084
  and the sensor's LIVE `frame_length` stays 3554; note `frame_length dead =
  0x0000`. Frame timing cannot be changed from userspace until the driver writes
  FLL after `MODE_SELECT`.

---

## 6. Settled in mission 16

**The register set on the working mode.** `0x210` reads `0x00000000` for
12,214 of 12,214 samples at 110 kHz across the whole streaming window, while
`0x240` climbs to 2,644 (= 2,640 lines + 4) and a full frame lands.
`CSI2_RX_CAPTURE_CTRL` (`0x208`) is `0x00000000` in **both** modes, so the
difference is not configuration — mode 0's packets are genuinely unrouted and
mode 1's are genuinely routed. The DT mismatch is real and mode-0-specific.

**Do not write the DT patch anyway.** Mapping DT `0x2A` would successfully route
a 504 × 382 thumbnail. The mismatch is a symptom of the sensor sending the wrong
image, not the cause of mode 0 failing, and a patch that accepts RAW8 turns "no
frame" into something that looks like progress and is not.

> Mission 17 vindicated this. `0x2000 = 0x01` made the sensor send RAW10 at full
> width and the existing DT mapping routed it without modification. Had the
> patch gone in, mode 0 would have started delivering 504 × 382 thumbnails and
> the real defect would have been buried under an apparent success. Declining a
> change that makes a symptom disappear is worth the argument it costs.

**Bayer order is `SRGGB10`** — the driver's declaration is correct, and the SP10
thread's `SBGGR10` does not transfer. Measured as an A/B between two illuminants
at the same gain:

```
              R (phase 0)     G        B (phase 3)    B/R     |Gr-Gb|
blue light      105.06      134.09      130.35       1.241     1.21
warm light      159.61      170.05      146.16       0.916     0.08
```

**`0x0ace8358` reads `0x0C` while frames are flowing.** So non-zero there does
not mean receiver failure in our configuration and the mission-13/15 paradox
dissolves: `CSIPhyWaitforRx` tests something our path never satisfies. On the
working mode it walks `0x00 → 0x05 → 0x0C`; on mode 0 it flickers across
`0x00/0x03/0x05/0x0C/0x0D`, so it is not the stable `0x0C` earlier notes claimed.

**`CSI2_RX_CFG0` = `0x01300000`** in both modes: `PHY_TYPE_SEL = 1` (C-PHY
confirmed in the receiver), `PHY_NUM_SEL = 3`, `NUM_ACTIVE_LANES = 0`. The last
one looks wrong against the PHY's own `[3 lanes, ctrl5 02]` even though the
camera works. `CFG1` = `0x00000001`.

**`camera_orientation` reads `Front`.** This is the user-facing camera.

**The privacy LED works.** `/sys/class/leds/white:indicator` **is** the camera
LED — `/sys/devices/platform/camera-privacy-led`, DT `compatible = "gpio-leds"`,
TLMM GPIO 225. The sensor node carries `leds = <phandle>` and
`led-names = "privacy"`, so `v4l2_async_register_subdev_sensor()` claims it and
`call_s_stream()` drives it. Measured at 14.90 s asserted on a 15 s mode-0 run
and 44.88 s on a `TIMEOUT=45` run, **with the physical indicator visually
confirmed lit** on the latter. To see it, use a long `TIMEOUT` on mode 0; the
working mode is far too brief.

Two traps, both of which caught me:

- **A successful capture asserts it for ~104 ms** and looks to the eye like it
  never lights. Only the failing mode holds it visibly. Same root cause as
  rule 19 — do not judge the working mode by a fifteen-second habit.
- **`trigger` lists every trigger registered in the system, for every LED.** It
  is the menu, not the assignment. Reading battery entries there does not make it
  a battery LED. Follow `device` to the platform device instead. Writing
  `brightness` returns `EBUSY` because V4L2 called `led_sysfs_disable()` on
  claim — that is the LED working, not the LED missing.

## 6a. Settled in mission 17

**Mode 0 works — `0x2000 = 0x01`.** Full detail in §4.

**`NUM_ACTIVE_LANES = 0` is correct, not a bug.** The DT gives one-element
`data-lanes` lists, so `lane_cnt = 1` and `camss-csid-680.c:209` writes
`(lane_cnt - 1) << 0` = 0. The sensor agrees (`0x0114 = 0x00` in all six modes),
and Windows' own `Csi2PhaseNumOfLanes = 1` at 5,485,700 kbps is the same single
trio. Sensor, DT, CSID and Windows all agree. Closed.

**The `bus-type = <4>` DT work must not touch the lane count.** Three trios
would move us *away* from what Windows does. The change is narrow:
`bus-type = <4>`, drop `clock-lanes`, remove the probe-time D-PHY rejection in
`camss.c`. Lane count stays 1. (`clock-lanes = <7>` is a D-PHY-ism — C-PHY has
no clock lane — and is the same original sin as the halved `link-frequencies`.)

**`0x0ace8000` is confirmed twice by independent routes:** `/proc/iomem` here
and `csiphy2_ep` in the DT source.

## 6c. The desktop camera stack — what works and what is missing

Ubuntu's camera app shows a black window with the privacy LED lit. Two
independent causes, both measured through the real stack (libcamera 0.7.0 +
PipeWire 1.6.2 + gnome-snapshot 50.0).

**The stack itself is fine.** libcamera brings the camera up through its
`simple` pipeline handler — which has an explicit `qcom-camss` entry — and the
software ISP debayers `SRGGB10` to ABGR8888 over EGL. PipeWire exposes it as
`imx681 [libcamera]`. Nothing needs replacing.

**Cause 1: the default format is mode 0.** `/dev/video0` defaults to
4032x3024 `pRAA`, so an application is *handed* the broken mode rather than
happening to choose it. Measured end to end:

```
mode0_class=0  (driver as shipped)   0 frames in 60 s, streaming, LED lit
mode0_class=1                        89 frames, real images
```

So `0x2000 = 0x01` is not only about the full-resolution capture path — until
it is in the mode table, every camera application on this machine is black.
`/etc/modprobe.d/imx681-sp11.conf` now sets `mode0_class=1` at load time so this
survives a reboot; that file should be deleted once the register is in the
driver.

**Cause 2: libcamera had no `CameraSensorHelper` for `imx681`.** It ships 27
(imx219, imx477, imx708 …); ours was not among them, so `IPASoft` could not map
a gain code to a gain and its AE reasoned with the wrong model.

**Fixed — patched and installed.** `patches/libcamera/` holds the patch, the
measured justification for the constants, and the rebuild recipe.

```
                        exposure   gain code   actual   result
stock libcamera 0.7.0   3546 (max)     18       1.02x   black
patched                 2210         1014       102x    correctly exposed
```

The distro package was rebuilt rather than an upstream tree installed over it.
**The core library and the IPA package must be installed together** — libcamera
signs IPA modules per build, so a locally built module against the distro
library fails signature verification and falls back to an isolated IPA.

Three non-blocking gaps libcamera reports, worth fixing before trusting colour
or any cropped mode:

- The sensor subdev does not implement the selection ioctl, so
  `PixelArrayActiveAreas` and the crop rectangle are defaulted —
  *"The sensor kernel driver needs to be fixed"*. Harmless only because the
  defaults are currently correct; five of the six modes use a real crop.
- No entry in libcamera's `camera_sensor_properties` database, so readout
  delays and rotation are guessed.
- No `imx681.yaml` IPA tuning file — falls back to `uncalibrated.yaml`, so
  colour through the app is approximate for the same reason rule 21 exists.

**Cause 3, and the one still open: the `3840x2160` sensor mode is broken, and
it is the one libcamera picks for ordinary app resolutions.** All six modes,
one capture each through the harness:

```
MODE=4032x3024   15,240,960   OK   (with 0x2000 = 0x01)
MODE=3840x2640   12,672,000   OK
MODE=3660x2440   11,165,440   OK   (stride padded 4575 -> 4576; frame is complete)
MODE=3520x2640   11,616,000   OK
MODE=3840x2160            0   BROKEN, 4 runs of 4
```

Same signature mode 0 had: sensor streams, LED lights, no frame completes.
`mode0_class` does not help — it is gated on the mode having an `extra` block
and only mode 0 has one — and per the Windows table this mode carries the
*normal* class values, so it is a different fault from mode 0's.

The simple pipeline handler picks the smallest sensor mode covering the request:

```
request 640x480    -> Picked 3840x2160  -> 0 frames
request 3840x2160  -> Picked 4032x3024  -> frames OK
```

The second is not a typo — a 3840x2160 *output* needs a debayer border so it
does not fit a 3840x2160 *mode*, and libcamera steps up to 4032x3024. Anything
smaller fits, lands on the broken mode, and dies. Snapshot asks for 1920x1080.

This also explains why every test I ran passed: I never requested anything small
enough to select that mode. **Fixing or dropping `3840x2160` is what remains
between here and a working camera app** — the next mode up, `3660x2440`, works.

Note also that PipeWire lists sixteen raw `Qualcomm Camera Subsystem [v4l2]`
nodes beside the one libcamera device. An app that picks a raw node is black
regardless, because those hand out undebayered Bayer.

**Diagnosing this class of thing:** `pw-top -b -n 3` shows the negotiated format
and the frame rate per node. Both nodes `running` with `QUANT 0 / RATE 0` means
negotiation succeeded and no buffers are flowing — which points at the pipeline,
not the app. `LIBCAMERA_LOG_LEVELS='SimplePipeline:DEBUG'` then prints the
`Picked <sensor mode> for max processed stream size <request>` line that names
the mode actually selected.

## 6d. Settled in mission 19

### The minimum LINE_LENGTH_PCK, and why `3840x2160_1` was dead

`3840x2160_1` differed from `_2` in seven registers — two exposure-ish pairs,
`LINE_LENGTH_PCK`, and `0x0368`. Bisected by applying `_1`'s values to `_2`
through `reg_patch`:

```
all of _1's timing                       0 bytes
vertical only  (frame_length 3554 -> 2218)   CAPTURES
horizontal only (LLP 6752 -> 5408)           0 bytes    x3
```

**The vblank was innocent** — 58 lines of frame-end slack, 24x less than any
working mode, costs nothing. The line length is the whole fault, and `_1` is
repairable: with its short vblank kept and LLP raised to 5632 it captures, at
**1.92x the frame rate of `_2`** (2218 x 5632 clocks against 3554 x 6752).

The threshold is exact, reproducible, and set by **output width alone**:

```
mode          width   min LLP   native   ratio to width
4032x3024      4032      5376     6752   4/3      exact   (pll 180, op 2/208)
3840x2640      3840      5632     6752   22/15    exact
3840x2160      3840      5632     6752   22/15    exact
3660x2440      3660      5368     6752   22/15    exact
3520x2640      3520      5176     6752   1.47045  the outlier
```

`3840x2640` and `3840x2160` share a threshold to the count despite different
heights — that was a stated prediction, then tested. Mode 0 has its own ratio
and is the one mode with a different PLL, so the coefficient tracks the clock
configuration. **3520x2640 is unexplained**: 13.3 counts above `width x 22/15`,
and the only width whose 22/15 product is not an integer.

**Below the threshold nothing is wrong with the signalling.** Sampling a failing
capture: `0x210` 0 throughout, ECC 0, CRC 0, `0x240` climbing at ~78,700
packets/s for the full 15 s — over 1.2 M packets against the 2,285 a successful
capture takes. The sensor emits, the CSID receives cleanly, and no buffer
completes.

Two models fitted and falsified, recorded so they are not re-derived: linear in
width across the 22/15 group (predicted 5375.5 for 3660, actual 5368), and a
fixed line time scaling by mode 0's slower `vt_pix_clk` (predicted 4731, actual
5376; link-rate scaling predicted 5686). See rule 23.

### The hardware video codec

`iris` binds on `integ47` — DT node `status = "okay"` plus `firmware-name`
pointing at `qcvss8380.mbn`, which the Windows side recovered from the driver
store. No driver change was needed; the node had shipped `disabled` because the
blob is vendor-signed per board.

```
decode   H264 HEVC VP90 AV01          /dev/video0
encode   H264 HEVC                    /dev/video1
no VP8, either direction
```

**On success there is nothing in dmesg** — the only mention of the block in a
whole boot is `Adding to iommu group 12`. The binding is visible in sysfs, not
in the log, so silence is the pass condition and not the failure one.

- **No VA-API.** `msm_drv_video.so` does not exist, so browsers gain nothing.
  iris is a *stateful* m2m decoder and `libva-v4l2-request` targets stateless
  ones; there is no bridge in stock distros.
- **`ffmpeg -c:v h264_v4l2m2m` segfaults when encoding**, 8 runs of 8, having
  written a 48-byte MP4. Root-caused to ffmpeg, not the hardware:
  `v4l2_buffer_swframe_to_buf()` takes the plane height from the *driver's*
  format and the plane pointer from the *AVFrame*, and iris rounds 1920x1080 up
  to 1920x1088, so it reads 15,360 bytes past the end of the luma plane. Fix
  and evidence in `patches/ffmpeg/`; still unfixed in ffmpeg master. Its
  *decoder* is fine and GStreamer never touches that path.
  **The failure tracks the resolution, not the code path**, because an
  over-read only faults if the allocator left nothing after the plane — 640x488
  over-reads exactly as many bytes as 1920x1080 and survives. The obvious
  hypothesis, "heights not a multiple of 16", is wrong: 1280x720 crashes and
  640x488 does not. What matters is what the driver *returns*.
- **The encoder honours `V4L2_CID_MPEG_VIDEO_BITRATE` as bits per *frame*,**
  where V4L2 defines it as bits per second. Recomputed as bits per frame, the
  three runs are 2.001, 2.001 and 2.000 Mbit at 30, 15 and 60 fps — constant,
  and exactly the number asked for. The bits/second only moved because the same
  payload is divided by a duration that shrinks as the rate rises. Workaround:
  divide the request by FPS; asking 266,667 gave 8,006,250 bit/s at 30 fps.
  Driver-side bug; if it is ever fixed the correction in `sp11-record.sh` must
  come out in the same commit.
  **The frame rate is not in that path at all.** The driver always sends
  `HFI_PROP_FRAME_RATE` (`sm8550_venc_output_config_params`), from
  `inst->frame_rate`, which defaults to `DEFAULT_FPS` = 30 and is only updated
  by `S_PARM` on the CAPTURE queue — `S_PARM` on OUTPUT sets `operating_rate`
  instead (`iris_venc.c:410-438`). GStreamer never calls `S_PARM`, so the
  firmware heard 30 fps in all three runs; had it been dividing by that, all
  three would have matched in bits per *second* rather than per frame. My first
  write-up said the driver "knows the frame rate and scales by it anyway" — that
  was an over-reading of a factor that is pure arithmetic.
- **Pin profile and level in caps.** Unconstrained, GStreamer fixates to
  Baseline level 1 on a 1080p stream. ffmpeg decodes it; GStreamer's own caps
  intersection returns EMPTY, so `v4l2h264dec` will not play back what
  `v4l2h264enc` wrote. The driver's defaults are sane (level 5, High); this is
  GStreamer, not iris.
- `h264parse`, `h265parse` and `mp4mux` are not installed by default —
  `gstreamer1.0-plugins-bad`. Without them nothing can mux or parse the output.

## 6b. Open questions, in the order I would take them

1. **`0x218` reads `0x00000000`**, in both modes, 1,076 samples on mode 0.
   Mission 14 recorded `0x0000000A`. One of the two is wrong.
2. **Repair `3840x2160_1`** rather than delete it: `0x0342/0x0343` to
   `0x16/0x00`. Windows side. It turns a dead entry into the fastest mode on the
   part, and it needs a distinguishing name so it can be selected.
3. **Why is 3520x2640's minimum LLP 13 counts above `width x 22/15`?** Everything
   else lands exactly. Needs the datasheet, so Windows side.
4. **The iris encoder's bitrate units** (§6d). Kernel side.
5. **No `imx681.yaml` IPA tuning file**, so libcamera's colour is uncalibrated.
   Mine, and it needs a colour target rather than more code.

Done since mission 18: the libcamera `CameraSensorHelper` and the
`camera_sensor_properties` entry (§6c, `patches/libcamera/`); `0x2000 = 0x01` in
mode 0's table; the `3840x2160` reorder that made the desktop work; and the
`_1` diagnosis above.

Dropped as settled or moot: `0x2000 = 0x02` (an output-path selector, confirmed
both directions in mission 18), bit 11 (§4 — followed the failure, not the
block), where mode 0's table comes from (§4), `NUM_ACTIVE_LANES` (§6a), and the
D-PHY control run — every mode now works on C-PHY and it has no bearing left.

---

## 7. Working practice

**The gate rule.** Never touch CSID/CSIPHY MMIO unless the sensor's
`power/runtime_status` is `active`. Violations reset the SoC below the kernel:
no panic, no pstore record, all mounted FAT/exFAT volumes dirty. This happened
three times this session, each time because the access felt like it did not
count — a timing test, a batched gate check, "the clock cannot drop mid-capture".
The gate is a sysfs read via a shell builtin; it is free. See
`tools/native/README.md`.

**Ground rules carried forward** (1–15 are the Windows agent's, in the relay
`STATE.md`; these are the ones added from this side):

- 14. Reproducibility to the digit is a measurement.
- 16. The gate is not suspended for measurements *about* the instrument. (This
  is the gate rule; the Windows side numbers it 16, and 17 is theirs — "a
  register that reads zero may be a command register".)
- 18. A success metric you have never seen succeed is a hypothesis, not a
  metric. `vfe0 == 0` was the definition of failure for fifteen missions and
  reads 0 on success too. When a project is organised around a number that is
  always the same, that number needs independent confirmation it can ever differ.
- 19. **An instrument only ever tested against failure is untested.** The
  sampler slept 0.1 s between gate polls and stopped at the first suspend, which
  is fine against mode 0 — it streams for the full 15 s timeout. A *successful*
  capture is `--stream-count=1`: one frame, then STREAMOFF, a 104 ms window. The
  first mode-1 run returned four samples of pre-streaming zeros and read as
  "the counters are dead on the working mode". Fifteen missions never caught it
  because there was never a success to catch it with.
- 20. **A measurement taken under conditions that cannot show the thing is not
  evidence of its absence.** Mode 0's first working frame was flat at 15–16 and
  looked exactly like a routed-but-empty stream; the gain was 0, where *any*
  frame from this sensor is pedestal. One run at gain 1023 turned it into a
  photograph. The general form — asserting a downstream fact without checking
  the thing itself — also produced `0x0ace4000`, the `MODE=` slip, and the
  privacy-LED miscall. Before reporting a negative, state what a positive would
  have looked like under the conditions you actually used.
- 21. **A plausible-looking rendering is not a verified one.** The first colour
  conversion rendered a room lit by a magenta lamp as green — grey-world white
  balance cancels a dominant cast by construction, and the colour matrix
  amplified the residual into the complement. Nothing about the image looked
  wrong; it was caught only when the user produced a phone photo of the same
  room. The internal tell was there and unread: raw Bayer is green-heavy, so a
  correct balance has both gains ≥ 1, and the measured red gain was 0.851.
  **When an instrument's output is an image, "it looks right" is the weakest
  possible check** — find the number that has to hold, and assert on it.
- 22. **Any test whose point is that a knob changes something must read the
  knob back.** A mission-18 gain sweep returned four identical rows — signal
  83.57, 83.62, 83.47, 83.38 across a 16x gain change. `modprobe -r` had
  renumbered the sensor subdev from 22 to 23 and `2>/dev/null` on the
  `v4l2-ctl --set-ctrl` swallowed `Cannot open device`, so every capture ran at
  one unchanged gain. The lesson is narrower than "do not hide stderr": **a
  no-op and a null result are indistinguishable in the output**, so the control
  has to be read back, not just written. Discover the subdev from `media-ctl`
  rather than hardcoding it — the number moves on every module reload.
- 23. **A curve fitted through N points has to be tested on point N+1, and not
  on the points it was fitted to.** Two measured LLP thresholds gave
  `min = width x 1.425 + 160`, clean enough to nearly ship as the rule. It
  predicted 5375 for the next mode; the answer was 5368. A fit that reproduces
  its own inputs is a restatement of the data, not a model — the only thing that
  distinguishes them is a number written down before the measurement that
  produced it. Cost here: one capture. Keep falsified models in the write-up;
  a model that would have been shipped is worth more as a warning than as an
  omission.

**Environment traps.** `sudo` strips the environment — `TIMEOUT=120 sudo foo`
silently runs the default; use `sudo env TIMEOUT=120 foo`. POSIX `[` compares
decimal only, so `[ 0x20c -le 572 ]` is an error and skips the loop silently.
`numpy` is not installed; PIL is.

**Relay protocol.** The Windows agent writes `/mnt/t7/sp11-relay/TO-LINUX.md`
(mission briefs — these are files, not user turns). I own `TO-WINDOWS.md` and
never edit theirs. Report requested numbers first, verbatim, in the brief's
order; then reasoning; then next steps; then explicitly what changed on the
machine, even if nothing. Artifacts go in `mission<N>-artifacts/`. `sync` after
writing — the box crashes and the relay is exfat.

---

## 8. Tools

In `tools/native/` — see its README for the register map and gotchas.

| tool | use |
|---|---|
| `sp11-camss-gate.sh` | sourceable gate + `rd`/`wr`; everything else builds on it |
| `sp11-camss-sample.sh` | gated multi-register sampler, ~55 Hz |
| `sp11-camss-fast.py` | mmap'd counter sampler, ~110 kHz; resolves the burst |
| `sp11-raw10-preview.py` | RAW10-packed → greyscale PNG, and a completeness check |
| `sp11-raw10-rgb.py` | RAW10-packed → **colour** PNG; demosaic + WB + gamma + CCM |
| `sp11-bayer-phase.py` | 2×2 CFA phase means; settles the Bayer order |
| `sp11-mode-ab.sh` | alternating A/B between two modes |
| `sp11-record.sh` | record video that is not destroyed by the encoder defaults |

**To sample a *successful* capture you must pass `-k` / `--keep`.** The window is
~104 ms and the harness powers the sensor twice — once for the state dump, then
again to stream — so without it the sampler locks onto the dump and reports
pre-streaming zeros. See rule 19.

**To measure colour, raise `analogue_gain` first.** At default gain a dim indoor
scene means ~16/255, almost all black-level pedestal, which carries no colour;
phase ratios then sit within 1 % of each other whatever you photograph. At gain
1023 the same scene means ~130 and the ratios move 30 %. Recolouring the room
light beats holding a coloured object up — a blue object under a warm lamp
reflects almost no blue.

The capture harness itself is `/mnt/t7/surface/tools/sp11-camera-test.sh`
(`MODE=WxH`, `TIMEOUT=` via `sudo env`) and is **not** mine to edit. Note
line 140: `MODE=${MODE:-4032x3024}` — it defaults to the *broken* mode.
