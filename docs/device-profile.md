# Surface Pro 11 (ARM64) — Platform Profile

General-purpose reference for this machine. Not eGPU-specific — this is the "why does
this niche thing not work" file. Everything here was measured on the device, not
looked up. Re-generate the raw data with `probes/probe-platform.ps1` and
`probes/dump-acpi.ps1` + `probes/parse_acpi.py`.

Last verified: 2026-08-01

## Identity

| | |
|---|---|
| Model | Microsoft Surface Pro, 11th Edition |
| SoC | Snapdragon X Elite **X1E80100**, 12 core, 3.40 GHz |
| Arch | ARM64 (`SystemType: ARM64-based PC`) |
| OS | Windows 11 Home, 10.0.**26200** |
| Firmware | Qualcomm EDK2 (`OemTableId: QCOMEDK2`), Surface SSDT overlay (`SsdtSurf`) |

## Security posture (matters constantly on this device)

| Feature | State |
|---|---|
| Secure Boot | **Enabled** |
| VBS | **Running** (`VirtualizationBasedSecurityStatus = 2`) |
| HVCI / Memory Integrity | **Running** (`SecurityServicesRunning` includes 2) |
| Available security properties | 1 (hypervisor), 2 (Secure Boot), 3 (DMA protection), 5 (UEFI code RO), 7 (MBEC) |
| Kernel DMA Protection | Available; no explicit policy key set |

Consequences:
- Any unsigned / test-signed kernel driver requires **Secure Boot off + HVCI off**.
  Both are reversible; Surface UEFI (Vol-Up at boot) can disable Secure Boot.
- HVCI blocks drivers that allocate RWX or use certain legacy patterns, even when
  test-signed. Turn it off before debugging driver loads — the failure mode is a
  useless generic "cannot start" error.

## ACPI / firmware layout

16 tables exposed via `EnumSystemFirmwareTables`, plus DSDT (277 KB) which is *not*
enumerated and must be fetched by signature — a Windows quirk that trips up most
dump scripts. `dump-acpi.ps1` handles both.

