# Front camera bring-up — state at 2026-08-06 18:30

Read this first when picking the camera thread back up. `docs/camera-sensors.md`
holds the firmware archaeology; this holds the current state, what is installed,
what has been eliminated, and where the one open question sits.

## Where it stands, in one paragraph

The Sony IMX681 front camera **probes, identifies itself over I²C, and builds a
complete camss pipeline**. It is programmed exactly as the recovered vendor
tables say to program it, reports itself streaming, and **emits nothing** —
`acb6000.isp_msm_vfe0` has taken zero interrupts in every configuration tried.
Everything on the I²C bus now reproduces the vendor sequence, which argued the
missing piece was not an I²C write. **It is not — it is which physical layer the
I²C writes select.** See the next section.

## The lead: the vendor programs this sensor for C-PHY, and we built D-PHY

Found on 2026-08-06 by re-reading the recovered init table rather than the
hardware. The init sequence contains one write that had never been looked at:

```
{0x0111, 0x03},
```

`0x0111` is the CCS/SMIA **`CSI_SIGNALLING_MODE`** register, and the constants
are in mainline `drivers/media/i2c/ccs/ccs-regs.h`:

```c
#define CCS_R_CSI_SIGNALING_MODE          CCI_REG8(0x0111)
#define CCS_CSI_SIGNALING_MODE_CSI_2_DPHY 2U
#define CCS_CSI_SIGNALING_MODE_CSI_2_CPHY 3U
```

**The blob puts the IMX681 in CSI-2 C-PHY mode. Our DT, our CSIPHY and our
driver are D-PHY end to end.** A sensor emitting C-PHY trio signalling into a
receiver decoding D-PHY produces exactly what we see: every register correct,
`mode_select = 1`, and not one start-of-frame at the receiver.

### Why this reading is trusted

The rest of the `0x011x` block in the same table is CCS-conformant, and three of
its four registers have been **read back off the part** as written:

| reg | CCS meaning | blob writes | reads back |
|---|---|---|---|
| `0x0110` | `CSI_CHANNEL_IDENTIFIER` | `0x00` | — |
| **`0x0111`** | **`CSI_SIGNALLING_MODE`** | **`0x03` = C-PHY** | **not yet read** |
| `0x0112/3` | `CSI_DATA_FORMAT` | `0x0a0a` | `0x0a0a` ✓ |
| `0x0114` | `CSI_LANE_MODE` | `0x00` | `0x0000` ✓ |

So writes in this block land and stick. `0x0111` sitting between two registers
that demonstrably behave per spec is the argument that it does too — unlike
`0x0340` and `0x0202`, which are elsewhere in the map and were caught by exactly
this kind of readback.

It also makes sense of a detail that has looked odd since the beginning: **a
12 MP sensor on a single lane.** One D-PHY lane is a strange way to wire a 12 MP
part. One **C-PHY trio** is completely ordinary for a front camera — three wires
instead of four, no separate clock lane, and ~2.28 bits per symbol. `0x0114 = 0`
and `laneAssign = 0x0000` describe a single trio just as naturally as a single
lane.

### Second, independent route: Windows agrees

Found later the same afternoon in Ghidra, by a completely different path — the
platform side, not the sensor side.

`surfacecamfrontsensor8380.sys` logs a per-sensor CSIPHY config struct. Its
fields, and the payload-size check of **0x18**, recover the layout exactly:

```c
struct CSIPhyInfo {          /* 24 bytes, checked against the size test */
    u16 laneMask;            /* +0x00 */
    u16 laneAssign;          /* +0x02 */
    u8  CSIPHY3Phase;        /* +0x04  <- D-PHY / C-PHY selector */
    u8  comboMode;           /* +0x05 */
    u8  laneCount;           /* +0x06 */
    u8  secureMode;          /* +0x07 */
    u64 settleTimeNS;        /* +0x08 */
    u64 dataRate;            /* +0x10 */
};
```

`CamX_ImageSensorData_CreateCSIPHYConfig` in `QcDeviceMFT8380.dll` fills it, and
takes `is3Phase`, `laneCount` and `settleTimeNS` straight out of the per-mode
sensor data. So the value is per-sensor firmware data, not a driver constant.

That data is the `resolutionData` record in the sensor-module blob: a flat array
of **252-byte per-mode structs**. `probes/chromatix_resdata.py` decodes it. Two
columns matter:

| sensor | `laneCount` col[20] | `is3Phase` col[24] | PHY known independently? |
|---|---|---|---|
| **front IMX681 (this SKU)** | **1** | **1** | — |
| IR VD55G0 | 1 | 0 | — |
| front OV02C10 (other SKU) | 2 | 0 | **yes, D-PHY** |
| rear OV13858 | 4 | 0 | **yes, D-PHY** |

**The `laneCount` column is what makes the decode trustworthy** — it reads
1 / 2 / 4 and the last two are known from mainline `ov13858.c`, from `laneAssign`
(`0x10`, `0x3210`) in the same blobs, and from `x1-dell-thena.dtsi` wiring the
OV02C10 as `data-lanes = <1 2>`. Three parts agreeing pins the layout.

**The IR sensor is what makes col[24] an identification rather than a guess.**
It is *also* one lane and *also* the always-on Windows-Hello part, so neither
"1 lane" nor "always on" explains the column. Of the four sensors, exactly one
has it set, and it is the one whose init table writes `CSI_SIGNALLING_MODE = 3`.

Ghidra names are saved in the project: `CamX_ImageSensorData_CreateCSIPHYConfig`,
`CamX_SensorNode_AcquireResources`, `CamX_IFENode_SetupCSIPHYInputResource`.

