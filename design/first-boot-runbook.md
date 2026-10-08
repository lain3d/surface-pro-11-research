# First-boot runbook

How to actually get from here to booting, in order, with the BitLocker problem
handled first because it is the only step that can cost you data.

Facts below were checked on this machine and this ISO on 2026-08-02, not assumed.
Where something is unverified it says so.

---

## Step 0 — BitLocker, before anything else

### What is actually true right now

```
Secure Boot .............. Enabled
BitLocker C: ............. FullyEncrypted, ProtectionStatus On
  key protectors ......... RecoveryPassword, Tpm
TPM ...................... present, ready, enabled
```

The protector set is **TPM-only** — no PIN. That means the disk key is released
automatically based on the firmware's measurements, and with Secure Boot on,
Windows binds that to **PCR7**, which measures Secure Boot state.

### Why this matters here

The custom kernel is **unsigned**. The ISO's boot chain is Microsoft-signed shim
→ Canonical-signed GRUB, and that GRUB enforces `shim_lock`. So a locally built
kernel will be **refused while Secure Boot is on**.

Which leaves two ways forward, and the obvious one is the dangerous one:

> **Turning Secure Boot off changes PCR7. BitLocker will then demand the recovery
> password the next time Windows boots.**

You have a `RecoveryPassword` protector, so this is recoverable — *if you have
the password*. If you do not, turning off Secure Boot locks you out of Windows.

### Do these three things first

**1. Get the recovery password off this machine.**

```powershell
# Run as Administrator
manage-bde -protectors -get C:
```

Also check it is escrowed to your Microsoft account:
<https://account.microsoft.com/devices/recoverykey>

Store it somewhere **not on the encrypted disk** — a phone photo, another
machine, paper. I deliberately have not printed it into this session's
transcript; it is a credential and it should not live in a chat log.

**2. Verify it is the right key** by matching the Key ID shown by `manage-bde`
against the one listed in your Microsoft account. A recovery password for a
different volume is worthless at 3am.

**3. Suspend BitLocker before touching firmware settings.**

```powershell
# Run as Administrator
Suspend-BitLocker -MountPoint "C:" -RebootCount 2
```

This is the actual safety mechanism, not just insurance. Suspending tells
BitLocker to stop requiring the TPM measurement for the next two boots, and on
resume it **re-seals the key to whatever the new PCR values are**. So the
sequence is: suspend → change Secure Boot → boot Windows once → resume.

```powershell
Resume-BitLocker -MountPoint "C:"      # when you are done, or after the change settles
```

### Secure Boot: two routes

**Route A — turn Secure Boot off (simple, needs step 0 done properly).**
On Surface: power off, hold **Volume-Up** while pressing power, release at the
logo → UEFI → Security → Secure Boot → disable. Reverse it when finished.

**Route B — keep Secure Boot on and sign your own kernel (no PCR7 change).**
Generate a key, sign the kernel with `sbsign`, enroll the public key through
**MokManager** — `mmaa64.efi` is already on the ISO. Modern shim measures the MOK
list into **PCR14** specifically so that enrolling a key does not disturb PCR7,
which is what makes this route BitLocker-safe in principle.

I have **not verified** that this build of shim (15.8) behaves that way on this
firmware. Treat Route B as probably-safe rather than known-safe, and do step 0
regardless.

**Recommendation:** Route A. It is fewer moving parts, and once step 0 is done
properly the downside is "type in a recovery key once", not data loss. Take Route
B only if you dislike leaving Secure Boot off.

---

## Can the ISO be booted live?

**Yes.** The GRUB menu is:

```
menuentry "Try or Install Ubuntu"      <- live session with a Try/Install chooser
menuentry "Boot from next volume"
menuentry "UEFI Firmware Settings"
```

It is a standard Ubuntu live+installer image (`casper/` with squashfs layers). It
lands you in a desktop and **will not install anything unless you choose to.**
The live user is `ubuntu` with passwordless `sudo`.

### One thing to watch on the first boot

The kernel command line in `grub.cfg` is:

