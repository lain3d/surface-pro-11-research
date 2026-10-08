# The GRUB boot failure — what it is, and what it is not

Status as of 2026-08-03. GRUB reaches its menu on roughly one attempt in ten.
The rest of the time it draws part of one line and either sits there or
watchdog-resets back to Windows.

This file records what has been **eliminated**, so nobody re-runs these checks.

---

## It is not our image

The identical failure occurs with stock Ubuntu, written by two different methods,
on two different media:

| media | write method | image | result |
|---|---|---|---|
| PNY stick via USB-C hub | raw ISO | custom INTEG | menu once, kernel once, then black screen |
| T7 over Thunderbolt | files onto FAT32 | custom INTEG | half-line freeze |
| T7 over Thunderbolt | files onto FAT32 | **stock** | half-line + green dots |
| PNY stick via USB-C hub | raw ISO | **stock** | same |

Since stock fails the same way, nothing we build is implicated.

## It is not the June 2026 UEFI update

Tempting, because the timeline is tight:

| time (2026-08-03) | event |
|---|---|
| 7/20 → 00:39 | **no reboots at all** — machine up ~2 weeks |
| **00:39:35** | Surface UEFI 175.222.235 installs |
| 00:40:49 → 00:44:01 | first reboot, **3m12s** — a capsule flash, not a restart |
| 00:44 → 02:54 | ~18 reboots, 2× Event 41 unclean, 1× Event 6008 |

Every Linux boot ever attempted on this machine happened **after** that flash,
so there is no pre-update control. The firmware's headline fix is
**CVE-2026-21380, a Qualcomm flaw that "may lead to memory corruption"** — i.e.
tightened memory attributes, exactly the area suspected below.

**But it is still not the cause.**
[dwhinham/linux-surface-pro-11#25](https://github.com/dwhinham/linux-surface-pro-11/issues/25)
describes the same symptom — GRUB menu appears, unresponsive within 5–10 s,
watchdog reset, boot loop — and was filed **16 March 2026**, two and a half
months before this firmware shipped. The bug predates the update.

Rollback is impossible anyway; Surface UEFI capsules do not downgrade.

## It is not Secure Boot or a revoked binary

Secure Boot is **off**. No signature check happens, so a dbx revocation of an
old shim/GRUB cannot be the mechanism. Checked with `Confirm-SecureBootUEFI`.

## It is not a stale firmware version

Running 175.**222**.235 (June 2026), *newer* than the 175.182.235 in
[issue #26](https://github.com/dwhinham/linux-surface-pro-11/issues/26), so we
are not on the build with the known display bug.

## What remains

Issue #25's reporter suspects a conflict between the **Surface UEFI memory map
(NX/no-execute) and the GRUB2 build**. Two things support it: the independent
report, and a firmware security fix aimed at exactly that subsystem. It
implicates the GRUB *binary*, not its configuration — so no amount of grub.cfg
editing will help.

The intermittency (≈1 in 10, not deterministic) points at a race rather than a
straight code defect.

### The response

Stop debugging GRUB; remove it. See `boot-efistub/` in the distro repo. The
kernel is packaged as a UKI and loaded directly by the firmware. If it still
fails identically, the problem is below GRUB and we stop spending nights there.

---

## Related: the black screen after the kernel loads

A separate symptom — kernel boots, `hid … exiting now`, screen black, keyboard
still lit — matches
[issue #26](https://github.com/dwhinham/linux-surface-pro-11/issues/26),
**closed as fixed**. Cause: BIOS 175.182.235 / Windows build 26200 relocated the
Qualcomm firmware in the driver store, so an extraction script silently missed
4 of 5 files including the GPU firmware:

- CDSP: `qcsubsys_ext_cdsp8380.inf_arm64_…` → `qcnspmcdm_ext_cdsp8380.inf_arm64_…`
- GPU: System32 → `qcdx8380.inf_arm64_…\qcdxkmsuc8380.mbn`

This machine runs Windows 10.0.26200. **Our build extracts no Windows firmware
at all** (verified by grep over the repo). Without `qcdxkmsuc8380.mbn` the
Adreno zap shader never loads and the display pipeline dies right where ours
did. Open work item.

Mitigated for now by `earlycon=efifb keep_bootcon`, which writes to the UEFI
framebuffer before any DRM driver loads and so survives a failed panel probe.

---

## Related: why the Ubuntu installer aborted

The installer was run during a rare successful GRUB pass and died copying to
`/boot`. Cause found from Windows afterwards: partition 4 was typed
`{0fc63daf-…}` **Linux filesystem**, not EFI System Partition, so there was
nothing to mount at `/boot/efi`.

Everything else had already succeeded — a complete 14 GB Ubuntu 26.04 root on
partition 5, `/boot` populated, fstab written, swap created, `grub.cfg`
generated. Only the user account was missing, since that step runs later.

**Careful:** partitions 2 and 4 both carried FAT volume id `96C9-AB20`, because
curtin had targeted the existing 8 GB live ESP (`/dev/sda2` in its fstab
comment), not a new partition. Cloning that id onto partition 4 made
`/dev/disk/by-uuid/96C9-AB20` ambiguous. Fixed with `mlabel -N`.

---

## Prior art, checked 2026-08-03

Three independent SP11 projects, none of which have the three pillars working:

| project | kernel | camera | USB4 | multi-touch |
|---|---|---|---|---|
| [denisix](https://github.com/denisix/ubuntu-surface-pro-11) | 7.1.3-jg — **same base as ours** | ❌ | ❌ | ❌ (single-touch only) |
| [dwhinham](https://github.com/dwhinham/linux-surface-pro-11) | mainline 6.17 | ❌ "no status LEDs either" | ❌ | ❌ |
| ours | 7.1.3-jg / INTEG | in progress | in progress | analysed |

A recent release date is not a newer kernel: denisix builds Jens Glathe's
`jg/ubuntu-qcom-x1e-7.1.3-jg-1`, the same tree we use, and ships no ISO — it is
a post-install patch set applied on top of the official concept ISO.

The "working camera on 7.2-rc5-jg" report on the Ubuntu discourse thread is a
**ThinkPad T14s Gen 6**, sensor **ov02c10 on CSIPHY4**, landed upstream as
`arm64: dts: qcom: x1e80100-t14s: Add ov02c10 RGB sensor on CSIPHY4`. Different
board, different sensor, no overlap with IMX681/OV13858/VD55G0 on denali. It
does prove the camss → CSIPHY → CCI path works on x1e80100 silicon, and gives a
reference DT to diff against — worth a rebase onto 7.2-rc5-jg, but it does not
duplicate the work here.

The reported "pink cast" is the signature of raw Bayer data with no AWB and no
colour correction matrix, **not** a wrong CFA order — a wrong CFA order swaps
red and blue or produces a checkerboard. Do not read it as the Bayer question
being settled elsewhere.