**Honest limits.** col[24]'s identity is inferred from its signature, not traced
through the blob parser. And `CreateCSIPHYConfig` builds `laneMask` with a
clock-lane bit (`mask |= 2`) whenever `comboMode == 0` — a D-PHY-shaped
construction, and the one piece of evidence pointing the other way. It is
generic code shared by every sensor, so it is weak, but it is not nothing.

### The cheap decisive test — no reboot, no build

Power the sensor with nothing programmed, read `0x0111`, then read it again
while the driver has it streaming:

- **`0x02` → `0x03`** — the write lands and changes the signalling mode. C-PHY
  confirmed, and the D-PHY receiver is the fault.
- **`0x03` → `0x03`** — inconclusive; the part may simply default to C-PHY.
- **anything → `0x02`** — the write is discarded like `0x0340`. Lead dies.

### What the fix would be

Not yet built — the readback comes first.

| where | change |
|---|---|
| `&csiphy2` | `phy-type = <PHY_TYPE_CPHY>` |
| csiphy endpoint | drop `clock-lanes` (C-PHY has none), `bus-type = <1>` |
| sensor endpoint | `bus-type = <1>` (`MEDIA_BUS_TYPE_CSI2_CPHY`) |
| `link-frequencies` | **open** — for C-PHY the v4l2 convention is symbol rate, not the D-PHY DDR clock. Must be checked against `csiphy_settle_cnt_calc()` before the values below are reused. |

Whether mainline camss on x1e80100 honours `phy-type` on the CSIPHY node or
takes the mode from the endpoint's `bus-type` needs checking in the tree — that
is a kernel-source question, not a hardware one.

## Proven on hardware

| | |
|---|---|
| Part identity | `sensor_model_id` (CCS `0x0016`) = **`0x0681`** |
| I²C address | `0x10` on `cci1 i2c-bus@1`, the always-on bus; `0x50` on the same bus is the module EEPROM, which is what confirms the bus |
| CSI link | 1 data lane (`0x0114 = 0`), RAW10 (`0x0112/3 = 0x0a0a`) |
| MCLK | 19.2 MHz — `cam_cc_mclk4_clk en=1 rate=19200000` read from the clock tree, not inferred from the register |
| Media graph | `imx681 1-0010 → msm_csiphy2 → msm_csid0 → msm_vfe0_rdi0 → /dev/video0`, all links `ENABLED` |
| Frame geometry | `frame_length 3554`, `line_length_pck 6752`, `4032×3024` — all read back off the part |
| Privacy LED | **gpio225**, established as a 2×2: lights only when 225 is high **and** the camera is powered |

## The register map is not SMIA-standard

This is the single most useful thing learned today, and it cost two rounds.

| purpose | this part | SMIA/CCS standard |
|---|---|---|
| frame length | **`0x033e`** | `0x0340` — ACKs writes, discards them, reads 0 |
| exposure | **`0x022a`** | `0x0202` — read-only mirror, trails the live value by 8 |
| stream on/off | `0x0100` | same |
| grouped hold | `0x0104` | same |

Found by reading the blob, not by guessing: `0x033e` is the only
geometry-adjacent value that tracks the one fast mode; `0x022a` is `0x033e − 8`
in every mode table, which is SMIA's `coarse_integration_time = frame_length −
margin` exactly; and the frame rates come out as integers a mis-identified pair
would not produce. Redone from the PLL dividers **read off the streaming part**
rather than inferred:

| mode | VT PLL | `vt_sys`/`vt_pix` | `vt_pix_clk` | `line × frame` | fps |
|---|---|---|---|---|---|
| 4032×3024 | 19.2/2 × 180 = 1728 | 2 / 6 | 144.0 MHz | 6752 × 3554 | **6.0008** |
| 3840×2160 | 19.2/2 × 225 = 2160 | 2 / 6 | 180.0 MHz | 5408 × 2218 | **15.006** |

Both land within 0.02 % of an integer. (An earlier note gave the second as
12.00 fps, from a link-rate derivation rather than the VT clock; 15 is the
correct figure and the conclusion is unchanged.)

The calibration that makes the negative meaningful: no table writes `0x0340`,
while the same extractor recovers `0x380e/0x380f` for the OV13858 where mainline
can check the values.

## Eliminated, with the evidence

Each of these was a live hypothesis and is now closed. Do not re-open without new
evidence.

| hypothesis | how it died |
|---|---|
| A third rail (DVDD) is missing | `_RES` blobs: CAMF votes **two** rails (LDO3_M 1.8, LDO7_B 2.8). CAMS and CAMI each get a core rail; the front one does not. Windows powers it with exactly what our DT declares. |
| Reset gpio237 was never corroborated | It is in `CAMF_RES_MSHW0490.bin` as `TLMMGPIO 0xed`, in the power-on sequence. Absent from the DSDT for *all three* sensors, so the DSDT search was looking in the wrong file. `x1-dell-thena.dtsi` uses the same pin. |
| MCLK is not actually running | Clock tree read during streaming: `cam_cc_mclk4_clk en=1 prep=1 rate=19200000 hw_en=Y`. |
| camss is misconfigured or dropping frames | dyndbg, 43 callsites: `VFE:0 HW Version 3.0.2`, `CSID:0 3.0.0`, `RDI0 WM:24 width 4032 height 3024 stride 5040` — stride correct for packed RAW10. No errors, no overflow. Zero interrupts means nothing to drop. |
| The missing grouped parameter hold | The hold **works** at the vendor's moment (freshly powered, before mode programming). But replaying all 566 driver writes onto a live pipeline **with and without** the hold, in the same run, gave identical results: `vfe0` delta 0 both ways. |
| `frame_length_lines = 0` is the blocker | It was the pre-`handler_setup` value. It now reads 3554 and nothing changed. |
| The privacy LED is an interlock | Driving gpio225 high during a stream lights the LED and produces no frame. It is an indicator. |
| `link-frequencies` are wrong, so the PHY settle count is wrong | Computed from the mode tables' own PLL dividers and confirmed against the values read off the streaming part. Full-res: `op_pre_pll_div=2`, `op_pll_multiplier=208` → 19.2/2 × 208 = 1996.8 Mbps → **998.4 MHz**. All five cropped modes: `3`, `375` → 19.2/3 × 375 = 2400 → **1200 MHz**. Both DT values reproduce exactly. |
| The vfe0 interrupt is misrouted, so frames arrive unseen | `/proc/interrupts` gives vfe0 hwirq **497** and csid0 **496**. ACPI declares VFE0's GSIVs as 488, 319, **495–501**, 721, 796, 797 — both fall inside it. And csid0 at 496 demonstrably fires, once per `STREAMON`. Adjacent line, same block, one of them working. |
| The Sony manufacturer-access unlock is missing | The init table opens `{0x30eb,0x05} {0x30eb,0x0c} {0x300a,0xff} {0x300b,0xff}` and then `{0x3532,0xff} {0x3533,0xff}` — the same `0xff` pair idiom for a second range. Not IMX219's 6-write form, but complete on its own terms, and the table goes on to write `0x3xxx`/`0x7xxx` freely. |

## Installed right now

```
ESP  BOOTAA64.EFI = BOOTAA64-integ46-ledname.efi
     43739D529D55A0282C35C41006FB2EAF4074FBB5A4D42E4D7C7D4022E65E41C2

     integ45  E098DABF...330CED8F   + privacy LED node (no led-names — inert)
     integ44  FA317B1E...96B5E46B   + camss/csiphy2 wiring
     integ40  C30EBF9B...509EC12C   BASELINE, no camera DT. Rollback target.
     integ43  9684656D...19BF9A53   POISONED, do not boot. Built in the wrong
                                    worktree; deleted ramoops, PCIe PERST#/WAKE#
                                    and the USB4 routers' iommus/power-domains.
