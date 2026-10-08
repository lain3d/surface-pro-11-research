# Session state — 2026-08-03

The machine boots Linux. That is new. Everything below is either how that
happened, what it unblocked, or what it corrected.

Read `docs/boot-failure.md` first for why GRUB was abandoned; this file is what
replaced it and what came after.

---

## Where things stand

| | state |
|---|---|
| Boot | **works**, via a UKI, no GRUB anywhere |
| Display | **works**, 2880×1920, DPU + panel bound |
| GPU | **works** — needed a firmware blob extracted from Windows |
| Storage / PCIe | works (NVMe enumerates on the other controller) |
| Bluetooth | works |
| WiFi | chip enumerates, driver binds, board data loads; **blocked at rfkill** |
| Audio | broken — LPASS pinctrl cannot get its `core` clock |
| ADSP / CDSP | offline — needs a second firmware file per DSP |
| Camera / USB4 / heat map | untested; need the INTEG kernel, which is mid-bring-up |

Boot time went 3 min → **48 s**, almost entirely by removing `keep_bootcon`.

---

## 1. The boot chain

GRUB was replaced entirely. One file does everything:

```
T7 partition 4 (ESP, 489 MB, vfat, UUID 5011-AB20)
└── \EFI\BOOT\BOOTAA64.EFI
    ├── .linux     the kernel
    ├── .initrd    the initramfs
    ├── .cmdline   root=UUID=… ro quiet loglevel=4 console=tty0
    │              clk_ignore_unused pd_ignore_unused arm64.nopauth
    └── .dtb       our device tree
└── \EFI\sp11\stock-fallback.efi     known-good, boots
```

**Ubuntu's `vmlinuz` is itself a UKI.** It carries systemd-stub, the real kernel
in `.linux`, a `.hwids` table and **32 `.dtbauto` sections** — one board device
tree each, selected by hardware ID. Wrapping it in another UKI produces
`kernel has no image base relocations`; the fix is to add `.cmdline` and
`.initrd` to Ubuntu's image rather than around it.

**`.dtbauto` outranks `.dtb`.** An explicit `.dtb` is ignored while a hardware
ID match exists. Strip `.dtbauto` and `.hwids` for the `.dtb` to take effect.
This contradicts the precedence table in the primer PDF, which says explicit
beats automatic — **the PDF is wrong on that point.**

The INTEG kernel is a raw `Image`, not a UKI, so it is wrapped with the
systemd 259.5 stub instead (Ubuntu 22.04's stub is 249 and silently ignores
`.dtb`; `systemd-boot-efi` is in **universe**, not main, and 26.04's `systemd`
package no longer ships the stub at all).

### Iterating

Everything is done from Windows. The ESP mounts directly:

```powershell
Get-Partition -DiskNumber 1 -PartitionNumber 4 | Add-PartitionAccessPath -AccessPath 'X:\'
Copy-Item C:\sp11-stage\<image>.efi X:\EFI\BOOT\BOOTAA64.EFI -Force
Get-Partition -DiskNumber 1 -PartitionNumber 4 | Remove-PartitionAccessPath -AccessPath 'X:\'
```

No usbipd, no reboot, no replug. **Rollback is one copy.**

For the ext4 root, usbipd is still required — `wsl --mount` needs Windows build
27653 on ARM64 and this machine ships 26200. Sequence:

```
usbipd bind --force --busid 2-2      # Windows loses D:/E: while bound
usbipd attach --wsl --busid 2-2      # retry if "busy"; physical replug if it persists
… work …
usbipd detach ; usbipd unbind        # unbind is what forces the next replug
```

---

## 2. WiFi — four sequential problems

Each was only visible after fixing the one before. None is an alternative to
another.

```
reset-gpios (PERST#) -> link trains -> endpoint enumerates -> ath12k binds
   -> amss.bin loads -> board.bin (BDF) accepted -> rfkill permits TX
```

### 2.1 PCIe link never trained — `reset-gpios` missing

`qcom-pcie 1c08000.pci: Device not found` / `LTSSM: PRE_DETECT_QUIET`.

