# Building Blender for Windows ARM64 with CUDA / OptiX

Blender is GPL. Nothing legal or proprietary blocks this. The gate is entirely build
configuration plus one historical logistics problem that stopped being a problem in
July 2026.

## The driver side is already correct

A native ARM64 process calling `LoadLibrary("nvcuda.dll")` gets **native ARM64 CUDA**.
No emulation, no thunking. Verified from the INF's install mapping plus PE headers:

```
INF:  nvcuda.dll , nvcuda_loader64.dll     -> System32 (dir 11)
      nvoptix.dll, (same name)             -> System32

nvcuda_loader64.dll   ARM64   ARM64X (hybrid ARM64 + ARM64EC)
  └─ nvcudaa64.dll    ARM64   ARM64 native          (11 MB, sm_75 .. sm_121)
nvoptix.dll           ARM64   ARM64X (hybrid ARM64 + ARM64EC)
  └─ nvoptixa.dll     ARM64   ARM64 native          (88 MB, sm_75 .. sm_130)
nvptxjitcompilera64.dll ARM64 ARM64 native
```

ARM64X is the point: **one file serves both worlds**. A native ARM64 caller executes
the ARM64 side; an emulated x64 caller executes the ARM64EC side. So the same
`System32\nvcuda.dll` gives native Blender native CUDA and emulated Blender ARM64EC
CUDA. This is exactly the arrangement you would design if you wanted both to work, and
it means a native build has no driver-side obstacle at all.

## Don't write the patch — it already exists, from NVIDIA