```
linux /casper/vmlinuz clk_ignore_unused pd_ignore_unused arm64.nopauth --- quiet splash console=tty0
```

**There is no `boot=casper`.** On Ubuntu live images that parameter is normally
what tells the initramfs to find and mount the live filesystem. Its absence may
be fine — newer casper can autodetect — but if the boot drops to an
`(initramfs)` prompt, that is the reason.

Fix without rebuilding anything: at the GRUB menu press **`e`**, add `boot=casper`
to the `linux` line, press **Ctrl-X**. If that works, note it — the ISO build
script needs the same fix.

The same trick edits the `devicetree` line, which is how you switch DTBs later
without rebuilding a kernel.

---

## What can you answer from a live USB?

Two things get confused here, so separate them:

1. **Which image** — baseline or INTEG. This is what decides what you can measure.
2. **Live vs installed** — this decides nothing about capability. It is only about
   how painful it is to iterate.

### Live is enough. Installed is only about iteration.

**Every measurement in phase 2 works from a live session.** Nothing requires an
installed system. The live user has passwordless `sudo`, `/dev/hidraw*`,
`/sys/bus/thunderbolt`, `i2c` and `dmesg` all behave normally.

The reason to install to an external USB SSD is that **changing something and
retrying is cheap on an install and expensive on a live image**: `dpkg -i` a new
kernel and reboot, versus rebuilding and rewriting a 4.5 GB ISO. If you expect one
pass through the measurements, boot live and skip the install entirely.

### Which image answers what

| Goal | baseline | INTEG |
|---|---|---|
| Boots; pen/touch/wifi/audio | yes | yes |
| Multi-touch heat map | **yes, fully** | yes |
| USB4 host router binds | no — `CONFIG_USB4` unset, no `usb4@` nodes in the DTB | **yes** |
| PCIe tunnel enumerates | no | **yes** (`HOTPLUG_PCI_PCIE` is `=y` — see Phase 1) |
| Camera I2C address | no — no sensor drivers, CCI nodes disabled | **yes**, via the debug scan |

`surface-pro-11-ubuntu-BASELINE-20260802-gd81a425b872a.iso` was built at 00:47,
**before any feature branch existed**. It is the control, not a test target.

`surface-pro-11-ubuntu-INTEG-20260802.iso` carries kernel
`7.1.3-sp11-integ-gf2cc827b6b89` with all four branches plus
`debug/imx681-addr-scan`, and answers all five rows.

**One correction to an earlier version of this table:** it said the baseline had
"no camcc". That was the invented-symbol error — `CONFIG_CLK_X1E80100_CAMCC` is
already `=m` in the baseline and always was. What the baseline genuinely lacks is
the two sensor drivers and the DT enables.

So the reason to boot the baseline first is **not** that it can do more than you
think. It is that it is the known-quantity control: if INTEG misbehaves, the
baseline is what tells you whether the machine or the new patches are at fault.
If you would rather go straight at USB4 and the camera, boot INTEG — just keep
the baseline stick around.

---

## Phase 0 — boot the baseline, answer multi-touch

Do this before building anything. If the image does not boot, you want to find
that out while only one variable is in play.

Write the **preserved baseline** to a USB stick:

```
/home/lain/sp11-out/baseline/surface-pro-11-ubuntu-BASELINE-20260802-gd81a425b872a.iso
```

(sha256 `0b1e0d23…a42788`, verified, immutable. Do not use the working copy in
`sp11-out/` — keep that one pristine too.)

Once in the live session:

```bash
# 1. General state, keep all of it
sudo dmesg > /media/dmesg.txt
lsmod > /media/lsmod.txt; lspci -nn > /media/lspci.txt

# 2. Find the heat-map digitizer: usage page 0x000D, usage 0x0F
for d in /sys/class/hidraw/hidraw*; do
    echo "== $d"; cat $d/device/uevent
    xxd $d/device/report_descriptor | head -5
done
```

Then, on the hidraw node for that collection:

