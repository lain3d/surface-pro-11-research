# Orientation: what all of this actually is

Written as a reading aid for the rest of the repo. Nothing here is new work — it
is the vocabulary and the mental model you need to follow the other documents and
the PRs without having to look up an acronym every third line.

MVP-stage document. It explains what things *are* and how they fit together, not
every detail of how they work.

---

## The one-paragraph picture

The Surface Pro 11 is an ARM64 laptop whose hardware works fine under Windows.
Linux does not know how to drive several parts of it — USB4, the cameras, the
touchscreen's high-resolution mode — not because the hardware is exotic but
because **nobody has written down, in the form Linux wants, what is wired to
what.** Windows has that description, in its firmware tables and in the data
files its drivers ship. Most of this project is reading Windows' description of
the machine and re-expressing it in Linux's form, then writing the small amount
of driver code that has no Linux equivalent yet.

So the recurring shape of the work is: *find the fact in Windows → prove it is
really that fact → write it as Linux device tree or driver code → verify the
built artifact says what you meant.*

---

## The central idea: two ways to describe hardware

This is the single most important concept in the repo. Everything else hangs off
it.

On a PC, the CPU can discover PCI devices by scanning. On an ARM SoC it mostly
cannot — the blocks are just memory addresses, and something has to *tell* the OS
"there is an I2C controller at 0x0ac16000, its interrupt is number 271, and it
needs these three clocks." There are two competing conventions for that telling:

**ACPI** — a set of firmware tables baked into the machine. Windows uses these.
The big one is the **DSDT** (Differentiated System Description Table). It is
compiled bytecode (**AML**) which you decompile to a C-like source (**ASL**) with
a tool called `iasl`. Inside, hardware is described as `Device (NAME)` entries
with properties:

| | |
|---|---|
| `_HID` | Hardware ID — the name Windows matches a driver against. `SONY0681` is how we learned the front camera is an IMX681. |
| `_CID` | Compatible ID — a fallback/generic ID. |
| `_UID` | Unique ID, to tell several instances apart. |
| `_SUB` | Subsystem ID — Microsoft uses these (`MSHW0490`) to name specific modules. |
| `_CRS` | Current Resource Settings — **the important one**: the memory addresses, interrupts, GPIOs and bus connections this device uses. |
| `_STA` | Status — whether the device is present. Often conditional. |
| `_DSD` | Device Specific Data — arbitrary extra key/value properties. |
| `_PLD` | Physical Location — where the port physically is on the chassis. |

**Device Tree (DT)** — a separate data file describing the same thing, used by
Linux on ARM. Source files are `.dts` (a board) and `.dtsi` (an include, usually
a whole SoC), compiled by `dtc` into a `.dtb` blob that the bootloader hands the
kernel. Vocabulary:

| | |
|---|---|
| node | one hardware block, e.g. `cci1: cci@ac16000 { ... }` |
| `compatible` | the string a driver matches on — DT's equivalent of `_HID`, e.g. `"qcom,x1e80100-cci"` |
| `reg` | address and size, or an address on a bus (an I2C device's `reg` is its bus address) |
| `status` | `"okay"` or `"disabled"`. **SoC `.dtsi` files usually define everything as disabled**, and each board file enables the parts it actually has. A large amount of this project is "enable the right nodes." |
| label / phandle | `cci1:` is a label; `<&cci1>` elsewhere is a *phandle*, a pointer to that node. If a label does not exist, nothing can point at it — this is how a missing regulator becomes a hard blocker. |
| binding | a YAML schema saying which properties a `compatible` is allowed/required to have. Lives in `Documentation/devicetree/bindings/`. |

**This machine has both.** The firmware ships ACPI tables (for Windows), and we
boot Linux with a device tree. That is *why* reading the DSDT is so productive
here: it is the manufacturer's own description of the same silicon we are writing
DT for. When ACPI and our DT agree on an irregular detail, that is real
corroboration, not coincidence.

### Interrupt numbering, because it bites

ACPI reports an interrupt as a **GSIV** (Global System Interrupt Vector). ARM's
interrupt controller is the **GIC**, and its interrupts come in kinds: SGIs
(software-generated, IDs 0–15), PPIs (per-CPU, 16–31), and **SPIs** (Shared
Peripheral Interrupts, 32 and up). Device tree numbers SPIs *from zero*, so:

```
GIC_SPI number = GSIV − 32
```

Every interrupt in the DT nodes in this project comes from that conversion. It is
verified, not assumed: the tree's existing `cci0`/`cci1` nodes say `GIC_SPI 460`
and `271`, and ACPI reports GSIV 492 and 303. (Careful: "SPI" here is *not* the
serial bus — the touchscreen's SPI is a different SPI entirely. Context tells you
which.)

---

## Names you will see for this machine

| Name | What it is |
|---|---|
| **X1E80100** | The Qualcomm Snapdragon X Elite SoC part number. |
| **hamoa** | Qualcomm's codename for that platform. This kernel tree's SoC include is `hamoa.dtsi`; mainline calls the same thing `x1e80100.dtsi`. |
| **denali** | Microsoft's codename for the Surface Pro 11 board. `x1-microsoft-denali.dtsi`. |
| **sp11** | Shorthand for the machine in this project. |

The kernel here is a **downstream** tree (Ubuntu 7.1.3 + Qualcomm/Microsoft
patches), not mainline. That is why some things upstream lacks are already
present — the camss and CCI nodes, the camcc driver — and why file names differ
from mainline.

---

## SoC building blocks

| Acronym | Meaning |
|---|---|
| **PMIC** | Power Management IC. A separate chip full of regulators. This board has several (`pm8550`, `pmc8380`, `pm8010`, …), each with an id letter — `b`, `m`, etc. |
| **LDO** | Low-DropOut regulator — one adjustable power rail on a PMIC. `LDO7_B` means "LDO 7 on PMIC b". Windows' blobs name rails exactly this way, which is how the voltages were recovered. |
| **regulator** | Linux's name for a controllable power rail. |
| **GDSC** | A switchable power domain inside the SoC ("footswitch"). Blocks must have theirs on before their registers respond. |
| **RPMh** | The always-on resource manager that actually actions voltage/clock requests. |
| **GCC / CAMCC** | Global Clock Controller / Camera Clock Controller — the blocks that produce clocks. `camcc-x1e80100.c` is the Linux driver for the latter. |
| **TLMM** | Qualcomm's pin controller ("Top Level Mode Multiplexer"). |
| **pinctrl / pinmux** | Choosing which internal function a physical pin carries. A pin can be a GPIO, or I2C, or a camera clock. Picking the wrong *function* name is a silent failure — e.g. gpio100's camera-clock function here is `cam_aon`, not `cam_mclk`. |
| **GPIO** | A single controllable pin. Used here mostly for sensor reset lines. |

---

## Pillar 1 — USB4

**What we want:** plug in a dock or an external GPU enclosure and have it work.

| Acronym | Meaning |
|---|---|
| **Thunderbolt / USB4** | Thunderbolt 3 was Intel's; USB4 is the open standard built from it. Linux drives both with one driver, `drivers/thunderbolt`, and one config symbol, `CONFIG_USB4`. |
| **host router** | The controller inside the laptop that a USB4 link plugs into. This SoC has three. |
| **NHI** | Native Host Interface — the register/DMA-ring interface the OS uses to talk to a host router. `nhi.c` is that driver. |
| **tunneling** | USB4 carries other protocols inside itself. **PCIe tunneling** is what makes an external GPU work; there is also USB3 and DisplayPort tunneling. |
| **Type-C** | The connector. Physically separate concern from USB4 — the same connector carries USB2, USB3, DP and USB4. |
| **PD** | Power Delivery — the negotiation protocol running on the connector's CC pins. USB4 entry is negotiated by a PD message called `Enter_USB`. |
| **alt mode** | Repurposing the connector's high-speed lanes for another protocol (e.g. DisplayPort). *USB4 is not an alt mode* — a common and costly confusion. |
| **UCSI** | USB Type-C Connector System Software Interface — a standard mailbox through which the OS **observes and influences** the connector. |
| **PPM / OPM** | Platform Policy Manager (firmware side of UCSI) and OS Policy Manager (the OS side). **The PPM does the actual negotiation.** This matters: Linux reads the result, it does not command USB4 entry. |
| **PMIC GLINK** | Qualcomm's message channel to its own firmware. On this platform UCSI runs over it, not over ACPI. |
| **retimer** | A signal-conditioning chip in the path on long/fast links. |

The key structural fact, established by reading the code: `drivers/thunderbolt`
contains **no reference to typec or ucsi**. USB4 device enumeration happens over
the router's own protocol via the NHI. The Type-C stack is not in that path.

**Whose code is whose:** the patches in this project make the host router bind on
a DT-booted machine. Everything about entering USB4 mode on the wire is
firmware's job and already works under Windows.

---

## Pillar 2 — the cameras

**What we want:** the front camera producing frames.

The path from photons to your screen has a lot of stages, and each has a name:

```
sensor ──I2C(CCI)── configured by the CPU
   │
   └─MIPI CSI-2 lanes─▶ CSIPHY ─▶ CSID ─▶ VFE/IFE ─▶ memory ─▶ /dev/video*
                        (receive)  (decode) (process)
```

| Acronym | Meaning |
|---|---|
| **sensor** | The imaging chip. Here: IMX681 (Sony, front), OV13858 (OmniVision, rear), VD55G0 (ST, infrared / Windows Hello). |
| **I2C** | A two-wire control bus. The sensor is *configured* over I2C and *sends pixels* over a different, much faster link. |
| **CCI** | Camera Control Interface — Qualcomm's dedicated I2C controller for camera sensors. This SoC has two (`cci0`, `cci1`), each with two buses. |
| **slave address** | A device's address on an I2C bus. **This is the one value we could not recover from Windows**, and the reason for the debug branch. |
| **MIPI CSI-2** | The high-speed serial link carrying pixels from sensor to SoC. |
| **CSIPHY** | The physical-layer receiver for those lanes. |
| **CSID** | CSI Decoder — turns the received stream into identified frames. |
| **VFE / IFE** | Video/Image Front End — the hardware that crops, scales and writes frames to memory. |
| **ISP** | Image Signal Processor — the general term for that processing hardware. |
| **camss** | The Linux driver tying CSIPHY+CSID+VFE together. `qcom,x1e80100-camss`. |
| **MCLK** | The reference clock the SoC feeds the sensor (19.2 MHz here). Without it many sensors will not even answer on I2C — which is why a naive `i2cdetect` finds nothing. |
| **EEPROM** | A small memory chip in the camera module holding calibration. Sits on the same I2C bus at address 0x50 — useful as a landmark. |
| **V4L2** | Video4Linux2 — the kernel's video API. |
| **subdev** | One stage of a V4L2 pipeline (the sensor is a subdev). |
| **media-ctl** | The userspace tool that connects subdevs into a working pipeline. Frames do not flow until this is done. |
| **Bayer / CFA** | Colour Filter Array. Sensors are monochrome; a grid of coloured filters makes them colour. The **order** of that grid (RGGB, BGGR, …) must be known or colours come out wrong. Not recoverable from any Windows file. |
| **VTS / HTS** | Vertical/Horizontal Total Size — frame timing, including blanking. Determines frame rate. |

On the Windows side:

| | |
|---|---|
| **CamX** | Qualcomm's camera driver framework. |
| **Chromatix** | Qualcomm's camera tuning format. The `com.surface.sensormodule.*.bin` files are Chromatix blobs, and Windows' own INF calls them the "Driver binary file" — they contain the sensor's register programming as data. Decoding them is where the IMX681 driver's register tables came from. |
| **`CAM*_RES_*.bin`** | Per-camera power sequences — clocks, rails, GPIOs, delays, in execution order. |

---

## Pillar 3 — the touchscreen's heat map

**What we want:** proper multi-touch.

| Acronym | Meaning |
|---|---|
| **HID** | Human Interface Device — the standard for input devices. |
| **report descriptor** | A blob the device provides describing what data it will send and in what shape. Both sides derive everything from this. |
| **input / output / feature report** | Input = device→host (touch data). Output = host→device. **Feature = configuration**, readable and writable both ways. Mode switches live here. |
| **usage page / usage** | HID's type system. Page `0x0D` is Digitizers; usage `0x0F` within it is the heat-map digitizer. |
| **HUTRR87** | The HID Usage Table Review Request that standardised the capacitive heat-map digitizer. It is a spec document number, nothing more. |
| **heat map** | Instead of reporting "two fingers here and here", the panel reports the **raw capacitance grid** — 46 × 68 cells. Turning that into contacts is the host's job. |
| **digitizer** | The touch/pen sensing hardware. |
| **hidraw** | The Linux char device giving userspace direct access to a HID device's raw reports (`/dev/hidraw*`). |
| **`HIDIOCGFEATURE` / `HIDIOCSFEATURE`** | The ioctls to read/write a feature report from userspace. This is how the mode gets switched. |
| **SPI-HID** | HID transported over the SPI serial bus rather than USB. How this touchscreen is attached. |
| **IPTS / iptsd** | Intel Precise Touch & Stylus, and its open userspace daemon. Solves the same heat-map→contacts problem, but is Intel-specific, so it would need adapting rather than reusing. |

The important structural point: **there is no kernel driver that consumes a
HUTRR87 heat map.** This pillar is not blocked on reverse engineering; it is
blocked on writing userspace.

---

## Kernel development vocabulary

| Term | Meaning |
|---|---|
| **Kconfig / `CONFIG_*`** | The build configuration system. A symbol is `y` (built in), `m` (module), or unset. |
| **module** | A driver built as a separately loadable `.ko` file. |
| **`.config`** | The current build configuration. Fragile across branch switches — see the strategy doc. |
| **`W=1`** | Build with extra warnings enabled. |
| **sparse** | A static checker for kernel-specific mistakes, especially address-space confusion (mixing a normal pointer with an `__iomem` one). |
| **checkpatch** | A style checker for patches. |
| **coccinelle / `make coccicheck`** | Pattern-based semantic checker for common kernel bugs. |
| **dtschema / `dt_binding_check` / `dtbs_check`** | Validate device tree bindings and validate the built DTBs against them. |
| **`__iomem`** | An annotation marking a pointer as pointing at device registers rather than memory. sparse enforces it. |
| **probe** | The function called when a driver is matched to a device. Most of the interesting failure modes live here. |
| **worktree** | A git feature letting several branches be checked out in separate directories at once. Used here to build one branch while editing another. |

---

## How to read this repo

| Repo | Holds |
|---|---|
| `surface-arm-platform-research` (this one) | investigation, decoded data, probes, docs, plans. Nothing that builds a kernel. |
| `surface-pro-11-kernel` | the actual kernel commits, one branch per logical change, each with a draft PR. |

Start with `design/state-and-unblock-plan.md` for where things stand and what
happens next. `docs/usb4-host-router.md`, `docs/camera-sensors.md` and
`docs/multitouch-heatmap.md` are the per-pillar deep dives. `probes/` holds the
tools that produced everything in `data/`.

Open PRs on the kernel repo:

| # | Branch | What |
|---|---|---|
| 1 | `camera/ov13858-dt` | make the rear sensor driver DT-probeable |
| 2 | `camera/denali-pm8010` | the camera power rails |
| 3 | `usb4/platform-nhi` | bind the USB4 host routers |
| 4 | `camera/imx681` | the new front-camera driver |
| 5 | `debug/imx681-addr-scan` | **throwaway**, exists to recover one number |
