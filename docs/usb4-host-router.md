# USB4 host router — revised assessment

**This document exists because the previous verdict was wrong.**
`three-pillars-loop.md` said *"do not build this — blocked on undocumented
Qualcomm init"*. Both halves of that turned out to be false when checked against
the DSDT and the Windows driver, and the correction changes what this pillar is
worth.

Priority note: eGPU is no longer the only motivation. Docks, DisplayPort
alt-mode and 40 Gbps storage all ride the same transport and are worth having on
their own.

## There is no vendor init to reverse

`QcUsb4Bus8380.sys` is 338 KB and contains **no MMIO, PHY, retimer, lane or
firmware-load surface at all**. Its whole vocabulary is framework:

```
WdfCustomType_DMF_AcpiPepDevice      WdfCustomType_DMF_AcpiNotification
WdfCustomType_DMF_AcpiTarget         USB4BUS_DEVICE_CONTEXT
ACPI\ACPI0015                        USB4 HR PDO
USB4\QCOM0CD10001                    QC USB4 BUS 0
```

It is a **thin ACPI shim** that publishes a standard host-router PDO which
Microsoft's *inbox* `Usb4HostRouter.sys` then binds. There is no register logic
in it because **`ACPI0015` is a standard ID and the register interface behind it
is defined by the USB4 specification** — the same specification Linux's
`drivers/thunderbolt/usb4.c` already implements.

That is the crux. "Reverse-engineer Qualcomm's init" was never the task.

## What the DSDT hands over

`\_SB.UBF0`, `_HID QCOM0C6D`, `_DEP { PEP0, UCS0 }`, `_CCA Zero`, with three
children — one per USB4 port:

| Router | `_ADR` | MMIO base | Length | IRQ (level) | IRQ (edge, wake) | IRQ (level) | `PSET` |
|---|---|---|---|---|---|---|---|
| `PRT0` | 0 | `0x1563F000` | `0xBFFFF` | `0x1F8` | `0x11F` | `0x263` | `PRS0` = `0x6F` |
| `PRT1` | 1 | `0x1573F000` | `0xBFFFF` | `0x27D` | `0x22B` | `0x27F` | `PRS1` = `0x6F` |
| `PRT2` | 2 | `0x1553F000` | `0xBFFFF` | `0x1CD` | `0x236` | `0x1D6` | `PRS2` = `0x6C` |

All three carry `_CID "ACPI0015"` and `_S0W 0x03`, and all three have
`PHYC → Package () {}` — **empty, so no board-specific PHY tuning is required**.
`PRS2` differing from the other two (`0x6C` vs `0x6F`) suggests the third port
has a slightly different capability set; worth confirming, not worth assuming.

Windows corroborates three routers independently: the DSDT elsewhere names
`USB4_HR_0_DP_AP_0_INTERRUPT` through `USB4_HR_2_DP_AP_1_INTERRUPT`.

### Which router is which physical port

`UCSI` (`_HID USBC000`) declares three Type-C connectors whose `_ADR` values
match the host routers':

| Connector | Router | `_PLD` panel | Group position |
|---|---|---|---|
| `UCN0` | `PRT0` | Left | 0 |
| `UCN1` | `PRT1` | Left | 1 |
| `UCN2` | `PRT2` | Left | 2 |

All three `_PLD` descriptors decode to **panel = Left**, group token 0, group
positions 0/1/2 — three connectors in one group down the left side. The machine
has two user-facing USB-C ports, so one of the three is not a user port; that
`PRT2` also carries a different capability byte (below) is consistent with it.

### `PSET` and `PHYC` are dead ACPI — do not trust the capability bytes

The three routers each expose `PSET`, returning a one-byte buffer:
`PRS0 = 0x6F`, `PRS1 = 0x6F`, `PRS2 = 0x6C`. It is tempting to read those bits
as per-port protocol capability, and if they were, `PRS2` differing in two bits
would be interesting for the PCIe-tunneling question.

**Nothing reads them.** A raw byte search for `PSET` and for `PHYC` across both
USB4 drivers — Qualcomm's `QcUsb4Bus8380.sys` and Microsoft's inbox
`Usb4HostRouter.sys` — returns **zero occurrences in either**. Neither driver
evaluates either method, so their meaning cannot be recovered from driver
behaviour, and they are not evidence of anything. `PHYC` returning an empty
package fits the same picture: vestigial firmware scaffolding.

So **the PCIe-tunneling question is not answerable from ACPI.** It stays a
boot-time measurement.

