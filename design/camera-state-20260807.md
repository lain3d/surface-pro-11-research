# Camera bring-up: state of play, 2026-08-07

Continuity note for picking this up cold.

---

## 0. What to read, and what not to

**Point a cold session at this file alone.** It is written to be sufficient:
current state, the next mission with its decision table, what is installed, what
is deliberately unresolved, and the traps. Everything else is a lookup.

| resource | when to read it |
|---|---|
| **this file** | always, first |
| `design/camera-bringup-20260806.md` | when you need *why* a conclusion was reached, not what it was. 800+ lines of narrative — do not load it speculatively |
| `data/csiphy-cphy-x1e80100.txt` | **the CSIPHY reference.** Settle table, C-PHY preamble, all three per-frequency tables, `CSIDPhyReset`, the full `CameraMIPIPHY_Start` sequence, interrupt registers, lane masks, the data-rate reconciliation. Read whenever touching PHY programming |
| `data/csid-irq-decode-x1e80100.txt` | **the CSID interrupt decode**, recovered from `qccamisp8380.sys`: the RX and RDI error masks, `rxIrqStatus` bit 22 = unmapped long packet header, the IFE acquire structure. Read whenever interpreting a CSID status word |
| `data/csitestmode-20260807.txt` | the four Windows measurements, with the reading notes and provenance warnings |
| `data/imx681-registers.txt` | recovered sensor register sequences |
| `drivers/media/platform/qcom/camss/camss-csid-680.c` (in `wt-cfg`) | authoritative CSID register map and bit fields. Prefer it over any transcription |
| `E:\sp11-relay\TO-LINUX.md` | the live mission brief as the Linux side sees it |

There is also a rendered reference document (sensor "datasheet", SoC
integration, kernel bindings) published as an Artifact and exportable to PDF.
**Do not load it to resume work.** It is a human-facing explainer, and every
fact in it is derived from the sources above — reading it costs context to
re-learn things that are grep-able from the originals.

---

## 1. Where it stands

> **THE DESKTOP CAMERA APP WORKS (mission 18, 2026-08-08).** GNOME Snapshot
> opens, previews and captures, at its default settings, from a cold boot. The
> user confirmed it directly. **This is the project's original goal, met.**
>
> Two independent faults had to fall for it, both in mission 18's module:
> `0x2000 = 0x01` fixed `4032x3024`, which is the capture node's *default*
> format and so was what every application got handed; and reordering the
> `3840x2160` pair put the working variant first, which is what libcamera
> resolves 1920x1080 / 1280x720 / 640x480 onto.
>
> **THE CAMERA WORKS (mission 15, 2026-08-07).** `3520x2640` captures a complete
> frame: 11,616,000 bytes = 3520 × 2640 × 10/8, RAW10-packed, a recognisable
> photograph, reproduced 8/8 alternating against the failing mode. Brightness
> tracks `analogue_gain`, so it is live silicon.
>
> As of mission 16 it is also the **default mode**, and `csid_cphy` /
> `cphy_force` default on, so a plain capture needs no arguments.
>
> **One defect remains: `3840x2160_1`**, which no longer blocks anything because
> it is unreachable from userspace. See §6.6.

**`vfe0` was never the right metric — rule 18.** Thirteen missions treated
`vfe0 == 0` as the definition of failure. **It reads 0 on a successful capture
too**: `buf_done` on this hardware is raised by `CSID_BUF_DONE_IRQ_STATUS` in
`csid_isr()` calling `camss_buf_done()`, not by the VFE's own line. The real
signals are **`csid0` going from +1 (reset only) to +4, and `BUF_DONE` moving**.
Anything below that cites `vfe0` is reasoning from a broken instrument.

**What mode 0 actually does.** It is not a 12 MP frame failing 12.6 % in. It
puts a **504 × 382 RAW8** image on the wire, complete and well-formed:

```
0x210 = 0x002A01F8   DT 0x2A (RAW8), VC 0, word count 504
4032 / 504 = 8.0     width subsampled 8x
3024 / 8   = 378     observed 382 = 378 + 4  (FS + FE + 2)
```

So **382 is explained** — it was never a fraction of anything, it was the whole
stream. The remaining question is why mode 0 emits it. Leading candidate: the
136-register `0xE801-0xE899` block that mode 0's table appends and mode 1's does
not (mission 16 tests this via `imx681.mode0_e8xx=0`).

**The physical layer is solved.** Mission 13, 120-second capture:

```
TOTAL_PKTS_RCVD  136,756      CRC_ERRORS  0      STATS_ECC  0
settle_cnt 0x22   table >= 2.5 Gbps   datarate 5,485,700 kbps
status19 000000d7 -- RefGen Ready
```

Mission 11 measured ~50 % CRC on 2 packets. Zero errors across 136,756 is a
different regime, and runs L and M returned **22,538 packets identically twice**,
which rules out a marginally-locking analog link.

**No frame has ever been delivered.** `vfe0` has taken zero interrupts in
thirteen missions.

**The open symptom.** Packets arrive in bursts of **exactly 382**, one CSIPHY
interrupt per burst, burst period 0.3350 s (2.985 Hz), reproducible to the
packet across three runs. A 4032x3024 frame is 3,026 packets (3,024 long + FS +
FE), so each burst is 12.6 % of a frame. The interrupt reports CSIPHY
`STATUS2 = 0x1b`; no bit definitions exist for it and Windows does not save that
word.

### What fixed the link

Three faults, all fixed at once in mission 13, all downstream of one mistake:

| | was | is |
|---|---|---|
| symbol rate assumed | 875.8 MSps | 1996.8 MSps |
| settle count | `0x40` (64) | `0x22` (34) |
| per-frequency table | `< 2.0 Gbps` | `>= 2.5 Gbps` |

Root cause: `link_freq_menu_items[]` in `imx681.c` are **half the C-PHY symbol
rate** — the D-PHY DDR convention applied to a C-PHY sensor —
and `cphy_settle_cnt()` then divided by 2.28 as though the doubled value were a
bit rate. The link ran at 36 % of its real symbol rate with a settle window
68 % too long, out of the wrong register table.

---

## 2. Mission 14 — RUN. Mission 15 is the live one.

**Mission 14 result:** the CSID error layer is clean. `RDIN`, `TOP` and
`BUF_DONE` are zero across 118 s and 6,792 samples. `CSI2_RX_IRQ_STATUS` reads
`0x00400017` from the first burst onward. `REG_UPDATE_CMD` reads zero throughout
— but that is a *command* register (gen3's clear path writes nothing, which is
how you can tell), and the one write happens at `STREAMON` before any sampler
starts, so that particular null proves nothing. The finding that survives is
`RDIN_IRQ_MASK0 = RUP_DONE` with `RDIN_IRQ_STATUS = 0` for 118 s:

> **no register update ever completed, so the CSID has never reached a frame
> boundary** — which is the predicted consequence of the 382-packet burst, not a
> second fault.

Ordering was checked and cleared: `video_start_streaming()` walks upstream so the
RUP is written before `csid_configure_stream()`, but the sensor starts *last*, so
the shadow is complete before the first frame boundary. Not a bug.

**Mission 15** is at `E:\sp11-relay\TO-LINUX.md`: unmask `RDIN` and re-read
(closes backpressure properly — BIT(2)/BIT(19) were masked), arm packet capture
and read `0x0acb7210` for the unmapped VC/DT, and read the CSIPHY per-trio status
at `0x0ace4358` which is Windows' own health criterion and has never been
sampled. Reads and devmem pokes only.

The mission-14 brief below is kept because its register list is still the
sampling baseline.

Old brief. **Reads only, no build required.**

Setup is mission 13's, plus the rate override:

```bash
echo 1 > /sys/module/qcom_camss/parameters/csid_cphy
echo 1 > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_force
echo 5485700 > /sys/module/phy_qcom_mipi_csi2/parameters/cphy_datarate_kbps
```

Sample these across the stall, CSID0 base `0x0acb7000`:

| offset | register |
|---|---|
| `0x0ec` / `0x0f0` | `RDIN_IRQ_STATUS(0)` / `RDIN_IRQ_MASK(0)` |
| `0x09c` / `0x0a0` | `CSI2_RX_IRQ_STATUS` / `MASK` |
| `0x07c` / `0x080` | `TOP_IRQ_STATUS` / `MASK` |
| `0x08c` | `BUF_DONE_IRQ_STATUS` (RDI0 = bit 14) |
| `0x208` | `CSI2_RX_CAPTURE_CTRL` |
| `0x500` / `0x504` / `0x510` | `RDI_CFG0(0)` / `RDI_CTRL(0)` / `RDI_CFG1(0)` |

`camss-csid-680.c` already defines the bits and never reads them:

```
CSID_CSI2_RDIN_INFO_FIFO_OVERFLOW            BIT(2)    <- backpressure
CSID_CSI2_RDIN_ERROR_REC_OVERFLOW_IRQ        BIT(19)
CSID_CSI2_RDIN_BATCH_END_MISSING_VIOLATION   BIT(25)
CSID_CSI2_RDIN_ERROR_REC_HEIGHT_VIOLATION    BIT(26)
CSID_CSI2_RDIN_ERROR_REC_WIDTH_VIOLATION     BIT(27)
CSID_CSI2_RDIN_CCIF_VIOLATION                BIT(29)
```

**Why the masks are in the list.** `csid0` takes exactly one interrupt per
`STREAMON` while 358 bursts go past, so whatever ends a burst is not reaching
the CSID interrupt line. If the block only latches STATUS for unmasked sources,
a status read of zero is uninterpretable on its own. Reading the mask alongside
makes a zero mean something.

### Decision table

| reading | meaning | next |
|---|---|---|
| `RDIN` BIT(2) or BIT(19) | backpressure; 382 is a FIFO depth | reduce the load — binning, see §4 |
| BIT(26)/BIT(27) | geometry mismatch | `RDI_CFG0` vs the sensor's real output size |
| `RDI_CTRL` not enabled | the consumer was never started | camss config bug; sensor is irrelevant |
| clean, `BUF_DONE` never moves | CSID content, write master not running | VFE |

Also never used in `camss-csid-680.c`: `CAPTURE_CTRL`, `TOTAL_PKTS_RCVD`,
`STATS_ECC`, `CRC_ERRORS`, `RDI_ERR_RECOVERY_CFG0`, `RDI_PIX_DROP_*`,
`RDI_LINE_DROP_*`, `RDI_FRM_DROP_PATTERN`.

---

## 3. What is installed and where

Installed on the T7 root under
`/lib/modules/7.1.3-sp11-stockcfg-gf2cc827b6b89/`, as of mission 17:

**Current as of mission 20: `imx681.ko` is `1FB3BA3A673DD193E53E360`**, adding
the `3840x2160_1` LLP repair and the frame-interval pad ops. `hts`/`vts` are now
derived from each mode's register table rather than hand-transcribed — the
original bug was two hand-maintained copies of 5408 with nothing checking
either. The other two modules are unchanged.

The historical list below is from mission 17.

```
imx681.ko               srcversion F8B9A372D76A6E5C7A5D893
  parm mode0_e8xx (bool, default 1), mode0_class (uint, default 0), addr_scan

qcom-camss.ko           srcversion D13CE257B7EBB32ED398C37
  parm csid_cphy (default 1)

phy-qcom-mipi-csi2.ko   srcversion 6872706400130DA2682B82C
  parm cphy_force (default 1), cphy_datarate_kbps (default 0 = derive),
       irq_unmask, cphy_ctrl5, win_reset, timer_400
```

**Defaults now carry a working camera** — mission 16 reproduced an 11,616,000-byte
`3520x2640` frame six times with nothing set. `cphy_datarate_kbps` is
**unnecessary**; the rate derived from `link_freq_menu_items[]` is sufficient.
It is still present, to be removed alongside the DT/`bus-type` commit.

**As of mission 18 the parameter set is `mode0_e8xx`, `reg_patch`, `addr_scan`.**
`mode0_class` is gone — its finding is in the mode table. `reg_patch` takes
comma-separated `ADDR=VAL` 8-bit sensor writes applied after the mode table,
e.g. `reg_patch="0x0368=0x00"`, and exists because four missions were each
spent posting a single register across the relay. Use it before proposing a
rebuild.

**Two modes were broken and only one is fixed.** `4032x3024` needed
`0x2000 = 0x01` (§6.0). `3840x2160` still produces zero bytes in its `_1`
variant; the driver now enumerates the working `_2` first, which is what
unblocked the desktop, and `_1` is consequently unreachable from userspace
because `v4l2_find_nearest_size()` returns the first entry of equal error.
`{0x0368, 0x01}` was the suspect and is **cleared** — see §6.6 for what
actually remains.

**The CCS array-limit registers are not implemented on this part.** Mission 18
read `0x0168`/`0x016a`/`0x016c`/`0x016e` at stream start and got
`x 0..0  y 0..0`. So the pixel-array constants in `imx681.c` stay derived from
the mode tables, and that is the best available source rather than a stopgap.
The log line is kept because it now records a measured negative.

