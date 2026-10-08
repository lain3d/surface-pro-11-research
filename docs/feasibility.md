# eGPU on Surface Pro 11 (ARM64) — Feasibility

Status as of 2026-08-01. No eGPU hardware on hand yet; everything below is derived
from the platform itself (ACPI tables, driver binaries, PnP state).

> **Superseded in part by `prior-art.md`.** This document was written before
> discovering that NVIDIA shipped an ARM64 Windows driver in July 2026 and that an
> RTX 4060 has been run as an eGPU on a Snapdragon X Elite laptop. Walls 2 and 3
> below are accurate about what it takes to *write* a driver, but they are no longer
> the only option. The platform analysis (Wall 1) is unaffected and is independently
> corroborated by that prior art.

## Verdict

The **platform** is not the blocker. Every hardware and firmware precondition for an
external PCIe GPU is present and correctly provisioned.

For **using** a GPU here, the answer is now NVIDIA's 616.00 ARM64 developer preview —
see `prior-art.md`.

For **writing** a driver, the blocker is entirely software above the bus: no vendor
ships an ARM64 Windows KMD for a discrete GPU except NVIDIA's preview, and the
user-mode half of one is not a solo project. The realistic target for that path is
**not** "plug in a GPU and play games" but "a non-WDDM compute/render device with a
Vulkan front end." That is achievable and can be made stable. See `architecture.md`.

## Wall 1 — Transport and firmware resources: **CLEARED**

This was the question that could have killed the project outright. It doesn't.

**PCIe tunneling is implemented, inbox, for ARM64.**
`Usb4HostRouter.sys` (Microsoft, arm64, 645 KB, binds `ACPI\ACPI0015`) contains
`Usb4Hrd::PCIeTunnel::InitInternal`, `Usb4Hrd::PCIeTunnel::Configure`, and a
`USB4TunnelTypePcie` tunnel class alongside DisplayPort, USB3 and InterDomain. Its
bandwidth manager explicitly co-schedules `usb3&pcie` against link capacity.

Qualcomm's `QcUsb4Bus8380.sys` is only the USB-side dynamic enumeration bus (DMF +
UDECX, zero PCIe logic); it publishes the `ACPI\ACPI0015` PDO that the Microsoft
stack binds. The layering initially looks like PCIe support is missing — it isn't,
it's just in the other driver.

**Firmware reserves real MMIO space for tunneled devices.**
`\_SB.PCI0` and `\_SB.PCI1` are declared in the DSDT as full 256-bus host bridges,
each with a **3.75 GB 64-bit MMIO window** (`0x410000000` and `0x510000000`) plus
256 MB below 4 GB. Both are registered with PnP as `Present: False` — waiting for a
hotplug event. The five internal bridges get 29–32 MB each by comparison.

3.75 GB is not the full 16 GB a modern card might want for Resizable BAR, but:
- The host programs rBAR size. Since we write the driver, we choose it.
- 256 MB (the traditional non-rBAR aperture) or a 2 GB rBAR both fit comfortably.
- Losing full-VRAM rBAR costs some performance, not function.

The windows are declared non-prefetchable (`tflags=0x01`), which is mildly unusual
for a 64-bit window above 4 GB. Not expected to block placement, but it's the first
thing to check if the PCI arbiter ever refuses a BAR.

**DMA is sane.** IORT puts all 8 root complexes behind an **SMMUv3**, reporting
40-bit addressing, `coherent = True`, no ATS. Coherent DMA is a significant
simplification — no cache maintenance around buffers, unlike most ARM SoCs.

**Resolved since writing:** whether Windows actually *populates* `PCI0`/`PCI1` and
assigns those windows on a real hotplug. A Surface Pro 11 user's Razer Core X
enumerated in Device Manager as "Microsoft Basic Display Adapter" — no code 12, no
resource failure. The transport chain is empirically proven on this model. Microsoft's
HLK also *requires* PCIe tunneling on all exposed USB4 connectors. See `prior-art.md`.

