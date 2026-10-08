# Session state — 2026-08-04

> **SUPERSEDED — read `root-cause-20260804.md` first.**
>
> The cause was found later the same day: `qcom_q6v5_pas` restarts the ADSP,
> which restarts `charger_pd` — the protection domain owning USB-C power
> delivery — and the Type-C port drops the root disk 89 ms later.
>
> **This file's conclusions about the kernel config are wrong.** In particular
> the claim that the stock config eliminates the I/O errors came from reading a
> journal that ended at `systemd-journal-flush` and calling it clean; that is
> what a dead disk looks like from the inside, not a healthy boot.
>
> Still accurate and worth keeping: the eliminated-hypothesis table, the two real
> defects found on the way (`USB_UAS`, `REGULATOR_FIXED_VOLTAGE`), the device-tree
> work, and the traps at the end.

The machine has **never reached a login prompt on any INTEG kernel**. Stock
Ubuntu `7.0.0-22-qcom-x1e` reaches a desktop on the same disk, same enclosure,
same port. So the hardware is fine and the fault is ours.

Read `session-state-20260803.md` for how the boot chain works; this file is
what is broken and what has been eliminated.

---

## The failure

Boot proceeds into userspace, then the root filesystem — the T7 over USB-C —
goes away:

```
device offline error, dev sda, sector 1548348960 op 0x1:(WRITE)
EXT4-fs error (device sda5): ext4_dirty_inode:5587: IO failure
Aborting journal on device sda5-8
JBD2: I/O error when updating journal superblock for sda5-8
```

Every subsequent unit fails. The screen ends as a wall of red `[FAILED]` lines
and stops. systemd is alive; the kernel is not panicked.

Timing varies between boots (11.8 s, 18.7 s), so it is not a fixed trigger
point.

---

## What is eliminated

| hypothesis | verdict | evidence |
|---|---|---|
| Hardware / cable / enclosure | **no** | stock kernel reaches a desktop on the same setup |
| USB4 driver touching the port | **no** | `modprobe.blacklist=thunderbolt`, no `thunderbolt-platform` lines, disk still drops |
| Our initrd module rebase | **no** | failure predates it, and dracut failing would print |
| Our device tree | **no** | integ11 booted our kernel with every one of our DT commits removed; failed identically, three times |
| The USB link running at 2.0 speed | **no** | the stock kernel enumerates the T7 at `high-speed` too, and reaches a desktop |
| `rtmr0` pinctrl missing `output-enable` | **no** | stock DTB has the identical node; it is upstream-wide, not ours |
| ESP filesystem damage | **no** | `chkdsk` clean; the *contents* of one diagnostic file were garbage, from writing 200 MB into 84 MB free |

---

## The two remaining variables

Stock = 7.0.0-22 + Ubuntu config + stock DTB. Ours = 7.1.3 + defconfig + our DTB.

### 1. Kernel config — the strong suspect

Every INTEG kernel has been built from `make ARCH=arm64 defconfig` plus eight
`scripts/config` flips. **4,777 set symbols against the flavour's 11,655.**

The tree carries `debian.qcom-x1e/config/annotations` — Ubuntu's config for
exactly this hardware, already annotating `CONFIG_VIDEO_IMX681` — and it had
never been used.

**`CONFIG_USB_UAS` is the specific suspect.** `usbipd list` reports the T7 as:

```
3-2  04e8:61fb  USB Attached SCSI (UAS) Mass Storage Device
```

The kernel that boots sets `USB_UAS=m`. Ours does not have it at all, so every
INTEG kernel has driven the root disk through the usb-storage BOT fallback
instead of the UAS driver. That has been true since the first INTEG kernel,
which matches "it has never worked."

`tools/mkconfig.sh` also turns it off explicitly — the overlay line
`n CONFIG_USB_UAS "was off before"`. The flavour build therefore has the same
gap as the defconfig builds; that overlay line is wrong and should go.

Other defconfig gaps found the same way, each of which had been treated as a
separate mystery:

| symbol | consequence |
|---|---|
| `FW_LOADER_COMPRESS` | 29 of 35 firmware files in the initramfs unloadable — the GPU, WiFi and Bluetooth `-2`s |
| `EXFAT_FS` | `/mnt/t7` will not mount (worked on stock, regressed on ours) |
| `SQUASHFS_LZO/XZ/ZSTD` | every snap fails to mount |
| `NLS_UTF8` | exfat with a utf8 iocharset cannot work even once `EXFAT_FS` is on |

