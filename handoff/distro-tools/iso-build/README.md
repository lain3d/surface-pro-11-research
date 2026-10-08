# Historical ISO and kernel build tools

Source-only export of `iso-build/` from the private research snapshot
`c38ba9d323bc8d8ed520ea5aa74b4c57e15d9e37` (2026-08-02). Original script
commits were authored and committed by lain3d; the scripts contain no SPDX
notices. This export imports no private Git history, distro runtime, firmware,
compiled probes, kernel packages or ISO images. It is a historical workflow,
not a current supported distribution or evidence of hardware qualification.

## Scripts

| Script | Purpose |
|---|---|
| `00-deps.sh` | Install Debian/Ubuntu kernel and ISO build tools (root; apt) |
| `01-kernel-fetch.sh` | Shallow-clone the already-patched public kernel |
| `02-kernel-build.sh` | Select config, enable historical SP11 options, build `.deb` packages |
| `03-inspect-iso.sh` | Read-only mount and report base ISO layout; leaves it mounted |
| `04-remaster.sh` | Replace the root layer and live kernel, stage audited public userspace, assemble ISO |
| `04b-mkiso.sh` | Reassemble an already-prepared tree with the historical appended ESP |
| `05-verify-kernel.sh` | Inspect packaged SPI-HID modules, OLED Denali DTB and DMIC properties |
| `06-verify-iso.sh` | Compare boot metadata and inspect the produced ISO payload |