```

Every integ4x above differs from integ40 in `.dtb` **only** — `.cmdline`,
`.linux` and `.initrd` are byte-identical, verified each time. So swapping
between them is always a clean single-variable experiment, and rollback is one
file copy.

`imx681.ko` on the T7 carries the `0x033e`/`0x022a` map, the chip-ID check, the
labelled state dump and the vblank fix. vermagic
`7.1.3-sp11-stockcfg-gf2cc827b6b89`.

### Operational limit worth knowing before it bites

**The DTB has 107 bytes of headroom left.** `.dtb` is 221077 bytes and `.linux`
starts at 221184. `tools/sp11-patch-dtb.sh` refuses rather than overrunning, so
the next DT addition of any size needs a **full UKI rebuild** that relocates
`.linux` and `.initrd` — `tools/sp11-rebuild-uki.sh` — not a splice.

## Branches

| branch | PR | contents |
|---|---|---|
| `integration/camera` | — | everything, on top of `debug/ramoops`. This is what to build. |
| `camera/imx681` | #4 | driver, with a real chip-ID check. **No debug code.** |
| `camera/denali-pm8010` | #2 | PM8010 camera PMIC rails |
| `camera/ov13858-dt` | #1 | rear sensor DT probing |
| `debug/imx681-addr-scan` | #5 | bus scan + state dump, marked do-not-merge |

`integration/camera` sits on `debug/ramoops`, whose parent `f2cc827b6` is the
commit the running kernel's vermagic names — so the installed `.linux` stays
valid and only the DTB and module need rebuilding.

Debug instrumentation must not reach the `camera/*` branches.

## The one open question

**Is the sensor talking C-PHY into a D-PHY receiver?** See the second section.
The register-level question that framed this all afternoon — *what does Windows
do between power-on and stream-on that is not an I²C write?* — turns out to have
been the wrong shape. It was an I²C write, one nobody had decoded.

Two things settle it, in this order:

1. **Read `0x0111` off the part**, fresh-powered and again while streaming. No
   reboot, no build. Decision table in the C-PHY section above.
2. ~~Ghidra on `QcDeviceMFT8380.dll`~~ — **done**, see the section above. It
   answered the question rather than the one it was opened for: the Windows
   stack carries an explicit per-sensor D-PHY/C-PHY selector and sets it for
   this part alone.

The blob's own `isComboMode` is **0** in all three sensor blobs and
`cphyDphyComboMode` is stored in none of them, so those fields do not decide it.
Qualcomm's "combo mode" means the PHY carrying mixed D-PHY and C-PHY links, not
"this sensor is C-PHY" — checked, and recorded here so it is not re-checked.

### Still open in Ghidra, and worth having before the C-PHY build

`CreateCSIPHYConfig` also reads **`settleTimeNS`** from the same per-mode struct
and computes **`dataRate`** as

```
dataRate = ((clk + clk * marginPercent / 100) * bitsPerPixel) / laneCount
```

Both are values camss otherwise derives itself — `csiphy_settle_cnt_calc()` from
`link_freq`, and the link rate from the DT. Reading Windows' numbers straight out
of the blob would turn `link-frequencies` under C-PHY from an open question into
a checked one. The columns are not identified yet; the same
`chromatix_resdata.py --columns` dump has them.

Still unsettled and untestable until a frame arrives: **Bayer order.** The driver
declares `SRGGB10_1X10` and it is a one-in-four guess — no
`colorFilterArrangement` exists in any of the three blobs. `/dev/video0` offers
packed `pRAA` and unpacked `BG10`; `tools/sp11-bayer.py` wants the unpacked one.

## How the two agents split

The Linux-side agent tests, measures and reports; the Windows side owns the UKI,
DTB and modules. Read-only probing and `tools/sp11-camera-test.sh` belong to the
Linux side, which has now caught four separate bugs in Windows-side work that way.
Briefs go in `E:\sp11-relay\TO-LINUX.md`, reports come back in `TO-WINDOWS.md`.

## Mistakes worth not repeating

1. **A UKI's DTB comes from one specific worktree.** Rebuilding integ40's DTB in
   the wrong one silently deleted four unrelated DT fixes and cost two failed
   boots. Prove byte-equality against the installed DTB before trusting a rebuild.
2. **Normalise phandles before diffing device trees.** Adding a node renumbers
   every later phandle. Reading the first 80 lines of an un-normalised diff is how
   those deletions got through.
3. **Never verify a build by checking the object file exists.** A stale `.o`
   makes a failed compile look fine; test `make`'s exit status. This let two
   non-compiling commits through.
4. **Annotations do not reach `.config`.** `CONFIG_VIDEO_IMX681` was annotated
   and stayed off in every booted kernel for four days.
5. **camss enumerates a video node's pixelformats from the connected pad's mbus
   code**, so formats must be walked along the pipe with `media-ctl -V` before
   touching the video node.
6. **A diagnostic that can hang is worse than one that reports nothing** —
   `v4l2-ctl --stream-mmap` blocks forever on exactly the failure being chased.
7. **Never report a failed write without a positive control in the same run.**
   Established by the Linux side; it is doctrine now.

---

# C-PHY confirmed on hardware, and the register tables recovered (2026-08-06 evening)

## The readback settles it

Mission 4, measured on the part:

| | |
|---|---|
| A — fresh power, nothing programmed | `0x0111 = 0x02` (D-PHY, the part's reset default) |
| B — driver streaming, after the init table | `0x0111 = 0x03` (C-PHY) |

Plus a control in the same run that is better than a positive control:
`0x0114` moved `0x01 → 0x00` across the same boundary, so the `0x011x` block is
demonstrably writable *in that run*. The part is not C-PHY-only — the vendor
table deliberately moves it. **The D-PHY receiver is the fault.**

The privacy LED also works now, closing the last mission-3 item.

## This is a camss feature, not a DT patch

Checked in the tree by the Linux side, and it changes the plan:

- `camss_parse_endpoint_node()` **rejects** anything that is not
  `V4L2_MBUS_CSI2_DPHY` with `-EINVAL`. So `bus-type = <1>` does not enable
  C-PHY, it stops the sensor probing at all.
- **`phy-type` is not read anywhere in camss.** It is a generic `drivers/phy`
  binding and this is not a generic PHY provider. Our `&csiphy2` property is inert.
- There is **no C-PHY lane register table**. `lane_regs_x1e80100[]` is one flat
  D-PHY sequence. "3ph" in `camss-csiphy-3ph-1-0.c` is the PHY *hardware
  generation*, not a C-PHY code path.
- `csiphy_settle_cnt_calc()` is D-PHY by construction — `ui /= 2` is the DDR
  half-bit assumption and `85000 + 6*ui` is the D-PHY `T_HS_PREPARE` constant.
  Feeding it a C-PHY symbol rate gives an arbitrary number, not a close one.

## What Windows does, recovered — `qccammipicsi8380.sys`

This is the CSIPHY/CSID kernel driver, 104 KB. It is the piece that "cannot be
derived", and it is now in `data/csiphy-cphy-x1e80100.txt`.

**Settle count, C-PHY** — a 26-entry lookup, not a formula:

```c
msps = dataRate_bps / 2.28 / 1e6;        /* 2.28 bits per C-PHY symbol */
for (i = 0; i < 26; i++)
    if (msps < table[i].threshold) { settle = table[i].value; break; }