`firmware.txt` from the ESP confirms the mechanism — the files were present the
whole time, as `.zst`:

```
PRESENT  qcom/gen70500_sqe.fw.zst            26,070
PRESENT  ath12k/WCN7850/hw2.0/amss.bin.zst   2,882,357
PRESENT  qca/hmtbtfw20.tlv.zst               187,194
PRESENT  ath12k/WCN7850/hw2.0/board.bin      88,760   <- the one we installed by hand
```

`request_firmware()` never failed to *read* them; without
`CONFIG_FW_LOADER_COMPRESS` it never looked under the compressed name, and
returned `-ENOENT`, which reads as "missing".

#### The config of the kernel that boots

Every config in `sp11-stage` was one of ours — all 7.1.3, including the
misleadingly named `config-from-deb`. The real one was never compared against
because it was never in hand.

Ubuntu does not set `CONFIG_IKCONFIG`, so it cannot be extracted from the image.
It is in the live squashfs instead, and needs no booted system, no ext4 mount
and no replug:

```
unsquashfs -f -d out /mnt/d/casper/minimal.squashfs boot/config-7.0.0-22-qcom-x1e
```

Saved as `config-stock-7.0.0-22` — **11,981 symbols against our 4,906.** What it
settles, on the storage and port path:

| symbol | boots | ours | |
|---|---|---|---|
| `USB_UAS` | m | *absent* | the root disk is a UAS device |
| `SCSI_SCAN_ASYNC` | y | *absent* | |
| `USB_STORAGE` | m | y | both present |
| `QCOM_PMIC_GLINK` | y | m | Type-C port manager for the root disk's connector |
| `PHY_QCOM_QMP_COMBO` | y | m | |
| `PHY_QCOM_QMP_USB` / `_PCIE` / `EUSB2_REPEATER` | y | m | |
| `USB_ANNOUNCE_NEW_DEVICES` | y | *absent* | free to turn on, useful in a log |

The `y`-vs-`m` split on the port path looked like a mechanism — a port manager
that probes late could reconfigure the connector under a mounted filesystem, and
the variable failure time (11.8 s, 18.7 s) fits module ordering better than a
fixed hardware event. **It does not hold up:** every one of those modules is
already inside our initrd (`pmic_glink.ko`, `ucsi_glink.ko`,
`phy-qcom-qmp-combo.ko`, `nb7vpq904m.ko`, `qcom_pd_mapper.ko`), so they load
before root is mounted. The difference is real; the mechanism is unproven.

The practical consequence is bigger than any single symbol: the next kernel
should be built from `config-stock-7.0.0-22` run through `olddefconfig`, not
from `defconfig` and not from the annotations. It is the only config on hand
that is known to boot this machine.

### 2. Our DTB additions

`camera@10` + `sony,imx681`, the PM8010 camera PMIC, three `usb4@` routers,
PERST#/WAKE# on `pcie4_port0`. All absent from the stock DTB.

---

## What the machine's own journals say

The journals are readable from Windows with no booted Linux — see
`tools/README-sp11-access.md`. One row per boot:

```
BOOT  KERNEL                          T7 SPEED    DRIVER       REACHED
 -21  7.0.0-22-qcom-x1e               high-speed  uas          DESKTOP   (x11)
 -10  7.1.3-sp11-integ-gf2cc827b6b89  high-speed  usb-storage  never     (x10)
```

Same port, same device, **same link speed**. The one difference in how the root
disk is driven is `scsi host0: uas` against `scsi host0: usb-storage` — which is
`CONFIG_USB_UAS`, absent from every config we have built. The suspect is now
confirmed from the machine rather than inferred from a config diff.

**The journal cannot see the failure itself.** It lives on the disk that dies,
so it stops at the last flush — `02:41:19.476`, mid `systemd-journal-flush`. The
I/O errors exist only on the console.

## integ12: UAS on, and it got worse

`CONFIG_USB_UAS=y`, built at `f2cc827b6` with `LOCALVERSION=-sp11-integ` so the
release string stayed `gf2cc827b6b89` and the installed modules stayed valid;
only `.linux` differed from integ9.

It booted — the hook fired at uptime 4.51 s, so root was mounted — and then left
**no persistent journal at all**. It is now failing before journald flushes,
i.e. earlier than the ~19.5 s of the integ11 boots.

