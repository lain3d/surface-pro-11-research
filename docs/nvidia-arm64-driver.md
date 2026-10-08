# NVIDIA GeForce 616.00 ARM64 — package analysis

`616.00_DeveloperPreview_win11_arm64_International.exe`, 775 MB, 3.1 GB extracted.
Driver version string: **32.0.16.1600**, dated 07/13/2026. Class `Display`.

Extract with 7-Zip (the payload uses the BCJ2 filter, which `py7zr` and bsdtar cannot
handle):

```
7z x 616.00_DeveloperPreview_win11_arm64_International.exe -oNV616
python probes\pe_arch.py NV616\Display.Driver
```

## Verdict

This is a **complete, production-shape WDDM driver**, not a compute stub or a
cut-down bring-up package. Every API surface a workstation application would ask for
is present as a native ARM64 binary, and NVIDIA additionally shipped **ARM64EC**
builds of the user-mode drivers so that emulated x64 applications get native-speed
graphics rather than a software fallback.

The limiting factor is **not** the driver. It is (a) the INF's hardware match list,
and (b) whether a given application's ARM64 build knows how to use a non-Adreno GPU.

## What's in it

151 PE files in `Display.Driver`: **ARM64 = 73, x64 = 46, x86 = 32**.

NVIDIA's suffix convention: no suffix / `32` = x86, `64` = x64, `a64` / `ax` = ARM64,
`a64ec` / `axec` = **ARM64EC**, trailing `x` = ARM64X hybrid forwarder.

Note ARM64EC images report PE machine type `AMD64` by design — that is how the x64
loader accepts them — so `pe_arch.py` lists them as `x64`. Machine type cannot
distinguish the two; the `CHPEMetadataPointer` field in the Load Config Directory can.
`probes/pe_hybrid.py` does that check, and the result is worth stating plainly:

**Every x64-ABI component in this driver is ARM64EC. There is no genuinely emulated
code in the package.**

```
nvcuda64.dll           x64    ARM64EC (native ARM64, x64 ABI)
nvcudart_hybrid64.dll  x64    ARM64EC
nvoptix64.dll          x64    ARM64EC
nvwgf2umaxec.dll       x64    ARM64EC
nvogla64ec.dll         x64    ARM64EC
nvcuvid64.dll          x64    ARM64EC
nvencodeapi64.dll      x64    ARM64EC
nvopencl64.dll         x64    ARM64EC
nvogla64x.dll          ARM64  ARM64X (hybrid ARM64 + ARM64EC)
```

An emulated x64 application that loads `nvcuda.dll` therefore gets **native ARM64
code**. Only the application's own code is emulated; everything below the API boundary
runs natively. You do not ship ARM64EC builds of an entire user-mode stack — D3D,
OpenGL, CUDA, OptiX, NVENC, NVDEC, OpenCL — unless you intend the existing x64
Windows software catalogue to be a first-class consumer of the GPU.

| Capability | ARM64 binary | Size | ARM64EC / x64 sibling |
|---|---|---|---|
| WDDM kernel driver | `nvlddmkm.sys` | 122 MB | — (kernel is ARM64-only) |
| D3D10/11/12 UMD | `nvwgf2umax.dll` | 89 MB | `nvwgf2umaxec.dll` |
| D3D9 UMD | `nvd3dumax.dll` | 70 MB | `nvd3dumaxec.dll` |
| UMD loader | `nvldumdax.dll` | 1 MB | `nvldumdaxec.dll` |
| OpenGL | `nvogla64.dll` | 31 MB | `nvogla64ec.dll` |
| Vulkan | `vulkan-1-a64.dll` | 2.8 MB | — |
| CUDA | `nvcudaa64.dll` | 11 MB | `nvcuda64.dll`, `nvcudart_hybrida64.dll` |
| OptiX | `nvoptixa.dll` | 88 MB | `nvoptix64.dll` |
| OpenCL | `nvopencla64.dll` | 12 MB | `nvopencl64.dll` |
| NVENC | `nvencodeapia64.dll` | 1.2 MB | `nvencodeapi64.dll` |
| NVDEC | `nvcuvida64.dll` | 33 MB | `nvcuvid64.dll` |
| Optical Flow | `nvofapia64.dll` | 753 KB | `nvofapi64.dll` |
| MF encoders | `nvencmfth264ax.dll`, `nvencmfthevcax.dll`, `nvencmftav1ax.dll` | ~2.8 MB ea | x86 variants |
| PTX JIT | `nvptxjitcompilera64.dll` | 26 MB | `nvptxjitcompilera64ec.dll` |
| DLSS / NGX | `_arm64_nvngx.dll`, `nvngx_dlssg.dll` | — | — |

Also present: `nvidia-smi.exe`, `nvfbca64.dll` (framebuffer capture), NVIDIA Container
services, HD Audio driver (`nvhda64a.sys`), and `nvcudla.dll` / `nvdla_runtime.dll`
for the N1X deep-learning accelerator.