```

Thresholds run 500→3000 MSps in 100 MSps steps. For this sensor:

| mode | dataRate | symbol rate | settle |
|---|---|---|---|
| 4032×3024 | 1996.8 Mbps | 875.8 MSps | **0x40 (64)** |
| the five cropped modes | 2400 Mbps | 1052.6 MSps | **0x38 (56)** |

**Settle count, D-PHY** — and this is the cross-check that validates the decode,
because it reproduces mainline:

```c
settle = (int)((float)((int)((1000.0 / mbps) * 6.0) + 0x55) / 2.5) - 10;
                                  6 UI    +  85 ns    / 2.5 ns tick
```

`6*UI + 85` is exactly camss's `85000 + 6*ui` in ps. Same shape, differing only
in the tick and the constant offset — so the C-PHY branch beside it is being read
correctly.

**Lane masks**, from `CSIPhyRxLane`:

| | 1 | 2 | 3/4 |
|---|---|---|---|
| C-PHY (trios) | **0x02** | 0x0a | 0x2a |
| D-PHY (lanes) | 0x81 | 0x85 | — |

D-PHY 1 lane is `0x81` = clock bit 7 + lane 0. C-PHY 1 trio is `0x02` and carries
**no clock bit** — which retires the one piece of counter-evidence recorded
earlier, the `mask |= 2` in CamX's `CreateCSIPHYConfig`. Different layer,
different encoding; the KMD's mask is what reaches hardware.

**Per-frequency register tables** — the C-PHY counterpart of
`lane_regs_x1e80100[]`. Selected by data rate (`< 2.0 Gbps`, `< 2.5 Gbps`, …),
123 entries of `{u32 offset, u32 value, u32 flag}`. Per-lane blocks repeat at
**stride 0x400**, and C-PHY programs the odd lanes only — settle counts land at
`0x20c`, `0x60c`, `0xa0c`, i.e. ln1/ln3/ln5. **Our full-res mode's 1996.8 Mbps
selects the first table**, the one at `0x140011420`.

## What is left

A camss patch series: accept C-PHY bus-type, add the lane table above, add the
C-PHY settle lookup, and set CSID/VFE decode to match. None of it can be
validated in pieces — the link is dark until all of it is right.

One cheap intermediate the Linux side proposed and I agree with: patch **only**
the bus-type check and let it run the existing D-PHY lane table. No frame will
arrive, but if csiphy's ISR starts reporting *errors* where it reports nothing
today, that is independent confirmation the link is live and merely undecodable.
Silence would be worth knowing too. Two lines.

---

# The instrument was off, and the tables were wrong (2026-08-06 late)

Two missions' worth of results in one place, because they only make sense
together: mission 8 connected the CSIPHY interrupt and got a real answer, and
that answer only became readable after three errors in the recovered tables
were fixed.

## The interrupt had never been requested

The DT routes `GIC_SPI 479`. `phy-qcom-mipi-csi2-3ph-dphy.c` has
`phy_qcom_mipi_csi2_isr()`, and the ops struct wires it in as `.isr`. Nothing
ever called `platform_get_irq()` or `request_irq()`, so there was no line in
`/proc/interrupts` — and `lanes_enable()` masked every source at the end
regardless. Three pieces, none joined to each other, for seven missions.

I had used the empty `/proc/interrupts` as evidence twice before this. Both
times the absence meant something was disconnected, not something was silent.

## The trio is not dark

With the line connected, `hwirq 511` = `GIC_SPI 479 + 32`, exactly as routed.
Under forced C-PHY the PHY fires **~72 times a second for as long as the sensor
emits**, starting **3.2 ms after `mode_select = 1`**, and stops when it stops.
The control is inside the same run: 133 ms fully configured and fully unmasked
with the sensor not yet emitting produced **zero** interrupts.

"Nothing arrives at the PHY" is eliminated. `vfe0` is still 0 and no frame has
ever arrived.

## Three errors in the extraction, all in the same field or its neighbours

### The delay field is nanoseconds

`FUN_140005d00` in `qccammipicsi8380.sys` is the register writer:

```c
us = e.third / 1000;
if (us == 0)       us = 1;
else if (us > 50)  { KeDelayExecutionThread(-10 * us); continue; }
KeStallExecutionProcessor(us);
```

Over 50 µs Windows sleeps; below it busy-stalls. `0x989680` is 10,000,000 ns =
**10 ms**. The generator had copied the raw field into a microsecond slot, so
two entries became two **ten-second** `udelay`s. `gen2_config_lanes()` spun for
20.000 s, the pipeline brings the PHY up before the sensor, and so stream-on
landed 20 s after the capture began — past a 20 s `DQBUF`.

**Every C-PHY run from mission 6 to mission 8 measured the timeout, not the lane
table.** That includes the flat result I reported as a real negative one turn
before it was disproved. The elapsed time was in the logs the whole time.

### The C-PHY sequence has a nine-entry preamble

`FUN_140006f10` calls the writer twice on the C-PHY path: once on a 9-entry
block at `0x1400119f0`, then on the per-frequency table. The D-PHY path skips
it because `lane_regs_x1e80100[]` carries the equivalent inline — that table
opens with `{0x1014, 0xD5}, {0x101C, 0x7A}, {0x1018, 0x01}`, the same registers
in the same order.

Because the per-frequency table has no `0x101c` entry, **CTRL7 stayed at the
`0x02` `lanes_enable()` writes by hand instead of `0x7a`** on every C-PHY run.

### The interrupt masks were already in the table

Both C-PHY tables end with `CTRL11..CTRL21 = ff fe e6 df df fc fb 9b 7f bf ff`
and `CTRL0 = 0x0e` — byte-identical to the mask block the *other* SoCs' tables
in this driver already carry. `lane_regs_x1e80100[]` is the one table that omits
it, which is why `lanes_enable()` zeroing these has left x1e80100 silent.

So the table programmed the right masks and the debug patch's blanket `0xff`
overwrote all eleven a few lines later. Mission 8's interrupts were observed
through a more permissive configuration than Windows ever uses, which may be
exactly why `STATUS1` carried bits.

## Two things recovered that mainline does not have at all

**Per-lane receiver status.** `CSIPhyWaitforRx` (`FUN_140005dd8`) polls these
until they all read **zero**, 101 × 1 ms, then waits a further 20 ms. Lane block
+ `0x158`, stride `0x400`:

```
C-PHY (odd):  Lane1 0x358  Lane3 0x758  Lane5 0xb58
D-PHY (even): Lane0 0x0c4  Lane2 0x4c4  Lane4 0x8c4  Lane6 0xcc4  Clk 0xec4
```

Nothing in the mainline driver reads them. This is the first measurement
available to this project that reports on the link **without going through an
interrupt count**.

**The status words have names.** Windows' handler `FUN_140001570`
(`MipiCsiCallback`) reads the same eleven words we do and keeps four by name.
With `STATUSn = 0x10b0 + 4n` the mapping is exact:

| Windows | register | our index |
|---|---|---|
| `Csi2CommonStatus1` | `0x10b4` | **1** |
| `Csi2CommonStatus3` | `0x10bc` | 3 |
| `Csi2CommonStatus6` | `0x10c8` | 6 |
| `Csi2CommonStatus8` | `0x10d0` | 8 |

The word that carried everything in mission 8 is index 1 — the one Windows saves
first. That is corroboration of *where* to look, not a bit-level decode, and
nobody should guess at the bits.

Its ack sequence is a 24-entry table at `0x140011280`: `CTRL22..CTRL32 = 0xff`,
100 ns, `CTRL10 = 1`, 100 ns, `CTRL22..CTRL32 = 0x00`, 100 ns, `CTRL10 = 0`. The
kernel's hand-rolled ack is equivalent in shape and demonstrably works.

## Where that leaves the open question

The next run separates two things that have never been separable here: whether
the receiver locks (lane status → zero) and whether anything reaches `vfe0`. If
lane status goes to zero and `vfe0` stays flat, the problem has moved downstream
to CSID decode configuration, which has never been touched.

## Mistakes worth not repeating, continued

- **A flat counter is not a negative until you know the run happened.** Three
  missions were spent on captures that ended before the sensor emitted a line.
  Check elapsed time between the bracketing log lines before interpreting a
  result.
- **A round number in a units-bearing field is a decode error, not a hardware
  requirement.** 10,000,000 in a "microseconds" column should have been
  suspicious on sight.
- **When a debug patch and a recovered table both write the same register, say
  which one runs last.** The `0xff` masks and the table's masks were in conflict
  for a whole mission without anyone noticing.

## Mission 9: the first valid C-PHY measurement, and what it showed

Programming now costs **21.8 ms** against 20.000 s. Every C-PHY result before
this one was a capture that ended during setup.

**B against C is the comparison the effort needed.** Through the same selective
masks, forced C-PHY takes **1339** csiphy interrupts and D-PHY takes **61**, and
they do not light the same words — C-PHY puts everything in STATUS1 and STATUS2
with STATUS0 clean, D-PHY does the reverse. ~67/s is not what this PHY does
whenever any sensor talks to it; it is specific to the C-PHY configuration.

`vfe0` is 0 in all four runs. `csid0` takes exactly one tick per `STREAMON`.

Per-lane receiver status, sampled over `/dev/mem` across a full capture (187
samples, with three idle samples at the head as an in-run control):

```
trio 0   0x00000000 -> 0x0000000C  when the sensor starts, sustained 19 s
trio 1   0x00000000  in every sample
trio 2   0x00000000  in every sample
```

It does **not** go to zero while streaming, which is what `CSIPhyWaitforRx`
waits for. Whatever `0x0C` means — and nobody should guess — the receiver is
saying something is wrong, steadily rather than per-frame.

### The one-trio question

The Linux side read the above as two trios wrongly disabled: the C-PHY table
programs all three lane blocks symmetrically, 37 entries each, and `CTRL5` ends
at `0x02`.

The evidence runs the other way, and it is worth writing down because it will
come up again:

- **`laneCount` is 1** for the IMX681 in the chromatix `resolutionData`,
  cross-checked against 2 for the OV02C10 and 4 for the OV13858 in the same
  decode. `CSIPhyRxLane` derives the CTRL5 mask from exactly that field. The
  `0x2a` in the binary is the three-trio default before the runtime patch.
- **Programming a lane block is not enabling it.** The D-PHY table also programs
  every block and then selects with `CTRL5 = 0xD5`.
- **A disabled block reads zero** whether or not anything is arriving at it, so
  "trios 1 and 2 read zero" cannot separate the two hypotheses.
- **The settle table covers 500–3000 MSps.** This link is 875.8 MSps on one trio
  and 292 MSps on three — the second is below the lowest threshold in the table
  built for this part.
- **The sensor agrees.** `0x0114` (CCS `CSI_LANE_MODE`) settles to `0x00`.

It is still one register, so it is now `cphy_ctrl5`, a module parameter, and the
question gets settled by measurement rather than by whoever writes the brief.

### A reporting bug that had always been there

`lanes_enable()` announces `ctrl5 0x81` on the D-PHY path and the register reads
`0xD5` — `lane_regs_x1e80100[]`'s first entry overwrites what was computed from
the DT's `data-lanes = <1>`. The announcement had been printing a decision, not
a measurement, for as long as it existed. The lane-status line now reads CTRL5
back.

Two smaller things: the ISR half of the lane-status reader was defined and never
called, caught by a `strings` check on the context argument rather than on the
format string; and `timer_400` is a no-op under `cphy_force`, since the C-PHY
path already selects 400 MHz.

## Mission 10: one trio, confirmed by measurement

`cphy_ctrl5 = 0x2a` enabled all three trios, verified by read-back from the
register in 120/120 samples. Trios 1 and 2 stayed at `0x00000000` in **all 160
observations across two independent instruments** — the `/dev/mem` sampler and
the ISR's own reading. Enabling them changed nothing else: the status-word
census is byte-identical to mission 9's, and `vfe0` stayed 0.

**The sensor drives one trio.** The chromatix `laneCount`, the settle table's
range, `CSI_LANE_MODE` and now the hardware all agree.

Two things worth keeping from how that was established:

**A repeatability figure, obtained by accident.** Running the same
configuration twice gave **1214 and 1469** interrupts — a 19% spread — against
2.5% between the two configurations being compared. Without it, a 36-interrupt
difference would have looked like a result. Interrupt counts on this block are
not precise enough to carry a small difference; only the ~22× C-PHY/D-PHY gap
survives that noise.

**The two instruments disagree about trio 0.** `/dev/mem`, sampled
asynchronously, reads `0x0000000C` steadily. The ISR, reading at interrupt time
after acking the eleven status words, reads `0x00000000` or `0x00000005`. `0x0C`
is bits 2–3 and `0x05` is bits 0 and 2 — neither a superset of the other, so it
is not accumulation. Rule 8 says read registers back rather than printing what
you computed; this is the layer below it: **when you read back matters too**, and
where two instruments disagree neither is automatically the truth.

## The fourth undriven field: CSID has been decoding as D-PHY

```c
#define CSI2_RX_CFG0_PHY_TYPE_SEL   24
```

Declared in `camss-csid-680.c`, `camss-csid-gen2.c` and `camss-csid-340.c`, and
written by **no CSID driver anywhere in `drivers/media`**. `__csid_configure_rx()`
assembles CFG0 out of lane count, lane assignment and PHY index and stops, so
bit 24 is always zero and the decoder is told "D-PHY" on every stream regardless
of how the PHY was programmed.

Unlike the CSIPHY, **this is live camss code on x1e80100**: `csid_res_x1e80100[]`
declares `.reg = { "csid0" }` and `.interrupt = { "csid0" }`, the SoC uses
`csid_ops_680`, and `csid0` takes its interrupt on every `STREAMON`. The PHY had
to be fixed by going around camss; CSID never needed that and never got it.

**This is the fourth instance of one pattern on this hardware:**

| field | state |
|---|---|
| CSIPHY interrupt | ISR written, wired into the ops struct, `request_irq` never called |
| CSIPHY IRQ masks | mask block present in every other SoC's lane table, absent from x1e80100's |
| `CSID_CSI2_RX_CAPTURE_CTRL` | three enable bits defined, register never written at all |
| `CSI2_RX_CFG0_PHY_TYPE_SEL` | defined in three CSID variants, written by none |

The lesson generalises past this camera: **on this platform, a `#define` is not
evidence that anything uses it.** Grep for the write, not the definition. Three
of the four cost a mission each before anyone checked.