```bash
# read feature 0x05 -- the mode switch. Expect 01 if enabled, 00 if reset to
# multi-touch reporting
sudo ./hidfeature get <dev> 0x05 120

# read feature 0x06 -- must match the bytes recorded in docs/multitouch-heatmap.md,
# starting 77 00 00 00 00 00 00 70 ... with 46 and 68 at payload offsets 14 and 18
sudo ./hidfeature get <dev> 0x06 120

# if 0x05 read back 00, enable heat-map mode
sudo ./hidfeature set <dev> 0x05 01

# then confirm 7488-byte input reports arrive
sudo cat <dev> | xxd | head
```

**Checking `0x06` first is the cheap step that makes everything else
trustworthy**, because the expected bytes are already written down. If they
match, the whole feature-report analysis is confirmed on hardware. If they do
not, stop and re-derive before writing to `0x05`.

(`hidfeature` is a stand-in for a ~30-line `HIDIOCGFEATURE`/`HIDIOCSFEATURE`
helper; `hid-tools` from PyPI also does this. Not yet written.)

---

## Phase 1 — build the kernel that can answer the rest

The four branches merge cleanly onto a base whose tree is byte-identical to the
one this ISO's kernel was built from — verified, not assumed.

```
CONFIG_USB4=m
CONFIG_USB4_DEBUGFS_WRITE=y
CONFIG_HOTPLUG_PCI_PCIE=y      # RESOLVED 2026-08-06 -- already =y, see below
CONFIG_VIDEO_OV13858=m
CONFIG_VIDEO_IMX681=m
```

**RESOLVED 2026-08-06 — `CONFIG_HOTPLUG_PCI_PCIE` is already `=y`.** This
section used to say it was unset, and that was true of the *integ* config the
original ISO was built from. The kernel actually running now is the **stockcfg**
one, and `data/integ33/config:2155` has `CONFIG_HOTPLUG_PCI_PCIE=y`, with
`PCIEPORTBUS=y`, `PCIE_DPC=y`, `PCI_PASID=y`, `ARM_SMMU_V3=y` and
`IOMMU_DEFAULT_DMA_STRICT=y` alongside it. No rebuild is needed for tunnel
hotplug.

Why it mattered: a device arriving over a PCIe tunnel shows up through PCIe
**native hotplug**, so without this the tunnel could come up and the device
still never enumerate — a failure that reads as "USB4 doesn't work" when the
transport was fine. `CONFIG_HOTPLUG_PCI=y` alone is not enough.

The one option still absent is `CONFIG_USB4_DEBUGFS_WRITE` (and
`CONFIG_USB4_DMA_TEST`). Neither is needed to bring a router up; they only buy
register-level debugging, and they are the only reason a rebuild would be
required for USB4 work at all.

### Correction: the camera clock controller symbol

Earlier drafts of this document listed `CONFIG_QCOM_CAMCC_X1E80100`. **No such
symbol exists** — I invented the name, then read "absent from config" as a
finding and reported the camera clock controller as missing.

The real symbol is **`CONFIG_CLK_X1E80100_CAMCC`**, it is annotated `y`, and it
is **already built as a module in the shipped kernel**. So it needs no action,
and the camera gap is smaller than stated: only the two sensor drivers and the
DT enables are actually missing.

DT: enable `camcc`, `cci1`, `csiphy*`, `camss`; all three `usb4_*` are already
enabled by `5f180ef47`.

### Do not iterate on a live ISO

Rebuilding a 4.4 GB image for every kernel change is the wrong loop. **Install to
an external USB SSD** and iterate there:

- kernel change → `dpkg -i linux-image-*.deb` → reboot
- DT change → copy the `.dtb`, edit the GRUB `devicetree` line, reboot
- **no ISO rebuild at any point**

An external disk also sidesteps the other risk entirely: no repartitioning of the
internal drive, so nothing touches the Windows install.

---

## Phase 2 — the four measurements

In priority order. Each retires one stated unknown.

**1. USB4 binds**
```bash
dmesg | grep -i thunderbolt
ls /sys/bus/thunderbolt/devices
```
If this fails it is my code, and the pdev audit missed something.

