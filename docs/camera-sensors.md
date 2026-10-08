# Camera: the sensors are named, and the DT risk assessment was wrong

Pillar 2, steps 1–3. Two of the plan's assumptions turn out to be wrong in
opposite directions:

- **Step 3 is more blocked than stated.** The DSDT does *not* contain the sensor
  wiring. `CAMS`, `CAMF` and `CAMI` have no `_CRS` at all.
- **The overall risk is much lower than stated.** "First-of-kind for any X1E
  laptop. No reference DT to copy" is no longer true — six X1E boards wire up
  `camss` in our own kernel tree, one of them with a complete CSIPHY endpoint and
  sensor node.

## Step 1 — the parts, named

Windows' Qualcomm camera stack ships per-sensor module blobs whose filenames are
the part numbers. Cross-referencing them against each ACPI device's `_SUB`
pins the mapping exactly, with no ambiguity about which SKU's blob applies:

| ACPI | `_HID` | `_UID` | `_SUB` | Sensor module blob | **Part** |
|---|---|---|---|---|---|
| `CAMS` (rear) | `OVTID858` | `0x15` | `MSHW0491` | `com.surface.sensormodule.rfc_ov13858.bin` | **OmniVision OV13858** |
| `CAMF` (front) | `SONY0681` | `0x1A` | `MSHW0490` | `com.surface.sensormodule.ffc_imx681.bin` | **Sony IMX681** |
| `CAMI` (IR) | `SMO55F0` | `0x1C` | `MSHW0492` | `com.surface.sensormodule.aux_vd55g0_MSHW0492.bin` | **ST VD55G0** |