### Two details that matter for a port

- **`_CCA = Zero` — the host router is not cache-coherent.** Linux's NHI
  allocates its descriptor rings with `dma_alloc_coherent`. On arm64 the DMA API
  handles non-coherent devices transparently *provided the DT node does not
  claim `dma-coherent`* — it returns a non-cacheable mapping instead. So this is
  a DT property to get right rather than a landmine, but it is exactly the sort
  of thing that is silently wrong if copied from a coherent device's node.
- **No `_PR0`, `_PS0` or `_PS3` anywhere in the scope.** Power is entirely
  PEP-managed (hence `_DEP` on `PEP0`), so ACPI does not describe the power
  sequence. On Linux that has to come from DT instead — see below, where it turns
  out most of it already exists.

## What Linux already has

Checked against our own 7.1.3 tree.

**The clock tree is already implemented.** `drivers/clk/qcom/gcc-x1e80100.c`
contains **272 `usb4` references**, and
`include/dt-bindings/clock/qcom,x1e80100-gcc.h` defines the full set for all
three routers:

```
GCC_USB4_n_MASTER_CLK        GCC_USB4_n_CFG_AHB_CLK    GCC_USB4_n_SYS_CLK
GCC_USB4_n_TMU_CLK           GCC_USB4_n_SB_IF_CLK      GCC_USB4_n_DP0/DP1_CLK
GCC_USB4_n_PHY_RX0/RX1_CLK   GCC_USB4_n_PHY_PCIE_PIPE_CLK
GCC_USB4_n_PHY_USB_PIPE_CLK  GCC_AGGRE_USB4_n_AXI_CLK
```

**The PHY is already driven.** `hamoa.dtsi` (the X1E SoC DTSI in this tree) wires
`GCC_USB4_0_DP0_PHY_PRIM_BCR` as the `"common"` reset of `usb_1_ss0_qmpphy`
(`qcom,x1e80100-qmp-usb3-dp-phy`), with `GCC_USB4_1_..._SEC_BCR` and
`GCC_USB4_2_..._TERT_BCR` on the other two. The combo PHY that physically carries
USB4 is already brought up for its USB3 and DisplayPort roles.

**What is missing** is narrow:

- no node at `0x1553F000` / `0x1563F000` / `0x1573F000` in any DTS
- **no node named `usb4` in any Qualcomm DTSI at all** — checked across the whole
  directory, including `glymur.dtsi` (Snapdragon X2 Elite, `qcom,oryon-2-2`),
  where the `GCC_AGGRE_USB4_*_AXI_CLK` references are consumed only by
  interconnect nodes, not a host router
- no platform-capable NHI in `drivers/thunderbolt`

## The PCI coupling is narrower than "PCIe-only" implies

| | |
|---|---|
| `drivers/thunderbolt` | 39,515 lines |
| Files referencing `pci_dev` | **5** — `nhi.c` (17), `icm.c` (7), `acpi.c` (2), `switch.c` (2), `tb.c` (1) |
| `pci_*` call sites | ~90 |
| Domain / router layer | **already `struct device`-based** — 40 hits in `switch.c`, 18 in `tb.h`, 17 in `domain.c` |

`icm.c` is legacy Intel/Apple firmware-CM and can stay PCI-gated. The coupling is
concentrated in the NHI transport, which is what Dybcio's RFC proposed to split
into `pci.c` / `platform.c`.

## The window size is consistent with a standard NHI

Linux's NHI register map (`nhi_regs.h`) runs from `REG_TX_RING_BASE 0x00000` to
`REG_FW_STS 0x39944` — about **232 KB**. The ACPI window is `0xBFFFF`, about
**768 KB**, so it comfortably contains the whole map with room left for router
and port config space beyond it.

That is not proof the layout matches, but the sizes are compatible, and they
would not be if this were a bespoke Qualcomm interface.

## The actual port surface, enumerated

`nhi->iobase` is a plain `void __iomem *` driven with `ioread32`/`iowrite32` —
**the entire register-access path is already platform-agnostic**. The PM
callbacks already take `struct device *dev`. The PCI dependency is confined to
setup, and it is a short list:

