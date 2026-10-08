# Three pillars — iteration recipe

A repeatable work plan for the three things nobody has solved on this platform.
Written to be driven in a loop: each pillar has a defined next action, a
definition of done for the current step, and an explicit statement of what
blocks it.

Everything else on this machine is either working or solved by someone else —
see `linux-prior-art.md`. These three are the actual frontier.

**Priority order is USB4 → camera → multi-touch.** eGPU is no longer the only
thing USB4 is for: docks, DisplayPort alt-mode over the same connector, and
40 Gbps storage all ride on the same transport, and all of them are worth having
independently of whether a graphics card ever hangs off it.

## Ground rules for every cycle

1. **Check prior art first.** This project has twice re-derived work that
   already existed (the `SP11` / `QUP_1_SE_2,QSPI` / `PNP0C51` mapping, and the
   entire touchscreen enablement). Search before building.
2. **Git is the oracle, not a heuristic.** A homegrown validator produced false
   positives on all 18 kernel patches and false negatives on a surplus hunk. If
   a tool disagrees with `git apply`, the tool is wrong.
3. **Verify against the source, not against memory.** Checking for
   `hid-descr-addr` made a correct kernel look broken; the driver reads five
   entirely different properties. Read the code that consumes the thing.
4. **Kernel changes go in the kernel repo as commits.** Not as `.patch` files.
   Six wrong hunk counts is what the alternative costs.
5. **Record negative results.** "Nobody has done this for any X1E laptop" is a
   finding worth keeping.
6. **A tool that disagrees with the bytes is wrong.** Three parsers in this
   project produced plausible-looking output that was silently wrong: a dropped
   GPIO pin number, a mis-located data section, and a record walk with no upper
   bound that ran into the data and reported field lengths of 1732277888. The
   first two were caught by decoding a field whose correct value was known in
   advance; the third only by the number being absurd.

   So: **a parser needs a limit it can fail against, not just a start** — and a
   field whose right answer you already know, printed every run.

---

## Pillar 1 — USB4 / Thunderbolt