`CAPTURE_CTRL` deliberately left alone for now — its `CPHY_PKT_EN` reads like a
debug packet-capture path rather than a decode enable, and it would be a second
variable in the same run.

## Mission 11: the decoder was the missing write, and it was not enough

Bit 24 moved the counter and run I proved it did. The Linux side added a third
capture because G and H differ in two variables at once:

| | PHY C-PHY | PHY D-PHY |
|---|---|---|
| **bit 24 set** | **2 packets, 1 CRC error** (G) | 0 (H) |
| **bit 24 clear** | **0** (I) | 0, every prior mission |

Same `ctrl5`, same `lane0`, same ~1500 CSIPHY interrupts in G and I; one bit in
CFG0 between them. `TOTAL_PKTS_RCVD` had read zero for ten missions.

A 120 s repeat says it is a rate, not a latch: **23 packets, 12 CRC errors, ECC
0**, arriving irregularly and sometimes in pairs — roughly one every five
seconds against the ~18,000 per second a 6 fps 4032x3024 stream owes. `vfe0`
still zero. So bit 24 was necessary and nowhere near sufficient, and the fault
is still in transport rather than in formatting.

One correction to the reading of that result, which matters for where to look
next: **`STATS_ECC` has never been in a position to read non-zero.** It was 0 in
the runs where no packets arrived at all, and CSI-2 over C-PHY protects the
packet header with a CRC and duplication rather than an ECC byte, so the counter
may be structurally dead in this mode. What survives is narrower and enough:
`TOTAL_PKTS_RCVD` cannot increment without a parsed header, because the receiver
needs the word count to find the payload CRC. A counter reading zero in a run
where it could not have read anything else has not measured anything.