| `nhi.c` | Platform equivalent |
|---|---|
| `nhi_probe(struct pci_dev *pdev, …)` | `platform_driver` probe |
| `pcim_enable_device(pdev)` | not needed |
| `pcim_iomap_region(pdev, 0, …)` — BAR0 | `devm_platform_ioremap_resource()` |
| `pci_alloc_irq_vectors` / `pci_irq_vector` | `platform_get_irq()` ×3 |
| `pci_set_master(pdev)` | not needed |
| `pci_set_drvdata` | `platform_set_drvdata` |
| `dma_set_mask_and_coherent(&pdev->dev, …)` | same, on the platform device |
| `dma_alloc_coherent(&ring->nhi->pdev->dev, …)` | store a `struct device *` in `tb_nhi` |
| `dma_pool_create(…, &nhi->pdev->dev, …)` in `ctl.c` | same |

**Correction to an earlier version of this document:** calling that "eight call
sites" understated the diff. There are **83 `nhi->pdev` references** across ten
files. The distinction that matters is:

- **~8 are semantically PCI** — the setup calls in the table above, plus
  `nhi->pdev->msix_enabled`, `pci_irq_vector`, the Intel device-ID quirks and the
  `pci_walk_bus` IOMMU check.
- **The other ~75 are mechanical** — `&nhi->pdev->dev` used purely to obtain a
  `struct device *` for logging, `dma_alloc_coherent`, `dma_pool_create` or the
  domain's parent pointer.

So the *semantic* dependency really is tiny, but the *diff* is not. Step one of
the port — adding `struct device *dev` to `tb_nhi` and using it for all the
mechanical cases — came to **57 replacements across 9 files**, builds clean, and
is `lain3d/surface-pro-11-kernel#3`.

`icm.c` (10 refs) and `nhi_ops.c` (11 refs) are left alone: Intel firmware-CM
reading PCI config space, PCI-only by nature.

## Revised estimate

| Piece | Cost |
|---|---|
| DT node for a host router | Small — every value is in the table above, and the clocks exist |
| De-PCI the NHI | **200–400 lines**, mechanical. Smaller than first estimated, because the register path and PM callbacks are already generic |
| Non-coherent DMA | A DT property, not a rewrite — just don't set `dma-coherent` |
| Router *binds* | Plausibly **weeks**, not months |
| Getting it **upstream** | Separate, longer — Westerberg wants the `pci.c`/`platform.c` split, MSI forward-compat, power-contract properties, ports and retimers in DT |
| **PCIe tunneling working** | **The real unknown.** Nobody has asked this publicly for this SoC |

## On waiting for upstream

Konrad Dybcio (Qualcomm) posted the RFC on 2025-09-16 and drew substantive
structural review from Mika Westerberg. **No v2 in ten and a half months.**

He is best placed — a prolific upstream Qualcomm SoC maintainer with internal
documentation — but best placed is not certain to finish. A quiet RFC is at least
as consistent with internal deprioritisation as with work in progress, and we
have no evidence either way. Any plan that depends on him landing it should say
so out loud rather than treat it as scheduled.

## Progress

| Step | State |
|---|---|
| Confirm the window is plausibly standard NHI | ✅ by size — 232 KB needed, 768 KB given |
| `tb_nhi` gains a `struct device *` | ✅ 57 replacements, builds clean |
| Guard `nhi_check_quirks` / `nhi_check_iommu` / `nhi_shutdown` / `ring_request_msix` on `nhi->pdev` | ✅ |
| Split `nhi_probe` into common + PCI + platform wrappers | ✅ plus a `platform_driver` |
| DT nodes for all three routers, clocks enabled in probe | ✅ Denali enables `usb4_0` |
| Kconfig: drop `depends on PCI` | **deliberately not done** — see below |
| Does it bind? Does PCIe tunnel? | needs the ISO booted |

All of the above is `lain3d/surface-pro-11-kernel#3`, five commits, module and
Denali DTB both build clean. **Nothing has been booted.**

### The GSIV → SPI offset, verified

ACPI interrupt numbers are GSIVs; DT wants GIC SPI numbers. The offset is 32,
and that was checked against this machine rather than assumed: the SP11 SPI
controller is `0x00A88000` with GSIV `0x342` in the DSDT, and `hamoa.dtsi`
already describes the same block at `a88000` as `GIC_SPI 802`. 834 − 802 = 32.

| Node | MMIO | GSIVs | GIC SPIs |
|---|---|---|---|
| `usb4_2` | `0x1553F000` | `0x1CD` / `0x236` / `0x1D6` | 429 / 534 / 438 |
| `usb4_0` | `0x1563F000` | `0x1F8` / `0x11F` / `0x263` | 472 / 255 / 579 |
| `usb4_1` | `0x1573F000` | `0x27D` / `0x22B` / `0x27F` | 605 / 523 / 607 |