`.orig` backups exist for all three and must never be overwritten. Verify an
install by decompressing what landed and comparing to the build — not by the
file appearing.

**The harness does not follow the driver's default mode.**
`sp11-camera-test.sh:140` is `MODE=${MODE:-4032x3024}`, so a plain capture
tests the *broken* mode. `MODE=3520x2640` is required. Confirm which mode
actually ran from the PLL readback (`op_pre_pll_div`/`op_pll_multiplier`:
mode 0 is `2 / 208`, mode 1 is `3 / 375`), not from the mode string.

- UKI `integ46`, untouched.
- Kernel: `debug/camss-cphy` at `62c2e144f` on remote **`publish`**
  (`lain3d/surface-pro-11-kernel`; `origin` is upstream and 403s).
- Worktrees live in WSL at `/root/sp11/`; `wt-cfg` is the build tree.
- Relay: `E:\sp11-relay\TO-LINUX.md` (mine) and `TO-WINDOWS.md` (theirs),
  prior missions under `archive/`.

`win_reset` is answered and dead — run M was bit-identical to run L on every
counter. Do not spend another mission on it. RefGen is answered and dead too.

---

## 4. The Surface Pro 10 work — what is reusable

`linux-surface/linux-surface#2153`, by djmulder. **A complete IMX681 bring-up**:
1920x1080, SBGGR10, correct colour, ~15.85 fps, working in Teams via PipeWire.

