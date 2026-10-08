# Getting at the Surface's disk from Windows

The Surface Pro 11 boots Linux off the Samsung T7 Shield over USB-C. When it
fails to boot there is no shell on the machine, so everything is read from the
Windows side. Two scripts do it.

| | |
|---|---|
| `sp11-disk.ps1` | move the drive between Windows and WSL, mount the ESP |
| `sp11-journal.sh` | mount the ext4 root read-only and read its journals |
| `sp11-winlog.sh` | stream `/dev/kmsg` to the Windows ESP, for boots where the root disk dies |
| `install-sp11-winlog.sh` | install that onto the Surface and enable it |
| `sp11-install-fw.sh` | copy firmware blobs onto the root fs (mounts **rw**) |
| `sp11-adsp-fw.sh` | hide/restore the ADSP firmware, to keep the CDSP without the ADSP |

For which logging mechanism to reach for and why the obvious ones fail, see
`design/boot-diagnostics.md`.

## Install a UKI

```powershell
.\tools\sp11-disk.ps1 esp                      # mounts the T7's ESP as S:
Copy-Item C:\sp11-stage\BOOTAA64-integ12-uas.efi S:\EFI\BOOT\BOOTAA64.EFI -Force
```

Verify with `Get-FileHash` on both sides before rebooting. Rollback is the same
copy with `BOOTAA64-integ9.efi`, or `BOOTAA64-stock-KNOWN-GOOD.efi` for the
Ubuntu kernel that reaches a desktop.

The ESP is looked up by partition type on the T7 itself, not by a hardcoded
GUID. **The internal NVMe also has a System partition — the bootloader never
goes there.**

## Read the journals

```powershell
.\tools\sp11-disk.ps1 to-wsl
wsl -d Ubuntu-22.04 -u root bash tools/sp11-journal.sh
.\tools\sp11-disk.ps1 to-win
```

`sp11-journal.sh` prints one row per boot — kernel, the speed the T7 enumerated
at, which driver claimed it, and how far the boot got — and writes each boot to
`C:\sp11-stage\logs\boot<N>.txt`. That table is what identified the fault:

```
BOOT  KERNEL                          T7 SPEED    DRIVER       REACHED
 -20  7.0.0-22-qcom-x1e               high-speed  uas          DESKTOP
  -9  7.1.3-sp11-integ-gf2cc827b6b89  high-speed  usb-storage  ends at 15:49
```

## Install firmware

```powershell
.\tools\sp11-disk.ps1 to-wsl
wsl -d Ubuntu-22.04 -u root bash tools/sp11-install-fw.sh
.\tools\sp11-disk.ps1 to-win
```

Stage blobs in `C:\sp11-stage\fw`. A bare filename lands in
`/lib/firmware/qcom/x1e80100/microsoft/Denali/` — this board's directory, Denali
being the Surface Pro 11's codename. Stage a path if you need somewhere else.

**Board-specific signed firmware exists only in the Windows driver store**;
`linux-firmware` does not redistribute it. Look in
`C:\Windows\System32\DriverStore\FileRepository\qcdx8380.inf_arm64_*`. There is
more than one such directory and **their blobs are not identical** — pick the
one whose `qcdx8380.inf` hashes equal to the `oemNNN.inf` in `C:\Windows\INF`
that the Adreno is actually bound to (`Get-PnpDeviceProperty ... DriverInfPath`).

## Why it is this convoluted

- **`wsl --mount` does not work here.** On ARM64 it needs Windows build 27653+;
  this machine is 26200. usbipd-win passes the USB device through instead.
- **usbipd refuses while Windows holds the disk** — `Device busy (exported)`,
  because two partitions are mounted as `D:` and `E:`. `sp11-disk.ps1 to-wsl`
  takes the disk offline first, which dismounts them cleanly. `bind --force`
  also works but yanks a mounted 1.6 TB volume out from under Windows.
- **Mount `ro,noload`.** The filesystem is dirty after every failed boot, and a
  plain read-only ext4 mount still replays the journal — a write to the
  machine's root filesystem.
- **WSL's `journalctl` cannot read these journals.** WSL is Ubuntu 22.04
  (systemd 249), the Surface runs 26.04 (systemd 259). 249 rejects the newer
  files with `unsupported feature, ignoring file`, which reads as corruption and
  is not. `sp11-journal.sh` runs the *target's own* `journalctl` through its own
  loader — WSL is native aarch64, so no chroot is needed. Note that
  `libsystemd-shared-NNN.so` sits in `/usr/lib/aarch64-linux-gnu/systemd`, which
  is not a default search path.
- **usbipd costs 7-10x throughput** — `vhci_hcd` has no bulk streams, so UAS
  refuses and the disk falls back to BOT. Fine for reading logs, not for bulk
  copies.

## The limit of this method

The journal lives on the disk that dies. On a failing boot it stops at the last
flush, so **the errors themselves are never written** — they exist only on the
console. Recovering those needs `CONFIG_PSTORE_CONSOLE` plus a ramoops carveout,
so the next boot can read the previous boot's console out of RAM.