### Why `depends on PCI` was left alone

Dropping it is not one line. Measured across the subsystem, the code that would
need conditional compilation is:

| File | PCI-touching lines |
|---|---|
| `nhi.c` | 82 |
| `icm.c` | 53 |
| `switch.c` | 45 |
| `tb.c` | 21 |
| `nhi_ops.c` | 11 |
| `acpi.c` | 5 |

and the specific symbols with no `!CONFIG_PCI` stub include `pci_walk_bus`,
`pcie_find_root_port`, `pci_upstream_bridge`, `pci_alloc_irq_vectors`,
`pci_irq_vector`, `pcim_iomap_region` and the config-space accessors.

`switch.c` and `tb.c` are **core files, not NHI plumbing**. Scattering `#ifdef
CONFIG_PCI` through them is precisely what Westerberg's review of the RFC asked
to avoid when he requested a clean `pci.c` / `platform.c` split. A version built
from `#ifdef`s would be unreviewable, and — since this tree cannot produce a
working `PCI=n` arm64 config to test against — it would also be **unverifiable**.

It is also not needed here: this kernel has `PCI=y`, so the platform driver binds
with the dependency still in place. Dropping it is upstream hygiene, and it
belongs with the file split rather than ahead of it.

**Follow-up, properly specified:** move the PCI probe, `nhi_ids`, `nhi_driver`,
`nhi_imr_valid`, `nhi_check_iommu` and the MSI-X paths into `pci.c`; move the
platform probe into `platform.c`; leave `nhi.c` bus-agnostic; then the Kconfig
dependency can go and `icm.o` / `nhi_ops.o` gate cleanly on `CONFIG_PCI`.

### The interrupt-model question

The ACPI device gives **three plain interrupts per router**, not the 16 MSI-X
vectors Linux's NHI prefers. That is fine: `nhi_init_msi` already has a
single-interrupt fallback (`pci_alloc_irq_vectors(pdev, 1, 1, PCI_IRQ_MSI)` →
`devm_request_irq(..., nhi_msi, ...)` with a shared `nhi_interrupt_work`), so the
platform path can reuse that shape with `platform_get_irq()`. `ring_request_msix`
then has to take the no-MSI-X branch, which it already supports.

Which of the three interrupts is the ring interrupt — versus the wake and the
third line — is a question for the hardware.

### Audit: every `nhi->pdev` dereference on the platform path

The platform driver makes `tb_nhi::pdev` NULL for the first time in this
driver's history. Nothing in the compiler will catch a missed dereference —
it builds fine and NULL-derefs at runtime — so the sites have to be enumerated
by hand. There are 34 of them.

**Nothing outside `drivers/thunderbolt/` touches `nhi->pdev` at all.** Two files
elsewhere include `linux/thunderbolt.h` (`drivers/net/thunderbolt/main.c`,
`drivers/usb/typec/port-mapper.c`); both build clean at `W=1` against the
changed header, as does all of `drivers/thunderbolt/`.

Inside the directory, each site is reached only when `pdev` is non-NULL:

| Site | Why a platform NHI never reaches it |
|---|---|
| `icm.c` (12 sites) | `nhi_select_cm()` returns `tb_probe(nhi)` on `!nhi->pdev`, so `icm_probe()` is never called |
| `nhi_ops.c` (11 sites) | reached only via `nhi->ops`, which is assigned once, from the PCI id table's `driver_data`; every call site is `nhi->ops && …` guarded |
| `tb.c:3313`, `:3323` | `tb_apple_add_links()` returns on `!x86_apple_machine`, which is `#define`d to `false` on non-x86 |
| `switch.c:222`, `:231` | the DMA-port NVM paths. `nvm_authenticate()` returns early for `tb_switch_is_usb4(sw)`, and the host router here *is* USB4; `tb_switch_add()`'s dma_port block returns before `dma_port_alloc()` when `!tb_route(sw) && !tb_switch_is_icm(sw)` |
| `nhi.c:470`, `:479` | `ring_request_msix()` returns 0 on `!nhi->pdev` before the `pci_irq_vector()` call |
| `nhi.c:1173`, `:1209`, `:1219`, `:1281`, `:1323` | explicitly guarded, or inside the `if (pdev)` half of `nhi_init_irq()` |