The obsolete patch-bootstrap checker and kernel-history publishing tool are
intentionally absent. Fetch defaults to
[`lain3d/surface-pro-11-kernel`](https://github.com/lain3d/surface-pro-11-kernel),
branch `main`; `KSRC`, `KERNEL_REPO` and `KERNEL_BRANCH` remain configurable.
An existing `KSRC/.git` is reused without fetching, resetting or changing its
branch: use a separate source directory to obtain a different revision.
Clone, Git inspection and `make kernelversion` failures retain nonzero status.

## External distro checkout: explicit and pinned

`04-remaster.sh` requires `DISTRO_ROOT` to name a separate checkout of the
public [`denisix/ubuntu-surface-pro-11`](https://github.com/denisix/ubuntu-surface-pro-11)
repository, with `origin` pointing there and HEAD at the audited revision
`049b1caccf153ccf7aa5d0f6b824a4dc48e8b02d`. The exact inspected
[`install.sh`](https://github.com/denisix/ubuntu-surface-pro-11/blob/049b1caccf153ccf7aa5d0f6b824a4dc48e8b02d/install.sh)
blob is `2fb9ba0b8d86b4e315aa055ac254431fe6463aea`.
Modified or missing allowlisted files are rejected before mounts or remastering.

```bash
git clone https://github.com/denisix/ubuntu-surface-pro-11.git /path/to/ubuntu-surface-pro-11
git -C /path/to/ubuntu-surface-pro-11 checkout --detach 049b1caccf153ccf7aa5d0f6b824a4dc48e8b02d
```

The `DISTRO_FILES` array in `04-remaster.sh` is the exact 32-file runtime
allowlist: installer; three GRUB drop-ins; Wi-Fi apt hook; seven runtime scripts;
audio topology and three UCM files; system-sleep hook; eight systemd unit/config
files; two udev rules; pen C source; NPU CMake presets; sensor config and two
sensor C sources. Only those individual files are copied to `/opt/sp11`, with
their relative paths. `.git`, assistant memories, development archives,
prebuilt pen/sensor executables, ISO trees, kernel patch folders and bundled
`hexagonrpc-src`/`libssc-src` development trees are not copied. The installer
can clone the latter projects at first boot; any locally patched versions of
those trees are deliberately not inherited.

No proprietary payload is shipped **in this handoff**. The external installer
requires its topology `.bin` at remaster time; it is copied from the public
distro checkout into the user's generated image, not exported here. Users must
assess that external artifact's licensing and redistribution rights themselves.

## Build environment and historical run

Use a native **aarch64 Linux** host with ample free disk/RAM; these scripts do
not set up cross-compilation. `00-deps.sh` installs Git, compiler/packaging tools,
SquashFS, xorriso and supporting utilities. Optional `device-tree-compiler`
adds the numeric DMIC-rate check. Supply your own lawful base ISO as
`$WORK/base.iso`; no ISO download or checksum is supplied by this export.

**Inspect the base before building.** The original Ubuntu Concept X1E layout
used `casper/minimal.squashfs` as its root and other layers as deltas. The writer
retains the original ESP extraction (`bs=512`, `skip=7964672`, `count=12288`)
and boot load size; it is NOT generic for different daily images. Confirm these
values with `xorriso -indev "$ISO" -report_el_torito as_mkisofs` and
`-report_system_area plain`, or adapt the writer deliberately before using a
different base. No successful assembly report proves firmware will boot it.

From this directory, after provisioning the base ISO and public checkout:

```bash
sudo bash 00-deps.sh
sudo WORK=/root/sp11 bash 03-inspect-iso.sh
sudo KSRC=/root/sp11/linux-sp11 bash 01-kernel-fetch.sh
sudo WORK=/root/sp11 KSRC=/root/sp11/linux-sp11 bash 02-kernel-build.sh
sudo WORK=/root/sp11 bash 05-verify-kernel.sh
sudo WORK=/root/sp11 DISTRO_ROOT=/path/to/ubuntu-surface-pro-11 bash 04-remaster.sh
sudo WORK=/root/sp11 bash 06-verify-iso.sh
# Optional: rerun only assembly after editing a prepared ISO tree:
sudo WORK=/root/sp11 bash 04b-mkiso.sh
```

`WORK`, `ISO`, `OUT`, `KDEB_DIR`, `TARGET_LAYER`, `KSRC`, `KCONFIG` and `JOBS`
retain their script-specific historical overrides; `TREE` is configurable in
`04b-mkiso.sh`. `02` prefers explicit `KCONFIG`, then an already-extracted
`$WORK/squashfs-root/boot/config-*`, then arm64 defconfig. `03` does not extract
that root: obtain the matching base config separately. Kernel signing and BTF
are disabled by the historical build; this is not a Secure Boot setup.
The preserved config flips target the old touch/audio baseline, not a complete
camera-enabled config. For the latest camera tree, review the retained
[flavour-config exporter](../../../tools/mkconfig.sh) and supply its reviewed
result as `KCONFIG`; do not assume the default defconfig enables every camera
dependency just because the source is present.
`06` specifically inspects `minimal.squashfs` and the OLED/X1E device tree.

**Use a disposable work directory.** Remastering replaces `iso-tree` and `layer`;
verification replaces `verify`; assembly overwrites `OUT` and `$WORK/efi.img`.
Scripts mount images and bind host filesystems, execute chroots, and preserve
historical best-effort handling for some installation/initramfs operations.
An interrupted remaster can leave mounts; inspect and unmount them before
removing work directories. No script automatically writes a USB device.

## First-boot runtime dependencies and limits

The generated system unit retains `/opt/sp11/install.sh --all`; it does not
invoke the installer's obsolete `--kernel` path. Review that public installer
before booting: it changes GRUB, udev, firmware, audio and suspend services,
mounts a Windows NTFS volume read-only for sensor data, and performs network
downloads/builds. Its external requirements include:

- A systemd/udev Debian/Ubuntu root with GRUB tools, initramfs-tools, sudo,
  Python 3, ALSA utilities, PipeWire/WirePlumber and GNU shell utilities.
- `curl`, `jq`, `cabextract`, `zstd` and installed WCN7850 `board-2.bin` data;
  firmware CAB downloads use WOA-Project/Qualcomm-Reference-Drivers, and Wi-Fi
  extraction downloads the qca ath12k board encoder.
- A compiler for the pen daemon; NPU/sensor phases additionally need Git, wget,
  unzip, binutils, autoconf/automake/libtool, pkg-config, CMake/clang, Meson/Ninja
  and the development packages named in the external installer.
- Distribution `hexagonrpcd`/FastRPC packages and a `fastrpc` account; external
  Qualcomm QAIRT/Hexagon SDK/DSP components, fastrpc and llama.cpp sources, and a
  downloaded Hugging Face model. Availability/licensing is the user's concern.
- A matching Windows installation's DriverStore sensor JSONs, calibration and
  pre-parsed FastRPC registry; these cannot be fabricated or supplied here.

`--all` includes NPU and sensors, not just basic live-session setup. Network,
Windows data and hardware/session prerequisites can fail; the installer warns
and continues in some phases. The first-boot service runs as root without a
selected desktop `SUDO_USER`, so per-user PipeWire setup may target root and
need deliberate execution in the intended user's session. Stock source clones
do not promise the optional patched hexagonrpc functionality. Review service
journal and verification output; the firstboot marker is not a hardware test.
The preserved speaker routing has no demonstrated speaker-protection guarantee.

## Non-destructive handoff checks

Use real Git, make, PE tools and ISO readers on disposable paths. The
[publication verification record](../README.md#publication-verification)
distinguishes source/PE/ISO checks from an actual hardware boot.
Do not use a physical root disk or write USB media for these checks. The
historical appended-ESP interval still needs review against your actual base.
On a Windows-mounted checkout, Git may reject root's access as dubious
ownership; run as the owner or trust only that known checkout for the invocation,
never a blanket `safe.directory=*`.