Blobs live in
`C:\Windows\System32\DriverStore\FileRepository\surfacecam{rear,front,aux}sensor_extension8380.inf_arm64_*\`.

The ACPI IDs encode the part numbers once you see the trick: `OVTI` + `D858` is
OV**13**858, because 13 decimal is 0xD. `SONY0681` is IMX**681** directly.
`SMO55F0` is ST's VD55G**0** (`SMO55F1` in the same INF is VD55G1).

The other SKUs' blobs in the same packages are a useful cross-check that this is
per-device and not guesswork: the front package also carries `ffc_ov02c10` builds
for `MSHW0540`/`MSHW0560`, which is the OmniVision front camera on the
non-Sony SKUs. This machine is the Sony one.

## Step 2 — driver coverage in our own 7.1.3 tree

Checked against `drivers/media/i2c` in `/root/sp11/linux-sp11`, not from memory:

| Sensor | Driver | Usable from DT? |
|---|---|---|
| OV13858 (rear) | `ov13858.c` **exists** | **No** — ACPI-only |
| IMX681 (front) | **none** | — |
| VD55G0 (IR) | `vd55g1.c` exists but does not match | **No** — different part |

Details that matter:

**`ov13858.c` is ACPI-only.** Its entire match table is

```c
static const struct acpi_device_id ov13858_acpi_ids[] = {
	{"OVTID858"},
	{ /* sentinel */ }
};
```

— that is literally our `_HID`, because the driver was written for Intel ACPI
platforms that expose the same sensor. There is no `of_match_table`. Adding one
plus a `compatible = "ovti,ov13858"` binding is a small, clean, upstreamable
patch, and it is the single highest-value thing in this pillar.

**`vd55g1.c` does not cover VD55G0.** It matches `st,vd55g1` and `st,vd65g4`
only, and describes itself as the "VD55G1 global shutter sensor family". VD55G0
is a different part. The IR camera needs a new driver — but the IR camera is
Windows Hello, i.e. the least valuable of the three.

**IMX681 has no driver anywhere in the tree.** Front camera — the one that
matters most for video calls — needs a driver written from scratch.

So the honest ordering is: **rear camera is close** (existing driver + a DT
match), front camera is a real driver-writing project, IR is optional.

## Step 3 — the DSDT does not have the wiring

The plan said steps 1–4 were unblocked because "the DSDT is already dumped in
this repo". For step 3 that is false. The sensor devices are bare stubs:

```
Device (CAMS)
{
    Name (_DEP, Package (One) { \_SB.MPCS })
    Name (_HID, "OVTID858")
    Name (_UID, 0x15)
    Name (_SUB, "MSHW0491")
    Method (_HRV, ...) { ... }
    Method (_STA, ...) { Return (0x0F) }
}
```

No `_CRS`, so no I²C SerialBus descriptor, no slave address, no MCLK, no
reset GPIO, no regulator references. `CAMF` and `CAMI` are identical in shape.
Windows does not need them there — the Qualcomm camera platform driver
enumerates the sensors as its own children, which is also why only `QCOM0C32`
(`CAMP`) and `QCOM0C27` (`FLSH`) appear under `HKLM\...\Enum\ACPI` while the
three sensor IDs do not.

Full extract: `data/acpi/dsdt-camera.dsl`.

### What the DSDT *does* give

`CAMP` (camera platform, `QCOM0C32`, `_SUB MSHW0495`):

| Resource | Value |
|---|---|
| MMIO | `0x0AC13000`+`0x1000`, `0x0AC19000`+`0xC000`, `0x0AC15000`+`0x1000`, `0x0AC16000`+`0x1000` |
| IRQ | `0x1EC`, `0x12F`, `0x1EB` |
| GPIO | `0xE1` (225), `0x69` (105) |
| `_DEP` | `PEP0`, `PMIC`, `GIO0` |

`MPCS` (ISP, `QCOM0C98`) has two resource sets selected by `\_SB.SDFE`:

| | MMIO | IRQ |
|---|---|---|
| `SDFE == 0x88` | `0x0ACE4000`, `0x0ACE6000`, `0x0ACE8000`, `0x0ACEC000` (`0x2000` each); `0x0ACF6000`, `0x0ACF7000`, `0x0ACF8000` (`0x400` each) | `0x1FD`, `0x1FE`, `0x1FF`, `0x9A` |
| `SDFE == 0x9A` | `0x0ACE4000`, `0x0ACEC000`, `0x0ACF6000`, `0x0ACF7000`, `0x0ACF8000` | `0x1FD`, `0x9A` |

The three `0x400` blocks at `0x0ACF6000`/`7000`/`8000` are CSIPHY-shaped. Worth
diffing against the `csiphy_res_x1e80100` addresses `x1e80100.dtsi` already
carries.

### Where the wiring actually is

The same driver-store packages that named the parts also ship per-SKU **resource**
blobs, and this machine's `_SUB` values select exactly three of them:

```
CAMS_RES_MSHW0491.bin    2293 bytes    rear
CAMF_RES_MSHW0490.bin    1843 bytes    front
CAMI_RES_MSHW0492.bin    2187 bytes    IR
SCFG_REAR_MSHW0491.bin    135 bytes
SCFG_FRONT_MSHW0490.bin   133 bytes
SCFG_AUX_MSHW0492.bin     151 bytes
CAMP_RES_MSHW0495.bin   14778 bytes    platform
```

`_RES` is resources — and they are exactly where the wiring lives. **Parsed; see
the next section.**

## Step 3 — the wiring, from the `_RES` blobs

The blobs need no reverse engineering. They are a **self-describing TLV tree** in
plain text: magic `AeoB`, a `u32` size, a `u32` version, then records of
`type:u16, length:u16, payload` where type 0 is an integer, type 1 a
NUL-terminated string, and type 3 a nested container. `probes/camres_parse.py`
walks it; full output in `data/camera-res-parsed.txt`.

Each blob is a **power-sequencing script**, keyed by D-state — `DSTATE 0` is
power-on, `DSTATE 3` is power-off, and the off sequence is the on sequence
reversed.

### Per-sensor values

| | **CAMF** front — IMX681 | **CAMS** rear — OV13858 | **CAMI** IR — VD55G0 |
|---|---|---|---|
| Reset GPIO | `tlmm` **237** | `tlmm` **110** | `tlmm` **109** |
| MCLK | `cam_cc_mclk4_clk` | `cam_cc_mclk1_clk` | `cam_cc_mclk0_clk` |
| MCLK rate | 19 200 000 Hz | 19 200 000 Hz | 19 200 000 Hz |
| 1.8 V (dovdd) | `LDO3_M` | `LDO6_M` | `LDO4_M` |
| 2.8 V (avdd) | `LDO7_B` | `LDO5_M` | `LDO7_M` |
| core | — | `LDO1_M` 1.2 V | `LDO2_M` 1.15 V |
| extra | — | `LDO16_B` 2.9 V | — |

`LDO16_B` at 2.9 V appears only on the rear sensor, and 2.9 V is the usual
autofocus VCM rail — consistent with the rear module having an actuator (the
sensor-module blob has an `actuatorSlaveAddress` field). That is an inference,
not something the blob labels.

### The `_M` / `_B` suffixes map straight onto DT regulator labels

`_B` is the main PMIC, `_M` the camera one, and the mapping is confirmed by
existing device trees rather than assumed:

| Blob | DT label | Confirmed by |
|---|---|---|
| `LDO7_B` 2.8 V | `vreg_l7b_2p8` | `x1-dell-thena.dtsi` uses it as the front camera's `avdd` |
| `LDO3_M` 1.8 V | `vreg_l3m_1p8` | the `ovti,ov02e10.yaml` binding example uses it as `dovdd` |

So `LDO6_M` → `vreg_l6m_1p8`, `LDO5_M` → `vreg_l5m_2p8`, `LDO1_M` →
`vreg_l1m_1p2`, `LDO16_B` → `vreg_l16b_2p9`.

**But `x1-microsoft-denali.dtsi` instantiates no `_m` PMIC at all** — grepping the
X1E device trees turns up `vreg_l1b_*`, `vreg_l6b_*`, `vreg_l16b_*` and friends,
and no `vreg_l*m_*` on denali. The camera PMIC node has to be added before any
sensor node can reference those rails. That is a prerequisite for step 4 that the
plan did not have.

`_M` is confirmed to be the **PM8010** camera PMIC, and not by inference —
`x1e78100-lenovo-thinkpad-t14s.dtsi` has:

```dts
compatible = "qcom,pm8010-rpmh-regulators";
qcom,pmic-id = "m";
```

The `pmic-id` is literally the suffix. `pm8010.dtsi` is already in the tree, and
`x1-crd.dtsi` defines `vreg_l3m_1p8`, `vreg_l4m_1p8` and `vreg_l7m_2p9` — so
step 3c is copying a known-good block, not new work. Only the voltages need
setting from the table above (e.g. our IR rail is `LDO7_M` at 2.8 V where crd
has 2.9 V).

### Shared preamble, identical across all three

```
NPARESOURCE  /arc/client/rail_mmcx     64
CLOCK        gcc_camera_xo_clk
CLOCK        gcc_camera_ahb_clk
CLOCK        cam_cc_gdsc_clk
FOOTSWITCH   cam_cc_titan_top_gdsc
CLOCK        cam_cc_cpas_ahb_clk       80 000 000 Hz
```

### Power-on order (front camera, verbatim)

```
reset GPIO 237 -> 0
cam_cc_mclk4_clk on @ 19.2 MHz
LDO3_M  -> 1 800 000 uV
LDO7_B  -> 2 800 000 uV
DELAY
reset GPIO 237 -> 1
DELAY
```

Reset is asserted before the clock and rails come up, then released after a
settling delay — the ordering a `reset-gpios` + `assigned-clock-rates` DT node
reproduces naturally.

### Cross-check against the reference DT

`x1-dell-thena.dtsi` drives *its* front camera with

```dts
reset-gpios = <&tlmm 237 GPIO_ACTIVE_LOW>;
clocks = <&camcc CAM_CC_MCLK4_CLK>;
assigned-clock-rates = <19200000>;
```

— the same GPIO and the same MCLK this blob specifies, on a different laptop with
a different sensor. Two independent sources agreeing on 237/MCLK4 is good
evidence that the front-camera wiring is SoC-reference-design standard, and that
the numbers above are right.

### One bug worth recording

The first version of `camres_parse.py` printed the GPIO records as
`0 0 1 0 0` — it treated a container's first element as a label and dropped it
when it was not a string. The dropped element was the **pin number**. A hexdump
of the raw record showed `ed 00` (237) sitting where the parser showed nothing.

Rule 2 of the loop recipe, in a new costume: the tool disagreed with the bytes,
so the tool was wrong. Anything derived from that output before the fix would
have produced a DT node with no usable reset line.

## Step 3b — the CSI lanes, and where the I²C address is not

The `_RES` blobs carry power and clocks but not the bus or the CSI link. Those
belong to the sensor-module blobs (`com.surface.sensormodule.ffc_imx681.bin`,
212 KB) — a different format, `QTI Chromatix Header` / `Parameter Parser V3.4.0`.

### Format

A flat table of fixed **56-byte records** starting at `0xd0`, followed by a data
section:

```
+0x00  char name[40]     NUL-padded
+0x28  u32  0xffffffff   constant
+0x2c  u32  offset       cumulative offset into the data section
+0x30  u32  length       size of this field's data, in bytes
+0x34  u32  id
```

`length` is a **byte count, not a value** — established by prediction rather than
assertion: `sensorName` is 7 in the imx681 blob and 8 in the ov13858 and ov02c10
blobs, i.e. exactly `len(part_number) + 1` in each. The consecutive-offset
arithmetic agrees (`sensorName` at `0x75c` + 8 = `0x764`, which is the next
record's offset).

The data section's base is not recorded in the header, so `probes/chromatix_parse.py`
recovers it: the module-name string near the top of the file ends in the part
number, that same string is `sensorName`'s data, so `base = strpos - offset`.
The decode is self-checking — if the base is wrong, `sensorName` prints something
that obviously isn't a part number.

### Result

| Blob | `laneAssign` | Reading |
|---|---|---|
| `rfc_ov13858` (rear) | **`0x3210`** | 4 lanes, identity mapping |
| `ffc_ov02c10` | **`0x0010`** | 2 lanes |
| `ffc_imx681` (front) | `0x0000` | ambiguous — see below |

The middle row is the check that matters: `ov02c10` is wired as `data-lanes =
<1 2>` in `x1e80100-dell-xps13-9345.dts` and `x1-dell-thena.dtsi`, and
`0x0010` is exactly that as a packed nibble-per-lane map. The rear sensor's
`0x3210` likewise matches `ov13858.c`'s own comment, *"4224x3136 needs
1080Mbps/lane, 4 lanes"*. Two independent confirmations that the decode is right.

**So the rear camera's CSI link is known: 4 lanes.** That, with the reset GPIO,
MCLK and rails already recovered, is everything a `data-lanes` property needs.

The front camera's `0x0000` is not usable as-is. It would read as lane 0 twice,
which is not a valid two-lane map; a one-lane sensor is the benign reading but
that is a guess, and it is recorded here as unresolved rather than assumed.

### The I²C address is not in these blobs at all

```
sensorSlaveAddress       length 0
actuatorSlaveAddress     length 0
eepromSlaveAddress       length 0
sensorI2CFrequencyMode   length 0
i2cFrequencyMode         length 0
cphyDphyComboMode        length 0
```

Zero-length in **all three** blobs, so this is the format saying "not stored"
rather than a parsing failure. The sensor-module blob describes the sensor's
register programming, not its bus placement.

That leaves the slave address and the CCI bus assignment to come from the
Qualcomm sensor driver binaries. `CAMP_RES` shows both `cam_cc_cci_0_clk` and
`cam_cc_cci_1_clk` live at 37.5 MHz, so both buses are in use and the per-sensor
assignment is a real question.

### Where the decompiler got to

`surfacecamrearsensor8380.sys` in Ghidra (244 functions after analysis; use the
per-binary headless workflow in the README, **not** the default MCP port).

`CameraSensorDriver_ProbeImageSensor` is `FUN_14000d8a0`. It logs the sensor
parameters from three qwords in its device context:

```c
local_70  = *(ulonglong *)(param_1 + 0x24c);
uStack_68 = *(ulonglong *)(param_1 + 0x254);
uVar11    = *(ulonglong *)(param_1 + 0x25c);
```

and the `I2cSlaveAddr = %#04x` string at `0x140017248` is referenced from
`0x14000d9d0`, in the log call sitting between the ones for `0x140017200` and
`0x1400172d8`. By position that argument is the high half of the qword at
`+0x24c` — i.e. **the slave address is the device-context field at
`context + 0x250`**.