**State: revised 2026-08-02 — this looks considerably more buildable than this
document used to claim.** The previous verdict ("do not build this; blocked on
undocumented Qualcomm init") rested on an assumption that has now been checked
against the DSDT and the Windows driver, and it did not survive.

### What the Windows side actually shows

`QcUsb4Bus8380.sys` is **338 KB and contains no MMIO, PHY, retimer, lane or
firmware-load surface at all.** Its strings are `DMF_AcpiPepDevice`,
`DMF_AcpiNotification`, `DMF_AcpiTarget`, `USB4BUS_DEVICE_CONTEXT`,
`ACPI\ACPI0015`, `USB4 HR PDO`. It is a **thin ACPI shim** that publishes a
standard host-router PDO for Microsoft's *inbox* `Usb4HostRouter.sys` to bind.

There is no register logic in it because there is nothing vendor-specific to do:
**`ACPI0015` is a standard ID and the register interface behind it is specified
by USB4**, which Linux's `usb4.c` already implements.

### What the DSDT gives us, for free

```
Device (UBF0)
    _HID "QCOM0C6D"
    _DEP { \_SB.PEP0, \_SB.UCS0 }          // power engine plugin + UCSI/Type-C
    Device (PRT0)                           // and PRT1, PRT2 — three routers
        _ADR 0
        _CID "ACPI0015"                     // standard USB4 host router
        _S0W 0x03
        _CRS: Memory32Fixed(0x1563F000, 0x000BFFFF)
              Interrupt 0x1F8  level, shared
              Interrupt 0x11F  edge,  shared + wake
              Interrupt 0x263  level, shared
        PSET → \_SB.PRS0                    // power resource set
        PHYC → Package () {}                // empty: no PHY quirks on this board
```

Register window, interrupts, power handle and PHY config are all right there.
`PHYC` returning an empty package is a small gift — it means no board-specific
PHY tuning is required. The `USB4_HR_0/1/2_DP_AP_*_INTERRUPT` names elsewhere in
the DSDT corroborate three host routers.

### What Linux actually lacks

Measured against our own 7.1.3 tree — the PCI coupling is narrower than
"PCIe-only" suggests:

| | |
|---|---|
| `drivers/thunderbolt` total | 39,515 lines |
| Files referencing `pci_dev` | **5** — `nhi.c` (17), `icm.c` (7), `acpi.c` (2), `switch.c` (2), `tb.c` (1) |
| `pci_*` call sites overall | ~90 |
| Domain/router layer | **already `struct device`-based** — 40 hits in `switch.c`, 18 in `tb.h`, 17 in `domain.c` |

`icm.c` is legacy Intel/Apple firmware-CM and can stay PCI-gated. So the work is
concentrated in the NHI transport, not smeared through the stack.

### Cycle

| Step | Action | Done when |
|---|---|---|
| 1 | ~~Poll the upstream series~~ | ✅ 2026-08-02 — RFC of 2025-09-16 only, no v2 in 10½ months. See the poll table below |
| 2 | ~~Establish what the hardware needs~~ | ✅ MMIO `0x1563F000`+`0xBFFFF`, 3 IRQs, `PRS0` power set, no PHY quirks |
| 3 | Map `PRS0` / `PEP0` to DT clocks, regulators and power-domains | The rails and clocks the router needs are named |
| 4 | Confirm the register block really is spec-standard NHI (compare `usb4.c` expectations against the window) | Go / no-go on reusing the core |
| 5 | De-PCI the NHI: `pci_dev *` → `struct device *`, split `pci.c` / `platform.c`, platform IRQs | Builds with `USB4` no longer `depends on PCI` |
| 6 | Write the DT node + a minimal platform host-router driver | `tb_domain` registers |
| 7 | Boot it | Router enumerates, ports appear in `/sys/bus/thunderbolt` |
| 8 | **The real unknown:** does PCIe tunneling work over it? | A TB NVMe enclosure enumerates |
| 9 | DP alt-mode, docks, then eGPU | Each works or is ruled out |

**Blocked on:** steps 3–6 need no hardware. Step 7 onward needs the ISO booted.

**Revised risk.** Getting a router to *bind* is plausibly weeks, not months, for
someone comfortable in the kernel. Getting it *upstream* is a separate and longer
job — Westerberg's review asked for a `pci.c`/`platform.c` split, MSI
forward-compatibility, power-contract properties, and ports and retimers
described in DT.

**The caveat that still stands:** host-router support is the *transport*. Whether
**PCIe tunneling** works over it is a separate question the RFC thread never
addresses, and nobody has asked it publicly for this SoC. It is the single
highest-value unknown in this pillar and it is what decides the eGPU question.

### Poll — 2026-08-02

| Check | Result |
|---|---|
| `qcom_usb4.c` in `drivers/thunderbolt` | absent |
| `config USB4 … depends on PCI` | still there, Kconfig line 4 |
| `platform_driver` anywhere in `drivers/thunderbolt` | none |
| `pci_dev` references in `nhi.c` | 17 |
| `ACPI0015` occurrences in-tree | still zero |
| `Documentation/devicetree/bindings/thunderbolt/` | does not exist |

Upstream searches surfaced only the original RFC. Patchwork's `linux-usb` returns
nothing for a Qualcomm USB4 query — weak evidence, since the series may be filed
under `linux-arm-msm`, and `lore.kernel.org` refused automated fetches. Not an
authoritative archive search.

**On waiting for Konrad Dybcio (Qualcomm) to land it:** he is best placed — a
prolific upstream Qualcomm SoC maintainer with internal documentation — but
"best placed" is not "certain to finish". An RFC that drew substantive structural
review and then went quiet for ten and a half months is at least as consistent
with internal deprioritisation as with work in progress. **We have no evidence
either way**, and any plan that depends on him finishing should say so out loud.

---

## Pillar 2 — Camera

**State:** everything that can be done without hardware is done. See
`../docs/camera-sensors.md`.

The ISP driver is **already upstream** — `qcom,x1e80100-camss` with a DT binding
— and **six X1E boards already wire camss up** in our 7.1.3 tree (xps13-9345,
yoga-slim7x, dell-thena, x1-crd, zenbook-a14, thinkpad-t14s).
`x1-dell-thena.dtsi` is a complete copyable template. The earlier "zero camera
nodes in any X1E DT" finding is stale.

| ACPI | `_HID` | `_SUB` | Part | Driver | CCI | CSIPHY |
|---|---|---|---|---|---|---|
| `CAMS` | `OVTID858` | `MSHW0491` | **OV13858** rear | `ov13858.c` (now DT-capable) | 1 | 1 |
| `CAMF` | `SONY0681` | `MSHW0490` | **IMX681** front | **none — must be written** | 3 | 2 |
| `CAMI` | `SMO55F0` | `MSHW0492` | **VD55G0** IR | `vd55g1.c` does *not* match | 0 | 0 |

CCI/CSIPHY index→part mapping is inferred from ascending `_UID`; confirmable in
seconds once booted.

### Cycle

| Step | Action | Done when |
|---|---|---|
| 1–3 | ~~Parts, drivers, power/clock/GPIO wiring~~ | ✅ reset GPIOs 237/110/109, MCLK4/1/0 @ 19.2 MHz, rails per sensor |
| 3a | ~~Make `ov13858.c` DT-probeable~~ | ✅ `lain3d/surface-pro-11-kernel#1`, compile-tested |
| 3b | ~~Lane assignment~~ | ✅ rear 4 lanes (`0x3210`); front `0x0000` unresolved |
| 3c | ~~PM8010 camera PMIC in denali DT~~ | ✅ `lain3d/surface-pro-11-kernel#2`, DTB builds |
| 3d | ~~CCI bus + CSIPHY index~~ | ✅ from `CAMP_PCFG_MSHW0495.bin` bitfields |
| 3b' | I²C slave address | **Parked** — not in any blob or driver; one `i2cdetect` after boot |
| 4 | Write the camss + sensor nodes, copying `x1-dell-thena.dtsi` | Node compiles into the DTB |
| 5 | Boot, check `dmesg` for camss probe | ISP probes |
| 6 | libcamera pipeline config | An image comes out |

**Risk:** low for the rear camera (existing driver + DT match + template + all
values known but one). The front camera needs an **IMX681 driver written from
scratch** — that is the real work here, and it is the camera most people use.

---

## Pillar 3 — Multi-touch

**State:** single-touch works. The device *can* emit a full 2-D frame, and the
mode switch is de-risked. See `../docs/multitouch-heatmap.md`.

`ACPI\MSHW0485` Col02 has usage `0x0D`/`0x0F` — **Capacitive Heat Map Digitizer**
— and declares a **7488-byte input report**. The 464-byte report the daemon reads
is, in HUTRR87's own words, "a subset of the heat map for power savings".

Windows does contact detection in **user mode**: `heat.inf` has no service binary
at all, and the registry names a `SoftwareProcessor`, `TouchPenProcessor0C83.dll`.
So the Linux daemon's architecture is already the right one.

### Cycle

| Step | Action | Done when |
|---|---|---|
| 1–2 | ~~Descriptor + report enumeration~~ | ✅ 7488 bytes on Col02 vs 464 in use |
| 5 | ~~RE the Windows side~~ | ✅ mode switch is a HID *feedback* report whose ID and IOCTL are **derived from the descriptor at runtime**; device advertises a mode bitmap |
| 3 | Select full-frame mode on hardware | Parse descriptor → read mode bitmap → write feedback report. No magic constant needed |
| 4 | Capture frames | Grid **46 × 68** (confirmed twice), cells **1 byte**. 3128 of 7488 bytes accounted for; the rest needs a capture |
| 6 | Blob detection → uinput MT slots | Two-finger scroll works |

**Blocked on:** booted hardware from step 3.

**Hard limit:** finger and pen modes are mutually exclusive on this sensor.
Simultaneous pen-and-touch is not achievable in software.

---

## Priority

1. **USB4** — the only pillar with substantial no-hardware work left (steps 3–6),
   and the one whose payoff is broadest. Start here.
2. **Camera** — everything possible without hardware is done; resumes at boot
   with one `i2cdetect`. The IMX681 driver can be started any time.
3. **Multi-touch** — de-risked and waiting on the boot.

**Standing lesson:** step 1 of the old Pillar 1 was scheduled against booted
hardware and turned out to be answerable from Windows in one probe. Before
declaring anything hardware-blocked, check whether Windows already parses the
same data. That has now paid off four times.

## Environment

Identification work belongs on Windows (ACPI, vendor drivers, working
hardware as reference). Verification belongs in a Claude CLI inside the booted
Ubuntu (`dmesg`, `hidraw`, `debugfs`, DT iteration). See
`../docs/linux-support.md` and the sibling repo's
`iso-build/research/DIAGNOSIS-ENVIRONMENTS.md`.