The `switch.c` entry is the one that took reading to settle rather than
grepping, and it is the one that would have bitten: it is reachable from
ordinary device hotplug, not from probe. It is safe only because a platform host
router is by construction a USB4 router. That is a true property of this
hardware, not a defensive check — worth stating out loud, because the day
someone binds this driver to a pre-USB4 platform router it stops being true.

### UCSI is not in the critical path

I had flagged the Type-C stack as the top risk — "the host router will bind, but
UCSI has to negotiate USB4 entry and that is thin in Linux". That was wrong, and
it pointed debugging at the wrong subsystem.

**`drivers/thunderbolt` contains no reference to typec or ucsi.** Not one. The
only coupling between the two subsystems runs the other way: `usb4_port.c`
exports `usb4_usb3_port_match()`, and the sole consumer is
`drivers/usb/typec/port-mapper.c`. That is Type-C reaching into USB4 to build
sysfs links and associate USB3 tunnel bandwidth — not USB4 depending on Type-C.
A USB4 device enumerates over the router's own protocol via the NHI; the Type-C
stack is not consulted.

**USB4 entry is also not an alt mode.** `ucsi/thunderbolt.c` implements the
*Thunderbolt 3* SVID (`USB_TYPEC_TBT_SID`) through `SET_NEW_CAM` — the legacy
TBT3 path. USB4 proper is entered with a PD `Enter_USB` message negotiated by the
**PPM firmware**. Linux only *reads* the result:

```
UCSI_CONSTAT_PARTNER_FLAG_USB4_GEN3   bit 23
UCSI_CONSTAT_PARTNER_FLAG_USB4_GEN4   bit 24
```

Status bits, not commands. There is no code path by which Linux asks for USB4
mode, so there is none to be missing.

And the PPM here demonstrably works: the ACPI UCSI device's `_STA` returns 0
unless `\_SB.PMGK.LKUP > 0`, i.e. Windows' UCSI sits behind the same PMIC-GLINK
firmware, and USB4 works under Windows. Booting Linux does not change that
firmware.

This lines up with something already established: **`PSET` and `PHYC` are never
called by either Windows USB4 driver.** PHY bring-up is not the USB4 driver's job
on Windows either. Which matters, because Linux has no `PHY_MODE_USB4` at all —
the `phy_mode` enum stops at `PHY_MODE_DP`, and `phy-qcom-qmp-combo` only knows
USB3+DP. If Linux had to put the combo PHY into a USB4 mode there would be no
mechanism to do it. The Windows evidence says it does not have to.

Version gating is worth knowing but is not a blocker: the `USB4_GEN3` flag is
only read when UCSI ≥ 2.0 and `GEN4` when ≥ 3.0, so a low-version PPM means
`/sys/class/typec/*/partner/usb_mode` will not say `usb4`. Cosmetic.

#### What is genuinely affected

**Port mapping will not happen on a DT boot.** `port-mapper.o` is built only
under `CONFIG_ACPI` (`typec-$(CONFIG_ACPI) += port-mapper.o`) and matches
connectors to ports by ACPI `_PLD` CRC via `to_acpi_device()`. With no ACPI
companions there is no match, so the `usb4_port` ↔ `typec port` sysfs links are
absent and USB3-tunnel bandwidth is not associated with a connector. Neither
blocks PCIe tunnelling.

**The router-to-port mapping does not add up, and this is the actionable one:**

| | count |
|---|---|
| `usb4@` routers in `hamoa.dtsi` | 3 |
| ACPI UCSI connectors (`UCN0/1/2`) | 3 |
| `usb-c-connector` nodes in the denali board DT | **2** |
| routers enabled at board level | **1** (`&usb4_0`) |

The machine has two USB-C ports. So one of the three routers goes somewhere that
is not a user-facing port, the board DT describes only two connectors, and the
single router currently enabled may not be either of them. Enable all three and
find out which binds and which corresponds to a physical port before concluding
anything from a dock that fails to enumerate.

## MEASURED 2026-08-06: PCIe tunnels on this machine. The dock is TBT3.

The Dell dock was plugged into the running Windows install and the PnP database
read. Two results, and they change the plan.

### The dock is Thunderbolt 3, not USB4

```
USB4\VID_8086&PID_15EF   "Thunderbolt 3(TM) Router, Dell - WD19TB Thunderbolt Dock"
```

`8086:15EF` is Intel **Titan Ridge** (JHL7540). The WD19TB is a 2019 dock and
predates USB4 entirely; it speaks TBT3 and is accepted by the X1E host router in
backward-compatibility mode. "Thunderbolt dock" and "USB4 dock" are not the same
thing, and this is the former.