So it is runtime state, not a constant in this function.

### What writes it — the trail ends at the driver boundary

`CameraSensorDriver_Init` (`FUN_14000c430`, named from its own log strings) does:

```c
CamSensor_MemcpyChecked(pContext + 0x1e8, 0x130, param_2, 0x130);
```

The entire 0x130-byte sensor-config struct is copied wholesale from the caller's
buffer. `0x250 - 0x1e8 = 0x68`, so:

> **`I2cSlaveAddr` = caller's config struct `+ 0x68`**

It is **not a constant anywhere in this driver.** It is handed in by the Qualcomm
camera platform stack — which is exactly consistent with `sensorSlaveAddress`
being zero-length in every shipped `com.surface.sensormodule.*.bin`. Two
independent sources now agree that this driver and its data files simply do not
carry the value.

### The platform driver gives the CCI bus and the CSIPHY index

`qccamplatform8380.sys` has a function whose own log line is
`GetPlatformConfiguration exiting ...`. It reads `Resources\PcfgBinaryPath` from
the registry — that is `CAMP_PCFG_MSHW0495.bin`, 232 bytes, already in this repo's
reach — and parses it as **the same `AeoB` TLV** as the `_RES` blobs (it skips the
12-byte header with `base + 0xc` and walks 12-byte records reading
`*(uint *)(rec + 4)`).

Records 1–8 land in `local_90[0..7]`: the first four are a per-sensor connection
word for sensors 0–3, and the driver unpacks it bitwise:

| Bits | Field |
|---|---|
| 9–11 | flash index |
| **16–19** | **I²C master** — which CCI bus |
| **20–23** | **CSI PHY index** |
| 24 | flash / shutter type |
| 25 | Face Authentication |

Decoded for `MSHW0495`:

| | Connection word | I²C master | CSIPHY |
|---|---|---|---|
| sensor[0] | `0x00110000` | **1** | **1** |
| sensor[1] | `0x00230010` | **3** | **2** |
| sensor[2] | `0x01000110` | **0** | **0** |
| sensor[3] | `0x00000000` | — | absent |

**Which index is which sensor is an inference**, not something the blob labels.
The ACPI `_UID`s are ascending in the order `CAMS` `0x15` → `CAMF` `0x1A` →
`CAMI` `0x1C`, so sensor[0]=rear, sensor[1]=front, sensor[2]=IR is the natural
reading:

| Sensor | CCI/I²C master | CSIPHY port |
|---|---|---|
| rear OV13858 | 1 | 1 |
| front IMX681 | 3 | 2 |
| IR VD55G0 | 0 | 0 |

Both are confirmable in seconds on booted hardware, so they are recorded as
*probable* rather than settled.

#### Which DT bus each master is

`hamoa.dtsi` has exactly **two CCI controllers with two buses each** — four in
total, the right number for master indices 0–3:

```
cci0: cci@ac15000    cci0_i2c0 (reg 0)   cci0_i2c1 (reg 1)
cci1: cci@ac16000    cci1_i2c0 (reg 0)   cci1_i2c1 (reg 1)
```

Those two controller addresses appear **verbatim in the camera platform
device's own ACPI `_CRS`** — `CAMP` claims `0x0AC15000`+`0x1000` and
`0x0AC16000`+`0x1000` among its windows. So both CCI controllers demonstrably
belong to the camera block, and the DT addresses are confirmed from a second,
independent source.

Reading the masters as numbered CCI-major, which is the only assignment that
fits four indices onto four buses:

| Sensor | Master | DT bus |
|---|---|---|
| IR VD55G0 | 0 | `cci0_i2c0` |
| rear OV13858 | 1 | `cci0_i2c1` |
| front IMX681 | 3 | `cci1_i2c1` |

The ordering convention remains an assumption, but a well-constrained one: the
controller addresses agree across ACPI and DT, and the counts match exactly.

That closes two of the three DT unknowns. `camss` on x1e80100 exposes CSIPHY 0,
1, 2 and 4 as `port@0..port@3`, so the rear camera would hang off `port@1`.