The Media Foundation encoder MFTs for **H.264, HEVC and AV1 exist as ARM64 builds** —
that is the exact plumbing a video editor uses for hardware-accelerated export.

## GPU architecture support: Turing through Blackwell

Extracted from the compiler and runtime binaries:

- `nvcudaa64.dll` (ARM64 CUDA driver): `sm_75, sm_80, sm_86, sm_87, sm_88, sm_89,
  sm_90, sm_100, sm_103, sm_107, sm_110, sm_120, sm_121`
- `nvoptixa.dll` (ARM64 OptiX): `sm_75` through `sm_130`
- `nvptxjitcompilera64.dll`: `sm_20` through `sm_121`
- `nvlddmkm.sys` references `TU102`, `GA102`, `AD102`, `GB202`, and the family names
  Turing / Ampere / Ada / Blackwell

So the ARM64 build carries **NVIDIA's normal unified chip support** — RTX 20-series
onward — not an N1X-only subset. That is consistent with the third-party report of an
RTX 4060 (AD107, `sm_89`) working.

## The real constraint: the INF match list

`nv_surface_woa.inf` is 142 KB but contains only **five** hardware IDs:

| Hardware ID | Name |
|---|---|
| `ACPI\NVDA1081` | NVIDIA Graphics Device (N1X integrated) |
| `PCI\VEN_10DE&DEV_2E03&SUBSYS_0109`**`1414`** | RTX Spark N1X (6144-core Blackwell) |
| `PCI\VEN_10DE&DEV_2E06&SUBSYS_0109`**`1414`** | RTX Spark N1X (5120-core Blackwell) |
| `PCI\VEN_10DE&DEV_2E06&SUBSYS_0110`**`1414`** | RTX Spark N1X (5120-core Blackwell) |
| `PCI\VEN_10DE&DEV_2E13&SUBSYS_0116`**`1414`** | NVIDIA Desktop Device |

Every PCI entry is **subsystem-locked to `1414`, which is Microsoft's PCI vendor ID**.

Press coverage described the `DEV_2E13` entry as an unnamed generic "NVIDIA Desktop
Device", implying a catch-all. **It is not a catch-all** — it is one specific device ID
with a Microsoft subsystem ID. A retail RTX 4060 (`DEV_2882`) or RTX 5070 matches
nothing in this INF.

Consequence: installing on any retail card requires a forced install — Device Manager
→ Update driver → Browse → "Let me pick" → Have Disk → point at
`Display.Driver\nv_surface_woa.inf` → select a model → accept the compatibility
warning. Windows then applies one of the `SectionNNN` install sections regardless of
the hardware ID mismatch, and the KMD's own chip support decides whether the card
actually initialises.

**Do not edit the INF to add your device ID.** The catalog binds file hashes; changing
the INF invalidates its hash, the package becomes unsigned, and an unsigned kernel
driver will not load on ARM64 with Secure Boot on. The unmodified Have Disk route
keeps the signature intact — hardware-ID matching is not part of signature validation.

## The KMD's own device table: Turing through Blackwell, 348 entries

`nvlddmkm.sys` contains a sorted 16-bit device-ID table at file offset `0xF12E82`,
348 entries, spanning `0x1E02` (Turing) through Blackwell:

| Family | Count |
|---|---|
| Turing (`0x1E`–`0x21`) | 35 |
| Ampere (`0x22`–`0x25`) | 123 |
| Ada (`0x26`–`0x28`) | 78 |
| Blackwell (`0x2B`–`0x2F`) | 107 |

Spot checks, all **present**: `0x2786` RTX 4070, `0x2782` 4070 Ti, `0x2783` 4070 Super,
`0x2704` 4080, `0x2684` 4090, `0x2882` 4060, `0x2B85` 5090, `0x2C02` 5070.

Corroborated by the display HAL classes compiled into the same binary —
`CNvDisplay_Turing_TU102`, `CNvDisplay_Ampere_GA102`, **`CNvDisplay_Ada_AD102`**,
`CNvDisplay_Blackwell_GB202`.

So the restriction really is only in the INF. The driver itself is NVIDIA's normal
multi-architecture build and knows about retail GeForce cards by device ID.

## Signing: WHQL, so no security downgrade needed

- `nvlddmkm.sys` — Authenticode signed by `CN=NVIDIA Corporation` (DigiCert).
- `nv_surface_woa.cat` — signed by **`CN=Microsoft Windows Hardware Compatibility
  Publisher`**, chaining `Microsoft Windows Third Party Component CA 2014` →
  `Microsoft Root Certificate Authority 2010`. Valid, timestamped, expires 2027-05-11.

That is a genuine Microsoft attestation/WHQL signature, which means **Secure Boot and
HVCI can stay enabled**. No test signing, no `bcdedit`, no security posture change —
unlike the custom-driver path in `architecture.md`, which requires turning both off.

The INF's OS decorations are `NTarm64.10.0...17134` and `NTarm64.10.0...26200`. This
machine is build **26200** — an exact match for the newer section.

## Application reality check

The driver is not the bottleneck for either target application. The open questions are
app-side.

