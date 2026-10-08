# D:\surface — Surface Pro 11 Linux bring-up

Everything needed to boot Linux on this machine and continue the work. Staged
2026-08-02; every file below was checksum-verified after copying.

Historical local-drive manifest, not the contents of the public release.
The private-memory archive, Git bundles, Ghidra projects, and ISO images below
are not distributed in the public research snapshot.
The private Git-bundle generator has been removed. For current public source,
use the matching `research-handoff-2026-10` release tags in
[the research repo](https://github.com/lain3d/surface-pro-11-research/releases/tag/research-handoff-2026-10)
and [the kernel repo](https://github.com/lain3d/surface-pro-11-kernel/releases/tag/research-handoff-2026-10).
The old bundle-clone commands below describe that local drive only.

## Start here

`handoff\sp11-handoff\BRINGUP.md` — already unpacked, read it first. It is
written for someone (or some session) arriving with no context.

If the acronyms are unfamiliar, `handoff\sp11-handoff\docs\orientation.md`.

**Before booting anything: `handoff\sp11-handoff\design\first-boot-runbook.md`,
step 0.** BitLocker is TPM-only on this machine and Secure Boot has to come off
for an unsigned kernel, which will make Windows demand the recovery key. Get that
key off the machine first.

## What is here

```
iso\
  surface-pro-11-ubuntu-BASELINE-20260802-gd81a425b872a.iso   4.14 GB
  surface-pro-11-ubuntu-INTEG-20260802.iso                    4.55 GB
  *.sha256, BASELINE.SHA256SUMS
kernel-debs\
  linux-image / linux-headers for the baseline kernel
handoff\
  sp11-handoff-20260802.tar.gz    824 KB   docs, memories, tools, patches
  sp11-handoff\                            ^ unpacked, read directly
  sp11-repos-20260802.tar         1.18 GB  git bundles + Ghidra project
```

## Which ISO

| | BASELINE | INTEG |
|---|---|---|
| kernel | `7.1.3-sp11-gd81a425b872a-dirty` | `7.1.3-sp11-integ-gf2cc827b6b89` |
| Boots, pen/touch/wifi/audio | yes | yes |
| Multi-touch heat map | **yes** | yes |
| USB4 router binds | no | **yes** |
| PCIe tunnel enumerates | no | **yes** |
| Camera I2C address scan | no | **yes** |

**BASELINE** predates every feature branch. It is the control: if INTEG
misbehaves, this is what tells you whether the machine or the new patches are at
fault. **INTEG** carries all four branches plus the throwaway address-scan
branch, and answers everything.

Neither needs an install — every measurement works from a live session. An
external SSD install is only worth it if you plan to iterate on kernel or DT
changes.

## The repos tarball

```bash
tar -xf sp11-repos-20260802.tar && cd sp11-repos
git clone         bundles/surface-arm-platform-research.bundle research
git clone         bundles/surface-pro-11-linux.bundle           distro
git clone -b sp11 bundles/surface-pro-11-kernel.bundle          kernel
```

The kernel one needs `-b sp11` — the source repo is shallow, so the bundle
carries the eight complete branches by name rather than `--all`. See the
tarball's own README for why.

Also inside: `ghidra/SurfaceCam.rep`, the reverse-engineering database behind the
Windows-side findings, with the analysis's function names, types and comments.
Lock files were stripped; if Ghidra ever says "project is in use", delete
`*.lock` next to the `.gpr`.

## The four things that are still unknown

Each needs one measurement on real hardware. Nothing else is blocking.

1. Does the USB4 host router bind?
2. Does PCIe tunnel through it?
3. The front sensor's I2C address — provably not in the firmware, checked three
   ways. Needs the INTEG image's debug scan, **not** `i2cdetect`: nothing powers
   the sensor until a driver binds.
4. The Bayer/CFA order — provably not in any Windows file. Needs one captured
   frame.

## A note on the USB stick

The PNY stick was flashed with BASELINE and now shows no drive letter in Windows.
That is normal for a raw image write and does not mean it failed — the write was
byte-count exact. The readback verification was skipped, so if it will not boot,
re-flashing from `iso\` is the first thing to rule out.
