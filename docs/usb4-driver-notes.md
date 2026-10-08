# `Usb4HostRouter.sys` — reverse engineering notes

Microsoft inbox USB4 connection manager, ARM64, v10.0.26200, 645 KB.
Analyzed in Ghidra headless (1501 functions after auto-analysis).

Reproduce:
```
C:\Tools\ghidra-mcp\start-server-for-file.bat "C:\Users\Crazy\projs\arm64-egpu\data\bin\Usb4HostRouter.sys" 8090
curl -X POST "http://127.0.0.1:8090/run_analysis?program=Usb4HostRouter.sys"
python probes\ghidra_api.py 8090 /search_strings search_term=PCIeTunnel
```

The binary is WPP-traced and largely stripped of symbols, but assertion strings carry
fully qualified C++ names (`Usb4Hrd::PCIeTunnel::Configure`), so the class structure
recovers cleanly from strings even where decompilation is noisy.

## Structure

Namespace `Usb4Hrd`. Tunnel classes, one per type:

- `Usb4Hrd::PCIeTunnel` — `InitInternal` @ `FUN_140039b30`, `Configure` @ `FUN_14008a8c0`
- `Usb4Hrd::DPTunnel` — `InitPaths`, main path + `m_DpInAuxPath` / `m_DpOutAuxPath`
- `Usb4Hrd::InterDomainDatapathTunnel` — host-to-host
- USB3 tunnelling handled via `BandwidthManager` USB3 paths

Tunnel type enum observed: `USB4TunnelTypePcie`, `USB4TunnelTypeDisplayPort`,
`USB4TunnelTypeUSB3`, `USB4TunnelTypeInterDomain`.

Supporting machinery: `Usb4Hrd::BandwidthManager`, `Usb4Hrd::DomainPolicyManager`,
`Usb4Hrd::TmuDomainPolicy` (time management unit), `Usb4Hrd::AsymmetricDomainPolicy`.

## Finding: no security gating on PCIe tunnels

Searched for `Security`, `Approv`, `Authoriz`, `Policy`, `Trust`, `Untrust`,
`DmaProtect`, `External`, `Iommu`, `Remap`. **21 hits, all of them bandwidth,
asymmetric-link, or TMU related** — `CheckAsymPolicyOnRouterPlugUnplug`,
`TmuDomainPolicy::DetermineAndApplyDomainPolicyLocked`, and assert-action policy.

There is **no Thunderbolt-style security-level model** here — no SL0–SL3 equivalent,
no per-device user approval, no "allowed buses" list, no untrusted-device concept in
this driver. "Domain policy" in this codebase means link bandwidth and clock domain
management, not access control.

Practical consequence: an attached PCIe device is not expected to require user
authorization before its tunnel is established. Whatever DMA containment exists comes
from the SMMUv3 (see `device-profile.md`), not from a gate in the connection manager.
That is convenient for this project and consistent with the stated tolerance for
running the machine in an unsafe configuration.

Caveat: this is a negative result from string search over one binary. Policy could
still live in `pci.sys`, the PnP subsystem, or the ACPI `SDEV` table (which exists on
this system, 110 bytes, and is worth parsing before treating this as settled).

## Registry tunables

Read by the driver, under its service/device parameters key:

| Value | Relevance |
|---|---|
| `EnableUSB4v2Support` | USB4 v2 (80 Gbps) gating |
| `ForceEnableDpBwAllocationMode` | forces DP bandwidth allocation mode |
| `EnableDpBwMinimalPreallocationMode` | reduces DP preallocation |
| `DisableCLxDomainWide` | disables CLx link power states domain-wide |
| `EnableDebugInterface` | debug interface |
| `EnableDriverDisableable` | driver unload behaviour |
| `SwAssertActionPolicy` / `HwAssertActionPolicy` | assert behaviour (bugcheck vs. continue) |

Two of these bear directly on an open question in `architecture.md` — whether an
attached DisplayPort tunnel starves the PCIe tunnel of bandwidth.
`EnableDpBwMinimalPreallocationMode` and `ForceEnableDpBwAllocationMode` are the knobs
that would shift that allocation, and are worth testing once a real eGPU is attached
and a monitor is on the same port.

`SwAssertActionPolicy` / `HwAssertActionPolicy` are useful during bring-up: the driver
is assert-heavy, and controlling whether an assert bugchecks affects how debuggable a
misbehaving tunnel is.

## DMA

Single relevant string: `WdfCommonBufferCreate(m_dmaEnabler, descriptorsBufferLength,
nullptr, &m_ringBuffer)`. The host router uses a WDF DMA enabler with a common-buffer
descriptor ring — consistent with the INF's `DMA Management\RemappingSupported = 1`
and with DMA going through the SMMU.

This is also a working reference for the DMA pattern our own KMD needs: WDF DMA
enabler → common buffer → device-visible logical addresses, rather than raw physicals.

## Not yet examined

- What actually triggers `PCI0`/`PCI1` host bridge appearance (likely `pci.sys` +
  ACPI hot-plug rather than this driver).
- `Usb4Hrd::PCIeTunnel::Configure` internals — decompilation is dominated by WPP trace
  prologue and needs the trace macros stripped before it reads usefully.
- The `SDEV` ACPI table.