**Blender** — native ARM64 since 4.3; 4.5 LTS added a Vulkan backend built for Adreno.

- Viewport / EEVEE: should work. ARM64 Vulkan and OpenGL ICDs are both in the driver.
- **Cycles GPU rendering will not work with the official ARM64 build. Verified.**

Cycles loads CUDA at runtime through cuew rather than linking it, so the library and
entry-point names appear as literal strings in `blender.exe` when the backend is
compiled in. Comparing blender.org's 4.5.9 Windows builds:

| String | x64 `blender.exe` | ARM64 `blender.exe` |
|---|---|---|
| `nvcuda.dll` | 1 | **0** |
| `cuInit` | 2 | **0** |
| `cuDeviceGet` | 15 | **0** |
| `nvrtc` | 16 | **0** |
| `nvoptix` | 1 | **0** |
| `amdhip64` | 1 | 0 |
| `CUDA` (all occurrences) | 118 | 15 |
| `OptiX` (all occurrences) | 32 | 1 |

The residual `CUDA`/`OptiX` hits in the ARM64 binary are UI enum labels, not backend
code. `WITH_CYCLES_DEVICE_CUDA` and `WITH_CYCLES_DEVICE_OPTIX` are simply off in that
build — consistent with Blender's stated plan to reach Cycles hardware ray tracing on
Snapdragon via SYCL during 2026, targeting Adreno rather than NVIDIA.

Note the packaging is otherwise identical: neither build ships `.cubin`/`.ptx`/
`.optixir` files (kernels are embedded), and the only file-list differences between
the two zips are architecture-suffixed Python modules. So a naive "are the kernel
files there" check proves nothing — the string test is the one that discriminates.

### Nothing intrinsic is missing — it is one line of CMake

From Blender's `CMakeLists.txt`:

```cmake
if(NOT APPLE AND NOT (WIN32 AND CMAKE_SYSTEM_PROCESSOR STREQUAL "ARM64"))
  option(WITH_CYCLES_DEVICE_CUDA  "Enable Cycles NVIDIA CUDA compute support" ON)
  option(WITH_CYCLES_DEVICE_OPTIX "Enable Cycles NVIDIA OptiX support"        ON)
  ...
endif()
```

On Windows ARM64 the options are not merely off — they are never *defined*. HIP is
gated identically.

Critically, the condition is `WIN32 AND ARM64`. **Linux aarch64 is not gated**, which
is exactly why a community ARM64 Linux Blender with working CUDA and OptiX exists.
Same host-side device code, same architecture, and it builds and runs. So there is
nothing architecture-specific in Cycles' CUDA/OptiX host implementation — the Windows
ARM64 exclusion is a decision made when no NVIDIA GPU could exist on that platform,
not a technical limit.

Confirming the build really is configured that way, not just stripped: the ARM64
binary contains no `cuew`, no `hipew`, no `device_cuda` symbols at all.

### Which workaround is more viable

**Run x64 Blender under emulation — try this first.** Because `nvcuda64.dll` is
ARM64EC, x64 Blender's CUDA calls land in native ARM64 driver code. The GPU does the
rendering; only Blender's own CPU-side work (scene sync, UI, Python) is emulated, and
that is mostly idle during a render. Expect close to native *render* performance with
slower scene preparation. Cost: zero. Nothing to build.

**Build Blender for Windows ARM64 with the backends enabled.** Better end state —
fully native — and now genuinely practical, because NVIDIA ships a CUDA Toolkit
preview for Windows on Arm (13.4) that did not exist before July 2026. Relax the CMake
condition and build. One wrinkle: the driver ships `nvptxjitcompiler` (PTX→SASS, a
driver component) but **not** NVRTC (CUDA C++→PTX, a toolkit component), so either
build with `WITH_CYCLES_CUDA_BINARIES=ON` to precompile kernels with `nvcc`, or
redistribute NVRTC alongside. Note cubins are GPU-architecture-specific, not
host-architecture-specific, so they can be built anywhere.

Order of operations: emulation first to prove the eGPU renders at all, native build
afterwards if the CPU-side overhead actually bothers you.

**Premiere Pro** — native ARM64 since 26.0.
- The driver ships everything Premiere would want: ARM64 NVENC, NVDEC, the H.264 /
  HEVC / AV1 Media Foundation encoder MFTs, and the Optical Flow API used for frame
  interpolation.
- But Adobe's ARM64 system requirements name a **Qualcomm Adreno** driver version, and
  Adobe has explicitly deferred hardware-accelerated export for selected formats on
  ARM. Whether the ARM64 build enumerates and uses a non-Adreno GPU is an Adobe
  question this package cannot answer. **Unverified.**

## Method note

The decisive evidence came from the INF, PE header inventory, and targeted string
extraction — not from decompilation. Auto-analysing a 122 MB kernel driver in Ghidra
is many hours of work for questions that the package metadata answers directly. Worth
doing only if a specific behaviour needs tracing, e.g. whether `nvlddmkm.sys` gates
initialisation on subsystem ID rather than just device ID.