**"I²C master" is the bus, not the slave address** — that one is still missing,
and it is not in this driver either.

### User-mode CamX, checked and negative

`QcDeviceMFT8380.dll` (23 MB) does contain the Surface sensor libraries — its
debug paths include `chi-cdk/oem/Surface/sensorlibs/src/imx681.cpp`,
`vd55g0.cpp` and `vd55g1.cpp`. Notably **`ov13858.cpp` is absent**, so the rear
sensor is not handled by a Surface OEM sensor lib.

A bounded search did **not** find the slave address:

- the sensor names (`vd55g1`, `vd55g0`, `ov13858`, `imx681`, `ov02c10`) sit
  packed together in a plain **string pool**, not in per-sensor structs with an
  adjacent address
- the strings `slaveAddress`, `sensorSlaveAddress` and
  `GetOverrideSensorSlaveAddress` are **absent** entirely (only
  `GetOverrideActuatorSlaveAddress` and `GetOverrideEepromSlaveAddress` exist)

Recovering it from here would mean full analysis of a 23 MB binary — the same
scale this project already judged impractical for a 122 MB driver. Stopping here
was a deliberate call, not a dead end reached by accident.

### Recommendation: park the slave address until the ISO boots

Chasing it further means analysing `qccamplatform8380.sys` or the user-mode CamX
components — a substantially larger effort than everything in this document so
far, for one 7-bit number. `i2cdetect` on the two CCI buses answers it in seconds
on booted hardware, and the boot is needed for steps 5–6 regardless.

The Ghidra project is saved at `C:\Tools\ghidra-proj\SurfaceCam.gpr` with
`CameraSensorDriver_Init`, `CameraSensorDriver_ProbeImageSensor`,
`CamSensor_ReadDeviceRegistryDword`, `CamSensor_LogPrintf`,
`CamSensor_MemcpyChecked`, `CamSensor_LoadBinaryFile`, the `CAM_SENSOR_CONTEXT`
and `CAM_SENSOR_CONFIG` structs, and plate comments recording the field map — so
picking this up later costs nothing to re-derive.

### Corroboration from the Windows driver

`surfacecamrearsensor8380.sys` carries its debug format strings uncompressed, and
they name the same fields:

```
CameraSensorDriver_CSIPhyConfig() pCSIPhyInfo->laneAssign   = 0x%x
CameraSensorDriver_CSIPhyConfig() pCSIPhyInfo->laneCount    = %d
CameraSensorDriver_CSIPhyConfig() pCSIPhyInfo->laneMask     = 0x%x
CameraSensorDriver_CSIPhyConfig() pCSIPhyInfo->comboMode    = %d
CameraSensorDriver_CSIPhyConfig() pCSIPhyInfo->dataRate     = %llu
I2cSlaveAddr = %#04x
```

`laneAssign` is printed as hex and is a *separate* field from `laneCount` and
`laneMask` — which is exactly the shape a packed nibble-per-lane map has, and
independent support for reading `0x3210` as four lanes rather than as a count.

The driver also formats `I2cSlaveAddr`, confirming it holds the value at runtime
even though no shipped blob stores it.

### `SCFG_*.bin` is a manifest, not config

Parsed for completeness: `SCFG_REAR_MSHW0491.bin` contains only the names of the
sensor-module and tuning blobs plus two opaque integers (`0x150020`, and a
per-sensor word that looks like a hash). No wiring. Negative result, recorded so
it is not re-checked.

### Second parser bug, same shape as the first

The first version of the base-finder accepted "the first plausible-looking
NUL-terminated string at the right distance". It picked bases that made
`sensorName` decode as `'delayUs'` and `'qValue'` — wrong, but only obviously
wrong because the tool prints a field whose correct value is known in advance.

Same lesson as the GPIO-pin bug, arrived at from the other direction: the check
has to be something that fails loudly. Matching on plausibility does not.

## Scoping the IMX681 driver

The front sensor has no driver in any tree, so one has to be written. Does that
need a datasheet? **Partly — the blob gets further than expected, but not far
enough.**

### What the sensor-module blob contains

| Field | Count / size |
|---|---|
| `regSetting` | 14 arrays — largest **14560 bytes**, then 8160, then five of 2720 |
| `slaveAddr` / `registerData` / `delayUs` | **915 of each** — the register-write entries |
| `streamConfiguration` | 6, one per mode |
| `resolutionData` | 1512 bytes |
| `powerSetting` | 84 and 72 bytes |

915 register writes across the init and per-mode sequences — exactly the shape of
the `reg_sequence` tables a Linux sensor driver carries.

### Where the addresses are — correcting this document

An earlier version of this section concluded the blob held register *data* but no
*addresses*, and recommended capturing the I²C bus at boot instead. **That was
wrong.** The addresses are in the blob. The mistake was looking at the record
table — which is the *schema*, one `slaveAddr` / `registerData` / `delayUs`
record per write, holding values only — instead of at the array in the data
section that `regSetting` actually points at.

That array is a flat run of **40-byte entries**, ten little-endian u32 each:

| Slot | Meaning |
|---|---|
| 0 | **register address** |
| 1 | `1` (constant) |
| 2 | record id of this entry's `slaveAddr` |
| 3 | `2` (constant) |
| 4, 5, 6 | `1`, `0`, `1` (constant) |
| 7 | record id of this entry's `registerData` — **the value is there** |
| 8 | `0` |
| 9 | record id of this entry's `delayUs` |

The address is inline; the value is one indirection away through the record
table, which is why the values looked deduplicated (915 writes referencing 103
distinct value slots).

### How it was cracked: known plaintext

Mainline `drivers/media/i2c/ov13858.c` carries the real register tables for the
OV13858 — this machine's *rear* sensor. So if addresses were stored at all, that
exact sequence had to appear in `com.surface.sensormodule.rfc_ov13858.bin`.

It does, at a 40-byte stride. Decoding through the layout above reproduces
mainline's values **15 out of 16** — the one difference being `0x3013` = `0x72`
where mainline has `0x32`, which is a genuine Surface-versus-Intel tuning
difference rather than a decode error. The blob also contains `0x3016`, which
mainline omits, confirming it is the real Surface variant and not a copy.

### Full cross-validation of the extractor

The 15/16 spot check was small, and the IMX681 driver rests entirely on this
extraction being right. Comparing **every** overlapping register between the
blob and mainline `ov13858.c`:

```
TOTAL: 508/558 matching (91.0%) across all overlapping registers
```

91% would be worrying if the 9% were scattered. They are not. Of the 16
differences in the largest table, **12 fall inside the crop/window/timing block
`0x3800`–`0x3813`**, and they are internally coherent:

| | blob | mainline |
|---|---|---|
| horizontal | start 64, end 4191, output **4076** | start 0, end 4255, output 4224 |
| vertical | start 160, end 3007, output **2806** | start 8, end 3159, output 3136 |