Whether `uas` bound is unknown: keeping the release string identical to integ9
also made the two builds indistinguishable in a log. Good for module
compatibility, useless for diagnosis. Do not repeat that without another marker.

## The next experiment

**`BOOTAA64-integ13-pstore.efi` is installed.** integ12 plus two things that
exist only to make the failure observable:

- **ramoops**, 1 MiB at `0xb0000000`, with `CONFIG_PSTORE_CONSOLE=y`. That
  address is inside the 1.13 GiB hole between `q6-wpss-dtb` (ends `0x91380000`)
  and `xbl-sc` (starts `0xd8000000`), checked against the built DTB as
  overlapping no reserved region. The console log survives the reboot in DRAM;
  the next boot's pre-pivot hook copies it to `ESP:\sp11-diag\pstore\`. On
  branch `debug/ramoops`, marked not-for-submission — it must not reach the PRs.
- **a pre-pivot hook that dumps `dmesg`.** `dmesg` is in the initrd, and at
  pre-pivot the root disk is already mounted, so the ring buffer already names
  the driver that claimed it. It writes `dmesg.txt` and a filtered
  `storage.txt`. The initrd has no `grep`, `head` or `tail`; filtering is
  `sed -n`.

Read after the next boot: `ESP:\sp11-diag\storage.txt` answers uas-vs-usb-storage
on its own, and `pstore/` holds the console of the boot *before* it.

---

The two DTB experiments below are finished; both are recorded for the record.
Both kept our kernel, initrd and cmdline and changed only the device tree.

**`BOOTAA64-integ10-stockdtb.efi`** — Ubuntu's 7.0.0-22 DTB. *Installed.*
Confounded: between 7.0.0 and 7.1.3 the dwc3 nodes were restructured from a
`qcom,dwc3` glue wrapper containing the core to a flat `qcom,snps-dwc3`
controller. Our `dwc3-qcom.c` matches only the new compatible; the old one is
matched by `dwc3-qcom-legacy.c`, which is built by the same
`CONFIG_USB_DWC3_QCOM=y` — so it boots, but USB comes up through a different
driver. A result either way is about USB *and* the DT at once.

**`BOOTAA64-integ11-controldtb.efi`** — our own tree's denali DTB built at the
import commit `31339fbd9`, i.e. every one of our DT commits removed, same kernel
version and therefore the same bindings. Staged, not installed. The node diff is
clean:

```
22 nodes only in ours, 0 nodes only in the control
  camera@10, touchscreen@0, the five ts/hid pinctrl states,
  regulators-8 + ldo1..7, ldo7/ldo16 on regulators-0,
  usb4@1553f000 / @1563f000 / @1573f000, ts-5p0-regulator
```

The dwc3 controllers are identical in shape; the only USB difference is our
three `usb4@` routers.

**Result: integ11 failed identically, three boots.** The device tree is
eliminated, and the four DT fixes are cleared — the PRs stand.

Install and rollback are scripted; see `tools/README-sp11-access.md`. The ESP is
found by partition type on the T7. **The internal NVMe also has a System
partition and must never be written.**

---

## Fixed this session (device tree)

All on topic branches with draft PRs on `lain3d/surface-pro-11-kernel`; all
seven branches build and audit clean standalone, all refs match `publish/`.

| commit | what | PR |
|---|---|---|
| `80b11c712` | camera rails snapped to the RPMh voltage grid | #2, #5, #7 |
| `95357516b` | PERST#/WAKE# on the WCN7850 PCIe port | #6 |
| `029174f90` | GDSCs for the USB4 host routers | #3 |
| `a699f1b2d` | SMMU stream IDs for those routers, from the firmware IORT | #3 |

The voltage-grid fix is on three PRs because topic branches fork from `sp11`
independently and do not inherit each other's fixes. `debug/imx681-addr-scan`
and `debug/cci-bus-scan` both carried the bad rails and would have stalled at
0.196 s — PR #5 exists to run an I²C scan that needs userspace.

**Camera result, from the one boot that got far enough:**

```
imx681 5-0010: DEBUG:   0x10 ACK
imx681 5-0010: DEBUG:   0x1a ACK
imx681 5-0010: DEBUG:   0x50 ACK  (module EEPROM)
```

`0x10` matches the DT and is now confirmed by hardware. `0x50` is the module
EEPROM, proving the bus. `0x1a` is unidentified — PR #7 sweeps all four CCI
buses to place it. The IR sensor is *probably* ruled out: it sits on `cci0`,
which is `status = "disabled"`.

---

