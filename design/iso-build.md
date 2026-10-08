# Reproducing the ISO build

> Historical incremental-build notes. The formerly missing original ISO
> assembly tools are now exported in
> [handoff/distro-tools/iso-build](../handoff/distro-tools/iso-build/README.md).
> They require a lawful base image and an explicit public runtime checkout;
> no historical root filesystem, firmware, ISO or EFI binary is distributed.

How `surface-pro-11-ubuntu-INTEG-*.iso` is produced, what it is made of, and how
to tell whether the result is sound.

The executable version of this is `build-iso2.sh` in the repo root. This document
explains what each step is for, because a build script that nobody understands is
not reproducible — it is just repeatable.

---

## Scope, honestly

This reproduces an **incremental rebuild**: new kernel → into the existing live
filesystem → repack. It does **not** build the image from zero.

The from-zero path is only partly known. `/root/sp11/layer` already contains a
working Surface Pro 11 rootfs — stock Ubuntu plus the prior-art enablement plus
the first custom kernel — and the script that originally assembled it was not
kept. So:

| | Reproducible today |
|---|---|
| Rebuild the ISO with a new kernel | **Yes** — `build-iso2.sh` |
| Rebuild `layer/` from a stock Ubuntu ISO | **No** — that step was ad hoc and is not recorded |

Worth fixing eventually. Not blocking, since `layer/` is on disk and can be
re-derived by unsquashing `casper/minimal.squashfs` from `base.iso`.

---

## Inputs

| Path | What it is |
|---|---|
| `/root/sp11/base.iso` | **Ubuntu 26.04 arm64**, daily image, created 2026-03-26. The upstream starting point. |
| `/root/sp11/iso-tree/` | The ISO contents, unpacked. This is what gets repacked. |
| `/root/sp11/layer/` | The live root filesystem, unpacked (6.8 GB). Becomes `casper/minimal.squashfs`. |
| `/root/sp11/efi.img` | The 6 MiB EFI system partition image, appended as partition 2. |
| `/root/sp11/wt-ov13858` | Kernel worktree; the feature branches live here. |

Host used: 12 cores, 29 GB RAM, ~815 GB free. The build needs roughly 30 GB of
working space and writes a 4.4 GB image.

---

## Rules

1. **Never write to the baseline.** `/home/lain/sp11-out/baseline/` holds the
   pre-change ISO and its kernel packages, mode `444` with the immutable bit set.
   It is the control that distinguishes "the new patches broke it" from "it never
   worked here."
2. **Every build gets a new filename.** No rebuilding over
   `surface-pro-11-ubuntu.iso`.
3. **Verify the artifact, not the script.** Steps 8 and 9 below exist for this.

---

## Procedure

### 1. Compose the branches

```bash
cd /root/sp11/wt-ov13858
git checkout -b integration/iso2 debug/imx681-addr-scan
git merge camera/ov13858-dt
git merge usb4/platform-nhi
```

`debug/imx681-addr-scan` already carries `camera/imx681` and
`camera/denali-pm8010`. The only overlapping file across all of them is
`x1-microsoft-denali.dtsi`, and it auto-merges.

Including the debug branch is deliberate: the whole point of this image is to run
the phase-2 measurements, and the I2C address scan is one of them. It also means
this ISO carries a sensor node with a placeholder `reg` — fine here, never in the
PR series.

### 2. Configure, and check that it took

```bash
./scripts/config --file .config \
    -m CONFIG_USB4 -e CONFIG_USB4_DEBUGFS_WRITE -e CONFIG_HOTPLUG_PCI_PCIE \
    -m CONFIG_VIDEO_OV13858 -m CONFIG_VIDEO_IMX681 \
    -m CONFIG_CLK_X1E80100_CAMCC -m CONFIG_VIDEO_QCOM_CAMSS -m CONFIG_I2C_QCOM_CCI
make olddefconfig </dev/null
grep -x 'CONFIG_USB4=m' .config          # ... and each of the others
```

**The grep is not optional.** `scripts/config` will happily set a symbol that
does not exist, and `olddefconfig` will silently drop a symbol whose dependencies
are unmet. Both failures are invisible unless you read `.config` back. This is
the same trap that once produced a meaningless `W=1` run, and it is why the
script fails hard if any symbol is missing afterwards.

`CONFIG_HOTPLUG_PCI_PCIE` is the one that matters most and is easiest to miss: a
device arriving over a PCIe tunnel enumerates through PCIe **native** hotplug.
Without it the tunnel can come up and the device still never appear. The tree's
annotations already ask for `y`; the first ISO was simply built from a `.config`
that diverged from them.

### 3. Build the kernel packages

```bash
make -j$(nproc) bindeb-pkg LOCALVERSION=-sp11-integ KDEB_PKGVERSION=1
```

Produces `linux-image-*-sp11-integ*_arm64.deb` alongside headers and a dbg
package. `LOCALVERSION` is what keeps this kernel's version distinct from the
baseline's, so both can coexist in the layer.

This is the long step.

### 4. Install into the live filesystem

```bash
for m in proc sys dev dev/pts; do mount --bind /$m /root/sp11/layer/$m; done
cp linux-image-*.deb /root/sp11/layer/tmp/
chroot /root/sp11/layer dpkg -i /tmp/linux-image-*.deb
chroot /root/sp11/layer update-initramfs -c -k "$KVER"
for m in dev/pts dev sys proc; do umount /root/sp11/layer/$m; done
```

