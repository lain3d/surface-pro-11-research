# tools/native — Linux-side camera probes for Surface Pro 11 (x1e80100)

Instruments for the IMX681 / qcom-camss bring-up, run natively on the SP11 under
Linux. Everything here reads or pokes CSID and CSIPHY MMIO through `/dev/mem`.

## The one rule that matters

**Never touch CSID or CSIPHY MMIO unless the sensor's runtime-PM status is
`active`.**

Those blocks are clock-gated. An access while unclocked raises a NoC error that
resets the SoC *below* the kernel: no panic, no oops, and **no pstore record**
even with ramoops configured and working — the CPU never runs a panic path. The
machine just restarts, and every mounted FAT/exFAT volume comes up dirty.

This cost three resets during bring-up. Every one was the same mistake in a
different disguise:

| what I told myself | what happened |
|---|---|
| "it's only a timing test, not real data" | reset |
| "the block can't lose its clock mid-capture" | reset at STREAMOFF |
| "checking the gate every 200 samples is close enough" | reset, ~200 ms of ungated reads |

So: **gate every single access, including writes, including throwaway ones.**
The gate is a sysfs read. Use a shell builtin (`read`) or a Python `open()`, not
`$(cat …)` — then it costs nothing and there is never a reason to skip it.
`sp11-camss-gate.sh` exists so you do not have to re-implement it.

## Tools

| tool | what it does |
|---|---|
| `sp11-camss-gate.sh` | sourceable gate + `rd`/`wr` helpers. Everything else uses it. |
| `sp11-camss-sample.sh` | gated multi-register sampler, ~55 Hz. The general workhorse. |
| `sp11-camss-fast.py` | mmap'd single-counter sampler, ~110 kHz. For burst timing. |
| `sp11-raw10-preview.py` | MIPI RAW10-packed frame → greyscale PNG. Integrity check. |
| `sp11-raw10-rgb.py` | same frame → **colour** PNG. Demosaic + WB + gamma + CCM. |
| `sp11-bayer-phase.py` | 2×2 CFA phase means. Settles `SRGGB` vs `SBGGR`. |
| `sp11-mode-ab.sh` | alternating A/B capture between two sensor modes. |
| `sp11-record.sh` | record video at a bitrate that does not wreck the image. |

## Every sensor mode has a minimum LINE_LENGTH_PCK

`0x0342/0x0343` below the threshold and the capture returns **zero bytes** with
nothing else visibly wrong: the sensor streams, the CSID counts long packets by
the million, ECC and CRC stay 0, `0x210` stays 0, and no buffer ever completes.
It looks exactly like a routing failure and is not one.

Measured by bisection, exact to ±1 count, set by **output width alone** — two
modes of the same width and different heights share a threshold to the count:

```
mode          width   min LLP   native LLP   ratio to width
4032x3024      4032      5376        6752    4/3      exact  (pll 180, op 2/208)
3840x2640      3840      5632        6752    22/15    exact
3840x2160      3840      5632        6752    22/15    exact
3660x2440      3660      5368        6752    22/15    exact
3520x2640      3520      5176        6752    1.47045  unexplained outlier
```

Mode 0 has its own coefficient and is the one mode with a different PLL, so the
ratio tracks the clock configuration. Use this to sanity-check a recovered mode
table on paper: the `3840x2160_1` entry, which was dead for four missions, asks
for 5408 against a minimum of 5632 and would have failed this check without a
capture.

## Recording video: check the bitrate before blaming the camera

GNOME Snapshot records 1080p30 at well under 1 Mbit/s and the result is a
blocky mess, while its own preview looks excellent — the two go down different
paths.

**The cause is a units bug in libaperture, not a GStreamer default.** It sets
`vp8enc`'s `target-bitrate` to 2048 where the property is bits/sec, intending
2048 kbit/s — the `openh264enc` line directly above it does the `* 1024`
correctly. So VP8 is asked for 2 kbit/s. Full write-up and measurements in
`patches/aperture/`, including why installing `gstreamer1.0-plugins-bad` makes
the problem vanish and why `enable-hardware-encoding` makes it far worse.

Same camera, same scene, ~12 s of 1080p30:

```
GNOME Snapshot     940,806 bytes   ~0.5 Mbit/s   heavy blocking
sp11-record.sh   8,041,107 bytes    8 Mbit/s     clean
```

No frames were dropped in either (374 frames over 12.62 s). It is purely
quantisation.

## The hardware video encoder, and the two things it needs

There *is* one, as of mission 19 — an earlier version of this file said there
was not, and it was wrong in both halves. The firmware was never missing (it is
in the Windows driver store, now at
`/lib/firmware/qcom/x1e80100/microsoft/Denali/qcvss8380.mbn`) and the driver was
never absent — `hamoa.dtsi` ships `iris: video-codec@aa00000` with
`status = "disabled"`, because the blob is vendor-signed and each board must
name its own. Ours now does.

