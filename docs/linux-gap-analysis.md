# What it would take to fix the Linux gaps

> **Read `linux-prior-art.md` first.** This document analyses what it *would* take.
> It was written before discovering that most of it has already been done — pen,
> touchscreen (single-touch), audio, suspend and sensors all work today in
> `denisix/ubuntu-surface-pro-11`. What remains genuinely open is USB4, cameras, and
> multi-touch — and those three are researched in that document too. Two corrections
> it makes to this one: cameras are far closer than assessed here (the
> `qcom,x1e80100-camss` ISP driver is already mainline; only board DT wiring is
> missing), and multi-touch probably needs userspace heatmap processing rather than a
> kernel driver.
>
> That last guess has since been confirmed: the digitizer declares a 7488-byte
> full-frame report on a `Capacitive Heat Map Digitizer` collection, reachable from
> the `hidraw` node userspace already opens. See
> [multitouch-heatmap.md](multitouch-heatmap.md).

Assessed against one stated constraint: **hardware reverse engineering is a blocker,
software reverse engineering is not.** So the key column is not "how hard" but "does
this require touching the board".

Short answer: **none of it requires hardware RE.** Every unknown on this machine is
recoverable from ACPI tables, Windows driver binaries, or published specifications.

## Correction to `linux-support.md`

That document says the pen needs an IPTS-scale multi-year reverse-engineering effort.
**That is wrong**, and the error is worth stating plainly because it inverts the
verdict.

The Surface Pro 11 digitizer reports:

```
DEVPKEY_Device_CompatibleIds = ACPI\PNP0C51 | PNP0C51
DEVPKEY_Device_Service       = hidspi
DEVPKEY_Device_DriverInfPath = hidspi_km.inf
```

**`PNP0C51` is the standard ACPI ID for a HID-over-SPI device** — a published Microsoft
specification, bound to Microsoft's *inbox* `hidspi.sys` / `HidSpiCx.sys`. It is not a
Surface-proprietary protocol.

This is categorically different from Intel Surfaces, where IPTS genuinely was
proprietary and did take years to reverse. Here the protocol is documented, and open
implementations already exist.

## Ranked by (value × tractability)

### 1. Touchscreen + pen — the actual requirement

| | |
|---|---|
| Hardware RE | **No** |
| Difficulty | **Moderate** — integration, not reverse engineering |
| Blocking unknowns | which SPI controller + GPIO the digitizer hangs off |

The device is `ACPI\MSHW0485`, compatible `PNP0C51`, exposing **ten HID collections**
(`Col01`–`Col0A`) — touch, pen, buttons, and firmware-update endpoints. On Windows the
whole `Surface Touch G6` stack, `Surface Digitizer`, and `Surface Touch Pen Processor`
are just HID collections on that one SPI device.

Existing code you would not have to write:

- **`linux-surface/spi-hid`** — an out-of-tree HID-over-SPI driver, lifted from the
  Surface Duo 2 kernel sources.
- **Upstream `spi-hid` v3 patch series**, posted April 2026, implementing HID Over SPI
  Protocol Specification 1.0.
- **`drivers/hid/hid-goodix-spi.c`** in mainline — an in-tree example of an SPI HID
  transport, useful as a structural reference.

The work is therefore:

1. Build the spi-hid driver (or apply the v3 series) against the Denali kernel.
2. Add a device-tree node for the digitizer on the correct QUP SPI controller with the
   right GPIO interrupt and reset lines.
3. Debug until HID reports come through.

The controller is very likely **QUP1 SE2**. The DSDT contains an ACPI device `SP11`
(`_HID QCOM0C0E`, `_SUB MSHW0489`) whose `_STR` reads literally `"QUP_1_SE_2,QSPI"`.
Confirming the mapping and extracting the GPIO/IRQ numbers is a matter of reading ACPI
and the Windows PnP resource assignments — both already dumped in this repo.

**Known risk:** the v3 series notes it does not yet support multi-fragment input
reports, `GET_INPUT`/`COMMAND` output report types, or device sleep. A
ten-collection digitizer with pen data plausibly needs multi-fragment reports. That may
need implementing — still spec work against a published document, not RE.

