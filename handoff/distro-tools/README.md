# Reviewed distro/build tooling handoff

> Unmaintained research; experimental hardware changes; no support commitment.
> This export is source, not a supported installer or a newly qualified image.

The formerly unpublished distro checkout remains private. Useful original tools
are now included here; no private Git history, assistant memories, passwords,
proprietary payload, or generated kernel/ISO/EFI image was imported.

## What to use

- [ISO/kernel build tooling](iso-build/README.md): public kernel `main`, package
  inspection, remastering and ISO inspection. Runtime input is an explicitly
  selected public denisix checkout, not the private distro repository.
- [Historical EFI-stub tooling](boot-efistub/README.md): stub acquisition and
  three-variant UKI construction. Disk/UUID/path defaults were removed;
  replacing an ESP requires explicit opt-in.
- [ADSP test UKI builder](../../tools/sp11-build-adsp-test-uki.sh): rebuild an
  existing UKI's command line without silently truncating its PE section.
- [ADSP initramfs helper](../../tools/sp11-adsp-initramfs-boot.sh) and
  [later pre-mount hook](../../tools/50-sp11-adsp.sh): already retained public
  versions; the older private runner was not copied over them.

The ADSP experiment can disconnect a USB-C root disk or wedge the hardware.
These sources do not establish a complete external-root fix. Later session
notes supersede some of the August experiment's hypotheses; do not infer an
already-working current installation from a historical command sequence.

## ADSP experiment deployment

The historical `/usr/local/sbin/sp11-adsp` command means an installed copy of
`tools/sp11-adsp-initramfs-boot.sh`, not a missing private script. Before booting
an experimental UKI, copy it into the selected target root at that path. Do not
run it from a mounted live desktop root: the helper refuses outside initramfs,
and restarting ADSP on USB-root is not a safe desktop operation.

The builder expects an existing UKI at `<ESP>/EFI/BOOT/BOOTAA64.EFI`, root access,
a mounted ESP, and GNU objcopy/objdump capable of handling its AArch64 PE image.
`ESP=/path/to/mounted/esp` overrides `/boot/efi`. It checks section positions and
payload hashes before writing the alternate image:

```bash
sudo ESP=/path/to/mounted/esp bash tools/sp11-build-adsp-test-uki.sh --status
sudo ESP=/path/to/mounted/esp bash tools/sp11-build-adsp-test-uki.sh
# These change the boot default; review the image and maintain recovery first:
sudo ESP=/path/to/mounted/esp bash tools/sp11-build-adsp-test-uki.sh --install
sudo ESP=/path/to/mounted/esp bash tools/sp11-build-adsp-test-uki.sh --rollback
```

No signed EFI stub, kernel, DTB, initrd, firmware, or recovery image is supplied.
The builder does not sign its result or make Secure Boot work.

## Provenance and license

The original script authorship was checked against the source commits. Own
ISO/EFI scripts are covered by the repository's scoped [MIT grant](../../LICENSE).
The ADSP tools keep their explicit BSD-3-Clause SPDX notice; the full
[BSD-3-Clause license](../../LICENSES/BSD-3-Clause.txt) is included. No upstream
kernel, denisix runtime, Ubuntu EFI stub, or vendor payload is relicensed here.

Original source heads (identifiers are recorded for provenance; no history was
imported):

| Source slice | Original source head |
|---|---|
| ISO/kernel tooling | `c38ba9d323bc8d8ed520ea5aa74b4c57e15d9e37` |
| EFI-stub tooling | `53cc5ffb65bd218985a7871580de978839ae51f9` |
| ADSP test UKI builder | `79ad6c2cc7c73b4f2587d5d08e03571c24dcd7f7` |

Original ISO blobs before the public dependency/path cutover:

| Original file | Source blob |
|---|---|
| `iso-build/00-deps.sh` | `867e6ee982761cae6cf825182524478d68d89b23` |
| `iso-build/01-kernel-fetch.sh` | `2d3a19f2b18732927d218648ac95d90b04ce08b3` |
| `iso-build/02-kernel-build.sh` | `525fc372bc0887ae6a401184231db4fc2c186e9d` |
| `iso-build/03-inspect-iso.sh` | `2d7f72b2865691729875ef111fd898c28682a490` |
| `iso-build/04-remaster.sh` | `f8d935840ba7d9b1c358ed78a661dcf04223b1c9` |
| `iso-build/04b-mkiso.sh` | `24dd6e94a545fa6536841810b0617e81f1837875` |
| `iso-build/05-verify-kernel.sh` | `169320f14efc802880efeab01f775df6bd62cc71` |
| `iso-build/06-verify-iso.sh` | `1af6a3f4bfdbf4b4a5d7aba2dec1c1962a28559d` |