```
/dev/video0   qcom-iris-decoder    H264 HEVC VP90 AV01
/dev/video1   qcom-iris-encoder    H264 HEVC
```

**No VP8 either direction**, so Snapshot's own recordings are still software.
**And the camss nodes moved to `/dev/video2..17`.** Anything that hardcoded
`video0` for the camera now points at a video decoder; follow the media graph.

Two non-obvious requirements, both handled inside `sp11-record.sh`:

- **Pin `profile` and `level` in caps.** Unconstrained, GStreamer fixates the
  encoder's src caps to the first entry in each list — Baseline, level 1 — on a
  1080p stream. Level 1 permits 99 macroblocks; 1080p needs 8160. ffmpeg decodes
  it anyway, but GStreamer's own caps intersection returns EMPTY, so
  `v4l2h264dec` refuses to play back what `v4l2h264enc` just wrote
  (`not-negotiated (-4)`). The driver's defaults are sane; this is GStreamer.
- **Divide the bitrate by the frame rate.** iris treats
  `V4L2_CID_MPEG_VIDEO_BITRATE` as bits per *frame*, where V4L2 defines it as
  bits per second. Asking for 2 Mbit/s gives 60.04 at 30 fps, 30.02 at 15 and
  119.98 at 60 — the factor is the frame rate to three digits. Asking 266,667
  gave 8,006,250 bit/s off the camera.

`h264parse`, `h265parse` and `mp4mux` are not installed by default; they live in
`gstreamer1.0-plugins-bad`. Without them nothing can mux or parse the output.

**`ffmpeg -c:v h264_v4l2m2m` segfaults when encoding**, deterministically, at
most common resolutions. It is a bug in ffmpeg, not in the hardware or the
driver: `v4l2_buffer_swframe_to_buf()` takes the plane height from the driver's
format and the plane pointer from the AVFrame, and the iris encoder rounds
1920x1080 up to 1920x1088, so the copy reads 8 luma rows past the end of the
plane. Root cause, evidence and a validated fix are in `patches/ffmpeg/`. Its
*decoder* is fine, and GStreamer never goes near that code path.

## Sampling a *successful* capture needs `-k` / `--keep`

A failing mode streams for the whole `TIMEOUT`. A working one does not: the
harness runs `v4l2-ctl --stream-count=1`, takes one frame and calls STREAMOFF,
and the entire active window is about **104 ms**. On top of that the harness
powers the sensor **twice** — once for the state dump, then again to stream — so
a sampler that stops at the first suspend locks onto the dump and never sees a
packet.

Both samplers used to sleep 0.1 s between gate polls and exit at the first
suspend. Against mode 0, which never stops streaming, that looked fine for
fifteen missions. The first mode-1 run returned four samples of pre-streaming
zeros, which read as "`0x210` and `0x240` are dead on the working mode" — a
completely wrong conclusion that the instrument produced confidently.

They now busy-spin the gate and keep sampling across suspend/resume. The spin is
a sysfs read, not MMIO, so it is outside the gate's remit.

An instrument only ever tested against failure is untested.

## Register map (x1e80100, verified against `/proc/iomem` on this machine)

```
csid0            0x0acb7000 - 0x0acb8fff     acb6000.isp csid0
csid_wrapper     0x0acb6000 - 0x0acb6fff
csiphy           0x0ace8000 - 0x0ace9fff     ace8000.csiphy   <- the ONLY csiphy
```

**There is no `0x0ace4000` on this machine.** Vendor docs and Windows-side
analysis refer to `csiphy0` at that base; nothing claims it here and reading it
resets the SoC. This platform instantiates one CSIPHY and the sensor is on it.
Confirm with `grep -iE 'csiphy|csid' /proc/iomem` before trusting any base.

Useful CSID0 offsets (names from `drivers/media/platform/qcom/camss/camss-csid-680.c`):

```
0x018  REG_UPDATE_CMD        write-1-to-command, SELF-CLEARING -> always reads 0
0x07c  TOP_IRQ_STATUS        0x080 TOP_IRQ_MASK
0x08c  BUF_DONE_IRQ_STATUS   0x090 BUF_DONE_IRQ_MASK
0x09c  CSI2_RX_IRQ_STATUS    0x0a0 CSI2_RX_IRQ_MASK   (mask never written by camss)
0x0ec  RDIN_IRQ_STATUS(0)    0x0f0 RDIN_IRQ_MASK(0)   (camss sets RUP_DONE only)
0x200  CSI2_RX_CFG0          0x204 CFG1   0x208 CAPTURE_CTRL
0x210  unmapped long packet header  DT 21:16, VC 26:22, word count 15:0
0x218  live, unnamed in tree
0x240  TOTAL_PKTS_RCVD       0x244 STATS_ECC   0x248 CRC_ERRORS
0x500  RDI_CFG0(0)           0x504 RDI_CTRL(0)   0x510 RDI_CFG1(0)
0x550  crop H bounds (end 31:16 / start 15:0)   0x554 crop V bounds
```