**[blender/blender#161040 — "Deps: Enable CUDA/OptiX support for Windows ARM64"](https://projects.blender.org/blender/blender/pulls/161040)**

- Author: `pmoursnv` — Patrick Mours, NVIDIA, Blender's OptiX developer.
- Opened 2026-07-03, targets `main` from branch `windows_arm_cuda`.
- **State: open, `mergeable: true`.** Last activity 2026-07-15.

What it does, beyond the obvious CMake change:

- Enables `WITH_CYCLES_DEVICE_CUDA` and `WITH_CYCLES_DEVICE_OPTIX` on Windows ARM64
- Enables the NVPTX backend in LLVM (needed by OSL's OptiX support), and OptiX in OSL
- Enables CUDA in OpenImageDenoise, with a workaround so it links without a native-arch
  `cuda.lib`
- Forces MSVC for kernel compilation (`--force-cl-env-setup`) to fix Clang header issues
- Fixes a couple of unrelated Windows build breakages

**It confirms the cross-compile point, and makes it easier than described below.** From
the PR body: you do *not* need an ARM64 CUDA toolkit. Copy `\bin\*`, `\include\*`,
`\lib\x64\*` and `\nvvm\*` from an **x86_64 CUDA 12.8** install onto the ARM64 machine
and set `CUDA_PATH`. It works because Blender only uses the CUDA *driver* API, so it
needs the headers and `nvcc` — and `nvcc` "can compile kernels successfully running in
emulation".

Directly relevant to this project, Patrick Mours on whether older GPU architectures
could be dropped from `CYCLES_CUDA_BINARIES_ARCH` for Windows on Arm:

> sm_120 is sufficient to handle various Blackwell variants, so don't need to add
> something new. We could remove older architectures for Windows on ARM. **Then again
> somebody could also plug in an external GPU, in which case they would be needed
> again.**

NVIDIA's own developer explicitly anticipates eGPU use on Windows on Arm, and argues
for keeping Turing/Ampere/Ada kernels compiled in because of it.

### What is actually blocking the merge

Not code. Build-infrastructure provisioning. Sergey Sharybin asked how buildbot
machines would get CUDA, preferring "official CUDA builds" over copying files from an
x64 install. Patrick's last reply (2026-07-15):

> If usually the actual installer for the various versions is run, then we'll need to
> wait for a WoA toolkit installer.

**That blocker looks stale.** NVIDIA shipped the first CUDA Toolkit preview for
Windows on Arm around 2026-07-21 — six days after that comment, and nobody appears to
have updated the PR. Worth a comment on the thread if you build it successfully.

## Toolkit vs driver — two different things, both needed

Easy to conflate, so stated plainly:

| | **CUDA Toolkit** | **Display driver (616.00)** |
|---|---|---|
| What | `nvcc`, headers, import libs | `nvlddmkm.sys`, `nvcuda.dll`, `nvoptix.dll` |
| When | **Build time**, on the machine compiling Blender | **Runtime**, on the machine with the GPU |
| Architecture | x86_64 is fine (runs emulated) | must be ARM64 — and is |
| From | CUDA 12.8 installer files, copied over | the 775 MB preview package analysed here |

The PR's "existing x86_64 CUDA toolkit" refers **only to the build side**. It says
nothing about the driver, and does not conflict with using 616.00 — the built Blender
*requires* a driver like it to run at all.

**Why an x86_64 toolkit suffices:** Blender never links against native CUDA libraries.
It uses the **CUDA driver API**, resolved at runtime by `cuew` doing
`LoadLibrary("nvcuda.dll")`. The toolkit is needed only for headers and for `nvcc` to
compile Cycles' kernels into cubins/PTX — and cubins are *GPU*-architecture-specific,
not host-architecture-specific.

The PR states this outright, in the ARM64 workaround it adds:

```cmake
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "ARM64")
  # FindCUDA does not handle arm64 library path and fails finding required cudart
  # It is not needed in Cycles anyway though, so just force it to some dummy value
  set(CUDA_CUDART_LIBRARY cudart)
endif()
```

"It is not needed in Cycles anyway" — there is no `cudart` dependency at runtime.
OpenImageDenoise is the same shape: its CUDA device is built with
`OIDN_DEVICE_CUDA_API = "Driver"`, and the PR's `oidn_cuda.diff` patches out its need
for the native-arch `cuda.lib` import library.

**So at runtime, everything comes from the driver we analysed:**

- `nvcuda.dll` → `nvcuda_loader64.dll` (ARM64X) → `nvcudaa64.dll`, ARM64 native
- `nvoptix.dll` (ARM64X) → `nvoptixa.dll`, ARM64 native
- OptiX's host API is header-only at build time and loads `nvoptix.dll` at runtime

Version skew is not a problem: kernels compiled against CUDA 12.8 run on a
616.00-era driver, because NVIDIA drivers are backward compatible with older toolkits.

## Is this PR for the same setup?

Yes. Same platform — Windows ARM64 with an NVIDIA GPU and this driver stack. Its
stated motivation is the N1X / RTX Spark machines ("This is going to change soon
though"), but the eGPU case is explicitly in scope; see the author's remark about
keeping older architectures compiled in because "somebody could also plug in an
external GPU".

What it is *not* is a patch for eGPU support specifically. It enables the Cycles CUDA
and OptiX backends for the platform. Whether the GPU is soldered to an N1X board or
tunneled over USB4 is invisible to Blender — by the time Cycles calls `cuInit`, it is
just a CUDA device.

## What is actually gating it

### 1. One CMake condition

```cmake
if(NOT APPLE AND NOT (WIN32 AND CMAKE_SYSTEM_PROCESSOR STREQUAL "ARM64"))
  option(WITH_CYCLES_DEVICE_CUDA  ... ON)
  option(WITH_CYCLES_DEVICE_OPTIX ... ON)
endif()
```

Delete the `WIN32 AND ARM64` clause and the options exist again.

### 2. Compiling the GPU kernels

The only piece needing an NVIDIA toolchain. `intern/cycles/kernel/device/cuda/kernel.cu`
is compiled by `nvcc` into cubins per `sm_XX`, and the OptiX variant into OptiX-IR/PTX.

Two ways to satisfy it, and the second is the one people miss:

- **Native**: NVIDIA now ships a CUDA Toolkit preview for Windows on Arm (13.4), which
  did not exist before July 2026. That gives you an ARM64 `nvcc` invoking ARM64 MSVC.
- **Cross-compile**: cubins and PTX are **GPU**-architecture-specific, not
  **host**-architecture-specific. Build them on any x64 machine with a normal CUDA
  toolkit and drop the artifacts in. This route needs no ARM64 toolkit at all and
  sidesteps any rough edges in the preview.

There is also `WITH_CYCLES_CUDA_BINARIES=OFF`, in which case Cycles falls back to
compiling kernels at runtime via NVRTC. Note the **driver does not ship NVRTC** — it
has `nvptxjitcompiler` (PTX→SASS, a driver component) but NVRTC (CUDA C++→PTX) is a
toolkit redistributable. So either precompile the binaries or ship NVRTC yourself.

### 3. OptiX SDK headers

The OptiX host API is header-only and loads `nvoptix.dll` dynamically at runtime.
Blender's per-platform prebuilt dependency bundle (`lib/windows_arm64`) would need the
OptiX headers added. Cheap — it is a header drop, not a compiled library.

### 4. The real reason: nobody could test it

Until July 2026 no NVIDIA GPU could exist on a Windows ARM64 machine. There was no
hardware, no driver, and no CUDA toolkit for the platform. Disabling the option was
correct at the time. That premise is now stale, and this is a straightforward
candidate for an upstream patch rather than a permanent fork.

## Evidence the host-side code is clean

The CMake condition is `WIN32 AND ARM64`. **Linux aarch64 is not gated**, and a
community ARM64 Linux Blender with working CUDA and OptiX exists. Same host
architecture, same Cycles device code, builds and runs.

So there is nothing ARM-hostile in `device/cuda/*.cpp`, `device/optix/*.cpp`, or cuew
— cuew just does `LoadLibrary("nvcuda.dll")` and resolves function pointers, which is
architecture-agnostic. The Windows ARM64 exclusion is about Windows, not about ARM.

## Recipe

Toolchain on this machine is already sufficient: **Visual Studio Community 2026**
(18.4.11620.152) with the MSVC ARM64 host toolset present at
`VC\Tools\MSVC\14.50.35717\bin\Hostarm64`.

1. Clone Blender and fetch the PR branch:
   ```
   git clone https://projects.blender.org/blender/blender.git
   cd blender
   git fetch origin pull/161040/head:windows_arm_cuda
   git checkout windows_arm_cuda
   ```
2. Get a CUDA toolkit. Either the new Windows-on-Arm preview, or — per the PR author —
   copy `\bin\*`, `\include\*`, `\lib\x64\*`, `\nvvm\*` from an x86_64 CUDA 12.8
   install and point `CUDA_PATH` at it. `nvcc` runs fine under emulation.
3. `make.bat` as normal. The PR handles the CMake options, OSL/LLVM NVPTX, and
   OpenImageDenoise.

Verify the result the same way the absence was detected — the strings should now be
present:

```
python probes/strings_pe.py <built blender.exe> "nvcuda\.dll|cuInit|cuDeviceGet|nvoptix"
```

## Risks

- The preview toolkit's `nvcc` must drive ARM64 MSVC as its host compiler. Plausible
  since that is its purpose, but unproven here. The cross-compile route avoids it.
- Removing the guard may expose downstream code that assumed CUDA implies x64. The
  Linux aarch64 precedent suggests not, but Windows-specific paths are less exercised.
- Everything downstream still depends on the preview driver and an unsupported eGPU
  configuration.

## Which to do first

Run the **emulated x64 Blender** first regardless. It requires zero build work and its
CUDA calls land in ARM64EC code, so GPU rendering is already near native speed — only
Blender's own CPU work is emulated. That establishes the eGPU renders at all, and
gives a performance baseline to judge whether the native build is worth the effort.