## The CSIPHY has never been reset

Recovered from `CameraMIPIPHY_Start` (FUN_140001c70) on 2026-08-07, chasing the
Linux side's read of the CRC split as a marginal-timing signature. Only step 6
of seven had been transcribed:

| | step | mainline |
|---|---|---|
| 1 | settle count — table for C-PHY, formula for D-PHY | have it |
| 2 | RefGen ready: `base[0x10fc] >> 7 & 1` (STATUS19 bit 7) | never read |
| 3 | `CSIDPhyReset` — common pulse, then a per-lane pulse | never run |
| 4 | patch settle count and lane mask into the table | equivalent |
| 5 | phase patching, D-PHY and `CsiTestMode` only | N/A |
| 6 | 9-entry preamble, then the per-frequency table | have it |
| 7 | `CSIPhyWaitforRx` — poll per-lane status until zero | reported only |

Step 3 is two gaps stacked. The per-trio pulse — `0x025c`/`0x065c`/`0x0a5c`,
`0x10` then `0x00` — appears nowhere in `phy-qcom-mipi-csi2-3ph-dphy.c`; the
only `0x?05c` writes in that file are on the *even* blocks, tagged
`CSIPHY_SKEW_CAL`, which `gen2_config_lanes()` skips. And the common pulse that
`phy_qcom_mipi_csi2_reset()` does implement never happens either, because
**nothing calls it**: `.reset` sits in the ops struct and
`phy_qcom_mipi_csi2_power_on()` goes `hw_version_read` -> `lanes_enable`.