Original EFI sources: `05-fetch-stub.sh` blob
`41cbdc84a5eba08c7bf22b086ceb7462c6199775`; `06-build-uki.sh` blob
`652dcbae3e0502b3cdaec207d7ed0ca9276d6d43`. The ADSP builder was
`scripts/sp11-build-adsp-test-uki.sh`, blob
`3e6d646b9933bfa42c0961997c8b0d3fae50d80e`; the exported copy adds a configurable
ESP and points to the retained public helper rather than a private home path.

Public runtime prerequisite:
[denisix/ubuntu-surface-pro-11 at 049b1caccf15](https://github.com/denisix/ubuntu-surface-pro-11/tree/049b1caccf153ccf7aa5d0f6b824a4dc48e8b02d).
Its installer has broad historical NPU/sensor/network dependencies and is not
included or licensed by this export. The remasterer copies only the listed
runtime inputs; it does not copy private histories or arbitrary checkout data.
Review any third-party firmware/topology redistribution before distributing an
image you generate yourself.

## Deliberately not exported

- Private disk partition/format helpers, account/password bootstrap, FAT serial
  replacement, and personally specific root UUIDs.
- The broad distro installer and duplicate runtime scripts/services/C probes:
  use the cited public upstream for that baseline instead.
- The obsolete kernel-history republishing and private Git/Ghidra bundle tools.
- Compiled daemons, firmware/topology binaries, SDK/model downloads, Windows
  drivers, EFI/ISO images, SquashFS layers, private logs, and assistant memories.
- A frozen claim that old pen/touch or upstream camera gaps remain unsolved:
  this is historical source, not the October 2026 ecosystem status.

## Public source packaging

GitHub's matching `research-handoff-2026-10` tags provide repository source
archives. They are not prebuilt kernel or ISO assets. Use
`tools/make-handoff-tar.sh` for the smaller document/tool handoff, or
`tools/make-audio-handoff.sh` for audio-focused material. Both include these
exports and the licenses from committed Git content, never assistant memories.
If exporting a patch series, explicitly set `WT` to a public kernel clone;
`KERNEL_REF` defaults to `main`, and `BASE` to the preserved public squashed
import `31339fbd93060c569c7ae3b911f87726d3021fc6` (also named `upstream/base`
in the kernel repository). Override `KERNEL_REF` with the handoff tag to freeze
the selected tip rather than following a future `main`.

## Publication verification

Executed on 2026-10-08 under x86_64 Ubuntu 24.04/WSL, using real tools and
disposable file-backed inputs. Fixture kernel/initrd/DTB payloads were structural
test data, not bootable hardware images.

| Exercised path | Observed result |
|---|---|
| Exported/changed Bash scripts | All 14 parsed with `bash -n`. |
| ADSP runner on a live root | Refused before hardware operations: no `/etc/initrd-release`. |
| Ubuntu stub acquisition | Actual 259.5 package downloaded/extracted; AArch64 PE stub recognized `.dtb`. |
| ADSP UKI builder | Build/install/status/rollback on a disposable bind-mounted ESP; total size and non-command-line sections/payloads preserved; blacklist extended and pre-mount break added; original and fallback restored/preserved. |
| EFI variants A/B | Real PE files constructed; A retained DTB, B omitted it, both retained kernel/initrd bytes; default path left the fixture ESP unchanged. |
| Existing kernel fetch path | Real checkout reused without fetch/reset; `make kernelversion` returned `7.1.3`. |
| Public runtime guard | Pinned denisix checkout passed source validation up to the missing-ISO boundary; modified runtime and wrong-origin inputs rejected before mounting. |
| ISO writer | Real xorriso assembled a small file-backed fixture; retained 6 MiB FAT ESP byte-for-byte and emitted El Torito UEFI/GPT metadata. |
| Public handoff packagers | Both included exported tools and BSD license; neither included assistant-memory directories; audio handoff copied no implicit local logs. |
| Optional public kernel patch export | 53 patches applied to the recorded public base reconstructed the complete published `main` tree `7c1ba25b2f68e3ad073923ea839698151bc79ff4`. |

Initial WSL attempts correctly propagated Git ownership and missing-make
failures; prerequisites were then satisfied, without disabling Git's ownership
check globally. No Surface hardware boot, ADSP restart, kernel compilation,
optional EFI variant C/ESP replacement, full ARM64 distro remaster, or first-boot
installer/session integration was qualified by this publication work.

The larger patch bundle exposed an archive-preview SIGPIPE (exit 141) after a
valid archive had already been written. The preview now drains the stream
instead of closing it at line 40. The repaired command passed using an ordinary
public clone, and its 53 patches reproduced the exact published kernel tree.