Notable: `IORT` (SMMU topology), `CSRT` (47 KB — Qualcomm core system resources),
`SDEV` (secure devices), `PPTT` (cache/topology), no `DMAR` (that's x86; ARM uses IORT).

### PCIe segments (MCFG)

Eight segments. Three "big" ones with full 256-bus ranges, five small single-port ones.

| Seg | ECAM base | Buses | Role |
|---|---|---|---|
| 0 | `0x400000000` | 0–255 | **USB4 tunnel target** (`\_SB.PCI0`) — CONFIRMED populated on dock attach, 2026-08-06 |
| 1 | `0x500000000` | 0–255 | **USB4 tunnel target** (`\_SB.PCI1`) — second port, still empty |
| 2 | `0x6000000000` | 0–255 | declared, `_STA` = 0 (not registered with PnP) |
| 3 | `0x740000000` | 0–1 | declared, not registered |
| 4 | `0x7C000000` | 0–1 | **internal NVMe** (`ACPI\PNP0A08\4`) |
| 5 | `0x7E000000` | 0–1 | declared, not registered |
| 6 | `0x70000000` | 0–1 | **internal WiFi** — FastConnect 7800 (`ACPI\PNP0A08\6`) |
| 7 | `0x74000000` | 0–1 | declared, not registered |

Only `PNP0A08\0`, `\1`, `\4`, `\6` register with PnP. `\0` and `\1` show
`Present: False` — they exist in the namespace waiting for a hotplug event.

**Confirmed 2026-08-06:** plugging a Dell WD19TB (Thunderbolt 3, Intel Titan
Ridge `8086:15EF`) populates segment 0. `\_SB.PCI0.RP1` is a Qualcomm
`17CB:0111` root port — the same device ID as the NVMe's and the WiFi's — with
the dock's PCIe switch on buses 1–2 and an Intel xHCI on bus 3, and everything
downstream working. PCIe tunneling on this SoC is a measured fact, not a hope.
See `usb4-host-router.md`.

### MMIO windows reserved per host bridge

From each bridge's `_CRS` in the DSDT:

| Bridge | 32-bit window | 64-bit window | Buses |
|---|---|---|---|
| PCI0 | 256 MB @ `0x40000000` | **3.75 GB @ `0x410000000`** | 256 |
| PCI1 | 256 MB @ `0x50000000` | **3.75 GB @ `0x510000000`** | 256 |
| PCI2 | 256 MB @ `0x60000000` | 63.75 GB @ `0x6010000000` | 256 |
| PCI3 | 32 MB | 1022 MB | 2 |
| PCI4 | 29 MB | — | 2 |
| PCI5 | 29 MB | — | 2 |
| PCI6 | 29 MB | — | 2 |
| PCI7 | 29 MB | — | 2 |

All windows are declared `non-cacheable / RW`, `MinFixed|MaxFixed`
(`gflags=0x0C tflags=0x01`) — i.e. **not** marked prefetchable. Worth knowing if the
PCI arbiter ever refuses a placement.

The internal devices get only 29 MB apiece; the two USB4 bridges get 3.75 GB. That
asymmetry is the whole reason external PCIe is viable here.

### IOMMU (IORT)

- 30 nodes. Two `SMMUv1/v2` (model 3 = MMU-500) serving on-SoC blocks
  (`\_SB.GPU0` — the Adreno — has 22 stream-ID mappings; `\_SB.SISP` the ISP).
- **All 8 PCIe root complexes map to an SMMUv3.**
- Every root complex reports: **40-bit** DMA address limit (1 TB),
  **`coherent = True`**, **`ATS = no`**.

Consequences for any driver doing DMA here:
- Device-visible addresses are **IOVAs**, not physical. Use the OS DMA abstraction;
  raw `MmGetPhysicalAddress` results will not work.
- I/O is **cache-coherent** — no manual cache maintenance around DMA buffers. This is
  a large simplification versus most ARM SoCs.
- No ATS/PRI, so no shared virtual memory / device page faults.

## USB4 / Thunderbolt stack

Two-layer, and the split is not obvious:

1. `QcUsb4Bus8380.sys` (Qualcomm, `ACPI\QCOM0C6D`, "Dynamic Enumeration Bus Driver").
   Built on DMF + **UDECX** (USB device emulation). Handles the USB side and
   exposes a child PDO with hardware ID **`ACPI\ACPI0015`** ("USB4 HR PDO").
   Contains no PCIe logic at all.
2. `Usb4HostRouter.sys` (Microsoft inbox, **arm64**, 645 KB) binds `ACPI\ACPI0015`
   and `PCI\USB4_MS_CM`. This is the real connection manager.

`Usb4HostRouter.sys` implements all four tunnel types —
`USB4TunnelTypePcie`, `USB4TunnelTypeDisplayPort`, `USB4TunnelTypeUSB3`,
`USB4TunnelTypeInterDomain` — with a bandwidth manager that co-schedules
USB3 + PCIe against link capacity (`Usb4Hrd::BandwidthManager`,
`Usb4Hrd::PCIeTunnel::Configure`).

Its INF sets `DMA Management\RemappingSupported = 1` and 16 MSI vectors.

Hardware also includes `Surface USB4 Retimer (Port 0/1)` as UEFI-updatable
firmware devices — retimer firmware ships through Windows Update, and a stale
retimer is a plausible cause of flaky high-speed USB-C behavior.

## Toolchain present

- Python 3.12.10
- Windows Kits 10 headers: `10.0.26100.0`
- Visual Studio "18" install directory present
- git
- **Missing**: `cl`, `clang`, `link`, `msbuild`, `cmake`, `ninja` on PATH; no `iasl`
  (so ACPI decompiling has to be done by parser, see `probes/parse_acpi.py`)

## Gotchas collected

- **DSDT is not in `EnumSystemFirmwareTables` output.** It's referenced by the FADT,
  not the XSDT. Fetch it with `GetSystemFirmwareTable(ACPI, 'DSDT')` directly.
- **`_CRS` on the PCI bridges is a dynamic method**, so the inline resource template
  found near `PNP0A03` is the one that carries the real windows. A naive AML scan
  that only looks at `PNP0A08` finds nothing.
- **Ghidra MCP: `import_file` requires GUI mode** (`Import requires GUI mode
  (PluginTool not available)`), but that does *not* mean headless analysis is
  unavailable. The headless server imports at launch via its own `--file` flag —
  one server instance per binary, on its own port:

  ```
  C:\Tools\ghidra-mcp\start-server-for-file.bat "C:\path\to\binary.sys" 8090
  ```

  Then `list_instances` / `connect_instance` to switch the bridge onto it. The
  long-running instance on port 8089 is the Ableton one
  (`start-ableton-server.bat`, project `C:\Tools\ghidra-proj\Ableton.gpr`) — don't
  repurpose it; `create_project` against the connected bridge *does* switch that
  server's open project out from under the Ableton work.
- `run_script_inline` is gated behind `GHIDRA_MCP_ALLOW_SCRIPTS=1`, unset in the MCP
  config (`.claude.json` → `mcpServers.ghidra.env` is `{}`). Setting it would allow
  arbitrary Java in the Ghidra process, including programmatic `AutoImporter` calls.
- Qualcomm's USB4 driver name has an SoC suffix (`8380`) and lives only in the
  DriverStore, not `System32\drivers` — filename searches for `usb4` miss it.
- The `.cat` in that package is named `8280` while the driver is `8380`. Harmless,
  but confusing when grepping.