So the fifth instance of the pattern, and the one that widens it:

| field | state |
|---|---|
| CSIPHY interrupt | ISR written, wired into the ops struct, `request_irq` never called |
| CSIPHY IRQ masks | mask block in every other SoC's lane table, absent from x1e80100's |
| `CSID_CSI2_RX_CAPTURE_CTRL` | three enable bits defined, register never written |
| `CSI2_RX_CFG0_PHY_TYPE_SEL` | defined in three CSID variants, written by none |
| `phy_qcom_mipi_csi2_reset()` | fully implemented, correctly named, in the ops struct, never invoked |

**A `#define` is not evidence that anything uses it, and neither is a function
body.** Grep for the call site.

An unreset trio receiver holding stale state is a complete explanation for a
link that never locks but syncs by accident a couple of dozen times a minute,
and it fits the most stable observation in the project: `lane0` status pinned at
`0x0C` through every configuration change, where Windows treats any non-zero
value as `CSIPhyWaitforRx Failed` and declines to call the link up.

Shipped as `phy_qcom_mipi_csi2.win_reset`, default off, picking the C-PHY or
D-PHY register set off `cphy_force`. The RefGen read is unconditional on every
path — one `readl`, and no measurement of it exists.

### Also recovered, not yet acted on

- **The settle count can be overridden by the client.** `Client requested settle
  count %d is used instead of recommended settle count of %d` — a non-zero value
  at `ctx+0x14` wins over the table lookup. Our `0x40` is the recommendation, not
  necessarily what the shipping stack runs.