### PCIe tunneling works — the "real unknown" is answered on the hardware side

`\_SB.PCI0`, which `device-profile.md` recorded as a **USB4 tunnel target,
currently unpopulated**, populates on attach exactly as predicted:

```
ACPI(_SB_)#ACPI(PCI0)#ACPI(RP1_)                 PCI\VEN_17CB&DEV_0111  seg 0 bus 0  Qualcomm root port
  #PCI(0000)                                     8086:15EF  seg 0 bus 1  Titan Ridge upstream switch port
    #PCI(0200)                                   8086:15EF  seg 0 bus 2  downstream switch port
      #PCI(0000)                                 8086:15F0  seg 0 bus 3  Intel xHCI
```

and everything downstream enumerates: Realtek RTL8153 GbE, four Realtek hubs,
the dock's USB audio, and a Dell S2725QC on the dock's HDMI with its display
audio endpoint. `Usb4HostRouter`, `Usb4DeviceRouter` and `QcUsb4Filter` all went
from `Stopped` to `Running`.

**So the silicon and firmware tunnel PCIe.** Every remaining question is a Linux
question. Note also what sits at the top of that hierarchy: a **Qualcomm PCIe
root port, `17CB:0111`** — the same device ID as the root ports of `PCI4` (the
NVMe) and `PCI6` (WiFi), which in DT are `pcie4` and `pcie6a`. The tunnel target
is an ordinary Qualcomm controller of the same family, not exotic hardware. That
makes "describe it in DT" a far more plausible ask than it looked, and puts
`pcie3` and `pcie5` — the two DT controllers Denali leaves disabled — under
suspicion as the two tunnel controllers, with firmware assigning them the 64-bit
ECAM and window that ACPI reports.

### Gate 2 does not apply to a TBT3 dock

Traced through the code with the SVID this dock actually presents:

`pmic_glink_altmode_worker()` sees `MUX_CTRL_STATE_TUNNELING` with
`svid == USB_TYPEC_TBT_SID`, so it calls `pmic_glink_altmode_enable_tbt()`, not
`_enable_usb4()`. That sets `port->retimer_state.alt = &port->tbt_alt`, so
`ps883x_set()` takes the **`if (state->alt)`** branch and lands in
`case USB_TYPEC_TBT_SID`, which sets `CONN_STATUS_2_TBT_CONNECTED`
unconditionally. **`disable_usb4` is only tested in the `else` branch.**

So `parade,disable-usb4` cannot block this dock, and **no DTB change is needed
to try it.** The property matters only for a native USB4 device. That removes
the second move from the plan for this hardware and leaves the cmdline edit
standing alone.

### What replaces it

TBT3 on a platform host router is a path nobody has run. The good news is that
`nhi_select_cm()` returns `tb_probe(nhi)` when `nhi->pdev` is NULL, so a platform
router gets the **software connection manager** in `tb.c` — the right one — and
`icm.c`, the Intel firmware-CM that is genuinely PCI-bound, is never entered.
The DP the dock carries is a **`tb` DP tunnel**, not a `pmic_glink_altmode` HPD
event, so it does not ride the mechanism `sp11-dp-reset.service` fixes.

## BOOTED 2026-08-06 (integ41): the routers bind, the domain times out

`modprobe.blacklist=thunderbolt` came off the cmdline and udev autoloaded the
module off the DT compatible, exactly as `modules.alias` promised. All three
routers then failed the same way:

```
17.244s  thunderbolt-platform 1553f000.usb4: device links to tunneled native ports are missing!
17.665s  thunderbolt-platform 1553f000.usb4: probe with driver thunderbolt-platform failed with error -110
         1563f000 and 1573f000 identical, ~420 ms apart each
```

**The warning is noise on a DT boot.** `tb_probe()` (`tb.c:3396`) fires it when
both `tb_apple_add_links()` and `tb_acpi_add_links()` return false; the ACPI one
needs ACPI companions, which a DT boot has none of. It concerns suspend/resume
tunnel ordering, not bring-up. Predicted by the "port mapping will not happen on
a DT boot" note above.

**The `-110` is ETIMEDOUT out of `tb_domain_add()`**, and how far probe got
first is the useful part:

| step | result |
|---|---|
| bound to all three DT nodes | ✅ |
| `devm_clk_bulk_get_all_enabled()` — all five clocks | ✅ |
| `devm_platform_ioremap_resource()` | ✅ |
| `ioread32(REG_CAPS)` for `hop_count` | ✅ reached |
| `devm_request_irq()` on the `nhi` line | ✅ |
| `nhi_select_cm()` → software CM in `tb.c`, not `icm.c` | ✅ |
| `tb_domain_add()` — first control packet | ❌ ETIMEDOUT |

So the plumbing is right and **the router never answers a control packet**.
`TB_TIMEOUT` is 100 ms (`tb.c:19`); the ~420 ms per router is retries.

**A cold boot reproduces it identically**, which rules out stale state left by a
previous boot. Two candidates remain:

1. **The interrupt never fires.** `tb_cfg_request_sync()` →
   `wait_for_completion_timeout()` never completing looks exactly like this. The
   platform path takes `platform_get_irq(pdev, 0)` — the `nhi` line — and which
   of the three interrupts is really the ring interrupt was flagged above as a
   question for the hardware.
2. **The window is mapped but the block is not fully out of reset.** ACPI
   describes power for these as PEP-managed (`_DEP` on `PEP0`, no `_PR0`/`_PS0`),
   and the DT node describes no power domain at all — only clocks.

Distinguishing them takes one boot: `/proc/interrupts | grep thunderbolt` for
whether the IRQ ever fires, and `thunderbolt.dyndbg=+p` to print `total paths:
N` from `REG_CAPS`. A sane `hop_count` means the window is alive and it is (1);
0 or 1023 means the window is dead and clocks are not enough.

**integ42** is integ41 plus `thunderbolt.dyndbg=+p`, staged and unbooted.

The dock meanwhile enumerated on its **USB 2.0 fallback** — `usb 1-1: Dell
dock`, three Realtek hubs, its audio — which is the correct behaviour for a TBT3
dock whose host router never came up, and confirms the dock itself is fine.

## The four gates, enumerated without booting — 2026-08-06

Everything below was established by reading the tree, the DSDT report and
Windows' PnP database. No boot was involved, and none of it needs one.

### Gate 1 — `modprobe.blacklist=thunderbolt`. Cheap.

`nhi_of_match` is `{ .compatible = "qcom,x1e80100-usb4" }` and all three
`hamoa.dtsi` nodes carry exactly that compatible, with `status = "okay"` applied
by `5f180ef47`. The driver is built (`CONFIG_USB4=m`), the devices enumerate
every boot. Only the cmdline stops the bind. **A cmdline edit, not a rebuild.**

### Gate 2 — `parade,disable-usb4`, and it is live, not cosmetic

Both SP11 retimer nodes in `x1-microsoft-denali.dtsi` carry
`parade,disable-usb4`. `ps883x.c:418` reads it into `retimer->disable_usb4`, and
`ps883x.c:276`:

```c
case TYPEC_MODE_USB4:
        if (retimer->disable_usb4) {
                dev_info(..., "USB4 disabled via DT property, rejecting USB4 mode\n");
                return -EOPNOTSUPP;
        }
```

That branch **is reachable on this machine.** `pmic_glink_altmode.c:381` calls
`pmic_glink_altmode_enable_usb4()` whenever a port reports
`MUX_CTRL_STATE_TUNNELING` with an SVID that is not `USB_TYPEC_TBT_SID`, and
that function sets `port->retimer_state.mode = TYPEC_MODE_USB4` and calls
`typec_retimer_set()`. So with the property in place the sequence ends in
`failed to setup retimer to USB4: -95`, with the retimer never told to map the
lanes for USB4.

The property is on **every** X1E board in the tree — Dell Thena, Acer Swift 14,
HP Omnibook X14, ThinkPad T14s, all three devkits, both IoT EVKs. That is worth
reading two ways: it is the deliberate upstream default rather than an SP11
quirk, *and* it means nobody upstream has ps883x USB4 lane configuration
working. Deleting it takes the "normal USB4 handling" path, which writes
`CONN_STATUS_2_USB4_CONNECTED` plus `CONN_STATUS_0_ACTIVE_CABLE` for non-passive
cables. Untested by anyone, on any board.

This is a **DTB change** (`tools/sp11-patch-dtb.sh`), and it is the second move,
not the first — bind the routers before changing the signal path.

### Gate 3 — USB4 entry rides the same notification channel as DP

`pmic_glink_altmode_enable_usb4()` is inside `pmic_glink_altmode_worker()`, the
same worker that carries DP alt mode and HPD. Nothing is delivered before
`ALTMODE_PAN_EN`, which on this machine is sent by `sp11-altmode.service` at
**~22.6 s** and not before. A dock present at power-on is therefore reported at
PAN_EN or not at all.