## Gotchas that cost real time

- **`sudo` strips the environment.** `TIMEOUT=120 sudo foo` silently runs the
  default. Use `sudo env TIMEOUT=120 foo`.
- **POSIX `[` compares decimal only.** `[ 0x20c -le 572 ]` is "Illegal number"
  and the loop is skipped *silently* if you do not check stderr. Initialise loop
  counters with `$((0x20c))`.
- **`vfe0` is not a success metric.** On this hardware `buf_done` is raised by
  `CSID_BUF_DONE_IRQ_STATUS` in the CSID ISR, not the VFE IRQ line. `vfe0` reads
  0 on a *successful* capture. Watch `csid0` (+1 = reset only, more = working)
  and the output file.
- **Sample *during* streaming.** A sweep in the sampler's preamble runs before
  the first packet and its zeros mean nothing.
- **IRQ-status registers here are W1C** and the ISR clears them. They only
  accumulate because `csid0` takes so few interrupts; do not assume stickiness.
- **Always pass `MODE=`, and confirm the mode from the PLL.**
  `sp11-camera-test.sh:140` is `MODE=${MODE:-4032x3024}` and it negotiates that
  through media-ctl whatever the driver enumerates first, so the mode string in
  the log is what was *asked for*, not what ran. Check the state dump: mode 0 is
  `op_pre_pll_div 2 / op_pll_multiplier 208`, mode 1 is `3 / 375`. The frame size
  is the other independent check — 15,240,960 bytes is 4032×3024, 11,616,000 is
  3520×2640.
- **All six sensor modes capture** as of the mission-18 driver. `0x2000 = 0x01`
  is in `4032x3024`'s table and `mode0_class` is gone. To poke a sensor register
  without a driver rebuild, use `imx681.reg_patch` —
  `echo "0x2000=0x02" | sudo tee /sys/module/imx681/parameters/reg_patch` puts
  the old 504x382 thumbnail back, which is a handy known-bad control.
- **Do not hardcode the sensor subdev.** It moves on every module reload
  (`/dev/v4l-subdev22` became 23 after one `modprobe -r`). Find it with
  `media-ctl -p | grep -A3 'entity.*imx681'`, and never send `v4l2-ctl` stderr
  to `/dev/null` — a failed `--set-ctrl` otherwise looks exactly like a control
  that had no effect.
- **`analogue_gain` is `1024/(1024-code)`, not linear in the code.** Codes 0,
  300 and 600 are 1×, 1.4× and 2.4×, so a sweep across the low three-quarters of
  the range looks like the control does nothing — every frame comes back at
  pedestal. Everything usable is above ~900: 960 is 16×, 1014 is 102×, 1020 is
  256×, and 1023 is 1024×. For a normally-lit indoor scene 1014–1020 is the
  working range; 1023 blows the highlights.
- **A greyscale preview does not mean a greyscale sensor.**
  `sp11-raw10-preview.py` writes a single-channel image, so the Bayer mosaic
  shows up as luminance no matter how colourful the scene. Use
  `sp11-raw10-rgb.py` for colour.
- **Do not white-balance a coloured scene by grey-world.** A room under a
  magenta lamp rendered *green* — grey-world cancels the dominant cast by
  design, and the colour matrix then amplifies the residual into the complement.
  The output looked entirely plausible; it was caught only by comparing against
  a phone photo of the same room. The tell is in the gains: raw Bayer is
  green-heavy (twice the green photosites, wider passband), so a correct balance
  has **both gains ≥ 1**, raising weak R and B toward green. Grey-world returned
  `R 0.851`. `sp11-raw10-rgb.py` now warns when a measured gain drops below 1
  and defaults to a fixed preset instead.
- **Raise `analogue_gain` to 1023 before judging frame content at all.** At
  default gain a dim indoor scene means ~16/255 and is almost entirely
  black-level pedestal. This bites twice. For colour, phase ratios come out
  within 1 % of each other no matter what is in front of the lens — a small
  spread means "not enough light", not "no CFA". For *presence*, a flat 15–16
  frame is indistinguishable by eye from a routed-but-empty stream: mode 0's
  first working capture looked blank and was very nearly reported as a failure.
  A correct byte count plus flat content proves nothing until the gain is up.