Start, end and output agree with each other in both cases — margins of 52 and 42
pixels. A mis-decode produces scattered nonsense, not a self-consistent smaller
window.

The three blob tables seal it. All three match `mode_4224x3136_regs` at ~91%,
and they differ **from each other** only in the crop registers — `0x3801` is
`0x40`, `0x40`, `0xe0`; `0x3806`/`0x3807` shift with it — while agreeing on the
other ~170. Three windows over one register program is what per-mode crops look
like. A decode error would not politely confine itself to the same twelve
addresses in three tables. The extractor is sound.

It also means something practical: **mainline's mode geometry is wrong for this
board.** The Surface runs the rear sensor at a 4076 × 2806 window, not the
4224 × 3136 full array `ov13858.c` programs. Anyone using the mainline driver
here as-is gets the wrong crop.

The four differences outside the window block:

| Register | blob | mainline | |
|---|---|---|---|
| `0x3013` | `0x72` | `0x32` | already noted |
| `0x3820` | `0xb0` | `0xa8` | **format/flip control** |
| `0x405e` | `0x00` | `0x20` | ISP trim |
| `0x4837` | `0x0d` | `0x0e` | PLL/MIPI timing |

`0x3820` matters beyond bookkeeping. On OmniVision parts that register carries
vertical binning and flip bits, and **flip changes the Bayer phase**. So the
Surface module is oriented differently from mainline's assumption — direct
evidence that CFA order is board-specific here, and a reminder that the IMX681
driver's `SRGGB10` guess is exactly the kind of thing that will be wrong until a
frame is captured.

### The IMX681 tables

`probes/chromatix_regs.py` extracts them. **901 writes across 7 tables** — a
363-entry init sequence, a 203-entry one, and five 67-entry mode tables. Saved
to `data/imx681-registers.txt`.

They validate themselves against Sony's conventions:

| Registers | Value | Meaning |
|---|---|---|
| `0x0136` / `0x0137` | `0x13` / `0x33` | **EXTCLK = 19.2 MHz** in 8.8 fixed point |
| `0x0112` / `0x0113` | `0x0a` / `0x0a` | CSI data format **RAW10** |
| `0x0114` | `0x00` | **CSI data lanes = 1** (Sony encodes lanes − 1) |
| `0x30eb` | `0x05`, `0x0c` | the standard Sony IMX unlock sequence |

Two of those are independent confirmations of things recovered elsewhere. The
19.2 MHz matches the MCLK4 rate from the `_RES` power blob, derived by a
completely different route. And `0x0114 = 0` **resolves the front camera's
`laneAssign = 0x0000`**, which was recorded as unresolved: it really is a
single-lane link.

### The blob does not state the Bayer order

Checked directly, because it is the driver's weakest assumption. Searching every
record name for colour, filter, pattern, order, phase or orientation terms turns
up only:

| Field | What it is |
|---|---|
| `noiseCoefficientBayer` (128 B) | tuning coefficients, not a CFA declaration |
| `colorBarMode`, `colorBarPeriod`, `patternType` | test-pattern generator, all zero-length |
| `numPixelsPerColor` | zero-length |

**There is no `colorFilterArrangement` or equivalent.** So the CFA phase cannot
be recovered from this file, and the driver's `SRGGB10` remains a one-in-four
guess. A single captured frame settles it.

One incidental find that does bear on another assumption:
`middleCoarseIntgTimeAddr = 0x30b2`. That is a vendor-range register for the
*middle* exposure of an HDR triple, which is consistent with the long exposure
living at the SMIA-standard `0x0202` the driver uses — weak corroboration, but
in the right direction.

### What the CamX DLL adds — and does not

With the headless throttles lifted, `QcDeviceMFT8380.dll` (23 MB) imports in
**5.8 minutes** and yields 23,667 functions. Worth stating because this project
previously recorded it as impractical: 23 MB analysed *faster* than 9.3 MB had
under the default 2 GB heap.

**The Surface IMX681 sensor lib contributes exactly one function.** Xrefing the
`imx681.cpp` `__FILE__` string finds a single caller,
`GetSensorModeIndex` at `0x1808712f0`. Everything else about this sensor comes
from the Chromatix blob, not from code.

That one function is still useful:

- it is entered for a request of `0xfc0` × `0xbd0` — **4032 × 3024** — at
  **≤ 30.0 fps**, so 30 fps is the ceiling
- and it selects the mode measuring `0xdc0` × `0xa50` — **3520 × 2640**

So the vendor's preferred mode for a full-field-of-view request is 3520 × 2640,
not the full array. Worth knowing when choosing the driver's default.

**The Bayer order is not there, and not anywhere.** `colorFilterArrangement` is
a real CamX field name, but searching `ffc_imx681.bin`, the 6.4 MB
`com.surface.tuned.ffc_imx681.bin`, and `rfc_ov13858.bin` for it and for every
Bayer spelling returns **zero hits in all three**. CamX obtains
`SensorInfoColorFilterArrangement` somewhere further up its static-metadata
path. The driver's `SRGGB10` therefore stays a one-in-four guess that a single
captured frame will settle — this is now a well-evidenced negative rather than
an unchecked assumption.

### The EEPROM address, incidentally

Of the 915 `slaveAddr` records exactly one carries data, and its value is
**`0xa0`** — an 8-bit I²C write address, `0x50` as 7-bit, sitting beside the
`EEPROMName` records. That is the module EEPROM, not the sensor.

Two things follow. Addresses in this format are 8-bit, so the sensor's own
address will be too when it turns up. And the DT will eventually want an
`eeprom@50` node on the same CCI bus.

### What this changes

The IMX681 driver is no longer blocked on a datasheet or on capturing the bus.
The register sequences, the link configuration, the clock rate and the lane count
are all in hand. What remains is ordinary driver-writing: mode geometry from
`resolutionData`, exposure/gain register mapping, and the V4L2 subdev plumbing —
with `ov02c10.c` as a structural template.

`data/ov13858-registers.txt` holds the rear sensor's 619 writes as well, useful
as a cross-check since mainline can validate them.

### A parser bug, third of its kind

`chromatix_parse.py` walked the record table with no upper bound, ran into the
data section, and decoded it as records — reporting field lengths like
`1732277888`. Anything derived from that output would have been nonsense.

The fix bounds the walk at the data-section base, which the first pass already
computes. Same lesson as the dropped GPIO pin number and the mis-located data
base before it: **a parser needs a limit it can fail against, not just a start.**

## The risk assessment was stale

The plan states:

> **no X1E device tree wires camss up at all** (checked crd, qcp, denali,
> romulus, xps13-9345, x1-crd — zero camera nodes in any)

and

> **Risk:** first-of-kind for any X1E laptop. No reference DT to copy.

