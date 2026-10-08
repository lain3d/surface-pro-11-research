# Historical systemd-stub / UKI construction

Original source: `boot/efistub` at
`53cc5ffb65bd218985a7871580de978839ae51f9`, authored by lain3d. Own shell glue
is covered by the repository MIT license; Ubuntu's downloaded package/stub
keeps its own licensing. No EFI binary, kernel, initrd or DTB is distributed.

This preserves the August 2026 comparison of an installed kernel with an
explicit OLED DTB, the same kernel without a DTB section, and an optional old
`*-integ-*` kernel. It is not a generic installer, a current hardware support
claim, or a Secure Boot signing workflow.

## Acquire a DTB-capable AArch64 stub

`05-fetch-stub.sh` downloads the historical Ubuntu
`systemd-boot-efi_259.5-0ubuntu3_arm64.deb` over HTTPS and extracts
`linuxaa64.efi.stub`. The public package was reachable when this export was
prepared; availability may change. `W`, `OUT`, `MIRROR` and `FN` are configurable.
It needs curl, dpkg-deb, strings and GNU utilities. Downloaded files remain
outside this repository by default.

```bash
W=/tmp/sp11-stub OUT=/tmp/sp11-stub/linuxaa64.efi.stub bash 05-fetch-stub.sh
```

The original finding was that systemd-stub 249 ignored embedded `.dtb`; the
259.5 stub recognized it. Inspect a different stub rather than assuming that
any successfully constructed PE image will honor a DTB.

## Construct the historical variants

`06-build-uki.sh` now requires explicit target identifiers and paths. It mounts
the selected root, bind-mounts host filesystems, reads its installed kernel,
initrd and DTB, and emits `A-stock-dtb.efi` / `B-stock-nodtb.efi` under `WORK`.
Optional `INTEG_DEB` installs that package into the target root and enables the
old `*-integ-*` variant; omit it to avoid that mutation. Optional `INTEG_DTB`
selects that variant's DTB. This naming/layout reflects the old experiment.

```bash
sudo DISK=/dev/<reviewed-target-disk> \
  ROOT_PART=/dev/<reviewed-root-partition> \
  ESP=/dev/<reviewed-ESP-partition> \
  MNT=/path/to/target-root-mountpoint \
  ROOT_UUID=<target-root-filesystem-UUID> \
  STOCK_KVER=<installed-kernel-version> \
  STUB=/tmp/sp11-stub/linuxaa64.efi.stub \
  WORK=/path/to/disposable-UKI-output \
  bash 06-build-uki.sh
```

Run on a Linux host with root access, mount/chroot tools, GNU awk, and
objcopy/objdump supporting AArch64 PE. `STOCK_KVER` means the kernel already
installed on the selected root; the label is historical, not a required distro
version. The script expects its DTB under
`usr/lib/firmware/<version>/device-tree/qcom/`; adapt the source deliberately
for a different packaging layout. A `.deb`/DTB/initrd is not fetched or faked.
The constructed command line is preserved from the original experiment and
must be reviewed for your target.

**By default the ESP is not changed.** The original installation block is
retained only behind explicit `INSTALL_ESP=yes`: it deletes the target ESP's
`EFI` directory and replaces it with the experiment's files using mtools.
Never opt in on a Windows/system/recovery ESP or a disk you have not backed up.
The builder does not identify the correct disk or provide a partition-format
workflow. Destructive disk/account/UUID bootstrap scripts were not exported.

The original motivation and prior-art attribution were documented in
[dwhinham's GRUB failure discussion](https://github.com/dwhinham/archiso-aarch64-sp11/issues/25).
That old report is provenance, not a claim that current GRUB fails on every
SP11. WSL filesystem/module capabilities also change; the old preference for
mtools is not a statement about every current WSL kernel.