Realistic estimate: days if the DT node is straightforward and the driver works
as-is; weeks if multi-fragment support has to be written.

### 2. USB4 / Thunderbolt — the one that matters for eGPU

| | |
|---|---|
| Hardware RE | **No** |
| Difficulty | **Moderate-high** |

Linux's `thunderbolt` driver already implements USB4 host routers, and the USB4
specification is public. The complication is platform shape: on this SoC the host
router is **ACPI/DT-enumerated, not a PCIe device** (established in
`device-profile.md` — Qualcomm's `QcUsb4Bus` binds `ACPI\QCOM0C6D` and publishes an
`ACPI\ACPI0015` PDO for Microsoft's connection manager).

So the work is binding Qualcomm's host router to Linux's USB4 stack plus the retimer
and PHY glue, rather than writing a tunneling implementation. `ACPI0015` is the
standard USB4 host-router ID, which is a good sign — Linux already knows that ID.

Nobody appears to have done USB4 on a Qualcomm platform under Linux yet, so this would
be first-of-kind, with the associated risk.

### 3. Audio quality — best effort-to-reward ratio

| | |
|---|---|
| Hardware RE | **No** |
| Difficulty | **Low-moderate** |

Speakers work but distort; microphones are unusably distorted. This is almost
certainly missing amplifier configuration and speaker-protection parameters plus DMIC
setup — i.e. `alsa-ucm-conf` profiles and AudioReach topology data, not driver work.
Topology blobs are extractable from the Windows install alongside the other firmware.

### 4. Suspend / resume — the only item that flirts with hardware access

| | |
|---|---|
| Hardware RE | **Probably not, but this is the closest call** |
| Difficulty | **High, and tedious** |

Resume hangs, black screens, and random freezes are reported — including freezes when
suspending with the Surface keyboard attached. Debugging this needs log extraction
across a failed resume, which normally means `pstore`/`ramoops` or a serial console.

The `DBG2` ACPI table exists on this machine and describes a debug port, so a software
route likely exists. If it turned out to need physical UART test points, that is the
one place this list touches hardware — and it is a soldering-and-probing job, not
reverse engineering.

### 5. Cameras — no hardware RE, but not really your project

| | |
|---|---|
| Hardware RE | **No** |
| Difficulty | **Very high, and mostly gated on Qualcomm** |

Sensors are fully identified in ACPI already:

| ACPI device | `_HID` | Role |
|---|---|---|
| `CAMS` | `OVTID858` | rear (OmniVision) |
| `CAMF` | `SONY0681` | front (Sony) |
| `CAMI` | `SMO55F0` | infrared (Windows Hello) |
| `MPCS` | `QCOM0C98` | Spectra 695 ISP |
| `CAMP` | `QCOM0C32` | camera platform |
| `FLSH` | `QCOM0C27` | flash |

So identification is done. What is missing is CAMSS/ISP support for X1E in the kernel
plus libcamera plumbing — a large upstream effort, largely Qualcomm's to deliver.
Writing sensor drivers is tractable; the ISP is not, alone.

### 6. Status LEDs, Surface Dock connector

Low value, low difficulty, SAM/GPIO work. Ignore until everything else works.

## Summary

| Item | Hardware RE | Difficulty | Prior art exists |
|---|---|---|---|
| Touchscreen + pen | No | Moderate | **Yes — spi-hid, upstream v3** |
| USB4 / Thunderbolt | No | Moderate-high | Partial — Linux USB4 stack |
| Audio quality | No | Low-moderate | Yes — UCM/topology |
| Suspend / resume | Probably not | High | No |
| Cameras | No | Very high | Gated on Qualcomm |
| LEDs / dock | No | Low | SAM already upstream |

Nothing on this list is blocked by the constraint you set. The pen — the item that
actually decides whether Linux is usable for you — is the second most tractable thing
on it.

## The first thing to do

Confirm the digitizer's SPI controller and GPIO assignment, using data already in this
repo plus the live Windows PnP resource tree. That is a few hours of work, costs
nothing, and determines whether the device-tree node is a ten-line addition or a
research problem.