Neither holds in our own tree (`grep -rn camss arch/arm64/boot/dts/qcom/x1*`):

| Board | Camera |
|---|---|
| `x1e80100-dell-xps13-9345.dts` | `ovti,ov02c10` |
| `x1e80100-lenovo-yoga-slim7x.dts` | `ovti,ov02c10` |
| `x1-dell-thena.dtsi` | `ovti,ov02e10`, full CSIPHY4 endpoint |
| `x1-crd.dtsi` | `&camss` node |
| `x1-asus-zenbook-a14.dtsi` | `&camss` node |
| `x1e78100-lenovo-thinkpad-t14s.dtsi` | `&camss` node |

`x1-dell-thena.dtsi` is a complete, copyable template — CSIPHY port mapping,
sensor node on `cci1_i2c1`, MCLK via `camcc`, reset GPIO, three supplies, and
both ends of the endpoint link:

```dts
&camss {
	status = "okay";
	ports {
		/* port0 => csiphy0, port1 => csiphy1, port2 => csiphy2, port3 => csiphy4 */
		port@3 {
			camss_csiphy4_inep0: endpoint@0 {
				clock-lanes = <7>;
				data-lanes = <0 1>;
				remote-endpoint = <&ov02e10_ep>;
			};
		};
	};
};

&cci1_i2c1 {
	camera@10 {
		compatible = "ovti,ov02e10";
		reg = <0x10>;
		reset-gpios = <&tlmm 237 GPIO_ACTIVE_LOW>;
		clocks = <&camcc CAM_CC_MCLK4_CLK>;
		assigned-clock-rates = <19200000>;
		orientation = <0>;
		avdd-supply  = <&vreg_l7b_2p8>;
		dvdd-supply  = <&vreg_l7b_2p8>;
		dovdd-supply = <&vreg_cam_1p8>;
		port {
			ov02e10_ep: endpoint {
				data-lanes = <1 2>;
				link-frequencies = /bits/ 64 <360000000>;
				remote-endpoint = <&camss_csiphy4_inep0>;
			};
		};
	};
};

&csiphy4 {
	vdda-0p8-supply = <&vreg_l2c_0p8>;
	vdda-1p2-supply = <&vreg_l1c_1p2>;
	status = "okay";
};
```

This is ground rule 1 paying for itself. The pillar is board bring-up against a
worked example, not pioneering.

## Revised Pillar 2

| Step | Status |
|---|---|
| 1 — name the parts | **done** — OV13858 / IMX681 / VD55G0 |
| 2 — driver survey | **done** — rear has an ACPI-only driver, front has none, IR has none |
| 3 — extract regulators/clocks/GPIOs | **done** — from `CAM*_RES_MSHW*.bin`, not the DSDT |
| 3b — CSI lane assignment | **done for the rear** — 4 lanes (`0x3210`); front unresolved |
| 3b' — I²C address and CCI bus | open — **not** in the blobs; needs the driver binaries or `i2cdetect` |
| 3a — make `ov13858.c` DT-probeable | **done** — `lain3d/surface-pro-11-kernel#1`, compile-tested |
| 3c — add the `_m` camera PMIC to `x1-microsoft-denali.dtsi` | new prerequisite for step 4 |
| 4 — write the nodes into `x1-microsoft-denali.dtsi` | template exists: `x1-dell-thena.dtsi` |
| 5–6 — boot, probe, libcamera | unchanged, needs hardware |

Nothing here needed hardware, and steps 3 and 3a still do not.

## The camera platform, from ACPI

`sensorSlaveAddress` being empty had been read as "the blob does not carry
addresses". Following the per-entry `slaveAddr` indirection shows something more
useful: exactly one non-empty `slaveAddr` per blob, always `0xa0`, and it belongs
to the module's EEPROM (`gt24p128f_imx681` / `st_m24c64`, a 24C64-class part at
7-bit `0x50`).

So the format stores slave addresses fine. The sensor's is absent on purpose.
Confirmed three ways, using the OV13858 — whose address is public — as control:

- no record in any blob decodes to `0x6c`, `0x6d`, `0x36` or `0x37`
- the u16 `0x006c` occurs **once** in the whole data section
- there is no `probe` / `chipId` / `expectedData` record group at all

That is as strong as this negative gets. **Every module does have an EEPROM at
7-bit `0x50` on the sensor's own CCI bus**, which is both a DT node and, once
booted, the thing that identifies which bus a sensor is on.

### Device map

`_HID` names the sensor outright, independently of the blobs:

| ACPI | `_HID` | `_SUB` | Sensor | MCLK | MCLK pin | Reset | Rails |
|---|---|---|---|---|---|---|---|
| CAMF | `SONY0681` | MSHW0490 | IMX681, front | `mclk4` | gpio100 (`cam_aon`) | gpio237 | LDO3_M 1.8 V, LDO7_B 2.8 V |
| CAMS | `OVTID858` | MSHW0491 | OV13858, rear | `mclk1` | gpio97 | gpio110 | LDO6_M 1.8, LDO1_M 1.2, LDO5_M 2.8, LDO16_B 2.9 V |
| CAMI | `SMO55F0` | MSHW0492 | VD55G0, IR | `mclk0` | gpio96 | gpio109 | LDO4_M 1.8, LDO2_M 1.15, LDO7_M 2.8 V |

Clocks and rails come from the `CAM*_RES_MSHW*.bin` power blobs in execution
order (`probes/camres_summary.py`). All three also pull `gcc_camera_xo_clk`,
`gcc_camera_ahb_clk`, `cam_cc_gdsc_clk` and `cam_cc_cpas_ahb_clk` at 80 MHz,
take the `cam_cc_titan_top_gdsc` footswitch, and run MCLK at 19.2 MHz.

### Which CCI bus the front camera is on

This looked like it needed a booted `i2cdetect`. It does not — the pin
assignment settles it.

`CAMP_RES_MSHW0495.bin` lists the pins the camera platform claims:
**96, 97, 100, 101, 102, 103, 104, 235, 236**. Against `hamoa.dtsi` and
`pinctrl-x1e80100.c`:

| Pins | Group | In CAMP's list? |
|---|---|---|
| 101, 102 | `cci0_i2c0` | yes |
| 103, 104 | `cci0_i2c1` | yes |
| 105, 106 | `cci1_i2c0` | **no — unused on this board** |
| 235, 236 | `cci1_i2c1` (`aon_cci`) | yes |
| 96, 97 | `cam_mclk` (mclk0, mclk1) | yes |
| 100 | **`cam_aon`**, not `cam_mclk` | yes |

Three sensors, three buses, and the odd one out is the always-on group. The
front camera is the one on `cam_cc_mclk4_clk`; gpio100's pinmux function is
`cam_aon` rather than `cam_mclk`; and CAMF's reset line is **gpio237**, adjacent
to the AON I2C pair at 235/236.