## Wall 2 — Kernel-mode driver must be native ARM64: **tractable, or skippable**

Windows on ARM emulates x64 in **user mode only**. There is no kernel-mode emulation,
so an x64 `.sys` can never load.

**NVIDIA now ships one** (616.00 ARM64, developer preview), which is the skip. For
every other vendor this half gets written from scratch.

That is real work but bounded: PCI enumeration, BAR mapping, interrupt (MSI) setup,
DMA via the OS abstraction, then device bring-up. For AMD, bring-up runs **AtomBIOS**,
which is interpreted bytecode rather than x86 machine code — it ports to ARM cleanly,
which is exactly how Radeons boot on POWER and ARM under Linux today.

Signing: test-signed driver requires **Secure Boot off** (Surface UEFI, Vol-Up at
boot) and **HVCI off**. Both currently on. Both reversible.

## Wall 3 — User-mode driver: **the actual wall**

A D3D12 UMD means a DXIL→RDNA shader compiler, residency/memory management, and full
pipeline-state translation. Team-years. Not happening solo, and this is where the
project must route around rather than through.

The route around: **don't write a display driver at all.** Write a KMD that exposes
an amdgpu-shaped ioctl surface, then port Mesa's **RADV** (MIT-licensed, already a
complete Vulkan driver, already contains the RDNA compiler) on top. Apps get Vulkan
directly; D3D via DXVK/VKD3D-Proton if wanted later.

This converts "write a GPU compiler" into "write a compatibility shim" — still the
largest single piece of work in the project, but the kind one person can finish.

## Wall 4 — Presentation: **deferred by design**

No WDDM means the eGPU is not a display adapter. The desktop compositor will not know
it exists. Options, in increasing cost:

1. **Headless compute.** Render/compute offscreen, read results back. Works from day
   one of the Vulkan stack. This is the honest v1.
2. **Copy-back present.** Render offscreen, DMA the frame to host RAM, blit into a
   normal window via the Adreno. USB4 gives roughly 2.5–3.5 GB/s of real bandwidth —
   fine for 1080p60, tight at 4K.
3. **Drive a monitor on the eGPU directly.** Requires implementing display engine
   programming, mode setting, DP link training. Large, and independent of everything
   else. Last.

## Bandwidth reality

USB4 at 40 Gbps, minus encoding and minus whatever DisplayPort/USB3 tunnels are
co-scheduled, lands around 22–32 Gbps ≈ 2.5–3.5 GB/s — roughly PCIe 3.0 x4. For
compute with a decent compute-to-transfer ratio this barely matters. For gaming it
costs 10–25%. It is not the limiting factor of this project; the driver is.

## Next steps, in order

Which sequence depends on which project you're doing.

**To use a GPU (recommended first):**

1. Optionally prove the tunnel on *this* unit for ~$40 with any TB3/TB4 NVMe
   enclosure. Re-run `probes/probe-platform.ps1` attached and diff against
   `data/probe-baseline.txt`. Already proven on the model, not on your specific
   device.
2. eGPU enclosure + an **NVIDIA** card. Ada is proven working; Blackwell is what
   616.00 actually targets.
3. Install the 616.00 ARM64 developer preview via Device Manager "Have Disk",
   overriding the compatibility warning. Expect a ~2 minute blank screen during
   install.

**To write a driver (the original project):**

4. Get a **TB3/TB4 GPU enclosure + an RDNA2 card** (RX 6600/6700 class). RDNA2 is the
   sweet spot: mature RADV support, well-documented ISA, AtomBIOS init, modest power.
   Avoid the newest generation — least reverse-engineering maturity.
5. Disable Secure Boot + HVCI, enable test signing, confirm a hello-world KMDF driver
   loads on ARM64 at all.
6. Then start on the KMD per `architecture.md`.

Steps 2–3 cost an enclosure and a card and answer the entire question in an evening.
Doing them first is worthwhile even if the driver project is the real goal — a working
reference implementation on the same hardware is a substantial debugging asset.