Extracted all 32 board DTBs from Ubuntu's kernel and diffed. **23 of 24 X1E
boards with a WCN7850 declare `reset-gpios` and `wake-gpios` on the PCIe port
node. denali is the only one that does not.** Every board uses the same pins —
146 (PERST#) and 148 (WAKE) — including both Surface Laptop 7 variants, same
OEM. denali *does* have them on its other PCIe controller, the one that works.

Fix, now committed in the tree:

```dts
&pcie4_port0 {
	reset-gpios = <&tlmm 146 GPIO_ACTIVE_LOW>;
	wake-gpios = <&tlmm 148 GPIO_ACTIVE_LOW>;
```

Adding it made the chip enumerate immediately.

**Unresolved:** denisix's users get WiFi on jg 7.1.3 with a DTB that lacks this,
and none of their 18 patches touches PCIe. So the property is evidently not
required on that kernel and is on Ubuntu's 7.0.0-22. A maintainer will ask why;
booting INTEG answers it.

`vddio1p2 not found, using dummy regulator` is a **red herring** — no X1E board
declares it, including every one whose WiFi works.

### 2.2 The `.dtb` was ignored

See §1. Stripping `.dtbauto`/`.hwids` fixed it. Verified by reading the live
tree, not by assuming.

### 2.3 Board data — path, then framing

`qmi-board-id=255` (0xff) means no board ID was ever programmed, so the
`board-2.bin` lookup key matches nothing. The container has entries for our
subsystem (`17cb:1107`) with board-ids 82 and 44, and entries with board-id 255
under *other* subsystems — never both.

`ath12k` falls back to `board.bin`, which is the slot we used.

Two attempts:

- **Windows' `bdwlan.elf` payload extracted** → `-110`. Wrong: the entries
  inside `board-2.bin` are **whole ELF files**, not payloads.
- **`bdwlan.elf` verbatim** → still `-110` on a clean boot.

Error transitions are the diagnostic: `-2` = file not found, `-110` = found,
transmitted, firmware rejected it.

**`lf82` works** — a BDF lifted from linux-firmware's own `board-2.bin`
(subsystem `17cb:1107`, board-id 82). Interface `wlP4p1s0` appears, no QMI
errors.

Leading explanation for the Windows file failing: it pairs with `wlanfw20.mbn`,
while we run `amss.bin` (`WLAN.HMT.1.1.c7-00108-…UPSTREAM-3`). BDF layout is
defined by the firmware that parses it. **Not established** — the timeout says
rejected, not why.

If `lf82`'s calibration proves inadequate, the transplant is the open idea: 25
Windows BDFs and 25 linux-firmware BDFs are on disk; diff *within* each set to
find which byte ranges vary per board (calibration) versus stay constant
(format), then graft. Pure offline analysis.

### 2.4 rfkill — where it stands now

```
rfkill0  bluetooth  soft=0 hard=0
rfkill1  wlan       soft=0 hard=1
```

**Bluetooth is not blocked and it is the same chip**, so this is not a physical
switch — it is the WiFi firmware polling a GPIO and reading it as killed. Which
pin it polls comes from the board data, so the borrowed BDF is a live suspect.

Hard blocks cannot be cleared from userspace by design.

**The kernel patch is not needed.** jg 7.1.3 already has, at
`drivers/net/wireless/ath/ath12k/core.c:83`:

```c
if (of_property_read_bool(ab->dev->of_node, "disable-rfkill"))
	return 0;
```

and `x1-microsoft-denali.dtsi` already carries `disable-rfkill;` on `wifi@0`,
committed in the jg import. dwhinham's hardcoded `return 0` exists only because
his firmware supplied the device tree and he could not set the property. **We
inject our own DTB, so we can.**

Adding the property under Ubuntu's 7.0.0-22 changed nothing — verified present
in the live tree, still `hard=1` — so that kernel lacks the check. Hence INTEG.

---

## 3. Firmware extracted from Windows

Everything below was missing and is now installed under `/lib/firmware`.

| file | Windows path | fixes |
|---|---|---|
| `qcdxkmsuc8380.mbn` | `qcdx8380.inf_arm64_8053adc44985505a\` | **GPU** — without it `gpu hw init failed: -2` and GNOME renders on llvmpipe |
| `qcadsp8380.mbn` | `surfacepro_ext_adsp8380.inf_arm64_3cc952aaca3564ae\` | ADSP |
| `qccdsp8380.mbn` | `qcnspmcdm_ext_cdsp8380.inf_arm64_4a8c3ebe3aad408a\` | CDSP |
| `adsp_dtbs.elf`, `cdsp_dtbs.elf` | same dirs | the DSPs' own device trees |
| `bdwlan.elf` | `qcwlanhmt8380.inf_arm64_f6c170edbe88d474\` | WiFi BDF (rejected — see §2.3) |

Staged at `E:\surface\firmware\`, installed by `sp11-install-wifi-bdf.sh` and
the retired `fix-firmware.sh`.

**Two traps in the paths.** The ADSP lives under a *Surface-specific*
`surfacepro_ext_adsp8380` directory, not the generic one documented in
dwhinham's issue #26. And there are **two copies of the zap shader with
different hashes** — the active one (matching `C:\Windows\System32\`) is
`8053adc44985505a`; issue #26 points at `e13ac55ddce2b10f`, which is the stale
one here.

### The DSPs still fail

The device tree asks for **two** files each:

```
firmware-name = "…/qcadsp8380.mbn"  "…/adsp_dtb.mbn"
```

`adsp_dtb.mbn` does not exist in Windows. **22 of 24 boards use
`adsp_dtbs.elf`** — including Surface Laptop 7, same OEM — and only denali and
Qualcomm's CRD ask for `adsp_dtb.mbn`. Windows ships the `.elf`, so it is
installed under both names. Whether they are actually the same artifact is
**an assumption, not a finding.**

Also a timing problem: remoteproc requests firmware at **1.19 s**, the root
filesystem mounts at **3.43 s**. Firmware on `/` is invisible at probe time.

**Do not auto-start the DSPs.** Starting one hands a coprocessor 59 MB + 32 MB
of reserved memory and its own SMMU-mapped DMA, fed a file we substituted on an
assumption. `sp11-dsp-disable.sh` removes the service; the manual starter is
kept as `sp11-dsp-start-manual`.

---

## 4. Corrections to earlier claims

Recorded because each was stated with more confidence than the evidence
supported.

| claim | reality |
|---|---|
| "`.dtb` beats `.dtbauto`" | backwards; `.dtbauto` wins. **The primer PDF is wrong** |
| "the firmware supplies the device tree on SP11" | it does not — the kernel image does, via `.dtbauto` |
| "stock Ubuntu has no camera nodes at all" | it has camss/CCI/CSIPHY, `status = "disabled"`, no *sensor* nodes |
| "`vddio1p2 not found` is the WiFi cause" | red herring; no X1E board declares it |
| "the I/O errors were probably my DSP start" | the DSPs never started (`offline -> offline` in the log). It was the T7 dropping off Thunderbolt |
| "denisix is stock Ubuntu plus scripts" | it builds a patched kernel from the jg tree |
| "we need a kernel patch for rfkill" | the DT property and the driver check both already exist |
| "partition 5 is empty, safe to format" | **the ext4 superblock is at byte 1024.** Reading sector 0 shows zeros for a full filesystem. `blkid` is the correct check — it caught a live install |

---

## 5. INTEG — current bring-up

Built from **`integration/iso2`**, commit `f2cc827b6`, which merges all five
branches. The kernel version string encodes it:
`7.1.3-sp11-integ-gf2cc827b6b89`. **`git describe` is the ground truth for which
tree a build came from.**

Staged:

```
C:\sp11-stage\integ-Image                          52,623,872  PE, "ARM\x64" at 0x38
C:\sp11-stage\initrd.img-7.1.3-sp11-integ-…        60,151,510
C:\sp11-stage\integ-denali-perst.dtb                  219,998
C:\sp11-stage\BOOTAA64-integ2.efi                 113,085,952  installed
```

### First boot stalled at 0.196 s

```
vreg_l16b_2p9: failed to get the current voltage: -ENOTRECOVERABLE
qcom-rpmh-regulator 17500000.rsc:regulators-0: ldo16: devm_regula…
```

Our own commit `6df377fd7` added the rail at **2,900,000 µV**. The pm8550 pLDO
is `REGULATOR_LINEAR_RANGE(1504000, 0, 255, 8000)`, verified in
`drivers/regulator/qcom-rpmh-regulator.c`:

```
2800000 -> selector 162     exact    (ldo7, never complained)
2900000 -> selector 174.5   INVALID  -> no selector -> -ENOTRECOVERABLE
2912000 -> selector 176     exact
```

One bad rail kills the whole `regulators-0` node, which cascades to
`pmic_glink` and stalls the boot.

Fixed to **2912000**, which `hamoa-iot-som.dtsi` already uses for the identical
rail on the same PMIC.

**General rule: voltages lifted from Windows blobs are nominal. Snap every one
to `1504000 + n×8000` before putting it in a device tree.** 2.8 V happened to
land on the grid; 2.9 V did not.

### Uncommitted in the tree

On `integration/iso2`, in `x1-microsoft-denali.dtsi`:

- `reset-gpios` / `wake-gpios` on `&pcie4_port0` — **new, upstreamable**
- `vreg_l16b_2p9` 2900000 → 2912000 — a fix to our own commit

Both need committing once a boot confirms them.

---

## 6. Traps

- **`modprobe -r ath12k_wifi7_pci` does nothing** — that is the *driver* name;
  the module is `ath12k`. With `2>/dev/null` it fails silently and every
  subsequent test silently re-reads nothing. Three BDF candidates were
  "tested" this way and none actually ran. **Prove a re-probe happened** (look
  for a fresh `Wi-Fi 7 Hardware name` line) before reporting any result.
- **`ath12k` also logs `ignore reset dev flags 0x12`** — it skips a device
  reset, so unbind/bind is not a clean slate. **Reboot between BDF candidates.**
- **WSL `/tmp` is cleared on restart.** Anything that must survive goes on
  `/mnt/c`. Extracted DTBs were lost twice this way.
- **PowerShell mangles inline `wsl bash -c`** — `$VAR`, `<`, `>` and quotes are
  eaten. Always write a script file and `tr -d '\r'` it.
- **The WSL kernel has neither `vfat` nor `exfat`.** The ESP cannot be mounted
  there. `mkfs.vfat` works on the raw device; `mtools` (`mcopy`, `mdir`,
  `mdeltree`) reads and writes FAT unmounted. From Windows the ESP mounts fine
  as a drive letter.
- **Two ESPs on one disk is ambiguous** — the firmware offers only a generic
  `USB Storage` entry. Retyping partition 2 to `0700` was not enough on its
  own; the firmware still booted its `\EFI\BOOT\BOOTAA64.EFI`. **Renaming that
  directory is what worked.**
- **Retyping a partition shifts Windows drive letters.** `D:` became the old
  live ESP and the data partition moved to `E:`.
- **Diagnostics must self-deliver.** Anything writing only to `~` on the Linux
  side is unreadable from Windows without a usbipd attach. Every script now
  writes to `/mnt/t7/surface/diag/`.
- **A rebuilt artifact that is *smaller* after adding content is a red flag.**
  `make dtbs` on the wrong branch silently produced a DTB with no camera and no
  USB4 nodes; only the byte count exposed it. Check node inventory, not just
  that the build succeeded.

---

## 7. Next

1. Boot the fixed INTEG image. `uname -r` should read
   `7.1.3-sp11-integ-gf2cc827b6b89`.
2. `dmesg | grep 'DEBUG:'` — the camera I²C scan. Expect **two** responders:
   `0x50` (module EEPROM, confirms the bus) and the sensor. This number is
   provably absent from firmware and is the reason the debug branch exists.
3. WiFi should clear rfkill via `disable-rfkill` on this kernel.
4. `ls /sys/bus/thunderbolt/devices/` — three routers now enabled.
5. Heat map via `tools/sp11-hid.py`.
6. Commit the two DTS changes; the PERST one is the upstream candidate.
7. Audio: `qcom-sm8550-lpass-lpi-pinctrl: Failed to get clk 'core'` stalls every
   codec. Self-contained, plausibly upstreamable.
8. Correct the `.dtb`/`.dtbauto` precedence claim in the primer PDF and the
   boot-chain artifact.