The bind mounts are required — `update-initramfs` needs `/proc` and `/sys`. The
chroot works natively because the host is aarch64; no qemu-user needed.

The old kernel is left installed on purpose. It costs a few hundred MB and gives
a fallback entry if the new one misbehaves.

### 5. Stage kernel, initrd and DTB

```bash
chmod -R u+w /root/sp11/iso-tree
cp layer/boot/vmlinuz-$KVER    iso-tree/casper/vmlinuz
cp layer/boot/initrd.img-$KVER iso-tree/casper/initrd
cp layer/usr/lib/linux-image-$KVER/qcom/x1e80100-microsoft-denali-oled.dtb \
   iso-tree/dtb/qcom/
```

GRUB loads the DTB by path, which is why DT iteration later needs only a file
copy and a reboot — no kernel rebuild.

### 6. Add `boot=casper`

The first image's `grub.cfg` had no `boot=casper` on the kernel command line. On
Ubuntu live images that is normally what tells the initramfs to find and mount
the squashfs. Its absence may be harmless — newer casper can autodetect — but if
it is not, the boot lands at an `(initramfs)` prompt.

Adding it is harmless when redundant, so the script adds it.

### 7. Rebuild the squashfs

```bash
COMP=$(unsquashfs -s iso-tree/casper/minimal.squashfs | awk '/Compression/{print $2}')
mksquashfs /root/sp11/layer minimal.new.squashfs -comp "$COMP" -noappend
mv minimal.new.squashfs iso-tree/casper/minimal.squashfs
du -sx --block-size=1 /root/sp11/layer > iso-tree/casper/minimal.size
```

The compression is read off the existing image rather than assumed — casper reads
`minimal.size` to size the overlay, so it has to be refreshed too.

### 8. Pack the ISO

```bash
xorriso -as mkisofs -r -V "SP11_INTEG_$STAMP" \
    -o /home/lain/sp11-out/surface-pro-11-ubuntu-INTEG-$STAMP.iso \
    -partition_offset 0 \
    -append_partition 2 0xef /root/sp11/efi.img \
    -appended_part_as_gpt \
    --mbr-force-bootable \
    -e '--interval:appended_partition_2:all::' -no-emul-boot \
    /root/sp11/iso-tree
```

This is EFI-only, as arm64 requires: no El Torito BIOS image, an appended EFI
system partition, protective MBR plus GPT.

**Both trailing flags are load-bearing, and both were found by step 9 rather than
by reasoning.**

`-appended_part_as_gpt`: the first attempt omitted it and used
`-iso_mbr_part_type 0x00`, producing a plain MBR with **no GPT at all** —
partition 1 typed `0x00` instead of a `0xee` protective entry. `xorriso` exited 0
and wrote 4.5 GB of plausible output.

`--mbr-force-bootable`: this is what writes the `0x80 0x00 / 0 / 1` MBR entry —
a one-block partition carrying the bootable flag. It was missing from the second
attempt too, and only showed up when the comparison was widened from `base.iso`
to **the previously built Surface ISO as well**. Both known-good images have it;
mine did not.

That widening is the lesson. The right reference is not just upstream — it is
every image known to work.

### 9. Verify the boot structure against the original

```bash
xorriso -indev "$NEW_ISO"           -report_el_torito plain
xorriso -indev /root/sp11/base.iso  -report_el_torito plain
```

`base.iso` boots, so its El Torito and partition layout is the reference. The new
image should report a UEFI boot image of the same size (3072 blocks = 6 MiB, the
`efi.img`) and the same MBR/GPT arrangement. **A structural mismatch here is the
one failure that would otherwise only surface as an unbootable USB stick.**

Then checksum it and confirm the baseline is still intact:

```bash
sha256sum "$NEW_ISO" | tee "$NEW_ISO.sha256"
sha256sum -c /home/lain/sp11-out/baseline/SHA256SUMS
```

---

## Running it

```bash
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu-22.04 -u root \
    bash /mnt/c/Users/Crazy/projs/arm64-egpu/build-iso2.sh
```

Two invocation notes, both learned the hard way:

- **`MSYS_NO_PATHCONV=1` is required from Git Bash**, which otherwise rewrites
  `/mnt/c/...` into `C:/Program Files/Git/mnt/c/...`.
- **Do not background it with `nohup ... &` inside `wsl.exe`.** WSL reaps the
  session's processes when the invocation returns and the build dies silently
  with no log. Run it in the foreground of a long-lived process instead.

Progress goes to `/root/sp11/build-iso2.log`.

---

## What the output is for

The resulting image can answer all four phase-2 measurements, unlike the
baseline, which can only answer multi-touch:

| | baseline | INTEG |
|---|---|---|
| Boots, pen/touch | yes | yes |
| Heat-map feature reports | yes | yes |
| `thunderbolt` binds a router | no | **yes** |
| PCIe tunnel enumerates | no | **yes** (with `HOTPLUG_PCI_PCIE`) |
| Camera I2C address scan | no | **yes** (debug branch) |

Boot order is still the one in `design/first-boot-runbook.md`: **BitLocker step 0
first**, then the baseline, then this.
