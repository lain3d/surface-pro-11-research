# Prior art

Surveyed 2026-08-01. This materially changed the project's framing, so it is kept
separate from the original analysis rather than folded into it.

## Summary

Two things happened in July 2026 that the rest of these docs predate:

1. **NVIDIA shipped an ARM64 Windows GPU driver.**
2. **Someone ran a GeForce card as an eGPU on a Snapdragon X Elite laptop with it.**

Together these mean Walls 2 and 3 in `feasibility.md` — "no ARM64 KMD exists" and
"writing a UMD is not a solo project" — are potentially bypassable by installing
someone else's driver rather than writing one.

## NVIDIA GeForce 616.00 ARM64 (Developer Preview)

- Released July 2026 from NVIDIA's developer portal:
  `https://developer.download.nvidia.com/assets/geforce-drivers/616.00_DeveloperPreview_win11_arm64_International.exe`
- Native Windows 11 **arm64** package. Ships CUDA 13.4 support for Windows on Arm.
- INF is `nv_surface_woa.inf`. It officially matches only RTX Spark **N1X**
  (Blackwell, 6144 / 5120 CUDA core configs), a generic **"NVIDIA Desktop Device"**
  entry, and several NPU/DLA device IDs. Desktop GeForce parts are *not* officially
  listed.
- Intended target is Microsoft's Surface RTX Spark Dev Box, ahead of the N1X
  Windows-on-Arm systems launching in autumn 2026.

Despite the INF's narrow match list, the driver binaries evidently cover more silicon
than they advertise — see below. Installation on unlisted hardware is done by pointing
Device Manager at the extracted files ("Have Disk") and overriding the compatibility
warning.

Known issues called out by NVIDIA: CUDA transfers on pageable memory underperform,
some PyTorch build workflows trigger GPU timeouts or restarts, and the display can
stay blank for ~2 minutes during install.

## RTX 4060 eGPU on Snapdragon X Elite

- Machine: Lenovo YOGA Air 14s, Windows 11 on Arm.
- Chain: USB4 port → Razer Thunderbolt 5 dock → Thunderbolt-to-M.2 → M.2-to-PCIe
  adapter → RTX 4060. Notably *not* a conventional eGPU enclosure.
- Driver: the 616.00 ARM64 developer preview, manually installed.
- Results: ~44.6 FPS in Cyberpunk 2077, ~53 FPS in Forza Horizon 6.

Significant because the 4060 is **Ada**, not Blackwell — so the driver works on at
least one GPU generation outside its INF match list.

## The tunnel already works on this exact model

A Surface Pro 11 (Snapdragon) user attached an NVIDIA card in a **Razer Core X**. The
card **enumerated in Device Manager**, binding to "Microsoft Basic Display Adapter".
No resource error, no code 12, no host-bridge failure reported.

That is Phase 0 of the plan in `feasibility.md`, already executed by a third party on
this hardware. It empirically confirms the whole transport chain — retimer, host
router, PCIe tunnel, host bridge appearance, MMIO window assignment, PCI enumeration —
and independently corroborates the ACPI analysis in `device-profile.md`.

The report predates 616.00, which is why it ends in "wait for NVIDIA drivers."

Microsoft's own HLK requirement backs this up: systems with a USB4 host router and
externally connectable USB4 ports **must** support PCIe tunneling on all exposed
connectors, per chapter 11 of the USB4 spec.

## AMD status: nothing

No ARM64 Windows Radeon driver, and no announced plans. The only AArch64 artifact AMD
ships is a UEFI GOP driver for boot-time output on ARM servers — not a runtime Windows
driver.

**This inverts the hardware recommendation in `feasibility.md`.** That document
recommends AMD, correctly, *for the write-your-own-driver path*: open documentation,
AtomBIOS, and a complete Mesa/RADV reference stack. But for the goal of actually using
a GPU on this machine, AMD is currently the only vendor that cannot work at all, and
NVIDIA — the worst choice for a custom driver — is the only one that can.

| Goal | Vendor |
|---|---|
| Use a GPU on this machine, working, soon | **NVIDIA** (616.00 ARM64) |
| Write a GPU driver as the actual project | **AMD** (RDNA2, RADV, AtomBIOS) |

## What this does to the project

The custom-driver work in `architecture.md` is no longer the shortest path to a
working GPU. It remains interesting on its own terms — a Vulkan stack over a
self-written KMD is a genuinely novel thing on Windows on Arm, and it does not depend
on NVIDIA's preview driver continuing to exist or continuing to accept unlisted
hardware. But it should now be chosen deliberately as a project, not adopted as a
necessity.

The pragmatic path, in order:

1. eGPU enclosure + an NVIDIA card. Ada is proven; Blackwell is what the driver
   actually targets and is the safer bet.
2. Install 616.00 ARM64 via Device Manager, overriding the compatibility warning.
3. If it works — done, with none of the driver work.
4. If it doesn't, the platform analysis in this repo still holds, and the custom
   driver path is unchanged and still open.

Step 1–2 costs an enclosure and a card, and answers the entire question in an evening.

## Sources

- [igor'sLAB — Snapdragon X Elite + RTX 4060 eGPU](https://www.igorslab.de/en/snapdragon-x-elite-geforce-rtx-4060-windows-on-arm-egpu-capabilities/)
- [VideoCardz — Snapdragon X Elite laptop runs RTX 4060 eGPU with NVIDIA ARM driver](https://videocardz.com/newz/snapdragon-x-elite-laptop-runs-geforce-rtx-4060-egpu-with-nvidia-arm-driver)
- [TweakTown — Cyberpunk 2077 on an RTX 4060 eGPU via the RTX Spark driver](https://www.tweaktown.com/news/112802/snapdragon-x-elite-laptop-runs-cyberpunk-2077-using-an-rtx-4060-egpu-with-the-help-of-an-rtx-spark-development-driver/index.html)
- [Guru3D — GeForce 616.00 ARM64 RTX Spark Developer Preview](https://forums.guru3d.com/threads/nvidia-geforce-616-00-arm64-rtx-spark-developer-preview-driver.461096/)
- [VideoCardz — first Windows-on-Arm GeForce driver confirms N1X specs](https://videocardz.com/newz/nvidias-first-geforce-driver-for-windows-on-arm-confirms-rtx-spark-n1x-with-6144-or-5120-cuda-cores)
- [Microsoft Q&A — Razer Core X eGPU on Surface Pro 11](https://learn.microsoft.com/en-us/answers/questions/2303940/cant-set-up-egpu-nvidia-card-in-razer-core-x-with)
- [Microsoft Q&A — Does Surface Pro 11 support PCIe tunneling over USB4](https://learn.microsoft.com/en-us/answers/questions/2305789/does-surface-pro-11-support-pcie-tunneling-over-us)
- [AMD community — driver support for AMD eGPU on Arm64 Windows](https://community.amd.com/t5/pc-drivers-software/will-there-be-driver-support-for-amd-mobile-egpu-on-arm64/m-p/695694)