**2. USB4 tunnels** — plug a dock, then an eGPU.
```bash
boltctl list; lspci
```
If step 1 worked and this does not: **the router-to-port mapping is the first
suspect, not UCSI.** Three routers, three ACPI connectors, two physical ports —
work out which router is which port before concluding anything.

**3. Camera I2C address** — boot the `debug/imx681-addr-scan` branch (PR #5).
```bash
dmesg | grep 'DEBUG:'
```
Expect two responders: `0x50` (the module EEPROM, confirming the bus is right)
and the sensor. **Probe is expected to fail afterwards** — no port/endpoint,
camss unwired. That is designed behaviour, not a bug.

A plain `i2cdetect` will **not** work: nothing powers the sensor until a driver
binds, so the bus reads empty and looks like the wrong bus.

**4. First frame** — put the real address in a DT node, rebuild the DTB, reboot,
build the pipeline with `media-ctl`, capture with `v4l2-ctl --stream-mmap`. The
frame settles the Bayer order, the last unproven constant in `imx681.c`.

---

---

## The NVIDIA driver question

**Can the 616.00 driver be used on Linux? No.** GeForce 616.00 is a *Windows*
ARM64 driver. Windows kernel drivers do not run on Linux — different kernel,
different driver model, no shim. There is no path from that file to a working
Linux GPU.

**But there is a Linux equivalent, and it is not obviously blocked.** NVIDIA ships
[Linux-aarch64 (ARM64) Display Driver](https://www.nvidia.com/en-us/drivers/details/254667/)
`.run` packages — 580.95.05 as of Sept 2025 — and people do run discrete GeForce
cards on ARM64 Linux; Ampere maintain
[a repo specifically for GPU-accelerated Linux desktop on Altra](https://github.com/AmpereComputing/NVIDIA-GPU-Accelerated-Linux-Desktop-on-Ampere).

Honest caveats, in order of how much they worry me:

- **NVIDIA's supported-host list has historically been specific** — Tegra,
  X-Gene, ThunderX, and in practice Ampere. Snapdragon X Elite appears on no such
  list. "Not listed" is not "will not work", but nobody has validated it.
- **Page size**: NVIDIA's driver
  [supports 4K/64K but not 16K pages](https://github.com/NVIDIA/open-gpu-kernel-modules/discussions/725).
  Checked — this kernel is `CONFIG_ARM64_4K_PAGES=y`, so **this one is fine.**
- Open alternatives exist if the proprietary driver refuses: `nouveau` is already
  `=m` here, plus NVK for Vulkan and the newer `nova-core` work.

### The verdict that needs revisiting

The stored conclusion was *"Windows + NVIDIA 616.00 works; Linux impossible for
lack of USB4."* **The second half of that predates PR #3.** It was written when
USB4-on-Linux for this machine was believed unbuildable, which this session
overturned.

So eGPU-on-Linux is no longer blocked on a missing transport. It is gated on the
same measurement as everything else in phase 2 — *does PCIe actually tunnel* —
plus `CONFIG_HOTPLUG_PCI_PCIE`, plus an unvalidated driver.

That is a much better position than "impossible", and it is still three unknowns
deep. Do not buy hardware on the strength of it. The order that makes sense:
prove the tunnel with something cheap first (a dock, an NVMe enclosure), and only
then think about a GPU.

Supporting config on this kernel, already checked: `ARM_SMMU_V3=y`,
`IOMMU_DMA=y`, `VFIO=y`, `DRM_NOUVEAU=m`. The DMA and isolation side is in place.

---

## Order of operations, condensed

```
0.  Recovery key off-machine + verified   <- do not skip
1.  Suspend-BitLocker -RebootCount 2
2.  Secure Boot off (or MOK route)
3.  Boot the BASELINE ISO live            -> multi-touch answered
4.  Boot Windows once, Resume-BitLocker
5.  Build the integrated kernel
6.  Install to an external USB SSD
7.  Measurements 1-4, iterating on that disk
8.  Feed results back into PRs #1-#5, delete the debug branch
```

Steps 3 and 7 are where the actual information is. Steps 0–2 exist so that a bad
outcome costs an evening instead of a Windows install.