**It is not our machine.** SP10 is Intel Meteor Lake with IPU6; the "SP11" in
their comparison table is Intel **Lunar Lake with IPU7** (AndreGilerson's work).
Ours is Snapdragon X1E80100 with camss. Nothing they built touches CSIPHY, CSID
or VFE, and none of their INT3472 / ipu-bridge work applies.

### Sensor-level findings that do transfer

Worth having whatever mission 14 says. `imx681.c` currently contradicts three of
these.

1. ~~**Bayer phase is `SBGGR10`**~~ **DOES NOT TRANSFER — ours is `SRGGB10`,
   measured, mission 16.** Their `SBGGR10` was measured against a blue object
   with `IMAGE_ORIENTATION = 0x03` (h_mirror + v_flip); our blob never writes
   `0x0101`, and their own orientation caveat predicted the phase could differ.
   Measured here by illuminant swap at equal gain:

   ```
                  R (phase 0)      G          B (phase 3)     B/R     |Gr-Gb|
   blue light       105.06       134.09        130.35        1.241     1.21
   warm light       159.61       170.05        146.16        0.916     0.08
   ```

   R and B swap in the right direction with the illuminant, and the two greens
   agree to 0.05 % on the warm frame. **`imx681.c`'s declared `SRGGB10` is
   correct** and is no longer a one-in-four guess. Second SP10 finding that does
   not transfer.

   **Why it differs on the same sensor — it is not wiring.** The CFA is fixed
   on the die. Only two things move the phase the receiver sees: the parity of
   `x_addr_start`/`y_addr_start`, and `IMAGE_ORIENTATION` (`0x0101`, h_mirror
   bit 0, v_flip bit 1). Both are neutral here — all six mode tables crop from
   an **even** column and an **even** row (verified), and neither the blob nor
   the driver writes `0x0101`, so it stays at its power-on `0`. The SP10 port
   runs `IMAGE_ORIENTATION = 0x03`, which over an even-sized window is a
   180° rotation of the 2x2 tile, and **RGGB rotated 180° is BGGR**. Different
   readout direction, same silicon. Their measurement and ours are both right.

   **Live trap.** `imx681.c` exposes no `HFLIP`/`VFLIP`. Adding them requires
   the media bus code to change with the control, since each flip inverts one
   axis: none `SRGGB10`, h `SGRBG10`, v `SGBRG10`, h+v `SBGGR10`. Wiring a flip
   to `0x0101` with the format left hardcoded silently inverts red and blue.
   Documented in the driver at `d9729f349`.
2. ~~**Analog gain `0x0204` is inverted.**~~ **CONTRADICTED on our module,
   mission 15.** Their finding was code 0 = 16x, code 960 = 1x. Measured here on
   a real frame, brightness *increases* with the code: mean 24.46 → 31.30 →
   67.96 for 0 → 512 → 1023. Do not apply their inverted helper. This is the
   first SP10 finding that does not transfer, and it is a reminder that "same
   sensor" is not "same module".

   **The gain law and the cap are both settled (mission 18) — do not cap it.**
   The law is `1024/(1024 − code)`, the Sony family form `2^n/(2^n − code)`,
   corroborated by mainline `imx219` (`ANA_GAIN_MAX 232` → 10.7x) and `imx208`
   (`224` → 8.0x); measured points land on it to the digit (code 1014 → 102.4x,
   code 1020 → 256x). The *cap* was the open part, and it was answered by
   measurement rather than judgement:

   ```
    code    gain      mean    std   signal    SNR
     960   16.0x     36.35   4.45   20.85    4.68
    1000   42.7x     69.10  11.64   53.60    4.61
    1014  102.4x    132.87  26.99  117.37    4.35
    1020  256.0x    244.55  22.37  229.05   10.24   <- clipped, disregard
   ```

   **SNR is flat from 16x to 102x** — noise scales with signal, so the limit is
   the light in the room, not the amplifier. Flat SNR alone cannot separate
   analogue gain from a digital multiply, so a second test did: a digital
   multiply leaves comb gaps in the output histogram, and there were **none
   inside the central 90 %** at either code 1014 or 1020. The gain is applied
   before quantisation — genuinely analogue to at least code 1020. Capping at
   16x would cost six stops and buy nothing. Caveat: one scene, one light level,
   mid-tone patch.
3. **`0x0340` (frame length) reads back 0 and is ignored during init** under
   `v_flip`; it must be written *after* `MODE_SELECT = 1`. **Our driver reads FLL
   back from the sensor after programming a mode** and would read zero.
4. **Horizontal binning does not work on this part.** `0x0901 = 0x22` reads back
   `0x02` — vertical only. Horizontal reduction needs the sensor's scaler:
   `SCALE_MODE 0x0401 = 1`, `SCALE_M 0x0404 = 32` for 2x.
5. Binning registers are `0x0900` BINNING_MODE and `0x0901` BINNING_TYPE.

### Their diagnosis, and why it is not automatically ours

Their blocker was a `STR2MMIO error=8` — a **DMA** error — and they still got
76 % of a frame delivered to userspace with visible scene content. Fix was 2x2
binning; the confirming evidence was that Windows' own `iacamera64` config never
pushes full resolution through stream2mmio.

Ours is a **CSIPHY** interrupt at 12.6 % with nothing ever delivered. "Works but
truncates" and "never completes" are different states. Binning is the right
response *if mission 14 says backpressure*, and only then — if nothing is
draining, a quarter-rate fill into a FIFO nobody empties still fills.

### Their C-PHY retraction does not transfer

They concluded IMX681 is D-PHY, on the grounds that reading `0x0111 = 0x03`
during streaming was circular — their own init wrote it. Fair in general. For
this machine:

- their `0x03` came from a ported driver; **ours came from the SP11 vendor blob**
- `Csi2PhaseNumOfLanes = 1` at 5,485,700 kbps. **One lane at 5.49 Gbps is not
  physically D-PHY** (spec tops out at 2.5 Gbps/lane, 4.5 in the newest
  revision). As one C-PHY trio at 2400 MSps it is ordinary.
- **The whole chain agrees on one trio, and it is not an accident** (mission
  17). DT `imx681_ep: data-lanes = <1>` and `csiphy2_ep: data-lanes = <0>` are
  one-element lists → `lane_cnt = 1` → `camss-csid-680.c:209` writes
  `NUM_ACTIVE_LANES = 0`, which mission 16 read back as `CSI2_RX_CFG0 =
  0x01300000`. The sensor agrees: `0x0114 = 0x00` in all six mode tables. And
  Windows agrees: `Csi2PhaseNumOfLanes = 1`. **`NUM_ACTIVE_LANES = 0` is
  correct — do not "fix" it, and do not raise the DT to three lanes.** Doing so
  would diverge from Windows and desync the receiver from the sensor.
  Consequently the deferred `bus-type` work is narrower than it looks:
  set `bus-type`, drop the D-PHY-only `clock-lanes = <7>`, remove the
  probe-time D-PHY rejection in `camss.c`. **Lane count stays 1.**

  **VALUE CORRECTION (2026-08-09). C-PHY is `<1>`, not `<4>`.** Missions 17, 18
  and 19 and this document all said `bus-type = <4>`. From
  `include/dt-bindings/media/video-interfaces.h`:

  ```
  #define MEDIA_BUS_TYPE_CSI2_CPHY   1
  #define MEDIA_BUS_TYPE_CSI2_DPHY   4
  ```

  `<4>` is D-PHY. This would not have failed loudly:
  `camss_parse_endpoint_node()` *requires* D-PHY, so it would have accepted the
  value and the DT would simply have described a C-PHY link as D-PHY. Use
  `MEDIA_BUS_TYPE_CSI2_CPHY` by name, and add
  `#include <dt-bindings/media/video-interfaces.h>` to the dtsi.

  Note the enums are not interchangeable: the DT constant (`CSI2_CPHY = 1`) and
  the kernel-side `enum v4l2_mbus_type` (`V4L2_MBUS_CSI2_CPHY = 6`) number
  differently. Compare `vep.bus_type` against the **name**, never a literal.
- Windows' phase-value discriminator, §5 below
- 136,756 CRC-clean packets out of a receiver programmed C-PHY

Same die, different module wiring. Their SP10 is 2-lane D-PHY at 380.8 MHz.

**Honest gap:** every D-PHY run we did predates the rate fix. A D-PHY control at
corrected settings has never been run.

### Their PLL numbers, for cross-reference

| | `0x030D`/`0E`/`0F` | op_pre | op_mult | op_sys_clk |
|---|---|---|---|---|
| SP10 | `03 00 77` | 3 | 119 | 761.6 MHz |
| SP11-Intel | `03 01 2F` | 3 | 303 | 1939.2 MHz |
| **ours, modes 1-5** | `03 01 77` | 3 | **375** | **2400 MHz** |

Their `link_freq` is `op_sys_clk / 2`, which is correct for D-PHY and is exactly
the convention we wrongly inherited into a C-PHY driver.

---

## 5. Windows measurements (CsiTestMode)

Qualcomm's CSIPHY driver has a registry-gated diagnostic mode. Key:
`HKLM\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera`, value `CsiTestMode = 1`.
It dumps on device teardown. **No reboot is needed** — the driver reads the flag
at device-context creation and writes at teardown, and opening and closing a
capture app does both.

Four runs, all exported to `data/csitestmode-*.reg` / `.txt`, summarised in
`data/csitestmode-20260807.txt`:

```
Csi2DataRateKbps       5,485,700    identical across ALL FOUR configurations:
                                    video preview; photo preview + still;
                                    Camera app at 4032x3024; preview-free
                                    4032x3024 still
Csi2PhaseNumOfLanes    1
Csi2CommonStatus1/3/6/8  0          (one run: Status1 = 0x20)
CsidRxTotalPktsRcvd    559,179 / 920,115 / 9,977 / 55,524
CsidRxStatsEcc         0            zero on a WORKING link too -- not an instrument
CsidRxTotalCrcErrors   0
CsidRxStats            23           identical across a 65% difference in packet
                                    count, so not a traffic counter. Meaning unknown.
```

**The phase-value discriminator.** `Csi2PhaseCtrl0*`, `Csi2PhaseLnckCtrl0*` and
`Csi2PhasePhyMode` are written *only* inside `FUN_140006b50`, which returns
immediately unless `is3Phase == 0` — D-PHY only. A D-PHY teardown would leave
`PhaseCtrl0Default = 0x8e` and `PhasePhyMode = 1` or `2`. All four runs show
zeros, so the last teardown recorded was the C-PHY device every time. This also
rules out Windows Hello's IR sensor (which is D-PHY) contaminating the dump.
**Keep checking these — non-zero means the reading belongs to the IR camera.**

Windows advertises photo modes **4032x3024, 3840x2640, 3840x2160**, mapping onto
`imx681.c`'s `supported_modes[]` entries 0, 1 and 4/5. `3520x2640` and
`3660x2440` are not advertised.

---

## 6. Deliberately unresolved

Do not quietly close these; each was left open for a reason.

0. ~~**Mode 0's 504x382 RAW8 stream — the live hypothesis is a mode *class*.**~~
   **SOLVED, mission 17: `0x2000 = 0x01`.** One register, isolated by a
   single-bit bisect with a zero-byte control run first. 15,240,960 bytes =
   4032 x 3024 x 10/8, reproduced three times. The other three registers
   (`0x6a83`, `0x7e9b`, `0xdc3c`) were each tested alone and do nothing. Now
   in the mode table, not a parameter — commit `29bc8c549`.

   **This was also why every camera application showed a black window:**
   4032x3024 is the capture node's default format, so applications did not
   "happen to pick" the broken mode, they were handed it.

   **What `0x2000 = 0x02` means (mission 18, from the blob):** the 4032x3024
   table has **no resolution descriptor** in
   `com.surface.sensormodule.ffc_imx681.bin`. Five descriptors exist, each
   carrying its own crop origin and a RAW10 depth field; the u32 `4032` occurs
   exactly once in the whole 212 KB file and has none of that structure around
   it. Corroborated by `IMX681DeLoB35P3A5.json`, whose 20 `sensor -> image`
   entries list 4032x3024 only as an **output**, never as a sensor mode.
   `0x2000 = 0x02` marks a table Qualcomm's sensor library does not expose as
   a streaming resolution — Windows never streams it, which is why it shipped
   emitting a thumbnail and why nobody noticed.

   The historical detail follows because it explains the reasoning:
   Mission 17 compared every vendor register across all six recovered mode
   tables. The five ordinary full-frame modes are identical to each other on
   four addresses; `4032x3024` is the sole outlier on all four:

   ```
                    0x2000   0x6a83   0x7e9b   0xdc3c
   4032x3024         0x02     0x00     0x07     0x00
   the other five    0x01     0x03     0x02     0x01
   ```

   Every other difference (crop, PLL, output size) varies per mode. These four
   split one-against-five. `imx681.mode0_class` is a bitmask parameter
   (1/2/4/8, default 0 = off) that rewrites them to the other five modes'
   values so all sixteen combinations bisect without a rebuild.

   **Ruled out already:** the appended `0xE801-0xE899` block. It *is* the
   geometry — three 0x34-byte stream descriptors at `0xE800`/`0xE834`/`0xE868`
   whose first entry is literally 504 x 378 (`0x01F8` x `0x017A`), with crops
   dividing exactly by 8, 24 and 48 — but skipping it leaves the wire
   bit-identical and changes only the burst rate (2.96 → 10.03 Hz). Nothing
   else in the driver ever writes `0xE8xx`, so those descriptors sit at
   power-on defaults with the block gone. **The block describes the mode; it
   does not select it.** Do not re-run the 136-register bisect.

1. ~~**mode 0 PLL contradiction**~~ **RESOLVED, mission 15.** `op_sys_clk_div`
   was read back off the live sensor over CCI while streaming and is `0x0001`,
   killing the third candidate. Mode 0 really does run 1996.8 MSps =
   4,563,929 kbps, and no Windows run ever measured that — because Windows never
   streams mode 0 as a 12 MP mode. Matching the rate was tested
   (`cphy_datarate_kbps=4563929`, settle moved `0x22`→`0x26`) and mode 0 **still
   fails**, so the rate was never the cause.
2. ~~**Whether 4032x3024 is a true full-array read or an upscale — undetermined.**~~
   **ANSWERED, mission 18, and the answer is "both, depending on the OS".**

   Two image-forensic tests were tried and both were blind under positive
   control (`probes/jpeg-upscale-test.py`, `probes/jpeg-resample-test.py`) —
   JPEG quantisation noise fills the stop band and JPEG's 8-pixel block grid
   at 0.1250 c/s sits on the resampling peak at 0.1270. The question was
   settled from the blob instead, which the image tests could never have done.

   `IMX681DeLoB35P3A5.json` lists 20 `sensor_width/height -> image_width/height`
   entries. **4032x3024 appears only as an output**, produced from a
   `3520x2640` or `2880x2160` sensor read. It is never a sensor mode. So
   **Windows' 12 MP stills are upscaled.**

   And our capture is not. `0x0344..0x034b` read out columns 8..4039 one for
   one, and mission 17 measured 15,240,960 bytes of real image. **Linux gets a
   true 4032-column readout that Windows does not take.** Do not reopen this
   as an upscale question for our path.
3. **Burst rate 2.985 Hz vs a derived 6.00 fps** — a factor of two, in the *vt*
   PLL path this time. Either one burst per two frames, or `vt_pix_clk` carries
   the same doubling error `op_sys_clk` did.
4. ~~**382 is unexplained.**~~ **EXPLAINED, mission 15** — see §1. It is
   378 = 3024/8 subsampled lines plus 4 non-image packets, i.e. the entire
   504x382 RAW8 stream mode 0 actually emits. Not a fraction of a 12 MP frame.
   Invariant to the receiver rate (44/44 bursts at `4563929`), which is what
   ruled out a settle-timing artifact.
5. **CSIPHY `STATUS2 = 0x1b`** — no bit definitions. Windows names STATUS1/3/6/8
   and does not save STATUS2. Mapping is `byte[n] = STATUS n = 0x10b0 + 4n`.
   **Searched and closed as unanswerable from the blob (2026-08-07):** there is
   no decode for common STATUS2 anywhere in `qccammipicsi8380.sys`, and
   `CSIPhyWaitforRx` shows the driver's health decision does not use the common
   block at all — it polls the per-trio register at `trio_base + 0x158`, where
   **zero means healthy**. Sample that instead of chasing `0x1b`.

   **BASE CORRECTION.** An earlier version of this line said `0x0ace4358`. That
   is wrong and it is the dangerous kind of wrong: `0x0ace4000` is `csiphy0`
   from `hamoa.dtsi`, and this board does not enable it. Reading an unmapped
   address SoC-resets this machine with no panic path and no pstore record. The
   only CSIPHY here is **`0x0ace8000`**, so the trio-0 register is
   **`0x0ace8358`**. Established twice by independent routes: `/proc/iomem`
   (mission 15) and the DT source, where the sensor endpoint links to
   `csiphy2_ep` and `csiphy2@ace8000` (mission 17).

   **And non-zero there does not mean failure in our configuration.** Mission 16
   measured `0x00 -> 0x05 -> 0x0C` during a *successful* `3520x2640` capture.
   `0x0C` was previously treated as evidence the receiver had failed on mode 0;
   it is not a discriminator.
6. ~~**`3840x2160_1` produces zero bytes.**~~ **SOLVED, mission 19: its
   `LINE_LENGTH_PCK` is below a hard platform minimum.** Not a broken mode — a
   mode that is 224 counts short in one register.

   ```
   3840-wide minimum LLP = 5632      5631 fails, 5632 captures, bisected to ±1
   _1 shipped with        = 5408      224 under
   ```

   Repaired it keeps its short vblank and runs **1.9210x the frame rate of
   `_2`** at the same PLL — a genuine high-frame-rate 4K mode. Fixed in
   `4f548f23d`, not deleted. **`vblank = 58` was never involved**; the leading
   guess in mission 19 was wrong, and applying `_1`'s vertical timing alone to
   `_2` captures normally.

   **The repair needed frame-interval ops to be worth anything.** Both entries
   advertise 3840x2160 and `v4l2_find_nearest_size()` returns the first of equal
   error, so fixing the register alone left the mode exactly as unreachable.
   `imx681.c` now implements `enum/get/set_frame_interval`; set the format
   *then* the interval, never the other way round.

   ### The minimum-LLP rule — check a mode table without streaming it

   Measured on all five working modes, each threshold bisected to a single count
   and confirmed by a live readback:

   ```
   mode          width   min LLP   native LLP   ratio to width
   4032x3024      4032      5376        6752    1.33333 = 4/3     exact
   3840x2640      3840      5632        6752    1.46667 = 22/15   exact
   3840x2160      3840      5632        6752    1.46667 = 22/15   exact
   3660x2440      3660      5368        6752    1.46667 = 22/15   exact
   3520x2640      3520      5176        6752    1.47045           outlier
   ```

   - **Set by output width alone.** 3840x2640 and 3840x2160 share a threshold to
     the count despite different heights and frame lengths.
   - **Not signalling.** Through a failing capture: `0x210` zero throughout, ECC
     0, CRC 0, and `0x240` climbing at ~78,700 packets/s for 15 s — 1.2 M clean
     packets, against 2,285 for a successful capture. The sensor emits and the
     CSID receives; no buffer ever completes.
   - **The coefficient tracks the PLL** — mode 0 is the only mode with a
     different one (`op 2/208`) and the only one on 4/3.

   **Use it as a paper check:** `width x 22/15`, or `x 4/3` at mode 0's PLL.
   `_1` would have failed it without a capture.

   **3520x2640 is unexplained**, 13.33 counts above `width x 22/15`. Two things
   are eliminated: it is *not* a clock difference (it uses `link_freq_index = 1`
   like the rest; only mode 0 differs), and it is *not* affine in width —
   the slope 3660↔3840 is 1.46667 and 3520↔3840 is 1.42500, so no `a*width + b`
   fits all three. Falsified models on record, do not re-fit them: a two-point
   fit `width x 1.425 + 160` (predicted 5375 for 3660, actual 5368); fixed line
   time scaled by mode 0's vt_pix_clk (predicted 4731, actual 5376); link-rate
   scaling (predicted 5686). The open test is to synthesise a sixth width that
   is a multiple of 15 — 3600 predicts exactly 5280 — and see whether it lands.

   `{0x0368, 0x01}` was the suspect and is **cleared** (mission 18): applied to
   the *working* mode via `reg_patch`, with the write confirmed in dmesg, the
   mode still captured 10,368,000 bytes three times. That is a negative by
   construction — it shows `0x0368` is not *sufficient* to break a healthy mode,
   not that it is inert inside `_1`.

   Diffing the decoded tables (not the blob — its container records are not
   length-aligned and a fixed-offset diff is pure noise) gives **seven**
   registers, not the four recorded earlier:

   ```
                    _1      _2
   0x022a/0x022b   2210    3546
   0x033e/0x033f   2218    3554
   0x0342/0x0343   5408    6752     LINE_LENGTH_PCK
   0x0368          0x01    0x00     cleared
   ```

   **Two corrections to mission 17's account.** It reported `_1` as holding
   `6752 x 3554`; it is the other way round — **`_1` is the short one**. And
   2.0006 is not a ratio between registers, it is the ratio of the *products*
   (`_2` 23,996,608 clocks against `_1` 11,994,944). The conclusion "`_1` is the
   double-rate variant" stands; the description that produced it did not.

   **What makes it decisive is the one-against-five shape**, the same shape as
   `0x2000` on mode 0:

   ```
   mode              LLP    0x033e   frame_clks      vblank   hblank
   3840x2160_1      5408      2218   11,994,944          58     1568
   3840x2160_2      6752      3554   23,996,608        1394     2912
   3840x2640        6752      3554   23,996,608
   3520x2640        6752      3554   23,996,608
   3660x2440        6752      3554   23,996,608
   4032x3024        6752      3554   23,996,608
   ```

   Every working mode has identical timing. With `0x0368` cleared, **the timing
   is the fault by elimination.** Mission 19 bisects it on the working mode
   (all six registers, then vertical alone, then horizontal alone). Leading
   guess is `vblank = 58` — legal for the sensor (`VBLANK_MIN = 4`) but ~24x
   less frame-end slack than any working mode, and the binding constraint may be
   the CSID's rather than the sensor's. **If `_1`'s full register set applied to
   `_2` still captures, nothing in the table distinguishes them and `_1` should
   be deleted rather than repaired.**

---

## 7. Tooling that now exists

| path | what it does |
|---|---|
| `tools/sp11-csitestmode.ps1` | `on` / `read` / `off` for the Windows diagnostic. `read` exports `.reg` + `.txt` **before** printing; `off` refuses without an export on disk and cleans up the empty `Qualcomm` parent |
| `probes/CaptureNoPreview/` | .NET 10 app driving `Windows.Media.Capture`. Captures a still with **no preview**, selects by video profile, enumerates every profile and pin |
| `tools/sp11-install-module.sh` | Safe module installer. Skips volumes already mounted — WSL's own system distro is a 1 TB ext4 volume that matched the "large ext4" heuristic |
| `tools/sp11-disk.ps1` | T7 handoff. Flushes volume caches before offlining |
| `probes/gen-camss-cphy-patch.py` | Single source of truth for the PHY patch. `late_patches()` is idempotent; add new steps there, not to a second list |
| `tools/artifact-to-pdf.ps1` | Artifact fragment to paginated PDF |

### Ghidra

`C:\Tools\ghidra-proj\SurfaceCam.gpr`. Only one server can hold the project
lock; stop it before any `analyzeHeadless` import and delete
`SurfaceCam.lock` / `.lock~` if one was killed.

| program | port / launcher | contents |
|---|---|---|
| `qccammipicsi8380.sys` | 8098, `start-mipicsi-server.bat` | CSIPHY: lane tables, settle counts, reset sequences, ISR |
| `qccamisp8380.sys` | 8099, `start-isp-server.bat` | **CSID + IFE.** Found 2026-08-07 |

`qccamisp8380.sys` was mined on 2026-08-07 — results in
`data/csid-irq-decode-x1e80100.txt`. Its strings name
`CamZ\Core\IFEDriverV3\csid\src\csid_full_hal.c` and it carries:

- `IFE Overflow IRQ on Stats/RDI/Image, ifeOverflowStatus = 0x%x`
- per-path enables, `CSID%d: Enabling CSID RDI0.` through `RDI4`
- an ISR decoding `ippIrqStatus`, `rdiIrqStatus`, `rxIrqStatus`, `topIrqStatus`,
  `bufDoneIrqStatus`
- the complete IFE acquire structure: `Lane type (dphy/cphy)`,
  `Active lane number`, `Virtual Channel`, `Data Type`,
  `Number of Valid VCDT`, `Input height in lines`, `Sensor output clock`,
  `Binning Config`, `HBI Count`

It was found by searching the DriverStore for `CsidRxTotalPktsRcvd`, which
`qccammipicsi8380.sys` does **not** contain. `data/bin/` is gitignored; copy the
binary back from
`C:\Windows\System32\DriverStore\FileRepository\qccamisp8380.inf_arm64_*\`.

---

## 8. Gotchas worth not re-deriving

**PowerShell**

- Never name a variable `$args` — automatic variable; a splat of it expands to
  nothing and the command runs with no arguments, silently.
- Launch browsers with `Start-Process -Wait -PassThru`, not `&`. The call
  operator returns instantly with `$LASTEXITCODE` unset and never starts them.
- `Get-Content` needs `-Encoding UTF8`. PS 5.1 falls back to the ANSI codepage
  on a BOM-less file and double-encodes on write.
- Pass multi-line strings to native commands via a file (`git commit -F`), not a
  here-string — embedded double quotes get re-parsed.
- Piping `Format-Table` output through `Select-Object` throws
  `GroupEndData ... not valid or not in the correct sequence`.

**WSL**

- Write script files and invoke them; inline `bash -c` mangles quoting.
- Use the Write tool, not a Bash heredoc, to create them.

**Kernel build**

- **`make drivers/foo/` does not produce `.ko` files.** It stops at objects, so
  `modinfo` still reports the previous module and a stale parm list. `make
  <path>/foo.ko` fails modpost (it regenerates `Module.symvers` from that module
  alone, so every external symbol comes back undefined). The one that works is
  plain `make modules`.
- **vermagic's trailing `+` is not about a dirty tree.** `scripts/setlocalversion`
  appends it whenever the environment variable `LOCALVERSION` is *unset*; setting
  it to the empty string suppresses it. `.scmversion` does nothing — this kernel's
  `setlocalversion` no longer reads it. Build with `LOCALVERSION=` exported, and
  delete `include/config/kernel.release` first, because `make modules` alone will
  not regenerate `UTS_RELEASE`. Target is `7.1.3-sp11-stockcfg-gf2cc827b6b89`,
  no plus.
- The default WSL user is `lain`, not root. `/root/sp11` reads fine and writes
  fail; use `wsl -u root`.

**General**

- Verify by exit status or by reading content back, never by whether a file
  exists. A stale output masked two failed PDF renders before a guard went in.
- An idempotency guard must match the thing it guards. A `mode0_e8xx` param was
  silently skipped because an earlier step in the same script had put that string
  in a *comment*; the code referencing it was added anyway and only the build
  caught it. Guard on the declaration, not the name.
- Check `git status` in `wt-cfg` before building. One source file was found
  truncated to zero mid-session; cause never established, restored from git.

---

## 9. Ground rules in force

1. Never report a failed write without a positive control in the same run.
2. i2c adapter numbers are not stable across boots; identify by the EEPROM at `0x50`.
3. The bootloader goes on the T7, never the internal NVMe.
4. Verify a build by `make`'s exit status, never by whether the `.o` exists.
5. An unconditional log line at the decision point beats a correct patch.
6. Before concluding a configuration does not work, check the code implementing
   it is reachable and the instrument measuring it is switched on.
7. When a run produces nothing, check how long it took before concluding what it means.
8. A log line that prints a computed value is not a measurement. Read registers back.
9. When you read back matters. Say which instrument and at what point in the cycle.
10. A `#define` is not evidence that anything uses it.
11. Neither is a function body. `phy_qcom_mipi_csi2_reset()` is complete,
    correctly named, in the ops struct, and never called.
12. A counter that reads zero in a run where it could not have read anything
    else has not measured anything.
13. A value being in range is not evidence it is right. Prefer a number the
    other side states outright over one derived through an unverified
    assumption — and when one is available for the asking, ask.
14. Reproducibility to the digit is a measurement.
15. A null result from an instrument that could not have resolved the event is
    not evidence.
16. The gate is not suspended for measurements *about* the instrument. A timing
    test is still a read. Proposed by the Linux side after an ungated `devmem`
    on a suspended CSID reset the SoC — "I was only measuring fork overhead" is
    not an exemption. Accepted.
17. A register that reads zero may be a command register, not a level register.
    Before concluding a write never happened, check whether the sibling driver
    writes on the clear path: `camss-csid-gen3.c` does not and `camss-csid-680.c`
    does, which is how `REG_UPDATE_CMD` was identified as write-1-to-command.
    Confirmed by measurement in mission 15: `0x00100010` written, reads back
    `0x00000000` immediately.
18. **A success metric you have never seen succeed is a hypothesis, not a
    metric.** `vfe0 == 0` was the definition of failure for thirteen missions and
    reads 0 on a successful capture too. Nobody checked what it does when things
    work, because things had never worked — the one reading that could have
    invalidated it was the one reading unavailable. When a project is organised
    around a number that is always the same, that number needs independent
    confirmation that it can ever be different. (Proposed by the Linux side,
    mission 15. The best rule on this list.)

Standing constraints: PRs only in `lain3d/*`; bootloader never on the internal
NVMe; the baseline ISO is never overwritten; BitLocker recovery password never
printed; WiFi credentials only on the user's own drive; the debug branch's
placeholder `reg` must never reach the PR series; root will **not** move to the
internal NVMe (closed, do not re-raise).

---

## 10. Housekeeping state

- Both T7 FAT volumes were **NOT Dirty** at the last handback with no Linux boot
  between. The `Write-VolumeCache` fix in `sp11-disk.ps1` works; the recurring
  dirty bit is the Linux side's `/boot/efi` being mounted rw across its silent
  restarts, which the Linux agent has confirmed as theirs.
- The Linux box restarts silently every 1-2 minutes, no panic, nothing in
  pstore. Root is `/dev/sda5` on the USB-attached T7. Leading suspect matches
  this project's confirmed earlier finding that an ADSP restart takes the USB-C
  disk down with it (`charger_pd` lives on the ADSP) — a kernel-command-line
  question about `q6v5_pas`, not a build. Not yet investigated.
- Windows registry is clean: the `CsiTestMode` key and its empty `Qualcomm`
  parent were both removed after the last read.
- Three SoC resets total for the project, none since mission 16.

---

## 11. Adjacent: hardware video encode is one DT property away

Not camera work, but it surfaced from a camera symptom and it is cheap enough
to be worth not re-deriving.

**Symptom (mission 18).** GNOME Snapshot's *recordings* look far worse than its
preview. The camera is not involved: `vp8enc`'s GStreamer default
`target-bitrate` is 256000 — 256 kbit/s for 1080p30 — and Snapshot exposes no
setting. 940 KB for 12.62 s against 8 MB via `gst-launch` at 8 Mbit/s, with no
dropped frames either way. Workaround is `tools/native/sp11-record.sh`.

That is software encoding, because the hardware codec never binds.

**Why it never binds — not missing driver support, and not missing firmware:**

```
iris: video-codec@aa00000 {                          hamoa.dtsi:5532
    compatible = "qcom,x1e80100-iris", "qcom,sm8550-iris";
    /*
     * IRIS firmware is signed by vendors, only
     * enable on boards where the proper signed firmware
     * is available.
     */
    status = "disabled";
};
```

`iris` has no `x1e80100` platform entry and does not need one — it matches the
`qcom,sm8550-iris` fallback → `sm8550_data`
(`fwname = "qcom/vpu/vpu30_p4.mbn"`, `pas_id = 9`), and
`CONFIG_VIDEO_QCOM_IRIS=m` is already set. **The node is disabled at SoC level
by design, pending per-board signed firmware.**

**Upstream already shows the pattern on another X1E80100 laptop**, and it names
the same file we have:

```
&iris {              hamoa-lenovo-ideacentre-mini-01q8x10.dts:671
	firmware-name = "qcom/x1e80100/LENOVO/91B6/qcvss8380.mbn";
	status = "okay";
};
```

`iris_firmware.c:131` reads `firmware-name` from the DT and overrides the
built-in `fwname`, so **no driver change is needed**. The Denali version is four
lines in `x1e80100-microsoft-denali-oled.dts`, using the same
`qcom/x1e80100/microsoft/Denali/` convention that file already uses for the zap
shader, ADSP and CDSP.

**The firmware exists in the Windows image** and is staged at
`E:\sp11-relay\mission19-artifacts\`:

```
qcvss8380.mbn    2,323,048 B   SHA256 2e37684e...5ef85ebc
qcav1e8380.mbn   4,607,848 B   AV1 encoder, separate block, no DT node — parked
```

Source: `DriverStore\FileRepository\qcdx8380.inf_arm64_8053adc44985505a\`.
Verified rather than assumed: ELF with `e_machine = 0x5e` (EM_QDSP6/Hexagon),
strings include `venus_firmware.c`, `venusCoreController.c`,
`venus_venc_codec_h264.c`, `venus_venc_codec_h265.c`.

**WORKS, confirmed mission 19.** iris bound on the first boot of `integ47`, no
`qcom_scm_pas` failure — **the Microsoft-signed blob authenticates on this
device at `pas_id = 9`**, which was the one thing unverifiable from Windows.

```
video4linux/video0   qcom-iris-decoder      H264 HEVC VP90 AV01
video4linux/video1   qcom-iris-encoder      H264 HEVC
150 frames of 1080p encoded in 0.29 s  (~517 fps)  -- not a CPU encoder
```

Three things worth carrying forward:

- **On success there are no iris lines in dmesg either.** The only mention in
  the whole boot is `Adding to iommu group 12`. The binding is visible in sysfs,
  not dmesg — a success criterion built on dmesg silence is rule 18 all over
  again.
- **The camss video nodes shifted** `/dev/video0..15` → `/dev/video2..17`,
  because iris registers first. libcamera and the media-graph-following harness
  are unaffected; anything hardcoding `video0` for the camera now points at the
  iris decoder.
- **`vainfo` confirms no VA-API driver exists** for this device
  (`msm_drv_video.so` absent), so browsers gain nothing. Predicted, now
  measured.

**Encoder defect, ours-ish:** `V4L2_CID_MPEG_VIDEO_BITRATE` is honoured as bits
per **frame**, not per second — constant bits/frame across 15/30/60 fps, matching
the requested value to 0.05 %. `iris_set_bitrate()` passes the value to
`HFI_PROP_TOTAL_BITRATE` with no scaling at all, so the firmware is consuming it
per frame. **Not patched:** dividing by frame rate assumes firmware semantics
inferred from one encoder, and a half-fix produces recordings at 1/30 the
requested bitrate. The discriminating experiment is to set a real frame rate via
CAPTURE `S_PARM` and re-measure bits/frame.

Two defects cleared as *not* ours: GStreamer fixates the encoder caps to
Baseline/level 1 on 1080p (iris's own defaults are High/level 5), and ffmpeg's
`v4l2_buffer_swframe_to_buf()` over-reads because it takes plane height from the
driver's format (1088) and the pointer from the AVFrame (1080) — still present
in ffmpeg master, patch written and validated in `patches/ffmpeg/`.

**Shipped 2026-08-09 as UKI `integ47`.** The camera `bus-type` commit was
deliberately *not* bundled with it: the value was wrong (see §4), mission 19 is
pending against the current `qcom-camss.ko`, and one change per boot keeps a bad
boot to one suspect.

```
DTB delta, phandle-normalised, three lines and nothing else:
-  status = "disabled";
+  status = "okay";
+  firmware-name = "qcom/x1e80100/microsoft/Denali/qcvss8380.mbn";

firmware  /lib/firmware/.../Denali/qcvss8380.mbn   hash-verified after copy
UKI       BOOTAA64-integ47-iris.efi   sha256 CEBE48C0...AEF71FDA
          .linux/.initrd/.cmdline byte-identical to integ46
rollback  C:\sp11-stage\BOOTAA64-integ46-KNOWN-GOOD.efi
dt-audit  0 BUG, 11 SUSPECT (all pre-existing, none the iris node)
```

**Headroom warning:** the new `.dtb` is 221,133 bytes against 221,184 of room
before `.linux`. **51 bytes left.** The next DT addition will not fit through
`sp11-patch-dtb.sh`; it will need a full UKI rebuild that relocates `.linux`
and `.initrd`.

Still unverifiable from Windows: whether this device's TrustZone accepts
`pas_id = 9` for the video subsystem. Failure mode would be
`qcom_scm_pas_auth_and_reset` erroring in
dmesg, which is clean, not a reset.

**NPU, pen and touchscreen are already solved** in
`denisix/ubuntu-surface-pro-11` (the base of `lain3d/surface-pro-11-linux`) and
merely not installed on this root — see its `NPU.md`, `PEN.md`,
`TOUCHSCREEN.md`. Do not re-derive them.
