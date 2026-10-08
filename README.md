# Surface Pro 11 platform research

> **Unmaintained research; experimental hardware changes; no support commitment.**
> Released for others to inspect, reuse, and continue. Historical notes are not
> current installation instructions. Scripts can change boot configuration,
> firmware loading, regulators, and mounted disks; review them before running.

## Public release

This is a cleaned snapshot of `handoff/new-system` at
`e5337eca90b64ef4be05ab9a2c6d1bb30d7360fe`, released on 2026-10-07 without
the original private Git history or assistant-memory bundle. The original
research repository remains private.

Original research prose, probes, and tooling are MIT-licensed; see [LICENSE](LICENSE).
Third-party patches, quoted source, driver excerpts, OEM ACPI tables, and
vendor-derived register data retain their existing rights and provenance.
The MIT license does not grant redistribution rights over vendor material.
Complete proprietary drivers and firmware are not supplied.

### Most useful handoff

- [Front camera state and measured fixes](design/camera-state-20260807.md):
  IMX681 capture, desktop/libcamera integration, C-PHY bring-up, and mode timing.
- [Kernel source and experimental branches](https://github.com/lain3d/surface-pro-11-kernel):
  the latest camera work is on `debug/camss-cphy`, not the default `sp11` branch.
- [Upstream handoff and remaining limits](design/upstream.md): audio/ADSP,
  USB-C/DisplayPort, USB4, and camera/codec findings.
- [libcamera, FFmpeg, and libaperture patches](patches/): userspace fixes with
  their own evidence and scope.

### Release changes

- Excluded the private-memory handoff archive and two stray command-output files.
- Removed private-memory copying from both handoff generators.
- Limited handoff line-ending validation to Linux executables; PowerShell files
  intentionally retain CRLF.
- Removed references that required unpublished assistant notes.
- Added this maintenance notice and scoped original-material licensing.

## Historical research

Investigating external GPU support on a **Surface Pro 11 (Snapdragon X Elite
X1E80100, Windows 11 ARM64)** â€” and, along the way, keeping a decent platform
reference for this fairly niche machine.

No eGPU hardware on hand yet. Everything so far is derived from the device itself:
ACPI tables, driver binaries, PnP state.

> **New here?** Start with **[docs/orientation.md](docs/orientation.md)** â€” the
> vocabulary and mental model behind everything else (ACPI vs device tree, what
> CCI/CSIPHY/NHI/UCSI/HUTRR87 actually are, and how the pieces connect). Then
> **[design/state-and-unblock-plan.md](design/state-and-unblock-plan.md)** for
> where things stand and what happens next, and
> **[design/kernel-dev-strategy.md](design/kernel-dev-strategy.md)** for how the
> kernel work is done and verified.

## Current verdict

**The platform is not the blocker**, and as of July 2026 the driver may not be either.

On-device analysis established that PCIe tunneling over USB4 is implemented inbox on
ARM64, firmware reserves 3.75 GB of 64-bit MMIO per USB4 port for exactly this, and
DMA goes through a coherent SMMUv3. All the things that usually kill eGPU on an ARM
machine are fine here.

Then prior-art search turned up two things these docs originally predated: **NVIDIA
shipped an ARM64 Windows GPU driver** (GeForce 616.00, developer preview), and
**someone ran an RTX 4060 as an eGPU on a Snapdragon X Elite laptop with it** at
playable frame rates. Separately, a Surface Pro 11 user's Razer Core X **already
enumerates** in Device Manager â€” the transport chain on this exact model is
empirically proven.

So there are now two paths, and they want different hardware:

| Goal | Path | Vendor |
|---|---|---|
| Actually use a GPU here, soon | Install NVIDIA's 616.00 ARM64 preview | **NVIDIA** |
| Write a GPU driver as the project | Custom KMDF + Mesa RADV, no WDDM | **AMD** |

The custom-driver work is no longer the shortest route to a working GPU. It stays
interesting on its own terms â€” a Vulkan stack over a self-written KMD would be novel
on Windows on Arm, and it doesn't depend on a preview driver continuing to exist or to
accept unlisted hardware â€” but it should be chosen deliberately, not adopted as a
necessity.

Read in order:

| Doc | What's in it |
|---|---|
| [`design/three-pillars-loop.md`](design/three-pillars-loop.md) | **The work plan.** Iteration recipe for the three unsolved problems: multi-touch, camera, USB4 |
| [`docs/rtx4070-verdict.md`](docs/rtx4070-verdict.md) | **Start here for the practical question.** Will an RTX 4070 eGPU work on this machine, and will it be genuinely usable |
| [`docs/prior-art.md`](docs/prior-art.md) | **Read first.** NVIDIA's ARM64 driver, the working Snapdragon eGPU build, and what it does to this project |
| [`docs/nvidia-arm64-driver.md`](docs/nvidia-arm64-driver.md) | Teardown of the 616.00 package â€” full API inventory, chip support, the subsystem-locked INF, and what it means for Blender/Premiere |
| [`docs/native-blender-arm64.md`](docs/native-blender-arm64.md) | What actually gates a native ARM64 Blender with CUDA/OptiX, and how to build one |
| [`docs/feasibility.md`](docs/feasibility.md) | The four walls, what's cleared, what isn't, and next steps |
| [`docs/architecture.md`](docs/architecture.md) | Proposed design â€” no WDDM, RADV, user-mode fence polling |
| [`docs/linux-support.md`](docs/linux-support.md) | Per-peripheral Linux status for this exact machine. Pen and touchscreen do not work, and USB4 doesn't either â€” which rules out the Linux eGPU path |
| [`docs/linux-install-options.md`](docs/linux-install-options.md) | Custom ISO vs VM â€” WSL2 is a build environment, not a test environment, and why |
| [`docs/linux-prior-art.md`](docs/linux-prior-art.md) | **Who already solved what.** Pen, audio, suspend and sensors are working today in someone else's repo; USB4 and cameras are not |
| [`docs/linux-gap-analysis.md`](docs/linux-gap-analysis.md) | What it would take to fix each Linux gap, and whether any of it needs hardware RE (it doesn't) |
| [`docs/device-profile.md`](docs/device-profile.md) | General platform reference for this machine, not eGPU-specific |
| [`docs/usb4-driver-notes.md`](docs/usb4-driver-notes.md) | RE notes on `Usb4HostRouter.sys` â€” tunnel classes, registry tunables, and the absence of any security gate on PCIe tunnels |

## The one thing worth doing next

Get an **eGPU enclosure and an NVIDIA card**, install the 616.00 ARM64 developer
preview via Device Manager (overriding the compatibility warning), and see whether it
comes up. Ada is proven to work; Blackwell is what the driver actually targets.
That answers the whole question in an evening.

A **cheap TB3/TB4 NVMe enclosure** (~$40) is still a reasonable sanity check on *this
particular unit* first â€” a third party confirmed enumeration on a Surface Pro 11, but
not on yours. It proves the transport chain end to end: retimer, host router, PCIe
tunnel, host bridge appearance, SMMU, and MMIO window assignment.

```powershell
# before plugging anything in
powershell -ExecutionPolicy Bypass -File probes\probe-platform.ps1 -Tag baseline
# with the enclosure attached
powershell -ExecutionPolicy Bypass -File probes\probe-platform.ps1 -Tag with-enclosure
Compare-Object (gc data\probe-baseline.txt) (gc data\probe-with-enclosure.txt)
```

What to look for:
- `ACPI\PNP0A08\0` or `\1` flipping from `Present: False` to `OK` â€” transport works.
- A new device with **problem code 12** (insufficient resources) â€” the tunnel works
  but MMIO assignment doesn't, which would be the one genuinely fatal outcome.
- Nothing changes at all â€” tunneling isn't being negotiated; check retimer firmware
  and whether the enclosure is genuinely USB4/TB rather than plain USB-C.

## Tools

| Script | Purpose |
|---|---|
| `probes/probe-platform.ps1` | Snapshot PnP/PCI/USB4/security state. Designed for before/after diffing. |
| `probes/dump-acpi.ps1` | Dump all ACPI tables via `GetSystemFirmwareTable`, including the DSDT (which is *not* enumerated and needs fetching by signature). |
| `probes/parse_acpi.py` | Parse MCFG (PCIe segments), DSDT (host bridge MMIO windows), IORT (SMMU topology, DMA limits). Not a full AML interpreter â€” scans for raw resource descriptors, which is enough for recon. |
| `probes/strings_pe.py` | ASCII + UTF-16 strings and PE import table from a driver. Fast triage without involving Ghidra at all. |
| `probes/pe_arch.py` | PE machine-architecture inventory over a directory tree. Written to answer whether a driver ships ARM64, ARM64EC, or x64 user-mode components. |
| `probes/Check-CrossAdapter.ps1` | Query every D3D12 adapter for the cross-adapter / hybrid-presentation capabilities an eGPU driving the internal display depends on. |
| `probes/acpi_i2c_map.py` | Recover I2C/SPI/UART slave devices and their controllers from the Windows ACPI DSDT â€” for identifying hardware Linux hasn't named yet. |
| `probes/pe_hybrid.py` | Distinguish ARM64EC / ARM64X hybrid images from genuine x64 via the CHPE metadata pointer. PE machine type cannot tell them apart. |
| `probes/ghidra_api.py` | Minimal client for a GhidraMCP headless server's HTTP API, so you can talk to a specific port when several instances are running. |

Regenerate the ACPI analysis:

```powershell
powershell -ExecutionPolicy Bypass -File probes\dump-acpi.ps1
python probes\parse_acpi.py > data\acpi-report.txt
```

## Layout

```
docs/     findings and design
probes/   re-runnable investigation scripts
data/     generated output, OEM ACPI tables, and decoded reports
```

## Notes

- Proprietary system drivers used for offline analysis must be obtained from your
  own Windows DriverStore. `data/bin/` is gitignored and is not part of this release.

### Ghidra workflow (headless)

There are two modes, and **the difference decides whether your work survives**.

**Throwaway triage** â€” `start-server-for-file.bat` passes `--file`, which imports
into a *transient* program:

```
C:\Tools\ghidra-mcp\start-server-for-file.bat "...\Usb4HostRouter.sys" 8090
curl -X POST "http://127.0.0.1:8090/run_analysis?program=Usb4HostRouter.sys"
python probes\ghidra_api.py 8090 /search_strings search_term=PCIeTunnel
```

A `--file` program **can never be saved** â€” `save_program` returns
`Location does not exist for a save operation!`, and adding `--project` does not
help, because `--file` still imports transiently. Renames and comments made this
way are lost when the server stops.

**Durable work** â€” import into a real project first, then serve that program.
This is the only way renames, prototypes, structs and comments persist:

```
:: 1. import + analyze + save into the project (creates it if needed)
C:\Tools\ghidra\ghidra_12.1.2_PUBLIC\support\analyzeHeadless.bat ^
    C:\Tools\ghidra-proj SurfaceCam -import "...\rearsensor.sys" -overwrite

:: 2. serve the program that now lives in the project -- --program, not --file
C:\Tools\ghidra\ghidra_12.1.2_PUBLIC\support\launch.bat fg jdk GhidraMCPHeadless 4G "" ^
    com.xebyte.headless.GhidraMCPHeadlessServer ^
    --project C:\Tools\ghidra-proj\SurfaceCam.gpr --program /rearsensor.sys --port 8094
```

Then `save_program` works, and should be called after each batch of edits.

Gotchas:
- The loader does **not** auto-analyze when launched with `--file`.
  `analysis_status` reports `analyzed: false` and queries come back nearly empty
  until `run_analysis` has been POSTed. (`analyzeHeadless` analyses as it imports,
  so the `--program` path is already analysed.)
- **Reads are GET with query params; writes are POST with a JSON body.** Sending a
  mutation as a query string returns a misleading `"Function address or name is
  required"` even when the parameter is present. `probes/ghidra_api.py` only does
  GET, so use `Invoke-RestMethod -Method Post -Body <json> -ContentType application/json`
  for anything that changes the database.
- `create_project` takes `parentDir` + `name` (not `path`).
- The MCP bridge only ever sees the one auto-discovered instance â€” `list_instances`
  shows just port 8089 no matter how many per-binary servers are running, and
  `connect_instance` matches on *project name* among those. So MCP tools cannot
  drive a per-binary server; use HTTP.
- Port 8089 is the long-running **Ableton** instance. Calling `create_project` on the
  connected bridge switches that server's open project out from under it. Calling it
  over HTTP against your own port is fine.
- In PowerShell, don't name a variable `$args` â€” it is an automatic variable and the
  assignment silently yields nothing.
- **A kernel build after `git checkout` can report success without building what
  you asked for.** Switching to a branch that introduces a new Kconfig symbol
  leaves `.config` stale; the implicit `syncconfig` then tries to *prompt* for the
  new symbol, fails with `Error in reading or end of file` because stdin is
  closed, and the build still **exits 0**. The log looks like a menu dump. Set the
  symbol and run `olddefconfig` non-interactively on every branch before
  building, and check the symbol is really in `.config` before trusting the
  result:

  ```
  ./scripts/config --file .config -m CONFIG_VIDEO_IMX681
  make olddefconfig </dev/null
  grep -E '^CONFIG_VIDEO_IMX681=' .config    # or the build proved nothing
  ```
- **`analyzeHeadless` is throttled by default and it looks like a hang.** Its
  launcher sets `MAXMEM_DEFAULT=2G` plus
  `-XX:ParallelGCThreads=2 -XX:CICompilerCount=2`, explicitly so people can run
  many instances in parallel. On a 9.3 MB DLL that produced **36 minutes of CPU,
  RSS pinned at ~2 GB, and no program** â€” which reads as "too big to analyse"
  but is really GC thrash against a 2 GB ceiling. Raise it before blaming the
  binary:

  ```
  set GHIDRA_HEADLESS_MAXMEM=12G
  set GHIDRA_HEADLESS_JAVA_OPTIONS=-XX:ParallelGCThreads=8 -XX:CICompilerCount=8
  ```

  The server launcher (`start-server-for-file.bat`) takes its heap as an
  argument instead and is *not* subject to this default, which is why the small
  drivers analysed fine through it.
- **A running server holds the project lock, so `analyzeHeadless` cannot import
  into it.** The failure is immediate and explicit â€”
  `LockException: Unable to lock project!` â€” but easy to cause, because the
  natural workflow is to serve a program and then import the next one. Stop the
  server first; if it was killed rather than shut down, delete the stale
  `<Project>.lock` and `.lock~`.

Current projects: `C:\Tools\ghidra-proj\SurfaceCam.gpr` holds **eight** programs,
all imported with `analyzeHeadless` and therefore already analysed. Enumerate them
by reading `NAME` out of `SurfaceCam.rep/idata/**/*.prp` â€” do not go from memory,
which is how this list was wrong once already:

| program | annotations |
|---|---|
| `qccammipicsi8380.sys` | the CSIPHY/CSID driver â€” C-PHY settle table, lane masks and per-frequency register tables, extracted to `data/csiphy-cphy-x1e80100.txt` |
| `QcDeviceMFT8380.dll` | `CamX_ImageSensorData_CreateCSIPHYConfig`, `CamX_SensorNode_AcquireResources`, `CamX_IFENode_SetupCSIPHYInputResource` |
| `surfacecamfrontsensor8380.sys` | `CameraSensorDriver_SendCSLPacket` + a plate comment holding the recovered opcode map and the 24-byte `CSIPhyInfo` payload layout |
| `surfacecamrearsensor8380.sys` | camera-probe annotations, see `docs/camera-sensors.md` |
| `surfacecamauxsensor8380.sys` | none yet â€” the IR sensor, imported for comparison work |
| `qccamplatform8380.sys` | camera platform driver, imported 2026-08-02 |
| `qccamisp8380.sys` | **the CSID/IFE driver** -- imported 2026-08-07. The Windows counterpart of `drivers/media/platform/qcom/camss`; its strings name `CamZ\Core\IFEDriverV3\csid\src\csid_full_hal.c`. Has the RDI0-RDI4 path enables, the ipp/rdi/rx/top/bufDone ISR, `IFE Overflow IRQ`, and the full acquire structure (lane type dphy/cphy, VC, data type, VCDT count, input height, binning config, HBI count). Serve with `start-isp-server.bat` on 8099. Found by searching the DriverStore for `CsidRxTotalPktsRcvd`, which `qccammipicsi8380.sys` does *not* contain. `data/bin/` is gitignored, so copy it back from `C:\Windows\System32\DriverStore\FileRepository\qccamisp8380.inf_arm64_*\qccamisp8380.sys` before re-importing. |
| `QcUsb4Bus8380.sys`, `TouchPenProcessor0C83.dll` | earlier USB4 and touch work |

Launchers, one per program because **only one server can hold the project lock**:
`start-camx-server.bat` (8096), `start-frontsensor-server.bat` (8097),
`start-ableton-server.bat` (8089, a different project). Stop the running one
before starting another or before any `analyzeHeadless` import, and delete the
stale `.lock`/`.lock~` if it was killed rather than shut down â€” there is no
`/shutdown` endpoint, so killing it is the normal exit and the lock *will* be
stale.

The findings those annotations record are in
`design/camera-bringup-20260806.md`; the database is a convenience, the
document is the record.


Start here: [`design/three-pillars-loop.md`](design/three-pillars-loop.md).