- **Three C-PHY per-frequency tables, not two**, selected at 2.0 and 2.5 Gbps.
  IMX681 at 1996.8 Mbps takes the first — the one this repo carries — clearing
  the boundary by 0.16 %.
- **`CsiTestMode`**, a registry flag under
  `HKLM\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera` (absent on this
  machine). With it set, the Windows driver writes the real `Csi2DataRateKbps`,
  `Csi2PhaseNumOfLanes`, `Csi2PhasePhyMode` and the four `Csi2CommonStatus`
  words back to the registry on teardown — from a link that works. That would
  settle the data rate by measurement and give a known-good baseline for the
  `00 04 01` the Linux side reports. Needs the user's go-ahead; it is a change
  to the working Windows install.

## The rate was wrong, and Windows was willing to say so

`qccammipicsi8380.sys` reads three values at device init from
`HKLM\SYSTEM\CurrentControlSet\Control\Qualcomm\Camera` and, with `CsiTestMode`
set, writes its own view of the link back on teardown. The key did not exist on
this machine. Set it, opened the front camera, read it back, deleted it:

```
Csi2DataRateKbps       5485700     = 5.4857 Gbps
Csi2PhaseNumOfLanes    1
Csi2CommonStatus1/3/6/8  all 0
CsidRxTotalPktsRcvd    559179      CsidRxStatsEcc 0      CsidRxTotalCrcErrors 0
```

That closes three questions at once. One trio, stated by the vendor stack rather
than inferred from a struct field. A working link reports zero in all four
status words and zero CRC errors in half a million packets, which is the first
known-good baseline for the `00 04 01` the Linux side had been reading in every
configuration since mission 3. And `CsidRxStatsEcc` is zero on a *working* C-PHY
link too — so that counter reads zero whether everything works or nothing does,
and the earlier caution about it was right for a stronger reason than was given.

### The rate

`5,485,700 kbps` against the `1996.8 Mbps` every C-PHY run had programmed. It
reconciles exactly with the sensor's own recovered PLL registers, which is what
makes it evidence rather than a surprise:

```
EXTCLK 19.2 MHz.
modes 1-5:  0x030d = 3, 0x030e/0x030f = 0x0177 = 375
            op_sys_clk = 19.2 / 3 * 375 = 2400.0 MHz
5,485,700,000 / 2,400,000,000 = 2.28571 = 16/7, to five figures.
```

**`op_sys_clk` is the C-PHY symbol rate; the data rate is symbols x 16/7**,
C-PHY carrying 16 bits per 7 symbols. Two independent sources — a vendor blob
recovered months earlier and a live link measured today — agreeing to five
figures. It also retroactively settles `imx681.c`'s own flagged UNVERIFIED
assumption that `op_sys_clk_div` is 1.

`link_freq_menu_items` are therefore half the symbol rate: the D-PHY DDR
convention applied to a C-PHY sensor. `cphy_settle_cnt()` doubled that back and
then divided by 2.28 as though the result were a bit rate.

| | programmed | correct |
|---|---|---|
| symbol rate, mode 0 | 875.8 MSps | **1996.8 MSps** |
| data rate, mode 0 | 1.9968 Gbps | **4.564 Gbps** |
| settle count | **0x40** (64) | **0x26** (38) |
| register table | **< 2.0 Gbps** | **>= 2.5 Gbps** |

A settle window 68 % too long, from a table for a link running at a third of the
speed. Mission 11's 23 packets in 113 seconds were 23 lucky alignments, not a
marginal link — which is a different diagnosis from the one the CRC split
suggested, and a better fit to how far off the count was.

The third per-frequency table, 121 entries at `0x140010c50`, had been recorded
in this repo as "out of range for IMX681". It is the table this sensor needs on
every mode. Its baked-in settle value is `0x22`, and running Windows' measured
5,485,700 kbps through the corrected lookup returns `0x22` — the formula
reproducing a constant the binary ships is the check worth trusting.

### What this says about the method

The wrong rate was an inference stacked on an assumption the sensor driver's own
header flags as unverified, and it was then defended in mission 9 with a
range argument: 875.8 MSps sits comfortably inside a 500-3000 MSps table, so it
must be about right. **Every plausible wrong answer is also in range.** 2001.8
sits comfortably inside that table too.

The correction did not need better reasoning. It needed a number the other side
was willing to state outright, and Windows had a documented mechanism for
stating it the whole time. Prefer the measurement that already exists over the
derivation you can defend — and when one is available for the asking, ask.