So: **IMX681 sits on `cci1`, `i2c-bus@1`** — the always-on bus — with its MCLK on
gpio100 under the `cam_aon` function. That last detail is the one that pattern-
matching the other two sensors would have got wrong: a DT node for this sensor
cannot use `function = "cam_mclk"`.

Which of `cci0_i2c0` / `cci0_i2c1` carries the rear versus the IR sensor is still
open; their reset lines (110 and 109) are adjacent and do not discriminate. Not
needed for the front-camera work.

### Platform blocks, and a validation of the GSIV arithmetic

| ACPI | `_HID` | MMIO | GSIV | GIC SPI |
|---|---|---|---|---|
| CAMP | `QCOM0C32` | `ac13000`/4K, `ac19000`/48K, `ac15000`/4K, `ac16000`/4K | 492, 303, 491 | 460, 271, 459 |
| MPCS | `QCOM0C98` | `ace4000`, `ace6000`, `ace8000`, `acec000` (8K each); `acf6000`, `acf7000`, `acf8000` (1K each) | 509, 510, 511, 154 | 477, 478, 479, 122 |
| JPGE | `QCOM0C33` | `ac2a000`, `ac2b000` | 506, 507 | 474, 475 |
| VFE0 | `QCOM0C25` | — | 488, 319, 495–501, 721, 796, 797 | 456, 287, 463–469, 689, 764, 765 |

`hamoa.dtsi` independently has `cci@ac15000`, `cci@ac16000` and
`csiphy@ace4000` / `ace6000` / `ace8000` / `acec000` — the same addresses,
**including the same gap where csiphy3 would be**. Two unrelated sources agreeing
on an irregular set is worth more than either alone.

The interrupts check out arithmetically too: `hamoa.dtsi` gives cci0
`GIC_SPI 460` and cci1 `GIC_SPI 271`; ACPI reports GSIV 492 and 303. **GSIV − 32
reproduces both.** That is the same conversion the USB4 DT nodes rest on, tested
here against numbers derived by someone else — so it is no longer an assumption
in that work either.

The three 1 KiB blocks at `acf6000`–`acf8000` appear in no qcom dtsi and remain
unidentified. `MPCS` returns a reduced resource set when `\_SB.SDFE == 0x9A`
(csiphy0 and csiphy4 only), so the same firmware serves a two-camera variant.

### What is left for the front-camera DT node

Everything except one value. Bus, MCLK, pinmux function, reset line and both
regulators with their voltages are established above, and
`drivers/clk/qcom/camcc-x1e80100.c` plus the `cci0` / `cci1` / `camss` nodes
already exist in this tree — all `status = "disabled"`, so the board file only
has to enable them.

The missing value is the sensor's I2C address, and the evidence above is that it
is not recoverable from the firmware. One `i2cdetect` on `cci1 i2c-bus@1` after
boot gives it, and the EEPROM at `0x50` on the same bus confirms the right bus
was found.

Writing the node with a plausible-looking address instead would repeat the
`vts_def` mistake exactly: a fabricated constant that looks researched.

## Settling the Bayer/CFA order

The other value that cannot be derived. `imx681.c` declares
`MEDIA_BUS_FMT_SRGGB10_1X10` and that is **a guess**, marked as such in the code.

A sensor is colour-blind; a Colour Filter Array puts a coloured filter over each
photosite, in a repeating 2 × 2 cell of one red, one blue and two green. The
*order* is which colour lands on the frame's first pixel — RGGB, BGGR, GRBG or
GBRG. Demosaicing has to know which, or red and blue swap (skin goes blue) or
the green phase is wrong (maze-like colour artefacts).

