# Who has already solved what — Linux on Surface Pro 11

Checked 2026-08-01, specifically to avoid repeating work. The short version: **almost
everything in `linux-gap-analysis.md` has already been done by someone else**, most of
it within the last few weeks.

## The main result

**[`denisix/ubuntu-surface-pro-11`](https://github.com/denisix/ubuntu-surface-pro-11)**
— last pushed **2026-07-29**, three days before this was written.

Target device is essentially identical to this machine: Surface Pro 11, **OLED**,
X1E80100, SKU `Surface_Pro_11th_Edition_2076`, no 5G. Built on Ubuntu Concept
(`resolute-desktop-arm64+x1e`).

It contains scripts, kernel patches, firmware extraction, configs and source — not just
notes.

### Against the two hard requirements

| Requirement | Status | How |
|---|---|---|
| **Pen** | ✅ **Working** | Slim Pen 2: 1–4095 pressure, hover, tip contact, eraser |
| **Detachable keyboard** | ✅ **Working** | "Type Cover touchpad and keyboard work when attached" |

The keyboard line explicitly says *Type Cover*, which is the older non-Bluetooth
keyboard — the one in question.

### Full status from that repo

| Feature | Status | Notes |
|---|---|---|
| NVMe, graphics, backlight | ✅ | custom DTB + patched kernel |
| Wi-Fi | ✅ | rfkill bypass + board-data extraction |
| Bluetooth | ✅ | MAC configured via `btmgmt` helper |
| Audio — speakers | ✅ | WSA884x via PipeWire sink + WSA routing service |
| Audio — microphone | ✅ | dual far-field DMIC, VA macro at 2.4 MHz (kernel patch) |
| **Touchscreen** | ⚠️ | **single-touch only** — no pinch-zoom, no two-finger scroll |
| **Pen** | ✅ | hybrid HEAT/uinput auto-switching daemon |
| Keyboard + touchpad | ✅ | Type Cover, attached |
| Suspend / resume | ✅ | s2idle via lid daemon + `cpu-sleep-0` cpuidle workaround |
| Sensors | ✅ | 13 SSC sensors + tablet mode via SSAM |
| NPU | ✅ | llama.cpp on Hexagon HTP0 — Llama-3.2-1B ~48 t/s, Qwen2.5-Coder-3B ~21 t/s |
| **USB4 / Thunderbolt** | ❌ | still nothing |
| Cameras, status LEDs | ❌ | still nothing |

## How the pen actually works, and why touch is limited

This is the part worth understanding before relying on it.

The digitizer is one sensor serving both finger and pen, over HID-over-SPI
(VID `045E`, PID `0C83`). It has **two mutually exclusive modes**:

- **Standard HID (`05 00`)** — single-touch finger events
- **HEAT mode (`05 01`)** — raw capacitive data, no standard HID events

> **Correction.** "68×46 capacitive matrix" was wrong for the mode the daemon
> actually enables: `05 01` yields a 464-byte report holding two 1-D projections
> (46-bin and 68-bin). A true full-frame mode does exist — a 7488-byte report on
> the `Capacitive Heat Map Digitizer` collection — but nothing on Linux enables it
> yet. See [multitouch-heatmap.md](multitouch-heatmap.md).

No kernel driver switches between them, so a userspace daemon (`sp11-pen-daemon`)
does it: default to finger mode, probe for 25 ms when fingers go idle, switch to HEAT
if pen energy exceeds a threshold, parse the matrix (weighted centroid → position,
signal energy → pressure), emit via uinput, and restore finger mode after 1 s of pen
inactivity.

Two consequences:

1. **Multi-touch is not available.** Real multi-touch requires interpreting a full
   heat-map frame continuously — the same shape of problem IPTS solves on Intel
   Surfaces. So my earlier IPTS comparison was wrong about the *protocol* (it is
   standard HID-over-SPI, not proprietary) but right that heatmap processing is
   involved for the full experience. It does **not** need a kernel driver: the
   full-frame report is reachable from the same `hidraw` node the daemon already
   opens. See [multitouch-heatmap.md](multitouch-heatmap.md).
2. **Mode switching has latency.** Pen pickup costs up to a 25 ms probe cycle; touch
   restore waits 1 s after the pen goes idle.

## Corrections this forces

`linux-support.md` and `linux-gap-analysis.md` were both written before finding this
and are wrong in places:

| Earlier claim | Reality |
|---|---|
| Pen needs IPTS-scale multi-year RE | Wrong — it is standard HID-over-SPI, and it is already working |
| Pen "not working, but tractable" | Understated — someone has it working now |
| Audio is `⚠️ partial`, mic unusable | Fixed upstream of us — speakers and DMIC both working |
| Suspend/resume `⚠️`, hangs | Solved with a lid daemon plus a cpuidle workaround |
| Touchscreen simply `❌` | Single-touch works; multi-touch is the actual gap |
| Cameras `❌` | Still true |
| **USB4/Thunderbolt `❌`** | **Still true — the eGPU conclusion holds** |

## The earlier trail, for context

The path was worked out publicly over the past year in
[`dwhinham/linux-surface-pro-11` issue #10](https://github.com/dwhinham/linux-surface-pro-11/issues/10)
("Digitizer and Pen Input", open since 2025-07-04):

- **hmelder**, 2025-07-04/05 — identified HID-over-SPI; found the ACPI `SP11` device
  (`QCOM0C0E`, `_STR "QUP_1_SE_2,QSPI"`, base `0xA88000`, IRQ `0x342`); mapped it to
  `spi10` in `x1e80100.dtsi`; located the touchscreen as `GTCH` with `_CID "PNP0C51"`
  **in the SSDT**; identified GPIOs 40/41/42 (data+clk), 43 (cs).
- **hmelder**, 2025-08-18 — published a working DTS overlay.
- **hot21shot**, 2025-12-16 — combined it with `linux-surface/spi-hid`, plus a
  `spi-geni-qcom` patch to force `SPI_SE_SPI` and avoid proto error 9.
- **denisix**, 2026-07-28 — announced touchscreen and pen working; repo above.

Independently reaching the same `SP11` / `QUP_1_SE_2,QSPI` / `PNP0C51` conclusions was
a decent sanity check on the method, but it was re-derivation, not discovery.

Note `linux-surface/spi-hid` itself is **stale — last commit 2022-09-09**, lifted from
Surface Duo 2 sources. The upstream `spi-hid` v3 series (April 2026) is the live
effort. The SP11 work uses the old out-of-tree driver plus local patches.

## The three remaining gaps, researched

### 1. USB4 / Thunderbolt — Qualcomm is already on it

**Do not build this yourself.**

Linux's USB4 subsystem is structurally PCIe-only:

```
config USB4
	tristate "Unified support for USB4 and Thunderbolt"
	depends on PCI
```

The Native Host Interface (`nhi.c`) assumes a `pci_dev`. Qualcomm's host router is
MMIO-mapped and ACPI/DT-enumerated instead, and **`ACPI0015` has zero occurrences in
mainline** — Linux cannot enumerate an ACPI-declared host router at all today.

But there is a live upstream effort:

| | |
|---|---|
| Series | *"dt-bindings: thunderbolt: Add Qualcomm USB4 Host Router"* (RFC) |
| Author | **Konrad Dybcio, Qualcomm** |
| Date | 2025-09-17 |
| Reviewer | Mika Westerberg (Intel), thunderbolt maintainer |
| Status | **RFC, not merged** — no `qcom_usb4.c` in `drivers/thunderbolt` |

Approach: a new `qcom_usb4.c` handling Qualcomm init, firmware load and MCU wake-up,
reusing the thunderbolt core, and — the structurally significant part — **refactoring
NHI to accept both PCI and platform devices**, replacing the `pci_dev *` with a
generic `struct device *`. Type-C integration goes through `pmic_glink_altmode`/`ucsi`.
X1E is named as a target.

Westerberg's feedback: split PCI code into `pci.c` and platform code into
`platform.c`, reconsider MSI forward-compatibility in DT, define power-contract
properties matching the ACPI equivalents, and describe USB4 ports and retimers in DT.

Assessment: this is Qualcomm-scale plumbing touching a maintained subsystem's core
abstraction. Duplicating it would be wasted effort. Track the series instead.

**Caveat that matters for eGPU:** even once the host router lands, that is the
*transport*. Whether **PCIe tunneling** works over it is a separate question the thread
does not address. USB4 host router support is necessary but not sufficient for an eGPU.

### 2. Cameras — much closer than previously assessed

Earlier this was called "very high difficulty, gated on Qualcomm". That was wrong.
The hard part is already upstream:

- **`qcom,x1e80100-camss`** is a supported compatible in `drivers/media/platform/qcom/camss/camss.c`
- **`Documentation/devicetree/bindings/media/qcom,x1e80100-camss.yaml`** exists

So the X1E ISP driver is merged. What is missing is **board integration**:

1. ~~**No X1E device tree wires camss up.**~~ **Stale — see
   [camera-sensors.md](camera-sensors.md).** In our own 7.1.3 tree, six X1E boards
   have `&camss` nodes: `x1e80100-dell-xps13-9345.dts` and
   `x1e80100-lenovo-yoga-slim7x.dts` (both `ovti,ov02c10`), `x1-dell-thena.dtsi`
   (`ovti,ov02e10`, with a full CSIPHY4 endpoint), plus `x1-crd.dtsi`,
   `x1-asus-zenbook-a14.dtsi` and `x1e78100-lenovo-thinkpad-t14s.dtsi`. There is a
   copyable template. This is no longer first-of-kind.
2. **Sensor drivers** for the specific parts — now identified from Qualcomm's
   per-SKU sensor blobs: `OVTID858` = **OV13858** (rear), `SONY0681` = **IMX681**
   (front), `SMO55F0` = **VD55G0** (IR). Coverage is mixed: `ov13858.c` exists but
   is ACPI-only and needs an `of_match_table`; IMX681 has no driver at all;
   `vd55g1.c` does not match VD55G0.
3. **libcamera** configuration on top.

That is CSIPHY lane mapping, regulators, clocks and GPIOs — **not** derivable from
the DSDT, which turns out to carry no `_CRS` for the sensors at all. They are in
the Windows driver-store `CAM*_RES_MSHW*.bin` blobs. Tedious board bring-up, not
ISP development. The real work is a from-scratch IMX681 driver for the front
camera; the rear camera is close.

### 3. Multi-touch — probably the most tractable of the three

The digitizer exposes a **`Capacitive Heat Map Digitizer` collection with a
7488-byte input report** — a real 2-D frame. `sp11-pen-daemon` does not use it; it
enables a 464-byte low-power mode carrying two 1-D projections, and takes one
weighted centroid per axis. Multi-touch is blob detection over the *full* frame:
select that mode, find multiple local maxima, emit multitouch slots via uinput.

The precedent is exact: **linux-surface's IPTSD** is a userspace daemon that does
precisely this for Intel Surface heatmaps. The processing model transfers even though
the transport does not.

So this likely does **not** need a kernel driver — contrary to what
`linux-gap-analysis.md` says. It needs heatmap→contacts processing in userspace, on
data that is already being read successfully. For someone comfortable with signal
processing, this is the cheapest meaningful contribution on the list.

The real constraint is architectural and unavoidable: finger and pen modes are
mutually exclusive on this sensor, so pen-and-touch simultaneously will never work
regardless of software.

## Caveats before relying on any of this

- `denisix/ubuntu-surface-pro-11` is 2 stars, one author, days old. Not a
  battle-tested distribution.
- The author states the work was done with AI assistance ("claude code, glm 5.2,
  gemini"). Not disqualifying, but review the kernel patches before trusting them.
- **Secure Boot must be disabled.**
- Keep the Windows partition — it is the source for Qualcomm DSP firmware blobs.
- Single-touch only. On a tablet, that is a real daily-driver limitation.
