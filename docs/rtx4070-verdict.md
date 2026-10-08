# RTX 4070 over eGPU on this Surface Pro 11 — verdict

Two different questions. Answering both.

## 1. Will it work?

**Very likely yes.** Every precondition that can be checked without hardware checks
out. Nothing known is blocking.

| Requirement | Status | Evidence |
|---|---|---|
| PCIe tunneling over USB4 | ✅ | `Usb4Hrd::PCIeTunnel::*` in inbox ARM64 `Usb4HostRouter.sys` |
| Firmware reserves MMIO for it | ✅ | `\_SB.PCI0/PCI1`, 3.75 GB 64-bit window each |
| GPU enumerates on this model | ✅ | Third party: Razer Core X on a Surface Pro 11 appeared in Device Manager |
| ARM64 kernel driver exists | ✅ | `nvlddmkm.sys`, 122 MB, ARM64 |
| KMD knows the RTX 4070 | ✅ | `0x2786` present in the 348-entry device table; `CNvDisplay_Ada_AD102` HAL compiled in |
| Loads with Secure Boot / HVCI on | ✅ | Catalog signed by Microsoft Windows Hardware Compatibility Publisher |
| Targets this OS build | ✅ | INF decoration `NTarm64.10.0...26200`; machine is 26200 |
| Same generation proven working | ✅ | RTX 4060 (Ada, `sm_89` — same as 4070) ran on Snapdragon X Elite |