## Tooling added

- `tools/dt-audit.py` — device tree vs constraints parsed from the drivers
- `tools/initrd-audit.py` — boot payload vs the kernel that runs it
- `tools/iort-parse.py` — SMMU stream IDs out of ACPI IORT
- `tools/mkconfig.sh` — generate the config from `debian.qcom-x1e` annotations
  plus a seven-symbol overlay, and verify 18 symbols we depend on
- `design/offline-verification-loop.md` — the loop and its failure modes

---

## Artifacts

```
BOOTAA64-integ13-pstore.efi      INSTALLED; uas + ramoops + dmesg-dumping hook
BOOTAA64-integ12-uas.efi         CONFIG_USB_UAS=y; left no journal
BOOTAA64-integ11-controldtb.efi  our DTB minus all our DT commits; failed 3/3
BOOTAA64-integ10-stockdtb.efi    Ubuntu 7.0.0-22 DTB; superseded by integ11
BOOTAA64-integ9.efi              rollback; 7.1.3-sp11-integ-gf2cc827b6b89
BOOTAA64-integ8.efi              rollback
BOOTAA64-stock-KNOWN-GOOD.efi    7.0.0-22-qcom-x1e, reaches a desktop
stock-denali.dtb                 from the above UKI, 213,644 bytes
control-denali.dtb               built at 31339fbd9, 215,031 bytes
config-stock-7.0.0-22            the config that boots, 11,981 symbols
config-uas / config-uas-pstore   integ12's and integ13's configs
integ-denali-ramoops.dtb         our DT plus the ramoops carveout
initrd-slim-pstore.img           repacked with the new hook; 1854 entries, as before
logs/boot<N>.txt                 every boot on the machine, dumped from its journal
config-sp11-flavour              flavour + overlay, 11,633 symbols
Image-flavour / modules-*.tar.gz 7.1.3-sp11-integ-ga699f1b2d9d1, does not boot
logs/integ11.log                 build log for the control DTB
```

Worktree `/root/sp11/wt-dtctl` is detached at `31339fbd9` and builds the control
DTB with `make ARCH=arm64 qcom/x1e80100-microsoft-denali-oled.dtb` — the target
is relative to `arch/$ARCH/boot/dts`, not a full path.

On the root filesystem: module trees for all three kernels, and
`/usr/local/sbin/sp11-late-collect` (its timed unit is disabled; run it by
hand).

---

## Traps that cost time

- **`make` with no stdin hangs forever.** Branch switches change `Kconfig`, so
  `make` fires `conf --syncconfig`, which blocks in `pipe_read` at 0% CPU —
  indistinguishable from a slow build. `build-iso2.sh:58` already carried
  `</dev/null`; that redirect was not decoration.
- **WSL2 destroys its VM after `vmIdleTimeout` (60 s default)** once no
  `wsl.exe` session remains, killing background jobs and clearing `/tmp`. Fixed
  with `vmIdleTimeout=-1` in `.wslconfig` (needs `wsl --shutdown`).
- **The pre-pivot hook cannot see the current boot.** It runs before userspace,
  so it only ever copies the previous boot's journal — and journald had not
  flushed, so every capture stopped at 1.710 s. It was also copying 200 MB onto
  a 488 MB FAT partition every boot, stalling boot by a minute and producing
  files whose contents were other files' data. Now writes small text only.
- **`CONFIG_PSTORE_CONSOLE` is not set** in either config, so ramoops would
  capture a panic but not the console — and this failure is not a panic.
- **`grep -c` prints `0` *and* exits 1.** So `n=$(grep -c x f || echo 0)` yields
  the two-line string `0\n0`, and every numeric test on it errors out. This bug
  was written three separate times today.
- **Scope a grep to the files that matter.** Checking "our DT work is absent"
  across all of `arch/arm64/boot/dts/qcom/` counts other boards' `pm8010` and
  `touchscreen@0` and reports hits on a tree that has none of ours. The
  authority is the built DTB, not the sources.
- **`unsquashfs -e` takes a file containing a list**, not a path. Paths go as
  trailing arguments, relative to the image root with no `squashfs-root/`.
- **Checks that cannot fail.** `MZ` + `ARM\x64` magic are present in any arm64
  `Image` whether or not it has a working EFI stub. Verifying a branch with
  `make dtbs` in a worktree that has no `.config` always reports failure.
  Comparing a config value against an empty grep result reports failure for
  every disabled symbol. Each read as information and was not.