**It is board-specific, not a property of the part**, because the phase moves
with where readout starts. Two things move it: an odd crop offset, and a flip.
Here the crop offsets are all even (64/160 against mainline's 0/8), so those do
not move it — but **`0x3820` differs, `0xb0` against mainline's `0xa8`**, and
that register carries binning and flip. That is the concrete evidence that the
Surface module's phase cannot be assumed to match anyone else's.

For contrast, mainline's OV13858 uses `SGRBG10`. Different sensor, different
board — it tells us nothing about the IMX681.

### The procedure

`tools/sp11-bayer.py` renders one raw frame under all four orders.

```bash
v4l2-ctl -d /dev/video0 --set-fmt-video=width=4032,height=3024,pixelformat=RG10 \
         --stream-mmap --stream-count=1 --stream-to=frame.raw
./tools/sp11-bayer.py frame.raw 4032 3024
```

**Shoot something strongly and unambiguously coloured** — a red object on a
neutral background. A grey or white scene cannot distinguish a red/blue swap and
wastes the capture.

One limitation, stated because the tool's own output demonstrates it: channel
means narrow the answer to a **pair**, not a single order. RGGB and BGGR are
mirror images of each other, as are GRBG and GBRG. So the numbers tell you which
*pair* you are in, and the rendered images — or a known-coloured subject — tell
you which of the two.

Verified against a synthetic frame with a known answer: a patch placed only on
the R sites of an RGGB grid produces `R/G 1.37` under RGGB, the mirrored
`B/G 1.37` under BGGR, and pushes the energy into green under both of the other
two, which is correct.

## STAGED 2026-08-06 (integ43): the front camera is wired end to end

Everything above was analysis. This is the first build in which the front camera
could actually bind, and it exists because three separate things were missing at
once — each of which on its own looks like "the camera does not work".

### 1. The driver was not in the kernel at all

`CONFIG_VIDEO_IMX681` was **not set** in the config that built every kernel this
project has booted. The annotation commit (`06d60ac34`) adds it to
`debian.qcom-x1e/config/annotations`, but the config actually used is
`config-stock-7.0.0-22` run through `olddefconfig` — which does not read the
annotations, so the symbol silently stayed off.

That is worth stating plainly: `imx681.ko` existed in the worktree since Aug 2
and had never been in a running kernel. Any earlier conclusion of the form "the
driver loaded and did nothing" would have been about a module that was not there.

Enabled as `=m`; the config delta is exactly one line, verified by diff.

### 2. camss and csiphy2 were disabled, so probe could not have succeeded

The DT node carried a comment saying so — probe was *expected* to fail at
`v4l2_async_register_subdev_sensor()` because there was no endpoint and no
receiver. The debug branch only ever wanted the bus scan, which runs earlier.

Now wired, in `x1-microsoft-denali.dtsi`:

| | |
|---|---|
| `&camss` | `status = "okay"`, `port@2` endpoint → the sensor |
| `&csiphy2` | `status = "okay"`, `vdda-0p8` = `vreg_l2c_0p8`, `vdda-1p2` = `vreg_l1c_1p2`, `phy-type = <PHY_TYPE_DPHY>` |
| `camera@10` | `port { endpoint }` → camss, `data-lanes = <1>`, both link frequencies |

`port@2` is CSIPHY 2 because that is what the connection word in
`CAMP_PCFG_MSHW0495.bin` gives the front sensor, and the port-to-phy mapping
(`port0→csiphy0, port1→csiphy1, port2→csiphy2, port3→csiphy4`) is the comment
`x1e80100-dell-xps13-9345.dts` carries over its own `port@3`.

The supplies are not a guess either: `phy-qcom-mipi-csi2-3ph-dphy.c` names
`vdda-0p8` and `vdda-1p2` in `mipi_csi2_dphy_4nm_x1e.supply_names`, and the
xps13 gives csiphy4 those exact two rails, both of which denali already defines.

**One lane.** The blob writes `0x0114 = 0` and Sony encodes lanes − 1. This also
retires the `laneAssign = 0x0000` that was recorded above as unresolved — it was
a genuine single-lane link, not a bad decode.

The DTB builds with no dtc warnings, and the two endpoints cross-reference
correctly (sensor phandle `0x110` ↔ csiphy `0x10b`), checked in the decompiled
output rather than assumed from the source.

### 3. `reg = <0x10>` is no longer a placeholder

The bus scan answered at `0x10` and at `0x50`. `0x50` is the module EEPROM on the
sensor's own bus, so the address and the bus are confirmed *together* — the
EEPROM is what proves the right bus was found, exactly as predicted above.

**What is still not confirmed is that the device at `0x10` is an IMX681** — and
the reason is sharper than "the driver has no chip-ID check".

Every I²C transaction in `imx681.c` was in `write_regs`, `set_stream`, `set_ctrl`
or the debug bus scan. **None of those are in the probe path**, so `probe()`
completed without ever addressing the sensor. An i2c client is *declared* by its
DT node, not discovered — I²C has no enumeration — so it is created whether or
not anything is physically present. Probe would have succeeded with the sensor
unsoldered.

So a successful probe proves the DT, the clock rate, the rails, the reset line
and the media graph link. It proves nothing about the silicon, not even that the
silicon exists.

Fixed: probe now reads SMIA's model ID at `0x0000` and CCS's sensor model ID at
`0x0016`. The blob carrying no model-ID register is a fact about the *blob*, not
about the part — Sony's IMX sensors follow those conventions whether or not
Qualcomm's stack reads them. Logged, never fatal, because no expected value has
been observed and gating probe on a guessed constant would repeat the `vts_def`
mistake. `0x0681` in either register settles it and turns this into a real
chip-ID check.

### What integ43 is

`BOOTAA64-integ43-camera.efi` = integ40 with the new DTB and **nothing else**:
`.cmdline`, `.linux` and `.initrd` were compared byte for byte against integ40
and are identical, so thunderbolt stays blacklisted and this changes only the
device tree. `imx681.ko` is installed on the T7 at the matching vermagic
(`7.1.3-sp11-stockcfg-gf2cc827b6b89`), and `depmod` resolves its five
dependencies, all of which were already present.

Rollback is one file copy of integ40 from `C:\sp11-stage`.

### How to test it

`tools/sp11-camera-test.sh`, run on the booted machine. It checks the live device
tree first, because "wrong UKI" and "driver broken" look identical otherwise.

Two things are expected to be wrong even on success:

- **Bayer order.** `SRGGB10` is a one-in-four guess; the blob has no
  `colorFilterArrangement` and searching all three blobs for one returned
  nothing. `tools/sp11-bayer.py` settles it from a frame — shot against
  something strongly coloured, since a grey scene cannot show a red/blue swap.
- **Frame rate at full resolution.** 4032×3024 needs ~365 Mpix/s; a single lane
  at the 998.4 MHz link frequency gives ~200 Mpix/s, i.e. about 16 fps. That is
  consistent with the vendor's own `GetSensorModeIndex()` substituting
  3520×2640 for a 30 fps full-array request, and it is why the test script
  captures at 3520×2640.

## CONFIRMED 2026-08-06: the sensor is an IMX681

The chip-ID read added to probe answered on its first boot:

```
imx681 1-0010: DEBUG:   0x10 ACK
imx681 1-0010: DEBUG:   0x1a ACK
imx681 1-0010: DEBUG:   0x50 ACK  (module EEPROM)
imx681 1-0010: DEBUG: 3 responder(s); DT node says 0x10
imx681 1-0010: ID: model_id        (SMIA 0x0000) = 0x0000
imx681 1-0010: ID: sensor_model_id (CCS  0x0016) = 0x0681
```

**`0x0681`.** The device at `0x10` on the always-on CCI bus is a Sony IMX681,
established by reading the part rather than by inferring it. SMIA's `0x0000` is
not implemented (reads zero); the CCS register at `0x0016` is — which is why
reading both mattered.

This retires the standing caveat that "only a frame identifies the sensor". It
also means the driver can gain a real chip-ID check: `0x0016 == 0x0681`.

Note the bus number is `1-0010` here and was `5-0010` on the 2026-08-04 boot.
i2c adapter numbering is not stable across boots; the bus is identified by the
EEPROM at `0x50`, not by the number.

### Probe does not fail without camss

The DT comment claimed probe would fail at `v4l2_async_register_subdev_sensor()`
when camss was disabled. **It does not.** With camss disabled the driver still
binds — `/sys/bus/i2c/drivers/imx681/1-0010` exists — because async subdev
registration succeeds with no notifier present and simply waits for one. What is
absent is the devnode, since nothing creates a `v4l2_device`:

```
=== 5. media graph ===   no /dev/media* -- camss did not register
=== 7. sensor controls ===   no subdev identifies as imx681
```

### The integ43 mistake, recorded so it is not repeated

integ43 was built as "integ40 + camera" and failed to boot twice: the root disk
never enumerated, and the failure capture showed no USB devices at all.

The cause was not the camera. **integ40's DTB was built from `debug/ramoops` in
`wt-ov13858`, and I rebuilt in `wt-cfg`** — a different topic branch. Verified
afterwards by building `debug/ramoops`'s DTB and finding it byte-identical to the
one embedded in integ40. So integ43 also carried four unrelated DT changes:

| | integ40 (boots) | integ43 (failed) |
|---|---|---|
| `ramoops@b0000000` | present | deleted |
| `pcie4_port0` PERST#/WAKE# | present | deleted |
| USB4 `iommus` + `power-domains` x3 | present | deleted |
| `vreg_l16b_2p9` / `vreg_l2m_1p15` | 2912000 / 1152000 | 2900000 / 1150000 |

Which one broke USB was never determined, and does not need to be: integ44
rebuilds the camera change on the correct base, and its DTS delta against
integ40 is the camera and nothing else.

**The checking method matters more than the fix.** Adding nodes renumbers every
later phandle, so a raw `dtc` diff is thousands of noise lines. Drop `phandle = `
lines and normalise `<0x...>` vectors before diffing — and never conclude from
`head -80` of the raw diff, which is what let all four through.