Install path: forced Have Disk install, **without editing the INF** (editing breaks
the catalog hash and the driver then won't load under Secure Boot).

Residual risk is that nobody has done this exact combination — Surface Pro 11 + 4070 +
616.00. It is not zero, but nothing identified points at failure.

## 2. Will it be genuinely usable?

More qualified. Ranked by how much each will actually bother you.

### Internal-display (portable) use

The target use case is portable: carry the enclosure, plug into USB-C, use the
Surface's own screen. That means **cross-adapter presentation** — the 4070 renders,
the frame is copied back over the tunnel to the Adreno, which scans it out.

The machinery exists in this driver build. `nvwgf2umax.dll` contains `Optimus` and
`CrossAdapter`; both it and `nvlddmkm.sys` reference `dGPU`/`iGPU`, and the KMD has
`displayless`. So the hybrid path is compiled in, not stripped.

**The Adreno side checks out too.** Verified on this machine with
`probes/Check-CrossAdapter.ps1`:

```
Adapter 0: Qualcomm(R) Adreno(TM) X1-85 GPU
   CrossAdapterRowMajorTextureSupported : YES
   CrossNodeSharingTier                 : 0
   ResourceHeapTier                     : 2
   ResourceBindingTier                  : 3
```

Plus **WDDM 3.1** and D3D feature level **12_1** (dxdiag). `CrossAdapterRowMajorTexture`
is precisely the capability cross-adapter shared surfaces require, so the display side
of the hybrid path is supported, not merely assumed.

That leaves the *combination* untested rather than any individual piece unsupported —
a much better position than before. Both ends declare support; nobody has publicly run
them together.

Cost when it does work: every frame crosses the tunnel in the opposite direction to
the render traffic. Typical eGPU internal-display penalty is roughly **15–30%**,
worse the higher the frame rate (more copies per second). An external monitor removes
this entirely, which is why it is the right way to *benchmark* — but it is not a
requirement for use.

### Bandwidth: roughly PCIe 3.0 x4

USB4 40 Gbps, minus overhead and minus any co-scheduled DisplayPort/USB3 tunnels,
lands around 2.5–3.5 GB/s.

- **Compute and offline rendering** (Blender Cycles, encode/decode): little impact.
  Data in and out is small relative to time spent computing. Often under 5%.
- **Games**: roughly 10–15% at 1440p, worse at 1080p where you are transfer- and
  CPU-bound, better at 4K.

### No Resizable BAR

A 12 GB card wants a 16 GB power-of-two BAR. The window is 3.75 GB, so rBAR will be
off and the card falls back to the 256 MB aperture. A few percent in games,
negligible for compute. Not a blocker — just don't expect rBAR gains.

### Hot-plug

USB4 PCIe tunneling is *inherently* hot-plug — that is the whole mechanism. The
strongest evidence is structural: `\_SB.PCI0` and `\_SB.PCI1` sit in the ACPI
namespace registered with PnP but `Present: False`, waiting for a device to arrive.
Bridges that materialise on attach are hot-plug by construction.

Supporting detail from the DSDT: `_OSC` is present on each PCI bridge including PCI0
and PCI1 — that is the method through which the OS requests control of PCIe features,
native hot-plug among them. `_HPX` (hot-plug parameters) is present once. There is no
`_RMV` or `_EJ0`, but those are for ACPI-mediated ejection (ExpressCard style) and are
not used by native PCIe hot-plug, so their absence is expected rather than concerning.

What is *not* provable without hardware is whether firmware grants the OS native
hot-plug control when `_OSC` is evaluated — that is a runtime negotiation. Given
Microsoft's HLK requires PCIe tunneling on all exposed USB4 connectors, denial would
be a firmware bug rather than a design choice.

**Surprise removal is a separate matter from hot-plug working.** Yanking the cable
mid-session produces `DXGI_ERROR_DEVICE_REMOVED`. Well-written applications recover;
many crash and lose unsaved work. Treat unplugging as "close apps first", not as
hot-swap.

### It is a developer preview, and you will be pinned to it

NVIDIA does not support this configuration and there is no update channel for it.
Their own published issues: CUDA transfers on pageable memory underperform, some
PyTorch build workflows cause GPU timeouts or system restarts, and the display can
stay blank for ~2 minutes during installation.

### Hotplug, sleep and resume are the likely pain

Surprise removal, sleeping with the eGPU attached, and dock/undock cycles are what
break eGPU setups even on mature x86 platforms. Untested here. Budget for treating it
as "attach, use, shut down, detach" rather than something you hot-swap casually.

### CPU side

For emulated x64 games the X1E80100 will often be the limit before the 4070 is.
Native ARM64 workloads are fine.

## 3. Per-application

**Blender**
- Viewport / EEVEE: native ARM64 build, Vulkan backend, should work on the eGPU.
- Cycles GPU: **not** with the stock ARM64 build — CUDA/OptiX are gated off in
  Blender's CMake for `WIN32 AND ARM64`. Run the **x64 Blender under emulation**
  instead: its CUDA calls resolve to `nvcuda64.dll`, which is ARM64EC (native ARM64
  code), so rendering runs at essentially native speed and only Blender's own CPU work
  is emulated. See `nvidia-arm64-driver.md`.

**Premiere Pro** — the weakest link, and still unverified.
- The driver has everything needed: ARM64 NVENC, NVDEC, H.264/HEVC/AV1 Media
  Foundation encoders, Optical Flow.
- But Adobe's ARM64 system requirements name a *Qualcomm Adreno* driver version, and
  Adobe deferred hardware-accelerated export for selected formats on ARM. Whether
  their ARM64 build will enumerate and use a non-Adreno GPU is an Adobe question no
  amount of driver analysis can settle. Test before relying on it.

## Candidate blockers, ranked

Nothing found so far is disqualifying. Ordered by how likely each is to actually bite.

1. **Windows picks the wrong adapter.** With no display on the eGPU, apps must be
   routed to it. Windows' "high performance GPU" heuristic was written for
   Intel/AMD iGPU + NVIDIA dGPU laptops; whether it classifies an NVIDIA eGPU
   correctly next to an Adreno is unknown. Mitigation is manual and easy —
   Settings → System → Display → Graphics → per-app GPU preference. Annoying, not
   fatal.
2. **Sleep / resume with the eGPU attached.** The classic eGPU failure mode even on
   mature x86 platforms. Entirely untested here. Budget for "shut down before
   unplugging" rather than lid-close-and-go.
3. **NVIDIA's hybrid path assumes a familiar partner.** Optimus on laptops pairs
   NVIDIA with Intel or AMD integrated graphics and has vendor-aware code. An Adreno
   partner is novel. Windows' *generic* cross-adapter presentation does not require
   vendor cooperation, so the likely outcome is that it works via the generic path,
   possibly without whatever optimisations NVIDIA applies on known pairings.
4. **`_OSC` denying native hot-plug control.** Would break the whole thing, but would
   equally break every USB4 dock and NVMe enclosure, so it is very unlikely.
5. **Displayless operation of a GeForce.** `displayless` appears in `nvlddmkm.sys`,
   and Optimus laptops run displayless GeForces routinely. Low risk, and a cheap
   dummy HDMI plug is the fallback if it turns out to matter.
6. **Two USB-C ports, and one may be needed for charging.** An open-frame adapter
   generally does not deliver power upstream. The machine has two USB4 ports plus
   Surface Connect, so this is a cable-management annoyance rather than a limit.

## Cheap validation hardware

Enclosures are **not** GPU-locked. An eGPU enclosure is a PCIe slot, a Thunderbolt/USB4
bridge and power — it has no idea what card is in it. The Blackwell restriction found
in this project is in NVIDIA's INF file, not in any hardware. Any TB3/TB4/USB4
enclosure takes any card.

More usefully: **the driver supports Turing (`sm_75`) and later**, so validating the
whole stack does not require a 4070.

| Purpose | Hardware | Rough cost |
|---|---|---|
| Prove the PCIe tunnel only | any TB3/TB4 NVMe enclosure | ~$40 |
| Prove the whole GPU stack | used TB3 enclosure (Razer Core X, Akitio Node) + used RTX 2060 | ~$250 |
| Portable, minimal | open-frame USB4 adapter + card + GaN PSU | ~$150 + card |

A used **RTX 2060** is the cheapest card that exercises everything that matters:
`sm_75` so it is inside the driver's support range, and it has RT cores so OptiX is
genuinely tested rather than just CUDA. ~160 W, so a small PSU suffices. A GTX 1660 is
also `sm_75` and cheaper, but has no RT cores and so cannot validate OptiX.

Buying a cheap Turing card first, proving the stack, then buying the 4070 is
strictly better than leading with the expensive card.

## Buying: avoid the obvious choice

**Do not buy an all-in-one "portable eGPU".** The OneXGPU, GPD G1 and similar units
that look purpose-built for this use case all have **AMD Radeon** GPUs soldered in
(7600M XT and relatives). AMD has no ARM64 Windows driver and no announced plans, so
those devices are completely dead on this machine. They are the natural thing to reach
for and exactly the wrong thing to buy.

It has to be an enclosure plus a discrete **NVIDIA** card.

Portable is still achievable. Open-frame USB4/TB adapters exist at 280–370 g
(TREBLEET Mini, ANQUORA ANQ-L336 and similar) — essentially a PCIe slot and a
Thunderbolt bridge with no built-in PSU. Realistic travel weight:

| Item | Weight |
|---|---|
| RTX 4070 | ~1.0 kg |
| Open-frame USB4 adapter | ~0.3 kg |
| 240–300 W GaN/SFX PSU | ~0.7–1.0 kg |
| **Total** | **~2.0–2.3 kg** |

Backpack-able. Not pocketable. A full enclosure like a Razer Core X is 6.5 kg and is
a desk device, not a travel one.

## Bottom line

For **rendering**, the portable plan works well. Cycles doesn't stream frames — you
launch a render, the GPU computes, one image comes back — so the copy-back path is
barely on the critical path. Coffee-shop Blender is a realistic goal.

For **games**, three things compound, and the tunnel is not the biggest:
1. Cross-adapter copy-back, ~15–30%.
2. **x64 emulation on the CPU side**, which is likely the dominant limit. A 4070 will
   often be waiting on emulated game code rather than the reverse.
3. **Anti-cheat.** Many multiplayer titles' kernel anti-cheat does not support Windows
   on ARM at all. Single-player is generally fine; check per game before counting on it.

The existing data point is encouraging though: an RTX 4060 on a Snapdragon X Elite
returned ~44.6 FPS in Cyberpunk 2077 and ~53 FPS in Forza Horizon 6. Settings,
resolution and display path are unstated, but those are playable numbers on a weaker
card than a 4070.

Expect roughly PCIe 3.0 x4 with no rBAR. Expect hotplug and sleep to be what annoys
you. Verify Premiere before depending on it. And treat internal-display mode as the
thing to test first, because it is both the point of the exercise and the least proven
part of the stack.