**For the first test, plug the dock in after the desktop is up.** That removes
the timing question entirely, and it also keeps the dock away from the window in
which the ADSP restart drops the Type-C ports.

### Gate 4 — the tunnel has nowhere to land in DT. This is the real one.

Windows puts tunneled PCIe under `\_SB.PCI0` and `\_SB.PCI1`:

| | ECAM | 32-bit window | 64-bit window | PnP |
|---|---|---|---|---|
| `PCI0` | `0x400000000` | 256 MB @ `0x40000000` | 3.75 GB @ `0x410000000` | `Present: False` |
| `PCI1` | `0x500000000` | 256 MB @ `0x50000000` | 3.75 GB @ `0x510000000` | `Present: False` |

Two of them, for two user-facing ports, empty until a hotplug event.

**`hamoa.dtsi` describes no host bridge anywhere near those addresses.** Its four
PCIe controllers are ordinary on-die ones:

| node | ECAM/config | domain | Denali |
|---|---|---|---|
| `pcie3: pcie@1bd0000` | `0x78100000` | 3 | not enabled |
| `pcie4: pci@1c08000` | `0x7c100000` | 4 | enabled — internal NVMe |
| `pcie5: pci@1c00000` | `0x7e100000` | 5 | not enabled |
| `pcie6a: pci@1bf8000` | `0x70100000` | 6 | enabled — WiFi |

Those match MCFG segments 4, 5, 6, 7 — the *small* two-bus segments. The USB4
tunnel targets are segments 0 and 1, the 256-bus ones, and they have **no DT
node at all**.

So the honest expectation for the first boot: the routers bind, and a tunneled
device still does not appear, because on a DT boot there is no host bridge for it
to enumerate under. That is exactly the failure mode `HOTPLUG_PCI_PCIE` was
feared to cause — and it would be misread the same way. Distinguish them by
looking for the tunnel itself (`/sys/bus/thunderbolt/devices/`, `tb_tunnel`
messages) before looking for a PCI device.

Whether host bridges at `0x400000000` / `0x500000000` can simply be described in
DT — and what clocks, resets and interconnect paths they need — is unanswered.
It is the first thing to work out if the routers bind and nothing tunnels.

**Linux's CM will not help here, and that is by design.** `tb_tunnel_alloc_pci()`
takes two `struct tb_port *` and nothing else; `tb.c:2259`–`2294` finds them with
`tb_switch_find_port(sw, TB_TYPE_PCIE_UP)` on the device router and
`tb_find_unused_port(sw, TB_TYPE_PCIE_DOWN)` on the host router. No `pci_dev` is
consulted anywhere on that path — the only `pci_upstream_bridge(nhi->pdev)` in
the subsystem is `tb.c:3323`, inside `tb_apple_add_links()`, which returns early
off x86. So the tunnel will be programmed happily whether or not a host bridge
exists to receive it, and **a successfully built tunnel is not evidence that
anything will enumerate.** Which root complex the host router's PCIe-down adapter
is wired to is a property of the silicon, and ACPI is currently the only
description of it we have.

### Corrected while checking the above

- **`CONFIG_HOTPLUG_PCI_PCIE` is `=y`** in the running stockcfg kernel
  (`data/integ33/config:2155`). `first-boot-runbook.md` said it was unset; that
  was true of the integ config, not of the kernel we run. One less rebuild.
- **Windows currently has no host router devices at all.** `QcUsb4Bus` is the
  only USB4 service running; `Usb4HostRouter`, `Usb4DeviceRouter` and
  `QcUsb4Filter` are all `Stopped`, and the only PnP device is
  `ACPI\QCOM0C6D\2&DABA3FF&0`, the bus. Host routers are materialised on
  attach. Firmware also carries **two** `Surface USB4 Retimer` UEFI capsule
  entries, Port 0 and Port 1 — two ports, three routers, consistent with the
  `_PLD` finding above.

#### Gotcha: invoking WSL from Git Bash

`wsl.exe -d Ubuntu-22.04 bash /mnt/c/...` fails from Git Bash — MSYS rewrites
the `/mnt/...` argument into `C:/Program Files/Git/mnt/...` before `wsl.exe`
sees it. Prefix the command with `MSYS_NO_PATHCONV=1`. `wslpath` does not exist
in Git Bash either. Combine with the existing rule that WSL work goes in script
files, never inline `bash -c`.
