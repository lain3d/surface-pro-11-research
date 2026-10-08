# Vendored patches

## `blender-pr-161040.diff`

[blender/blender#161040 — "Deps: Enable CUDA/OptiX support for Windows ARM64"](https://projects.blender.org/blender/blender/pulls/161040)
by `pmoursnv` (Patrick Mours, NVIDIA). Open as of 2026-08-01, `mergeable: true`.

Vendored because **projects.blender.org sits behind Cloudflare bot protection** and
the HTML pages intermittently return 403/404 to browsers and tools alike. The
`.diff` endpoint is reliable; the rendered PR page often is not.

If the link 404s, these work:

```
# raw diff - reliable
curl https://projects.blender.org/blender/blender/pulls/161040.diff

# JSON metadata, state, body
curl https://projects.blender.org/api/v1/repos/blender/blender/pulls/161040

# comments
curl https://projects.blender.org/api/v1/repos/blender/blender/issues/161040/comments
```

Note it is *not* on GitHub. `github.com/blender/blender` is a read-only code mirror
with no pull requests, so searching there will never find it.

### What it changes

10 files. The core of it:

```diff
-if(NOT APPLE AND NOT (WIN32 AND CMAKE_SYSTEM_PROCESSOR STREQUAL "ARM64"))
+if(NOT APPLE)
   option(WITH_CYCLES_DEVICE_CUDA "Enable Cycles NVIDIA CUDA compute support" ON)
   option(WITH_CYCLES_DEVICE_OPTIX "Enable Cycles NVIDIA OptiX support" ON)
```

Plus: NVPTX backend in LLVM, OptiX in OSL, CUDA in OpenImageDenoise (with a patch to
link without a native-arch `cuda.lib`), an ARM64 workaround for `FindCUDA` failing to
locate `cudart`, and two unrelated Windows build fixes.

Apply with:

```
git fetch origin pull/161040/head:windows_arm_cuda   # preferred - gets the live branch
# or, from this vendored copy:
git apply /path/to/blender-pr-161040.diff
```
